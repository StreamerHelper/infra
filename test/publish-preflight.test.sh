#!/bin/bash

set -euo pipefail

INFRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

mkdir -p "$TEST_DIR/bin" "$TEST_DIR/docker-authenticated"
cat > "$TEST_DIR/docker-authenticated/config.json" <<'EOF'
{
  "auths": {
    "ghcr.io": {
      "auth": "dGVzdDp0ZXN0"
    }
  }
}
EOF

DOCKER_CONFIG="$TEST_DIR/docker-authenticated" \
    bash "$INFRA_DIR/bin/assert-registry-auth" ghcr.io \
    || fail "inline GHCR credential was not detected"

mkdir -p "$TEST_DIR/docker-helper"
printf '%s\n' '{"auths": {}, "credsStore": "teststore"}' \
    > "$TEST_DIR/docker-helper/config.json"
cat > "$TEST_DIR/bin/docker-credential-teststore" <<'EOF'
#!/bin/bash

[ "${1:-}" = "get" ] || exit 1
IFS= read -r server
[ "$server" = "ghcr.io" ] || exit 1
printf '%s\n' '{"Username":"test-user","Secret":"test-token"}'
EOF
chmod +x "$TEST_DIR/bin/docker-credential-teststore"
DOCKER_CONFIG="$TEST_DIR/docker-helper" \
PATH="$TEST_DIR/bin:$PATH" \
    bash "$INFRA_DIR/bin/assert-registry-auth" ghcr.io \
    || fail "credential-helper GHCR login was not detected"

mkdir -p "$TEST_DIR/docker-missing"
printf '%s\n' '{"auths": {}}' > "$TEST_DIR/docker-missing/config.json"
missing_auth_output="$(
    DOCKER_CONFIG="$TEST_DIR/docker-missing" \
        bash "$INFRA_DIR/bin/assert-registry-auth" ghcr.io 2>&1 || true
)"
grep -q "docker login ghcr.io" <<<"$missing_auth_output" \
    || fail "missing registry credential did not provide login guidance"

WORKFLOW="$INFRA_DIR/.github/workflows/build.yml"
grep -q '^  DOCKER_REGISTRY: ghcr.io$' "$WORKFLOW" \
    || fail "workflow does not publish to GHCR"
grep -q '^  DOCKER_ORG: streamerhelper$' "$WORKFLOW" \
    || fail "workflow does not publish to the streamerhelper namespace"
grep -Fq 'username: ${{ github.actor }}' "$WORKFLOW" \
    || fail "workflow does not use github.actor for GHCR login"
grep -Fq 'password: ${{ secrets.GITHUB_TOKEN }}' "$WORKFLOW" \
    || fail "workflow does not use GITHUB_TOKEN for GHCR login"
grep -q '^      packages: write$' "$WORKFLOW" \
    || fail "workflow lost packages:write permission"
if grep -Eq 'DOCKERHUB_|Login to Docker Hub' "$WORKFLOW"; then
    fail "workflow still depends on Docker Hub credentials"
fi

cat > "$TEST_DIR/bin/docker" <<'EOF'
#!/bin/bash

printf '%s\n' "$*" >> "$PUBLISH_DOCKER_LOG"
case "$*" in
    "buildx version")
        exit 0
        ;;
    "buildx imagetools inspect "*)
        echo "manifest unknown: manifest unknown" >&2
        exit 1
        ;;
    "buildx build "*)
        exit 0
        ;;
    *)
        echo "unexpected docker invocation: $*" >&2
        exit 2
        ;;
esac
EOF
chmod +x "$TEST_DIR/bin/docker"

PUBLISH_DOCKER_LOG="$TEST_DIR/docker.log" \
DOCKER_CONFIG="$TEST_DIR/docker-authenticated" \
PATH="$TEST_DIR/bin:$PATH" \
    bash "$INFRA_DIR/build-and-push.sh" v-test-publish \
    >"$TEST_DIR/publish.log" 2>&1 \
    || {
        sed -n '1,120p' "$TEST_DIR/publish.log" >&2
        fail "authenticated publish preflight did not reach all mocked builds"
    }

if grep -q 'busybox' "$TEST_DIR/docker.log"; then
    fail "publish preflight still uses a public pull as an authentication check"
fi

build_count="$(grep -c '^buildx build ' "$TEST_DIR/docker.log" || true)"
[ "$build_count" = "4" ] || fail "expected four multi-architecture builds, got $build_count"

for component in backend frontend browser douyin-resolver; do
    grep -q -- \
        "-t ghcr.io/streamerhelper/streamerhelper-${component}:v-test-publish" \
        "$TEST_DIR/docker.log" \
        || fail "publish did not target the GHCR ${component} image"
done

platform_count="$(
    grep -c -- '--platform linux/amd64,linux/arm64 --push' "$TEST_DIR/docker.log" || true
)"
[ "$platform_count" = "4" ] \
    || fail "not all release images were built for amd64 and arm64"

: > "$TEST_DIR/docker.log"
if PUBLISH_DOCKER_LOG="$TEST_DIR/docker.log" \
    DOCKER_CONFIG="$TEST_DIR/docker-missing" \
    PATH="$TEST_DIR/bin:$PATH" \
        bash "$INFRA_DIR/build-and-push.sh" v-test-no-auth \
        >"$TEST_DIR/no-auth.log" 2>&1; then
    fail "publish proceeded without GHCR credentials"
fi
grep -q "docker login ghcr.io" "$TEST_DIR/no-auth.log" \
    || fail "publish authentication failure did not provide login guidance"
if grep -Eq '^buildx (build|imagetools inspect) ' "$TEST_DIR/docker.log"; then
    fail "publish inspected tags or started builds before rejecting missing registry credentials"
fi

echo "publish preflight tests passed"
