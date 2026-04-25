# agent-runtime

A Docker environment for running Claude Code agents in isolation with dangerous
mode enabled. Mount a local directory and the agent operates freely within it,
with no permission prompts.

## Usage

```sh
./run -v /path/to/project:/workspace
```

The image rebuilds automatically on each invocation. Docker's layer cache keeps
this fast when nothing has changed.

To pass additional arguments to `claude`, separate them with `--`:

```sh
./run -v /path/to/project:/workspace -- -p "refactor the auth module"
```

Multiple mounts are supported:

```sh
./run \
  -v /path/to/project:/workspace \
  -v /path/to/lib:/workspace/lib:ro \
  -- -p "update the integration"
```

## Requirements

- Docker
- `ANTHROPIC_API_KEY` set in the environment
- `GIT_NAME` and `GIT_EMAIL` set in the environment

## SSH Commit Signing

Set `GIT_SIGNING_KEY` to your public key literal and ensure `SSH_AUTH_SOCK` is
set. The run script forwards the agent socket into the container automatically.

```sh
export GIT_SIGNING_KEY="key::ssh-ed25519 AAAA..."
./run -v /path/to/project:/workspace
```
