# Plan: AWS EC2 backend for yolo

## Context

`yolo` runs one named session per harness image on two backends: local
containers (`docker`) and Datum Compute (`datum`). Add a third: `ec2`, where a
session is an EC2 instance in the caller's AWS account running the pinned
general-purpose harness image under Docker, reached by SSH over iroh like a
Datum session (no inbound ports). The AWS profile (and region) is chosen at
`yolo new` (`--profile`, `--region`, or `$AWS_PROFILE`/`$AWS_REGION`) and
recorded in the session directory, so `attach`, `logs`, `ls` and `rm` keep
using the right account afterwards. End state: `yolo new NAME --backend ec2
--profile P` creates a working session; `yolo attach/logs/ls/rm NAME` work
without naming the profile again.

Verified while planning: the general-purpose images in
`image/images-general-purpose` are amd64 OCI images whose entrypoint is
`/bin/sh /init` (329 MB compressed); they are **private** — an anonymous pull
is 403, while the local `~/.docker/config.json` token pulls the manifest
(`ghcr.io`, user `drewr`). The unikernel image digest is not pullable as an OCI
image, so the EC2 backend must use the general-purpose file. `session.zig`,
`keys.zig` and `datum.zig` already build the iroh ticket, pinned host key and
`known_hosts` line, and `init.sh`'s `datum` mode runs dropbear on loopback plus
a dumbpipe listener — so no image change and no image rebuild is needed.
Images are delivered through ECR in the session's account and region: `yolo
new` mirrors the pinned image there once per digest with `crane`, using the
host's ghcr login for the source, and the instance pulls it with a one-time ECR
token (no ghcr credentials reach the instance).

Also in this change: add `crane` (go-containerregistry, `pkgs.crane`) to the
flake wrapper's `tools`, next to `dumbpipe`, `socat` and `buildkit`, and update
that comment and the flake description.

## Approach

### 1. `src/infra.zig`: profile-based AWS helpers (independent)

Add a region/profile pair and route the existing `aws` wrapper through it, so
`ec2.zig` can use SSM and EC2 in a profile other than a box's default:

```zig
pub const Profile = struct { profile: []const u8, region: []const u8 };
pub fn profileOf(b: Box) Profile
pub fn awsArgsFor(allocator, p: Profile, args) ![]const []const u8  // aws --profile .. --region .. args
pub fn awsArgs(allocator, b: Box, args) ![]const []const u8         // awsArgsFor(allocator, profileOf(b), args)
pub fn awsTry(ctx, p: Profile, args) ?util.Result                    // capture; null only when aws is missing
pub fn awsFor(ctx, p: Profile, args) []const u8                      // awsTry + the existing SSO-expired die
fn aws(ctx, b: Box, args) []const u8                                // awsFor(ctx, profileOf(b), args)
```

`awsFor` keeps the exact current failure behavior: `r.term != .exited or
r.code != 0` dies with `AWS login needed for profile {s}: aws sso login
--profile {s}` when `SsoExpired.detect(r.stderr) == .yes`, else `aws {s} {s}:
{stderr}`. `awsTry` returns the raw result (for `ls`/`rm`, which must not die).

Convert the shared provisioners to take a `Profile` and a name, keeping the
`Box` wrappers:

```zig
pub fn ensureSecurityGroupFor(ctx, p: Profile, name: []const u8) []const u8
pub fn ensureSecurityGroup(ctx, b: Box) []const u8      // delegate with b.name
pub fn ensureInstanceProfileFor(ctx, p: Profile, name: []const u8) void
pub fn ensureInstanceProfile(ctx, b: Box) void          // delegate with b.name
pub fn defaultVpcFor(ctx, p: Profile) []const u8
fn defaultVpc(ctx, b: Box) []const u8                   // delegate
pub fn waitSsmOnline(ctx, p: Profile, instance: []const u8, what: []const u8) void
```

`waitSsmOnline` is `boxTicket`'s existing poll loop (5 s interval, 300 s
deadline, `describe-instance-information` until `PingStatus == Online`) with
`what` in the die text (`{s} isn't reachable over SSM after 5 min (SSM status:
{s})`). `boxTicket` calls it with `b.name`. No other infra behavior changes.

### 2. `src/session.zig` and `src/keys.zig`: share the SSH and iroh setup (independent)

**SSH argv.** Move `datum.zig`'s `datumSsh`, `SshArgs`, `splitSshArgs` and
`isValueOption` into `session.zig`, so the ec2 backend gets the same pinned-host
command line. New API:

```zig
pub const SshTarget = struct {
    dir: []const u8,            // holds known_hosts
    alias: []const u8,          // HostKeyAlias and known_hosts name (yolo-NAME)
    ticket: []const u8,         // dumbpipe ticket for ProxyCommand
    identity: ?[]const u8,      // -i, or null for the ssh-agent's keys
    user: []const u8,
    forward_agent: bool,
    args: []const []const u8,   // ssh-style args from the command line
};
pub fn sshArgs(ctx: Ctx, t: SshTarget) []const []const u8
pub const SshArgs = struct { opts: []const []const u8, cmd: []const []const u8 };
pub fn splitSshArgs(allocator, args) SshArgs
```

`session.sshArgs` is `datumSsh`'s body verbatim (ProxyCommand
`dumbpipe connect {ticket} 2>/dev/null`, `UserKnownHostsFile={dir}/known_hosts`,
`HostKeyAlias={alias}`, `StrictHostKeyChecking=yes`,
`ServerAliveInterval=30`, optional `-i {identity} -o IdentitiesOnly=yes`, optional
`ForwardAgent=yes`, then `splitSshArgs` and `{user}@{alias}`). Keep
`datum.zig`'s private `fn datumSsh(ctx, d, dir, wl, ticket, identity, args)` as a
one-line wrapper calling `session.sshArgs(ctx, .{ .dir = dir, .alias = wl,
.ticket = ticket, .identity = identity, .user = d.user, .forward_agent =
d.forward_agent, .args = args })`, so its three callers (`waitForSsh`,
`datumAttach`, `datumRm`) are untouched. Delete `datum.zig`'s `SshArgs`,
`splitSshArgs` and `isValueOption`; update the three tests in
`src/golden_test.zig:182,194,208` from `datum.splitSshArgs` to
`session.splitSshArgs` (same expectations).

**Iroh session keys.** Move `datumNew`'s key block into `keys.zig`:

```zig
pub const IrohSession = struct { secret_hex: []const u8, ticket: []const u8, host_key_pub: []const u8 };
pub fn prepareIrohSession(ctx: Ctx, dir: []const u8, alias: []const u8, relay: []const u8) IrohSession
pub fn recordIdentity(ctx: Ctx, dir: []const u8, key: ?[]const u8) void
```

`prepareIrohSession` reproduces the current block exactly: 32 random bytes
(`ctx.io.randomSecure`) hex-encoded into `iroh_secret` (`{hex}\n`), the ticket
from `endpointTicket(relay, hex)` into `ticket` (`{ticket}\n`), `ssh-keygen -q
-t ed25519 -N "" -C {alias} -f {dir}/host_key`, and `known_hosts`
(`{alias} {kind} {b64}\n`) from `host_key.pub` via `knownHostsLine`. Error
dies are the current ones: `can't get random bytes`, `relay URL too long`, `bad
iroh secret`, `could not make the host key` (after removing `dir`), `ssh-keygen
made no public key`. `datumNew` calls it with `wl` as the alias and `d.relay`,
and drops its inline copy. Keep `datumNew`'s existing `ticket_ok` file check.

`recordIdentity` is `datumNew`'s `--key FILE.pub` block: when `key` ends in
`.pub` and its private key exists beside it, write `identity` (`{realpath}\n`). `datumNew` replaces its inline block with
the call.

### 3. `src/ec2.zig`: the backend (depends on 1 and 2)

First, `flake.nix`: add `crane` to `tools` (`[ dumbpipe socat buildkit crane ]`),
say so in the tools comment, and extend the flake `description` to mention EC2.

Header comment: sessions are EC2 instances (`Name=yolo-NAME`) from the latest
AL2023 x86_64 AMI, with Docker installed by user-data; the pinned
general-purpose image runs in `YOLO_MODE=datum`, so attach is SSH over iroh
with the host key pinned and no inbound SG rules; lifecycle and logs go through
SSM RunCommand. The aws CLI, ssh, ssh-keygen, ssh-add and dumbpipe come from
PATH; the image comes from `image/images-general-purpose`.

Pure section (all `pub`, unit-tested below):

```zig
pub const containerTag = "yolo-ec2";        // SG + IAM role/instance-profile name
pub const aml2023_ami = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64";
pub fn registryOf(ref: []const u8) []const u8      // "ghcr.io" from "ghcr.io/drewr/x@sha256:..", else ""
pub fn imageDigest(ref: []const u8) ?[]const u8    // "sha256:.." after '@', else null
pub const Auth = struct { auth: []const u8, user: []const u8, token: []const u8 };
pub fn dockerAuth(ctx: Ctx, config_text: []const u8, registry: []const u8) ?Auth
pub fn ecrRegistry(allocator, account: []const u8, region: []const u8) ![]const u8 // "{account}.dkr.ecr.{region}.amazonaws.com"
pub fn ecrRepo(allocator, harness: []const u8) ![]const u8                        // "yolo/agent-{harness}"
pub fn ecrTag(allocator, digest: []const u8) ![]const u8                          // "gp-" + the digest's first 12 hex chars
pub const AuthEntry = struct { registry: []const u8, auth: []const u8 };
pub fn dockerConfig(allocator, entries: []const AuthEntry) ![]const u8            // {"auths":{REG:{auth:A},...}}
pub fn shellQuote(allocator, s: []const u8) ![]const u8   // 'x' with ' -> '\'' 
pub fn userData(allocator, name: []const u8) ![]u8   // name only labels the comment
pub const EnvInput = struct {
    name: []const u8, secret_hex: []const u8, authorized_b64: []const u8, host_key_b64: []const u8,
    provider_keys: []const []const u8, provider_lines: []const []const u8,
};
pub fn envFile(allocator, in: EnvInput) ![]const u8
pub const StartInput = struct {
    name: []const u8, container: []const u8, image: []const u8, registry: []const u8,
    user: []const u8, token: []const u8, env_text: []const u8,
};
pub fn startScript(allocator, in: StartInput) ![]const u8
```

`dockerAuth` parses the docker config JSON with `json.parse` /
`json.object(&.{"auths"})` / `.get(registry)`, reads its `auth` string, base64
decodes it (`util.b64decode`) and splits at the first `:`; returns the raw
`auth` string (for `dockerConfig`) plus the decoded user and token. Any missing
or malformed piece returns null (a public source registry needs no entry).
`dockerConfig` renders a minimal config for `crane`: each `registry` and `auth`
value is already registry/base64-safe, so the renderer is a formatted string;
the file is written 0600 and the directory is removed after the copy.

`userData` returns exactly:

```sh
#!/bin/sh
set -eu
# yolo ec2 session {name}: Docker for the harness container (the start command
# comes over SSM once the agent is online).
dnf install -y docker
systemctl enable --now docker
```

`envFile` returns these lines, `\n`-terminated:

```
YOLO_MODE=datum
SESSION_NAME={name}
IROH_SECRET={secret_hex}
AUTHORIZED_KEYS_B64={authorized_b64}
SSH_HOST_KEY_B64={host_key_b64}
PROVIDER_KEYS={provider_keys joined by one space}
{provider_lines, one per line: the valid KEY=value lines from providers.env}
```

(`init.sh` base64-decodes the two `_B64` values once; there is no Kubernetes
base64 layer here, so they are `b64encode(authorized_text)` and
`b64encode(host_key_text)`.)

`startScript` returns a POSIX sh script (every interpolation through
`shellQuote`; the env file is a quoted heredoc with delimiter
`YOLO_EC2_ENV`):

```sh
set -eu
mkdir -p /opt/yolo && chmod 700 /opt/yolo
cat > /opt/yolo/session.env <<'YOLO_EC2_ENV'
{env_text}
YOLO_EC2_ENV
chmod 600 /opt/yolo/session.env
i=0
until docker info >/dev/null 2>&1; do
  i=$((i+1)); [ "$i" -gt 120 ] && { echo "docker isn't running after 4 min" >&2; exit 1; }
  sleep 2
done
if [ -n '{token}' ]; then
  printf '%s' '{token}' | docker login '{registry}' -u '{user}' --password-stdin
fi
# For ECR: user is 'AWS' and token is `aws ecr get-login-password`.
docker pull '{image}'
docker rm -f '{container}' >/dev/null 2>&1 || true
docker run -d --name '{container}' --hostname '{name}' --restart unless-stopped \
  --cap-add NET_ADMIN --log-opt max-size=10m --log-opt max-file=3 \
  --env-file /opt/yolo/session.env '{image}'
[ -n '{token}' ] && docker logout '{registry}' >/dev/null 2>&1 || true
```

IO boundary:

```zig
pub fn ec2New(ctx, root, name, harness, opts: []const []const u8) u8
pub fn ec2Attach(ctx, name, args: []const []const u8) u8
pub fn ec2Ls(ctx, full: bool) u8
pub fn ec2Logs(ctx, name, args: []const []const u8) u8
pub fn ec2Rm(ctx, name) u8
fn ssmRun(ctx, p: infra.Profile, instance: []const u8, script: []const u8, timeout_s: i64, delete: bool) SsmResult
```

**`ec2New`**, in this order (nothing is created before step 5):

1. Parse options; `--profile NAME`, `--region NAME`, `--key PUBKEY_FILE`; anything
   else dies `ec2: unknown option {s}`. Defaults: profile = flag, else
   `$AWS_PROFILE`, else `default`; region = flag, else `$AWS_REGION`, else
   `$AWS_DEFAULT_REGION`, else `aws configure get region --profile {profile}`
   (trimmed; empty → `us-east-1`); `p = .{ .profile, .region }`. Die `the aws
   CLI isn't in PATH` when `util.findExecutable(ctx, "aws") == null`.
2. Resolve the pinned source: `ctx.opt("EC2_IMAGE", "")`, else
   `images.lookupImage(ctx, join(root, "image/images-general-purpose"), harness)`;
   missing → die `ec2: no general-purpose image for harness '{s}' in {s} (yolo
   build {s} --backend datum --class general-purpose)`; `digest =
   imageDigest(source) orelse die ec2: the pinned image {s} has no digest`.
3. Mirror it into the session's ECR:
   `account = awsFor(ctx, p, &.{ "sts", "get-caller-identity", "--query",
   "Account", "--output", "text" })`, `registry = ecrRegistry(account, region)`,
   `repo = ecrRepo(harness)`, `ecr_ref = "{registry}/{repo}@{digest}"`.
   Ensure the repository: `ecr describe-repositories --repository-names {repo}`
   via `awsTry`; when it fails run `ecr create-repository --repository-name
   {repo}` with `awsFor`, then `describe-repositories` again (a concurrent
   create is the only acceptable race; two failures are fatal). When `ecr
   describe-images --repository-name {repo} --image-ids imageDigest={digest}`
   succeeds, the image is already there. Otherwise copy it:
   - `password = awsFor(ctx, p, &.{ "ecr", "get-login-password" })`;
   - `src = dockerAuth(host config, registryOf(source))`, with `config_text`
     from `$DOCKER_CONFIG/config.json` else `~/.docker/config.json` (null for a
     public source);
   - write `$TMPDIR/yolo-ec2-docker-{pid}/config.json` (0600) with
     `dockerConfig(&.{ .{ .registry = registryOf(source), .auth = src.?.auth }
     if src != null, .{ .registry = registry, .auth = b64encode("AWS:" ++
     password) } })` and `ctx.setEnv("DOCKER_CONFIG", that directory)`;
   - die `ec2: crane isn't in PATH (use the flake's yolo)` when
     `util.findExecutable(ctx, "crane") == null`;
   - `crane copy {source} {registry}/{repo}:{ecrTag(digest)}` via
     `util.capture`; non-zero or a spawn error → die `ec2: could not copy
     {source} to ECR: {trimmed stderr}`;
   - verify `ecr describe-images --image-ids imageDigest={digest}`; if ECR
     stored another digest, read `imageDigest` for `imageTag={ecrTag(digest)}`
     and use that digest in `ecr_ref` instead;
   - remove the temp directory (`DOCKER_CONFIG` stays set; only crane/docker
     read it and `new` spawns neither again).
4. `authorized = keys.authorizedKeys(ctx, key)` (map `error.NoPublicKey` to
   `util.die(keys.no_public_key)`),
   `instance_type = ctx.opt("EC2_INSTANCE_TYPE", "t3a.large")`,
   `disk_gb = ctx.opt("EC2_DISK_GB", "20")`.
5. `dir = session.create(ctx, name, "ec2", harness)`; write `profile` and
   `region` (`{s}\n` each), `image` = `{ecr_ref}\n`, `state` = `launching\n`,
   `authorized_keys` = `authorized` (raw), then
   `k = keys.prepareIrohSession(ctx, dir, containerName, relay)` with
   `containerName = docker.containerName(ctx.arena, name)` (`yolo-NAME`) and
   `relay = ctx.opt("RELAY", datum.default_relay)`; call
   `keys.recordIdentity(ctx, dir, key)`.
6. `sg = infra.ensureSecurityGroupFor(ctx, p, containerTag)`,
   `infra.ensureInstanceProfileFor(ctx, p, containerTag)`.
7. `ami = infra.awsFor(ctx, p, &.{ "ssm", "get-parameter", "--name", aml2023_ami,
   "--query", "Parameter.Value", "--output", "text" })`;
   `root_dev = infra.awsFor(ctx, p, &.{ "ec2", "describe-images", "--image-ids",
   ami, "--query", "Images[0].RootDeviceName", "--output", "text" })`.
8. Write `userData` to `$TMPDIR/yolo-ec2-user-data-{pid}` and run
   `ec2 run-instances` with exactly: `--image-id {ami} --instance-type
   {instance_type} --security-group-ids {sg} --iam-instance-profile
   Name={containerTag} --block-device-mappings
   DeviceName={root_dev},Ebs={VolumeSize={disk_gb},VolumeType=gp3,DeleteOnTermination=true}
   --metadata-options HttpTokens=required,HttpPutResponseHopLimit=1
   --user-data file://{path} --tag-specifications
   ResourceType=instance,Tags=[{Key=Name,Value=yolo-NAME},{Key=yolo,Value=1},{Key=yolo-session,Value=NAME},{Key=yolo-harness,Value=HARNESS}]
   --query Instances[0].InstanceId --output text`. Remove the user-data file.
   Write the id to `instance`; `state` = `starting\n`.
   Print `launched {id} ({container}, profile {p.profile}, {p.region})` to
   stderr.
9. `infra.waitSsmOnline(ctx, p, id, name)`; then read `host_key` text and build
   the env file (`AUTHORIZED_KEYS_B64 = b64encode(authorized)`,
   `SSH_HOST_KEY_B64 = b64encode(host_key)`), provider key names and lines from
   `ctx.opt("PROVIDERS_ENV", ~/.config/yolo/providers.env)` using
   `util.providerName` (same filter as `dockerNew`), and the start script with
   `StartInput{ .name, .container, .image = ecr_ref, .registry = registry,
   .user = "AWS", .token = awsFor(ctx, p, &.{ "ecr", "get-login-password" }),
   .env_text }`; `ssmRun(ctx, p, id, script, 900, true)` (the fresh ECR token is
   in this command, hence the delete). Print its stdout and stderr to
   **stderr**; non-zero → write `state` = `failed\n`, die `ec2: the session did
   not start: {StatusDetails} (yolo logs {name})`.
10. `waitForSsh` (private in ec2.zig, modeled on datum.zig's): loop
    `ssh -o ConnectTimeout=20 -o BatchMode=yes true` built with
    `session.sshArgs`, every 10 s, up to 600 s; timeout → `state` =
    `failed\n`, die `no SSH after 10 min; try: yolo logs {name}`. Success:
    remove `state`, print `ready after {d}s: yolo attach {name}` to stderr.

**`ssmRun`** (private): base64 the script (`util.b64encode`) and write the
parameters file `{"commands":["printf '%s' '<b64>' | base64 -d | sh"]}` to
`$TMPDIR/yolo-ec2-ssm-{pid}.json`; die `ec2: the session setup is too large for
an SSM command ({d} bytes)` when that text exceeds 22000 bytes. Then `aws ssm
send-command --document-name AWS-RunShellScript --instance-ids {id}
--parameters file://{path} --timeout-seconds {timeout_s} --query
Command.CommandId --output text`; poll `aws ssm get-command-invocation
--command-id {cid} --instance-id {id} --query
"[Status,StatusDetails,ResponseCode,StandardOutputContent,StandardErrorContent]"
--output json` every 2 s until `Status` is not `Pending`/`InProgress`/`Delayed`/
`Cancelling` or `timeout_s + 60` elapse (die `the command on the instance
didn't finish`). Remove the params file; when `delete`, run `aws ssm
delete-command --command-id {cid}` quietly (best effort — the start command
holds the registry token and session keys). Return `code` (`ResponseCode`,
0 when null), stdout, stderr, `StatusDetails`.

**`ec2Attach`**: die `no local state for {name}` without `ticket`; read
`ticket`, `identity`; `util.replace(ctx, session.sshArgs(ctx, .{ .dir = dir,
.alias = containerName, .ticket = ticket, .identity = ident, .user =
ctx.opt("USER", "drewr"), .forward_agent = mem.eql(u8, ctx.opt("FORWARD_AGENT",
"1"), "1"), .args = args }))` — exec, so the exit code is ssh's.

**`ec2Logs`**: read `profile`, `region`, `instance` (die `no local state` /
`ec2: no instance recorded for {name}`); any arg equal to `-f` or `--follow`
dies `ec2: logs can't follow (-f) through SSM; run it again for a snapshot`.
Command: `docker logs [--tail 2000 when args is empty] {args, each through
shellQuote} {container through shellQuote}`; `ssmRun(..., 180, false)`; write stdout to stdout and stderr to
stderr; return the code. SSM truncates command output at 24 KB, hence the
default `--tail 2000`.

**`ec2Ls`**: group `session.localSessions(ctx, "ec2")` by the `profile` +
`region` files (missing files fall back to `default` / `us-east-1`); for each group call `infra.awsTry(ctx, p, &.{ "ec2",
"describe-instances", "--instance-ids", ids..., "--query",
"Reservations[].Instances[].[InstanceId,State.Name,InstanceType]", "--output",
"text" })`. On failure warn `can't list ec2 sessions in {profile} ({region}):
{stderr}` and skip the group. Before each table print `profile {profile},
{region}` (like docker's `runtime: {exe}`), then one `util.renderTable` table
with header `NAME INSTANCE STATE TYPE`; a session whose recorded id is absent from
the answer gets state `gone` and type `-`. `_ = full;` (like datum).

**`ec2Rm`**: die `no local state for {name}` without the session dir. Read
`profile`/`region`; when `instance` exists, run `ec2 terminate-instances
--instance-ids {id}` via `infra.awsTry`. Failure: warn `couldn't terminate {id}
({stderr}); keeping {name}'s state (aws sso login --profile {p.profile}?)` and
return 1 **without** removing the directory (so the instance isn't orphaned).
Success or no recorded instance: print `terminated {id}` to stderr, remove the
session directory, return 0. `rm` never touches ECR: the mirrored digest stays
cached for the next session, and old digests accumulate until deleted (the
README says so; a lifecycle rule is the operator's choice).

### 4. `src/main.zig`: wire the backend (depends on 3)

- Import `ec2.zig`; add `ec2: void` to `Backend`; arms:
  `new => |_| ec2.ec2New(ctx, root, name, harness, opts)`,
  `attach => |_| ec2.ec2Attach(ctx, name, args)`,
  `ls => |_| ec2.ec2Ls(ctx, full)`,
  `logs => |_| ec2.ec2Logs(ctx, name, args)`,
  `rm => |_| ec2.ec2Rm(ctx, name)`.
- `loadBackend`: `if (std.mem.eql(u8, which, "ec2")) return .{ .ec2 = {} };`
- `lsBackend`: `if (std.mem.eql(u8, which, "ec2")) return ec2.ec2Ls(ctx, full);`
- Update both unknown-backend messages to `unknown backend '{s}' (docker, datum
  or ec2)`.
- `usage`: `yolo new NAME [--backend docker|datum|ec2] ...`; add to the
  backend-options block after the datum lines:
  `  ec2     --profile NAME            AWS profile for the instance (default
  $AWS_PROFILE, else default)`, `          --region NAME             region
  (default the profile's, else us-east-1)`, `          --key PUBKEY_FILE
  authorize this key instead of the agent's`.
- `cmdNew`'s `yolo die` usage string gains `|ec2`.
- The file doc comment: "locally (docker or podman), on Datum Compute, or on AWS
  EC2"; `Backend`'s comment stays ("a new backend is a new arm here plus its
  name in loadBackend").

### 5. Tests and docs

- `src/ec2.zig` `test` blocks (pure only, no AWS):
  - `envFile` for fixed input equals the six-line header + provider lines;
  - `shellQuote("a'b")` == `'a'\''b'` and `startScript` contains
    `--name 'yolo-x'`, the `docker login` line only with a token, and the
    `docker run ... --env-file` line;
  - `registryOf("ghcr.io/drewr/agent-claude@sha256:..")` == `ghcr.io`,
    `registryOf("agent-claude:latest")` == `""`;
  - `imageDigest("ghcr.io/d/r@sha256:abcd")` == `sha256:abcd`, and null without
    `@`; `ecrRegistry("123", "us-east-2")` ==
    `123.dkr.ecr.us-east-2.amazonaws.com`; `ecrRepo("claude")` ==
    `yolo/agent-claude`; `ecrTag("sha256:abcdef1234567890")` ==
    `gp-abcdef123456`;
  - `dockerConfig` renders `{"auths":{"a":{"auth":"x"},"b":{"auth":"y"}}}` for
    two entries;
  - `dockerAuth` on a config with base64 `user:token` returns both, on `{}` /
    bad base64 returns null;
  - `userData` contains `dnf install -y docker`.
- `src/golden_test.zig`: the three ssh-args tests call `session.splitSshArgs`.
- `README.md`: intro "locally (Docker or Podman), on Datum Compute, or on AWS
  EC2"; add an `ec2` column to the Backends table (runs on: "EC2 instance
  `yolo-NAME`, AL2023 + Docker, the profile/region given at `new`"; attach:
  "SSH over iroh, host key pinned; no inbound ports"; HOME: "the container's
  `/home/agent` on the instance, gone at `rm`"; workspaces: "in the instance's
  container, gone at `rm`"; provider keys: "`~/.config/yolo/providers.env`,
  passed in the container's env file"; SSH agent: "forwarded while attached";
  images: "the general-purpose pins in `image/images-general-purpose`,
  copied into ECR in the session's account with `crane` (once per digest) and
  pulled with a one-time ECR token"). Add one sentence: EC2 sessions are
  instances and keep running (and billing) until `yolo rm`; choose the account
  with `--profile` or `$AWS_PROFILE`; repositories are created on first use,
  and ECR storage costs ~$0.03/month per 329 MB harness image (in-region pulls
  are free) until the image/digest is deleted — repeated builds add digests;
  the default t3a.large + 20 GB gp3 instance is ~$0.075/hour (~$55/month if
  left running), overridable with `YOLO_EC2_INSTANCE_TYPE`/`YOLO_EC2_DISK_GB`.
  Requirements: "ec2 backend: `aws` logged in to the chosen profile (`aws sso
  login --profile NAME`) with ECR permissions, `docker login ghcr.io` so
  `crane` can read the private pinned images, `crane` (from the flake),
  `ssh`/`ssh-keygen`, and `dumbpipe` (from the flake)".
- `AGENTS.md`: add `ec2` to the module list and to the "runs ... on two
  backends" sentence; mention in Structure that `ec2.zig` launches instances
  and uses SSM.

## Critical files & anchors

- `src/ec2.zig` (new): the whole backend; `ec2New` ordering above is the
  behavior spec.
- `flake.nix`: the wrapper's `tools` list (~line 30) gains `crane`, the
  comment and the flake description mention EC2.
- `src/main.zig`: `Backend` union (~line 28), `loadBackend` (~55), `lsBackend`
  (~290), `usage` (~75), `cmdNew` parse (~275).
- `src/infra.zig`: `aws`/`awsArgs` (~183-200), `ensureSecurityGroup` /
  `ensureInstanceProfile` / `defaultVpc` (~525-620), `boxTicket` (~300).
- `src/session.zig`: move-in point after `workload` (~line 150); `src/keys.zig`
  after `publicKeyOf` (~line 195).
- `src/datum.zig`: `datumNew` key block (~150-210), `datumSsh` (~330-370),
  `splitSshArgs`/`isValueOption` (~380-410).

## Verification

Static (from the repo root):

1. `nix develop -c zig build test` — the new ec2 pure tests and the moved
   ssh-args tests pass.
2. `nix develop -c zig fmt --check src build.zig` and `nix develop -c zig build
   -Doptimize=ReleaseSafe` succeed; `nix build` succeeds (ReleaseSafe + tests).
3. `./result/bin/yolo help` prints the ec2 backend and its options; `yolo ls`
   and `yolo version` still work.

Live (requires a live AWS login with ECR permissions, `docker login ghcr.io`,
and the flake's `crane`; use a scratch state directory so nothing else is
touched). Use the repo's sandbox profile `datum-sandbox-admin` (region
`us-east-2`) for `P`/`R` unless told otherwise:

```sh
export YOLO_STATE=$(mktemp -d)/sessions
aws sso login --profile P            # P = a profile with EC2 + SSM + IAM perms
./result/bin/yolo new e2e --backend ec2 --profile P
```

Expected, in order: on the first run for that harness/account/region, a
`crane copy` of the pinned image into ECR (no output on later runs);
`launched i-... (yolo-e2e, profile P, us-east-2)` on stderr; the start
command's `docker pull <account>.dkr.ecr...`/`docker run` output; `ready after
Ns: yolo attach e2e`. Then:

- `aws --profile P --region R ecr describe-images --repository-name
  yolo/agent-claude --image-ids imageDigest=<pinned digest> --query
  'imageDetails[0].imageDigest' --output text` prints the pinned digest (the
  copy preserved it), and `cat "$YOLO_STATE/e2e/image"` is
  `<account>.dkr.ecr.<region>.amazonaws.com/yolo/agent-claude@sha256:...`.
- A second `yolo new e2e2 --backend ec2 --profile P --agent claude` skips the
  copy (no `crane` run) and starts from the ECR image.

- `./result/bin/yolo attach e2e -- hostname` prints `e2e` and exits 0 (SSH over
  iroh to the pinned host key; the process is exec'd, so the exit code is the
  remote's).
- `./result/bin/yolo logs e2e` prints init's `[agent] mem:` / `harness: claude`
  / `mode: datum` lines (`[agent] keys: N authorized` included).
- `./result/bin/yolo ls` shows `e2e  ec2  claude  -  -` in the top table and an
  `== ec2` table with `e2e  i-...  running  t3a.large`.
- `python3 -c`-free check of the recorded profile: `cat
  "$YOLO_STATE/e2e/profile"` is `P`. With `AWS_PROFILE=default` exported (and
  no `--profile`), `yolo attach e2e -- true` still works and `yolo logs e2e`
  still reads the instance — proving later commands use the recorded profile.
- `./result/bin/yolo new e2e2 --backend ec2` with `AWS_PROFILE=P` records `P`
  in `$YOLO_STATE/e2e2/profile`; `yolo rm e2e2` terminates it.
- `./result/bin/yolo rm e2e` prints `terminated i-...` and removes
  `$YOLO_STATE/e2e`; `aws --profile P --region R ec2 describe-instances
  --instance-ids i-... --query 'Reservations[].Instances[].State.Name'` reports
  `shutting-down`/`terminated`.

Negative checks: `yolo new x --backend ec2 --profile no-such-profile` dies with
the aws CLI's error (and the SSO hint when the login expired); `yolo logs e2e
-f` dies with the SSM follow message; `yolo new x --backend ec2 --bogus` dies
`ec2: unknown option --bogus` before creating anything. Every instance created
during verification is `yolo rm`'d afterwards (instances bill until then).

## Assumptions & contingencies

- The chosen profile can create an IAM role/instance profile for SSM
  (`AmazonSSMManagedInstanceCore`), security groups, and instances, and send SSM
  commands. A failure surfaces as the aws CLI's error; `rm` keeps the local
  state until termination succeeds.
- AWS credentials are live. During planning all local profiles were expired
  (`Token has expired`, `aws login`), so the AL2023 public parameter
  `aml2023_ami` and the `docker` package were **not** confirmed against the
  account (unverified — confirm first). Contingency: if `dnf install -y docker`
  fails on AL2023, switch the AMI lookup to the ECS-optimized AL2023 public
  parameter `/aws/service/ecs/optimized-ami/amazon-linux-2023/recommended` and
  drop the `dnf`/`systemctl` lines from `userData` (that AMI ships Docker); no
  other step changes.
- The images are private (verified): the host needs `docker login ghcr.io`,
  and `crane` reads it through a temporary `DOCKER_CONFIG` that also carries
  the ECR token; the instance only ever sees the ECR token. That token (12 h,
  minted by `aws ecr get-login-password`) is in the SSM start command, which is
  deleted after it runs; the instance profile needs no ECR permissions.
- The caller's profile needs `sts:GetCallerIdentity`, `ecr:DescribeRepositories`,
  `ecr:CreateRepository`, `ecr:DescribeImages`, `ecr:GetAuthorizationToken` and
  crane's push permissions (`ecr:BatchCheckLayerAvailability`,
  `ecr:InitiateLayerUpload`, `ecr:UploadLayerPart`, `ecr:CompleteLayerUpload`,
  `ecr:PutImage`). A failure surfaces as the aws CLI's error or crane's.
- ECR accepts the OCI manifest and keeps the digest. Contingency (implemented
  in step 3): if the copy lands under a different digest, resolve the
  destination tag's digest and use it in the ref; if `crane copy` itself fails,
  nothing is recorded and the session directory is removed before dieing.
- Live verification uses `datum-sandbox-admin` / `us-east-2` (the repo's
  sandbox profile) unless the implementer is told otherwise.
- There is no shared home for ec2 sessions: `HOME` and `/work` live in the
  instance's container and are destroyed by `yolo rm`. Git identity can be set
  once per instance by attaching and running `git config --global`.
- `yolo attach NAME args` is the session's SSH command line: `--profile` is
  **not** accepted there; the profile recorded at `new` is used. Passing it
  would be offered to ssh as an option.
