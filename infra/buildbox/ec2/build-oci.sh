#!/usr/bin/env bash
# Client side: build a standard linux/amd64 OCI image on the EC2 build box's
# BuildKit, over iroh, and push it. For Datum's general-purpose runtime class,
# which runs ordinary container images; build.sh makes unikernel images.
#
#   BUILDBOX_TICKET=<ticket> infra/buildbox/ec2/build-oci.sh image ghcr.io/drewr/agent-pi:gp-dev \
#       --opt build-arg:HARNESS=pi   # extra arguments go to buildctl build
#
# Prints IMAGE@sha256:DIGEST last. Needs dumbpipe and buildctl (from nixpkgs if
# missing); pushes with your registry login (~/.docker/config.json).
set -euo pipefail
ctx=${1:?usage: build-oci.sh CONTEXT IMAGE [BUILDCTL-ARGS...]}
image=${2:?usage: build-oci.sh CONTEXT IMAGE [BUILDCTL-ARGS...]}
shift 2
: "${BUILDBOX_TICKET:?set BUILDBOX_TICKET (infra/buildbox/ec2/provision.sh ticket)}"
port=${BUILDBOX_PORT:-12340}
buildctl=$(command -v buildctl || echo "$(nix build --no-link --print-out-paths nixpkgs#buildkit)/bin/buildctl")

dumbpipe connect-tcp --addr "127.0.0.1:$port" "$BUILDBOX_TICKET" &
pipe=$!
meta=$(mktemp)
trap 'kill $pipe 2>/dev/null; rm -f "$meta"' EXIT
for _ in $(seq 30); do
  (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null && break
  sleep 1
done

"$buildctl" --addr "tcp://127.0.0.1:$port" build --progress plain \
  --frontend dockerfile.v0 --local context="$ctx" --local dockerfile="$ctx" \
  --opt platform=linux/amd64 \
  --output "type=image,name=$image,push=true" --metadata-file "$meta" "$@"
digest=$(jq -r '."containerimage.digest"' "$meta")
echo "${image%:*}@$digest"
