# Tasks: Add ec2 backend running harness images on EC2 instances

**Spec:** `.dmx/jobs/gh-3/spec.md`
**Branch:** feature-gh-3-add-ec2-backend-running-harness-images
**Ticket:** [gh-3](https://github.com/drewr/yolo/issues/3)
**Status:** In Progress

---

## Phase 1: Shared foundations — infra, session, keys, flake

- [x] `src/infra.zig`: add `Profile {profile, region}`, `profileOf(b)`, `awsArgsFor`, `awsArgs`, `awsTry` (null only when `aws` is missing from PATH) and `awsFor` with the current die behavior (`AWS login needed for profile {s}: aws sso login --profile {s}` on SSO expiry, else `aws {s} {s}: {stderr}`); re-point the private `aws` wrapper and call sites through them
- [x] `src/infra.zig`: convert `ensureSecurityGroup`/`ensureInstanceProfile`/`defaultVpc` to `(ctx, Profile, name)` pairs with `Box` delegating wrappers, and extract `boxTicket`'s SSM poll loop as `waitSsmOnline(ctx, p, instance, what)` (`{s} isn't reachable over SSM after 5 min (SSM status: {s})`); `boxTicket` calls it with `b.name`
- [x] `src/session.zig`: move `datumSsh`/`SshArgs`/`splitSshArgs`/`isValueOption` in as `SshTarget`/`sshArgs`/`splitSshArgs` (body verbatim: dumbpipe ProxyCommand, pinned `known_hosts` via `HostKeyAlias`, `StrictHostKeyChecking=yes`, `ServerAliveInterval=30`, optional `-i`/`IdentitiesOnly`, optional `ForwardAgent`, `{user}@{alias}`)
- [x] `src/datum.zig`: `datumSsh` becomes a one-line wrapper over `session.sshArgs`; delete the moved types fns; update the three golden tests `src/golden_test.zig` `182,194,208` to `session.splitSshArgs` (same expectations)
- [x] `src/keys.zig`: move `datumNew`'s key block in as `prepareIrohSession(ctx, dir, alias, relay)` (`iroh_secret`, `ticket`, `ed25519 host_key`, `known_hosts` line) and `--key` block as `recordIdentity(ctx, dir, key)`; `datumNew` calls both, with identical die texts and the removed-dir cleanup. `datumNew` keeps its `ticket_ok` check
- [x] `flake.nix`: add `crane` to `tools` (comment mentions it next to `dumbpipe`, `socat`, `buildkit`), flake `description` mentions EC2; Q5 answered "Add crane to the flake"

## Phase 2: `ec2.zig` pure section + unit tests

- [ ] `src/ec2.zig` pure section with `containerTag = "yolo-ec2"`, `aml2023_ami` constant, `registryOf`, `imageDigest`, `Auth`/`dockerAuth` (json.parse + util.b64decode, null on any malformed piece), `ecrRegistry`/`ecrRepo` (`yolo/agent-{harness}`)/`ecrTag` (`gp-` + 12 hex), `AuthEntry`/`dockerConfig`, `shellQuote` (`'` → `'\''`), `userData` (`dnf install -y docker` + `systemctl enable --now docker`), `EnvInput`/`envFile` (six header lines incl. base64 `AUTHORIZED_KEYS_B64`/`SSH_HOST_KEY_B64`, `PROVIDER_KEYS` joined, provider lines), `StartInput`/`startScript` (quoted heredoc, docker-wait loop, conditional `docker login`, `docker pull`/`docker rm -f`/`docker run` with `--restart unless-stopped --cap-add NET_ADMIN --log-opt max-size=10m --log-opt max-file=3 --env-file /opt/yolo/session.env`, `docker logout`)
- [ ] `src/ec2.zig` `test` blocks (pure only): `envFile` fixed input vs the six-line header + provider lines, `shellQuote("a'b")` == `'a'\''b'`, `startScript` contents (quoted `--name`, conditional `docker login`, `docker run ... --env-file`), `registryOf` both branches, `imageDigest` both branches, `ecrRegistry`/`ecrRepo`/`ecrTag`, `dockerConfig` two-entry JSON render, `dockerAuth` success vs `null` inputs, `userData` contains `dnf install -y docker`

## Phase 3: `ec2.zig` IO boundary — the backend

- [ ] `src/ec2.zig`: `ec2New` steps 1–5 (option parsing incl. `--profile`/`--region`/`--key` and the `aws`/`EC2_IMAGE`-or-`images.lookupImage` source resolution, `EC2_INSTANCE_TYPE`/`EC2_DISK_GB` plan semantics with the spec's **500 GB** default, digest resolution, ECR ensure/copy via `crane copy` under temp `DOCKER_CONFIG` carrying host ghcr + `AWS:{password}` ECR auth and digest-mismatch resolution via `imageTag`, session dir with `profile`/`region`/`image`/`state`/`authorized_keys` and shared `keys.prepareIrohSession`, `infra.ensureSecurityGroupFor`/`ensureInstanceProfileFor` under `containerTag`); nothing is created before step 5, and a failure in mirroring removes the session state dir before dying
- [ ] `src/ec2.zig`: `ec2New` steps 6–10 (write temp `userData`, `ec2 run-instances` with the exact plan flags (tags, SSM metadata options, gp3 volume at 500 GB), SSM send/start via `infra.waitSsmOnline` + `ssmRun(..., 900, true)` printing to **stderr**, `waitForSsh` (10 min, ConnectTimeout=20, BatchMode, `session.sshArgs`), `state` cleanup and the `ready after {d}s: yolo attach {name}` message)
- [ ] `src/ec2.zig`: private `ssmRun(ctx, p, instance, script, timeout_s, delete)` — base64-wrapped params file (die above 22000 bytes), `send-command` with AWS-RunShellScript, 2 s poll until terminal status (die `the command on the instance didn't finish`), best-effort `delete-command` when asked; `ec2Attach` (die `no local state for {name}` without `ticket`, read `ticket`/`identity` from the dir, exec'd ssh argv); `ec2Logs` (no `-f`/`--follow`, `--tail 2000` default, `ssmRun(..., 180, false)`); `ec2Ls` (group by profile+region via `session.localSessions`/`awsTry`, warn on group failure, `gone` rows where the recorded id disappeared); `ec2Rm` (`awsTry` terminate, keep the state dir when terminate fails so nothing is orphaned, `terminated {id}`, never touch ECR)

## Phase 4: Wire-in & docs

- [ ] `src/main.zig`: `ec2` arm in `Backend` (used `new`/`attach`/`ls`/`logs`/`rm`), `loadBackend`/`lsBackend` matchers, unknown-backend strings → `(docker, datum or ec2)`, `usage` backend-options block with `ec2` entries and `cmdNew`'s parse string gains `|ec2`, file doc comment gains `, or on AWS EC2`
- [ ] `README.md`: intro sentence gains `, or on AWS EC2`, an `ec2` column in the Backends table, one cost sentence documenting the confirmed defaults and prices (t3a.large $0.0752/hr ≈ $54/month; 500 GB gp3 ≈ $40/month while a session lives — ≈$0.115/hour combined; ECR ~$0.03/month per 329 MB digest; instances and disk bill until `yolo rm`), and the requirements bullet (`aws` logged in to the profile, `docker login ghcr.io`, `crane` + `dumbpipe` from the flake, `ssh`/`ssh-keygen`)
- [ ] `AGENTS.md`: `ec2` in the module list, the "two backends" sentence becomes three, and a Structure line that `ec2.zig` launches instances and uses SSM (keep the rest of the dmx block untouched)

## Phase 5: Verification

- [ ] Static: `nix develop -c zig build test`, `nix develop -c zig fmt --check src build.zig`, `nix develop -c zig build -Doptimize=ReleaseSafe`, `nix build`; then `./result/bin/yolo help` shows the `ec2` backend and its options and `yolo ls`/`yolo version` still work
- [ ] Live (scratch `YOLO_STATE=$(mktemp -d)/sessions`, `aws sso login --profile datum-sandbox-admin`, region `us-east-2`): `./result/bin/yolo new e2e --backend ec2` — expect `crane copy` output once, `launched i-...`, docker pull/run output, `ready after Ns`; then `yolo attach e2e -- hostname`, `yolo logs e2e` (init snapshot lines), `yolo ls` (both tables), recorded-profile independence (works with `AWS_PROFILE=default` exported), `YOLO_EC2_DISK_GB` override honored, and the digest preserved in ECR (`ecr describe-images ... imageDigest`), plus a second `yolo new` skipping the copy
- [ ] Negative checks: unknown profile dies with the aws CLI error (SSO hint when expired), `yolo logs e2e -f` dies with the SSM follow message, `yolo new x --backend ec2 --bogus` dies `ec2: unknown option --bogus` before creating anything; `yolo rm` every instance created during verification (instances bill until then); report only if the ECS-optimized fallback was needed
- [ ] Final: `/dmx/commit` the work on the feature branch; the loop's PR step drafts the PR against the configured `branch_base` (`dmx-aws`)

---
_Generated by /dmx/plan. Edit freely — this is your implementation contract._
