# yolo

Run coding agents in named, isolated sessions, either locally (Docker or
Podman) or on [Datum Compute](https://datum.net). Each session runs one
harness's image: `claude` (default), `gemini`, `codex`, `opencode` or `pi`.

```sh
yolo new work -v ~/src/app:/work/app       # local container (docker backend)
yolo attach work                           # zsh as your user; run your agent
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
| Runs on | this machine, container `yolo-NAME` | Datum Compute, workload `yolo-NAME`, `us-east-1`; unikernel class, or `--class general-purpose` |
| Attach | `docker exec` | SSH over iroh, host key pinned; no inbound ports |
| HOME | `~/.local/share/yolo/home` on the host, shared by docker sessions | a JuiceFS home shared by all Datum sessions |
| Workspaces | `-v HOST:CONTAINER` at `new` | `ws clone/open/save/close` (repos in RAM, saved to the shared home) |
| Provider keys | `~/.config/yolo/providers.env` (KEY=value, 0600) | the Datum Secret `agent-providers` |
| SSH agent | relayed while attached; or an injected key (`YOLO_SSH_PRIVATE_KEY_FILE`, needed for podman on macOS) | forwarded while attached |
| Images | `yolo/HARNESS:local`, built locally on first use | built on the EC2 build box, pinned in `image/images` (`image/images-general-purpose` for general-purpose) |

Choose the default backend with `YOLO_BACKEND=datum` (otherwise `docker`).

## Inside a session

The same image and init run on both backends:

- You log in as **`YOLO_USER`** (default: your local user), with zsh and, if
  you set `YOLO_DOTFILES`, your dotfiles' zsh config. The image's own user is a
  placeholder that init renames to that name at boot. On docker the user takes
  your host uid, so files in the home and the workspaces stay yours.
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
llm-agents.nix plus a shared base. With `YOLO_DOTFILES` set to a flake
reference for your dotfiles (for example `github:OWNER/dotfiles`), the
llm-agents and nixpkgs revisions follow them through the flake's `dotfiles`
input (`yolo sync-pins`, run by every Datum build), and so does the zsh config
in the images. Without it the images have no zsh config and the lock keeps its
pins. `yolo build --backend datum` needs `YOLO_REGISTRY`.

```sh
yolo build claude                         # docker: yolo/claude:local
yolo build claude codex --backend datum   # on the EC2 build box; updates image/images
yolo build claude --backend datum --class general-purpose   # updates image/images-general-purpose
nix flake update dotfiles --flake image   # follow newer dotfiles, then build
```

## Configuration

Nothing about you is built in: your login name, Datum session, registry, AWS
profile and the like come from the environment or from
`$XDG_CONFIG_HOME/yolo/yolo.conf` (`~/.config/yolo/yolo.conf`). The order is:
an environment variable, then `yolo.conf`, then the built-in default. A
variable set to the empty string still counts as set.

`yolo.conf` has one `KEY=VALUE` per line. Blank lines and lines starting with
`#` are ignored; a `#` after whitespace starts a comment at the end of a line;
whitespace around the key and the value is trimmed; a value may be in single or
double quotes (nothing inside them is a comment); a leading `~/` is your home
directory. A line that isn't `KEY=VALUE` is reported and skipped. A missing
file is fine.

```sh
# ~/.config/yolo/yolo.conf
YOLO_BACKEND=datum
YOLO_REGISTRY=ghcr.io/OWNER              # required by yolo build
YOLO_DOTFILES=github:OWNER/dotfiles/REV  # optional; pin a rev, or builds follow the latest commit
YOLO_AWS_PROFILE=my-profile
```

Each `YOLO_NAME` also reads the older `AGENT_SANDBOX_NAME`. A name marked
(was X) still reads X too.

**General**

| Variable | Default |
| - | - |
| `YOLO_ROOT` | the source built into yolo; a checkout for `image/` |
| `YOLO_STATE` | `~/.local/state/yolo/sessions` |
| `YOLO_BACKEND` | `docker` |
| `YOLO_AGENT` | `claude` (`claude`, `gemini`, `codex`, `opencode`, `pi`) |
| `YOLO_USER` | your local user (`$USER`); the login user in sessions |
| `YOLO_FORWARD_AGENT` | `1`; `0` stops forwarding the SSH agent |

**Datum**

| Variable | Default |
| - | - |
| `YOLO_DATUM_SESSION` | datumctl's active session (`USER@ENDPOINT`); new sessions record the one they were made in |
| `YOLO_DATUM_PROJECT` | datumctl's active project (passed as `--project`); new sessions record the one they were made in |
| `YOLO_DATUM_PULL_SECRET` (was `YOLO_PULL_SECRET`) | none: no `imagePullSecrets`, so the images must be public |
| `YOLO_LOCATION` | `us-east-1` |
| `YOLO_NETWORK` | `default` |
| `YOLO_INSTANCE_TYPE` | `datumcloud/d1-standard-2` |
| `YOLO_CLASS` | `unikernel` (or `general-purpose`) |
| `YOLO_RELAY` | `https://use1-1.relay.n0.iroh.link./` |
| `YOLO_HOME_SECRET` | `agent-home` |
| `YOLO_PROVIDERS_SECRET` | `agent-providers` |
| `YOLO_JFS_OPTS` | none; extra `juicefs mount` options |
| `YOLO_IMAGE` | none; run this image instead of the pinned one |
| `YOLO_IMAGES`, `YOLO_GP_IMAGES` | `$YOLO_ROOT/image/images`, `image/images-general-purpose` |

**Docker**

| Variable | Default |
| - | - |
| `YOLO_DOCKER_HOME` | `~/.local/share/yolo/home` |
| `YOLO_PROVIDERS_ENV` | `~/.config/yolo/providers.env` |
| `YOLO_RUNTIME` | the first of podman, colima and docker that is up |
| `YOLO_SSH_PRIVATE_KEY` (was `SSH_PRIVATE_KEY`) | none; base64 private key for runtimes that can't relay the agent |
| `YOLO_SSH_PRIVATE_KEY_FILE` (was `SSH_PRIVATE_KEY_FILE`) | none; path of such a key |

**Image builds**

| Variable | Default |
| - | - |
| `YOLO_REGISTRY` (was `AGENT_IMAGE_REGISTRY`) | none; required by `yolo build --backend datum` (for example `ghcr.io/OWNER`) |
| `YOLO_DOTFILES` | none; a flake reference such as `github:OWNER/dotfiles` for the zsh config and pins |
| `YOLO_BUILDBOX_PORT` (was `BUILDBOX_PORT`) | `12340` |
| `YOLO_BUILDBOX_TICKET` (was `BUILDBOX_TICKET`) | none; read from the box over SSM |

**yolo infra**

| Variable | Default |
| - | - |
| `YOLO_AWS_PROFILE` | none: no `--profile`, so the AWS CLI's own lookup (it honors `AWS_PROFILE`) |
| `YOLO_INFRA_SOURCE` | `github:OWNER/REPO` from this checkout's `origin` remote; the flake the boxes fetch their config from |
| `YOLO_META_BUCKET` | none; required by `yolo infra meta launch` (the S3 bucket of the metadata backups) |
| `YOLO_INFRA_TYPE` (was `TYPE`) | per box |
| `YOLO_INFRA_DISK_GB` (was `DISK_GB`) | per box |
| `YOLO_INFRA_IPV6` (was `IPV6`) | per box (build box `0`, meta `1`) |

The meta box reads its bucket at run time from `/var/lib/agent-meta/bucket`,
which `yolo infra meta launch` writes from `YOLO_META_BUCKET`. A meta box
launched before that needs the file written once (over SSM), or its nightly
backup fails with a message saying so.

## Layout

| Path | What |
| - | - |
| `src/` | the Zig CLI: `main.zig` dispatch, one module per backend and concern |
| `build.zig`, `flake.nix` | the build; the flake pins `zigutils`' Zig and wraps the binary |
| `image/` | image flake, Dockerfile, in-image scripts (init, `ws`, `agent-providers`), pinned Datum images |
| `infra/buildbox/ec2`, `infra/meta/ec2` | EC2 build box and JuiceFS metadata host (NixOS configs; `yolo infra`) |
| `docs/` | Datum details and the shared-home benchmarks |

## Requirements

- **Nix.** `yolo` is built by the flake, with Zig pinned through `zigutils`:

  ```sh
  nix build                              # ./result/bin/yolo
  nix profile install github:drewr/yolo  # on PATH
  ```

  The wrapper adds `dumbpipe`, `socat` and `buildctl` to PATH and points
  `YOLO_ROOT` at the source it was built from. `yolo version` says which build
  you're running: the commit and date it was compiled from (`-dirty` if from
  uncommitted changes). `YOLO_ROOT=<checkout>` points it at a checkout instead;
  `yolo build --backend datum` and `yolo sync-pins` need one, since they rewrite
  `image/`.
- **Development:** `nix develop` gives the pinned `zig`, then `zig build` and
  `./zig-out/bin/yolo` (or `zig build run -- ARGS`); `zig build test` runs the
  unit and compatibility-vector tests. A bare `zig-out/bin/yolo` has no
  `dumbpipe`/`socat`/`buildctl` on PATH, so use `./result/bin/yolo` or
  `nix develop` for Datum sessions and builds.
- **docker backend:** Docker or Podman, on x86_64 or aarch64 (Apple Silicon).
- **datum backend:** `datumctl` signed in to Datum (production), `ssh`,
  `ssh-keygen` and `ssh-add`. Building Datum images needs the EC2 build box
  (`infra/buildbox/ec2`) and the `aws` CLI to manage it.
