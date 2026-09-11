#!/usr/bin/env bash
# The atlas gap queue: the ordered question list a sitting works. Reads only.
#
#   gap-queue.sh [root]      default root: current directory
#
# Compares the map's claims against the repository's tracked files at run time
# and prints one GAP line per finding. This is the advisory half of the
# gate/queue split: check-atlas.sh gates the facts the map alone settles, and
# everything that compares the map to the code is here. A repo honestly
# mid-mapping has a long queue and a green gate, which is the correct state and
# not a failure. **No finding here can ever fail a landing.**
#
# Six classes, printed in this order, biggest question first:
#
#   undeclared-dependency
#                code in one area imports code in another area, and the
#                importing area's `Blocked-by:` line does not name the imported
#                area. One line per importing area, sorted by key, listing every
#                imported area it has no edge to with its count of importing
#                files, sorted by imported key:
#
#                  GAP undeclared-dependency: <importer> — imports with no
#                  Blocked-by edge: <imported> (<n> files), <imported> (1 file)
#
#                First because an architecture question outranks an ownership
#                one. Only a direct `Blocked-by:` entry declares a dependency:
#                a chain through a third area does not, and no other header
#                line does. An area whose file carries `Imports: any` imports
#                freely by design, so its importing side is skipped; other
#                areas importing it are still reported. Supported languages:
#                Python. With no tracked `.py` file in scope the class prints
#                nothing and writes nothing to stderr
#   contested    a file two or more areas both claim. There is no precedence
#                rule to apply, so the overlap is a question, and a sitting
#                settles it by narrowing a pattern
#   unclaimed    tracked code no area claims, rolled up to the shallowest
#                directory whose in-scope files are *all* unclaimed
#   dead-claim   a pattern matching no tracked file, in a Built ✅ area only.
#                Below ✅ the same pattern is an intention (SCHEMA.md) and says
#                nothing
#   unphrased    an area at ❌ understood recording no open decision — the map
#                says nothing is decided and does not say what is open
#   fog          an index Fog bullet, one line each, unadorned. Last, and with
#                no age on it: the queue position already says "still unnamed"
#
# **The import scan reads the code, not a cache.** Import lines are read with a
# pattern in awk at any indentation, so a lazy import inside a function or a
# type-only import under a TYPE_CHECKING guard counts; an import-shaped line
# inside a multi-line string counts too, and that imprecision is accepted. An
# import is attributed to the module the statement names, never to the names
# it imports: `from a.b import c, d` and `import a.b as x` both land on `a.b`.
# A module resolves by exact path from the root, `a/b.py` then
# `a/b/__init__.py`; a relative import resolves against the importing file's
# directory, one level up per extra leading dot, then the same two forms. There
# is no suffix match, so a module that resolves to no tracked file in scope is
# third-party or standard-library and is dropped. A file no area claims, or one
# two areas claim, produces nothing on either end: the unclaimed and contested
# classes already ask about it. An import within one area produces nothing.
#
# **The roll-up is what makes this a question list rather than a file dump.** A
# directory every one of whose in-scope files is unclaimed prints once, as high
# up the tree as that stays true, so an unmigrated repo's test tree is one
# question and not eight hundred. The root itself is never a cluster, so the
# coarsest line is a top-level entry — which is the coarse-first sitting the
# migration wants. A directory that rolls up to a single file prints that file
# instead, because the file says the same thing and reads better. An unclaimed
# file inside a partly-claimed directory prints on its own.
#
# Scope. The territory is the tracked files under <root>, the directory holding
# docs/atlas/, and paths are relative to it — the same root and the same reading
# `Owns:` itself uses. Out of it: the atlas's own directory, always and without
# being listed, and everything the index's `Ignore:` line matches. A file out of
# scope appears in no finding, on either side of a claim.
#
# Nothing is derived on disk. There is no cache, no staleness class and no
# regeneration step; the script reads the repository as it stands at run time.
#
# Exit codes:
#
#   exit 0   always, findings or none. It is a report, never a gate
#   exit 1   <root> has no docs/atlas/
#   exit 2   more than one argument
#   git's    a claim git refuses as a pathspec, or a root that is not a git
#            repository — git's own message and git's own exit code, unchanged.
#            A swallowed error would report the whole repository as unclaimed
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/atlas-lib.sh"

[ "$#" -le 1 ] || { echo "usage: gap-queue.sh [root]" >&2; exit 2; }

ROOT="${1:-.}"
ATLAS="$ROOT/docs/atlas"
INDEX="$ATLAS/index.md"

[ -d "$ATLAS" ] || { echo "no atlas at $ATLAS" >&2; exit 1; }

TAB="$(printf '\t')"

gap() { printf 'GAP %s: %s\n' "$1" "$2"; }

# Every git read goes through here, with the two settings atlas_claimed_files is
# built on: the GIT_ variables unset, because -C does not override an inherited
# GIT_DIR, and core.quotePath off, so a path outside ASCII is printed as itself
# rather than as a C-escaped string no later command can open.
git_ls() { # git_ls [pathspec…]
  (
    unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE
    git -C "$ROOT" -c core.quotePath=false ls-files -- "$@"
  )
}

sorted() { grep -v '^$' | LC_ALL=C sort -u; }

# Every set operation below runs under LC_ALL=C, and so does every sort that
# feeds one. Measured on macOS: under an en_CA.UTF-8 collation `comm` reads
# `README.md` as sorting after `build/out.js`, decides its input is unsorted,
# and prints the whole of the first stream with nothing subtracted — silently,
# at exit 0. The queue would then report every exempt and ignored file as
# unclaimed. A mismatch between the sort's collation and the set operation's is
# the failure, so the two are never allowed to differ.
c_comm() { LC_ALL=C comm "$@"; }

# --- the territory -----------------------------------------------------------
ALL="$(git_ls)" || exit $?
EXEMPT="$(git_ls docs/atlas)" || exit $?

IGNORED=
IGNORE_VALUE="$(atlas_header_value "$INDEX" 'Ignore')"
if [ -n "$IGNORE_VALUE" ]; then
  IGNORE_SPECS=()
  while IFS= read -r ENTRY; do
    [ -n "$ENTRY" ] || continue
    IGNORE_SPECS[${#IGNORE_SPECS[@]}]="$ENTRY"
  done < <(atlas_entries_of "$IGNORE_VALUE")
  if [ "${#IGNORE_SPECS[@]}" -gt 0 ]; then
    IGNORED="$(git_ls "${IGNORE_SPECS[@]}")" || exit $?
  fi
fi

OUT_OF_SCOPE="$(printf '%s\n%s\n' "$EXEMPT" "$IGNORED" | sorted)"
IN_SCOPE="$(c_comm -23 <(printf '%s\n' "$ALL" | sorted) <(printf '%s\n' "$OUT_OF_SCOPE"))"

# --- who claims what ---------------------------------------------------------
# One `path<TAB>key` line per claim, sorted, then narrowed to the territory. The
# whole ownership picture is this stream: contested reads it for a path two keys
# both name, and unclaimed reads it for the paths it never names.
PAIRS=
for KEY in $(atlas_keys "$ATLAS"); do
  CLAIMED="$(atlas_claimed_files "$ROOT" "$ATLAS/$KEY.md")" || exit $?
  [ -n "$CLAIMED" ] || continue
  PAIRS="$PAIRS$(printf '%s\n' "$CLAIMED" | sed "s|\$|$TAB$KEY|")
"
done
PAIRS="$(printf '%s' "$PAIRS" | grep -v '^$' | LC_ALL=C sort)"
PAIRS="$(LC_ALL=C join -t"$TAB" -o '1.1,1.2' \
  <(printf '%s\n' "$PAIRS" | grep -v '^$') <(printf '%s\n' "$IN_SCOPE" | grep -v '^$'))"

# --- undeclared-dependency ---------------------------------------------------
# Python only. The whole scan is one stream into one awk: the in-scope files
# (T), the ownership pairs the other classes read (O), the declared edges (E),
# the areas ruled to import freely (A), and the import lines (I). The owner map
# and the contested set are therefore the same ones contested and unclaimed use,
# and this class cannot disagree with them. The module-to-file lookup is built
# once from the T lines and joined in awk; nothing loops per import in the
# shell. Import extraction runs awk over the files from the root, so FILENAME is
# the same root-relative path the pairs carry. The `./` prefix keeps a file
# name holding `=` from being read as an awk assignment and is stripped again.
PY_FILES="$(printf '%s\n' "$IN_SCOPE" | grep '\.py$' || true)"
if [ -n "$PY_FILES" ]; then
  EDGES=
  IMPORTS_ANY=
  for KEY in $(atlas_keys "$ATLAS"); do
    F="$ATLAS/$KEY.md"
    while IFS= read -r BLOCKER; do
      [ -n "$BLOCKER" ] || continue
      EDGES="$EDGES$KEY$TAB$BLOCKER
"
    done < <(atlas_edges_of "$F")
    [ "$(atlas_header_value "$F" 'Imports')" = "any" ] && IMPORTS_ANY="$IMPORTS_ANY$KEY
"
  done
  {
    printf '%s\n' "$IN_SCOPE" | grep -v '^$' | sed "s|^|T$TAB|"
    printf '%s\n' "$PAIRS" | grep -v '^$' | sed "s|^|O$TAB|"
    printf '%s' "$EDGES" | sed "s|^|E$TAB|"
    printf '%s' "$IMPORTS_ANY" | sed "s|^|A$TAB|"
    (
      cd "$ROOT" && printf '%s\n' "$PY_FILES" | sed 's|^|./|' | tr '\n' '\0' | xargs -0 awk '
        # Both statement forms, at any indentation. `from X import …` names
        # one module, X, which may be relative. `import a, b as c` names one
        # module per comma-separated part, before any `as`.
        {
          f = FILENAME; sub(/^\.\//, "", f)
          if (match($0, /^[ \t]*from[ \t]+[.A-Za-z_][.A-Za-z0-9_]*[ \t]+import[ \t(]/)) {
            s = substr($0, RSTART, RLENGTH)
            sub(/^[ \t]*from[ \t]+/, "", s); sub(/[ \t]+import[ \t(]$/, "", s)
            print f "\t" s
          } else if (match($0, /^[ \t]*import[ \t]+[A-Za-z_]/)) {
            n = split(substr($0, RSTART + RLENGTH - 1), parts, ",")
            for (i = 1; i <= n; i++) {
              p = parts[i]; sub(/^[ \t]+/, "", p)
              if (match(p, /^[A-Za-z_][.A-Za-z0-9_]*/)) print f "\t" substr(p, RSTART, RLENGTH)
            }
          }
        }'
    ) | sed "s|^|I$TAB|"
  } | awk -F'\t' '
    $1 == "T" { tracked[$2] = 1; next }
    $1 == "O" { owner[$2] = $3; claims[$2]++; next }
    $1 == "E" { edge[$2 "\t" $3] = 1; next }
    $1 == "A" { any[$2] = 1; next }
    $1 == "I" {
      file = $2; mod = $3
      # The importing side: one claimant, and not ruled to import freely.
      if (!(file in owner) || claims[file] != 1 || (owner[file] in any)) next
      if (substr(mod, 1, 1) == ".") {
        dots = 0
        while (substr(mod, dots + 1, 1) == ".") dots++
        rest = substr(mod, dots + 1)
        # The importing file'\''s directory, then one level up per extra dot.
        # A dot that climbs above the root resolves to nothing.
        dir = file; above = 0
        for (i = 1; i <= dots; i++) {
          if (i > 1 && dir == "") { above = 1; break }
          if (index(dir, "/")) sub(/\/[^\/]*$/, "", dir); else dir = ""
        }
        if (above) next
        p = rest; gsub(/\./, "/", p)
        if (dir != "" && p != "") p = dir "/" p
        else if (dir != "") p = dir
      } else {
        p = mod; gsub(/\./, "/", p)
      }
      # Exact path from the root, the module file then the package, and no
      # suffix match: anything else is third-party or standard-library. A bare
      # `from . import x` names the package itself, so only its __init__ counts;
      # a module file that happens to share the directory name is not it.
      pkg = (p == "" ? "__init__.py" : p "/__init__.py")
      if (substr(mod, 1, 1) == "." && rest == "") {
        if (pkg in tracked) tgt = pkg; else next
      } else if ((p ".py") in tracked) tgt = p ".py"
      else if (pkg in tracked) tgt = pkg
      else next
      # The imported side: one claimant, another area, and no direct edge.
      if (!(tgt in owner) || claims[tgt] != 1) next
      a = owner[file]; b = owner[tgt]
      if (a == b || ((a "\t" b) in edge)) next
      print a "\t" b "\t" file
    }
  ' | LC_ALL=C sort -u | awk -F'\t' '
    # Sorted and unique importer, imported, file triples roll up to one line
    # per importer, in the order they arrive.
    function files(k) { return k == 1 ? "1 file" : k " files" }
    function flush_b() {
      if (b != "") list = list (list == "" ? "" : ", ") b " (" files(k) ")"
      b = ""; k = 0
    }
    function flush_a() {
      flush_b()
      if (a != "") printf "GAP undeclared-dependency: %s — imports with no Blocked-by edge: %s\n", a, list
      a = ""; list = ""
    }
    $1 != a { flush_a(); a = $1 }
    $2 != b { flush_b(); b = $2 }
    { k++ }
    END { flush_a() }
  '
fi

# --- contested ---------------------------------------------------------------
printf '%s\n' "$PAIRS" | grep -v '^$' | awk -F'\t' '
  $1 != cur {
    if (n >= 2) printf "GAP contested: %s — claimed by %s\n", cur, keys
    cur = $1; keys = $2; n = 1; next
  }
  { keys = keys ", " $2; n++ }
  END { if (n >= 2) printf "GAP contested: %s — claimed by %s\n", cur, keys }
'

# --- unclaimed ---------------------------------------------------------------
# Every in-scope file marked C or U, then rolled up. The first awk counts each
# ancestor directory's files and how many of them are unclaimed; a directory
# where those two counts agree is fully unclaimed. The second walks an unclaimed
# file's ancestors from the top down and takes the first such directory as its
# cluster, which is therefore the shallowest one. The walk starts at depth 1, so
# the root can never be a cluster.
CLAIMED_PATHS="$(printf '%s\n' "$PAIRS" | cut -f1 | sorted)"
UNCLAIMED="$(c_comm -23 <(printf '%s\n' "$IN_SCOPE" | grep -v '^$') \
                        <(printf '%s\n' "$CLAIMED_PATHS"))"

{
  printf '%s\n' "$CLAIMED_PATHS" | grep -v '^$' | sed 's|^|C'"$TAB"'|'
  printf '%s\n' "$UNCLAIMED" | grep -v '^$' | sed 's|^|U'"$TAB"'|'
} | awk -F'\t' '
  {
    n++; st[n] = $1; pa[n] = $2
    m = split($2, seg, "/")
    pre = ""
    for (i = 1; i < m; i++) {
      pre = (i == 1 ? seg[1] : pre "/" seg[i])
      tot[pre]++
      if ($1 == "U") un[pre]++
    }
  }
  END {
    for (k = 1; k <= n; k++) {
      if (st[k] != "U") continue
      m = split(pa[k], seg, "/")
      cluster = pa[k]
      pre = ""
      for (i = 1; i < m; i++) {
        pre = (i == 1 ? seg[1] : pre "/" seg[i])
        if (tot[pre] == un[pre]) { cluster = pre; break }
      }
      print cluster "\t" pa[k]
    }
  }
' | LC_ALL=C sort | awk -F'\t' '
  {
    if (!($1 in seen)) { seen[$1] = 1; order[++o] = $1 }
    c[$1]++; one[$1] = $2
  }
  END {
    for (i = 1; i <= o; i++) {
      k = order[i]
      if (c[k] == 1) printf "GAP unclaimed: %s\n", one[k]
      else printf "GAP unclaimed: %s/ — %d files, no area claims any\n", k, c[k]
    }
  }
'

# --- dead-claim --------------------------------------------------------------
# Per pattern, not per area: one dead pattern in an otherwise live claim list is
# the finding worth having. An exclude pattern is skipped, because git reads one
# standing alone as "everything else" and it could therefore never come back
# empty — measured, not assumed.
for KEY in $(atlas_keys "$ATLAS"); do
  F="$ATLAS/$KEY.md"
  [ "$(atlas_header_value "$F" 'Built')" = "✅" ] || continue
  while IFS= read -r PATTERN; do
    [ -n "$PATTERN" ] || continue
    case "$PATTERN" in ':(exclude)'*|':!'*) continue ;; esac
    MATCHED="$(git_ls "$PATTERN")" || exit $?
    [ -n "$MATCHED" ] \
      || gap dead-claim "$KEY.md claims '$PATTERN' but it matches no tracked file"
  done < <(atlas_entries_of "$(atlas_header_value "$F" 'Owns')")
done

# --- unphrased ---------------------------------------------------------------
for KEY in $(atlas_keys "$ATLAS"); do
  F="$ATLAS/$KEY.md"
  [ "$(atlas_header_value "$F" 'Understood')" = "❌" ] || continue
  OPEN="$(atlas_section "$F" 'Open decisions' | grep -c '^- \[ \]' || true)"
  [ "$OPEN" -eq 0 ] \
    && gap unphrased "$KEY.md is ❌ understood but records no open decision"
done

# --- fog ---------------------------------------------------------------------
while IFS= read -r BULLET; do
  [ -n "$BULLET" ] || continue
  gap fog "${BULLET#- }"
done < <(atlas_section "$INDEX" 'Fog' | grep '^- ' || true)

exit 0
