# shellcheck shell=bash
# Session state shared by all backends. Sourced by yolo.
#
# Each session is a directory under $YOLO_STATE/NAME holding at least
# `backend` and `harness`; backends keep their own files beside them (keys,
# tickets). Only `yolo new` needs --backend: later commands read it from here.

die() { echo "yolo: $*" >&2; exit 1; }

# opt NAME DEFAULT: $YOLO_NAME, else the old $AGENT_SANDBOX_NAME, else DEFAULT.
opt() {
  local y="YOLO_$1" a="AGENT_SANDBOX_$1"
  printf '%s' "${!y:-${!a:-$2}}"
}

YOLO_STATE=${YOLO_STATE:-${XDG_STATE_HOME:-$HOME/.local/state}/yolo/sessions}
HARNESSES="claude gemini codex opencode pi"

check_harness() {
  case " $HARNESSES " in *" $1 "*) ;; *) die "unknown harness '$1' (have: $HARNESSES)" ;; esac
}

session_dir() {
  [[ $1 =~ ^[a-z0-9]([a-z0-9-]{0,38}[a-z0-9])?$ ]] \
    || die "name must be lowercase letters, digits and '-', at most 40 chars"
  echo "$YOLO_STATE/$1"
}

session_backend() {
  local dir; dir=$(session_dir "$1")
  [ -f "$dir/backend" ] || die "no session $1 (yolo ls)"
  cat "$dir/backend"
}

# session_create NAME BACKEND HARNESS: the directory, mode 700, with metadata.
session_create() {
  local dir; dir=$(session_dir "$1")
  [ -e "$dir" ] && die "session $1 exists ($dir); yolo rm $1 first"
  mkdir -p "$dir" && chmod 700 "$dir"
  echo "$2" > "$dir/backend"
  echo "$3" > "$dir/harness"
  echo "$dir"
}

# Sessions created by agent-sandbox (Datum only) move here once. The old
# directory becomes a symlink to the new one, so agent-sandbox keeps working.
# Skipped when YOLO_STATE is overridden (tests, other state dirs).
migrate_agent_sandbox_state() {
  local default=${XDG_STATE_HOME:-$HOME/.local/state}/yolo/sessions
  local old=${XDG_STATE_HOME:-$HOME/.local/state}/agent-sandbox d n
  [ "$YOLO_STATE" = "$default" ] || return 0
  [ -d "$old" ] && [ ! -L "$old" ] || return 0
  mkdir -p "$YOLO_STATE"
  for d in "$old"/*/; do
    [ -d "$d" ] || continue
    n=$(basename "$d")
    [ -e "$YOLO_STATE/$n" ] && die "can't migrate $n: $YOLO_STATE/$n exists"
    mv "$d" "$YOLO_STATE/$n" && echo datum > "$YOLO_STATE/$n/backend"
    echo "yolo: moved agent-sandbox session $n to $YOLO_STATE" >&2
  done
  rmdir "$old" && ln -s "$YOLO_STATE" "$old"
}
