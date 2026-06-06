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
HIDE_EXHAUSTED="${HYPERAPI_HIDE_EXHAUSTED:-false}"
INCLUDE_ALL="${HYPERAPI_INCLUDE_ALL_SUBSCRIPTIONS:-true}"

if ! command -v jq >/dev/null 2>&1; then
  echo "Error: jq is required." >&2
  exit 1
fi

if ! command -v curl >/dev/null 2>&1; then
  echo "Error: curl is required." >&2
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

  if [[ "$method" == "POST" ]]; then
    status="$(curl -sS \
      -X POST "$BASE_URL$path" \
      -b "$COOKIE_JAR" -c "$COOKIE_JAR" \
      "${headers[@]}" \
      -H "content-type: application/json" \
      --data "$data" \
      -o "$out" \
      -w "%{http_code}")"
  else
    status="$(curl -sS \
      -X GET "$BASE_URL$path" \
      -b "$COOKIE_JAR" -c "$COOKIE_JAR" \
      "${headers[@]}" \
      -o "$out" \
      -w "%{http_code}")"
  fi

  if [[ "$status" -lt 200 || "$status" -ge 300 ]]; then
    echo "Error: $method $path returned HTTP $status" >&2
    jq -r '.message? // empty' "$out" 2>/dev/null >&2 || true
    exit 1
  fi

  jq empty "$out" >/dev/null
}

LOGIN_JSON="$TMP_DIR/login.json"
SELF_JSON="$TMP_DIR/self.json"
SUBS_JSON="$TMP_DIR/subscriptions.json"
PLANS_JSON="$TMP_DIR/plans.json"

echo "Logging in to $BASE_URL as <redacted>..."

login_path="/api/user/login"
if [[ -n "$TURNSTILE_TOKEN" ]]; then
  login_path="/api/user/login?turnstile=$TURNSTILE_TOKEN"
fi

login_payload="$(jq -n --arg username "$USERNAME" --arg password "$PASSWORD" '{username: $username, password: $password}')"
api_request POST "$login_path" "$LOGIN_JSON" "$login_payload"

login_success="$(jq -r '.success // false' "$LOGIN_JSON")"
if [[ "$login_success" != "true" ]]; then
  echo "Login failed: $(jq -r '.message // "unknown error"' "$LOGIN_JSON")" >&2
  exit 1
fi

requires_2fa="$(jq -r '.data.require_2fa // false' "$LOGIN_JSON")"
if [[ "$requires_2fa" == "true" ]]; then
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

api_request GET "/api/user/self" "$SELF_JSON" "" "$USER_ID"
api_request GET "/api/subscription/self" "$SUBS_JSON" "" "$USER_ID"
api_request GET "/api/subscription/plans" "$PLANS_JSON" "" "$USER_ID"

TZ=Asia/Shanghai jq -n -r \
  --slurpfile self "$SELF_JSON" \
  --slurpfile subs "$SUBS_JSON" \
  --slurpfile plans "$PLANS_JSON" \
  --arg includeAll "$INCLUDE_ALL" \
  --arg hideExhausted "$HIDE_EXHAUSTED" '
  def cents($v):
    if ($v | type) != "number" then null
    else
      (($v / 5000 + 0.5) | floor) as $c
      | if $v > 0 and $c == 0 then 1 else $c end
    end;

  def money($v):
    cents($v) as $c
    | if $c == null then "N/A"
      else
        ($c / 100 | floor | tostring) as $d
        | ($c % 100 | tostring) as $cent
        | "$" + $d + "." + (if ($cent | length) == 1 then "0" + $cent else $cent end)
      end;

  def percent($used; $total):
    if ($total // 0) <= 0 then 0
    else (((($used / $total) * 100) + 0.5) | floor)
    end;

  def days_left($end):
    ((($end - now) / 86400) | ceil);

  def time_text($ts):
    ($ts | strflocaltime("%Y/%-m/%-d %H:%M:%S"));

  ($self[0].data) as $u
  | ($subs[0].data.subscriptions // [] | map(.subscription)) as $current
  | ($subs[0].data.all_subscriptions // [] | map(.subscription)) as $all
  | ($plans[0].data // [] | map(.plan) | map({key: (.id | tostring), value: .title}) | from_entries) as $titles
  | (if $includeAll == "true" then $all else $current end) as $items
  | "账户统计",
    ("当前余额: " + money($u.quota)),
    ("历史消耗: " + money($u.used_quota)),
    ("请求次数: " + (($u.request_count // 0) | tostring)),
    "",
    "我的订阅",
    (
      $items
      | sort_by(.end_time)
      | reverse
      | map(select(if $hideExhausted == "true" then (.amount_used < .amount_total) else true end))
      | .[]
      | (.amount_total - .amount_used) as $remaining
      | percent(.amount_used; .amount_total) as $pct
      | ($titles[(.plan_id | tostring)] // null) as $title
      | (
          (if $title == null then "订阅 #" + (.id | tostring) else $title + " · 订阅 #" + (.id | tostring) end) + "\n" +
          (
            if .status == "active" then
              "剩余 " + (days_left(.end_time) | tostring) + " 天\n至 " + time_text(.end_time)
            elif .status == "cancelled" then
              "作废于 " + time_text(.end_time)
            else
              "过期于 " + time_text(.end_time)
            end
          ) +
          (if .status == "active" and (.next_reset_time // 0) > 0 then "\n下一次重置: " + time_text(.next_reset_time) else "" end) +
          "\n总额度: " + money(.amount_used) + "/" + money(.amount_total) + " · 剩余 " + money($remaining) + " 已用 " + ($pct | tostring) + "%\n"
        )
    )
'
