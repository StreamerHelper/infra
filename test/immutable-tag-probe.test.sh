#!/bin/bash

set -euo pipefail

INFRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT

mkdir -p "$TEST_DIR/bin"
cat > "$TEST_DIR/bin/docker" <<'EOF'
#!/bin/bash

case "${TAG_PROBE_SCENARIO:-}" in
    missing)
        echo "ERROR: docker.io/example/app:v-test: not found" >&2
        exit 1
        ;;
    manifest_unknown)
        echo "manifest unknown: manifest unknown" >&2
        exit 1
        ;;
    existing)
        echo "Name: docker.io/example/app:v-test"
        exit 0
        ;;
    tls_error)
        echo "ERROR: Get https://registry.example/v2/: net/http: TLS handshake timeout" >&2
        exit 1
        ;;
    auth_error)
        echo "ERROR: pull access denied, repository does not exist or may require authorization" >&2
        exit 1
        ;;
    *)
        echo "unexpected probe scenario" >&2
        exit 2
        ;;
esac
EOF
chmod +x "$TEST_DIR/bin/docker"

run_probe() {
    TAG_PROBE_SCENARIO="$1" \
        PATH="$TEST_DIR/bin:$PATH" \
        bash "$INFRA_DIR/bin/assert-image-tag-unused" \
        docker.io/example/app:v-test >/dev/null 2>&1
}

run_probe missing || {
    echo "FAIL: explicit not-found result was not accepted" >&2
    exit 1
}

run_probe manifest_unknown || {
    echo "FAIL: explicit manifest-unknown result was not accepted" >&2
    exit 1
}

for scenario in existing tls_error auth_error; do
    if run_probe "$scenario"; then
        echo "FAIL: $scenario was incorrectly treated as an unused tag" >&2
        exit 1
    fi
done

auth_output="$(
    TAG_PROBE_SCENARIO=auth_error \
        PATH="$TEST_DIR/bin:$PATH" \
        bash "$INFRA_DIR/bin/assert-image-tag-unused" \
        ghcr.io/example/app:v-test 2>&1 || true
)"
grep -q "docker login ghcr.io" <<<"$auth_output" || {
    echo "FAIL: authentication failure did not provide registry login guidance" >&2
    exit 1
}

echo "immutable tag probe tests passed"
