# Shared helpers for the atlas scripts. Source this; do not run it.
# Targets bash 3.2 (macOS system bash) — no associative arrays, no mapfile.
#
# The one fact both scripts must agree on lives here: what the generated
# regions of index.md look like. render-index.sh writes them; check-atlas.sh
# recomputes them to spot a stale copy. Two implementations would drift, so
# there is one, and there is exactly one accepted form of each region.
#
# The claim language is here for the same reason: drill-down.sh evaluates an
# area's `Owns:` patterns, and every later reader of them must evaluate them the
# same way or the map would answer two different questions.
#
# The header grammar is here for the same reason again. The title check, the
# axis line, the two edge lines, the closed vocabulary, the understood-axis
# contradictions, and the edge target checks are functions that take an area
# file and the caller's vocabulary, so the repo checker and a fleet checker
# over another directory parse one grammar. The header checks section below
# states the reporting and result conventions. The table body takes its
# columns the same way, so one function renders both indexes.
#
# The fleet section holds what the fleet scripts read in common: the fleet
# table pair, the Repos line, the Sides bullet grammar, and the checkout
# arguments the gate and the queue both take.
#
# The area file name minus `.md` is the permanent key (skills/atlas/SCHEMA.md).
# Keys are the only pointer language: nothing here resolves a pointer by
# slugging it, and nothing resolves an area by its display title.

# Marker pairs. Each generated region sits between one pair in index.md.
# A marker is found by its prefix, and the checker compares only the region
# between a pair (SCHEMA.md), so the comment text after the name is free to
# differ. The two full lines are what render-index.sh inserts when the table
# pair is missing; a graph pair it never inserts.
ATLAS_TABLE_OPEN='<!-- atlas-table:begin'
ATLAS_TABLE_SHUT='<!-- atlas-table:end'
ATLAS_GRAPH_OPEN='<!-- atlas-graph:begin'
ATLAS_GRAPH_SHUT='<!-- atlas-graph:end'
ATLAS_TABLE_BEGIN="$ATLAS_TABLE_OPEN — generated from the area files; do not hand-edit -->"
ATLAS_TABLE_END="$ATLAS_TABLE_SHUT -->"

# There is deliberately no name-to-key function here. Minting a key happens
# once, when an atlas session first creates an area, and SCHEMA.md states the
# rule for the session that does it. A function on this side would only ever be
# reached by code trying to resolve a pointer, which is the thing the schema
# forbids.

# The area file whose header block is held, and the block itself. Declared
# here because every script that sources this library runs under `set -u`.
ATLAS_HB_FILE=""
ATLAS_HB_VALUE=""

# True when a string is already a well-formed key: lowercase letters, digits
# and hyphens, starting with a letter or digit. A pointer that fails this is
# spelled in some other language and check-atlas.sh reports it.
#
# The classes are spelled out, never `a-z`. A range in a bash pattern follows
# the caller's collation, and under a UTF-8 locale bash 3.2 puts `S` inside
# `a-z`, so `Storage` passed as a key (#257). An explicit list means the same
# thing in every locale.
atlas_is_key() { # atlas_is_key <string>
  case "$1" in
    ''|*[!abcdefghijklmnopqrstuvwxyz0123456789-]*) return 1 ;;
    [!abcdefghijklmnopqrstuvwxyz0123456789]*)      return 1 ;;
    *)                                              return 0 ;;
  esac
}

atlas_trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

# The area keys of an atlas directory, sorted. index is not an area.
atlas_keys() { # atlas_keys <atlas-dir>
  local f key
  for f in "$1"/*.md; do
    [ -f "$f" ] || continue
    key="${f##*/}"; key="${key%.md}"
    [ "$key" = "index" ] && continue
    printf '%s\n' "$key"
  done | LC_ALL=C sort
}

# The value of one machine-readable header line, trimmed. Prints nothing when
# the line is absent. The header block ends at the first `## ` heading, so a
# later line that looks like a header is not one.
atlas_header_value() { # atlas_header_value <area-file> <field>
  local raw= line
  atlas__load_header "$1"
  while IFS= read -r line; do
    case "$line" in "$2:"*) raw="$line"; break ;; esac
  done <<< "$ATLAS_HB_VALUE"
  [ -n "$raw" ] || return 0
  atlas_trim "${raw#*:}"
}

# The entries of one comma-separated header value, one per line, trimmed and
# verbatim. Prints nothing for an empty value or one holding only separators.
# Nothing here normalizes an entry, so a value written in some other language
# reaches the caller unchanged and is reported rather than guessed at. Every
# comma-separated field in the schema is split here: `Blocked-by:`,
# `Pending-on:`, and the claim lines below.
atlas_entries_of() { # atlas_entries_of <comma-separated value>
  local entry
  [ -n "$1" ] || return 0
  printf '%s\n' "$1" | tr ',' '\n' | while read -r entry; do
    entry="$(atlas_trim "$entry")"
    [ -n "$entry" ] || continue
    printf '%s\n' "$entry"
  done
}

# The Blocked-by entry list of an area file. Entries are keys. `Blocked-by:
# none` is the written form of an empty list and prints nothing.
atlas_edges_of() { # atlas_edges_of <area-file>
  local line
  line="$(atlas_header_value "$1" 'Blocked-by')"
  [ "$line" = "none" ] && return 0
  atlas_entries_of "$line"
}

# The Pending-on entry list of an area file: the areas whose open decisions
# this one waits on. Entries are keys. The line is optional, and an absent line
# prints nothing. There is no `none` form for this line (SCHEMA.md), so a `none`
# entry reaches the caller verbatim and check-atlas.sh reports it.
atlas_pending_of() { # atlas_pending_of <area-file>
  atlas_entries_of "$(atlas_header_value "$1" 'Pending-on')"
}

# The content of one `## <heading>` section, up to the next `## ` or the end of
# the file. Two readers ask this now — the checker, for the lists an axis is
# read off, and gap-queue.sh, for those and for the index's Fog bullets — so it
# is one function rather than two awk programs that would drift.
atlas_section() { # atlas_section <file> <heading>
  awk -v h="## $2" '
    $0 == h { on = 1; next }
    /^## /  { on = 0 }
    on { print }
  ' "$1" 2>/dev/null
}

# The current display title of an area file, read from its first `# ` heading.
# A file with no heading falls back to its key; check-atlas.sh reports the
# malformed heading separately, so the fallback never hides it.
atlas_title_of() { # atlas_title_of <area-file>
  local title base
  title="$(awk '/^# / { sub(/^# /, ""); print; exit }' "$1" 2>/dev/null)"
  title="$(atlas_trim "$title")"
  if [ -n "$title" ]; then
    printf '%s' "$title"
  else
    base="${1##*/}"
    printf '%s' "${base%.md}"
  fi
}

# --- claims ------------------------------------------------------------------

# The tracked files one area claims, one per line, relative to <root> — the
# same root every atlas script takes, the directory holding `docs/atlas/`. A
# claim is written against that root, so an atlas nested inside a larger
# repository claims `src/scrape`, never the path from git's top level down.
#
# `Owns:` is a comma-separated list of git pathspecs and **git does the
# matching**, so a pattern behaves here exactly as it behaves in every git
# command: a bare directory claims its whole subtree, and the exclude syntax is
# available. `git ls-files` reads the index, so only tracked files are seen and
# untracked scratch never matches. Git also sorts the result and prints a file
# matched by two of the area's own patterns once, so nothing here post-processes
# the list.
#
# Two settings the caller does not get to change. Both failures they prevent are
# silent: the answer comes back at exit 0, and it is wrong.
#
#   - The three GIT_ variables are unset, because `-C` does not override an
#     inherited GIT_DIR. A stray one answers about another repository, or
#     answers "this area owns nothing". test-lib.sh guards its scratch
#     repositories the same way, for the same reason.
#   - core.quotePath is off, so a path outside ASCII is printed as itself. Git's
#     default prints a C-escaped string in quotes that no later command opens.
#
# Prints nothing and exits 0 when the area carries no `Owns:` line, and when its
# claims match nothing — a claim in a repo with no code yet is an intention
# (SCHEMA.md), not a defect. A pathspec git refuses is git's message on stderr
# and git's exit code here; this function does not second-guess it.
atlas_claimed_files() { # atlas_claimed_files <root> <area-file>
  local root="$1" file="$2" entry
  local -a specs=()
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    specs[${#specs[@]}]="$entry"
  done < <(atlas_entries_of "$(atlas_header_value "$file" 'Owns')")
  [ "${#specs[@]}" -gt 0 ] || return 0
  (
    unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE
    git -C "$root" -c core.quotePath=false ls-files -- "${specs[@]}"
  )
}

# --- the header checks -------------------------------------------------------
# The grammar of an area file's header block, as functions a checker calls
# with its own vocabulary. check-atlas.sh calls them for docs/atlas/; a fleet
# checker calls the same functions over another directory with another set of
# keys. Two checkers of one grammar would drift, so the grammar lives here.
#
# Reporting. Every finding goes through atlas_drift, which prints one
# `DRIFT <class>: <message>` line on stdout and sets ATLAS_FAIL=1. A caller
# exits with $ATLAS_FAIL. A checker's own findings use the same reporter.
#
# Results. A check that a later check depends on hands its result back in a
# library variable, never on stdout, so a caller reads a variable after the
# call and stdout stays the DRIFT stream:
#
#   ATLAS_AXIS_VALUE   atlas_check_axis: the validated symbol, or empty when
#                      the line is malformed or the value is not one of the
#                      three. An empty value feeds no contradiction check, so
#                      one bad line cannot cascade into a second class.
#   ATLAS_EDGE_OK      atlas_check_edge_line: 1 when the line parsed and every
#                      entry is a well-formed key, else 0. Only a parsed line
#                      reaches the target checks, so one wrong pointer cannot
#                      print two lines in two classes.
#   ATLAS_EDGE_N       atlas_check_edge_line: the count of well-formed entries.
#
# Both edge variables are overwritten by the next atlas_check_edge_line call,
# so a caller that checks both edge lines copies the pair it needs to keep.
#
# The key an area is named by in a message is its file name minus `.md`, and
# every function derives it from the file it is given.

ATLAS_FAIL=0
ATLAS_AXIS_VALUE=
ATLAS_EDGE_OK=0
ATLAS_EDGE_N=0

atlas_drift() { # atlas_drift <class> <message>
  printf 'DRIFT %s: %s\n' "$1" "$2"
  ATLAS_FAIL=1
}

# The header block of an area file: every line before the first `## ` heading.
# Read once per file and held, because the checker asks seven times for the
# same block and an awk pass per ask was most of its running time. Only area
# files reach this — the index has its own header shape, read by
# atlas_check_index_header — and no script here rewrites an area file, so a
# held block cannot go stale inside one run.
atlas__load_header() { # atlas__load_header <area-file>
  [ "$1" = "$ATLAS_HB_FILE" ] && return 0
  ATLAS_HB_FILE="$1"
  ATLAS_HB_VALUE="$(awk '/^## / { exit } { print }' "$1" 2>/dev/null)"
}

atlas_header_block() { # atlas_header_block <area-file>
  atlas__load_header "$1"
  printf '%s\n' "$ATLAS_HB_VALUE"
}

# Space-separated words joined into one grep alternation: `a b` to `a|b`.
atlas_alternation() { # atlas_alternation <words>
  local w out=
  for w in $1; do out="$out|$w"; done
  printf '%s' "${out#|}"
}

# bad-vocabulary: exactly one `# Title` heading, and it opens the file.
atlas_check_title() { # atlas_check_title <area-file>
  local key header
  key="${1##*/}"; key="${key%.md}"
  header="$(atlas_header_block "$1")"
  if [ "$(printf '%s\n' "$header" | grep -c '^# ' || true)" -ne 1 ] \
    || ! printf '%s\n' "$header" | sed -n '1p' | grep -qE '^# [^[:space:]]'; then
    atlas_drift bad-vocabulary "$key.md: malformed title header"
  fi
}

# bad-vocabulary: one exact `<axis>:` line carrying one symbol from the
# schema. The result lands in ATLAS_AXIS_VALUE, empty on any finding.
atlas_check_axis() { # atlas_check_axis <area-file> <axis>
  local file="$1" axis="$2" key header lines count form value
  ATLAS_AXIS_VALUE=
  key="${file##*/}"; key="${key%.md}"
  header="$(atlas_header_block "$file")"
  lines="$(printf '%s\n' "$header" | grep "^$axis" || true)"
  count="$(printf '%s\n' "$lines" | grep -c . || true)"
  form="$(printf '%s\n' "$lines" | grep -cE "^$axis:[[:space:]]*[^[:space:]]+[[:space:]]*$" || true)"
  if [ "$count" -ne 1 ] || [ "$form" -ne 1 ]; then
    atlas_drift bad-vocabulary "$key.md: malformed $axis header"
    return 0
  fi
  value="$(atlas_trim "${lines#*:}")"
  case "$value" in
    ❌|🔶|✅) ATLAS_AXIS_VALUE="$value" ;;
    *) atlas_drift bad-vocabulary "$key.md: $axis has invalid value '$value'" ;;
  esac
}

# bad-vocabulary: one edge line, parsed. `Blocked-by:` is mandatory and
# accepts `none` alone or a comma-separated list of well-formed keys.
# `Pending-on:` is optional, has no `none` form (absence already says the area
# waits on no decision, and the schema allows one spelling per fact), and a
# present line is the same comma-separated list. A display name on either line
# is a pointer in the wrong language, and it is named rather than guessed at.
# The result lands in ATLAS_EDGE_OK and ATLAS_EDGE_N.
atlas_check_edge_line() { # atlas_check_edge_line <area-file> <Blocked-by|Pending-on>
  local file="$1" field="$2" key header lines count value part
  ATLAS_EDGE_OK=0
  ATLAS_EDGE_N=0
  case "$field" in Blocked-by|Pending-on) ;; *) return 1 ;; esac
  key="${file##*/}"; key="${key%.md}"
  header="$(atlas_header_block "$file")"
  lines="$(printf '%s\n' "$header" | grep "^$field" || true)"
  count="$(printf '%s\n' "$lines" | grep -c . || true)"
  [ "$count" -eq 0 ] && [ "$field" = "Pending-on" ] && return 0
  if [ "$count" -ne 1 ] \
    || [ "$(printf '%s\n' "$lines" | grep -cE "^$field:[[:space:]]*[^[:space:]]" || true)" -ne 1 ]; then
    atlas_drift bad-vocabulary "$key.md: malformed $field header"
    return 0
  fi
  value="$(atlas_trim "${lines#"$field:"}")"
  ATLAS_EDGE_OK=1
  [ "$field" = "Blocked-by" ] && [ "$value" = "none" ] && return 0
  while IFS= read -r part; do
    part="$(atlas_trim "$part")"
    if [ -z "$part" ]; then
      atlas_drift bad-vocabulary "$key.md: malformed $field header"
      ATLAS_EDGE_OK=0
    elif [ "$field" = "Pending-on" ] && [ "$part" = "none" ]; then
      atlas_drift bad-vocabulary "$key.md: Pending-on has no 'none' form; remove the line"
      ATLAS_EDGE_OK=0
    elif ! atlas_is_key "$part"; then
      atlas_drift bad-vocabulary "$key.md: $field entry '$part' is not an area key"
      ATLAS_EDGE_OK=0
    else
      ATLAS_EDGE_N=$((ATLAS_EDGE_N + 1))
    fi
  done < <(printf '%s\n' "$value" | tr ',' '\n')
}

# bad-vocabulary: the header block closes its vocabulary. Every non-blank line
# after the title slot and before the first section heading must open with a
# defined key, or a misspelled optional line would silently mean "claims
# nothing" or "waits on nothing". The first line is the title's slot and any
# `# ` line belongs to the title check, so neither is read here.
#
# The caller names its keys in two space-separated lists. A key in
# <prefix-keys> has its own form check (the axes and both edge lines), so it is
# matched as a whole word without its colon and a line that check already named
# is not named again. A key in <colon-keys> has no other form check, so it
# must carry the colon: `Owns src/x`, `Ownsx: src/x` and `Imports any` all mean
# nothing and are named. Either list may be empty.
atlas_check_vocabulary() { # atlas_check_vocabulary <area-file> <prefix-keys> <colon-keys>
  local file="$1" key header line pattern= p c
  key="${file##*/}"; key="${key%.md}"
  header="$(atlas_header_block "$file")"
  p="$(atlas_alternation "$2")"
  c="$(atlas_alternation "$3")"
  [ -n "$p" ] && pattern="^($p)([[:space:]:]|$)"
  [ -n "$c" ] && pattern="${pattern:+$pattern|}^($c):"
  [ -n "$pattern" ] || pattern='^$'
  while IFS= read -r line; do
    atlas_drift bad-vocabulary "$key.md: header line '$line' is not one the schema defines"
  done < <(printf '%s\n' "$header" \
    | awk 'NR == 1 { next } /^# / { next } NF { print }' \
    | grep -vE "$pattern" || true)
}

# axes-contradiction: the understood axis against the enumerable facts that
# move it (SCHEMA.md). Understood reads off Open decisions and Options and why,
# and off the Pending-on line: an area cannot be fully understood while a
# decision it depends on is open in another area. That is the only axis rule
# the Pending-on edge adds. <understood> is the validated symbol from
# atlas_check_axis, and an empty one draws nothing. <pending-ok> and
# <pending-n> are the pair atlas_check_edge_line left for Pending-on.
atlas_check_understood() { # atlas_check_understood <area-file> <understood> <pending-ok> <pending-n>
  local file="$1" u="$2" pending_ok="$3" pending_n="$4" key open resolved
  key="${file##*/}"; key="${key%.md}"
  open="$(atlas_section "$file" 'Open decisions' | grep -c '^- \[ \]' || true)"
  resolved="$(atlas_section "$file" 'Options and why' | grep -c '^- ' || true)"
  if [ "$u" = "✅" ] && [ "$open" -gt 0 ]; then
    atlas_drift axes-contradiction "$key.md: Understood ✅ but $open open decision(s) remain"
  fi
  if [ "$u" = "❌" ] && [ "$resolved" -gt 0 ]; then
    atlas_drift axes-contradiction "$key.md: Understood ❌ but Options and why records $resolved resolved decision(s)"
  fi
  if [ "$u" = "✅" ] && [ "$pending_ok" -eq 1 ] && [ "$pending_n" -gt 0 ]; then
    atlas_drift axes-contradiction "$key.md: Understood ✅ but Pending-on waits on $pending_n area(s)"
  fi
}

# bad-edge and pending-resolved: every entry of a parsed edge line against the
# directory of area files. A well-formed key must have a file there. A
# Pending-on key must also name an area that still has something to decide:
# the condition is the named area's understood axis, not an empty
# open-decisions list, because an area at ❌ with nothing phrased yet is a
# legitimate thing to wait on. A ✅ area has nothing left to decide, so the
# edge is a fossil and the fix is to remove the entry.
#
# <display-dir> is how the directory is spelled in a message, `docs/atlas` for
# the repo checker. Call this only when atlas_check_edge_line left
# ATLAS_EDGE_OK at 1 for the same line, or a display-name entry is named twice.
atlas_check_edge_targets() { # atlas_check_edge_targets <area-file> <atlas-dir> <display-dir> <Blocked-by|Pending-on>
  local file="$1" dir="$2" shown="$3" field="$4" key other reader
  case "$field" in
    Blocked-by) reader=atlas_edges_of ;;
    Pending-on) reader=atlas_pending_of ;;
    *) return 1 ;;
  esac
  key="${file##*/}"; key="${key%.md}"
  while read -r other; do
    [ -n "$other" ] || continue
    if [ ! -f "$dir/$other.md" ]; then
      atlas_drift bad-edge "$key.md: $field names '$other' but $shown/$other.md does not exist"
    elif [ "$field" = "Pending-on" ] \
      && [ "$(atlas_header_value "$dir/$other.md" 'Understood')" = "✅" ]; then
      atlas_drift pending-resolved "$key.md: Pending-on names '$other' but $other.md is ✅ understood; remove the entry"
    fi
  done < <("$reader" "$file")
}

# bad-vocabulary: the index's header block, from its title to its first
# section heading, allows the space-separated <keys> and nothing else. Nothing
# else validates those lines, so each must carry its colon here, and a second
# line of one key is malformed: the scripts read the first and would drop the
# second in silence.
atlas_check_index_header() { # atlas_check_index_header <index-file> <keys>
  local index="$1" name header line k pattern
  name="${index##*/}"
  header="$(awk '/^## / { exit } on && NF { print } /^# / { on = 1 }' "$index")"
  pattern="$(atlas_alternation "$2")"
  [ -n "$pattern" ] && pattern="^($pattern):" || pattern='^$'
  while IFS= read -r line; do
    atlas_drift bad-vocabulary "$name: header line '$line' is not one the schema defines"
  done < <(printf '%s\n' "$header" | grep -vE "$pattern" | grep . || true)
  for k in $2; do
    if [ "$(printf '%s\n' "$header" | grep -c "^$k:" || true)" -gt 1 ]; then
      atlas_drift bad-vocabulary "$name: malformed $k header (more than one line)"
    fi
  done
}

# --- the generated regions ---------------------------------------------------

# The area table. One row per area file: current title linked to the key file,
# then the cells <cells-fn> prints for that file. Every cell is derived, so the
# table cannot disagree with the area files and still match.
#
# The columns are the caller's. <heading-row> is the two literal header lines,
# the column names and the `| --- |` rule, with a newline between them.
# <cells-fn> is the name of a function that takes one area file and prints the
# cells after the title cell, joined by ` | ` with no pipes at either end. The
# repo's pair is below; a fleet index passes its own.
#
# Row order is the PM's, not the machine's: the order already in the index is
# kept, areas missing from it are appended in key order, and a row whose file
# is gone disappears. That makes the pipeline order of a hand-built table
# survive every regeneration.
atlas_table_body() { # atlas_table_body <atlas-dir> <index-file> <heading-row> <cells-fn>
  local dir="$1" index="$2" heading="$3" cells="$4" key seen=" " order
  order="$(
    [ -f "$index" ] && sed -n 's/.*](\([a-z0-9][a-z0-9-]*\)\.md).*/\1/p' "$index"
    atlas_keys "$dir"
  )"
  printf '%s\n' "$heading"
  printf '%s\n' "$order" | while read -r key; do
    [ -n "$key" ] || continue
    case "$seen" in *" $key "*) continue ;; esac
    seen="$seen$key "
    [ -f "$dir/$key.md" ] || continue
    printf '| [%s](%s.md) | %s |\n' \
      "$(atlas_title_of "$dir/$key.md")" "$key" "$("$cells" "$dir/$key.md")"
  done
}

# The repo index's columns: both axis values copied verbatim from the area
# file. check-atlas.sh and render-index.sh both pass this pair, so the table
# the checker recomputes is the one the renderer writes.
ATLAS_REPO_TABLE_HEAD='| Area | Understood | Built |
| --- | --- | --- |'
atlas_repo_cells() { # atlas_repo_cells <area-file>
  printf '%s | %s' \
    "$(atlas_header_value "$1" 'Understood')" \
    "$(atlas_header_value "$1" 'Built')"
}

# --- the fleet ---------------------------------------------------------------
# The parts of the fleet schema (skills/atlas/FLEET.md) that two scripts read:
# check-fleet.sh and fleet-queue.sh both take the same checkout arguments and
# both read the Sides bullets, and check-fleet.sh and render-fleet-index.sh
# both produce the shared-area table. One reader each, here, so the gate and
# the queue cannot parse one bullet two ways. The checks that classify what a
# reader returns stay in check-fleet.sh: a reader here is silent.

# The fleet index's columns: the kind, then the line that goes with the kind,
# the Owner of an implementation or the Revision of a contract, then the
# understood axis. A file whose Kind is neither leaves the third cell empty;
# the gate names the Kind line, and the empty cell is the same on both sides
# of the byte comparison.
ATLAS_FLEET_TABLE_HEAD='| Shared area | Kind | Owner or revision | Understood |
| --- | --- | --- | --- |'
atlas_fleet_cells() { # atlas_fleet_cells <shared-area-file>
  local kind with=
  kind="$(atlas_header_value "$1" 'Kind')"
  case "$kind" in
    contract)       with="$(atlas_header_value "$1" 'Revision')" ;;
    implementation) with="$(atlas_header_value "$1" 'Owner')" ;;
  esac
  printf '%s | %s | %s' "$kind" "$with" "$(atlas_header_value "$1" 'Understood')"
}

# The entries of the index's Repos line, one per line, verbatim. The closed set
# a side may name is the well-formed ones; check-fleet.sh names the rest.
atlas_fleet_repos() { # atlas_fleet_repos <index-file>
  atlas_entries_of "$(atlas_header_value "$1" 'Repos')"
}

# The side specs of one shared area, one per line: each `- ` bullet under
# `## Sides`, cut at its first comma and trimmed. The prose after the comma is
# never read. No Sides section means no sides and prints nothing. An indented
# bullet is not a side, and it is not dropped either: it comes out with its
# `- ` still on, so the gate names it instead of a relation vanishing behind
# a green run.
atlas_sides_of() { # atlas_sides_of <shared-area-file>
  local spec
  atlas_section "$1" Sides \
    | awk '/^- / { sub(/^- /, ""); sub(/,.*/, ""); print }
           /^[[:space:]]+- / { sub(/,.*/, ""); print }' \
    | while IFS= read -r spec; do
        spec="$(atlas_trim "$spec")"
        [ -n "$spec" ] || continue
        printf '%s\n' "$spec"
      done
}

# One side spec parsed against the grammar: a head, then optionally one or
# more spaces and `@<n>` with n a positive integer. The head is `<repo>`,
# `<repo>:<key>` or `<repo>:uncharted`, every part in key form. The parts land
# in three variables and the return code says whether the spec parsed:
#
#   ATLAS_SIDE_REPO   the repo
#   ATLAS_SIDE_KEY    the key, the word `uncharted`, or empty for a whole repo
#   ATLAS_SIDE_PIN    the integer after `@`, or empty when the spec has none
#   ATLAS_SIDE_HEAD   the head as written, without the pin
#
# Returns 1 and leaves all four empty when the spec is not in the grammar. What
# a parsed spec is allowed to carry, given the area's Kind, is the gate's rule
# and not this function's.
ATLAS_SIDE_REPO=
ATLAS_SIDE_KEY=
ATLAS_SIDE_PIN=
ATLAS_SIDE_HEAD=
atlas_parse_side() { # atlas_parse_side <spec>
  local spec="$1" head pin= repo key=
  ATLAS_SIDE_REPO= ATLAS_SIDE_KEY= ATLAS_SIDE_PIN= ATLAS_SIDE_HEAD=
  case "$spec" in
    *@*)
      head="${spec%%@*}"
      pin="${spec#*@}"
      # The pin follows whitespace, so a head that ends in `@` with nothing
      # before it, or `key@3` run together, is not in the grammar.
      case "$head" in *[[:space:]]) ;; *) return 1 ;; esac
      printf '%s' "$pin" | grep -qE '^[1-9][0-9]*$' || return 1
      ;;
    *) head="$spec" ;;
  esac
  head="$(atlas_trim "$head")"
  case "$head" in
    *:*) repo="${head%%:*}"; key="${head#*:}" ;;
    *)   repo="$head" ;;
  esac
  atlas_is_key "$repo" || return 1
  [ -z "$key" ] || atlas_is_key "$key" || return 1
  ATLAS_SIDE_REPO="$repo"
  ATLAS_SIDE_KEY="$key"
  ATLAS_SIDE_PIN="$pin"
  ATLAS_SIDE_HEAD="$head"
  return 0
}

# The `<repo>=<path>` arguments of a fleet script, checked against the set of
# repos the index names. Every repo in the set needs a path and every path
# names a repo in the set, so a partial run can never read as green. On
# success the pairs land in ATLAS_CHECKOUTS, one `repo<TAB>path` line each,
# for atlas_checkout_of to answer from. On a usage error one line goes to
# stderr, nothing to stdout, and the return code is 2: the caller exits with
# it. <script> is the name printed in that line.
ATLAS_CHECKOUTS=
atlas_fleet_checkouts() { # atlas_fleet_checkouts <script> <repos, space-separated> <repo>=<path> ...
  local script="$1" named="$2" repos=" $2 " arg repo path seen=" " r tab
  shift 2
  tab="$(printf '\t')"
  ATLAS_CHECKOUTS=
  for arg in "$@"; do
    case "$arg" in
      *=*) repo="${arg%%=*}"; path="${arg#*=}" ;;
      *) echo "$script: argument '$arg' is not <repo>=<path>" >&2; return 2 ;;
    esac
    case "$repos" in *" $repo "*) ;; *)
      echo "$script: repo '$repo' is not in the index's Repos line" >&2; return 2 ;;
    esac
    case "$seen" in *" $repo "*)
      echo "$script: repo '$repo' is given twice" >&2; return 2 ;;
    esac
    [ -d "$path" ] || { echo "$script: '$path' for repo '$repo' is not a directory" >&2; return 2; }
    seen="$seen$repo "
    ATLAS_CHECKOUTS="$ATLAS_CHECKOUTS$repo$tab$path
"
  done
  for r in $named; do
    case "$seen" in *" $r "*) ;; *)
      echo "$script: no checkout given for repo '$r'; pass $r=<path>" >&2; return 2 ;;
    esac
  done
  return 0
}

# The checkout path one repo was given, from ATLAS_CHECKOUTS.
atlas_checkout_of() { # atlas_checkout_of <repo>
  printf '%s' "$ATLAS_CHECKOUTS" | awk -F'\t' -v r="$1" '$1 == r { print $2; exit }'
}

# Sorted edge lines of one kind. Both ids are keys: the waiting id comes from
# the file name, the other from the entry as written. Two edge kinds exist and
# the schema closes the set at two (SCHEMA.md): a Blocked-by entry draws a
# solid `blocker --> blocked` arrow, and a Pending-on entry draws a dotted
# `decider -.-> waiting` arrow. Both run from the area waited on to the area
# that waits.
atlas_graph_edges() { # atlas_graph_edges <atlas-dir> <Blocked-by|Pending-on>
  local dir="$1" field="$2" f key other arrow reader
  case "$field" in
    Blocked-by) arrow='-->'; reader=atlas_edges_of ;;
    Pending-on) arrow='-.->'; reader=atlas_pending_of ;;
    *) return 1 ;;
  esac
  for f in "$dir"/*.md; do
    [ -f "$f" ] || continue
    key="${f##*/}"; key="${key%.md}"
    [ "$key" = "index" ] && continue
    "$reader" "$f" | while read -r other; do
      [ -n "$other" ] || continue
      printf '  %s %s %s\n' "$other" "$arrow" "$key"
    done
  done | LC_ALL=C sort
}

# The dependency graph. Every area gets an explicit node whose id is its frozen
# key and whose visible label is its current title, so a retitle changes the
# drawing and never the identity. Edges stay the only source of dependency
# truth, in one deterministic order: every solid edge sorted, then every
# dotted edge sorted. There is one accepted form of this block and no fallback.
atlas_graph_body() { # atlas_graph_body <atlas-dir>
  local dir="$1" key title nodes solid dotted
  nodes="$(
    atlas_keys "$dir" | while read -r key; do
      title="$(atlas_title_of "$dir/$key.md" | sed 's/"/\&quot;/g')"
      printf '  %s["%s"]\n' "$key" "$title"
    done
  )"
  solid="$(atlas_graph_edges "$dir" Blocked-by)"
  dotted="$(atlas_graph_edges "$dir" Pending-on)"
  printf '%smermaid\ngraph TD\n' '```'
  [ -n "$nodes" ] && printf '%s\n' "$nodes"
  [ -n "$solid" ] && printf '%s\n' "$solid"
  [ -n "$dotted" ] && printf '%s\n' "$dotted"
  printf '%s' '```'
}

# The current content between one marker pair, or nothing when the pair is
# absent. Both scripts read a region the same way.
atlas_region_of() { # atlas_region_of <index-file> <begin-prefix> <end-prefix>
  awk -v b="$2" -v e="$3" '
    index($0, b) == 1 { on = 1; next }
    index($0, e) == 1 { on = 0 }
    on { print }
  ' "$1"
}

# Whether a marker pair is present in the index.
atlas_has_markers() { # atlas_has_markers <index-file> <begin-prefix> <end-prefix>
  grep -qF "$2" "$1" && grep -qF "$3" "$1"
}
