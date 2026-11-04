# Technical Context

## Stack

- **Language:** Zig (0.15.x-era std, as pinned through `drewr/zigutils`'s
  `zig-dev` package — the compiler is bumped in one place, the flake).
- **Build/packaging:** Nix flake (`flake.nix`) producing the wrapped release
  binary; `zig build` inside `nix develop` for day-to-day work. No
  `build.zig.zon` — no third-party Zig packages; `std` only.
- **Session images:** `image/flake.nix` builds one rootfs per harness from
  Nix (harness + shared base); a Dockerfile wraps it for the docker backend.
- **Session language:** POSIX sh for everything that runs inside an image
  (`image/init.sh`, `ws`, `agent-providers`, `nix-zsh-env`). No Zig in-image.
- **Infra:** NixOS configs under `infra/*/ec2` for the EC2 build box and the
  JuiceFS metadata host.

## Key dependencies (all external tools)

- `zigutils` (drewr) — pinned Zig toolchain.
- `dotfiles` (drewr, flake input) — supplies the zsh config and the upstream
  revisions (llm-agents.nix, nixpkgs) that the images follow
  (`yolo sync-pins` runs on every Datum build).
- Host tools used via PATH, not vendored: `datumctl`, `docker`/`podman`/
  `colima`, `ssh`, `ssh-keygen`, `ssh-add`, `aws`, `nix`, `git`.
- Session-side plumbing: `iroh` (SSH transport), `socat`, `buildctl`
  (BuildKit), `dumbpipe`.

## Dev setup

```sh
nix develop                # pinned zig on PATH
zig build                  # ./zig-out/bin/yolo
zig build run -- ARGS      # build+run
zig build test             # unit tests + golden vectors
nix build                  # the wrapped release binary: ./result/bin/yolo
```

- A bare `zig-out/bin/yolo` lacks `dumbpipe`/`socat`/`buildctl`; use nix for
  anything Datum. Commands that write to `image/` refuse the flake's read-only
  store copy — set `YOLO_ROOT=<checkout>` or run from a checkout.

## Constraints

- **Compiler pin:** newer Zig comes from a `zigutils` bump, not a local
  version bump; don't add a `build.zig.zon`.
- **Image rebuilds are heavy and remote:** any change under `image/` must
  evaluate for `x86_64-linux` and `aarch64-linux`, then rebuild every harness
  image for both classes on the EC2 build box (never locally), committing new
  digests in `image/images` and `image/images-general-purpose`.
- **Session-dir compatibility:** files like `iroh_secret`, `ticket`,
  `known_hosts`, `class` are read by older versions; don't remove or rename.
- **Both backends stay behaviorally equal** — a feature added to one image
  path applies to `YOLO_MODE=datum` and `YOLO_MODE=local` alike.
- **Shellcheck gate:** the in-image POSIX sh scripts are linted with
  `nix run nixpkgs#shellcheck` before commit.
- Platform: Linux + macOS (aarch64) hosts for the docker backend; Datum
  sessions run in `us-east-1`.
