# shellcheck shell=bash
# Shared typed-request provider/key selection for dispatch and memory checks.
# Usage: source immediately (before children), then fm_jev_configure.
# Caller supplies FM_HOME, CONFIG and callbacks die, emit_error, jev_off.
# Configuration/credential precedence is owned by docs/configuration.md
# "Typed dispatch resolution". Keys stay unexported; POST reads its header
# through fd 3. fm_jev_post consumes BODY, RESP_FILE and TIMEOUT and sets HTTP
# and LAT_MS without printing provider error bodies or credentials.

TYPESAFE_API_KEY_PRIVATE=${TYPESAFE_API_KEY:-}
OPENROUTER_API_KEY_PRIVATE=${OPENROUTER_API_KEY:-}
OPENAI_API_KEY_PRIVATE=${OPENAI_API_KEY:-}
DISPATCH_API_KEY_PRIVATE=${FM_DISPATCH_API_KEY:-}
export -n TYPESAFE_API_KEY_PRIVATE OPENROUTER_API_KEY_PRIVATE OPENAI_API_KEY_PRIVATE DISPATCH_API_KEY_PRIVATE 2>/dev/null || true
unset TYPESAFE_API_KEY OPENROUTER_API_KEY OPENAI_API_KEY FM_DISPATCH_API_KEY

# Dependencies are sourced by the caller using its own SCRIPT_DIR.
fm_jev_declared_key() {
  local provider=$1 src problem value rc
  [ -e "$CRED_PATH" ] || [ -L "$CRED_PATH" ] || return 1
  [ -r "$CRED_PATH" ] || die "credential source declaration not readable: $CRED_PATH"
  command -v jq >/dev/null 2>&1 || die "jq required"
  problem=$(fm_credsrc_check "$CRED_PATH" typesafe openrouter) \
    || die "malformed credential source declaration: $CRED_PATH - $problem"
  fm_credsrc_declares "$CRED_PATH" "$provider" || return 1
  src=$(fm_credsrc_field "$CRED_PATH" "$provider" source)
  fm_credsrc_supported "$src" \
    || emit_error "credential source $src declared for $provider is not supported on this host; nothing sent"
  value=$(fm_credsrc_read "$CRED_PATH" "$provider"); rc=$?
  if [ "$rc" -ne 0 ] || [ -z "$value" ]; then
    if fm_timed_out "$rc"; then
      emit_error "credential source $src declared for $provider did not answer in time; nothing sent"
    fi
    emit_error "credential source $src declared for $provider is unavailable; nothing sent"
  fi
  printf -v "$2" '%s' "$value"
}

fm_jev_select_key() {
  local provider=$1 name=$2 var=$3
  [ -n "${!var}" ] || printf -v "$var" '%s' "$(fmx_env_get "$name" "$FM_HOME/.env")"
  [ -n "${!var}" ] || fm_jev_declared_key "$provider" "$var"
  [ -n "${!var}" ] || jev_off "$name absent from the environment and $FM_HOME/.env"
}

# Select and validate the same optional base for implicit and explicit TypeSafe.
# Never echo a rejected value: a misconfigured URL may contain credentials.
fm_jev_select_typesafe_base() {
  local base=${TYPESAFE_BASE:-}
  [ -n "$base" ] || base=$(fmx_env_get TYPESAFE_BASE "$FM_HOME/.env")
  [ -n "$base" ] || return 0
  command -v jq >/dev/null 2>&1 || die "jq required"
  jq -en --arg base "$base" '
    def ipv4:
      split(".") | length == 4 and all(.[];
        test("\\A(0|[1-9][0-9]{0,2})\\z") and (tonumber <= 255));
    def ipv6:
      # An IPv4 tail occupies two of the eight IPv6 groups.
      (if contains(".") then
        split(":") | if (.[-1] | ipv4) then .[-1] = "0:0" | join(":") else "!" end
       else . end) |
      split("::") as $sides |
      if ($sides | length) == 1 then
        test("\\A[0-9A-Fa-f]{1,4}(:[0-9A-Fa-f]{1,4}){7}\\z")
      elif ($sides | length) == 2 then
        all($sides[]; test("\\A([0-9A-Fa-f]{1,4}(:[0-9A-Fa-f]{1,4})*)?\\z")) and
        (split(":") | map(select(length > 0)) | length < 8)
      else false end;
    $base | capture("\\Ahttps?://(?<host>\\[[0-9A-Fa-f:.]+\\]|[A-Za-z0-9._-]+)(:(?<port>[0-9]+))?(?<path>/[^?#[:space:]\\\\]*)?\\z"; "i") |
    ((.path // "") | (contains("[") or contains("]")) | not) and
    (if .host | startswith("[") then .host[1:-1] | ipv6
     else true end) and
    (.port == null or (.port | tonumber | . >= 1 and . <= 65535))
  ' >/dev/null 2>&1 || die "TYPESAFE_BASE must be an http(s) URL with a host and no userinfo, query, fragment, whitespace, or brackets in its path"
  while [ "${base%/}" != "$base" ]; do base=${base%/}; done
  TS_BASE=$base
}

fm_jev_configure() {
  TS_BASE=https://api.typesafe.ai
  CRED_PATH="$CONFIG/dispatch-credential-sources.json"
  DISPATCH_PROVIDER=${FM_DISPATCH_PROVIDER:-}
  [ -n "$DISPATCH_PROVIDER" ] || DISPATCH_PROVIDER=$(fmx_env_get FM_DISPATCH_PROVIDER "$FM_HOME/.env")
  DISPATCH_MODEL=${FM_DISPATCH_MODEL:-}
  [ -n "$DISPATCH_MODEL" ] || DISPATCH_MODEL=$(fmx_env_get FM_DISPATCH_MODEL "$FM_HOME/.env")
  case "$DISPATCH_PROVIDER" in
    '')
      DISPATCH_PROVIDER=typesafe DISPATCH_MODEL=jev-latest
      fm_jev_select_typesafe_base
      fm_jev_select_key typesafe TYPESAFE_API_KEY TYPESAFE_API_KEY_PRIVATE ;;
    typesafe)
      [ -n "$DISPATCH_MODEL" ] || DISPATCH_MODEL=jev-latest
      fm_jev_select_typesafe_base
      fm_jev_select_key typesafe TYPESAFE_API_KEY TYPESAFE_API_KEY_PRIVATE ;;
    openrouter)
      [ -n "$DISPATCH_MODEL" ] || die "FM_DISPATCH_MODEL required when FM_DISPATCH_PROVIDER=openrouter"
      fm_jev_select_key openrouter OPENROUTER_API_KEY OPENROUTER_API_KEY_PRIVATE ;;
    systemone)
      [ -n "$DISPATCH_MODEL" ] || die "FM_DISPATCH_MODEL required when FM_DISPATCH_PROVIDER=systemone"
      DISPATCH_BASE_URL=${FM_DISPATCH_BASE_URL:-}
      [ -n "$DISPATCH_BASE_URL" ] || DISPATCH_BASE_URL=$(fmx_env_get FM_DISPATCH_BASE_URL "$FM_HOME/.env")
      [ -n "$DISPATCH_BASE_URL" ] || die "FM_DISPATCH_BASE_URL required when FM_DISPATCH_PROVIDER=systemone"
      case "$DISPATCH_BASE_URL" in
        http://?*|https://?*) ;;
        *) die "FM_DISPATCH_BASE_URL must start with http:// or https://" ;;
      esac
      DISPATCH_BASE_URL=${DISPATCH_BASE_URL%/}
      [ -n "$DISPATCH_API_KEY_PRIVATE" ] || DISPATCH_API_KEY_PRIVATE=$(fmx_env_get FM_DISPATCH_API_KEY "$FM_HOME/.env") ;;
    openai)
      [ -n "$DISPATCH_MODEL" ] || die "FM_DISPATCH_MODEL required when FM_DISPATCH_PROVIDER=openai"
      [ -n "$OPENAI_API_KEY_PRIVATE" ] || OPENAI_API_KEY_PRIVATE=$(fmx_env_get OPENAI_API_KEY "$FM_HOME/.env")
      [ -n "$OPENAI_API_KEY_PRIVATE" ] || jev_off "OPENAI_API_KEY absent from the environment and $FM_HOME/.env" ;;
    *) die "unknown FM_DISPATCH_PROVIDER: $DISPATCH_PROVIDER (expected typesafe, openrouter, systemone, or openai)" ;;
  esac
  case "$DISPATCH_PROVIDER" in
    typesafe) ENDPOINT=$TS_BASE/v1/systemone TIMEOUT=5 KEY_PRIVATE=$TYPESAFE_API_KEY_PRIVATE ;;
    openrouter) ENDPOINT=https://openrouter.ai/api/alpha/decisions TIMEOUT=10 KEY_PRIVATE=$OPENROUTER_API_KEY_PRIVATE ;;
    systemone) ENDPOINT=$DISPATCH_BASE_URL/v1/systemone TIMEOUT=10 KEY_PRIVATE=$DISPATCH_API_KEY_PRIVATE ;;
    openai) ENDPOINT=https://api.openai.com/v1/decisions TIMEOUT=10 KEY_PRIVATE=$OPENAI_API_KEY_PRIVATE ;;
  esac
  export -n KEY_PRIVATE 2>/dev/null || true
}

# Caller supplies SEND_TEXT scratch file, NEVER_SEND_PATH, and the terminating
# never_send_off callback. Check every final string, including serialized JSON.
never_send_check() {
  local list value n=0 rc
  [ -e "$NEVER_SEND_PATH" ] || [ -L "$NEVER_SEND_PATH" ] || return 0
  { [ -f "$NEVER_SEND_PATH" ] && [ -r "$NEVER_SEND_PATH" ]; } \
    || never_send_off "$NEVER_SEND_PATH is not a readable regular file"
  jq -r --arg endpoint "$ENDPOINT" '
    $endpoint, (.. | strings | ., (try (fromjson | .. | strings) catch empty))
    | gsub("\\s+"; " ")' <<<"$BODY" > "$SEND_TEXT" 2>/dev/null \
    || never_send_off "could not extract the request text to check"
  list=$(jq -Rr 'gsub("\\s+"; " ")' "$NEVER_SEND_PATH" 2>/dev/null) \
    || never_send_off "could not read $NEVER_SEND_PATH"
  while IFS= read -r value; do
    n=$((n + 1))
    value=${value# }
    value=${value% }
    case "$value" in ''|'#'*) continue ;; esac
    grep -qiF -e "$value" "$SEND_TEXT" 2>/dev/null; rc=$?
    case "$rc" in
      0) never_send_off "brief text matches $NEVER_SEND_PATH line $n" ;;
      1) ;;
      *) never_send_off "could not check the request text against $NEVER_SEND_PATH line $n" ;;
    esac
  done <<<"$list"
}

# shellcheck disable=SC2034 # HTTP and LAT_MS are public results read by callers.
fm_jev_post() {
  local t0 t1
  t0=$(fm_timing_now_ms)
  if [ -n "$KEY_PRIVATE" ]; then
    HTTP=$(printf '%s' "$BODY" | curl --globoff -sS --max-time "$TIMEOUT" -o "$RESP_FILE" -w '%{http_code}' \
      -X POST "$ENDPOINT" -H 'Content-Type: application/json' \
      -H @/dev/fd/3 3< <(printf 'Authorization: Bearer %s\n' "$KEY_PRIVATE") \
      --data-binary @- 2>/dev/null) || HTTP=000
  else
    HTTP=$(printf '%s' "$BODY" | curl --globoff -sS --max-time "$TIMEOUT" -o "$RESP_FILE" -w '%{http_code}' \
      -X POST "$ENDPOINT" -H 'Content-Type: application/json' \
      --data-binary @- 2>/dev/null) || HTTP=000
  fi
  t1=$(fm_timing_now_ms)
  LAT_MS=$((t1 - t0))
}
