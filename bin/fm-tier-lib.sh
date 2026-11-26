# shellcheck shell=bash
# fm-tier-lib.sh - shared pieces of the worker tier table.
#
# docs/configuration.md "Worker tiers" owns the tier table's meaning, the
# checkable-failure line, and the step-up contract. This library owns only:
#
#   FM_TIER_ORDER                  the tier names, lowest first
#   FM_TIER_JQ                     jq defs, prepended to a program that reads
#                                  a crew-dispatch.json object:
#                                    fm_tier_err        structural error text, or empty
#                                    fm_tier_profiles   every tier profile
#                                    fm_tier_of($h; $m; $e)  the tier whose profile
#                                                       matches exactly, or null
#   fm_tier_checkable_failure      read text on stdin; print the first
#                                  checkable-failure line's kind (tests, check,
#                                  or runbook) and exit 0, or exit 1 when none
#
# The resolver and bootstrap add the tier profiles to their own existing
# harness, effort, and provider checks; fm_tier_err covers only what is
# particular to tiers, so neither validator carries a second copy of it.

# shellcheck disable=SC2034  # read by the sourcing consumers
FM_TIER_ORDER='light standard strong top'

# shellcheck disable=SC2016,SC2034  # jq program text, not shell expansion; read by the sourcing consumers
FM_TIER_JQ='
def fm_tier_names: ["light", "standard", "strong", "top"];
def fm_tier_as_list($v): if ($v | type) == "array" then $v elif ($v | type) == "object" then [$v] else [] end;
def fm_tier_profiles: [(.tiers // {}) | if type == "object" then .[] else empty end | objects | fm_tier_as_list(.use)[]];
def fm_tier_err:
  if has("tiers") | not then empty
  elif (.tiers | type) != "object" then "tiers must be an object keyed by tier name"
  elif any(.tiers | keys[]; IN(fm_tier_names[]) | not) then
    "unknown tier: " + ([.tiers | keys[] | select(IN(fm_tier_names[]) | not)] | join(", ")) + " (the tiers are light, standard, strong, and top)"
  elif (.tiers | has("standard") | not) then "tiers needs a standard tier, the tier for a job no rule matches"
  elif any(.tiers[]; type != "object") then "each tier must be an object"
  elif any(.tiers[]; (fm_tier_as_list(.use) | length) == 0) then "each tier needs a use profile object or a non-empty array of them"
  elif any(.tiers[] | fm_tier_as_list(.use)[]; type != "object" or (.harness | type) != "string" or (.harness | length) == 0) then "each tier profile needs harness"
  elif any(.tiers[] | fm_tier_as_list(.use)[];
      (.model | type) != "string" or (.model | length) == 0 or (.effort | type) != "string" or (.effort | length) == 0) then
    "each tier profile needs model and effort, so a running job'"'"'s tier can be read from its profile"
  elif any(.tiers[]; has("budget_minutes") and ((.budget_minutes | type) != "number" or .budget_minutes <= 0)) then
    "tier budget_minutes must be a positive number when present"
  elif (fm_tier_profiles | map([.harness, .model, .effort] | @json)) as $k | ($k | length) != ($k | unique | length) then
    "a tier profile (harness, model, and effort) may appear in one tier only"
  else empty end;
def fm_tier_of($h; $m; $e):
  [(.tiers // {}) | to_entries[] | select(any(fm_tier_as_list(.value.use)[]; .harness == $h and .model == $m and .effort == $e)) | .key] | first // null;
'

# The line firstmate writes in a brief's `## Firstmate spec` to say what would
# show the job failed: "Checkable failure: <tests|check|runbook>: <what>".
fm_tier_checkable_failure() {
  local line kind
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line#"${line%%[![:space:]]*}"}
    line=${line#- }
    case "$line" in
      'Checkable failure: '*) ;;
      *) continue ;;
    esac
    line=${line#Checkable failure: }
    kind=${line%%:*}
    case "$kind" in tests|check|runbook) ;; *) continue ;; esac
    line=${line#"$kind":}
    line=${line//[[:space:]]/}
    [ -n "$line" ] || continue
    printf '%s\n' "$kind"
    return 0
  done
  return 1
}
