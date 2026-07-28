#!/bin/bash

set -euo pipefail

INFRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_CONFIG_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_CONFIG_DIR"' EXIT

export STREAMER_HELPER_CONFIG_DIR="$TEST_CONFIG_DIR"
# shellcheck source=../bin/control
source "$INFRA_DIR/bin/control"
cp "$INFRA_DIR/settings.example.json" "$CONFIG_FILE"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

assert_equal() {
    local expected="$1"
    local actual="$2"
    local label="$3"
    [ "$actual" = "$expected" ] || fail "$label: expected '$expected', got '$actual'"
}

assert_file_value() {
    local expected="$1"
    local actual=""
    IFS= read -r actual < "$RELEASE_VERSION_FILE"
    assert_equal "$expected" "$actual" "release pin"
}

clear_explicit_versions() {
    CONTROL_BACKEND_VERSION=""
    CONTROL_FRONTEND_VERSION=""
    CONTROL_BROWSER_VERSION=""
    CONTROL_DOUYIN_RESOLVER_VERSION=""
}

if resolve_backend_version >/dev/null; then
    fail "un-pinned backend unexpectedly resolved a version"
fi
if require_pinned_release_version >"$TEST_CONFIG_DIR/no-pin.log" 2>&1; then
    fail "missing release pin was accepted"
fi
grep -q 'update app <version>' "$TEST_CONFIG_DIR/no-pin.log" \
    || fail "missing release pin did not provide bootstrap guidance"
if (do_app_up) >"$TEST_CONFIG_DIR/app-up-no-pin.log" 2>&1; then
    fail "app up succeeded without a release pin"
fi
if (do_up) >"$TEST_CONFIG_DIR/up-no-pin.log" 2>&1; then
    fail "combined up succeeded without a release pin"
fi

docker() {
    printf '%s:%s:%s:%s\n' \
        "$BACKEND_VERSION" \
        "$FRONTEND_VERSION" \
        "$BROWSER_VERSION" \
        "$DOUYIN_RESOLVER_VERSION"
}
assert_equal "local:local:local:local" "$(compose_app_dev config)" \
    "development versions without a release pin"
unset -f docker

generate_env_file
if grep -q '^BACKEND_VERSION=' "$ENV_FILE"; then
    fail "un-pinned environment unexpectedly contains application versions"
fi

printf 'not/a/tag\n' > "$RELEASE_VERSION_FILE"
CONTROL_PINNED_RELEASE_VERSION="not/a/tag"
if validate_existing_release_pin >/dev/null 2>&1; then
    fail "corrupt release pin was accepted"
fi
if resolve_backend_version >/dev/null; then
    fail "corrupt release pin fell back to another version"
fi
printf 'v-test-old\nunexpected-second-line\n' > "$RELEASE_VERSION_FILE"
CONTROL_PINNED_RELEASE_VERSION="v-test-old"
if validate_existing_release_pin >/dev/null 2>&1; then
    fail "multi-line release pin was accepted"
fi
rm -f "$RELEASE_VERSION_FILE"
CONTROL_PINNED_RELEASE_VERSION=""

persist_release_version "v-test-old"
assert_file_value "v-test-old"
clear_explicit_versions
assert_equal "v-test-old" "$(resolve_backend_version)" "pinned backend version"
assert_equal "v-test-old" "$(resolve_frontend_version)" "pinned frontend version"
assert_equal "v-test-old" "$(resolve_browser_version)" "pinned browser version"
assert_equal "v-test-old" "$(resolve_douyin_resolver_version)" "pinned resolver version"

# A candidate version in the current update process must not become durable
# merely because the environment file is regenerated before migration.
CONTROL_BACKEND_VERSION="v-test-candidate"
CONTROL_FRONTEND_VERSION="v-test-candidate"
CONTROL_BROWSER_VERSION="v-test-candidate"
CONTROL_DOUYIN_RESOLVER_VERSION="v-test-candidate"
generate_env_file
for variable in BACKEND_VERSION FRONTEND_VERSION BROWSER_VERSION DOUYIN_RESOLVER_VERSION; do
    grep -qx "${variable}=v-test-old" "$ENV_FILE" \
        || fail "$ENV_FILE does not preserve ${variable}"
done
clear_explicit_versions

new_process_version="$(
    STREAMER_HELPER_CONFIG_DIR="$TEST_CONFIG_DIR" \
        bash -c 'source "$1/bin/control"; resolve_backend_version' -- "$INFRA_DIR"
)"
assert_equal "v-test-old" "$new_process_version" "new process release pin"

if persist_release_version "latest"; then
    fail "latest was accepted as a persistent release"
fi
assert_file_value "v-test-old"

# Replace side effects so update ordering and pin transitions can be exercised.
check_dependencies() { :; }
check_config() { :; }
generate_env_file() { :; }
check_optional_application_services() { return 0; }
APP_RUNNING=1
FAIL_STAGE=""
MISSING_PRELOADED_IMAGE=""
CALL_LOG="$TEST_CONFIG_DIR/calls.log"
run_with_retries() {
    if [ "$FAIL_STAGE" = "pull" ]; then
        return 1
    fi
    shift
    "$@"
}
docker() {
    if [ "${1:-}" = "ps" ]; then
        if [ "$APP_RUNNING" -eq 1 ]; then
            echo "streamer-backend"
        fi
    elif [ "${1:-}" = "image" ] && [ "${2:-}" = "inspect" ]; then
        printf 'image-inspect:%s\n' "${3:-}" >> "$CALL_LOG"
        if [ "${3:-}" = "$MISSING_PRELOADED_IMAGE" ]; then
            return 1
        fi
    elif [ "${1:-}" = "compose" ] \
        && [[ " $* " == *" $COMPOSE_APP "* ]] \
        && [[ " $* " == *" down "* ]]; then
        printf 'down-helper:%s:%s:%s:%s\n' \
            "${BACKEND_VERSION:-}" \
            "${FRONTEND_VERSION:-}" \
            "${BROWSER_VERSION:-}" \
            "${DOUYIN_RESOLVER_VERSION:-}" >> "$CALL_LOG"
        APP_RUNNING=0
    fi
    return 0
}
compose_app() {
    local version
    version="$(resolve_backend_version)"
    printf '%s:%s\n' "$version" "$*" >> "$CALL_LOG"
    if [ "$version" != "v-test-old" ] \
        && [ "${1:-}" = "up" ] \
        && [ "$FAIL_STAGE" = "recreate" ]; then
        return 1
    fi
    if [ "${1:-}" = "down" ]; then
        APP_RUNNING=0
    elif [ "${1:-}" = "up" ]; then
        APP_RUNNING=1
    fi
    return 0
}
wait_for_healthy() {
    local version
    version="$(resolve_backend_version)"
    printf 'health:%s:%s\n' "$version" "$1" >> "$CALL_LOG"
    if [ "$version" != "v-test-old" ] \
        && [ "$FAIL_STAGE" = "backend_health" ] \
        && [ "$1" = "streamer-backend" ]; then
        return 1
    fi
    if [ "$version" != "v-test-old" ] \
        && [ "$FAIL_STAGE" = "frontend_health" ] \
        && [ "$1" = "streamer-frontend" ]; then
        return 1
    fi
    if [ "$version" != "v-test-old" ] \
        && [ "$FAIL_STAGE" = "nginx_health" ] \
        && [ "$1" = "streamer-nginx" ]; then
        return 1
    fi
    if [ "$version" = "v-test-old" ] \
        && [ "$FAIL_STAGE" = "restore_nginx_health" ] \
        && [ "$1" = "streamer-nginx" ]; then
        return 1
    fi
    return 0
}
do_migrate() {
    printf 'migrate:%s\n' "$(resolve_backend_version)" >> "$CALL_LOG"
    [ "$FAIL_STAGE" != "migration" ]
}

# Stop-only commands must remain usable without a release pin even though the
# Compose file itself requires all application image versions.
rm -f "$RELEASE_VERSION_FILE"
CONTROL_PINNED_RELEASE_VERSION=""
clear_explicit_versions
APP_RUNNING=0
: > "$CALL_LOG"
if ! (do_app_down); then
    fail "app down failed without a release pin"
fi
if ! (do_down); then
    fail "combined down failed without a release pin"
fi
down_helper_count="$(
    grep -c '^down-helper:unused-for-down:unused-for-down:unused-for-down:unused-for-down$' \
        "$CALL_LOG" || true
)"
assert_equal "2" "$down_helper_count" "release-independent app teardown count"

persist_release_version "v-test-old"
clear_explicit_versions

# A direct update that fails before cutover must leave a running old release
# untouched. Failures after cutover starts must recreate that old release.
for failure_stage in pull migration; do
    APP_RUNNING=1
    FAIL_STAGE="$failure_stage"
    : > "$CALL_LOG"
    if (do_update_app "v-test-new"); then
        fail "running direct update $failure_stage failure unexpectedly succeeded"
    fi
    assert_file_value "v-test-old"
    old_restore_count="$(
        grep -c '^v-test-old:up -d --force-recreate$' "$CALL_LOG" || true
    )"
    assert_equal "0" "$old_restore_count" \
        "running direct update pre-cutover recovery count after $failure_stage"
done

for failure_stage in recreate backend_health frontend_health nginx_health; do
    APP_RUNNING=1
    FAIL_STAGE="$failure_stage"
    : > "$CALL_LOG"
    if (do_update_app "v-test-new"); then
        fail "running direct update $failure_stage failure unexpectedly succeeded"
    fi
    assert_file_value "v-test-old"
    old_restore_count="$(
        grep -c '^v-test-old:up -d --force-recreate$' "$CALL_LOG" || true
    )"
    assert_equal "1" "$old_restore_count" \
        "running direct update recovery count after $failure_stage"
    old_nginx_health_count="$(
        grep -c '^health:v-test-old:streamer-nginx$' "$CALL_LOG" || true
    )"
    assert_equal "1" "$old_nginx_health_count" \
        "running direct update recovery Nginx health count after $failure_stage"
done

# A direct update of an application that was already stopped must never start
# the old release. It only tears down candidate containers after cutover began.
for failure_stage in pull migration recreate backend_health frontend_health nginx_health; do
    APP_RUNNING=0
    FAIL_STAGE="$failure_stage"
    : > "$CALL_LOG"
    if (do_update_app "v-test-new"); then
        fail "stopped direct update $failure_stage failure unexpectedly succeeded"
    fi
    assert_file_value "v-test-old"
    old_restore_count="$(
        grep -c '^v-test-old:up -d --force-recreate$' "$CALL_LOG" || true
    )"
    assert_equal "0" "$old_restore_count" \
        "stopped direct update old-release start count after $failure_stage"
    candidate_down_count="$(
        grep -c '^v-test-new:down$' "$CALL_LOG" || true
    )"
    case "$failure_stage" in
        pull|migration)
            assert_equal "0" "$candidate_down_count" \
                "stopped direct update pre-cutover cleanup count after $failure_stage"
            ;;
        *)
            assert_equal "1" "$candidate_down_count" \
                "stopped direct update candidate cleanup count after $failure_stage"
            ;;
    esac
done

# Successful explicit updates still start and pin the candidate release.
APP_RUNNING=0
FAIL_STAGE=""
: > "$CALL_LOG"
if ! (do_update_app "v-test-new"); then
    fail "healthy update failed"
fi
assert_file_value "v-test-new"
normal_pull_count="$(
    grep -c '^v-test-new:pull backend frontend browser douyin-resolver nginx$' \
        "$CALL_LOG" || true
)"
assert_equal "1" "$normal_pull_count" "normal update pull count"
normal_nginx_health_count="$(
    grep -c '^health:v-test-new:streamer-nginx$' "$CALL_LOG" || true
)"
assert_equal "1" "$normal_nginx_health_count" "normal update Nginx health count"

# A restore is not successful until the public Nginx entrypoint is healthy.
FAIL_STAGE="restore_nginx_health"
: > "$CALL_LOG"
if restore_application_release "v-test-old"; then
    fail "restore unexpectedly succeeded with an unhealthy Nginx"
fi
restore_nginx_health_count="$(
    grep -c '^health:v-test-old:streamer-nginx$' "$CALL_LOG" || true
)"
assert_equal "1" "$restore_nginx_health_count" "restore Nginx health count"
FAIL_STAGE=""

# A preloaded update verifies all four exact candidate tags, skips only the
# registry pull, and then reuses migration, cutover, health, pin, and recovery.
persist_release_version "v-test-old"
clear_explicit_versions
APP_RUNNING=1
FAIL_STAGE=""
MISSING_PRELOADED_IMAGE=""
: > "$CALL_LOG"
if ! (do_update_app "v-test-preloaded" "" "" 1); then
    fail "healthy preloaded update failed"
fi
assert_file_value "v-test-preloaded"
preloaded_inspect_count="$(
    grep -c '^image-inspect:ghcr.io/streamerhelper/streamerhelper-.*:v-test-preloaded$' \
        "$CALL_LOG" || true
)"
assert_equal "4" "$preloaded_inspect_count" "preloaded exact-image inspection count"
preloaded_pull_count="$(
    grep -c '^v-test-preloaded:pull ' "$CALL_LOG" || true
)"
assert_equal "0" "$preloaded_pull_count" "preloaded registry pull count"
preloaded_migration_count="$(
    grep -c '^migrate:v-test-preloaded$' "$CALL_LOG" || true
)"
assert_equal "1" "$preloaded_migration_count" "preloaded migration count"
preloaded_start_count="$(
    grep -c '^v-test-preloaded:up -d --force-recreate$' "$CALL_LOG" || true
)"
assert_equal "1" "$preloaded_start_count" "preloaded cutover count"

# Missing preloaded images fail before migration or cutover and leave the old
# running release and its pin untouched.
persist_release_version "v-test-old"
clear_explicit_versions
APP_RUNNING=1
MISSING_PRELOADED_IMAGE="ghcr.io/streamerhelper/streamerhelper-browser:v-test-preloaded-missing"
: > "$CALL_LOG"
if (do_update_app "v-test-preloaded-missing" "" "" 1); then
    fail "preloaded update accepted a missing candidate image"
fi
assert_file_value "v-test-old"
missing_inspect_count="$(
    grep -c '^image-inspect:ghcr.io/streamerhelper/streamerhelper-.*:v-test-preloaded-missing$' \
        "$CALL_LOG" || true
)"
assert_equal "4" "$missing_inspect_count" "missing preloaded image inspection count"
missing_migration_count="$(
    grep -c '^migrate:v-test-preloaded-missing$' "$CALL_LOG" || true
)"
assert_equal "0" "$missing_migration_count" "missing preloaded image migration count"
missing_start_count="$(
    grep -c '^v-test-preloaded-missing:up -d --force-recreate$' "$CALL_LOG" || true
)"
assert_equal "0" "$missing_start_count" "missing preloaded image cutover count"
MISSING_PRELOADED_IMAGE=""

# update all must carry the pre-update state through its deliberate app stop.
CONTROL_PINNED_RELEASE_VERSION="v-test-old"
clear_explicit_versions
persist_release_version "v-test-old"
APP_RUNNING=1
do_update_infra() { return 0; }
FAIL_STAGE="migration"
: > "$CALL_LOG"

if (do_update_all "v-test-next"); then
    fail "running update all migration failure unexpectedly succeeded"
fi
assert_file_value "v-test-old"
restore_count="$(grep -c '^v-test-old:up -d --force-recreate$' "$CALL_LOG" || true)"
assert_equal "1" "$restore_count" \
    "running update all recovery count"

# If update all began while the application was stopped, an infrastructure
# failure must not start the old release.
APP_RUNNING=0
FAIL_STAGE=""
: > "$CALL_LOG"
do_update_infra() { return 1; }
if (do_update_all "v-test-next"); then
    fail "stopped update all infrastructure failure unexpectedly succeeded"
fi
assert_file_value "v-test-old"
restore_count="$(grep -c '^v-test-old:up -d --force-recreate$' "$CALL_LOG" || true)"
assert_equal "0" "$restore_count" \
    "stopped update all infrastructure-failure recovery count"

# The nested application update must likewise preserve a stopped state both
# before and after candidate containers may have been created.
do_update_infra() { return 0; }
for failure_stage in migration backend_health; do
    APP_RUNNING=0
    FAIL_STAGE="$failure_stage"
    : > "$CALL_LOG"
    if (do_update_all "v-test-next"); then
        fail "stopped update all $failure_stage failure unexpectedly succeeded"
    fi
    assert_file_value "v-test-old"
    restore_count="$(grep -c '^v-test-old:up -d --force-recreate$' "$CALL_LOG" || true)"
    assert_equal "0" "$restore_count" \
        "stopped update all old-release start count after $failure_stage"
    candidate_down_count="$(grep -c '^v-test-next:down$' "$CALL_LOG" || true)"
    if [ "$failure_stage" = "migration" ]; then
        assert_equal "0" "$candidate_down_count" \
            "stopped update all pre-cutover cleanup count"
    else
        assert_equal "1" "$candidate_down_count" \
            "stopped update all candidate cleanup count"
    fi
done

# A failed first install has no old release to start and must remove candidate
# containers. A successful explicit first install may then establish the pin.
rm -f "$RELEASE_VERSION_FILE"
CONTROL_PINNED_RELEASE_VERSION=""
clear_explicit_versions
APP_RUNNING=0
FAIL_STAGE="backend_health"
: > "$CALL_LOG"
if (do_update_all "v-test-first"); then
    fail "failed first install unexpectedly succeeded"
fi
[ ! -e "$RELEASE_VERSION_FILE" ] \
    || fail "failed first install unexpectedly persisted a release pin"
first_install_down_count="$(
    grep -c '^v-test-first:down$' "$CALL_LOG" || true
)"
assert_equal "1" "$first_install_down_count" \
    "failed first-install candidate cleanup count"
first_install_up_count="$(
    grep -c '^v-test-first:up -d --force-recreate$' "$CALL_LOG" || true
)"
assert_equal "1" "$first_install_up_count" \
    "failed first-install candidate start count"

APP_RUNNING=0
FAIL_STAGE=""
if ! (do_update_all "v-test-first"); then
    fail "explicit first install failed"
fi
assert_file_value "v-test-first"

# The public command parser accepts only the explicit trailing --preloaded flag.
APP_RUNNING=0
FAIL_STAGE=""
MISSING_PRELOADED_IMAGE=""
: > "$CALL_LOG"
if ! (main update app "v-test-cli-preloaded" --preloaded); then
    fail "control CLI rejected the documented --preloaded form"
fi
assert_file_value "v-test-cli-preloaded"
cli_pull_count="$(
    grep -c '^v-test-cli-preloaded:pull ' "$CALL_LOG" || true
)"
assert_equal "0" "$cli_pull_count" "CLI preloaded registry pull count"
if (main update app "v-test-invalid-option" --unknown) >/dev/null 2>&1; then
    fail "control CLI accepted an unknown update app option"
fi
if (main update all "v-test-invalid-option" --preloaded) >/dev/null 2>&1; then
    fail "control CLI silently accepted --preloaded for update all"
fi

echo "control release pin tests passed"
