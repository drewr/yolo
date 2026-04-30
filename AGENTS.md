# Agent Instructions

This repository contains a container-based runtime (Docker or Podman) for running
Claude Code agents in an isolated environment with dangerous mode enabled.

## Commit Conventions

Use [Conventional Commits](https://www.conventionalcommits.org/en/v1.0.0-beta.2/):

```
<type>[optional scope]: <description>

[optional body]

[optional footer]
```

Common types: `feat`, `fix`, `chore`, `docs`, `refactor`, `ci`

## Running an Agent

```sh
./run -v /path/to/project:/workspace
```

Arguments before `--` are container flags; arguments after are passed to `claude`.
The image is always rebuilt on each invocation (layer cache keeps it fast).

## Key Files

| File | Purpose |
|------|---------|
| `run` | Builds image and starts container |
| `compose.yml` | Single-workspace shortcut via Docker Compose |
| `docker/Dockerfile` | Image definition (`node:22-slim` + `git` + `claude-code`) |
| `docker/settings.json` | Claude Code user settings baked into the image |
| `docker/claude-state.json` | Pre-seeded onboarding state; contains API key approval ID |
| `docker/entrypoint.sh` | Container entrypoint |

## Updating Settings

Edit `docker/settings.json` for Claude Code config (plugins, permissions, theme).
Edit `docker/claude-state.json` to update the onboarding state or API key approval.

If the API key is rotated, run the container once, answer the approval prompt, then:

```sh
docker exec $(docker ps -lq) cat /root/.claude.json
# or with podman:
podman exec $(podman ps -lq) cat /root/.claude.json
```

Copy the new `customApiKeyResponses.approved` value into `docker/claude-state.json`.
