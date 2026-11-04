# System Patterns

## High-level architecture

yolo is a single Zig CLI (`src/`) plus an image pipeline (`image/`) and NixOS
configs (`infra/`):

```
src/main.zig      dispatch: usage text, Backend union (new/attach/ls/logs/rm arms)
src/<module>.zig  one module per concern (see below)
image/            session-image flake + Dockerfile + in-image scripts
infra/            NixOS configs for the EC2 build box and JuiceFS metadata host
```

## Key patterns

- **One module per concern** (`util`, `json`, `session`, `keys`, `datum`,
  `docker`, `infra`, `images`); a new backend is a new arm of `main.zig`'s
  `Backend` union plus its name in `loadBackend`.
- **Pure-first module layout:** pure `pub` functions, then an
  `// IO boundary` divider, then the IO. Tests are inline `test` blocks;
  golden vectors (from the Haskell version) live in `src/golden/vectors.txt`.
- **`Ctx` dependency injection:** `util.zig`'s `Ctx` carries the `io`, the
  allocators and the environment; output via `util.say`/`sayf`/`errPrint`,
  errors via `util.die`, child processes via `util.capture`/`quiet`/`inherit`/
  `replace`.
- **Session dirs as a durable interface:** each session is a directory under
  `$YOLO_STATE` with files an older yolo must still honor.
- **Same image, both backends:** `image/init.sh` is PID 1 everywhere.
  `YOLO_MODE=datum` serves SSH over iroh and mounts the shared home;
  `YOLO_MODE=local` sets up the user and idles for `docker exec`.
- **Wrap, don't rebuild:** the release binary is a flake wrapper that puts
  `dumbpipe`, `socat`, `buildctl` on PATH and points `YOLO_ROOT` at its source.
- Host-side modules say which tools come from outside (datumctl, docker,
  ssh, nix, git, ...); tools available in nixpkgs are assumed inside the flake.

## Component relationships

- `session.zig` is the shared core both backends build on: it maps a session
  name to its state directory and owns discovery/attach logic.
- `docker.zig` and `datum.zig` are the two backend implementations; `datum.zig`
  depends on `keys.zig` (session keys), `json.zig` (API payloads) and
  `infra.zig` (build box / metadata host lifecycle via `yolo infra`).
- `images.zig` only really matters to the datum backend: it drives image builds
  on the EC2 build box and syncs the pinned digests in `image/images`.
- `image/` is consumed by both backends at runtime; changing it means
  rebuilding every harness image for both classes.

## Not yet established

Nothing further — the port plans in `docs/` (`zig-port-plan.md`,
`aws-ec2-backend-plan.md`) are the record of decisions already made.
