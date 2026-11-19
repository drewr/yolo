//! Jump boxes on Datum: what `yolo new NAME --agent jump` provisions beside the
//! session's Workload, and what `yolo rm NAME` takes down again. For the box
//! NAME in project P, in organization O:
//!
//!   jump-NAME            ServiceAccount (iam.miloapis.com), in P
//!   jump-NAME-P          PolicyBinding (iam.miloapis.com), in O's namespace:
//!                        the box's account gets the editor role on project P
//!   (generated)          ServiceAccountKey (identity.miloapis.com). Datum
//!                        generates its name; its status.privateKey is the
//!                        credentials JSON, returned once, and goes straight
//!                        into the Secret below
//!   yolo-NAME-config     Secret (key datum-credentials.json) and ConfigMap:
//!                        the box's Config, at datum://P/yolo-NAME-config
//!
//! The session's own Secret (yolo-NAME) and Workload belong to datum.zig. Datum
//! calls go through datumctl, from PATH, as the user logged in; the Config
//! Secret is written through datumapi.zig. Credentials stay in memory: nothing
//! here prints them, logs them or writes them to disk. Errors name the step and
//! the server's message only.
//!
//! Pure functions first, then the IO boundary.

const std = @import("std");
const util = @import("util.zig");
const json = @import("json.zig");
const config = @import("config.zig");
const datum = @import("datum.zig");
const datumapi = @import("datumapi.zig");
const Ctx = util.Ctx;
const mem = std.mem;

/// The harness that makes a session a jump box.
pub const harness = "jump";
/// The key in the box's Config Secret that holds the credentials JSON.
pub const credentials_key = "datum-credentials.json";

const role_name = "editor";
const role_namespace = "datum-cloud";
const project_group = "resourcemanager.miloapis.com";
/// How long to wait for Datum to give a new ServiceAccount its email.
const account_wait_tries = 30;
const account_wait_ms = 2000;

// ---------------------------------------------------------------------------
// Pure
// ---------------------------------------------------------------------------

pub fn serviceAccountName(allocator: mem.Allocator, name: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "jump-{s}", .{name});
}

/// The name of the box's Config: its Secret and its ConfigMap.
pub fn configName(allocator: mem.Allocator, name: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "yolo-{s}-config", .{name});
}

/// The PolicyBinding's name. Bindings share the organization's namespace, so
/// the project is part of the name.
pub fn bindingName(allocator: mem.Allocator, name: []const u8, project: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "jump-{s}-{s}", .{ name, project });
}

/// YOLO_CONFIG_URL for the box: datum://PROJECT/yolo-NAME-config.
pub fn configUrl(allocator: mem.Allocator, project: []const u8, name: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "datum://{s}/yolo-{s}-config", .{ project, name });
}

/// The namespace that holds a project's PolicyBindings in the organization.
pub fn organizationNamespace(allocator: mem.Allocator, org: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "organization-{s}", .{org});
}

pub fn serviceAccountManifest(allocator: mem.Allocator, sa: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator,
        \\apiVersion: iam.miloapis.com/v1alpha1
        \\kind: ServiceAccount
        \\metadata:
        \\  name: {s}
        \\  annotations:
        \\    kubernetes.io/description: "yolo jump box"
        \\spec:
        \\  state: Active
        \\
    , .{sa});
}

/// A ServiceAccountKey for the account with this email. Datum generates the
/// key's name and its private key.
pub fn serviceAccountKeyManifest(allocator: mem.Allocator, sa: []const u8, email: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator,
        \\apiVersion: identity.miloapis.com/v1alpha1
        \\kind: ServiceAccountKey
        \\metadata:
        \\  generateName: {s}-
        \\spec:
        \\  serviceAccountUserName: "{s}"
        \\
    , .{ sa, email });
}

/// The PolicyBinding that gives the box's account the editor role on the project.
pub fn policyBindingManifest(
    allocator: mem.Allocator,
    org_namespace: []const u8,
    binding: []const u8,
    project: []const u8,
    project_uid: []const u8,
    email: []const u8,
    sa_uid: []const u8,
) ![]u8 {
    return std.fmt.allocPrint(allocator,
        \\apiVersion: iam.miloapis.com/v1alpha1
        \\kind: PolicyBinding
        \\metadata:
        \\  name: {s}
        \\  namespace: {s}
        \\spec:
        \\  resourceSelector:
        \\    resourceRef:
        \\      apiGroup: {s}
        \\      kind: Project
        \\      name: {s}
        \\      uid: "{s}"
        \\  roleRef:
        \\    name: {s}
        \\    namespace: {s}
        \\  subjects:
        \\    - kind: ServiceAccount
        \\      name: "{s}"
        \\      uid: "{s}"
        \\
    , .{ binding, org_namespace, project_group, project, project_uid, role_name, role_namespace, email, sa_uid });
}

/// The ConfigMap of the box's Config. It starts empty; `yolo cfg put` fills it.
pub fn configMapManifest(allocator: mem.Allocator, config_name: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator,
        \\apiVersion: v1
        \\kind: ConfigMap
        \\metadata:
        \\  name: {s}
        \\
    , .{config_name});
}

/// The Workload env items a jump box adds, at the indentation renderWorkload
/// uses: its Config's URL, its name, the deployment generation, and the
/// credentials JSON from the Config's Secret. YOLO_USER comes from renderWorkload.
pub fn envYaml(allocator: mem.Allocator, config_url: []const u8, name: []const u8, config_name: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator,
        \\                - name: YOLO_CONFIG_URL
        \\                  value: "{s}"
        \\                - name: YOLO_BOX
        \\                  value: "{s}"
        \\                - name: YOLO_GENERATION
        \\                  value: "1"
        \\                - name: YOLO_DATUM_CREDENTIALS_JSON
        \\                  valueFrom:
        \\                    secretKeyRef: {{ name: {s}, key: {s} }}
        \\
    , .{ config_url, name, config_name, credentials_key });
}

/// The organization a project belongs to, from `datumctl whoami`'s Context line
/// (`ORG/PROJECT`), when that line names this project.
pub fn orgIn(whoami: []const u8, project: []const u8) ?[]const u8 {
    var lines = mem.splitScalar(u8, whoami, '\n');
    while (lines.next()) |line| {
        const t = util.trim(line);
        if (!mem.startsWith(u8, t, "Context:")) continue;
        const v = util.trim(t["Context:".len..]);
        const slash = mem.indexOfScalar(u8, v, '/') orelse return null;
        const org = v[0..slash];
        const proj = v[slash + 1 ..];
        if (org.len == 0 or !mem.eql(u8, proj, project)) return null;
        return org;
    }
    return null;
}

/// The `datumctl` argv with `--organization ORG` after the program name, for
/// resources in the organization's control plane.
pub fn withOrg(allocator: mem.Allocator, org: []const u8, argv: []const []const u8) ![]const []const u8 {
    std.debug.assert(argv.len >= 1);
    const out = try allocator.alloc([]const u8, argv.len + 2);
    out[0] = argv[0];
    out[1] = "--organization";
    out[2] = org;
    @memcpy(out[3..], argv[1..]);
    return out;
}

/// The names of the ServiceAccountKeys (a `get serviceaccountkeys -o json` list)
/// that belong to the account with this email.
pub fn keyNamesFor(allocator: mem.Allocator, list_body: []const u8, email: []const u8) ![]const []const u8 {
    const root = json.parse(allocator, list_body) orelse return error.BadJson;
    var names: std.ArrayList([]const u8) = .empty;
    for (json.list(&.{"items"}, root)) |item| {
        if (!mem.eql(u8, json.str(&.{ "spec", "serviceAccountUserName" }, item), email)) continue;
        const n = json.str(&.{ "metadata", "name" }, item);
        if (n.len != 0) try names.append(allocator, n);
    }
    return names.items;
}

/// The credentials JSON from a ServiceAccountKey create response's
/// `status.privateKey`; null when the response has none. The value is never
/// part of an error message.
pub fn credentialsFrom(allocator: mem.Allocator, create_body: []const u8) ?[]const u8 {
    const root = json.parse(allocator, create_body) orelse return null;
    const p = json.str(&.{ "status", "privateKey" }, root);
    if (p.len == 0 or p[0] != '{') return null;
    return p;
}

/// The email (`status.email`) of a ServiceAccount, if Datum has given one.
pub fn emailFrom(allocator: mem.Allocator, account_body: []const u8) ?[]const u8 {
    const root = json.parse(allocator, account_body) orelse return null;
    const e = json.str(&.{ "status", "email" }, root);
    return if (e.len == 0) null else e;
}

/// The UID (`metadata.uid`) of an object.
pub fn uidFrom(allocator: mem.Allocator, body: []const u8) ?[]const u8 {
    const root = json.parse(allocator, body) orelse return null;
    const u = json.str(&.{ "metadata", "uid" }, root);
    return if (u.len == 0) null else u;
}

/// Whether datumctl's error says the object isn't there.
pub fn isNotFound(stderr: []const u8) bool {
    return mem.indexOf(u8, stderr, "NotFound") != null or mem.indexOf(u8, stderr, "not found") != null;
}

// ---------------------------------------------------------------------------
// IO boundary — everything below does IO
// ---------------------------------------------------------------------------

/// The box's objects, by name. `org` is empty when it couldn't be found.
pub const Box = struct {
    name: []const u8,
    project: []const u8,
    org: []const u8,
    sa: []const u8,
    binding: []const u8,
    config: []const u8,
};

/// One datumctl call: its success, its output (may hold a credential, so never
/// printed) and its trimmed stderr, which is safe to show.
const Outcome = struct {
    ok: bool,
    out: []const u8,
    err: []const u8,
};

fn call(ctx: Ctx, argv: []const []const u8, stdin: ?[]const u8) Outcome {
    const r = util.capture(ctx, argv, .{ .stdin = stdin }) catch return .{
        .ok = false,
        .out = "",
        .err = "can't run datumctl (it must be on PATH)",
    };
    return .{ .ok = r.term == .exited and r.code == 0, .out = r.stdout, .err = util.trim(r.stderr) };
}

fn projectArgv(ctx: Ctx, project: []const u8, argv: []const []const u8) []const []const u8 {
    return datum.withProject(ctx.arena, project, argv) catch util.die("out of memory");
}

fn orgArgv(ctx: Ctx, org: []const u8, argv: []const []const u8) []const []const u8 {
    return withOrg(ctx.arena, org, argv) catch util.die("out of memory");
}

fn fmt(ctx: Ctx, comptime f: []const u8, args: anytype) []const u8 {
    return std.fmt.allocPrint(ctx.arena, f, args) catch util.die("out of memory");
}

/// The organization of a project, from the active datumctl context. Null when
/// the active context is another project.
pub fn orgOf(ctx: Ctx, project: []const u8) ?[]const u8 {
    if (util.findExecutable(ctx, "datumctl") == null) return null;
    const r = util.capture(ctx, &.{ "datumctl", "whoami" }, .{}) catch return null;
    if (r.term != .exited or r.code != 0) return null;
    return orgIn(r.stdout, project);
}

/// The names a box of this session name and project gets.
fn namesFor(ctx: Ctx, name: []const u8, project: []const u8) struct { sa: []const u8, binding: []const u8, config: []const u8 } {
    return .{
        .sa = fmt(ctx, "jump-{s}", .{name}),
        .binding = fmt(ctx, "jump-{s}-{s}", .{ name, project }),
        .config = fmt(ctx, "yolo-{s}-config", .{name}),
    };
}

/// The box for a new session. Dies, before anything is created, when the
/// project's name is unusable or its organization can't be found.
pub fn plan(ctx: Ctx, name: []const u8, project: []const u8) Box {
    if (!config.validObjectName(project))
        util.dief("jump: '{s}' isn't a usable Datum project name", .{project});
    const org = orgOf(ctx, project) orelse util.dief(
        "jump: can't tell the organization of project {s}; run yolo from that project's datumctl context (datumctl whoami shows it)",
        .{project},
    );
    const n = namesFor(ctx, name, project);
    return .{ .name = name, .project = project, .org = org, .sa = n.sa, .binding = n.binding, .config = n.config };
}

/// The box a session recorded (its `jump_org`, `jump_sa` and `jump_binding`
/// files), else the names its name gives. Used by rm, which warns rather than
/// dies when the organization can't be found.
pub fn recorded(ctx: Ctx, dir: []const u8, name: []const u8, project: []const u8) Box {
    const n = namesFor(ctx, name, project);
    const org = util.readMeta(ctx, util.join(ctx, &.{ dir, "jump_org" }), "");
    return .{
        .name = name,
        .project = project,
        .org = if (org.len != 0) org else (orgOf(ctx, project) orelse ""),
        .sa = util.readMeta(ctx, util.join(ctx, &.{ dir, "jump_sa" }), n.sa),
        .binding = util.readMeta(ctx, util.join(ctx, &.{ dir, "jump_binding" }), n.binding),
        .config = n.config,
    };
}

/// Record the box's names in the session directory: names only, no secrets.
pub fn recordNames(ctx: Ctx, dir: []const u8, b: Box) void {
    util.writeFileOrDie(ctx, util.join(ctx, &.{ dir, "jump_org" }), fmt(ctx, "{s}\n", .{b.org}));
    util.writeFileOrDie(ctx, util.join(ctx, &.{ dir, "jump_sa" }), fmt(ctx, "{s}\n", .{b.sa}));
    util.writeFileOrDie(ctx, util.join(ctx, &.{ dir, "jump_binding" }), fmt(ctx, "{s}\n", .{b.binding}));
}

/// Null when none of the box's objects exist yet, else why `new` must stop.
/// Creating over an existing object would patch it, and a rollback would take
/// it down, so the check comes first.
pub fn preflight(ctx: Ctx, b: Box) ?[]const u8 {
    const ns = organizationNamespace(ctx.arena, b.org) catch util.die("out of memory");
    if (checkAbsent(ctx, b, "service account", b.sa, projectArgv(ctx, b.project, &.{ "datumctl", "get", "serviceaccount", b.sa, "-o", "json" }))) |m| return m;
    if (checkAbsent(ctx, b, "PolicyBinding", b.binding, orgArgv(ctx, b.org, &.{ "datumctl", "get", "policybinding", b.binding, "-n", ns, "-o", "json" }))) |m| return m;
    if (checkAbsent(ctx, b, "ConfigMap", b.config, projectArgv(ctx, b.project, &.{ "datumctl", "get", "configmap", b.config, "-o", "json" }))) |m| return m;
    if (checkAbsent(ctx, b, "Secret", b.config, projectArgv(ctx, b.project, &.{ "datumctl", "get", "secret", b.config, "-o", "json" }))) |m| return m;
    return null;
}

/// Null when the object named by `argv`'s get is missing; else why `new` stops.
fn checkAbsent(ctx: Ctx, b: Box, what: []const u8, name: []const u8, argv: []const []const u8) ?[]const u8 {
    const o = call(ctx, argv, null);
    if (o.ok) return fmt(ctx, "{s} {s} already exists; yolo rm {s} first", .{ what, name, b.name });
    if (isNotFound(o.err)) return null;
    return fmt(ctx, "can't check for an existing {s}: {s}", .{ what, o.err });
}

/// The ServiceAccount's email and UID, once Datum has given it an email.
fn accountOf(ctx: Ctx, b: Box) ?struct { email: []const u8, uid: []const u8 } {
    var tries: usize = 0;
    while (tries < account_wait_tries) : (tries += 1) {
        const o = call(ctx, projectArgv(ctx, b.project, &.{ "datumctl", "get", "serviceaccount", b.sa, "-o", "json" }), null);
        if (o.ok) {
            const email = emailFrom(ctx.arena, o.out);
            const uid = uidFrom(ctx.arena, o.out);
            if (email != null and uid != null) return .{ .email = email.?, .uid = uid.? };
        }
        util.sleep(ctx, account_wait_ms);
    }
    return null;
}

/// Create the box's objects in order: ServiceAccount, PolicyBinding,
/// ServiceAccountKey (its credentials go into the Config Secret), ConfigMap.
/// Null on success; else the failed step and the server's message. The caller
/// takes down what exists with `teardown`, whatever the failure.
pub fn provision(ctx: Ctx, b: Box) ?[]const u8 {
    const sa_manifest = serviceAccountManifest(ctx.arena, b.sa) catch util.die("out of memory");
    const created = call(ctx, projectArgv(ctx, b.project, &.{ "datumctl", "create", "-f", "-", "-o", "json" }), sa_manifest);
    if (!created.ok) return fmt(ctx, "could not create the service account {s}: {s}", .{ b.sa, created.err });

    const account = accountOf(ctx, b) orelse return fmt(ctx, "service account {s} got no email from Datum", .{b.sa});

    const project_body = call(ctx, orgArgv(ctx, b.org, &.{ "datumctl", "get", "project", b.project, "-o", "json" }), null);
    if (!project_body.ok) return fmt(ctx, "could not read project {s}: {s}", .{ b.project, project_body.err });
    const project_uid = uidFrom(ctx.arena, project_body.out) orelse
        return fmt(ctx, "project {s} has no UID", .{b.project});

    const ns = organizationNamespace(ctx.arena, b.org) catch util.die("out of memory");
    const binding_manifest = policyBindingManifest(ctx.arena, ns, b.binding, b.project, project_uid, account.email, account.uid) catch
        util.die("out of memory");
    const bound = call(ctx, orgArgv(ctx, b.org, &.{ "datumctl", "create", "-f", "-", "-o", "json", "-n", ns }), binding_manifest);
    if (!bound.ok) return fmt(ctx, "could not create the PolicyBinding {s}: {s}", .{ b.binding, bound.err });

    const key_manifest = serviceAccountKeyManifest(ctx.arena, b.sa, account.email) catch util.die("out of memory");
    const key = call(ctx, projectArgv(ctx, b.project, &.{ "datumctl", "create", "-f", "-", "-o", "json", "--validate=false" }), key_manifest);
    if (!key.ok) return fmt(ctx, "could not create a key for service account {s}: {s}", .{ b.sa, key.err });
    const creds = credentialsFrom(ctx.arena, key.out) orelse
        return fmt(ctx, "the key for {s} came back without credentials", .{b.sa});
    // The Secret is created or patched in one call; the response's buffer, which
    // holds the credentials, is wiped once it has been sent.
    const put_err = datumapi.tryPut(ctx, b.project, b.config, .secret, credentials_key, creds);
    std.crypto.secureZero(u8, @constCast(key.out));
    if (put_err) |msg| return fmt(ctx, "could not store the credentials in {s}: {s}", .{ b.config, msg });

    const cm_manifest = configMapManifest(ctx.arena, b.config) catch util.die("out of memory");
    const cm = call(ctx, projectArgv(ctx, b.project, &.{ "datumctl", "apply", "-f", "-" }), cm_manifest);
    if (!cm.ok) return fmt(ctx, "could not create the ConfigMap {s}: {s}", .{ b.config, cm.err });
    return null;
}

/// Delete one object; a missing one is fine. Failures are warnings: teardown
/// keeps going so that as much as possible is taken down.
fn remove(ctx: Ctx, label: []const u8, argv: []const []const u8) void {
    const o = call(ctx, argv, null);
    if (o.ok) {
        util.errPrint("deleted {s}\n", .{label});
    } else if (!isNotFound(o.err)) {
        util.warn("could not delete {s}: {s}", .{ label, o.err });
    }
}

/// Take the box's objects down, in reverse order of creation: the Config, the
/// PolicyBinding, the keys, the ServiceAccount. Missing objects are fine.
pub fn teardown(ctx: Ctx, b: Box) void {
    remove(ctx, fmt(ctx, "ConfigMap {s}", .{b.config}), projectArgv(ctx, b.project, &.{ "datumctl", "delete", "configmap", b.config }));
    remove(ctx, fmt(ctx, "Secret {s}", .{b.config}), projectArgv(ctx, b.project, &.{ "datumctl", "delete", "secret", b.config }));

    if (b.org.len == 0) {
        util.warn("can't tell the organization of {s}, so PolicyBinding {s} is left in place", .{ b.project, b.binding });
    } else {
        const ns = organizationNamespace(ctx.arena, b.org) catch util.die("out of memory");
        remove(ctx, fmt(ctx, "PolicyBinding {s}", .{b.binding}), orgArgv(ctx, b.org, &.{ "datumctl", "delete", "policybinding", b.binding, "-n", ns }));
    }

    // The keys belong to the account's email, which goes once the account does.
    const sa_body = call(ctx, projectArgv(ctx, b.project, &.{ "datumctl", "get", "serviceaccount", b.sa, "-o", "json" }), null);
    if (emailFrom(ctx.arena, sa_body.out)) |email| {
        const list = call(ctx, projectArgv(ctx, b.project, &.{ "datumctl", "get", "serviceaccountkeys", "-o", "json" }), null);
        if (!list.ok) {
            util.warn("can't list the keys of {s}: {s}", .{ b.sa, list.err });
        } else {
            const names = keyNamesFor(ctx.arena, list.out, email) catch util.die("out of memory");
            for (names) |k| {
                remove(ctx, fmt(ctx, "ServiceAccountKey {s}", .{k}), projectArgv(ctx, b.project, &.{ "datumctl", "delete", "serviceaccountkey", k }));
            }
        }
    }
    remove(ctx, fmt(ctx, "ServiceAccount {s}", .{b.sa}), projectArgv(ctx, b.project, &.{ "datumctl", "delete", "serviceaccount", b.sa }));
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn testArena() std.heap.ArenaAllocator {
    return std.heap.ArenaAllocator.init(testing.allocator);
}

test "names: the service account, Config, binding and Config URL" {
    var arena = testArena();
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("jump-box", try serviceAccountName(a, "box"));
    try testing.expectEqualStrings("yolo-box-config", try configName(a, "box"));
    try testing.expectEqualStrings("jump-box-proj-1", try bindingName(a, "box", "proj-1"));
    try testing.expectEqualStrings("datum://proj-1/yolo-box-config", try configUrl(a, "proj-1", "box"));
    try testing.expectEqualStrings("organization-org-1", try organizationNamespace(a, "org-1"));
}

test "service account manifest" {
    var arena = testArena();
    defer arena.deinit();
    const m = try serviceAccountManifest(arena.allocator(), "jump-box");
    try testing.expect(mem.indexOf(u8, m, "apiVersion: iam.miloapis.com/v1alpha1\nkind: ServiceAccount\n") != null);
    try testing.expect(mem.indexOf(u8, m, "  name: jump-box\n") != null);
    try testing.expect(mem.indexOf(u8, m, "spec:\n  state: Active\n") != null);
}

test "key manifest names the account by its email" {
    var arena = testArena();
    defer arena.deinit();
    const m = try serviceAccountKeyManifest(arena.allocator(), "jump-box", "jump-box@proj-1.identity.example");
    try testing.expect(mem.indexOf(u8, m, "apiVersion: identity.miloapis.com/v1alpha1\nkind: ServiceAccountKey\n") != null);
    try testing.expect(mem.indexOf(u8, m, "  generateName: jump-box-\n") != null);
    try testing.expect(mem.indexOf(u8, m, "  serviceAccountUserName: \"jump-box@proj-1.identity.example\"\n") != null);
}

test "policy binding: editor on the project, for the account, in the organization's namespace" {
    var arena = testArena();
    defer arena.deinit();
    const m = try policyBindingManifest(
        arena.allocator(),
        "organization-org-1",
        "jump-box-proj-1",
        "proj-1",
        "uid-p",
        "jump-box@proj-1.identity.example",
        "uid-sa",
    );
    try testing.expect(mem.indexOf(u8, m, "  name: jump-box-proj-1\n  namespace: organization-org-1\n") != null);
    try testing.expect(mem.indexOf(u8, m, "      apiGroup: resourcemanager.miloapis.com\n      kind: Project\n      name: proj-1\n      uid: \"uid-p\"\n") != null);
    try testing.expect(mem.indexOf(u8, m, "  roleRef:\n    name: editor\n    namespace: datum-cloud\n") != null);
    try testing.expect(mem.indexOf(u8, m, "    - kind: ServiceAccount\n      name: \"jump-box@proj-1.identity.example\"\n      uid: \"uid-sa\"\n") != null);
}

test "ConfigMap manifest" {
    var arena = testArena();
    defer arena.deinit();
    const m = try configMapManifest(arena.allocator(), "yolo-box-config");
    try testing.expectEqualStrings("apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: yolo-box-config\n", m);
}

test "env items: the Config URL, the box name, generation 1, and the credentials from the Config Secret" {
    var arena = testArena();
    defer arena.deinit();
    const e = try envYaml(arena.allocator(), "datum://proj-1/yolo-box-config", "box", "yolo-box-config");
    try testing.expect(mem.indexOf(u8, e, "                - name: YOLO_CONFIG_URL\n                  value: \"datum://proj-1/yolo-box-config\"\n") != null);
    try testing.expect(mem.indexOf(u8, e, "                - name: YOLO_BOX\n                  value: \"box\"\n") != null);
    try testing.expect(mem.indexOf(u8, e, "                - name: YOLO_GENERATION\n                  value: \"1\"\n") != null);
    try testing.expect(mem.indexOf(u8, e, "                - name: YOLO_DATUM_CREDENTIALS_JSON\n                  valueFrom:\n                    secretKeyRef: { name: yolo-box-config, key: datum-credentials.json }\n") != null);
}

test "orgIn reads the organization of the Context line, only for its own project" {
    const whoami =
        \\User:         Someone (someone@example.com)
        \\Context:      org-1/proj-1
        \\Organization: Example Org (org-1)
        \\Project:      proj-1
        \\
    ;
    try testing.expectEqualStrings("org-1", orgIn(whoami, "proj-1").?);
    try testing.expect(orgIn(whoami, "proj-2") == null);
    try testing.expect(orgIn("Project: proj-1\n", "proj-1") == null);
    try testing.expect(orgIn("Context: proj-1\n", "proj-1") == null);
}

test "withOrg puts --organization after the program name" {
    var arena = testArena();
    defer arena.deinit();
    const argv = try withOrg(arena.allocator(), "org-1", &.{ "datumctl", "get", "project", "p", "-o", "json" });
    try testing.expectEqual(@as(usize, 8), argv.len);
    try testing.expectEqualStrings("datumctl", argv[0]);
    try testing.expectEqualStrings("--organization", argv[1]);
    try testing.expectEqualStrings("org-1", argv[2]);
    try testing.expectEqualStrings("get", argv[3]);
    try testing.expectEqualStrings("json", argv[7]);
}

test "keyNamesFor picks the keys of one account" {
    var arena = testArena();
    defer arena.deinit();
    const list =
        \\{"items":[
        \\ {"metadata":{"name":"111"},"spec":{"serviceAccountUserName":"jump-box@proj-1.identity.example"}},
        \\ {"metadata":{"name":"222"},"spec":{"serviceAccountUserName":"other@proj-1.identity.example"}},
        \\ {"metadata":{"name":"333"},"spec":{"serviceAccountUserName":"jump-box@proj-1.identity.example"}}
        \\]}
    ;
    const names = try keyNamesFor(arena.allocator(), list, "jump-box@proj-1.identity.example");
    try testing.expectEqual(@as(usize, 2), names.len);
    try testing.expectEqualStrings("111", names[0]);
    try testing.expectEqualStrings("333", names[1]);
    try testing.expectEqual(@as(usize, 0), (try keyNamesFor(arena.allocator(), "{}", "x")).len);
}

test "credentialsFrom takes status.privateKey only when it is a JSON object" {
    var arena = testArena();
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings(
        "{\"keyId\":\"k\"}",
        credentialsFrom(a, "{\"status\":{\"privateKey\":\"{\\\"keyId\\\":\\\"k\\\"}\"}}").?,
    );
    try testing.expect(credentialsFrom(a, "{\"status\":{\"privateKey\":\"-----BEGIN\"}}") == null);
    try testing.expect(credentialsFrom(a, "{\"status\":{}}") == null);
    try testing.expect(credentialsFrom(a, "<html>") == null);
}

test "emailFrom and uidFrom read status.email and metadata.uid" {
    var arena = testArena();
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("jump-box@proj-1.identity.example", emailFrom(a, "{\"status\":{\"email\":\"jump-box@proj-1.identity.example\"}}").?);
    try testing.expect(emailFrom(a, "{\"status\":{}}") == null);
    try testing.expectEqualStrings("uid-1", uidFrom(a, "{\"metadata\":{\"uid\":\"uid-1\"}}").?);
    try testing.expect(uidFrom(a, "{}") == null);
}

test "isNotFound recognises datumctl's missing-object errors" {
    try testing.expect(isNotFound("Error from server (NotFound): secrets \"x\" not found"));
    try testing.expect(!isNotFound("Error from server (Forbidden): nope"));
}
