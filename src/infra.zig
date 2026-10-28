//! The EC2 boxes whose NixOS configs live in this repo: the image build box
//! (infra/buildbox/ec2) and the JuiceFS metadata host for the shared home
//! (infra/meta/ec2). Idempotent for the security group and IAM role; `launch`
//! starts a new instance each time, so check `status` first. REV must be
//! pushed: the box fetches github:drewr/yolo/REV?dir=CONFIG#ATTR. Uses the aws
//! CLI from PATH with $AWS_PROFILE (default datum-sandbox-admin); TYPE,
//! DISK_GB and IPV6=1 override a box's defaults.

const std = @import("std");
const mem = std.mem;

const util = @import("util.zig");
const main = @import("main.zig");
const Ctx = util.Ctx;

// ---------------------------------------------------------------------------
// Pure
// ---------------------------------------------------------------------------

/// The i-th /64 of an Amazon /56 block (its fourth group's low byte).
pub const SubnetError = error{BadBlock} || mem.Allocator.Error;

pub fn subnet64(allocator: mem.Allocator, block: []const u8, i: u32) SubnetError![]const u8 {
    const addr = if (mem.indexOfScalar(u8, block, '/')) |s| block[0..s] else block;
    var left: []const u8 = addr;
    var right: []const u8 = "";
    if (mem.indexOf(u8, addr, "::")) |at| {
        left = addr[0..at];
        right = addr[at + 2 ..];
    }
    var groups: std.ArrayList(u16) = .empty;
    if (left.len != 0) {
        var it = mem.splitScalar(u8, left, ':');
        while (it.next()) |g| try groups.append(allocator, try hexGroup(block, g));
    }
    var right_groups: std.ArrayList(u16) = .empty;
    if (right.len != 0) {
        var it = mem.splitScalar(u8, right, ':');
        while (it.next()) |g| try right_groups.append(allocator, try hexGroup(block, g));
    }
    const fill = 8 -| (groups.items.len + right_groups.items.len);
    var full: std.ArrayList(u16) = .empty;
    try full.appendSlice(allocator, groups.items);
    try full.appendNTimes(allocator, 0, fill);
    try full.appendSlice(allocator, right_groups.items);
    if (full.items.len != 8 or i > 255) return error.BadBlock;
    const g3: u16 = (full.items[3] & 0xff00) | @as(u16, @intCast(i));
    return std.fmt.allocPrint(allocator, "{x}:{x}:{x}:{x}::/64", .{
        full.items[0], full.items[1], full.items[2], g3,
    });
}

fn hexGroup(block: []const u8, g: []const u8) SubnetError!u16 {
    _ = block;
    if (g.len == 0 or g.len > 4) return error.BadBlock;
    for (g) |c| {
        if (!std.ascii.isHex(c)) return error.BadBlock;
    }
    return std.fmt.parseInt(u16, g, 16) catch error.BadBlock;
}

pub const Box = struct {
    name: []const u8,
    region: []const u8,
    instance_type: []const u8,
    disk_gb: []const u8,
    /// The NixOS flake's directory in this repo.
    config_dir: []const u8,
    /// Its nixosConfigurations attribute.
    attr: []const u8,
    /// Where the box writes its dumbpipe ticket.
    ticket_file: []const u8,
    /// Public IPv6 (sets up the VPC once).
    ipv6: bool,
    profile: []const u8,
};

/// A box's defaults, before $TYPE/$DISK_GB/$IPV6 (`boxConfig`).
pub fn boxDefaults(which: []const u8) Box {
    if (mem.eql(u8, which, "buildbox")) {
        // 8 GB: the bigger harness images wedged a 4 GB box. The agent image is
        // ~4 GB and staged 3-4 times, hence the disk.
        return .{
            .name = "datum-buildbox",
            .region = "us-east-2",
            .instance_type = "t3a.large",
            .disk_gb = "64",
            .config_dir = "infra/buildbox/ec2",
            .attr = "buildbox",
            .ticket_file = "/var/lib/dumbpipe/ticket",
            .ipv6 = false,
            .profile = "datum-sandbox-admin",
        };
    }
    if (mem.eql(u8, which, "meta")) {
        // Same metro as Datum us-east-1 (IAD); IPv6 so Datum's IPv6-only
        // sandboxes reach it directly over iroh rather than through the relay.
        return .{
            .name = "agent-meta",
            .region = "us-east-1",
            .instance_type = "t3a.small",
            .disk_gb = "16",
            .config_dir = "infra/meta/ec2",
            .attr = "agentmeta",
            .ticket_file = "/var/lib/agent-meta/ticket",
            .ipv6 = true,
            .profile = "datum-sandbox-admin",
        };
    }
    util.dief("unknown box '{s}' (buildbox or meta)", .{which});
}

/// The user-data script a launch gives the instance: apply the box's config,
/// pinned to `rev`, on every boot.
pub fn userData(allocator: mem.Allocator, b: Box, rev: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator,
        \\#!/bin/sh
        \\# Apply the {s} config pinned to {s}. Re-runs on every boot as a no-op.
        \\nixos-rebuild switch --option experimental-features 'nix-command flakes' \
        \\  --flake 'github:drewr/yolo/{s}?dir={s}#{s}'
        \\
    , .{ b.attr, rev, rev, b.config_dir, b.attr });
}

/// argv for the aws CLI, with the box's profile and region.
pub fn awsArgs(allocator: mem.Allocator, b: Box, args: []const []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    try out.appendSlice(allocator, &.{ "aws", "--profile", b.profile, "--region", b.region });
    try out.appendSlice(allocator, args);
    return out.items;
}

pub const SsoExpired = enum {
    /// Not an SSO/credential problem.
    no,
    /// An expired login: the hint to log in again.
    yes,

    pub fn detect(err: []const u8) SsoExpired {
        for ([_][]const u8{ "Token has expired", "token is expired", "SSO session", "sso login", "Unable to locate credentials" }) |needle| {
            if (mem.indexOf(u8, err, needle) != null) return .yes;
        }
        return .no;
    }
};

// ---------------------------------------------------------------------------
// IO boundary — everything below does IO
// ---------------------------------------------------------------------------

/// A box's settings with the environment's overrides (`boxConfig`).
pub fn boxConfig(ctx: Ctx, which: []const u8) Box {
    var b = boxDefaults(which);
    if (ctx.envNonEmpty("TYPE")) |t| b.instance_type = t;
    if (ctx.envNonEmpty("DISK_GB")) |d| b.disk_gb = d;
    if (ctx.envNonEmpty("IPV6")) |v6| b.ipv6 = mem.eql(u8, v6, "1");
    if (ctx.envNonEmpty("AWS_PROFILE")) |p| b.profile = p;
    return b;
}

/// The aws CLI's trimmed stdout, with the box's profile and region; dies with
/// its error, or with how to log in when the SSO session has expired (`aws`).
fn aws(ctx: Ctx, b: Box, args: []const []const u8) []const u8 {
    const argv = awsArgs(ctx.arena, b, args) catch util.die("out of memory");
    const r = util.capture(ctx, argv, .{}) catch util.die("the aws CLI isn't in PATH");
    if (r.term != .exited or r.code != 0) {
        if (SsoExpired.detect(r.stderr) == .yes)
            util.dief("AWS login needed for profile {s}: aws sso login --profile {s}", .{ b.profile, b.profile });
        util.dief("aws {s} {s}: {s}", .{ args[0], if (args.len > 1) args[1] else "", util.trim(r.stderr) });
    }
    return util.trim(r.stdout);
}

pub fn cmd(ctx: Ctx, root: []const u8, args: []const []const u8) u8 {
    if (args.len == 0) infraUsage();
    const b = boxConfig(ctx, args[0]);
    const c = args[1..];
    if (c.len == 1 and mem.eql(u8, c[0], "launch")) return launchBox(ctx, root, b, null);
    if (c.len == 2 and mem.eql(u8, c[0], "launch")) return launchBox(ctx, root, b, c[1]);
    if (c.len == 1 and mem.eql(u8, c[0], "ticket")) {
        util.say(boxTicket(ctx, b));
        return 0;
    }
    if (c.len == 1 and mem.eql(u8, c[0], "ipv6")) return ensureIpv6Cmd(ctx, b);
    if (c.len == 1 and mem.eql(u8, c[0], "start")) {
        startBox(ctx, b);
        return 0;
    }
    if (c.len == 1 and mem.eql(u8, c[0], "stop")) {
        _ = aws(ctx, b, &.{ "ec2", "stop-instances", "--instance-ids", instanceId(ctx, b) });
        return 0;
    }
    if (c.len == 1 and mem.eql(u8, c[0], "terminate")) {
        _ = aws(ctx, b, &.{ "ec2", "terminate-instances", "--instance-ids", instanceId(ctx, b) });
        return 0;
    }
    if (c.len == 0 or (c.len == 1 and mem.eql(u8, c[0], "status"))) {
        status(ctx, b);
        return 0;
    }
    if (c.len <= 2 and mem.eql(u8, c[0], "tunnel") and mem.eql(u8, args[0], "buildbox")) {
        const port = if (c.len == 2) c[1] else "12340";
        const tk = buildboxTicket(ctx, b);
        util.errPrint("BuildKit at tcp://127.0.0.1:{s} (ctrl-c to close)\n", .{port});
        const connect = std.fmt.allocPrint(ctx.arena, "127.0.0.1:{s}", .{port}) catch "";
        util.replace(ctx, &.{ "dumbpipe", "connect-tcp", "--addr", connect, tk });
    }
    infraUsage();
}

fn infraUsage() noreturn {
    util.die("usage: yolo infra buildbox|meta launch [REV] | ticket | ipv6 | start | stop | status | terminate | tunnel [PORT]");
}

fn status(ctx: Ctx, b: Box) void {
    util.say(aws(ctx, b, &.{
        "ec2",
        "describe-instances",
        "--filters",
        std.fmt.allocPrint(ctx.arena, "Name=tag:Name,Values={s}", .{b.name}) catch "",
        "--query",
        "Reservations[].Instances[].[InstanceId,State.Name,InstanceType,Tags[?Key==`rev`]|[0].Value]",
        "--output",
        "table",
    }));
}

/// For `yolo infra ipv6`: give an instance launched before IPV6=1 an address
/// now, unless it has one.
fn ensureIpv6Cmd(ctx: Ctx, b: Box) u8 {
    ensureIpv6(ctx, b);
    const i = instanceId(ctx, b);
    const nic = struct {
        fn query(ctx_: Ctx, b_: Box, i_: []const u8, q: []const u8) []const u8 {
            return aws(ctx_, b_, &.{
                "ec2",     "describe-instances",                                                                                   "--instance-ids", i_,
                "--query", std.fmt.allocPrint(ctx_.arena, "Reservations[0].Instances[0].NetworkInterfaces[0].{s}", .{q}) catch "", "--output",       "text",
            });
        }
    };
    const existing = nic.query(ctx, b, i, "Ipv6Addresses[0].Ipv6Address");
    if (!mem.eql(u8, existing, "") and !mem.eql(u8, existing, "None")) {
        util.say(existing);
        return 0;
    }
    const eni = nic.query(ctx, b, i, "NetworkInterfaceId");
    const assigned = aws(ctx, b, &.{
        "ec2",                    "assign-ipv6-addresses", "--ipv6-address-count", "1",
        "--network-interface-id", eni,                     "--query",              "AssignedIpv6Addresses[0]",
        "--output",               "text",
    });
    util.say(assigned);
    return 0;
}

/// The box's instance and state (any state but terminated), if there is one
/// (`findInstance`).
fn findInstance(ctx: Ctx, b: Box) ?struct { id: []const u8, state: []const u8 } {
    const out = aws(ctx, b, &.{
        "ec2",
        "describe-instances",
        "--filters",
        std.fmt.allocPrint(ctx.arena, "Name=tag:Name,Values={s}", .{b.name}) catch "",
        "Name=instance-state-name,Values=pending,running,stopping,stopped",
        "--query",
        "Reservations[].Instances[].[InstanceId,State.Name]",
        "--output",
        "text",
    });
    var it = mem.tokenizeAny(u8, out, " \t\n\r");
    const id = it.next() orelse return null;
    const state = it.next() orelse return null;
    return .{ .id = id, .state = state };
}

fn instanceId(ctx: Ctx, b: Box) []const u8 {
    const found = findInstance(ctx, b) orelse
        util.dief("no instance named {s} (yolo infra ... launch)", .{b.name});
    return found.id;
}

/// Start the box if it's stopped (or stopping), and wait until it runs
/// (`startBox`).
fn startBox(ctx: Ctx, b: Box) void {
    const found = findInstance(ctx, b) orelse
        util.dief("no instance named {s} (yolo infra ... launch)", .{b.name});
    if (mem.eql(u8, found.state, "stopping"))
        _ = aws(ctx, b, &.{ "ec2", "wait", "instance-stopped", "--instance-ids", found.id });
    if (mem.eql(u8, found.state, "stopped") or mem.eql(u8, found.state, "stopping")) {
        util.errPrint("yolo: starting {s} ({s})\n", .{ b.name, found.id });
        _ = aws(ctx, b, &.{ "ec2", "start-instances", "--instance-ids", found.id });
    }
    _ = aws(ctx, b, &.{ "ec2", "wait", "instance-running", "--instance-ids", found.id });
}

/// The box's dumbpipe ticket, read on the box over SSM (it must be running).
fn boxTicket(ctx: Ctx, b: Box) []const u8 {
    const i = instanceId(ctx, b);
    // SSM's agent registers a while after EC2 reports the instance running.
    const t0 = util.monoNow(ctx);
    while (true) {
        const st = aws(ctx, b, &.{
            "ssm",                                                                      "describe-instance-information", "--filters",
            std.fmt.allocPrint(ctx.arena, "Key=InstanceIds,Values={s}", .{i}) catch "", "--query",                       "InstanceInformationList[0].PingStatus",
            "--output",                                                                 "text",
        });
        if (mem.eql(u8, st, "Online")) break;
        if (util.secondsSince(ctx, t0) >= 300)
            util.dief("{s} isn't reachable over SSM after 5 min (SSM status: {s})", .{ b.name, st });
        util.sleep(ctx, 5000);
    }
    const cmd_id = aws(ctx, b, &.{
        "ssm",          "send-command",                                                                     "--instance-ids", i,                   "--document-name", "AWS-RunShellScript",
        "--parameters", std.fmt.allocPrint(ctx.arena, "commands=[\"cat {s}\"]", .{b.ticket_file}) catch "", "--query",        "Command.CommandId", "--output",        "text",
    });
    _ = aws(ctx, b, &.{ "ssm", "wait", "command-executed", "--command-id", cmd_id, "--instance-id", i });
    return aws(ctx, b, &.{
        "ssm",     "get-command-invocation", "--command-id", cmd_id, "--instance-id", i,
        "--query", "StandardOutputContent",  "--output",     "text",
    });
}

fn ticketFile(ctx: Ctx) []const u8 {
    return util.join(ctx, &.{ util.stateHome(ctx), "agent-sandbox-build/buildbox-ticket" });
}

fn saveTicket(ctx: Ctx, t: []const u8) void {
    const file = ticketFile(ctx);
    util.createDirPath(ctx, std.fs.path.dirname(file) orelse ".") catch |e|
        util.dief("can't create the build state directory: {t}", .{e});
    util.writeFile(ctx, file, std.fmt.allocPrint(ctx.arena, "{s}\n", .{t}) catch "", @fromBackingInt(@intCast(0o600))) catch |e|
        util.dief("can't save the build box ticket: {t}", .{e});
}

/// The build box's ticket: $BUILDBOX_TICKET, else the saved one, else read
/// from the box (starting it if needed) and saved for next time
/// (`buildboxTicket`).
pub fn buildboxTicket(ctx: Ctx, b: Box) []const u8 {
    if (ctx.envNonEmpty("BUILDBOX_TICKET")) |t| return t;
    if (util.readFileMaybe(ctx, ticketFile(ctx))) |saved| {
        const t = util.trim(saved);
        if (t.len != 0) return t;
    }
    util.errPrint("yolo: no saved build box ticket; reading it from the box\n", .{});
    startBox(ctx, b);
    const t = freshTicket(ctx, b);
    saveTicket(ctx, t);
    return t;
}

/// The ticket the box has now; a new box writes it once NixOS has configured
/// it, a few minutes after launch.
fn freshTicket(ctx: Ctx, b: Box) []const u8 {
    const t = boxTicket(ctx, b);
    if (!mem.startsWith(u8, t, "endpoint"))
        util.die("the build box has no ticket yet (still configuring itself after launch?); try again in a few minutes");
    return t;
}

/// Start a dumbpipe tunnel to the build box's BuildKit and wait for the local
/// port; returns the tunnel process (kill it when done), or null when it
/// never came up (`withTunnel`).
pub fn openTunnel(ctx: Ctx, port: []const u8, ticket: []const u8) ?std.process.Child {
    const connect = std.fmt.allocPrint(ctx.arena, "127.0.0.1:{s}", .{port}) catch "";
    const child = util.spawnBackground(ctx, &.{ "dumbpipe", "connect-tcp", "--addr", connect, ticket });
    var n: u8 = 0;
    while (!util.canConnect(ctx, util.parsePort(port)) and n < 30) : (n += 1) util.sleep(ctx, 1000);
    return child;
}

/// The ticket to build with, retrying once with a freshly read one when the
/// box was replaced (`withBuildkit`'s ticket dance); dies with the hint when
/// there is nothing to try.
pub fn buildboxTickets(ctx: Ctx, b: Box) struct { first: []const u8, then: ?[]const u8 } {
    const first = buildboxTicket(ctx, b);
    return .{ .first = first, .then = null };
}

/// Read the box's ticket again after BuildKit didn't answer, saving it when
/// the box was replaced; dies when nothing changed or $BUILDBOX_TICKET is
/// stale (`withBuildkit`).
pub fn refreshTicket(ctx: Ctx, b: Box, old: []const u8) []const u8 {
    const fresh = freshTicket(ctx, b);
    if (mem.eql(u8, fresh, old))
        util.die("BuildKit on the build box isn't answering (yolo infra buildbox status)");
    if (ctx.envNonEmpty("BUILDBOX_TICKET") != null)
        util.dief("$BUILDBOX_TICKET is stale; the box's ticket is now {s}", .{fresh});
    util.errPrint("yolo: the build box has a new ticket (it was replaced); saved it\n", .{});
    saveTicket(ctx, fresh);
    return fresh;
}

/// Whether BuildKit answers through the tunnel, starting the box if it's
/// stopped (it powers itself off after 30 idle minutes) and waiting for it: up
/// to 10 min after a start, 90 s if it was already running
/// (`ensureBuildkit`).
pub fn ensureBuildkit(ctx: Ctx, b: Box, addr: []const u8) bool {
    if (buildkitUp(ctx, addr)) return true;
    var was_running = false;
    if (findInstance(ctx, b)) |found| {
        if (mem.eql(u8, found.state, "running")) {
            was_running = true;
            util.errPrint("yolo: the build box is running but BuildKit isn't answering; waiting\n", .{});
        } else startBox(ctx, b);
    } else util.die("no build box (yolo infra buildbox launch)");
    const t0 = util.monoNow(ctx);
    const limit: i64 = if (was_running) 90 else 600;
    while (true) {
        if (buildkitUp(ctx, addr)) break;
        if (util.secondsSince(ctx, t0) >= limit) return false;
        util.sleep(ctx, 10_000);
    }
    util.errPrint("yolo: BuildKit is up after {d}s\n", .{util.secondsSince(ctx, t0)});
    return true;
}

fn buildkitUp(ctx: Ctx, addr: []const u8) bool {
    return (util.quietUntil(ctx, &.{ "buildctl", "--addr", addr, "debug", "workers" }, 30) orelse 1) == 0;
}

fn launchBox(ctx: Ctx, root: []const u8, b: Box, mrev: ?[]const u8) u8 {
    main.needCheckout(root, "yolo infra launch");
    const rev = mrev orelse git(ctx, root, &.{ "rev-parse", "HEAD" });
    const pushed = git(ctx, root, &.{ "branch", "-r", "--contains", rev });
    if (pushed.len == 0)
        util.dief("rev {s} is not on any pushed branch; the box fetches its config from GitHub", .{rev});
    if (findInstance(ctx, b)) |found| util.dief("already exists: {s}", .{found.id});
    const sg = ensureSecurityGroup(ctx, b);
    ensureInstanceProfile(ctx, b);
    var v6: []const []const u8 = &.{};
    if (b.ipv6) {
        ensureIpv6(ctx, b);
        v6 = &.{ "--ipv6-address-count", "1" };
    }
    const ami_out = aws(ctx, b, &.{
        "ec2",
        "describe-images",
        "--owners",
        "427812963091", // official NixOS AMIs
        "--filters",
        "Name=architecture,Values=x86_64",
        "Name=name,Values=nixos/*",
        "--query",
        "sort_by(Images,&CreationDate)[-1].[ImageId,Name,RootDeviceName]",
        "--output",
        "text",
    });
    var words = mem.tokenizeAny(u8, ami_out, " \t\n\r");
    const ami = words.next() orelse util.dief("unexpected AMI lookup result: {s}", .{ami_out});
    const ami_name = words.next() orelse util.dief("unexpected AMI lookup result: {s}", .{ami_out});
    const root_dev = words.next() orelse util.dief("unexpected AMI lookup result: {s}", .{ami_out});
    util.sayf("ami={s} ({s}) rev={s} sg={s}", .{ ami, ami_name, rev, sg });

    const user_data = userData(ctx.arena, b, rev) catch util.die("out of memory");
    const tmp = ctx.envNonEmpty("TMPDIR") orelse "/tmp";
    const ud_path = util.join(ctx, &.{ tmp, std.fmt.allocPrint(ctx.arena, "yolo-user-data-{d}", .{std.os.linux.getpid()}) catch "yolo-user-data" });
    util.writeFileOrDie(ctx, ud_path, user_data);
    defer util.removeTree(ctx, ud_path);

    const instance = aws(ctx, b, &.{
        "ec2",
        "run-instances",
        "--image-id",
        ami,
        "--instance-type",
        b.instance_type,
        "--security-group-ids",
        sg,
        "--iam-instance-profile",
        std.fmt.allocPrint(ctx.arena, "Name={s}", .{b.name}) catch "",
        "--block-device-mappings",
        std.fmt.allocPrint(ctx.arena, "DeviceName={s},Ebs={{VolumeSize={s},VolumeType=gp3,DeleteOnTermination=true}}", .{ root_dev, b.disk_gb }) catch "",
        "--metadata-options",
        "HttpTokens=required",
        "--user-data",
        std.fmt.allocPrint(ctx.arena, "file://{s}", .{ud_path}) catch "",
        "--tag-specifications",
        std.fmt.allocPrint(ctx.arena, "ResourceType=instance,Tags=[{{Key=Name,Value={s}}},{{Key=rev,Value={s}}}]", .{ b.name, rev }) catch "",
        "--query",
        "Instances[0].InstanceId",
        "--output",
        "text",
    });
    util.say(instance);
    // The new instance makes its own iroh key, so its ticket is new.
    if (mem.eql(u8, b.name, "datum-buildbox")) {
        util.removeTree(ctx, ticketFile(ctx));
        util.errPrint("yolo: dropped the saved build box ticket; yolo build reads the new one once the box has configured itself (~5 min)\n", .{});
    } else {
        util.errPrint("yolo: the new {s} has a new ticket (yolo infra meta ticket, after ~5 min); update META_TICKET in the agent-home Secret before starting sessions\n", .{b.name});
    }
    return 0;
}

fn git(ctx: Ctx, root: []const u8, a: []const []const u8) []const u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    argv.appendSlice(ctx.arena, &.{ "git", "-C", root }) catch return "";
    argv.appendSlice(ctx.arena, a) catch return "";
    const r = util.capture(ctx, argv.items, .{}) catch return "";
    return util.trim(r.stdout);
}

/// No ingress rules: everything reaches the box over iroh or SSM
/// (`ensureSecurityGroup`).
fn ensureSecurityGroup(ctx: Ctx, b: Box) []const u8 {
    const sg = aws(ctx, b, &.{
        "ec2",
        "describe-security-groups",
        "--filters",
        std.fmt.allocPrint(ctx.arena, "Name=group-name,Values={s}", .{b.name}) catch "",
        "--query",
        "SecurityGroups[0].GroupId",
        "--output",
        "text",
    });
    if (!mem.eql(u8, sg, "None")) return sg;
    const vpc = defaultVpc(ctx, b);
    return aws(ctx, b, &.{
        "ec2",
        "create-security-group",
        "--group-name",
        b.name,
        "--vpc-id",
        vpc,
        "--description",
        std.fmt.allocPrint(ctx.arena, "{s}, no inbound", .{b.name}) catch "",
        "--query",
        "GroupId",
        "--output",
        "text",
    });
}

/// An instance profile that SSM can manage (for the ticket; no SSH needed).
fn ensureInstanceProfile(ctx: Ctx, b: Box) void {
    const probe = awsArgs(ctx.arena, b, &.{ "iam", "get-instance-profile", "--instance-profile-name", b.name }) catch return;
    if (util.quiet(ctx, probe) == 0) return;
    _ = aws(ctx, b, &.{
        "iam",                                                                                                                                                 "create-role", "--role-name", b.name, "--assume-role-policy-document",
        "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Principal\":{\"Service\":\"ec2.amazonaws.com\"},\"Action\":\"sts:AssumeRole\"}]}",
    });
    _ = aws(ctx, b, &.{ "iam", "attach-role-policy", "--role-name", b.name, "--policy-arn", "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore" });
    _ = aws(ctx, b, &.{ "iam", "create-instance-profile", "--instance-profile-name", b.name });
    _ = aws(ctx, b, &.{ "iam", "add-role-to-instance-profile", "--instance-profile-name", b.name, "--role-name", b.name });
    util.sleep(ctx, 10_000); // instance profiles take a moment to become usable
}

fn defaultVpc(ctx: Ctx, b: Box) []const u8 {
    return aws(ctx, b, &.{
        "ec2",     "describe-vpcs", "--filters", "Name=is-default,Values=true",
        "--query", "Vpcs[0].VpcId", "--output",  "text",
    });
}

/// Public IPv6 for the default VPC, once: an Amazon-provided block, a /64 per
/// default subnet (so any AZ works), and a ::/0 route to the internet gateway.
/// Sandboxes on Datum are IPv6-only, so this is what lets iroh go direct
/// instead of through the relay. Idempotent (`ensureIpv6`).
fn ensureIpv6(ctx: Ctx, b: Box) void {
    const vpc = defaultVpc(ctx, b);
    const vpc_block = struct {
        fn query(ctx_: Ctx, b_: Box, vpc_: []const u8) []const u8 {
            return aws(ctx_, b_, &.{
                "ec2",     "describe-vpcs",                                                                                  "--vpc-ids", vpc_,
                "--query", "Vpcs[0].Ipv6CidrBlockAssociationSet[?Ipv6CidrBlockState.State==`associated`]|[0].Ipv6CidrBlock", "--output",  "text",
            });
        }
    };
    var block = vpc_block.query(ctx, b, vpc);
    if (mem.eql(u8, block, "None")) {
        _ = aws(ctx, b, &.{ "ec2", "associate-vpc-cidr-block", "--vpc-id", vpc, "--amazon-provided-ipv6-cidr-block" });
        var n: u8 = 0;
        while (n < 30) : (n += 1) {
            block = vpc_block.query(ctx, b, vpc);
            if (!mem.eql(u8, block, "None")) break;
            util.sleep(ctx, 2000);
        }
    }
    util.errPrint("vpc {s} ipv6 {s}\n", .{ vpc, block });

    const subnet_out = aws(ctx, b, &.{
        "ec2",
        "describe-subnets",
        "--filters",
        std.fmt.allocPrint(ctx.arena, "Name=vpc-id,Values={s}", .{vpc}) catch "",
        "Name=default-for-az,Values=true",
        "--query",
        "sort_by(Subnets,&AvailabilityZone)[].SubnetId",
        "--output",
        "text",
    });
    var subnets = mem.tokenizeAny(u8, subnet_out, " \t\n\r");
    var i: u32 = 0;
    while (subnets.next()) |subnet| : (i += 1) {
        const n = aws(ctx, b, &.{
            "ec2",     "describe-subnets",                                                                        "--subnet-ids", subnet,
            "--query", "length(Subnets[0].Ipv6CidrBlockAssociationSet[?Ipv6CidrBlockState.State==`associated`])", "--output",     "text",
        });
        if (mem.eql(u8, n, "0")) {
            const cidr = subnet64(ctx.arena, block, i) catch
                util.dief("can't split {s} into /64s", .{block});
            _ = aws(ctx, b, &.{ "ec2", "associate-subnet-cidr-block", "--subnet-id", subnet, "--ipv6-cidr-block", cidr });
        }
        _ = aws(ctx, b, &.{ "ec2", "modify-subnet-attribute", "--subnet-id", subnet, "--assign-ipv6-address-on-creation" });
    }
    const rtb = aws(ctx, b, &.{
        "ec2",                                                                    "describe-route-tables",             "--filters",
        std.fmt.allocPrint(ctx.arena, "Name=vpc-id,Values={s}", .{vpc}) catch "", "Name=association.main,Values=true", "--query",
        "RouteTables[0].RouteTableId",                                            "--output",                          "text",
    });
    const igw = aws(ctx, b, &.{
        "ec2",                                                                               "describe-internet-gateways", "--filters",
        std.fmt.allocPrint(ctx.arena, "Name=attachment.vpc-id,Values={s}", .{vpc}) catch "", "--query",                    "InternetGateways[0].InternetGatewayId",
        "--output",                                                                          "text",
    });
    // Fails harmlessly if the route exists.
    const route = awsArgs(ctx.arena, b, &.{
        "ec2",                           "create-route", "--route-table-id", rtb,
        "--destination-ipv6-cidr-block", "::/0",         "--gateway-id",     igw,
    }) catch return;
    _ = util.quiet(ctx, route);
}

test "user-data pins the config to the rev" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const ud = try userData(a, boxDefaults("meta"), "abc1234");
    try std.testing.expect(std.mem.indexOf(u8, ud, "github:drewr/yolo/abc1234?dir=infra/meta/ec2#agentmeta") != null);
}

test "sso expiry is recognised" {
    try std.testing.expectEqual(SsoExpired.yes, SsoExpired.detect("Error: Token has expired and refresh failed"));
    try std.testing.expectEqual(SsoExpired.no, SsoExpired.detect("An error occurred (InvalidParameter)"));
}
