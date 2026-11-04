# Product Context

## Why this exists

Coding agents (claude, gemini, codex, opencode, pi) are only useful in a real,
promptable environment. Running them ad-hoc pollutes the developer's machine
and gives no isolation between pieces of work. yolo solves that by giving every
piece of work its own named session: a container or a Datum Compute workload
running a pinned harness image.

## How it works

```sh
yolo new work -v ~/src/app:/work/app       # local container (docker backend)
yolo attach work                           # zsh as drewr; run your agent
yolo new far --backend datum               # same image, on Datum Compute
yolo ls / logs / rm work
```

- **Sessions are named and remembered.** State lives in directories under
  `$YOLO_STATE`; after `yolo new`, every other command just takes the name.
- **Docker backend** runs a local container (`yolo-NAME`) that you enter with
  `docker exec`; the shared home is `~/.local/share/yolo/home` on the host.
- **Datum backend** creates a workload `yolo-NAME` in `us-east-1` (default
  unikernel class, `--class general-purpose` for more), attached over SSH
  tunneled through iroh — no inbound ports, host key pinned.
- **Datum sessions travel:** the shared JuiceFS home holds them. `yolo ls` sets
  up every Datum session that has no local state and drops local sessions whose
  workload is gone; `attach`, `logs` and `rm` can also discover a session.

## Who uses it

- Its developer (drewr) as the primary user — a personal tool that grew into a
  product-shaped project.
- Anyone on the same machine pattern: developers who run coding agents inside
  disposable sandboxes but want the sandbox to look and feel like their own
  machine (their uid, their zsh config, working nix).
