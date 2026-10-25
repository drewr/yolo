# shellcheck shell=bash
# datum backend: sessions on Datum Compute (unikernel class by default),
# reached by SSH over iroh. Sourced by yolo after lib/session.sh and lib/keys.sh.
#
# new options: --key PUBKEY_FILE (authorize this key instead of the agent's),
#              --no-home (private, ephemeral HOME instead of the shared home)
#
# Each session gets a fresh iroh secret and SSH host key generated here, stored
# in a per-session Datum Secret (agent-NAME) and in the session directory. The
# client derives the iroh ticket from the secret and pins the host key, so
# nothing is read from instance logs and there is no trust-on-first-use.
#
# Model providers: every key in the Datum Secret agent-providers is passed to
# the session as a variable of the same name; only key names are read here.
# Shared home: if the Datum Secret agent-home exists, every session mounts the
# same JuiceFS volume as HOME. See docs/datum.md.
#
# Needs: datumctl (logged in), ssh, ssh-keygen, openssl, jq, xxd, base32, and
# dumbpipe (falls back to `nix build nixpkgs#dumbpipe`).

DATUM_IMAGES=$(opt IMAGES "$YOLO_ROOT/image/images")
# Login user in the sandbox (the images' unprivileged user); root also works.
DATUM_USER=$(opt USER drewr)
# Forward the local SSH agent, so git over SSH in the sandbox uses your keys
# while you're connected (any process there can use them meanwhile). 0: off.
DATUM_FORWARD_AGENT=$(opt FORWARD_AGENT 1)
# Datum production (api.datum.net), project drewr-y4nd1b. Sessions depend only
# on features in production. Session names are email@api-host; an explicit
# DATUM_SESSION wins.
export DATUM_SESSION=${YOLO_DATUM_SESSION:-${AGENT_SANDBOX_DATUM_SESSION:-${DATUM_SESSION:-aaraines@gmail.com@api.datum.net}}}
DATUM_PULL_SECRET=$(opt PULL_SECRET ghcr-drewr)
DATUM_LOCATION=$(opt LOCATION us-east-1)
DATUM_NETWORK=$(opt NETWORK default)
DATUM_INSTANCE_TYPE=$(opt INSTANCE_TYPE datumcloud/d1-standard-2)
# Runtime class: unikernel, or general-purpose for harnesses that don't run on
# Unikraft; general-purpose gets the capabilities a FUSE mount (the shared
# home) needs.
DATUM_CLASS=$(opt CLASS unikernel)
# The relay instances have chosen as home in every run so far (n0 use1, Virginia).
DATUM_RELAY=$(opt RELAY https://use1-1.relay.n0.iroh.link./)
DATUM_HOME_SECRET=$(opt HOME_SECRET agent-home)
DATUM_PROVIDERS_SECRET=$(opt PROVIDERS_SECRET agent-providers)
# Extra `juicefs mount` options for the shared home (passed as JFS_MOUNT_OPTS).
DATUM_JFS_OPTS=$(opt JFS_OPTS '')

# Key names in the providers Secret that are valid variable names. Values are
# never read here.
datum_provider_key_names() {
  datumctl get secret "$DATUM_PROVIDERS_SECRET" -o json 2>/dev/null \
    | jq -r '.data // {} | keys[]' | grep -E '^[A-Za-z_][A-Za-z0-9_]*$' || true
}

backend_new() {
  local name=$1 harness=$2; shift 2
  local key='' home=1
  while [ $# -gt 0 ]; do
    case $1 in
      --key) key=$2; shift 2 ;;
      --no-home) home=0; shift ;;
      *) die "datum: unknown option $1" ;;
    esac
  done
  if [ $home = 1 ] && ! datumctl get secret "$DATUM_HOME_SECRET" >/dev/null 2>&1; then
    echo "yolo: no Secret $DATUM_HOME_SECRET; this session's HOME is ephemeral" >&2
    home=0
  fi
  local image; image=$(opt IMAGE '')
  [ -n "$image" ] || image=$(awk -v h="$harness" '$1 == h {print $2}' "$DATUM_IMAGES" 2>/dev/null)
  [ -n "$image" ] || die "no image for harness '$harness' in $DATUM_IMAGES (yolo build $harness)"
  local dir; dir=$(session_create "$name" datum "$harness")

  (
    umask 077
    openssl rand -hex 32 > "$dir/iroh_secret"
    endpoint_ticket "$DATUM_RELAY" < "$dir/iroh_secret" > "$dir/ticket"
    ssh-keygen -q -t ed25519 -N '' -C "agent-$name" -f "$dir/host_key"
    echo "agent-$name $(cut -d' ' -f1,2 "$dir/host_key.pub")" > "$dir/known_hosts"
    authorized_keys "$key" > "$dir/authorized_keys"
    # A --key FILE.pub with its private key beside it is also the identity.
    if [ -n "$key" ] && [ -f "${key%.pub}" ] && [ "${key%.pub}" != "$key" ]; then
      realpath "${key%.pub}" > "$dir/identity"
    fi
  )
  grep -q '^endpoint' "$dir/ticket" || die "could not derive the iroh ticket"

  {
    printf 'apiVersion: v1\nkind: Secret\nmetadata:\n  name: agent-%s\ntype: Opaque\nstringData:\n' "$name"
    printf '  IROH_SECRET: "%s"\n' "$(cat "$dir/iroh_secret")"
    printf '  AUTHORIZED_KEYS_B64: "%s"\n' "$(base64 -w0 < "$dir/authorized_keys")"
    printf '  SSH_HOST_KEY_B64: "%s"\n' "$(base64 -w0 < "$dir/host_key")"
  } | datumctl apply -f - >/dev/null
  local home_env='' k
  if [ $home = 1 ]; then
    for k in META_TICKET META_URL AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY; do
      home_env+=$(printf '                - name: %s\n                  valueFrom:\n                    secretKeyRef: { name: %s, key: %s }\n' "$k" "$DATUM_HOME_SECRET" "$k")
      home_env+=$'\n'
    done
  fi
  local caps=''
  if [ "$DATUM_CLASS" = general-purpose ]; then
    caps='              securityContext:
                capabilities:
                  add: [SYS_ADMIN, MKNOD, CHOWN, DAC_OVERRIDE, FOWNER, FSETID, KILL, NET_BIND_SERVICE, SETFCAP, SETGID, SETPCAP, SETUID, SYS_CHROOT]'
  fi
  # One secretKeyRef per provider key (the unikernel class has no envFrom).
  local provider_env='' provider_keys=''
  for k in $(datum_provider_key_names); do
    provider_env+=$(printf '                - name: %s\n                  valueFrom:\n                    secretKeyRef: { name: %s, key: %s }\n' "$k" "$DATUM_PROVIDERS_SECRET" "$k")
    provider_env+=$'\n'
    provider_keys+="$k "
  done

  datumctl apply -f - >/dev/null <<EOF
apiVersion: compute.datumapis.com/v1alpha
kind: Workload
metadata:
  name: agent-$name
  labels:
    agent-sandbox: "true"
    agent-harness: $harness
spec:
  template:
    spec:
      runtime:
        class: $DATUM_CLASS
        resources:
          instanceType: $DATUM_INSTANCE_TYPE
        sandbox:
          imagePullSecrets:
            - name: $DATUM_PULL_SECRET
          containers:
            - name: agent
              image: $image
$caps
              env:
                - name: YOLO_MODE
                  value: datum
                - name: SESSION_NAME
                  value: $name
                - name: JFS_MOUNT_OPTS
                  value: "$DATUM_JFS_OPTS"
                - name: ENDPOINT_DNS
                  value: _iroh.$(endpoint_z32 < "$dir/iroh_secret").dns.iroh.link
                - name: IROH_SECRET
                  valueFrom:
                    secretKeyRef: { name: agent-$name, key: IROH_SECRET }
                - name: AUTHORIZED_KEYS_B64
                  valueFrom:
                    secretKeyRef: { name: agent-$name, key: AUTHORIZED_KEYS_B64 }
                - name: SSH_HOST_KEY_B64
                  valueFrom:
                    secretKeyRef: { name: agent-$name, key: SSH_HOST_KEY_B64 }
                - name: PROVIDER_KEYS
                  value: "${provider_keys% }"
$provider_env
$home_env
      networkInterfaces:
        - network:
            name: $DATUM_NETWORK
  placements:
    - name: default
      locations:
        - name: $DATUM_LOCATION
      scaleSettings:
        minReplicas: 1
EOF
  echo "created agent-$name ($harness: $image); waiting for SSH..." >&2
  local t0=$SECONDS
  # Subshell: backend_attach execs ssh.
  until (backend_attach "$name" -o ConnectTimeout=20 -o BatchMode=yes true) 2>/dev/null; do
    [ $((SECONDS - t0)) -lt 300 ] || die "no SSH after 5 min; try: yolo logs $name"
    sleep 10
  done
  echo "ready after $((SECONDS - t0))s: yolo attach $name" >&2
}

backend_attach() {
  local name=$1; shift
  local dir; dir=$(session_dir "$name")
  [ -f "$dir/ticket" ] || die "no local state for $name"
  local dp; dp=$(dumbpipe_bin)
  # Options must precede the destination; anything after "--" is the command.
  local opts=() cmd=()
  [ -f "$dir/identity" ] && opts+=(-i "$(cat "$dir/identity")" -o IdentitiesOnly=yes)
  [ "$DATUM_FORWARD_AGENT" = 1 ] && opts+=(-o ForwardAgent=yes)
  while [ $# -gt 0 ]; do
    case $1 in --) shift; cmd=("$@"); break ;; -o|-L|-R|-D|-i) opts+=("$1" "$2"); shift 2 ;;
      -*) opts+=("$1"); shift ;; *) cmd=("$@"); break ;; esac
  done
  exec ssh -o "ProxyCommand=$dp connect $(cat "$dir/ticket") 2>/dev/null" \
    -o "UserKnownHostsFile=$dir/known_hosts" -o "HostKeyAlias=agent-$name" \
    -o StrictHostKeyChecking=yes -o ServerAliveInterval=30 \
    "${opts[@]}" "$DATUM_USER@agent-$name" "${cmd[@]}"
}

backend_ls() {
  datumctl compute workloads 2>/dev/null | awk 'NR==1 || /^agent-/'
}

backend_logs() {
  local name=$1; shift
  datumctl compute logs "agent-$name" "$@"
}

backend_rm() {
  local name=$1
  local dir; dir=$(session_dir "$name")
  # Persist RAM workspaces (/work) to the shared home and release their locks
  # before the instance goes, so another session can open them right away.
  if [ -f "$dir/ticket" ]; then
    (backend_attach "$name" -o BatchMode=yes -o ConnectTimeout=20 -- \
       'HOME=/home/agent; [ -d /work ] && ws close --all') 2>/dev/null \
      && echo "workspaces saved" >&2 || echo "yolo: could not save workspaces of $name" >&2
  fi
  datumctl delete workload "agent-$name" 2>&1 | tail -1 || true
  datumctl delete secret "agent-$name" 2>&1 | tail -1 || true
  rm -rf "$dir"
}
