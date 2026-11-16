---
ticket: gh-3
branch: feature-gh-3-add-ec2-backend-running-harness-images
summary: Add ec2 backend running harness images on EC2 instances
ticketing: github-issues
---

# Add ec2 backend running harness images on EC2 instances

**Ticket:** [#3](https://github.com/drewr/yolo/issues/3)
**Type:** feature
**Branch:** feature-gh-3-add-ec2-backend-running-harness-images

---

## Context

yolo runs one named session per harness image on two backends: local containers (`docker`) and Datum Compute (`datum`). A third backend makes the same pinned general-purpose harness image run in the operator's own AWS account: an EC2 instance reached by SSH over iroh (no inbound ports), with lifecycle and logs through SSM RunCommand and the image delivered through ECR. The AWS profile and region are chosen at `yolo new` and recorded in the session directory, so later commands keep using the right account.

Planning already verified: the general-purpose images in `image/images-general-purpose` are amd64 OCI images whose entrypoint is `/bin/sh /init`, private on ghcr; no image change or rebuild is needed (`init.sh`'s `datum` mode already serves SSH over iroh). `session.zig`, `keys.zig` and `datum.zig` already build the iroh ticket, pinned host key and `known_hosts` line — the plan moves the shared pieces (`sshArgs`, `prepareIrohSession`) up first, then builds `ec2.zig` on them.

## Scope

Per `docs/aws-ec2-backend-plan.md` — the authoritative behavior spec; its `ec2New` ordering (steps 1–10) and per-command sections are the contract:

- `src/infra.zig`: profile-based AWS helpers (`Profile`, `awsArgsFor`/`awsTry`/`awsFor` with the current SSO-expired die behavior), converted provisioners (`ensureSecurityGroupFor`, `ensureInstanceProfileFor`, `defaultVpcFor` with `Box` delegates, `waitSsmOnline` extracted from `boxTicket`).
- `src/session.zig` / `src/keys.zig`: move `datumSsh`/`SshArgs`/`splitSshArgs` into `session.zig` (`SshTarget`, `sshArgs`, `splitSshArgs`) and `datumNew`'s key block into `keys.zig` (`prepareIrohSession`, `recordIdentity`); `datum.zig` keeps one-line wrappers and loses the inlines; golden tests re-pointed (same expectations).
- `flake.nix`: add `crane` to the wrapper's `tools` (`[ dumbpipe socat buildkit crane ]`), update the tools comment and the flake `description` to mention EC2.
- `src/ec2.zig` (new): pure section (`containerTag`, `aml2023_ami`, `registryOf`, `imageDigest`, `Auth`/`dockerAuth`, `ecrRegistry`/`ecrRepo`/`ecrTag`, `AuthEntry`/`dockerConfig`, `shellQuote`, `userData`, `EnvInput`/`envFile`, `StartInput`/`startScript`) and IO boundary (`ec2New`, `ec2Attach`, `ec2Ls`, `ec2Logs`, `ec2Rm`, private `ssmRun` and `waitForSsh`). `ec2New` mirrors the pinned image into ECR with `crane` through a temp `DOCKER_CONFIG` (once per digest), launches an AL2023 instance with user-data installing Docker, sends the start script over SSM (command deleted after — it holds the ECR token), then waits for SSH.
- `src/main.zig`: wire the `ec2` arm into `Backend`, `loadBackend`, `lsBackend`, `usage`, `cmdNew`; both unknown-backend messages become `(docker, datum or ec2)`.
- Tests and docs: pure `test` blocks in `ec2.zig` (per the plan's list); golden ssh-args tests moved to `session.splitSshArgs`; `README.md` (intro, ec2 column, running-cost and requirements sentences); `AGENTS.md` (ec2 in the module list and Structure).

## Out of Scope

- Any change under `image/` — no image change or rebuild is needed (`init.sh`'s `datum` mode already runs dropbear + dumbpipe). Image digests are not updated in this ticket.
- Shared/remote home for ec2 sessions: `HOME` and `/work` live in the instance's container and are destroyed by `yolo rm`.
- ECR lifecycle rules or digest cleanup — old mirrored digests accumulate; the README merely documents it.
- PR merging strategy beyond this ticket: `attach` does not accept `--profile`/`--region`; the recorded session profile is authoritative.
- `yolo infra` changes beyond the refactor of its own helpers (no new behavior for box meta).

## Technical Approach

This is a three-layer refactor-backend-wire plan straight out of the planning doc, ordered by dependency:

1. **`infra.zig` (independent):** introduce `Profile {profile, region}`; `awsArgsFor` prepends `--profile/--region`; `awsTry` captures (returns null only when `aws` is missing) and `awsFor` keeps the exact existing die behavior (SSO-expired hint first). Convert the three provisioners to take `(ctx, Profile, name)` with `Box`-taking delegates; extract `boxTicket`'s poll loop as `waitSsmOnline(ctx, p, instance, what)`.
2. **`session.zig` + `keys.zig` (independent):** `sshArgs` is `datumSsh`'s body verbatim (ProxyCommand dumbpipe, pinned `known_hosts`, StrictHostKeyChecking=yes, ServerAliveInterval=30, optional `-i`/`ForwardAgent`, then `splitSshArgs`, `{user}@{alias}`); `datumSsh` becomes a one-line wrapper. `prepareIrohSession`/`recordIdentity` reproduce `datumNew`'s blocks exactly, down to the die texts and the error mapping (`NoPublicKey` → `util.die(keys.no_public_key)`).
3. **`ec2.zig` (depends on 1+2):** mirror → launch → start → wait, per the plan's step 1–10 ordering: resolve source (`EC2_IMAGE` override else `images.lookupImage` of `image/images-general-purpose`), `sts get-caller-identity` → ECR registry/repo/tag (`gp-` + 12 hex of the digest), ensure-repo/idempotent copy via `crane copy` under temp `DOCKER_CONFIG` carrying host ghcr auth + ECR token, digest-mismatch contingency by resolving the destination tag, session dir written with `profile`/`region`/`image`/`state`, `prepareIrohSession` with `containerName = docker.containerName`, SG+instance-profile under `containerTag` (`yolo-ec2`), AL2023 AMI from the public SSM parameter + user-data (`dnf install -y docker`), `run-instances` with the exact flag set in the plan, SSM start script (`ssmRun(..., 900, true)`), then `waitForSsh` (10 min). `ec2Ls` groups by recorded profile+region and warns on `awsTry` failure; `ec2Rm` keeps local state when termination fails.
4. **`main.zig` (depends on 3):** the union arm, `loadBackend`/`lsBackend` matchers, `usage` and `cmdNew` option strings, per the plan's exact text.
5. **Verification:** static gates first (`nix develop -c zig build test`, `zig fmt --check`, ReleaseSafe, `nix build`, `yolo help`); live checks against the sandbox profile `datum-sandbox-admin` (region `us-east-2`) on a scratch `YOLO_STATE`, including the recorded-profile independence check (`AWS_PROFILE=default` with a recorded profile), the second-new-skips-copy check, and `rm` of every instance created.

Deviation from the plan doc, per Q4's answer: the default root disk is **500 GB** gp3, not the 20 GB the plan doc wrote (`disk_gb = ctx.opt("EC2_DISK_GB", "500")`), and the README cost sentence the plan specifies must quote the confirmed live-run prices (t3a.large $0.0752/hr ≈ $54/month non-stop; gp3 $0.08/GB-month ≈ $40/month while the session lives — ≈$0.115/hour combined, all ending at `yolo rm`).

Constraints from techContext: Zig from `zigutils`' pin, std only (no `build.zig.zon` — `json.parse` and `util.b64*` do the parsing here), one module per concern with the pure/IO-boundary layout, tests as inline `test` blocks, and the aws/ssh/crane tools coming from PATH (the flake wrapper adds `crane`).

---

## Questions
<!-- Answer each question before running /dmx/plan. -->

1. The plan's live verification assumes `docker login ghcr.io` already works on the host and `aws sso login --profile datum-sandbox-admin`. Is that account still the right scratch target, or should a different profile/region be used for the first live run?
   Answer: Yes — `datum-sandbox-admin` / `us-east-2` stays the scratch target, as the plan assumes.

2. The unverified pieces (`al2023-ami-kernel-default-x86_64` SSM parameter, `dnf install -y docker` on AL2023) fall back to the ECS-optimized AMI. Should the first live run confirm them, or do you want the ECS-optimized AMI from the start to skip the risk?
   Answer: Confirm live and keep the fallback — implement the plain AL2023 AMI + `dnf install -y docker` user-data, and use the ECS-optimized-AMI contingency (drop `dnf`/`systemctl` from user-data) only if the live run shows that path failing.

3. `ec2New` deletes the start command's SSM record because it contains the one-time ECR token. Are you comfortable with `yolo logs` only showing docker-daemon and container logs (no start-command stdout) via `docker logs --tail 2000`?
   Answer: Yes — delete the SSM record; it holds the one-time ECR token. `yolo logs` showing docker-daemon and container logs (SNAPSHOT, not `--follow`) only is accepted.

4. The default instance is `t3a.large` + 20 GB gp3 (~$55/month if left running; sessions bill until `yolo rm`). Keep those defaults and `EC2_INSTANCE_TYPE`/`EC2_DISK_GB` as the overrides, or different defaults?
   Answer: Keep `t3a.large` (checked: $0.0752/hr on-demand us-east-2 ≈ $54.14/month non-stop) but raise the default disk to **500 GB** gp3 ($0.08/GB-month ≈ $40.00/month, billed pro-rated while the instance lives; the EBS volume and its deleted-at-`rm` data are per-session). Overrides stay `YOLO_EC2_DISK_GB` and `YOLO_EC2_INSTANCE_TYPE`. README must state these costs (per-hour running ≈ $0.115; storage ≈ $40/month while the session lives) so the size is a documented choice.

5. `crane` lands in the flake wrapper's `tools` for everyone. Any objection to extending the flake (a one-line change), or should the first run check for `crane` in PATH and only warn?
   Answer: Add `crane` to the flake wrapper's `tools` (one-line change, per the plan).
