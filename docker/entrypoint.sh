#!/bin/sh
git config --global user.name "${GIT_NAME:-agent}"
git config --global user.email "${GIT_EMAIL:-agent@localhost}"

if [ -n "$GIT_SIGNING_KEY" ]; then
  git config --global gpg.format ssh
  git config --global user.signingkey "$GIT_SIGNING_KEY"
  git config --global commit.gpgsign true
fi

exec claude --verbose "$@"
