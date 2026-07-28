#!/bin/bash

set -euo pipefail

INFRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT

CONFIG_FILE="$TEST_DIR/settings.json"
cat > "$CONFIG_FILE" <<'EOF'
{
  "app": {
    "keys": "keep-app-keys"
  },
  "platforms": {
    "douyin": {
      "cookie": "legacy-secret-cookie",
      "userAgent": "keep-user-agent",
      "customField": "keep-custom-field"
    },
    "other": {
      "enabled": true
    }
  }
}
EOF
chmod 640 "$CONFIG_FILE"

upgrade_output="$(
    bash "$INFRA_DIR/bin/upgrade-config" "$CONFIG_FILE" 2>&1
)"

if grep -q 'legacy-secret-cookie' <<<"$upgrade_output"; then
    echo "FAIL: upgrade log exposed the deprecated cookie value" >&2
    exit 1
fi

jq -e '
    (.platforms.douyin | has("cookie") | not)
    and .platforms.douyin.userAgent == "keep-user-agent"
    and .platforms.douyin.customField == "keep-custom-field"
    and .platforms.other.enabled == true
    and .app.keys == "keep-app-keys"
' "$CONFIG_FILE" >/dev/null \
    || {
        echo "FAIL: config upgrade changed fields other than the deprecated cookie" >&2
        exit 1
    }

config_mode="$(stat -c '%a' "$CONFIG_FILE" 2>/dev/null || true)"
if [[ ! "$config_mode" =~ ^[0-7]{3,4}$ ]]; then
    config_mode="$(stat -f '%Lp' "$CONFIG_FILE")"
fi
[ "$config_mode" = "640" ] || {
    echo "FAIL: config permissions changed to $config_mode" >&2
    exit 1
}

before_hash="$(shasum -a 256 "$CONFIG_FILE" | awk '{print $1}')"
second_output="$(
    bash "$INFRA_DIR/bin/upgrade-config" "$CONFIG_FILE" 2>&1
)"
after_hash="$(shasum -a 256 "$CONFIG_FILE" | awk '{print $1}')"
[ -z "$second_output" ] || {
    echo "FAIL: idempotent upgrade unexpectedly logged a change" >&2
    exit 1
}
[ "$before_hash" = "$after_hash" ] || {
    echo "FAIL: idempotent upgrade rewrote the config" >&2
    exit 1
}

INVALID_CONFIG="$TEST_DIR/invalid.json"
printf '{"platforms":' > "$INVALID_CONFIG"
invalid_hash="$(shasum -a 256 "$INVALID_CONFIG" | awk '{print $1}')"
if bash "$INFRA_DIR/bin/upgrade-config" "$INVALID_CONFIG" >/dev/null 2>&1; then
    echo "FAIL: invalid JSON was accepted" >&2
    exit 1
fi
[ "$invalid_hash" = "$(shasum -a 256 "$INVALID_CONFIG" | awk '{print $1}')" ] || {
    echo "FAIL: invalid JSON was modified" >&2
    exit 1
}

CONTROL_CONFIG_DIR="$TEST_DIR/control"
mkdir -p "$CONTROL_CONFIG_DIR"
cat > "$CONTROL_CONFIG_DIR/settings.json" <<'EOF'
{
  "platforms": {
    "douyin": {
      "cookie": "control-secret-cookie",
      "userAgent": "control-user-agent"
    }
  }
}
EOF
control_output="$(
    STREAMER_HELPER_CONFIG_DIR="$CONTROL_CONFIG_DIR" \
        bash -c 'source "$1/bin/control"; check_config' -- "$INFRA_DIR" 2>&1
)"
if grep -q 'control-secret-cookie' <<<"$control_output"; then
    echo "FAIL: control config upgrade exposed the cookie value" >&2
    exit 1
fi
jq -e '
    (.platforms.douyin | has("cookie") | not)
    and .platforms.douyin.userAgent == "control-user-agent"
' "$CONTROL_CONFIG_DIR/settings.json" >/dev/null \
    || {
        echo "FAIL: control did not apply the config upgrade safely" >&2
        exit 1
    }

echo "config upgrade tests passed"
