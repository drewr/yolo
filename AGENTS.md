# Agent Instructions

yolo runs coding agents in named, isolated sessions on two backends: local
containers (podman, colima or docker) and Datum Compute. See README.md for usage.

## Commit Conventions

Use [Conventional Commits](https://www.conventionalcommits.org/en/v1.0.0-beta.2/):

```
<type>[optional scope]: <description>

[optional body]

[optional footer]
```

Common types: `feat`, `fix`, `chore`, `docs`, `refactor`, `ci`

## Language: Zig

The CLI is Zig, built with `zigutils`' `zig-dev` pin (the flake's
`packages.<system>.zig-dev`), so the compiler is bumped in one place. Write new
host-side tooling in Zig, in the style of the modules in `src/` (after
drewr/zigutils):

- One module per concern under `src/` (`util`, `json`, `session`, `keys`,
  `datum`, `docker`, `infra`, `images`), with `main.zig` holding dispatch, the
  usage text and the `Backend` union. A new backend is a new arm of the union
  plus its name in `loadBackend`.
- In each file: pure `pub` functions first, then an `// IO boundary` divider,
  then the IO. Tests are `test` blocks next to the code; golden vectors (from
  the Haskell version this ports) are in `src/golden/vectors.txt`.
- Hand-rolled argument parsing where commands pass arguments through (like
  `yolo attach`). `std.process.spawn` for children, `std.Io.Dir` for files,
  `std.Io.File.stdout()` for output. Prefer `std` to a third-party package; the
  repo has no `build.zig.zon`.
- `Ctx` (`util.zig`) carries the `io`, the allocators and the environment.
  Use `util.say`/`sayf`/`errPrint` for output, `util.die` for errors, and
  `util.capture`/`quiet`/`inherit`/`replace` for children.
- Interactive commands (`attach`) inherit the terminal (`util.inherit`) or
  replace the process (`util.replace`, execve).
- `nix develop` gives the pinned `zig`; then `zig build` and
  `./zig-out/bin/yolo`, or `zig build run -- ARGS`. The flake wrapper adds
  `dumbpipe`, `socat` and `buildctl` to PATH and points `YOLO_ROOT` at its
  read-only source; a bare `zig-out/bin/yolo` lacks those tools. Commands that
  write to `image/` refuse the store copy.
- Tools that aren't in nixpkgs or must be the host's own (datumctl,
  docker/podman/colima, ssh, ssh-keygen, ssh-add, aws, nix, git) come from
  PATH; say so in the module's header comment.

Not everything moves: the scripts inside the image (`image/init.sh`, `ws`,
`agent-providers`, `nix-zsh-env`) stay POSIX sh. The image has no Zig
toolchain, init is PID 1 on a unikernel whose execve does no PATH search, and
on that class the whole image lives in RAM.

## Structure

- `src/`: the CLI. Sessions are directories under `$YOLO_STATE`; `main.zig`'s
  `Backend` union (`new`, `attach`, `ls`, `logs`, `rm`) has an arm per backend,
  and `loadBackend` maps a name to one. `images.zig` holds the Datum image
  builds and `yolo sync-pins`.
- `yolo infra BOX ...`: the EC2 build box and the JuiceFS metadata host;
  `yolo build --backend datum` starts the build box when BuildKit doesn't
  answer, and reads its ticket over SSM when none is saved.
- `image/init.sh` is PID 1 in every image. `YOLO_MODE=datum` (the default)
  serves SSH over iroh and mounts the shared home; `YOLO_MODE=local` sets up
  the same user and environment and idles for `docker exec`.
- Paths in init are inside the sandbox. The one host path it touches is the
  top of the docker backend's bind-mounted home, and only to hand it back to
  the host user.
- Session files are an interface: sessions made by an older yolo must keep
  working (`iroh_secret`, `ticket`, `known_hosts`, `class`, ...).

## Checks

Before committing:

- `nix build` must succeed: it builds `yolo` with `ReleaseSafe` and runs the
  tests in its check phase.
- `zig build test` (unit + golden) and `zig build -Doptimize=ReleaseSafe` must
  succeed in `nix develop`, and `zig fmt --check src build.zig` must be clean.
- Run what you changed for real (`yolo new`/`attach`/`rm` on each backend you
  touched).
- shellcheck the in-image scripts:
  `nix run nixpkgs#shellcheck -- -x image/init.sh image/ws image/agent-providers image/nix-zsh-env`

Image changes must evaluate for both systems
(`nix eval --raw ./image#packages.x86_64-linux.claude.drvPath`, and
`aarch64-linux`). Datum images are built on the EC2 build box, never locally.
Rebuild every harness image for both classes after changing anything in
`image/` (`yolo build HARNESS... --backend datum`, then again with
`--class general-purpose`), and commit the new digests in `image/images` and
`image/images-general-purpose` together with the change.

## Claude settings (docker backend)

`image/claude/settings.json` and `claude-state.json` seed a docker session's
home when it has none. If the API key is rotated, attach to a session, answer
the approval prompt, then copy the new `customApiKeyResponses.approved` value
from `~/.claude.json` into `image/claude/claude-state.json`.
