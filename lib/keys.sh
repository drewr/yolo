# shellcheck shell=bash
# Keys and iroh tickets for sessions reached over iroh (the datum backend).
# Sourced by yolo; uses die from lib/session.sh.

dumbpipe_bin() {
  command -v dumbpipe 2>/dev/null && return
  echo "$(nix build --no-link --print-out-paths nixpkgs#dumbpipe)/bin/dumbpipe"
}

# iroh endpoint public key (hex) for a hex ed25519 secret on stdin.
endpoint_pubhex() {
  { printf '302e020100300506032b657004220420'; cat; } | xxd -r -p \
    | openssl pkey -inform DER -pubout -outform DER | tail -c 32 | xxd -p -c 64
}

# z-base-32 label for iroh's DNS discovery name _iroh.<label>.dns.iroh.link.
endpoint_z32() {
  local hex bits='' i n out='' alpha=ybndrfg8ejkmcpqxot1uwisza345h769
  hex=$(endpoint_pubhex)
  for ((i = 0; i < ${#hex}; i++)); do
    n=$((16#${hex:i:1}))
    bits+=$(( (n >> 3) & 1 ))$(( (n >> 2) & 1 ))$(( (n >> 1) & 1 ))$(( n & 1 ))
  done
  while (( ${#bits} % 5 )); do bits+='0'; done
  for ((i = 0; i < ${#bits}; i += 5)); do out+=${alpha:$((2#${bits:i:5})):1}; done
  echo "$out"
}

# An iroh endpoint ticket that carries the relay URL, so the client dials the
# relay directly instead of depending on DNS discovery, which instances have
# failed to publish to (docs/datum.md). Wire format, as decoded from dumbpipe
# tickets: 00 | pubkey(32) | n_addrs | 00 len url.
endpoint_ticket() {
  local relay=$1 urlhex
  urlhex=$(printf '%s' "$relay" | xxd -p -c 256)
  (( ${#relay} < 128 )) || die "relay URL too long"
  { printf '00%s0100%02x%s' "$(endpoint_pubhex)" "${#relay}" "$urlhex"; } | xxd -r -p \
    | base32 -w0 | tr '[:upper:]' '[:lower:]' | tr -d '=' | sed 's/^/endpoint/'
}

# Public keys to authorize: FILE if given, else the SSH agent's, else ~/.ssh/id_*.pub.
authorized_keys() {
  if [ -n "${1:-}" ]; then cat "$1"; return; fi
  if ssh-add -L 2>/dev/null | grep -q '^ssh-'; then ssh-add -L; return; fi
  for f in "$HOME"/.ssh/id_ed25519.pub "$HOME"/.ssh/id_ecdsa.pub "$HOME"/.ssh/id_rsa.pub; do
    [ -f "$f" ] && { cat "$f"; return; }
  done
  die "no public key: load one into ssh-agent or pass --key FILE"
}
