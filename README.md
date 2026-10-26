# yolo

Run coding agents in named, isolated sessions, either locally (Docker or
Podman) or on [Datum Compute](https://datum.net). Each session runs one
harness's image: `claude` (default), `gemini`, `codex`, `opencode` or `pi`.

```sh
yolo new work -v ~/src/app:/work/app       # local container (docker backend)
yolo attach work                           # zsh as drewr; run your agent
yolo new far --backend datum               # same image, on Datum Compute
yolo ls
yolo rm work
```

`yolo help` lists every command. After `yolo new`, each session remembers its
backend, so the other commands just take the name.

Datum sessions follow you between machines: Datum is the source of truth, and
local state is a cache. `yolo ls` sets up every Datum session that has none
here and drops local sessions whose workload is gone; `attach`, `logs` and
`rm` set up a session they don't know yet the same way. You still need a key
the session authorizes.

## Backends

| | docker | datum |
| - | - | - |
| Runs on | this machine, container `yolo-NAME` | Datum Compute, `us-east-1`; unikernel class, or `--class general-purpose` |
| Attach | `docker exec` | SSH over iroh, host key pinned; no inbound ports |
| HOME | `~/.local/share/yolo/home` on the host, shared by docker sessions | a JuiceFS home shared by all Datum sessions |
| Workspaces | `-v HOST:CONTAINER` at `new` | `ws clone/open/save/close` (repos in RAM, saved to the shared home) |
| Provider keys | `~/.config/yolo/providers.env` (KEY=value, 0600) | the Datum Secret `agent-providers` |
| SSH agent | relayed while attached; or an injected key (`SSH_PRIVATE_KEY_FILE`, needed for podman on macOS) | forwarded while attached |
| Images | `yolo/HARNESS:local`, built locally on first use | built on the EC2 build box, pinned in `image/images` (`image/images-general-purpose` for general-purpose) |

Choose the default backend with `YOLO_BACKEND=datum` (otherwise `docker`).

## Inside a session

The same image and init run on both backends:

- You log in as **`drewr`**, with zsh and the dotfiles' zsh config. On docker
  the user takes your host uid, so files in the home and the workspaces stay
  yours.
- **`nix`** works (`nix shell nixpkgs#tool`), with nixpkgs pinned to the
  images' revision.
- claude starts with **Remote Control** on. On docker it is seeded with the
  settings in `image/claude/`: dangerous mode, the rtk hook and the Datum
  plugins. Whether Datum sessions get the same settings is still open.
- `agent-providers` and `with-provider` wire providers such as TokenRouter and
  subconscious into the harnesses (`image/providers`).
- git over SSH uses your keys through the forwarded agent. Pass
  `GIT_NAME`, `GIT_EMAIL`, `GIT_SIGNING_KEY` and `GITHUB_TOKEN` (docker) to set
  identity and signing.

## Images

`image/flake.nix` builds one rootfs per harness from Nix: the harness from
llm-agents.nix plus a shared base. The llm-agents and nixpkgs revisions follow
the [dotfiles](https://github.com/drewr/dotfiles) through the flake's
`dotfiles` input (`yolo sync-pins`, run by every Datum build), and so does the
zsh config.

```sh
yolo build claude                         # docker: yolo/claude:local
yolo build claude codex --backend datum   # on the EC2 build box; updates image/images
yolo build claude --backend datum --class general-purpose   # updates image/images-general-purpose
nix flake update dotfiles --flake image   # follow newer dotfiles, then build
```

## Layout

| Path | What |
| - | - |
| `yolo` | the CLI, a Haskell script (sessions, both backends, image builds) |
| `flake.nix` | the compiled `yolo` |
| `image/` | image flake, Dockerfile, in-image scripts (init, `ws`, `agent-providers`), pinned Datum images |
| `infra/buildbox/ec2`, `infra/meta/ec2` | EC2 build box and JuiceFS metadata host (NixOS configs; `yolo infra`) |
| `docs/` | Datum details and the shared-home benchmarks |

## Requirements

- **Nix.** `yolo` is a runghc script whose shebang
  pulls GHC, their libraries, dumbpipe, socat and buildctl from a pinned
  nixpkgs: `./yolo` works from a checkout, but every command pays about 3 s of
  startup (30 s the first time). For everyday use, run the compiled one from
  the flake, which starts in milliseconds:

  ```sh
  nix profile install github:drewr/yolo   # or: nix build && ./result/bin/yolo
  ```

  `yolo version` says which build you're running: the commit and date it was
  compiled from (`-dirty` if from uncommitted changes), or for `./yolo` the
  checkout's commit. The compiled yolo reads the pins and Dockerfile from the
  source it was built from. `YOLO_ROOT=<checkout>` points it at a checkout instead; `yolo build
  --backend datum` and `yolo sync-pins` need one, since they rewrite `image/`.
- **docker backend:** Docker or Podman, on x86_64 or aarch64 (Apple Silicon).
- **datum backend:** `datumctl` signed in to Datum (production), `ssh`,
  `ssh-keygen` and `ssh-add`. Building Datum images needs the EC2 build box
  (`infra/buildbox/ec2`) and the `aws` CLI to manage it.
