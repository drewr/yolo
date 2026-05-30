# yolo

A Docker environment for running AI code agents in isolation with dangerous
mode enabled. Supports **Claude Code** and **Qwen Code** via a unified interface.

## Usage

```sh
./yolo -v /path/to/project:/workspace
```

The image rebuilds automatically on each invocation. Docker's layer cache keeps
this fast when nothing has changed.

### Selecting the agent runtime

Use `--runtime` to choose between Claude Code (default) and Qwen Code:

```sh
./yolo --runtime qwen -v /path/to/project:/workspace
```

### Passing arguments to the agent

To pass additional arguments to the agent, separate them with `--`:

```sh
./yolo -v /path/to/project:/workspace -- -p "refactor the auth module"
```

```sh
./yolo --runtime qwen -v /path/to/project:/workspace -- -p "rewrite the tests"
```

### Multiple mounts

Multiple mounts are supported:

```sh
./yolo \
  -v /path/to/project:/workspace \
  -v /path/to/lib:/workspace/lib:ro \
  -- -p "update the integration"
```

## Requirements

### Claude Code (`--runtime claude`)

- Docker or Podman
- Standard environment:
    - `ANTHROPIC_API_KEY`
    - `GITHUB_TOKEN`
    - `GIT_NAME`
    - `GIT_EMAIL`

### Qwen Code (`--runtime qwen`)

- Docker or Podman
- Environment:
    - `QWEN_API_KEY`
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

## Docker Compose

Run with Docker Compose (Claude Code, default):

```sh
WORKSPACE=/path/to/project docker compose up
```

Run with Qwen Code:

```sh
WORKSPACE=/path/to/project docker compose -f compose.qwen.yml up
```

## Key Files

| File | Purpose |
|------|---------|
| `yolo` | Builds image and starts container |
| `compose.yml` | Claude Code via Docker Compose |
| `compose.qwen.yml` | Qwen Code via Docker Compose |
| `docker/Dockerfile.claude` | Claude Code image definition |
| `docker/Dockerfile.qwen` | Qwen Code image definition |
| `docker/settings.json` | Claude Code user settings |
| `docker/claude-state.json` | Claude Code pre-seeded onboarding state |
| `docker/qwen-settings.json` | Qwen Code user settings |
| `docker/qwen-state.json` | Qwen Code pre-seeded onboarding state |
| `docker/entrypoint.sh` | Container entrypoint (runtime-aware) |
