#!/bin/sh
mkdir -p /root/.ssh
ssh-keyscan github.com >> /root/.ssh/known_hosts 2>/dev/null

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

npm install -g @anthropic-ai/claude-code@latest --silent 2>/dev/null

CLAUDE_VERSION=$(claude --version 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
sed -i "s/\"lastOnboardingVersion\": \"[^\"]*\"/\"lastOnboardingVersion\": \"$CLAUDE_VERSION\"/" /root/.claude.json

claude --verbose "$@"
