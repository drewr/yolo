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

## Language: Haskell, run as Nix scripts

Write new host-side tooling in Haskell, in the style of `yolo` and
its `flake.nix` (after drewr/birdhaus `run.hs`):

- An executable file with a `nix-shell` shebang that runs it with `runghc`:

  ```haskell
  #!/usr/bin/env nix-shell
  #! nix-shell -i runghc -I nixpkgs=https://github.com/NixOS/nixpkgs/archive/<rev>.tar.gz
  #! nix-shell -p "haskellPackages.ghcWithPackages (pkgs: with pkgs; [ aeson ... ])"
  #! nix-shell -p dumbpipe ...
  ```

- Pin nixpkgs with `-I` to the rev in `image/flake.lock`, so GHC and the
  libraries come from cache.nixos.org and don't change under you. Bump all
  scripts' pins together, along with `flake.nix`'s nixpkgs.
- `flake.nix` compiles `yolo` (`nix build`): keep its Haskell package list and
  tools the same as the shebang's. The binary finds the repository through
  `YOLO_ROOT`, which its wrapper defaults to the flake's source; commands that
  write to `image/` refuse to run against that read-only copy.
- Tools from nixpkgs go in the shebang's `-p`. Tools that aren't in nixpkgs or
  must be the host's own (datumctl, docker/podman, ssh, aws, nix, git) come
  from PATH; say so in the header comment.
- One self-contained file per tool: runghc can't find sibling modules from a
  script run through a symlink. When a script needs its repository, take its
  own path from Template Haskell (`location`), as `yoloRoot` does.
- Plain `base`, `directory`, `process` and `filepath` for most things; argument
  parsing by hand where commands pass arguments through (like `yolo attach`).
  Use `aeson` for JSON instead of jq, and Haskell instead of awk, sed or python.
- Interactive commands (`attach`) inherit the terminal: `rawSystem`, or
  `executeFile` to replace the process.

Not everything moves: the scripts inside the image (`image/init.sh`, `ws`,
`agent-providers`, `nix-zsh-env`) stay POSIX sh. The image has no GHC, init is
PID 1 on a unikernel whose execve does no PATH search, and on that class the
whole image lives in RAM.

## Structure

- `yolo`: the CLI. Sessions are directories under `$YOLO_STATE`; a `Backend`
  record (`bNew`, `bAttach`, `bLs`, `bLogs`, `bRm`) per backend. A new backend
  is a new `Backend` value plus its name in `loadBackend`. `yolo build` also
  holds the Datum image builds and `yolo sync-pins`.
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

There are no tests. Before committing:

- `nix build` must succeed (it compiles `yolo` with `-O`).
- Type-check each Haskell script with `-Wall`, using the shebang's packages,
  and fix every warning:

  ```sh
  nix-shell -I nixpkgs=<the shebang's URL> -p "<the shebang's ghcWithPackages>" \
    --run "ghc -Wall -fno-code -x hs yolo -outputdir \$(mktemp -d)"
  ```

  To call one function directly, use
  `ghc -ignore-dot-ghci -x hs yolo -e 'EXPR'` in the same shell.
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
