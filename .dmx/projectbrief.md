# Project Brief

## Project

**yolo** — a CLI that runs coding agents in named, isolated sessions on two
backends: local containers (podman, colima, docker) and Datum Compute. Each
session runs one harness's image: `claude` (default), `gemini`, `codex`,
`opencode` or `pi`.

## Primary goals

- Give every coding-agent session a clean, named, reproducible environment —
  one harness image, isolated home, isolated workspaces.
- Make the same experience work locally and on Datum Compute; Datum is the
  source of truth and local state is a cache, so sessions follow you between
  machines.
- Keep the whole stack buildable and pinned by Nix: the CLI itself, the
  session images, and the EC2 infrastructure boxes.

## Scope

**Part of this codebase:**

- `src/` — the Zig CLI (currently the port of an earlier Haskell version).
- `build.zig`, `flake.nix` — the build; the flake pins Zig through `zigutils`
  and wraps the binary for release use.
- `image/` — the session-image flake, Dockerfile, in-image POSIX sh scripts,
  and the pinned Datum image digests.
- `infra/buildbox/ec2`, `infra/meta/ec2` — NixOS configs for the EC2 build box
  and JuiceFS metadata host.

**Not part of this codebase:**

- `drewr/zigutils` and the `drewr/dotfiles` (both consumed as flake inputs).
- The Datum platform itself; yolo is a client of its APIs.
- Anything about a specific user's dotfiles inside the image — those arrive
  through the `dotfiles` flake input, not this repo.

## Requirements

- `nix build` alone must be enough to produce a working `yolo` for end users
  (`./result/bin/yolo` or `nix profile install github:drewr/yolo`).
- Session directories made by older yolo versions must keep working;
  the files in a session dir are an interface
  (`iroh_secret`, `ticket`, `known_hosts`, `class`, ...).
- The docker and datum backends run the same image and the same PID 1
  (`image/init.sh`), so behavior inside a session does not depend on backend.
