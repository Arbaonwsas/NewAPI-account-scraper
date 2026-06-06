#!/usr/bin/env bash
set -euo pipefail

ENV_FILE="${ENV_FILE:-.env}"
if [[ -f "$ENV_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
fi

BASE_URL="${HYPERAPI_BASE_URL:-https://hyperapi.cc}"
USERNAME="${HYPERAPI_USERNAME:-}"
PASSWORD="${HYPERAPI_PASSWORD:-}"
TWO_FA_CODE="${HYPERAPI_2FA_CODE:-}"
TURNSTILE_TOKEN="${HYPERAPI_TURNSTILE_TOKEN:-}"
KEYCHAIN_SERVICE="${HYPERAPI_KEYCHAIN_SERVICE:-newapi-account-scraper.hyperapi}"

if ! command -v jq >/dev/null 2>&1; then
  echo "Error: jq is required." >&2
  exit 1
fi

if ! command -v curl >/dev/null 2>&1; then
  echo "Error: curl is required." >&2
  exit 1
fi

if ! command -v security >/dev/null 2>&1; then
  echo "Error: macOS security command is required for Keychain storage." >&2
  exit 1
fi

if [[ -z "$USERNAME" || -z "$PASSWORD" ]]; then
  echo "Error: HYPERAPI_USERNAME and HYPERAPI_PASSWORD are required." >&2
  echo "Copy .env.example to .env and fill them in." >&2
  exit 1
fi

BASE_URL="${BASE_URL%/}"
TMP_DIR="$(mktemp -d)"
COOKIE_JAR="$TMP_DIR/cookies.txt"
trap 'rm -rf "$TMP_DIR"' EXIT

api_request() {
  local method="$1"
  local path="$2"
  local out="$3"
  local data="${4:-}"
  local user_id="${5:-}"
  local status
  local headers=(
    -H "accept: application/json, text/plain, */*"
    -H "accept-language: zh-CN,zh;q=0.9,en;q=0.8"
    -H "cache-control: no-store"
    -H "pragma: no-cache"
    -H "referer: $BASE_URL/console/topup"
    -H "sec-fetch-dest: empty"
    -H "sec-fetch-mode: cors"
    -H "sec-fetch-site: same-origin"
    -H "user-agent: Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36"
  )

  if [[ -n "$user_id" ]]; then
    headers+=(-H "new-api-user: $user_id")
  fi

  for attempt in 1 2; do
    if [[ "$method" == "POST" ]]; then
      status="$(curl -sS \
        -X POST "$BASE_URL$path" \
        -b "$COOKIE_JAR" -c "$COOKIE_JAR" \
        "${headers[@]}" \
        -H "content-type: application/json" \
        --data "$data" \
        -o "$out" \
        -w "%{http_code}")" && break
    else
      status="$(curl -sS \
        -X GET "$BASE_URL$path" \
        -b "$COOKIE_JAR" -c "$COOKIE_JAR" \
        "${headers[@]}" \
        -o "$out" \
        -w "%{http_code}")" && break
    fi

    if [[ "$attempt" == "2" ]]; then
      echo "Error: $method $path failed before receiving an HTTP response." >&2
      exit 1
    fi
    sleep 1
  done

  if [[ "$status" -lt 200 || "$status" -ge 300 ]]; then
    echo "Error: $method $path returned HTTP $status" >&2
    jq -r '.message? // empty' "$out" 2>/dev/null >&2 || true
    exit 1
  fi

  jq empty "$out" >/dev/null
}

upsert_env_var() {
  local key="$1"
  local value="$2"
  local tmp

  touch "$ENV_FILE"
  tmp="$(mktemp)"
  if grep -qE "^#?${key}=" "$ENV_FILE"; then
    awk -v key="$key" -v value="$value" '
      BEGIN { replaced = 0 }
      $0 ~ "^#?" key "=" {
        print key "=" value
        replaced = 1
        next
      }
      { print }
      END {
        if (replaced == 0) {
          print key "=" value
        }
      }
    ' "$ENV_FILE" > "$tmp"
  else
    cp "$ENV_FILE" "$tmp"
    printf '\n%s=%s\n' "$key" "$value" >> "$tmp"
  fi
  mv "$tmp" "$ENV_FILE"
}

LOGIN_JSON="$TMP_DIR/login.json"
TOKEN_JSON="$TMP_DIR/token.json"

echo "Logging in to $BASE_URL as <redacted>..."

login_path="/api/user/login"
if [[ -n "$TURNSTILE_TOKEN" ]]; then
  login_path="/api/user/login?turnstile=$TURNSTILE_TOKEN"
fi

login_payload="$(jq -n --arg username "$USERNAME" --arg password "$PASSWORD" '{username: $username, password: $password}')"
api_request POST "$login_path" "$LOGIN_JSON" "$login_payload"

if [[ "$(jq -r '.success // false' "$LOGIN_JSON")" != "true" ]]; then
  echo "Login failed: $(jq -r '.message // "unknown error"' "$LOGIN_JSON")" >&2
  exit 1
fi

if [[ "$(jq -r '.data.require_2fa // false' "$LOGIN_JSON")" == "true" ]]; then
  if [[ -z "$TWO_FA_CODE" ]]; then
    echo "Login requires 2FA. Set HYPERAPI_2FA_CODE in .env or run once with HYPERAPI_2FA_CODE=123456." >&2
    exit 1
  fi
  two_fa_payload="$(jq -n --arg code "$TWO_FA_CODE" '{code: $code}')"
  api_request POST "/api/user/login/2fa" "$LOGIN_JSON" "$two_fa_payload"
  if [[ "$(jq -r '.success // false' "$LOGIN_JSON")" != "true" ]]; then
    echo "2FA failed: $(jq -r '.message // "unknown error"' "$LOGIN_JSON")" >&2
    exit 1
  fi
fi

USER_ID="$(jq -r '.data.id // empty' "$LOGIN_JSON")"
if [[ -z "$USER_ID" ]]; then
  echo "Error: login succeeded but user id was not returned." >&2
  exit 1
fi

echo "Generating system access token for user <redacted>..."
api_request GET "/api/user/token" "$TOKEN_JSON" "" "$USER_ID"

if [[ "$(jq -r '.success // false' "$TOKEN_JSON")" != "true" ]]; then
  echo "Token generation failed: $(jq -r '.message // "unknown error"' "$TOKEN_JSON")" >&2
  exit 1
fi

ACCESS_TOKEN="$(jq -r '.data // empty' "$TOKEN_JSON")"
if [[ -z "$ACCESS_TOKEN" ]]; then
  echo "Error: token response did not contain data." >&2
  exit 1
fi

KEYCHAIN_ACCOUNT="${HYPERAPI_KEYCHAIN_ACCOUNT:-$BASE_URL:$USER_ID}"
security add-generic-password \
  -a "$KEYCHAIN_ACCOUNT" \
  -s "$KEYCHAIN_SERVICE" \
  -w "$ACCESS_TOKEN" \
  -U >/dev/null

upsert_env_var "HYPERAPI_USER_ID" "$USER_ID"

echo "Saved access token to macOS Keychain."
echo "Keychain service: $KEYCHAIN_SERVICE"
echo "Keychain account: <redacted>"
echo "Updated $ENV_FILE with HYPERAPI_USER_ID."
echo "Next fetch can use ./scripts/fetch-hyperapi-token.sh without logging in."
