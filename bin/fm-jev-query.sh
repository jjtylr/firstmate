#!/usr/bin/env bash
# fm-jev-query.sh - internal bounded typed-request transport.
# Usage: fm-jev-query.sh < request.json
# Reads {state,questions}, supplies the dispatch-selected model, and prints
# {response,latency_ms} or {skipped,latency_ms}. No provider error body is
# relayed. One POST, at most 3 seconds; callers must also bound credential
# resolution and the whole process. Shared dispatch configuration and the
# dispatch-never-send list apply unchanged. Does not store request/response.
set -u
case ${BASH_SOURCE[0]} in
  */*) SCRIPT_DIR=${BASH_SOURCE[0]%/*} ;;
  *) SCRIPT_DIR=. ;;
esac
# shellcheck source=bin/fm-jev-client-lib.sh
. "$SCRIPT_DIR/fm-jev-client-lib.sh"
SCRIPT_DIR="$(cd "$SCRIPT_DIR" && pwd)"
FM_HOME=${FM_HOME:-$(cd "$SCRIPT_DIR/.." && pwd)}
CONFIG=${FM_CONFIG_OVERRIDE:-$FM_HOME/config}
# shellcheck source=bin/fm-env-lib.sh
. "$SCRIPT_DIR/fm-env-lib.sh"
# shellcheck source=bin/fm-timing-lib.sh
. "$SCRIPT_DIR/fm-timing-lib.sh"
# shellcheck source=bin/fm-credential-source-lib.sh
. "$SCRIPT_DIR/fm-credential-source-lib.sh"
LAT_MS=null
# Do not echo arbitrary configuration or upstream values: they may be secret.
skip() { printf '{"skipped":"Jev unavailable or configuration withheld request","latency_ms":%s}\n' "$LAT_MS"; exit 0; }
die() { skip; }
emit_error() { skip; }
jev_off() { skip; }
never_send_off() { skip; }
command -v jq >/dev/null 2>&1 || skip
fm_jev_configure
command -v curl >/dev/null 2>&1 || skip
TMP=$(umask 077; mktemp -d) || skip
trap 'rm -rf "$TMP"' EXIT
RESP_FILE=$TMP/response
SEND_TEXT=$TMP/send
NEVER_SEND_PATH=$CONFIG/dispatch-never-send
BODY=$(jq --arg model "$DISPATCH_MODEL" '. + {model:$model}') || skip
if [ "$DISPATCH_PROVIDER" = openai ]; then
  BODY=$(jq -c '{model,input:(.state|tojson),questions:[.questions|to_entries[]|
    {type:"choice",name:.key,instructions:.value.instructions,
     choices:[.value.criteria|to_entries[]|{value:.key,description:.value}]}]}' <<<"$BODY") || skip
fi
never_send_check
TIMEOUT=3
fm_jev_post
if [ "$HTTP" != 200 ]; then
  printf '{"skipped":"Jev HTTP %s","latency_ms":%s}\n' "$HTTP" "$LAT_MS"
  exit 0
fi
if [ "$DISPATCH_PROVIDER" = openai ]; then
  jq -e '(.answers|type)=="array" and
    ([.answers[].name]|length)==([.answers[].name]|unique|length) and
    all(.answers[]; .type=="choice" and (.probabilities|type)=="array" and
      ([.probabilities[].value]|length)==([.probabilities[].value]|unique|length))' "$RESP_FILE" >/dev/null 2>&1 || skip
  jq '{answers:(.answers|map({key:.name,value:{choice,confidence,
    probabilities:(.probabilities|map({key:.value,value:.probability})|from_entries)}})|from_entries)}' "$RESP_FILE" > "$TMP/mapped" 2>/dev/null || skip
  mv "$TMP/mapped" "$RESP_FILE" || skip
fi
jq -n --argjson latency "$LAT_MS" --slurpfile response "$RESP_FILE" \
  '{response:$response[0],latency_ms:$latency}' 2>/dev/null || skip
