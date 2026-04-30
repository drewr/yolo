# yolo

A Docker environment for running Claude Code agents in isolation with dangerous
mode enabled. Mount a local directory and the agent operates freely within it,
with no permission prompts.

## Usage

```sh
./yolo -v /path/to/project:/workspace
```

The image rebuilds automatically on each invocation. Docker's layer cache keeps
this fast when nothing has changed.

To pass additional arguments to `claude`, separate them with `--`:

```sh
./yolo -v /path/to/project:/workspace -- -p "refactor the auth module"
```

Multiple mounts are supported:

```sh
./yolo \
  -v /path/to/project:/workspace \
  -v /path/to/lib:/workspace/lib:ro \
  -- -p "update the integration"
```

## Requirements

- Docker or Podman
- Standard environment:
    - `ANTHROPIC_API_KEY`
    - `GITHUB_TOKEN`
    - `GIT_NAME`
    - `GIT_EMAIL`

## SSH Commit Signing

Set `GIT_SIGNING_KEY` to your public key literal and ensure `SSH_AUTH_SOCK` is
set. The run script forwards the agent socket into the container automatically.

```sh
export GIT_SIGNING_KEY="key::ssh-ed25519 AAAA..."
./yolo -v /path/to/project:/workspace
```
