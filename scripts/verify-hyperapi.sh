#!/usr/bin/env bash
set -euo pipefail

HAR_PATH="${HAR_PATH:-captures/hyperapi.cc.har}"
BASE_URL="${BASE_URL:-}"
NEW_API_USER="${NEW_API_USER:-}"
ACCESS_TOKEN="${ACCESS_TOKEN:-}"
AUTHORIZATION="${AUTHORIZATION:-}"
COOKIE="${COOKIE:-}"

if ! command -v jq >/dev/null 2>&1; then
  echo "Error: jq is required." >&2
  exit 1
fi

if ! command -v curl >/dev/null 2>&1; then
  echo "Error: curl is required." >&2
  exit 1
fi

if [[ -z "$BASE_URL" || -z "$NEW_API_USER" ]]; then
  if [[ ! -f "$HAR_PATH" ]]; then
    echo "Error: HAR not found at $HAR_PATH." >&2
    echo "Set BASE_URL and NEW_API_USER manually, or set HAR_PATH to a valid HAR file." >&2
    exit 1
  fi

  if [[ -z "$BASE_URL" ]]; then
    BASE_URL="$(jq -r '
      [.log.entries[].request.url
       | select(test("^https?://"))
       | capture("^(?<origin>https?://[^/]+)").origin][0] // empty
    ' "$HAR_PATH")"
  fi

  if [[ -z "$NEW_API_USER" ]]; then
    NEW_API_USER="$(jq -r '
      [.log.entries[].request.headers[]?
       | select((.name | ascii_downcase) == "new-api-user")
       | .value][0] // empty
    ' "$HAR_PATH")"
  fi

  if [[ -z "$AUTHORIZATION" ]]; then
    AUTHORIZATION="$(jq -r '
      [.log.entries[].request.headers[]?
       | select((.name | ascii_downcase) == "authorization")
       | .value][0] // empty
    ' "$HAR_PATH")"
  fi

  if [[ -z "$COOKIE" ]]; then
    COOKIE="$(jq -r '
      [.log.entries[].request.headers[]?
       | select((.name | ascii_downcase) == "cookie")
       | .value][0] // empty
    ' "$HAR_PATH")"
  fi
fi

if [[ -z "$AUTHORIZATION" && -n "$ACCESS_TOKEN" ]]; then
  AUTHORIZATION="$ACCESS_TOKEN"
fi

if [[ -z "$BASE_URL" ]]; then
  echo "Error: BASE_URL is empty." >&2
  exit 1
fi

if [[ -z "$NEW_API_USER" ]]; then
  echo "Error: NEW_API_USER is empty." >&2
  exit 1
fi

BASE_URL="${BASE_URL%/}"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

request_json() {
  local method="$1"
  local path="$2"
  local out="$3"
  local body="${4:-}"
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
    -H "new-api-user: $NEW_API_USER"
  )

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
        "${headers[@]}" \
        -H "content-type: application/json" \
        --data "$body" \
        -o "$out" \
        -w "%{http_code}")" && break
    else
      status="$(curl -sS \
        -X GET "$BASE_URL$path" \
        "${headers[@]}" \
        -o "$out" \
        -w "%{http_code}")" && break
    fi

    if [[ "$attempt" == "2" ]]; then
      echo "Error: $method $path failed before receiving an HTTP response." >&2
      return 1
    fi
    sleep 1
  done

  if [[ "$status" -lt 200 || "$status" -ge 300 ]]; then
    echo "Error: $method $path returned HTTP $status" >&2
    echo "Response body:" >&2
    jq -C . "$out" 2>/dev/null >&2 || sed -n '1,20p' "$out" >&2
    return 1
  fi

  jq empty "$out" >/dev/null
}

USER_SELF="$TMP_DIR/user-self.json"
SUB_SELF="$TMP_DIR/subscription-self.json"
PLANS="$TMP_DIR/subscription-plans.json"
AMOUNT="$TMP_DIR/user-amount.json"

echo "Verifying HyperAPI endpoints without browser..."
echo "Base URL: $BASE_URL"
echo "new-api-user: <redacted, length ${#NEW_API_USER}>"
if [[ -n "$AUTHORIZATION" ]]; then
  echo "authorization: <provided, length ${#AUTHORIZATION}>"
else
  echo "authorization: <not provided>"
fi
if [[ -n "$COOKIE" ]]; then
  echo "cookie: <provided, length ${#COOKIE}>"
else
  echo "cookie: <not provided>"
fi

request_json GET "/api/user/self" "$USER_SELF"
request_json GET "/api/subscription/self" "$SUB_SELF"
request_json GET "/api/subscription/plans" "$PLANS"

quota="$(jq -r '.data.quota // 0' "$USER_SELF")"
request_json POST "/api/user/amount" "$AMOUNT" "{\"amount\":$quota}"

TZ=Asia/Shanghai jq -n \
  --slurpfile user "$USER_SELF" \
  --slurpfile sub "$SUB_SELF" \
  --slurpfile plans "$PLANS" \
  --slurpfile amount "$AMOUNT" \
  --arg fetchedAt "$(TZ=Asia/Shanghai date '+%Y-%m-%d %H:%M:%S %Z')" '
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
    else (($used / $total) * 100)
    end;

  ($user[0].data) as $u
  | ($sub[0].data.subscriptions // [] | map(.subscription)) as $subs
  | ($sub[0].data.all_subscriptions // [] | map(.subscription)) as $allSubs
  | ($plans[0].data // [] | map(.plan) | map({key: (.id | tostring), value: .title}) | from_entries) as $titles
  | {
      fetchedAt: $fetchedAt,
      account: {
        currentBalance: money($u.quota),
        currentBalanceTextFromApi: ($amount[0].data // null),
        historicalUsage: money($u.used_quota),
        requestCount: $u.request_count,
        group: $u.group,
        status: $u.status
      },
      subscriptionsSummary: {
        current: ($subs | length),
        all: ($allSubs | length),
        active: ($allSubs | map(select(.status == "active")) | length),
        expired: ($allSubs | map(select(.status == "expired")) | length),
        cancelled: ($allSubs | map(select(.status == "cancelled")) | length)
      },
      currentSubscriptions: (
        $subs
        | sort_by(.end_time)
        | map({
            id,
            title: ($titles[(.plan_id | tostring)] // ("订阅 #" + (.id | tostring))),
            status,
            used: money(.amount_used),
            total: money(.amount_total),
            remaining: money(.amount_total - .amount_used),
            usedPercent: (percent(.amount_used; .amount_total) + 0.5 | floor),
            endTime: (.end_time | strflocaltime("%Y-%m-%d %H:%M:%S")),
            nextResetTime: (if (.next_reset_time // 0) > 0 then (.next_reset_time | strflocaltime("%Y-%m-%d %H:%M:%S")) else null end)
          })
      )
    }
'
