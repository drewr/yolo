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
`dotfiles` input (`image/sync-pins`), and so does the zsh config.

```sh
yolo build claude                         # docker: yolo/claude:local
yolo build claude codex --backend datum   # on the EC2 build box; updates image/images
yolo build claude --backend datum --class general-purpose   # updates image/images-general-purpose
nix flake update dotfiles --flake image   # follow newer dotfiles, then build
```

## Layout

| Path | What |
| - | - |
| `yolo` | CLI; dispatches to the session's backend |
| `lib/` | session state and iroh/SSH key helpers |
| `backends/docker.sh`, `backends/datum.sh` | the two backends |
| `image/` | image flake, Dockerfile, init, `ws`, `agent-providers`, pinned Datum images |
| `infra/buildbox/ec2`, `infra/meta/ec2` | EC2 build box and JuiceFS metadata host (NixOS) |
| `docs/` | Datum details and the shared-home benchmarks |

## Requirements

- **docker backend:** Docker or Podman, on x86_64 or aarch64 (Apple Silicon).
- **datum backend:** `datumctl` signed in to Datum (production), plus `ssh`,
  `ssh-keygen`, `openssl`, `jq`, `xxd` and `base32`. `dumbpipe` comes from
  nixpkgs if missing. Building Datum images needs the EC2 build box
  (`infra/buildbox/ec2`).
