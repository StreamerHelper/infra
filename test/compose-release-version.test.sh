#!/bin/bash

set -euo pipefail

INFRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPOSE_APP="$INFRA_DIR/docker-compose.app.yml"
COMPOSE_DEV="$INFRA_DIR/docker-compose.dev.yml"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
EMPTY_ENV="$TEST_DIR/empty.env"
: > "$EMPTY_ENV"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

for required_variable in \
    BACKEND_VERSION \
    FRONTEND_VERSION \
    BROWSER_VERSION \
    DOUYIN_RESOLVER_VERSION; do
    if (
        export BACKEND_VERSION=v-test
        export FRONTEND_VERSION=v-test
        export BROWSER_VERSION=v-test
        export DOUYIN_RESOLVER_VERSION=v-test
        unset "$required_variable"
        docker compose --env-file "$EMPTY_ENV" -f "$COMPOSE_APP" config --quiet
    ) >"$TEST_DIR/missing-${required_variable}.log" 2>&1; then
        fail "application Compose config accepted missing ${required_variable}"
    fi
    grep -q "${required_variable} is required" \
        "$TEST_DIR/missing-${required_variable}.log" \
        || fail "missing-version failure did not identify ${required_variable}"
done

production_images="$(
    BACKEND_VERSION=v-test \
    FRONTEND_VERSION=v-test \
    BROWSER_VERSION=v-test \
    DOUYIN_RESOLVER_VERSION=v-test \
        docker compose --env-file "$EMPTY_ENV" -f "$COMPOSE_APP" config --images
)"
for component in backend frontend browser douyin-resolver; do
    grep -qx "ghcr.io/streamerhelper/streamerhelper-${component}:v-test" \
        <<<"$production_images" \
        || fail "production Compose config did not pin ${component} to v-test"
done
if grep -q ':latest$' <<<"$production_images"; then
    fail "production Compose config rendered an application latest tag"
fi

BACKEND_VERSION=local \
FRONTEND_VERSION=local \
BROWSER_VERSION=local \
DOUYIN_RESOLVER_VERSION=local \
    docker compose --env-file "$EMPTY_ENV" -f "$COMPOSE_APP" -f "$COMPOSE_DEV" config --quiet

echo "compose release version tests passed"
