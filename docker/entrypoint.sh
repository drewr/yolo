#!/bin/sh
git config --global user.name "${GIT_NAME:-agent}"
git config --global user.email "${GIT_EMAIL:-agent@localhost}"
git config --global --add safe.directory /workspace

if [ -n "$GIT_SIGNING_KEY" ]; then
  git config --global gpg.format ssh
  git config --global user.signingkey "$GIT_SIGNING_KEY"
  git config --global commit.gpgsign true
fi

if [ -n "${HOST_UID:-}" ] && [ -n "${HOST_GID:-}" ]; then
  trap 'chown -R "$HOST_UID:$HOST_GID" /workspace /root/.claude/projects' EXIT
fi

claude --verbose "$@"
