# shellcheck shell=bash
# docker backend: sessions as long-lived local containers (docker or podman)
# running the same per-harness image as Datum, in local mode. Sourced by yolo
# after lib/session.sh.
#
# new options: -v HOST:CONTAINER[:ro]   bind-mount a directory (repeatable),
#                                       e.g. -v ~/src/app:/work/app
#
# - Container yolo-NAME, image yolo/HARNESS:local (built on first use, or with
#   `yolo build HARNESS`).
# - HOME is ${YOLO_DOCKER_HOME:-~/.local/share/yolo/home}, shared by every
#   docker session and kept across `yolo rm`. The login user takes your uid.
# - Provider keys: ${YOLO_PROVIDERS_ENV:-~/.config/yolo/providers.env}
#   (KEY=value lines, keep it 0600), if it exists.
# - Git: GIT_NAME, GIT_EMAIL, GIT_SIGNING_KEY and GITHUB_TOKEN are passed in.
# - SSH agent: while you're attached, a socat relay in the session directory
#   connects the container to your current $SSH_AUTH_SOCK
#   (YOLO_FORWARD_AGENT=0 turns it off). Podman on macOS can't share sockets
#   with the VM (VirtioFS), so there, or whenever SSH_PRIVATE_KEY_FILE (a key
#   path) or SSH_PRIVATE_KEY (base64 key) is set, the key is mounted read-only
#   instead and loaded into an agent inside the session. It must have no
#   passphrase.
# - ~/.ssh/allowed_signers, if present, is mounted for git signature checks.

DOCKER_RUNTIME=${YOLO_RUNTIME:-${CONTAINER_RUNTIME:-}}
if [ -z "$DOCKER_RUNTIME" ]; then
  if command -v docker >/dev/null 2>&1; then DOCKER_RUNTIME=docker
  elif command -v podman >/dev/null 2>&1; then DOCKER_RUNTIME=podman
  else die "docker: neither docker nor podman found in PATH"; fi
fi
case ${OSTYPE:-} in
  darwin*) DOCKER_HOME_DEFAULT="$HOME/Library/Application Support/yolo/home" ;;
  *) DOCKER_HOME_DEFAULT="${XDG_DATA_HOME:-$HOME/.local/share}/yolo/home" ;;
esac
DOCKER_HOME=$(opt DOCKER_HOME "$DOCKER_HOME_DEFAULT")
DOCKER_PROVIDERS_ENV=$(opt PROVIDERS_ENV "${XDG_CONFIG_HOME:-$HOME/.config}/yolo/providers.env")
DOCKER_FORWARD_AGENT=$(opt FORWARD_AGENT 1)
DOCKER_USER=$(opt USER drewr)

docker_image() { echo "yolo/$1:local"; }

# Podman machine on macOS shares host files over VirtioFS, which can't carry
# Unix sockets, so the agent relay can't reach the container.
docker_no_socket_relay() {
  [ "$DOCKER_RUNTIME" = podman ] && [[ ${OSTYPE:-} == darwin* ]]
}

# Build yolo/HARNESS:local from image/ with the same Dockerfile Datum uses.
docker_build() {
  local h=$1
  echo "yolo: building $(docker_image "$h")" >&2
  "$DOCKER_RUNTIME" build --build-arg "HARNESS=$h" -t "$(docker_image "$h")" -f "$YOLO_ROOT/image/Dockerfile" "$YOLO_ROOT/image"
}

backend_new() {
  local name=$1 harness=$2; shift 2
  local mounts=() m host
  while [ $# -gt 0 ]; do
    case $1 in
      -v|--volume)
        m=$2; host=${m%%:*}
        [ -e "$host" ] || die "docker: $host does not exist"
        mounts+=(-v "$(realpath "$host"):${m#*:}"); shift 2 ;;
      *) die "docker: unknown option $1" ;;
    esac
  done
  local image; image=$(docker_image "$harness")
  "$DOCKER_RUNTIME" image inspect "$image" >/dev/null 2>&1 || docker_build "$harness"
  mkdir -p "$DOCKER_HOME"
  local dir; dir=$(session_create "$name" docker "$harness")
  mkdir -p "$dir/agent"

  # SSH: relay the host agent at attach, or inject a key (see the header).
  local keymount=()
  if [ -n "${SSH_PRIVATE_KEY:-}" ]; then
    (umask 077; printf '%s' "$SSH_PRIVATE_KEY" | base64 -d > "$dir/ssh_key") \
      || { rm -rf "$dir"; die "docker: SSH_PRIVATE_KEY is not valid base64"; }
    keymount=(-v "$dir/ssh_key:/run/yolo-key/id:ro")
  elif [ -n "${SSH_PRIVATE_KEY_FILE:-}" ]; then
    [ -r "$SSH_PRIVATE_KEY_FILE" ] || { rm -rf "$dir"; die "docker: cannot read $SSH_PRIVATE_KEY_FILE"; }
    keymount=(-v "$(realpath "$SSH_PRIVATE_KEY_FILE"):/run/yolo-key/id:ro")
  elif docker_no_socket_relay; then
    echo "yolo: $DOCKER_RUNTIME on macOS can't relay the SSH agent; set SSH_PRIVATE_KEY_FILE for SSH in the session" >&2
  fi
  [ ${#keymount[@]} -gt 0 ] && touch "$dir/ssh_key_mode"
  # Copied rather than bind-mounted: it is often a symlink into /nix/store,
  # which a podman machine VM can't see.
  if [ -f "$HOME/.ssh/allowed_signers" ]; then
    cp -L "$HOME/.ssh/allowed_signers" "$dir/allowed_signers"
    keymount+=(-v "$dir/allowed_signers:/etc/ssh/allowed_signers:ro")
  fi

  local env=(-e YOLO_MODE=local -e SESSION_NAME="$name"
             -e HOST_UID="$(id -u)" -e HOST_GID="$(id -g)")
  local v
  for v in GIT_NAME GIT_EMAIL GIT_SIGNING_KEY GITHUB_TOKEN; do
    [ -n "${!v:-}" ] && env+=(-e "$v")
  done
  if [ -f "$DOCKER_PROVIDERS_ENV" ]; then
    env+=(--env-file "$DOCKER_PROVIDERS_ENV"
          -e PROVIDER_KEYS="$(grep -oE '^[A-Za-z_][A-Za-z0-9_]*=' "$DOCKER_PROVIDERS_ENV" | tr -d = | tr '\n' ' ')")
  fi

  "$DOCKER_RUNTIME" run -d --name "yolo-$name" --hostname "$name" \
    "${env[@]}" -v "$DOCKER_HOME:/home/agent" -v "$dir/agent:/run/yolo-agent" \
    "${keymount[@]}" "${mounts[@]}" "$image" >/dev/null \
    || { rm -rf "$dir"; die "docker: could not start yolo-$name"; }
  echo "started yolo-$name ($harness: $image); waiting for init..." >&2
  local t0=$SECONDS
  until "$DOCKER_RUNTIME" logs "yolo-$name" 2>&1 | grep -q '\[agent\] ready'; do
    [ $((SECONDS - t0)) -lt 120 ] || die "init not ready after 2 min; try: yolo logs $name"
    sleep 1
  done
  echo "ready after $((SECONDS - t0))s: yolo attach $name" >&2
}

backend_attach() {
  local name=$1; shift
  local dir; dir=$(session_dir "$name")
  local tty=(-i) relay='' env=(-e SHELL=/bin/zsh -e TERM="${TERM:-xterm-256color}")
  [ -t 0 ] && [ -t 1 ] && tty=(-it)
  # The session's own agent holding an injected key, or else the current SSH
  # agent, relayed only while attached.
  if [ -f "$dir/ssh_key_mode" ]; then
    env+=(-e SSH_AUTH_SOCK=/run/yolo-ssh/agent.sock)
  elif [ "$DOCKER_FORWARD_AGENT" = 1 ] && [ -S "${SSH_AUTH_SOCK:-}" ] && ! docker_no_socket_relay; then
    local socat; socat=$(command -v socat || echo "$(nix build --no-link --print-out-paths nixpkgs#socat)/bin/socat")
    rm -f "$dir/agent/agent.sock"
    "$socat" "UNIX-LISTEN:$dir/agent/agent.sock,fork,mode=600" "UNIX-CONNECT:$SSH_AUTH_SOCK" 2>/dev/null &
    relay=$!
    env+=(-e SSH_AUTH_SOCK=/run/yolo-agent/agent.sock)
    for _ in $(seq 50); do [ -S "$dir/agent/agent.sock" ] && break; sleep 0.1; done
  fi
  local rc=0
  if [ $# -gt 0 ]; then
    "$DOCKER_RUNTIME" exec "${tty[@]}" -u "$DOCKER_USER" -w /home/agent "${env[@]}" "yolo-$name" \
      zsh -lc "$*" || rc=$?
  else
    "$DOCKER_RUNTIME" exec "${tty[@]}" -u "$DOCKER_USER" -w /home/agent "${env[@]}" "yolo-$name" \
      zsh -l || rc=$?
  fi
  [ -n "$relay" ] && kill "$relay" 2>/dev/null
  rm -f "$dir/agent/agent.sock"
  return $rc
}

backend_ls() {
  "$DOCKER_RUNTIME" ps -a --filter name='^yolo-' --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}'
}

backend_logs() {
  local name=$1; shift
  "$DOCKER_RUNTIME" logs "$@" "yolo-$name"
}

backend_rm() {
  local name=$1
  local dir; dir=$(session_dir "$name")
  # Workspaces are bind mounts and HOME is on the host: nothing to save.
  "$DOCKER_RUNTIME" rm -f "yolo-$name" >/dev/null 2>&1 && echo "removed yolo-$name" >&2
  rm -rf "$dir"
}
