# Agent Instructions

This repository contains a container-based runtime (Docker or Podman) for running
AI code agents in an isolated environment with dangerous mode enabled.

## Commit Conventions

Use [Conventional Commits](https://www.conventionalcommits.org/en/v1.0.0-beta.2/):

```
<type>[optional scope]: <description>

[optional body]

[optional footer]
```

Common types: `feat`, `fix`, `chore`, `docs`, `refactor`, `ci`

## Running an Agent

Claude Code (default):
```sh
./yolo -v /path/to/project:/workspace
```

Qwen Code:
```sh
./yolo --runtime qwen -v /path/to/project:/workspace
```

Arguments before `--` are container flags; arguments after are passed to the agent.
The image is always rebuilt on each invocation (layer cache keeps it fast).

## Key Files

| File | Purpose |
|------|---------|
| `yolo` | Builds image and starts container |
| `compose.yml` | Single-workspace Claude Code via Docker Compose |
| `compose.qwen.yml` | Single-workspace Qwen Code via Docker Compose |
| `docker/Dockerfile.claude` | Claude Code image definition |
| `docker/Dockerfile.qwen` | Qwen Code image definition |
| `docker/settings.json` | Claude Code user settings baked into the image |
| `docker/claude-state.json` | Pre-seeded Claude Code onboarding state |
| `docker/qwen-settings.json` | Qwen Code user settings |
| `docker/qwen-state.json` | Pre-seeded Qwen Code onboarding state |
| `docker/entrypoint.sh` | Container entrypoint (runtime-aware) |

## Updating Settings

Edit `docker/settings.json` for Claude Code config (plugins, permissions, theme).
Edit `docker/qwen-settings.json` for Qwen Code config.
Edit `docker/claude-state.json` to update the Claude Code onboarding state or API key approval.
Edit `docker/qwen-state.json` to update the Qwen Code onboarding state.

If the API key is rotated, run the container once, answer the approval prompt, then:

```sh
docker exec $(docker ps -lq) cat /root/.claude.json
# or with podman:
podman exec $(podman ps -lq) cat /root/.claude.json
```

Copy the new `customApiKeyResponses.approved` value into `docker/claude-state.json`.
