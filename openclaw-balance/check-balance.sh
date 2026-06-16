#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${ENV_FILE:-$SCRIPT_DIR/.env}"

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
USER_ID="${HYPERAPI_USER_ID:-${NEW_API_USER:-}}"
ACCESS_TOKEN="${HYPERAPI_ACCESS_TOKEN:-${ACCESS_TOKEN:-}}"
AUTHORIZATION="${HYPERAPI_AUTHORIZATION:-${AUTHORIZATION:-}}"
COOKIE="${HYPERAPI_COOKIE:-${COOKIE:-}}"
INCLUDE_ALL="${HYPERAPI_INCLUDE_ALL_SUBSCRIPTIONS:-true}"
HIDE_EXHAUSTED="${HYPERAPI_HIDE_EXHAUSTED:-false}"
TIMEZONE="${HYPERAPI_TIMEZONE:-Asia/Shanghai}"
FORMAT="json"

usage() {
  cat <<'EOF'
Usage:
  ./check-balance.sh [--format json|text|compact]

Environment:
  ENV_FILE                         Optional env file path. Default: ./openclaw-balance/.env
  HYPERAPI_BASE_URL                Default: https://hyperapi.cc
  HYPERAPI_USER_ID                 Required for token/header mode
  HYPERAPI_ACCESS_TOKEN            Recommended for OpenClaw
  HYPERAPI_AUTHORIZATION           Optional explicit Authorization header value
  HYPERAPI_COOKIE                  Optional browser cookie fallback
  HYPERAPI_USERNAME                Optional login fallback
  HYPERAPI_PASSWORD                Optional login fallback
  HYPERAPI_2FA_CODE                Optional 2FA code for login fallback
  HYPERAPI_TURNSTILE_TOKEN         Optional Turnstile token for login fallback
  HYPERAPI_INCLUDE_ALL_SUBSCRIPTIONS true|false, default true
  HYPERAPI_HIDE_EXHAUSTED          true|false, default false
  HYPERAPI_TIMEZONE                Default Asia/Shanghai
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --format)
      if [[ -z "${2:-}" ]]; then
        echo "Error: --format requires json, text, or compact." >&2
        exit 1
      fi
      FORMAT="${2:-}"
      shift 2
      ;;
    --format=*)
      FORMAT="${1#*=}"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Error: unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

case "$FORMAT" in
  json|text|compact) ;;
  *)
    echo "Error: --format must be json, text, or compact." >&2
    exit 1
    ;;
esac

if ! command -v jq >/dev/null 2>&1; then
  echo "Error: jq is required." >&2
  exit 1
fi

if ! command -v curl >/dev/null 2>&1; then
  echo "Error: curl is required." >&2
  exit 1
fi

BASE_URL="${BASE_URL%/}"
TMP_DIR="$(mktemp -d)"
COOKIE_JAR="$TMP_DIR/cookies.txt"
trap 'rm -rf "$TMP_DIR"' EXIT

if [[ -z "$AUTHORIZATION" && -n "$ACCESS_TOKEN" ]]; then
  AUTHORIZATION="$ACCESS_TOKEN"
fi

request_json() {
  local method="$1"
  local path="$2"
  local out="$3"
  local body="${4:-}"
  local request_user_id
  local status
  if [[ $# -ge 5 ]]; then
    request_user_id="$5"
  else
    request_user_id="$USER_ID"
  fi
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

  if [[ -n "$request_user_id" ]]; then
    headers+=(-H "new-api-user: $request_user_id")
  fi

  if [[ -n "$AUTHORIZATION" ]]; then
    headers+=(-H "authorization: $AUTHORIZATION")
  fi

  if [[ -n "$COOKIE" ]]; then
    headers+=(-H "cookie: $COOKIE")
  fi

  for attempt in 1 2; do
    if [[ "$method" == "POST" ]]; then
      status="$(curl -sS \
        -X POST "$BASE_URL$path" \
        -b "$COOKIE_JAR" -c "$COOKIE_JAR" \
        "${headers[@]}" \
        -H "content-type: application/json" \
        --data "$body" \
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

login_if_needed() {
  if [[ -n "$AUTHORIZATION" || -n "$COOKIE" ]]; then
    if [[ -z "$USER_ID" ]]; then
      echo "Error: HYPERAPI_USER_ID is required when using token/header mode." >&2
      exit 1
    fi
    return
  fi

  if [[ -z "$USERNAME" || -z "$PASSWORD" ]]; then
    echo "Error: provide HYPERAPI_ACCESS_TOKEN + HYPERAPI_USER_ID, or HYPERAPI_USERNAME + HYPERAPI_PASSWORD." >&2
    exit 1
  fi

  local login_json="$TMP_DIR/login.json"
  local login_path="/api/user/login"
  local login_payload
  if [[ -n "$TURNSTILE_TOKEN" ]]; then
    login_path="/api/user/login?turnstile=$TURNSTILE_TOKEN"
  fi

  login_payload="$(jq -n --arg username "$USERNAME" --arg password "$PASSWORD" '{username: $username, password: $password}')"
  request_json POST "$login_path" "$login_json" "$login_payload" ""

  if [[ "$(jq -r '.success // false' "$login_json")" != "true" ]]; then
    echo "Login failed: $(jq -r '.message // "unknown error"' "$login_json")" >&2
    exit 1
  fi

  if [[ "$(jq -r '.data.require_2fa // false' "$login_json")" == "true" ]]; then
    if [[ -z "$TWO_FA_CODE" ]]; then
      echo "Login requires 2FA. Set HYPERAPI_2FA_CODE and retry." >&2
      exit 1
    fi
    local two_fa_payload
    two_fa_payload="$(jq -n --arg code "$TWO_FA_CODE" '{code: $code}')"
    request_json POST "/api/user/login/2fa" "$login_json" "$two_fa_payload" ""
    if [[ "$(jq -r '.success // false' "$login_json")" != "true" ]]; then
      echo "2FA failed: $(jq -r '.message // "unknown error"' "$login_json")" >&2
      exit 1
    fi
  fi

  USER_ID="$(jq -r '.data.id // empty' "$login_json")"
  if [[ -z "$USER_ID" ]]; then
    echo "Error: login succeeded but user id was not returned." >&2
    exit 1
  fi
}

login_if_needed

SELF_JSON="$TMP_DIR/user-self.json"
SUBS_JSON="$TMP_DIR/subscription-self.json"
PLANS_JSON="$TMP_DIR/subscription-plans.json"

request_json GET "/api/user/self" "$SELF_JSON"
request_json GET "/api/subscription/self" "$SUBS_JSON"
request_json GET "/api/subscription/plans" "$PLANS_JSON"

JQ_FILTER='
  def cents($v):
    if ($v | type) != "number" then null
    else
      (($v / 5000 + 0.5) | floor) as $c
      | if $v > 0 and $c == 0 then 1 else $c end
    end;

  def money($v):
    cents($v) as $c
    | if $c == null then null
      else
        ($c / 100 | floor | tostring) as $d
        | ($c % 100 | tostring) as $cent
        | "$" + $d + "." + (if ($cent | length) == 1 then "0" + $cent else $cent end)
      end;

  def percent($used; $total):
    if ($total // 0) <= 0 then 0
    else (((($used / $total) * 100) + 0.5) | floor)
    end;

  def time_text($ts):
    if ($ts // 0) > 0 then ($ts | strflocaltime("%Y-%m-%d %H:%M:%S")) else null end;

  def days_left($end):
    if ($end // 0) > 0 then
      ((($end - now) / 86400) | ceil) as $days
      | if $days < 0 then 0 else $days end
    else null end;

  ($self[0].data) as $u
  | ($subs[0].data.subscriptions // [] | map(.subscription)) as $current
  | ($subs[0].data.all_subscriptions // [] | map(.subscription)) as $all
  | ($plans[0].data // [] | map(.plan) | map({key: (.id | tostring), value: .title}) | from_entries) as $titles
  | (if $includeAll == "true" then $all else $current end) as $items
  | ($items
      | map(select(if $hideExhausted == "true" then ((.amount_total - .amount_used) > 0) else true end))
      | sort_by(.id)
      | reverse
      | map(
          (.amount_total - .amount_used) as $remaining
          | (if $remaining < 0 then 0 else $remaining end) as $remainingClamped
          | percent(.amount_used; .amount_total) as $usedPercent
          | {
              id,
              planId: .plan_id,
              title: ($titles[(.plan_id | tostring)] // ("订阅 #" + (.id | tostring))),
              status,
              daysLeft: days_left(.end_time),
              endTime: time_text(.end_time),
              nextResetTime: time_text(.next_reset_time),
              amount: {
                usedRaw: .amount_used,
                totalRaw: .amount_total,
                remainingRaw: $remainingClamped,
                used: money(.amount_used),
                total: money(.amount_total),
                remaining: money($remainingClamped),
                usedPercent: $usedPercent,
                remainingPercent: (if (100 - $usedPercent) < 0 then 0 else (100 - $usedPercent) end)
              }
            }
        )) as $subscriptions
  | {
      ok: true,
      fetchedAt: $fetchedAt,
      baseUrl: $baseUrl,
      account: {
        userId: $userId,
        group: $u.group,
        status: $u.status,
        quotaRaw: $u.quota,
        usedQuotaRaw: $u.used_quota,
        currentBalance: money($u.quota),
        historicalUsage: money($u.used_quota),
        requestCount: ($u.request_count // 0)
      },
      subscriptionsSummary: {
        selected: ($subscriptions | length),
        current: ($current | length),
        all: ($all | length),
        active: ($all | map(select(.status == "active")) | length),
        expired: ($all | map(select(.status == "expired")) | length),
        cancelled: ($all | map(select(.status == "cancelled")) | length)
      },
      subscriptions: $subscriptions
    }
'

RESULT_JSON="$TMP_DIR/result.json"
TZ="$TIMEZONE" jq -n \
  --slurpfile self "$SELF_JSON" \
  --slurpfile subs "$SUBS_JSON" \
  --slurpfile plans "$PLANS_JSON" \
  --arg includeAll "$INCLUDE_ALL" \
  --arg hideExhausted "$HIDE_EXHAUSTED" \
  --arg fetchedAt "$(TZ="$TIMEZONE" date '+%Y-%m-%d %H:%M:%S %Z')" \
  --arg baseUrl "$BASE_URL" \
  --arg userId "$USER_ID" \
  "$JQ_FILTER" > "$RESULT_JSON"

case "$FORMAT" in
  json)
    jq . "$RESULT_JSON"
    ;;
  compact)
    jq '{
      ok,
      fetchedAt,
      currentBalance: .account.currentBalance,
      historicalUsage: .account.historicalUsage,
      requestCount: .account.requestCount,
      subscriptions: [
        .subscriptions[]
        | {
            id,
            title,
            status,
            remaining: .amount.remaining,
            remainingPercent: .amount.remainingPercent,
            endTime
          }
      ]
    }' "$RESULT_JSON"
    ;;
  text)
    jq -r '
      "账户统计",
      ("当前余额: " + (.account.currentBalance // "N/A")),
      ("历史消耗: " + (.account.historicalUsage // "N/A")),
      ("请求次数: " + (.account.requestCount | tostring)),
      "",
      "我的订阅",
      (
        .subscriptions[]
        | .title + (if (.title | startswith("订阅 #")) then "" else " · 订阅 #" + (.id | tostring) end) + "\n"
          + "状态: " + (.status // "unknown") + "\n"
          + (if .daysLeft != null then "剩余: " + (.daysLeft | tostring) + " 天\n" else "" end)
          + (if .endTime != null then "至: " + .endTime + "\n" else "" end)
          + (if .nextResetTime != null then "下一次重置: " + .nextResetTime + "\n" else "" end)
          + "总额度: " + (.amount.used // "N/A") + "/" + (.amount.total // "N/A")
          + " · 剩余 " + (.amount.remaining // "N/A")
          + " · 已用 " + (.amount.usedPercent | tostring) + "%\n"
      )
    ' "$RESULT_JSON"
    ;;
esac
