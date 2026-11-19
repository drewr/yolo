# Plan: a jump host that holds keys and SSH connections, on any backend

**Branch:** feature-jump-box, on top of fix-hardcoded-identity

## Context

A jump host is a long-lived instance that does these things:

- It holds SSH private keys in memory so that a phone or laptop doesn't have to maintain a forwarded ssh agent.
- It keeps `ssh -A` connections to agent sandboxes launched on Datum and other clouds, as well as existing hosts which could be VMs or bare metal machines launched apart from yolo.
- It reconnects to sandboxes after the jump host reboots, or after a sandbox loses connection.

All of its configuration and secrets live in the cloud, so the host has zero dependency on the client that created it.

**Scope.** One client logs in to the box, without forwarding its own agent, and the box connects out to many hosts. What the box must do well is hold keys, hold connections, and bring both back after a restart. Sandboxes reach API services through the credential broker on the box, so they never hold the tokens.

Datum is the reference implementation platform. To implement jump host functionality, we have to enhance the yolo capabilities to handle cloud-hosted config (including secrets):

- `config load` stores keys in a Datum Secret.
- `jump register` stores connections in a ConfigMap.
- `yolo jump BOX connect [--accept-new] [USER@]HOST[:PORT]` holds connections to sessions over iroh and to hosts directly.
- When either side restarts, keys and connections come back without anyone logged in.

However, the provisioning was done by hand, and the design is tied to Datum.

This plan turns that into a design that works on any backend, with three initialization phases:

| Phase | What it does | Target |
|---|---|---|
| 1. Image build | base OS and slow work useful to every user | 5 min per CPU and OS combination |
| 2. Instance deployment | makes the host usable for one user: user, dotfiles, keys, Datum or cloud resources; runs once per deployment generation | 60 s |
| 3. Instance boot | reloads in-memory config and keys | 10 s until the box is usable; held connections come back afterwards |

Phase 2 follows cloud-init's model but doesn't use cloud-init itself, which can't run on the unikernel class. See https://gist.github.com/drewr/ad1f05d7f3fcdfd53916c3f61051ddc4.

## Design

**Five parts, each with an implementation per backend:**

| Part | What it is | Holds |
|---|---|---|
| Compute | the existing `Backend` union: run, restart and delete a long-lived instance | n/a |
| Config | small key/value settings, secret and not secret | keys, credentials, connections, session records, the broker's store, the deployment generation |
| Storage | an S3-compatible bucket or prefix that belongs to one deployment: created by `yolo new`, deleted by `yolo rm` | phase-2 outputs (dotfiles, harness settings), the shared home's data, logs |
| Identity | how the box reaches its Config and Storage | n/a |
| Bootstrap | how the instance receives its locators, user and generation | n/a |

**What the box reads, however it was delivered:**

- `YOLO_CONFIG_URL`, for example `datum://PROJECT/NAME`, `ssm://REGION/PREFIX` or `file:///...`;
- `YOLO_STORAGE_URL`, for example `s3://BUCKET/PREFIX?endpoint=...`;
- `YOLO_BOX`, `YOLO_USER` and `YOLO_GENERATION`.

**Agents on the box:** one persistent `ssh-agent`, in memory, filled from Config at boot. Logins, tmux panes and held connections all use it directly. The box's own key stays in a separate agent that is never forwarded. The client doesn't forward its agent to the box.

**Backends:**

| Backend | Compute | Config | Storage | Identity | Bootstrap |
|---|---|---|---|---|---|
| Datum (reference) | workload | Secret and ConfigMap | external S3-compatible bucket, keys kept in Config | service-account key | env and mounts |
| Local container | podman or docker | files (0600) | directory or MinIO | host user | env and mounts |
| AWS (after the EC2 backend lands) | EC2 | SSM Parameter Store | S3 | instance profile | user-data, run by cloud-init |
| *GCP (reference only)* | GCE | Secret Manager | GCS (S3-compatible API with HMAC keys) | VM service account | metadata, run by cloud-init |
| *DigitalOcean (reference only)* | droplet | another backend's Config | Spaces | API token | user-data, run by cloud-init |
| *Cloudflare (reference only)* | Containers | Workers secrets and KV | R2 | bindings | env and bindings |

Where a platform's identity can't grant access to Storage, the access keys live in the deployment's Config, as secrets.

## Approach

Restart recovery comes first: steps 1 to 3 give a box, made by `yolo new` alone, that brings its keys and connections back after a restart.

1. **Config first, on Datum.** `image/jump` stops calling `datumctl`. Boot reads Config over the API; the mounts become an optional speed-up, since they go stale and need a credential only to start. Sessions record their Datum project.
2. **Provisioning in `yolo new`.** The `jump` harness creates the service account, its binding and key, the Config objects and the bootstrap env, and `yolo rm` deletes them. `--no-home` becomes the default for jump.
3. **Bake the jump image** from what the jumpdev runner learned, with one agent and no mux, then rebuild every image for both classes.
4. **Credential broker on the box.** The broker in `broker/` moves its store to the box's Config and starts at boot; sandboxes the box launches get the proxy and trust its CA.
5. **Storage.** One S3-compatible client with SigV4, used by every backend. The same signing code later serves SSM.
6. **Split deployment from boot.** A `deploy` step in the image runs when `YOLO_GENERATION` differs from the generation recorded in Storage. Root-filesystem changes (user rename, env file) stay in boot because the root filesystem lives in RAM, but they take milliseconds. Dotfiles move from phase 1 to phase 2, so images are the same for every user.
7. **Make jump backend-neutral.** Any session with a ticket can serve as a box. Session records live in Config, and the client's `$YOLO_STATE` becomes a cache.
8. **Add the local backend** and a conformance suite that every backend must pass.
9. **Measure** each phase against its target.

## Out of scope

- **GCP, DigitalOcean and Cloudflare:** reference only. No implementation, and no spike.
- **`env`** (`datum-cloud/env`), a datumctl plugin, built as a separate effort.
- **Several devices logged in at once.** One client logs in, without forwarding its agent. ssh-agent-mux, its 16 forwarded-agent slots and the shared tmux session across devices leave the box (Phase 3). They can come back if multi-device use is needed.
- **Keys with a passphrase.** `load` takes unencrypted keys only; an askpass relay is a follow-up.
- **The broker's later steps:** HTTP/2, transparent interception, per-sandbox rate limits, CA name constraints (see `broker/README.md`).

## Open questions

1. Should Config and Storage clients be written in Zig inside yolo, or call the platform CLIs (datumctl, aws)? Zig keeps the image small and gives one code path, but means implementing SigV4 and each platform's auth; the CLIs are large (the aws CLI is Python). Recommendation: Zig.
2. The box-side command is `yolo config` or `yolo cfg`. `yolo config` reads as "edit my yolo.conf". Recommendation: `yolo cfg`.
3. Datum has no object storage that we know of. Should the Datum backend's Storage be the existing AWS bucket that JuiceFS uses (a prefix per deployment), or a new bucket per deployment?
4. How does the broker (Rust) reach its store in Config? The store holds the tokenizer URL and password, the CA, `policy.toml` and the sealed secrets. `serve` only reads it (`Store::load`, at start and on `SIGHUP`); `seal` and, later, OAuth refresh write to it.
   - **A. Through the box-side Config command:** a `Store` that runs `yolo cfg`. One Datum client to maintain, every Config backend works, and the broker stays generic ("run this command"). Costs a child process per operation.
   - **B. Its own Datum client in Rust:** self-contained, but a second implementation of Datum auth and of each later backend.
   - **C. Restore to files at boot:** `jump setup` copies the store from Config into a tmpfs directory owned by the broker's user, outside `$RUN` (which belongs to the login user), and the file store reads it unchanged. Writes need a path back: `seal` writes to Config and a root-run reload copies the entry in and sends `SIGHUP`; OAuth refresh needs the reverse.

   Recommendation: C to get the broker running on the box, then A.

## Tasks

### Phase 0: Datum prototype (done)

- [x] `image/jump`: `setup` runs the persistent agent, a separate agent for the box's own key, and ssh-agent-mux with 16 slots on a tmpfs. `login` is the forced command (tmux, `attach`, `load`, `connect`, `register`).
- [x] Keys persist to the box's Secret (`jump load`) and connections to its ConfigMap (`jump register`). Boot restores both from the mounts.
- [x] `src/jump.zig`: `yolo jump BOX connect [--accept-new] [USER@]HOST[:PORT]` reaches a session over iroh or a host directly. The host key is pinned from the client's `known_hosts`, or trusted on first use with `--accept-new`.
- [x] Reconnect loop with backoff. Verified after a target restart and after a box restart, with nobody logged in.
- [x] Held connections drop `IROH_SECRET`, so they don't knock the box's listener off the relay.
- [x] Committed `fix(broker)` (tokenizer IPv6) and `feat:` (jump box), rebased onto `fix-hardcoded-identity`.
- [x] Broker phase 1 (`broker/`): iroh tunnel from a sandbox-side proxy, TLS termination with the broker's CA, per-sandbox policy, unmodified tokenizer, file store, end-to-end and hostile-sandbox tests.

### Phase 1: Config on Datum

- [x] `src/config.zig`, pure part: parse `YOLO_CONFIG_URL` (`datum://PROJECT/NAME`, `file:///DIR`), validate keys, and model the entries (secret or plain), with tests.
- [x] `src/config.zig`, IO part:
  - [x] a Datum client over HTTP (`src/datumapi.zig`), authenticating with a service account's credentials file (`YOLO_DATUM_CREDENTIALS`, mode 0600), else with `datumctl auth get-token`. HTTPS only; the assertion goes only to the auth server's own origin; CA bundle from `SSL_CERT_FILE` or `NIX_SSL_CERT_FILE`, else std's system paths. Tokens stay in memory, one exchange per command, no disk cache. The JWT for the token exchange is signed RS256 (`src/jwt.zig`, modular arithmetic on `std.crypto.ff`; tests verify openssl signatures with public keys only and generate their private keys at runtime in `src/rsa_testkey.zig`, so no private key is in the source). Decided after a live test on 2026-11-19: Datum accepts only RSA keys (it rejects uploaded Ed25519 keys and, apparently by a bug, ECDSA ones). The JWT: `kid` = the key's `status.authProviderKeyID`, `iss` = `sub` = the service account's `status.clientID`, `aud` = `https://auth.datum.net`, 60 s; exchanged at the token endpoint from OIDC discovery (`https://auth.datum.net/oauth/v2/token`, jwt-bearer grant). Tokens last 12 h and are renewed by minting a new JWT;
  - [x] get, put and list on the box's Secret and ConfigMap (put patches, or creates the object on 404). Tested live on both credential paths; a service account with no role gets a 403;
  - [x] the same three operations on files (atomic writes; secret entries 0600 in a 0700 directory).
- [x] `src/main.zig`: the box-side command `yolo cfg get|put|list [--secret] KEY`, value on stdin for `put`, for both `file://` and `datum://`.
- [ ] `image/jump`: replace `datumctl login` and `datumctl patch` with the new command. `restore_keys` and `restore_connections` read through Config, not the mounts.
- [x] `src/datum.zig`: add `YOLO_DATUM_PROJECT` (default: datumctl's active project, read from `datumctl whoami` and recorded in `datum_project` next to `datum_session`). Later commands pass the recorded project as `--project`. Still needs a live `yolo new`; `yolo build` still uses the active project. `whoami` has no `-o json`, so the project is read from its text; switch to JSON if datumctl adds it.
- [x] README: document `YOLO_DATUM_PROJECT`.

### Phase 2: Provision jump boxes in `yolo new`

- [ ] `yolo new NAME --agent jump` on Datum:
  - [ ] create service account `jump-NAME`, its editor PolicyBinding (in the organization's namespace) and a key generated by Datum (RSA; the create response's `status.privateKey` is a complete credentials JSON, returned only once);
  - [ ] create Secret and ConfigMap `yolo-NAME-config` (one name for both, as `datum://PROJECT/NAME` addresses them; not `yolo-NAME`, the session's Secret with its iroh secret), seeding the Secret with the credentials;
  - [ ] set `YOLO_CONFIG_URL`, `YOLO_BOX`, `YOLO_USER` and `YOLO_GENERATION=1` in the workload's env;
  - [ ] make `--no-home` the default for jump.
- [ ] `yolo rm NAME` deletes everything above. A failure halfway through `new` cleans up whatever it already created.
- [ ] Unit tests for the manifests (pure builders), and a live `new`, `load`, `connect`, restart and `rm` run in a test project.

### Phase 3: Bake the jump image

- [ ] Port what the jumpdev runner does into `image/flake.nix` and `init.sh`:
  - [ ] ship `ssh-keyscan`, `jq`, `tmux`, and busybox `su`, `mount`, `tar` and `gzip`;
  - [ ] write `/etc/shells`;
  - [ ] write the bootstrap variables to `/etc/agent/env`.
- [ ] One agent, no mux:
  - [ ] `jump setup` starts the persistent agent and the agent for the box's own key, and no longer starts ssh-agent-mux;
  - [ ] `jump login` exports `SSH_AUTH_SOCK=$RUN/persist.sock` and no longer claims a forwarded-agent slot;
  - [ ] held connections (`jump connect`) use the persistent agent;
  - [ ] remove the slot pool, the mux config, their tests, and ssh-agent-mux from the image.
- [ ] `src/datum.zig`: `yolo attach` doesn't forward the client's agent to a jump box (no `ForwardAgent=yes` when the session's harness is `jump`); `-A` still opts in.
- [ ] Add tmux to every harness image.
- [ ] Bump the image's `yolo` input to a revision that includes Config and jump.
- [ ] Rebuild every harness image for both classes, and fold the digests into the jump commit before any push.
- [ ] Live: create a jump box from the image (not jumpdev), then `load`, `connect`, restart the box, restart the target, `rm`. Check that `ssh-add -l` on the box lists only the loaded keys.

### Phase 4: Credential broker on the box

- [ ] A Config-backed `Store` for the broker (per Question 4): the CA, the tokenizer password, the policy and the sealed secrets live in the box's Secret and ConfigMap, read at start and on `SIGHUP`.
- [ ] Jump image: ship `yolo-broker` and the patched tokenizer. `jump setup` starts both at boot, each as its own user, supervised.
- [ ] Tokenizer's open key (`OPEN_KEY`, outside the broker's store) persists in its own Secret, readable with a credential only tokenizer's user gets (a PolicyBinding on that one resource), and reaches tokenizer through its environment, never a file the broker can read. Without it, sealing protects nothing at rest, and a restart makes every sealed secret unreadable.
- [ ] A box-side command to seal a secret into the store (`yolo-broker seal`, writing through Config).
- [ ] Harness images: ship `yolo-broker-proxy`. When the session has a broker, the sandbox's init starts it and sets `HTTPS_PROXY` and CA trust (`SSL_CERT_FILE`, `NODE_EXTRA_CA_CERTS`, `REQUESTS_CA_BUNDLE`).
- [ ] yolo: `yolo new` on the box registers the sandbox's proxy endpoint ID and policy with the broker and passes the sandbox the broker's ID and CA; `yolo rm` removes the entry.
- [ ] OAuth: refresh tokens, and sealing refreshed access tokens back into the store.
- [ ] Live: a sandbox calls an API through the broker; restart the box, and the call works again with nobody logged in; removing the sandbox's entry stops it.

### Phase 5: Storage

- [ ] `src/storage.zig`, pure part: parse `YOLO_STORAGE_URL` (`s3://BUCKET/PREFIX?endpoint=...&region=...`, `file:///DIR`), and SigV4 canonical request and signing, tested against AWS's published SigV4 vectors.
- [ ] `src/storage.zig`, IO part: get, put, list and delete over HTTP, for S3-compatible endpoints and for a directory.
- [ ] Provisioning: `yolo new` creates the deployment's bucket or prefix (per Question 3) and stores its access keys in Config as secrets; `yolo rm` deletes them.
- [ ] Point the JuiceFS shared home at Storage instead of its own separate setup.

### Phase 6: Split deployment from boot

- [ ] Split `image/init.sh` into a `deploy` step and a `boot` step.
  - `deploy` runs when `YOLO_GENERATION` differs from the generation recorded in Storage, writes its outputs to Storage, then records the generation.
  - `boot` restores those outputs and reloads keys and connections.
- [ ] Move dotfiles from phase 1 to phase 2:
  - `yolo new` puts the `YOLO_DOTFILES` reference in Config;
  - `deploy` fetches it and stores it in Storage;
  - the image no longer contains dotfiles, so images are the same for every user.
- [ ] Make `sync-pins` an explicit option instead of the default build path, and drop the dotfiles input from `image/flake.nix`.
- [ ] Log a timestamp at the start and end of each phase in init's log.
- [ ] shellcheck, image eval for both systems, and rebuild every harness image for both classes.

### Phase 7: Backend-neutral jump

- [ ] `src/jump.zig`: drop the requirement that the box is a Datum session. Any session with a ticket can be a box.
- [ ] Session records (ticket, host key, user, backend) are written to Config. The client's `$YOLO_STATE` becomes a cache, and a second client can find sessions with Config alone.
- [ ] When a sandbox is recreated with a new host key, the box takes the new key from the sandbox's record in Config and re-pins it, without another `register`.

### Phase 8: Local backend and conformance suite

- [ ] Local backend: `file://` Config and Storage, podman or docker for Compute, env and mounts for Bootstrap.
- [ ] A conformance suite that every backend must pass:
  - [ ] `load`, then `register`;
  - [ ] restart the box: keys, connections and the broker come back;
  - [ ] restart the target: the box reconnects;
  - [ ] deployment output survives a restart without rerunning `deploy`;
  - [ ] `rm` leaves nothing behind.
- [ ] Run the suite on the local backend and on Datum.

### Phase 9: Verification and targets

- [ ] Static: `nix develop -c sh -c 'zig fmt --check src build.zig && zig build test && zig build -Doptimize=ReleaseSafe'`, `nix build`, shellcheck on the in-image scripts and `image/jump`, image eval for x86_64 and aarch64, and the broker's tests.
- [ ] Measure image build time per CPU and OS combination (target: 5 min).
- [ ] Measure `yolo new` for a jump box up to ready (target: 60 s).
- [ ] Measure a restart up to the box being usable (target: 10 s), and record when connections come back as a separate number.
- [ ] Commit, and open a PR when asked.

### Cleanup (needs the developer's go-ahead)

- [ ] Rotate the ECDSA key printed during testing, and shred `/tmp/id_ecdsa`.
- [ ] Delete the test resources: `metaltest` and its Secret, `agent1`, `jb1`, `t1`, `$XDG_RUNTIME_DIR/claude-agent1` and branch `backup-feature-jump-box-pre-rebase`.
- [ ] Retire jumpdev and its ConfigMap `jumpdev-dev` once phase 3 works.
