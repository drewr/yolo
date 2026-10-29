# Port yolo from Haskell to Zig

## Context

yolo (`~/src/drewr/yolo`, `main` at `8ec99da`) is now one ~1750-line Haskell
file (`yolo`) run by runghc, plus a `flake.nix` that compiles it. The owner's
other tools are Zig (`~/src/drewr/zigutils`), and yolo should match them: same
toolchain, layout idioms and build. The goal is a Zig `yolo` that is a drop-in
replacement: same commands, flags, environment variables, session files and
Datum objects, so existing sessions and other machines keep working. The
Haskell file is deleted only after the Zig version passes the same checks.

This plan is written to be handed to other agents: shared context first, then
work packages with dependencies.

## Decisions (made)

- **Toolchain:** the yolo flake takes `zigutils` as an input and builds with its
  `packages.<system>.zig-dev` (0.18.0-dev.610+720939f8c today), so one Zig pin is
  bumped in one place. Risk: ziglang.org drops old dev tarballs (the dotfiles
  404), so a fresh machine can't build an old pin; bump zigutils when that hits.
- **Layout:** modules under `src/`, keeping zigutils' style inside each file
  (pure `pub` functions first, then an `// IO boundary` divider; tests in
  separate `*_test.zig` files).
- **No third-party Zig packages** (zigutils has none; no `build.zig.zon` unless
  one becomes unavoidable). std covers JSON, base64, Ed25519, processes, sockets.
- **No script mode.** The runghc `./yolo` goes away; development uses
  `zig build run -- ARGS` (inside `nix develop`), users use the flake package.

## Shared context for every agent

**Read first:**
- the Haskell `yolo` at `8ec99da`, which is the behavior spec;
- `zigutils/zig-0.16-migration.md`, the std API changes;
- zigutils' `build.zig`, `flake.nix` and `src/gitclone.zig`, the house style.

**House style (from zigutils):**
- `pub fn main(init: std.process.Init) !void { mainInner(init) catch std.process.exit(1); }`
  with `init.gpa`, `init.arena`, `init.io` and `init.environ_map`.
- Hand-rolled argument parsing.
- `std.debug.print` for stderr.
- `std.Io.File.stdout()` for stdout.
- `std.process.spawn` for children.
- `std.Io.Dir` for files.

Verify every std API against 0.18-dev; many changed after 0.15.

**Process rules (owner's standing constraints):**
- Work on a feature branch (`zig-port`), with SSH-signed commits; never push to
  `main` without the owner's say-so.
- Datum production only (`DATUM_SESSION=aaraines@gmail.com@api.datum.net`,
  project drewr-y4nd1b).
- Datum images are built on the EC2 build box, never locally. The port doesn't
  touch `image/`, so no image rebuild is expected.
- Clean up every test session you create. Never touch workloads you didn't
  create (birdhaus-store, todo-*, the owner's `foo`/`bar`).

**Compatibility invariants (must not change):**
- **CLI surface:**
  - Commands: `new`, `attach` (alias `ssh`), `ls [--full]`, `logs`, `rm`, `build`,
    `sync-pins`, `infra BOX CMD`, `version`/`--version`/`-V`, `help`.
  - Exit codes: usage → 2, error → 1, attach passes the remote exit code through.
  - Option parsing rules, including attach's ssh-style split (`-o/-L/-R/-D/-i`
    take a value; `--` or the first non-option starts the command).
- **Environment:**
  - `YOLO_*` with the `AGENT_SANDBOX_*` fallback (`opt`).
  - `YOLO_STATE`, `YOLO_ROOT`, `XDG_*`, `DATUM_SESSION`/`YOLO_DATUM_SESSION`.
  - `BUILDBOX_TICKET`/`BUILDBOX_PORT`, `AWS_PROFILE`, `TYPE`/`DISK_GB`/`IPV6`.
  - `SSH_PRIVATE_KEY[_FILE]`, `GIT_*`, `GITHUB_TOKEN`, `CONTAINER_RUNTIME`.
- **Session directory files** (names, formats, modes):
  - `backend`, `harness`, `class`, `workload`, `datum_session`, `runtime`
  - `iroh_secret` (hex+\n, 0600), `ticket`, `known_hosts`, `authorized_keys`
  - `host_key[.pub]`, `identity`, `ssh_key`, `ssh_key_mode`, `allowed_signers`
  - `agent/` (the relay socket dir)

  Check the Haskell for the current list (e.g. what the runtime record is
  called).
- **Derivations (byte-identical):**
  - the iroh ticket from the secret (`endpointTicket`: `00|pub|01 00 len|url`,
    lowercase RFC4648 base32 without padding, `endpoint` prefix);
  - the z-base-32 DNS label;
  - `known_hosts` lines.
- **Datum objects:**
  - Workload/Secret `yolo-NAME`, with `agent-NAME` read for old sessions.
  - The same Workload YAML fields (class caps, env, secretKeyRefs, labels
    `agent-sandbox`/`agent-harness`).
  - `ls` sync semantics (adopt, prune only the current login's sessions, no
    change when Datum is unreadable, skip name clashes).
- **Build state:**
  - `~/.local/state/agent-sandbox-build/{buildbox-ticket,logs/}`.
  - The `image/images*` file format and `pinImage` ordering.
  - `sync-pins` via `nix eval …#lib.dotfiles`.
- **Wrapper/runtime tools:**
  - dumbpipe, socat and buildctl come from nixpkgs on PATH.
  - datumctl, docker/podman/colima, ssh, ssh-keygen, ssh-add, aws, git and nix
    come from the host PATH.
  - Keep the Haskell's `findOrNix` fallback for runtimes.

**Std building blocks (verify names on 0.18):**
- **Keys:**
  - Ed25519 public key from the 32-byte seed:
    `std.crypto.sign.Ed25519.KeyPair.generateDeterministic(seed)`. It must equal
    crypton's `toPublic . secretKey`; the golden vectors prove it.
  - Random 32 bytes from the std/Io random source.
  - Hex via `std.fmt`; `std.base64.standard`.
- **JSON:** `std.json.parseFromSlice(std.json.Value, …)` plus a small `at(path)`
  helper, like Haskell `at`/`jstr`.
- **Processes:**
  - attach replaces the process: the 0.18 execve equivalent.
  - Timeouts (`ssh-add -L` 10 s, `buildctl debug workers` 30 s): spawn, wait with
    a deadline, kill.
- **Files:** create secrets with mode 0600 directly, instead of the Haskell's
  umask bracket.
- **Network:** TCP connect probe for the tunnel via `std.Io.net`; isatty for
  docker `-it`.

## Target layout (yolo repo)

```
build.zig        exe "yolo" from src/main.zig; test step; options module:
                 version (rev, date) and default_root (b.build_root) for dev builds
flake.nix        inputs: nixpkgs, zigutils (nixpkgs follows); packages.yolo/default,
                 apps.default, devShells.default (zig-dev + zls?); wrapper adds
                 dumbpipe/socat/buildctl to PATH, YOLO_ROOT=${self},
                 -Dversion from self.shortRev/dirtyShortRev + lastModifiedDate
src/main.zig     dispatch, usage text, version line, needCheckout
src/util.zig     env/opt/firstEnv, die, run helpers (quiet, capture, inherit, logged),
                 readMeta/trim/lastLine, table renderer, age, timing
src/json.zig     at/jstr/list/num over std.json.Value
src/session.zig  state dirs, name rule, create, localSessions, sessionBackend (adopt
                 hook), migrateAgentSandboxState, Backend tagged union
src/keys.zig     pure: hex, pubFromSecret, encode5/zbase32/base32, endpointTicket;
                 IO: authorizedKeys
src/datum.zig    config, new (pure YAML renderers), ssh argv (pure) + attach exec,
                 rm, logs, sync/adopt, table, shortImage
src/docker.zig   runtime choice/recording, new/attach (relay, key mode)/ls/logs/rm, build
src/infra.zig    boxes, aws wrapper (SSO-expired hint), launch/ticket/ipv6/start/stop/
                 status/terminate/tunnel, subnet64 (pure), buildbox ticket,
                 ensureBuildkit/withBuildkit
src/images.zig   buildDatum, pinImage, lastDigestRef, syncPins/lockedRev
src/*_test.zig   unit tests of the pure functions + golden vectors
tests/golden/    vectors produced by the Haskell before it is deleted
```

Backend dispatch: `const Backend = union(enum) { docker: Docker, datum: Datum }`
with `new/attach/ls/logs/rm` switching on the tag (replaces the Haskell record).

## Work packages

**WP0: foundation (one agent, first; everything else waits on it)**
1. Branch `zig-port`.
2. `build.zig`, `flake.nix` (zigutils input, zig-dev, the wrapper and version
   options above), and a `.gitignore` for `zig-out` and `.zig-cache`.
3. `util.zig`, `json.zig`, `session.zig`, `keys.zig`, and `main.zig` with
   dispatch and stub backends that `die "not ported yet"`.
4. Golden vectors from the Haskell, produced with
   `ghc -ignore-dot-ghci -x hs yolo -e EXPR` in its shebang's nix-shell:
   - 20 random iroh secrets → ticket and z32 label;
   - `subnet64` cases;
   - `shortImage`, `age` and `table` cases;
   - the Workload and Secret YAML for fixed inputs (factor the YAML
     builders so they can be called purely).

   Commit them under `tests/golden/`.
5. `zig build test` passes on the keys and session tests.
6. Done when `nix build .#yolo` works and `yolo version`, `yolo help` and `ls`
   (top table) run.

**WP1: datum backend (after WP0; parallel with WP2 and WP3)**
- `datum.zig`: new, attach (exec), logs, rm, sync/adopt, datum table, `--full`.
- Golden tests for the YAML and ssh argv.
- Live checks:
  - new/attach/rm of a `yolo-` session;
  - attach to an existing `agent-` session;
  - the `ls` sync scenarios in a scratch `YOLO_STATE` (adopt, prune, another
    login's session kept, Datum unreadable).

**WP2: docker backend (after WP0)**
- `docker.zig`, including the runtime selection and recording the owner added
  (podman → colima → docker, nixpkgs fallback), the relay, key-injection mode
  and `allowed_signers` copy.
- Live checks:
  - new with `-v` / attach (relay, exit-code passthrough) / ls / rm;
  - `SSH_PRIVATE_KEY_FILE` and `SSH_PRIVATE_KEY` modes.

**WP3: infra + image builds (after WP0)**
- `infra.zig` and `images.zig`.
- Pure tests for `subnet64`, `lastDigestRef` and `pinImage`.
- Live checks:
  - `infra buildbox|meta status`, `ticket`;
  - `build pi --backend datum` from a stopped box with the saved ticket moved
    aside; it should auto-start, fetch the ticket, and reproduce the pinned
    digest. Restore `image/images` if only the order changes.
- Don't run `launch`, `ipv6` or `terminate` without the owner.
- Note: `sync-pins` will want the dotfiles' newer nixpkgs. Don't commit image
  re-pins as part of the port.

**WP4: integration and cutover (one agent, after WP1–3)**
1. Run a side-by-side parity script: the old Haskell (`git show 8ec99da:yolo`)
   vs the Zig binary, on `help`, `version` shape, `ls`, `ls --full`, argument
   errors and exit codes.
2. Run the full live checklist below.
3. Delete the Haskell `yolo`.
4. `AGENTS.md`: replace "Language: Haskell" with Zig rules:
   - toolchain from zigutils;
   - the house style;
   - checks: `zig build test`, `nix build`, shellcheck for the in-image scripts.
5. `README.md`: requirements and dev workflow (`nix develop`, `zig build run --`).
6. Open a PR to `main`. Merge only on the owner's say-so.
7. Dotfiles follow-up for the owner: add `inputs.zigutils.follows = "zigutils"`
   to the yolo input, which needs the dotfiles' zigutils bumped past the Zig 404
   first. That bump is the owner's to make.

## Verification (definition of done)

1. **Static checks:**
   - `zig build test` (golden + unit) and
     `zig build -Doptimize=ReleaseSafe` succeed;
   - `nix build github:drewr/yolo/zig-port#yolo` succeeds;
   - the flake evaluates for x86_64-linux, aarch64-linux and aarch64-darwin;
   - `yolo version` shows the rev.
2. **Parity:** identical output from the Haskell and Zig versions for the parity
   script's commands.
3. **Live checks, with test sessions cleaned up afterwards:**
   - docker: lifecycle, key modes;
   - datum: new/attach/rm (`yolo-`), an old `agent-` session, adopt and `ls` sync
     scenarios;
   - `infra status`/`ticket`;
   - a cold-start `build pi` reproducing its pinned digest.
4. **Startup:** `time yolo ls` is at least as fast as the GHC binary (~10 ms
   without Datum).
