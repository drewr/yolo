#!/bin/sh
set -e

IMAGE="${IMAGE:-datum-claude-code}"
WORKSPACE="${WORKSPACE:-$(pwd)}"

SSH_AGENT_ARGS=""
if [ -n "${SSH_AUTH_SOCK:-}" ]; then
  SSH_AGENT_ARGS="-v ${SSH_AUTH_SOCK}:/tmp/ssh-agent -e SSH_AUTH_SOCK=/tmp/ssh-agent"
fi

SSH_SIGNERS_ARGS=""
if [ -f "${HOME}/.ssh/allowed_signers" ]; then
  SSH_SIGNERS_ARGS="-v ${HOME}/.ssh/allowed_signers:/root/.ssh/allowed_signers:ro"
fi

exec docker run --rm -it \
  -v "${WORKSPACE}:/workspace" \
  -e GIT_NAME="${GIT_NAME:-}" \
  -e GIT_EMAIL="${GIT_EMAIL:-}" \
  -e GIT_SIGNING_KEY="${GIT_SIGNING_KEY:-}" \
  -e HOST_UID="$(id -u)" \
  -e HOST_GID="$(id -g)" \
  $SSH_AGENT_ARGS \
  $SSH_SIGNERS_ARGS \
  "${IMAGE}" "$@"
