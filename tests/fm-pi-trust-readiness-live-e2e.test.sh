#!/usr/bin/env bash
# Opt-in credentialed drift guard for Pi-family trust and launch readiness.
# It launches every installed Pi identity in a real tmux pane on a private
# socket and uses the backend's viewport capture as the evidence oracle.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate opt-in FM_PI_TRUST_READINESS_LIVE tmux jq

TMP_ROOT=$(fm_test_tmproot fm-pi-trust-readiness-live)
REAL_TMUX=$(command -v tmux)
SOCKET="fm-pi-trust-readiness-$$"
SESSION=pi-trust-readiness
SHIM_DIR="$TMP_ROOT/tmux-shim"
CHECKED=0
VERIFIED_VERSIONS='0.85.1'

cleanup() {
  "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  fm_test_cleanup
}
trap cleanup EXIT

mkdir -p "$SHIM_DIR"
cat >"$SHIM_DIR/tmux" <<EOF
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCKET" "\$@"
EOF
chmod +x "$SHIM_DIR/tmux"
PATH="$SHIM_DIR:$PATH"
export PATH

# shellcheck source=bin/fm-backend.sh
. "$ROOT/bin/fm-backend.sh"
fm_backend_source tmux || fail "could not load the tmux backend"
tmux new-session -d -s "$SESSION" -x 220 -y 50 \
  || fail "could not start the private tmux server"

capture_viewport() { # <target>
  fm_backend_visible_capture tmux "$1"
}

complete_dialog_for_path() { # <capture> <exact-path>
  local pane=$1 path=$2 token
  for token in \
    'Trust project folder?' \
    'This allows pi to load .pi settings and resources' \
    'install missing project' \
    'packages, and execute project extensions.' \
    'Trust parent folder' \
    'Trust (this session only)' \
    'Do not trust' \
    'Do not trust (this session only)' \
    'navigate' 'select' 'escape/ctrl+c' 'cancel'; do
    case "$pane" in *"$token"*) ;; *) return 1 ;; esac
  done
  case "$pane" in *"$path"*) ;; *) return 1 ;; esac
  printf '%s\n' "$pane" | grep -Eq '^[[:space:]]*→ Trust[[:space:]]*$'
}

wait_for_fresh_dialog() { # <target> <exact-path>
  local target=$1 path=$2 i=0 pane=
  while [ "$i" -lt 120 ]; do
    pane=$(capture_viewport "$target" 2>/dev/null) || {
      printf '%s\n' "viewport capture failed for $target" >&2
      return 1
    }
    if complete_dialog_for_path "$pane" "$path"; then
      return 0
    fi
    sleep 0.25
    i=$((i + 1))
  done
  printf '%s\n' "$pane" >&2
  return 1
}

wait_for_processing_after_clear() { # <target> <marker>
  local target=$1 marker=$2 i=0 pane=
  while [ "$i" -lt 120 ]; do
    pane=$(capture_viewport "$target" 2>/dev/null) || return 1
    case "$pane" in
      *'Trust project folder?'* | *'Trust parent folder'* | *'Do not trust'*) ;;
      *)
        if [ -f "$marker" ]; then
          return 0
        fi
        ;;
    esac
    sleep 0.25
    i=$((i + 1))
  done
  printf '%s\n' "$pane" >&2
  return 1
}

wait_for_reused_processing_without_dialog() { # <target> <marker>
  local target=$1 marker=$2 i=0 pane=
  while [ "$i" -lt 120 ]; do
    pane=$(capture_viewport "$target" 2>/dev/null) || return 1
    case "$pane" in
      *'Trust project folder?'* | *'Trust parent folder'* | *'Do not trust'*)
        printf '%s\n' "$pane" >&2
        return 1
        ;;
    esac
    if [ -f "$marker" ]; then
      return 0
    fi
    sleep 0.25
    i=$((i + 1))
  done
  printf '%s\n' "$pane" >&2
  return 1
}

launch_pi_pane() { # <window> <cwd> <binary> <agent-dir> <extension>
  local window=$1 cwd=$2 binary=$3 agent_dir=$4 extension=$5
  tmux new-window -d -t "$SESSION:" -n "$window" -c "$cwd" -- \
    env PI_CODING_AGENT_DIR="$agent_dir" PI_OFFLINE=1 \
    "$binary" --no-session --no-context-files --no-extensions --no-skills \
      -e "$extension" --thinking low \
      'Reply briefly with the words launch readiness confirmed.'
}

for identity in pi pi-signed; do
  if ! binary=$(command -v "$identity" 2>/dev/null); then
    printf '# %s absent: not exercised by this run\n' "$identity"
    continue
  fi
  version=$("$binary" --version 2>/dev/null | sed -n '1p') || version=
  case " $VERIFIED_VERSIONS " in
    *" $version "*) ;;
    *) fail "$identity $version is installed but its project-trust selector is not in the verified version set ($VERIFIED_VERSIONS)" ;;
  esac

  lab="$TMP_ROOT/$identity"
  project="$lab/project"
  agent_dir="$lab/agent"
  marker="$lab/agent-started"
  extension="$lab/readiness.ts"
  window="fm-$identity"
  target="$SESSION:$window"
  mkdir -p "$project/.pi" "$agent_dir"
  git -C "$project" init -q
  printf '{}\n' >"$project/.pi/settings.json"
  for name in auth.json models.json models-store.json settings.json; do
    [ ! -f "$HOME/.pi/agent/$name" ] || cp "$HOME/.pi/agent/$name" "$agent_dir/$name"
  done
  marker_json=$(printf '%s' "$marker" | jq -Rs .)
  cat >"$extension" <<EOF
import { writeFileSync } from "node:fs";
export default function (pi: any) {
  pi.on("agent_start", () => writeFileSync($marker_json, "agent-start\\n"));
}
EOF

  launch_pi_pane "$window" "$project" "$binary" "$agent_dir" "$extension" \
    || fail "$identity $version could not be launched in the real backend pane"
  wait_for_fresh_dialog "$target" "$project" \
    || fail "$identity $version did not show the complete exact-path selector in the viewport"
  fm_backend_send_key tmux "$target" Enter \
    || fail "$identity $version complete trust selector could not be submitted"
  wait_for_processing_after_clear "$target" "$marker" \
    || fail "$identity $version did not clear trust and emit agent_start"
  jq -e --arg path "$project" '.[$path] == true' "$agent_dir/trust.json" >/dev/null \
    || fail "$identity $version did not persist trust for the exact project path"
  fm_backend_kill tmux "$target"

  rm -f "$marker"
  launch_pi_pane "$window" "$project" "$binary" "$agent_dir" "$extension" \
    || fail "$identity $version could not relaunch the trusted path"
  wait_for_reused_processing_without_dialog "$target" "$marker" \
    || fail "$identity $version did not start its reused trusted path without another selector"
  fm_backend_kill tmux "$target"

  printf 'ok - %s %s: real backend viewport proved fresh exact-path trust, clear, agent_start, and trusted reuse\n' \
    "$identity" "$version"
  CHECKED=$((CHECKED + 1))
done

[ "$CHECKED" -gt 0 ] || fail "no Pi-family executable was installed, so the live readiness guard verified nothing"
printf '# checked %s installed Pi-family executable(s)\n' "$CHECKED"
