#!/bin/sh
# yolo session init (PID 1), in one of two modes (YOLO_MODE):
#
#   datum (default): configures loopback, installs the session's SSH keys,
#     mounts the shared home, then supervises dropbear (loopback only) and
#     dumbpipe (iroh endpoint). Logins land as the login user (see YOLO_USER).
#   local (docker backend): sets up the same user, environment, nix and home,
#     then idles; `docker exec` attaches. HOME is a host directory bind-mounted
#     at /home/agent, and the user takes the host's uid (HOST_UID/HOST_GID) so
#     files there keep the host user's ownership. GIT_NAME, GIT_EMAIL and
#     GIT_SIGNING_KEY set git identity and signing, and the claude settings in
#     /etc/agent/claude seed a home that has none. A private key mounted at
#     /run/yolo-key/id is loaded into an agent at /run/yolo-ssh/agent.sock.
#
# The `jump` image (harness jump; datum mode) is a long-lived jump box: no nix,
# shared home or provider config. Every login runs `jump login` (a forced command
# on each authorized key), and `jump setup` starts the one in-memory ssh-agent that
# logins, tmux and held connections all use. Clients don't forward their agent.
#
# Environment (datum), from the per-session Secret written by yolo:
#   IROH_SECRET          iroh endpoint secret key; the client derives the ticket
#   AUTHORIZED_KEYS_B64  base64 authorized_keys (for the user and root)
#   SSH_HOST_KEY_B64     base64 OpenSSH ed25519 host key; the client pins it
#   PROVIDER_KEYS        names of the provider keys (from the shared Secret
#                        agent-providers) passed in as variables of those names,
#                        e.g. "ANTHROPIC_API_KEY TOKENROUTER_API_KEY"; optional.
#                        OAuth logins (claude /login, codex login, ...) persist
#                        in the shared home instead.
#   SESSION_NAME         hostname
#   YOLO_USER            the login user's name (both modes). The image's user is a
#                        placeholder, renamed to this at boot; it must be a portable
#                        username and not root, or the placeholder stays.
#   YOLO_BROKER_ID       the credential broker's endpoint id (not jump harness). With
#   YOLO_BROKER_CA       the broker CA (PEM, base64) and YOLO_PROXY_SECRET_KEY (the
#   YOLO_PROXY_SECRET_KEY proxy's own key, hex), see broker_setup. Never written out.
# Shared home (optional; all from the shared Secret agent-home):
#   META_TICKET          dumbpipe ticket for the JuiceFS metadata Redis
#   META_URL             redis://:<password>@127.0.0.1:6379/1, through that tunnel
#   AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY   bucket-scoped key for JuiceFS data
#   JFS_MOUNT_OPTS       extra `juicefs mount` options (word-split), from agent-sandbox
# Programs run by absolute path: Unikraft's execve does no PATH search (H14).
export PATH=/bin
export HOME=/root
# The broker's proxy key and CA are kept in unexported shell variables and removed
# from the environment here, before any child starts, so no child inherits them.
# broker_setup hands the key to the proxy alone.
BROKER_KEY=${YOLO_PROXY_SECRET_KEY:-}
BROKER_CA=${YOLO_BROKER_CA:-}
unset YOLO_PROXY_SECRET_KEY YOLO_BROKER_CA
log() { echo "[agent] $*"; }
MODE=${YOLO_MODE:-datum}
JUMP=0
[ "$(cat /etc/agent/harness 2>/dev/null)" = jump ] && JUMP=1

# Nix normalizes permissions in store outputs, so the image's modes for /tmp
# and /root don't survive; set them here.
chmod 1777 /tmp
chmod 0700 /root

# The image's login user is a placeholder (/etc/agent/user), so no name is baked
# into the image; rename it, and its group, to $YOLO_USER. nix.conf trusts the
# user through its group (@NAME).
U=$(cat /etc/agent/user 2>/dev/null || echo agent)
valid_user() {
  case $1 in ''|root|[!a-z_]*|*[!a-z0-9_-]*) return 1 ;; esac
  [ ${#1} -le 32 ]
}
if [ -n "${YOLO_USER:-}" ] && [ "$YOLO_USER" != "$U" ]; then
  if valid_user "$YOLO_USER"; then
    sed -i "s/^$U:x:\([0-9]*:[0-9]*\):$U:/$YOLO_USER:x:\1:$YOLO_USER:/" /etc/passwd
    sed -i "s/^$U:/$YOLO_USER:/" /etc/group
    sed -i "s/@$U\$/@$YOLO_USER/" /etc/nix/nix.conf
    echo "$YOLO_USER" > /etc/agent/user
    U=$YOLO_USER
  else
    log "YOLO_USER '$YOLO_USER' is not a portable user name; the login user stays $U"
  fi
fi
# local: the user takes the host user's uid and gid, so the bind-mounted home
# keeps host ownership.
if [ "$MODE" = local ] && [ -n "$HOST_UID" ] && [ -n "$HOST_GID" ]; then
  old_uid=$(/bin/id -u "$U")
  sed -i "s/^$U:x:$old_uid:$old_uid:/$U:x:$HOST_UID:$HOST_GID:/" /etc/passwd
  sed -i "s/^$U:x:$old_uid:/$U:x:$HOST_GID:/" /etc/group
fi
# jump: plain bash. The dotfiles' zsh config re-picks SSH_AUTH_SOCK at every
# shell start, which fights the persistent agent that owns it here.
[ $JUMP = 1 ] && sed -i "/^$U:/s|:/bin/zsh\$|:/bin/bash|" /etc/passwd
UID_=$(/bin/id -u "$U")
GID_=$(/bin/id -g "$U")
as_user() { /bin/su "$U" -s /bin/sh -c "$1"; }

# The credential broker (datum, not jump): a loopback CONNECT proxy, run as its own
# user (yolo-proxy, so the login user cannot read its environment), which sends
# allowed hosts to the broker on the jump box (broker/README.md). Sets BROKER=1
# once the proxy's supervisor runs. The key comes from BROKER_KEY (captured at the
# top) and reaches the proxy's environment only: no file, the env file or a log
# line. env -i gives the proxy nothing else. A CA that is missing or doesn't
# decode skips the setup, and TLS stays as it was.
BROKER=0
broker_setup() {
  [ "$JUMP" = 0 ] && [ -n "${YOLO_BROKER_ID:-}" ] && [ -n "$BROKER_KEY" ] || return 0
  sys=/etc/ssl/certs/ca-certificates.crt
  bundle=/etc/agent/ca-bundle.pem
  ca=/etc/agent/broker-ca.pem
  if ! printf '%s' "$BROKER_CA" | /bin/base64 -d > "$ca" 2>/dev/null \
     || ! /bin/grep -q 'BEGIN CERTIFICATE' "$ca"; then
    rm -f "$ca"
    log "broker: YOLO_BROKER_CA is not a base64 PEM certificate; no proxy"
    return 0
  fi
  if [ ! -r "$sys" ] || ! { /bin/cat "$sys"; printf '\n'; /bin/cat "$ca"; } > "$bundle"; then
    rm -f "$ca" "$bundle"
    log "broker: cannot write the CA bundle; no proxy"
    return 0
  fi
  chmod 0644 "$ca" "$bundle"
  # The proxy's own user: no home, no login shell.
  /bin/grep -q '^yolo-proxy:' /etc/group || echo 'yolo-proxy:x:992:' >> /etc/group
  /bin/grep -q '^yolo-proxy:' /etc/passwd \
    || echo 'yolo-proxy:x:992:992:yolo-proxy:/nonexistent:/bin/false' >> /etc/passwd
  (
    # Only these four reach the proxy. The key goes through the environment,
    # never a command line: /proc/PID/cmdline is world-readable.
    id=$YOLO_BROKER_ID
    for name in $(/bin/env | /bin/sed -n 's/^\([A-Za-z_][A-Za-z0-9_]*\)=.*/\1/p'); do
      unset "$name" 2>/dev/null
    done
    # shellcheck disable=SC2030  # meant for this subshell only
    export PATH=/bin HOME=/nonexistent YOLO_BROKER_ID="$id" YOLO_PROXY_SECRET_KEY="$BROKER_KEY"
    while :; do
      # shellcheck disable=SC2016  # $YOLO_BROKER_ID expands in the proxy's shell
      /bin/su yolo-proxy -s /bin/sh -c 'exec /bin/yolo-broker-proxy run --broker "$YOLO_BROKER_ID"'
      log "broker proxy exited rc=$?; restarting"
      sleep 2
    done
  ) &
  BROKER=1
  # shellcheck disable=SC2031  # the subshell's export is meant to stay there
  log "broker: proxy for $YOLO_BROKER_ID on 127.0.0.1:3128"
}

# nix: register the store paths shipped in the image (the store database lives
# on the RAM overlay and starts empty), then run the daemon the user talks to.
if [ $JUMP = 0 ] && [ -s /etc/agent/nix-registration ] && [ ! -e /nix/var/nix/db/db.sqlite ]; then
  if /bin/nix-store --load-db < /etc/agent/nix-registration 2>/tmp/nix-load-db.log; then
    log "nix: registered $(grep -c '^/nix/store/' /etc/agent/nix-registration) store paths"
  else
    log "nix: load-db FAILED: $(tail -2 /tmp/nix-load-db.log | tr '\n' ' ')"
  fi
fi
[ $JUMP = 0 ] && /bin/nix-daemon > /tmp/nix-daemon.log 2>&1 &

# Unprivileged ICMP, so iputils ping works for the login user.
# (Read-only under docker, which already allows it in containers.)
(echo "0 2147483647" > /proc/sys/net/ipv4/ping_group_range) 2>/dev/null

if [ "$MODE" = datum ]; then
  # lo is down with no addresses at boot (docs/datum.md).
  /bin/ip link set lo up
  /bin/ip addr add 127.0.0.1/8 dev lo
  /bin/ip -6 addr add ::1/128 dev lo
  [ -n "$SESSION_NAME" ] && /bin/hostname "$SESSION_NAME"

  # The broker proxy binds loopback, so it starts after lo is up.
  broker_setup

  # SSH keys: dropbear -D reads authorized_keys from /etc/agent/ssh for every
  # user, so the session's keys stay out of the shared home.
  mkdir -p /etc/agent/ssh /etc/dropbear
  echo "$AUTHORIZED_KEYS_B64" | /bin/base64 -d > /etc/agent/ssh/authorized_keys
  # jump: every key logs in through `jump login` (the persistent agent, then tmux
  # or the client's command). Comments and blanks stay.
  [ $JUMP = 1 ] && sed -i '/^[[:space:]]*\(#\|$\)/!s|^|command="/bin/jump login" |' /etc/agent/ssh/authorized_keys
  chmod 0644 /etc/agent/ssh/authorized_keys
  umask 077
  echo "$SSH_HOST_KEY_B64" | /bin/base64 -d > /run/host_key
  /bin/dropbearconvert openssh dropbear /run/host_key /etc/dropbear/host_key >/dev/null 2>&1 \
    || log "host key conversion FAILED"
  rm -f /run/host_key
  umask 022
fi

# Shared home: JuiceFS (data in S3, metadata in Redis reached over iroh) mounted
# at /mnt/agent-fs; its home/ subdirectory is the user's HOME (/home/agent), so
# every session sees the same ~/.claude and ~/work, as on a laptop.
SHARED=0
if [ -n "$META_TICKET" ] && [ -n "$META_URL" ]; then
  (
    while :; do
      # Without IROH_SECRET: that key belongs to the SSH listener, and two
      # endpoints with one key knock each other off the relay.
      /bin/env -u IROH_SECRET -u YOLO_DATUM_CREDENTIALS_JSON /bin/dumbpipe connect-tcp --addr 127.0.0.1:6379 "$META_TICKET" 2>&1 \
        | /bin/grep -v -e 'endpoint[a-z0-9]\{20\}'
      log "meta tunnel exited; restarting"
      sleep 2
    done
  ) &
  # Not the mount root: JuiceFS puts virtual control files (.config, .stats,
  # .accesslog, .trash) there, and ~/.config being one broke every XDG program.
  mkdir -p /mnt/agent-fs /home /tmp/jfs-cache
  for _ in $(seq 30); do /bin/nc -z 127.0.0.1 6379 2>/dev/null && break; sleep 1; done
  # Cache lives in RAM (the root overlay is RAM-backed), so keep it bounded.
  # Dual-stack S3: some locations (staging us-east-1) have no IPv4 egress at
  # all, and JuiceFS rewrites the bucket URL to the IPv4-only endpoint.
  # shellcheck disable=SC2086  # JFS_MOUNT_OPTS is a list of options
  if /bin/env -u YOLO_DATUM_CREDENTIALS_JSON AWS_USE_DUALSTACK_ENDPOINT=true /bin/juicefs mount --background --cache-dir /tmp/jfs-cache --cache-size 256 \
       --buffer-size 128 --log /tmp/juicefs.log $JFS_MOUNT_OPTS "$META_URL" /mnt/agent-fs; then
    mkdir -p /mnt/agent-fs/home/work
    # Files written before the login user existed belong to root; hand them over once.
    if [ "$(stat -c %u /mnt/agent-fs/home)" != "$UID_" ]; then
      log "giving the shared home to $U"
      chown -R "$UID_:$UID_" /mnt/agent-fs/home
    fi
    ln -sfn /mnt/agent-fs/home /home/agent
    SHARED=1
    log "shared home mounted at /home/agent"
  else
    log "shared home mount FAILED; HOME is local ($(tail -3 /tmp/juicefs.log 2>/dev/null | tr '\n' ' '))"
  fi
fi
unset META_URL META_TICKET AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
if [ "$MODE" = local ]; then
  # The host directory mounted at /home/agent; a fresh mount point is root's.
  mkdir -p /home/agent
  [ "$(stat -c %u /home/agent)" = "$UID_" ] || chown "$UID_:$GID_" /home/agent
elif [ $SHARED = 0 ]; then
  mkdir -p /home/local && chown "$UID_:$GID_" /home/local
  ln -sfn /home/local /home/agent
fi
mkdir -p /work && chown "$UID_:$GID_" /work

# dropbear does not pass the container environment to sessions, so login
# shells load it from /etc/agent/env (via /etc/zshenv and /etc/profile).
# Writes `export NAME='value'`: the value is single-quoted, with any single quote
# inside it escaped.
env_export() {
  printf "export %s='%s'\n" "$1" "$(printf '%s' "$2" | sed "s/'/'\\\\''/g")"
}
{
  echo 'export PATH=/bin'
  echo 'export SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt'
  echo 'export DISABLE_AUTOUPDATER=1'
  echo 'export OPENCODE_CONFIG=/etc/agent/opencode.json'
  # Caches in RAM, per user: per-session anyway, and nix's tarball and eval
  # caches are thousands of small files that would be slow on JuiceFS.
  # shellcheck disable=SC2016  # expanded when a login shell loads the file
  echo 'export XDG_CACHE_HOME=/tmp/.cache-$(id -un)'
  echo "export AGENT_HARNESS=$(cat /etc/agent/harness 2>/dev/null)"
  cat /etc/agent/env.static 2>/dev/null
  for k in $PROVIDER_KEYS; do
    case $k in ''|[0-9]*|*[!A-Za-z0-9_]*) continue ;; esac   # names reach eval
    eval "v=\${$k:-}"
    # shellcheck disable=SC2154  # v is set by the eval above
    [ -n "$v" ] && env_export "$k" "$v"
  done
  # The box's bootstrap locators and generation (jump; harmlessly unset elsewhere).
  # YOLO_DATUM_CREDENTIALS_JSON never goes here: `jump setup` writes it to a file.
  [ -n "${YOLO_CONFIG_URL:-}" ] && env_export YOLO_CONFIG_URL "$YOLO_CONFIG_URL"
  [ -n "${YOLO_BOX:-}" ] && env_export YOLO_BOX "$YOLO_BOX"
  [ -n "${YOLO_GENERATION:-}" ] && env_export YOLO_GENERATION "$YOLO_GENERATION"
  # The broker proxy and CA trust (broker_setup). Later lines win, so these
  # override SSL_CERT_FILE above. The proxy key is never written here.
  if [ "$BROKER" = 1 ]; then
    env_export HTTPS_PROXY http://127.0.0.1:3128
    env_export https_proxy http://127.0.0.1:3128
    env_export SSL_CERT_FILE /etc/agent/ca-bundle.pem
    env_export REQUESTS_CA_BUNDLE /etc/agent/ca-bundle.pem
    env_export CURL_CA_BUNDLE /etc/agent/ca-bundle.pem
    env_export GIT_SSL_CAINFO /etc/agent/ca-bundle.pem
    env_export NODE_EXTRA_CA_CERTS /etc/agent/broker-ca.pem
  fi
} > /etc/agent/env
chown "root:$GID_" /etc/agent/env && chmod 0640 /etc/agent/env
unset AUTHORIZED_KEYS_B64 SSH_HOST_KEY_B64
[ $JUMP = 1 ] && U=$U UID_=$UID_ GID_=$GID_ /bin/sh /bin/jump setup
# jump setup has read the credentials; nothing started after this (dropbear,
# dumbpipe, ws) inherits them. The early children above are run with -u.
unset YOLO_DATUM_CREDENTIALS_JSON
for k in $PROVIDER_KEYS; do case $k in ''|[0-9]*|*[!A-Za-z0-9_]*) ;; *) unset "$k" ;; esac; done

# ws open/clone print the RAM path of the workspace; land the shell there.
# shellcheck disable=SC2016  # a function for login shells, expanded there
WS_FN='ws() {
  case ${1:-} in
    open|clone) local d; d=$(command ws "$@") && cd "$d" ;;
    close) command ws "$@" && case $PWD/ in /work/"$2"/*) cd ;; esac ;;
    *) command ws "$@" ;;
  esac
}'
printf '%s\n' "$WS_FN" > /etc/zshrc
printf '%s\ncd\n' "$WS_FN" > /root/.bash_profile

# The user's home, as that user: the dotfiles' zsh config (linked from the
# image, so it tracks the image, unless the home already has its own),
# ~/go (01-env warns without it), and in the claude image Remote Control on
# at startup unless the user settings already decide it.
touch /etc/agent/opencode.json && chown "$UID_:$GID_" /etc/agent/opencode.json
export YOLO_MODE="$MODE"
# shellcheck disable=SC2016  # runs in the user's shell
as_user '
  cd "$HOME" || exit 0
  if [ -d /etc/agent/zsh ] && [ "$(cat /etc/agent/harness)" != jump ]; then
    for f in zshrc zshenv zprofile; do [ -e ".$f" ] || [ -L ".$f" ] || ln -s "/etc/agent/zsh/$f" ".$f"; done
    [ -e .zsh.d ] || [ -L .zsh.d ] || ln -s /etc/agent/zsh/zsh.d .zsh.d
  fi
  [ -e .zshrc ] || [ -L .zshrc ] || : > .zshrc   # no dotfiles: skip zsh-newuser-install
  mkdir -p go
  if [ "$(cat /etc/agent/harness)" = claude ]; then
    mkdir -p .claude
    # local: seed claude from the image overlay (dangerous mode, rtk hook,
    # plugins; see /etc/agent/claude) unless the home already has its own.
    if [ "$YOLO_MODE" = local ] && [ -d /etc/agent/claude ]; then
      [ -s .claude/settings.json ] || cp /etc/agent/claude/settings.json .claude/settings.json
      [ -s .claude.json ] || cp /etc/agent/claude/claude-state.json .claude.json
    fi
    [ -s .claude/settings.json ] || echo "{}" > .claude/settings.json
    if ! jq -e "has(\"remoteControlAtStartup\")" .claude/settings.json >/dev/null 2>&1; then
      jq ". + {remoteControlAtStartup: true}" .claude/settings.json > .claude/settings.json.tmp \
        && mv .claude/settings.json.tmp .claude/settings.json
    fi
  fi
'

# local: git identity and signing from the host (GIT_NAME, GIT_EMAIL,
# GIT_SIGNING_KEY), as yolo's entrypoint did.
if [ "$MODE" = local ]; then
  as_user "
    [ -n '$GIT_NAME' ] && git config --global user.name '$GIT_NAME'
    [ -n '$GIT_EMAIL' ] && git config --global user.email '$GIT_EMAIL'
    if [ -n '$GIT_SIGNING_KEY' ]; then
      git config --global gpg.format ssh
      git config --global user.signingkey '$GIT_SIGNING_KEY'
      git config --global commit.gpgsign true
    fi
    # The host's ~/.ssh/allowed_signers, for verifying signatures.
    [ -r /etc/ssh/allowed_signers ] && git config --global gpg.ssh.allowedSignersFile /etc/ssh/allowed_signers
    true"
  # An injected private key (/run/yolo-key/id; for runtimes that can't relay
  # the host agent's socket, such as podman on macOS) goes into an agent here
  # at a fixed socket, which attach points SSH_AUTH_SOCK at.
  if [ -r /run/yolo-key/id ]; then
    mkdir -p /run/yolo-ssh && chown "$UID_:$GID_" /run/yolo-ssh && chmod 700 /run/yolo-ssh
    if as_user 'ssh-agent -a /run/yolo-ssh/agent.sock >/dev/null' \
       && as_user 'SSH_AUTH_SOCK=/run/yolo-ssh/agent.sock ssh-add - 2>/dev/null' < /run/yolo-key/id; then
      log "ssh key loaded into the session agent"
    else
      log "ssh key NOT loaded (passphrase-protected keys are unsupported)"
    fi
  fi
fi

# opencode and pi provider config for the registry providers whose key is set
# (needs the keys and the network, so it runs in the background).
[ $JUMP = 0 ] && as_user '. /etc/agent/env && /bin/agent-providers sync' >/dev/null 2>&1 &
# Repos live in RAM under /work and persist to ~/work via ws (agent/ws).
[ $SHARED = 1 ] && as_user 'exec /bin/ws autosave' &

log "mem: $(grep MemAvailable /proc/meminfo | tr -s ' ')"
log "harness: $(cat /etc/agent/harness 2>/dev/null); login user: $U"
log "mode: $MODE; providers: ${PROVIDER_KEYS:-none}"

if [ "$MODE" = local ]; then
  # Nothing to serve: `docker exec` attaches. Idle until stopped.
  trap 'log stopped; exit 0' TERM INT
  log "ready"
  while :; do sleep 3600 & wait $!; done
fi
log "keys: $(wc -l < /etc/agent/ssh/authorized_keys) authorized"

(
  while :; do
    /bin/dropbear -F -E -s -D /etc/agent/ssh -r /etc/dropbear/host_key -p 127.0.0.1:2222
    log "dropbear exited rc=$?; restarting"
    sleep 2
  done
) &

# Reachability of iroh's discovery server, which the client needs: the endpoint
# publishes its relay address there over HTTPS (pkarr), and clients look it up
# as a TXT record. Logged per address, because the network is IPv6-only (ULA)
# and publishing has been seen to hang silently.
for a in $(/bin/nslookup dns.iroh.link 2>/dev/null | /bin/awk '/^Address: /{print $2}'); do
  if /bin/nc -z -w 5 "$a" 443 2>/dev/null; then r=ok; else r=FAIL; fi
  log "dns.iroh.link $a:443 $r"
done

# On shutdown, copy every workspace from RAM to the shared home first. (Datum
# deletes workloads without SIGTERM, so autosave and agent-sandbox rm matter more.)
shutdown() {
  log "stopping: saving workspaces"
  [ $SHARED = 1 ] && as_user '/bin/ws save --all' 2>&1 | head -20
  log "stopped"
  exit 0
}
trap shutdown TERM INT

sleep 1
while :; do
  # Background + wait, so a signal runs the trap now rather than after dumbpipe.
  /bin/dumbpipe listen-tcp --host 127.0.0.1:2222 2>&1 | /bin/grep -v -e 'endpoint[a-z0-9]\{20\}' &
  wait $!
  log "dumbpipe exited; restarting"
  sleep 5
done
