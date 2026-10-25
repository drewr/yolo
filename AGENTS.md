# Agent Instructions

yolo runs coding agents in named, isolated sessions on two backends: local
containers (docker or podman) and Datum Compute. See README.md for usage.

## Commit Conventions

Use [Conventional Commits](https://www.conventionalcommits.org/en/v1.0.0-beta.2/):

```
<type>[optional scope]: <description>

[optional body]

[optional footer]
```

Common types: `feat`, `fix`, `chore`, `docs`, `refactor`, `ci`

## Structure

- `yolo` sources `lib/session.sh` and `lib/keys.sh`, then one backend.
- Each backend implements `backend_new NAME HARNESS [opts]`,
  `backend_attach NAME [args]`, `backend_ls`, `backend_logs NAME [args]` and
  `backend_rm NAME`. A new backend is a new `backends/NAME.sh` plus its name in
  `load_backend`.
- `image/init.sh` is PID 1 in every image. `YOLO_MODE=datum` (the default)
  serves SSH over iroh and mounts the shared home; `YOLO_MODE=local` sets up
  the same user and environment and idles for `docker exec`.
- Paths in init are inside the sandbox. The one host path it touches is the
  top of the docker backend's bind-mounted home, and only to hand it back to
  the host user.

## Checks

There are no tests. Before committing, run shellcheck on every script:

```sh
nix run nixpkgs#shellcheck -- -x yolo lib/*.sh backends/*.sh \
  image/init.sh image/ws image/agent-providers image/build-image image/sync-pins \
  image/nix-zsh-env infra/*/ec2/*.sh
```

Image changes must evaluate (`nix eval --raw ./image#claude.drvPath`). Datum
images are built on the EC2 build box, never locally. Rebuild every harness
image after changing anything in `image/`, and commit the new digests in
`image/images` together with the change.

## Claude settings (docker backend)

`image/claude/settings.json` and `claude-state.json` seed a docker session's
home when it has none. If the API key is rotated, attach to a session, answer
the approval prompt, then copy the new `customApiKeyResponses.approved` value
from `~/.claude.json` into `image/claude/claude-state.json`.
