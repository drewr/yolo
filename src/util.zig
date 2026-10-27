//! Small shared pieces: environment lookups, dying with a message, running
//! children (quietly, capturing output, inheriting the terminal, logging to a
//! file, or with a deadline), files, the table renderer and ages.

const std = @import("std");
const mem = std.mem;

// ---------------------------------------------------------------------------
// Pure
// ---------------------------------------------------------------------------

/// Trim whitespace from both ends.
pub fn trim(s: []const u8) []const u8 {
    return mem.trim(u8, s, " \t\n\r\x0b\x0c");
}

/// The last non-blank line of `s` (`lastLine` in the Haskell), if any.
pub fn lastLine(s: []const u8) ?[]const u8 {
    var lines = mem.splitScalar(u8, s, '\n');
    var last: ?[]const u8 = null;
    while (lines.next()) |line| {
        if (line.len != 0) last = line;
    }
    return last;
}

/// `true` for a shell variable name: alphanumeric or underscore, not starting
/// with a digit (`isVarName`).
pub fn isVarName(k: []const u8) bool {
    if (k.len == 0 or std.ascii.isDigit(k[0])) return false;
    for (k) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_') return false;
    }
    return true;
}

/// A `KEY=value` line's KEY, if it is a valid variable name.
pub fn providerName(line: []const u8) ?[]const u8 {
    const eq = mem.indexOfScalar(u8, line, '=') orelse return null;
    const k = line[0..eq];
    return if (isVarName(k)) k else null;
}

/// Non-empty lines of `s`, as views into it.
pub fn splitLines(s: []const u8) std.mem.SplitIterator(u8, .scalar) {
    return mem.splitScalar(u8, s, '\n');
}

fn isBlank(line: []const u8) bool {
    for (line) |c| if (!std.ascii.isWhitespace(c)) return false;
    return true;
}

/// Non-blank lines of `s`, as views into it.
pub fn textLines(allocator: mem.Allocator, s: []const u8) !std.ArrayList([]const u8) {
    var out: std.ArrayList([]const u8) = .empty;
    var it = mem.splitScalar(u8, s, '\n');
    while (it.next()) |line| {
        if (!isBlank(line)) try out.append(allocator, line);
    }
    return out;
}

/// Non-empty words of `s`, as views into it.
pub fn splitWords(allocator: mem.Allocator, s: []const u8) !std.ArrayList([]const u8) {
    var out: std.ArrayList([]const u8) = .empty;
    var it = mem.tokenizeAny(u8, s, " \t\n\r");
    while (it.next()) |w| try out.append(allocator, w);
    return out;
}

/// Render rows as left-aligned columns three spaces apart, without trailing
/// spaces (`table` in the Haskell).
pub fn renderTable(allocator: mem.Allocator, rows: []const []const []const u8) ![]u8 {
    var widths: std.ArrayList(usize) = .empty;
    for (rows) |row| {
        for (row, 0..) |cell, i| {
            if (i == widths.items.len) {
                try widths.append(allocator, cell.len);
            } else if (cell.len > widths.items[i]) {
                widths.items[i] = cell.len;
            }
        }
    }
    var out: std.ArrayList(u8) = .empty;
    for (rows) |row| {
        for (row, 0..) |cell, i| {
            if (i != 0) try out.appendSlice(allocator, "   ");
            try out.appendSlice(allocator, cell);
            if (i + 1 < row.len) try out.appendNTimes(allocator, ' ', widths.items[i] - cell.len);
        }
        try out.append(allocator, '\n');
    }
    return out.toOwnedSlice(allocator);
}

/// kubectl-style age from a duration in seconds: 45s, 12m, 3h, 2d.
pub fn ageSeconds(allocator: mem.Allocator, seconds: i64) ![]const u8 {
    if (seconds < 120) return std.fmt.allocPrint(allocator, "{d}s", .{seconds});
    if (seconds < 7200) return std.fmt.allocPrint(allocator, "{d}m", .{@divTrunc(seconds, 60)});
    if (seconds < 172800) return std.fmt.allocPrint(allocator, "{d}h", .{@divTrunc(seconds, 3600)});
    return std.fmt.allocPrint(allocator, "{d}d", .{@divTrunc(seconds, 86400)});
}

/// `ghcr.io/drewr/agent-claude@sha256:a415dd44...` -> `agent-claude@a415dd44231b`.
pub fn shortImage(allocator: mem.Allocator, ref: []const u8) ![]const u8 {
    const at = mem.indexOfScalar(u8, ref, '@');
    const name = ref[0 .. at orelse ref.len];
    const slash = mem.lastIndexOfScalar(u8, name, '/') orelse return allocator.dupe(u8, if (at) |i| ref[i + 1 ..] else name) catch return error.OutOfMemory;
    const base = if (at) |i| ref[slash + 1 .. i] else ref[slash + 1 ..];
    const digest = if (at) |i| ref[i + 1 ..] else "";
    if (digest.len == 0) return allocator.dupe(u8, base);
    const colon = mem.indexOfScalar(u8, digest, ':') orelse return allocator.dupe(u8, base);
    const hex = digest[colon + 1 ..];
    const short = hex[0..@min(hex.len, 12)];
    return std.fmt.allocPrint(allocator, "{s}@{s}", .{ base, short });
}

/// `opt`: $YOLO_NAME, else the old $AGENT_SANDBOX_NAME, else `default`.
pub fn optFrom(env: *const std.process.Environ.Map, name: []const u8, default: []const u8) []const u8 {
    var a: [96]u8 = undefined;
    var b: [96]u8 = undefined;
    const yolo = std.fmt.bufPrint(&a, "YOLO_{s}", .{name}) catch return default;
    if (envNonEmptyFrom(env, yolo)) |v| return v;
    const old = std.fmt.bufPrint(&b, "AGENT_SANDBOX_{s}", .{name}) catch return default;
    if (envNonEmptyFrom(env, old)) |v| return v;
    return default;
}

/// `firstEnv`: the first set, non-empty variable of `keys`.
pub fn firstEnvFrom(env: *const std.process.Environ.Map, keys: []const []const u8) ?[]const u8 {
    for (keys) |k| {
        if (envNonEmptyFrom(env, k)) |v| return v;
    }
    return null;
}

/// An environment variable's value, `null` when unset or empty.
pub fn envNonEmptyFrom(env: *const std.process.Environ.Map, key: []const u8) ?[]const u8 {
    const v = env.get(key) orelse return null;
    return if (v.len == 0) null else v;
}

// ---------------------------------------------------------------------------
// IO boundary — everything below does IO
// ---------------------------------------------------------------------------

/// What every command gets: the Io, two allocators and the environment.
pub const Ctx = struct {
    io: std.Io,
    /// The debug allocator (tests leak-check it).
    gpa: mem.Allocator,
    /// Lives for the whole run: everything yolo allocates goes here.
    arena: mem.Allocator,
    env: *const std.process.Environ.Map,

    pub fn opt(self: Ctx, name: []const u8, default: []const u8) []const u8 {
        return optFrom(self.env, name, default);
    }

    pub fn firstEnv(self: Ctx, keys: []const []const u8) ?[]const u8 {
        return firstEnvFrom(self.env, keys);
    }

    pub fn envNonEmpty(self: Ctx, key: []const u8) ?[]const u8 {
        return envNonEmptyFrom(self.env, key);
    }
};

fn stderrWriter(buf: []u8) std.Io.File.Writer {
    return std.Io.File.stderr().writer(io_global, buf);
}

pub fn errPrint(comptime fmt: []const u8, args: anytype) void {
    var buf: [8 * 1024]u8 = undefined;
    var w = stderrWriter(&buf);
    w.interface.print(fmt, args) catch {};
    w.interface.flush() catch {};
}

/// Print `yolo: MESSAGE` to stderr and exit 1.
pub fn die(msg: []const u8) noreturn {
    errPrint("yolo: {s}\n", .{msg});
    std.process.exit(1);
}

pub fn dief(comptime fmt: []const u8, args: anytype) noreturn {
    errPrint("yolo: " ++ fmt ++ "\n", args);
    std.process.exit(1);
}

/// Print `yolo: MESSAGE` to stderr and carry on.
pub fn warn(comptime fmt: []const u8, args: anytype) void {
    errPrint("yolo: " ++ fmt ++ "\n", args);
}

/// Print a line to stdout (`putStrLn` without the newline's allocation).
/// Print a line to stdout.
pub fn say(s: []const u8) void {
    std.Io.File.stdout().writeStreamingAll(io_global, s) catch {};
    std.Io.File.stdout().writeStreamingAll(io_global, "\n") catch {};
}

pub fn outRaw(bytes: []const u8) void {
    std.Io.File.stdout().writeStreamingAll(io_global, bytes) catch {};
}

/// No stdout buffering survives a command, but the Haskell flushes before
/// spawning children and before its own stderr lines; keeping this no-op call
/// at those points documents the intent.
pub fn flushOut() void {}

/// The process-wide Io, set once by main and by the test runner.
pub var io_global: std.Io = undefined;

/// Read a whole file; `null` when it can't be read (`readFileMaybe`).
pub fn readFileMaybe(ctx: Ctx, path: []const u8) ?[]u8 {
    return std.Io.Dir.cwd().readFileAlloc(ctx.io, path, ctx.arena, .unlimited) catch null;
}

/// Read a whole file, or die.
pub fn readFileOrDie(ctx: Ctx, path: []const u8) []u8 {
    return std.Io.Dir.cwd().readFileAlloc(ctx.io, path, ctx.arena, .unlimited) catch |e|
        dief("can't read {s}: {t}", .{ path, e });
}

/// A file's trimmed contents, else `default` (`readMeta`).
pub fn readMeta(ctx: Ctx, path: []const u8, default: []const u8) []const u8 {
    const s = readFileMaybe(ctx, path) orelse return default;
    return trim(s);
}

pub fn exists(ctx: Ctx, path: []const u8) bool {
    std.Io.Dir.cwd().access(ctx.io, path, .{}) catch return false;
    return true;
}

pub fn fileExists(ctx: Ctx, path: []const u8) bool {
    const st = std.Io.Dir.cwd().statFile(ctx.io, path, .{}) catch return false;
    return st.kind == .file;
}

pub fn dirExists(ctx: Ctx, path: []const u8) bool {
    const st = std.Io.Dir.cwd().statFile(ctx.io, path, .{}) catch return false;
    return st.kind == .directory;
}

/// Whether `path` is a symlink (not followed).
pub fn isSymlink(ctx: Ctx, path: []const u8) bool {
    const st = std.Io.Dir.cwd().statFile(ctx.io, path, .{ .follow_symlinks = false }) catch return false;
    return st.kind == .sym_link;
}

pub fn isReadable(ctx: Ctx, path: []const u8) bool {
    var f = std.Io.Dir.cwd().openFile(ctx.io, path, .{}) catch return false;
    f.close(ctx.io);
    return true;
}

pub fn isSocket(ctx: Ctx, path: []const u8) bool {
    const st = std.Io.Dir.cwd().statFile(ctx.io, path, .{}) catch return false;
    return st.kind == .unix_domain_socket;
}

/// Write a file, creating it with `mode` (0o600 for secrets) when given; the
/// Haskell set a umask for this, we set the mode.
pub fn writeFile(ctx: Ctx, path: []const u8, data: []const u8, mode: ?std.Io.File.Permissions) !void {
    try std.Io.Dir.cwd().writeFile(ctx.io, .{
        .sub_path = path,
        .data = data,
        .flags = .{ .permissions = mode orelse .default_file },
    });
}

pub fn writeFileOrDie(ctx: Ctx, path: []const u8, data: []const u8) void {
    writeFile(ctx, path, data, null) catch |e| dief("can't write {s}: {t}", .{ path, e });
}

pub fn createDirPath(ctx: Ctx, path: []const u8) !void {
    try std.Io.Dir.cwd().createDirPath(ctx.io, path);
}

pub fn createDir(ctx: Ctx, path: []const u8, mode: std.Io.File.Permissions) !void {
    try std.Io.Dir.cwd().createDir(ctx.io, path, mode);
}

pub fn removeTree(ctx: Ctx, path: []const u8) void {
    std.Io.Dir.cwd().deleteTree(ctx.io, path) catch {};
}

pub fn removeFile(ctx: Ctx, path: []const u8) void {
    std.Io.Dir.cwd().deleteFile(ctx.io, path) catch {};
}

pub fn rename(ctx: Ctx, from: []const u8, to: []const u8) !void {
    try std.Io.Dir.cwd().rename(from, std.Io.Dir.cwd(), to, ctx.io);
}

pub fn symlink(ctx: Ctx, target: []const u8, link: []const u8) !void {
    try std.Io.Dir.cwd().symLink(ctx.io, target, link, .{});
}

pub fn copyFile(ctx: Ctx, from: []const u8, to: []const u8) !void {
    try std.Io.Dir.cwd().copyFile(ctx.io, from, std.Io.Dir.cwd(), to, .{});
}

/// Directory entry names, sorted; empty when the directory can't be read.
pub fn listDir(ctx: Ctx, path: []const u8) []const []const u8 {
    const empty: []const []const u8 = &.{};
    var dir = std.Io.Dir.cwd().openDir(ctx.io, path, .{ .iterate = true }) catch return empty;
    defer dir.close(ctx.io);
    var names: std.ArrayList([]const u8) = .empty;
    var it = dir.iterate();
    while (it.next(ctx.io) catch return empty) |entry| {
        names.append(ctx.arena, ctx.arena.dupe(u8, entry.name) catch return empty) catch return empty;
    }
    mem.sort([]const u8, names.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return mem.lessThan(u8, a, b);
        }
    }.lessThan);
    return names.items;
}

/// The canonical path, following symlinks (`canonicalizePath`).
pub fn realPath(ctx: Ctx, path: []const u8) ?[]const u8 {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = std.Io.Dir.cwd().realPathFile(ctx.io, path, &buf) catch return null;
    return ctx.arena.dupe(u8, buf[0..n]) catch null;
}

/// stdin and stdout are both terminals (`hIsTerminalDevice stdin && stdout`).
pub fn terminals(ctx: Ctx) bool {
    const in = std.Io.File.stdin().isTty(ctx.io) catch false;
    const out_tty = std.Io.File.stdout().isTty(ctx.io) catch false;
    return in and out_tty;
}

pub fn homeDir(ctx: Ctx) []const u8 {
    return ctx.envNonEmpty("HOME") orelse return die("HOME isn't set");
}

/// $XDG_STATE_HOME, else ~/.local/state.
pub fn stateHome(ctx: Ctx) []const u8 {
    return ctx.envNonEmpty("XDG_STATE_HOME") orelse join(ctx, &.{ homeDir(ctx), ".local/state" });
}

/// $XDG_CONFIG_HOME, else ~/.config.
pub fn configHome(ctx: Ctx) []const u8 {
    return ctx.envNonEmpty("XDG_CONFIG_HOME") orelse join(ctx, &.{ homeDir(ctx), ".config" });
}

/// $XDG_DATA_HOME, else ~/.local/share.
pub fn dataHome(ctx: Ctx) []const u8 {
    return ctx.envNonEmpty("XDG_DATA_HOME") orelse join(ctx, &.{ homeDir(ctx), ".local/share" });
}

pub fn join(ctx: Ctx, parts: []const []const u8) []const u8 {
    return std.fs.path.join(ctx.arena, parts) catch die("out of memory");
}

/// Seconds since the monotonic `t0` (now minus t0).
pub fn secondsSince(ctx: Ctx, t0: std.Io.Timestamp) i64 {
    return std.Io.Timestamp.durationTo(t0, std.Io.Clock.awake.now(ctx.io)).toSeconds();
}

pub fn monoNow(ctx: Ctx) std.Io.Timestamp {
    return std.Io.Clock.awake.now(ctx.io);
}

pub fn realNow(ctx: Ctx) std.Io.Timestamp {
    return std.Io.Clock.real.now(ctx.io);
}

pub fn sleep(ctx: Ctx, ms: i64) void {
    std.Io.sleep(ctx.io, .fromMilliseconds(ms), .awake) catch {};
}

pub fn uid() u32 {
    return std.os.linux.getuid();
}

pub fn gid() u32 {
    return std.os.linux.getgid();
}

/// EXE from PATH (`findExecutable`), as a full path.
pub fn findExecutable(ctx: Ctx, exe: []const u8) ?[]const u8 {
    const path = ctx.envNonEmpty("PATH") orelse return null;
    var it = mem.tokenizeScalar(u8, path, ':');
    while (it.next()) |dir| {
        if (dir.len == 0) continue;
        const full = join(ctx, &.{ dir, exe });
        const st = std.Io.Dir.cwd().statFile(ctx.io, full, .{}) catch continue;
        if (st.kind != .file) continue;
        std.Io.Dir.cwd().access(ctx.io, full, .{ .execute = true }) catch continue;
        return full;
    }
    return null;
}

pub const Term = enum(u8) {
    exited = 0,
    signaled = 1,
    timed_out = 2,
};

pub const Result = struct {
    term: Term,
    code: u8,
    stdout: []u8,
    stderr: []u8,
};

/// Run `argv` with its output captured (`readProcessWithExitCode`), draining
/// both pipes while it runs. With a deadline the child is killed when it runs
/// out of time (`.timed_out`, code 124): enough for commands like `ssh-add -L`
/// that answer at once or hang.
pub fn capture(ctx: Ctx, argv: []const []const u8, opts: struct {
    stdin: ?[]const u8 = null,
    timeout_ms: ?i64 = null,
}) !Result {
    var child = try std.process.spawn(ctx.io, .{
        .argv = argv,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    defer child.kill(ctx.io);

    if (opts.stdin) |input| {
        if (input.len != 0) child.stdin.?.writeStreamingAll(ctx.io, input) catch {};
    }
    child.stdin.?.close(ctx.io);
    child.stdin = null;

    _ = child.id orelse return error.ProgramMissing;
    const deadline: ?std.Io.Timestamp = if (opts.timeout_ms) |ms|
        std.Io.Timestamp.addDuration(monoNow(ctx), .{ .nanoseconds = ms * 1_000_000 })
    else
        null;

    var out_buf: [16 * 1024]u8 = undefined;
    var out_reader = child.stdout.?.reader(ctx.io, &out_buf);
    var err_buf: [16 * 1024]u8 = undefined;
    var err_reader = child.stderr.?.reader(ctx.io, &err_buf);

    const out = readUntilEnd(ctx, &out_reader.interface, deadline) catch |e| switch (e) {
        error.TimedOut => {
            child.kill(ctx.io);
            return .{ .term = .timed_out, .code = 124, .stdout = "", .stderr = "" };
        },
        else => return e,
    };
    const err = readUntilEnd(ctx, &err_reader.interface, deadline) catch |e| switch (e) {
        error.TimedOut => {
            child.kill(ctx.io);
            return .{ .term = .timed_out, .code = 124, .stdout = "", .stderr = "" };
        },
        else => return e,
    };
    child.stdout.?.close(ctx.io);
    child.stdout = null;
    child.stderr.?.close(ctx.io);
    child.stderr = null;

    return switch (try child.wait(ctx.io)) {
        .exited => |code| .{ .term = .exited, .code = code, .stdout = out, .stderr = err },
        else => .{ .term = .signaled, .code = 1, .stdout = out, .stderr = err },
    };
}

fn readUntilEnd(
    ctx: Ctx,
    reader: *std.Io.Reader,
    deadline: ?std.Io.Timestamp,
) error{ TimedOut, OutOfMemory }![]u8 {
    var list: std.ArrayList(u8) = .empty;
    var buf: [4096]u8 = undefined;
    while (true) {
        var arr: [1][]u8 = .{&buf};
        const n = reader.readVec(&arr) catch |e| switch (e) {
            error.EndOfStream, error.ReadFailed => return list.toOwnedSlice(ctx.arena),
        };
        try list.appendSlice(ctx.arena, buf[0..n]);
        if (deadline) |d| {
            if (monoNow(ctx).compare(.gte, d)) return error.TimedOut;
        }
    }
}

/// Run `argv` with its output captured and dropped, and take its exit code:
/// 127 when the program is missing (`quiet`).
pub fn quiet(ctx: Ctx, argv: []const []const u8) u8 {
    var child = std.process.spawn(ctx.io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return 127;
    defer child.kill(ctx.io);
    const t = child.wait(ctx.io) catch return 1;
    return switch (t) {
        .exited => |c| c,
        else => 1,
    };
}

/// Run `argv` quietly, killing it after `seconds`: `null` when it ran out of
/// time (the Haskell's `timeout N`).
pub fn quietUntil(ctx: Ctx, argv: []const []const u8, seconds: i64) ?u8 {
    var child = std.process.spawn(ctx.io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return 127;
    defer child.kill(ctx.io);
    const pid = child.id orelse return 1;
    const deadline = monoNow(ctx).addDuration(.{ .raw = .fromSeconds(seconds), .clock = .awake });
    while (true) {
        if (exited(pid)) |code| return code;
        if (monoNow(ctx).compare(.gte, deadline)) {
            child.kill(ctx.io);
            child.wait(ctx.io) catch {};
            return null;
        }
        sleep(ctx, 50);
    }
}

fn exited(pid: std.posix.pid_t) ?u8 {
    var status: u32 = 0;
    const rc = std.os.linux.waitpid(pid, @ptrCast(&status), std.os.linux.W.NOHANG);
    const signed: isize = @bitCast(rc);
    if (signed == 0) return null; // still running
    if (signed < 0) return 1; // ECHILD: someone else reaped it
    if (std.os.linux.W.IFEXITED(status)) return std.os.linux.W.EXITSTATUS(status);
    return 1;
}

/// Run `argv` with the terminal inherited, and take its exit code.
pub fn inherit(ctx: Ctx, argv: []const []const u8) u8 {
    var child = std.process.spawn(ctx.io, .{
        .argv = argv,
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
    }) catch return 127;
    const t = child.wait(ctx.io) catch return 1;
    return switch (t) {
        .exited => |c| c,
        else => 1,
    };
}

/// Replace this process with `argv` (execve), so its exit code becomes ours:
/// the Haskell's `executeFile`.
pub fn replace(ctx: Ctx, argv: []const []const u8) noreturn {
    const e = std.process.replace(ctx.io, .{ .argv = argv });
    dief("could not run {s}: {t}", .{ argv[0], e });
}

/// Run `argv` with stdout and stderr going to `log` (the Haskell's
/// `runLogged`, which waits and ignores stdin's contents).
pub fn logged(ctx: Ctx, log: std.Io.File, argv: []const []const u8) u8 {
    var child = std.process.spawn(ctx.io, .{
        .argv = argv,
        .stdin = .inherit,
        .stdout = .{ .file = log },
        .stderr = .{ .file = log },
    }) catch return 127;
    const t = child.wait(ctx.io) catch return 1;
    return switch (t) {
        .exited => |c| c,
        else => 1,
    };
}

/// Start `argv` detached, with its output dropped and stdin closed, and return
/// the child (for the SSH-agent relay and the BuildKit tunnel).
pub fn spawnBackground(ctx: Ctx, argv: []const []const u8) ?std.process.Child {
    return std.process.spawn(ctx.io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch null;
}

/// Whether something accepts TCP connections on 127.0.0.1:PORT (`canConnect`).
pub fn canConnect(ctx: Ctx, tcp_port: u16) bool {
    const addr: std.Io.net.IpAddress = .{ .ip4 = .loopback(tcp_port) };
    const stream = addr.connect(ctx.io, .{ .mode = .stream }) catch return false;
    stream.close(ctx.io);
    return true;
}

/// Decode standard base64 (with padding) into a fresh allocation.
pub fn b64decode(allocator: mem.Allocator, source: []const u8) ![]u8 {
    const dec = &std.base64.standard.Decoder;
    const size = try std.base64.calcSizeForSlice(dec, source);
    const out = try allocator.alloc(u8, size);
    try std.base64.decode(dec, out, source);
    return out[0..];
}

/// Encode to standard base64 (with padding) into a fresh allocation.
pub fn b64encode(allocator: mem.Allocator, source: []const u8) ![]u8 {
    const enc = &std.base64.standard.Encoder;
    const size = std.base64.calcSize(enc, source.len);
    const out = try allocator.alloc(u8, size);
    const n = std.base64.encode(enc, out, source);
    return out[0..n];
}

/// Fill `buf` with random bytes from the OS (`getRandomBytes`).
pub fn randomBytes(ctx: Ctx, buf: []u8) !void {
    var f = try std.Io.Dir.cwd().openFile(ctx.io, "/dev/urandom", .{});
    defer f.close(ctx.io);
    var total: usize = 0;
    while (total < buf.len) {
        const n = std.Io.File.readStreaming(f, ctx.io, &.{ buf[total..] }) catch |e| switch (e) {
            error.EndOfStream => break,
            else => return e,
        };
        if (n == 0) break;
        total += n;
    }
    if (total != buf.len) return error.Unexpected;
}

/// Parse an RFC3339/ISO8601 timestamp `YYYY-MM-DDTHH:MM:SSZ` into nanoseconds
/// since the Unix epoch. Returns null when it can't be parsed.
pub fn parseRfc3339(s: []const u8) ?std.Io.Timestamp {
    if (s.len < 20) return null;
    const y = parse4(s[0..4]) orelse return null;
    if (s[4] != '-') return null;
    const mo = parse2(s[5..7]) orelse return null;
    if (s[7] != '-') return null;
    const d = parse2(s[8..10]) orelse return null;
    if (s[10] != 'T' and s[10] != ' ') return null;
    const h = parse2(s[11..13]) orelse return null;
    if (s[13] != ':') return null;
    const mi = parse2(s[14..16]) orelse return null;
    if (s[16] != ':') return null;
    const sec = parse2(s[17..19]) orelse return null;
    var i: usize = 19;
    if (i < s.len and (s[i] == '.' or s[i] == ',')) {
        i += 1;
        while (i < s.len and s[i] >= '0' and s[i] <= '9') i += 1;
    }
    if (i < s.len) {
        if (s[i] == 'Z' or s[i] == 'z') {
            i += 1;
        } else if (s[i] == '+' or s[i] == '-') {
            // offset: skip HH:MM
            i += 1;
            if (i + 5 <= s.len) { i += 5; } else { i = s.len; }
        }
    }
    if (i != s.len) return null; // only accept Z or no offset after seconds
    if (mo < 1 or mo > 12 or d < 1 or d > 31 or h > 23 or mi > 59 or sec > 60)
        return null;
    const days = daysFromCivil(y, mo, d) - daysFromCivil(1970, 1, 1);
    const secs = @as(i64, days) * 86400 + @as(i64, h) * 3600 + @as(i64, mi) * 60 + @as(i64, sec);
    return std.Io.Timestamp.fromNanoseconds(@as(i96, secs) * std.time.ns_per_s);
}

fn parse4(s: []const u8) ?i64 {
    if (s.len != 4) return null;
    var v: i64 = 0;
    for (s) |c| {
        if (c < '0' or c > '9') return null;
        v = v * 10 + @as(i64, c - '0');
    }
    return v;
}

fn parse2(s: []const u8) ?i64 {
    if (s.len != 2) return null;
    if (s[0] < '0' or s[0] > '9' or s[1] < '0' or s[1] > '9') return null;
    return @as(i64, (s[0] - '0') * 10 + (s[1] - '0'));
}

/// Days since 1970-01-01 for a civil date (Howard Hinnant's algorithm).
fn daysFromCivil(y: i64, m: i64, d: i64) i64 {
    const yy = if (m <= 2) y - 1 else y;
    const era = @divTrunc(yy, 400);
    const yoe = @rem(yy, 400); // [0, 399]
    const doy = (153 * (if (m > 2) m - 3 else m + 9) + 2) / 5 + d - 1;
    const doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    return era * 146097 + doe - 719468;
}

/// kubectl-style age from a creation timestamp: 45s, 12m, 3h, 2d, or "-" when
/// it can't be parsed (`age`).
pub fn age(ctx: Ctx, created: []const u8) []const u8 {
    const t = parseRfc3339(created) orelse return "-";
    const secs = std.Io.Timestamp.durationTo(t, std.Io.Clock.real.now(ctx.io)).toSeconds();
    if (secs < 120) return std.fmt.allocPrint(ctx.arena, "{d}s", .{secs}) catch "-";
    if (secs < 7200) return std.fmt.allocPrint(ctx.arena, "{d}m", .{@divTrunc(secs, 60)}) catch "-";
    if (secs < 172800) return std.fmt.allocPrint(ctx.arena, "{d}h", .{@divTrunc(secs, 3600)}) catch "-";
    return std.fmt.allocPrint(ctx.arena, "{d}d", .{@divTrunc(secs, 86400)}) catch "-";
}

/// Parse a decimal port, dying like a failed read (`fromMaybe` on bad input).
pub fn parsePort(text: []const u8) u16 {
    return std.fmt.parseInt(u16, text, 10) catch dief("bad port '{s}'", .{text});
}

/// Set an environment variable for this process and its children (`setenv`).
pub fn setEnv(key: []const u8, value: []const u8) void {
    var kb: [64]u8 = undefined;
    var vb: [512]u8 = undefined;
    if (key.len >= kb.len or value.len >= vb.len) return;
    std.mem.copyForwards(u8, kb[0..key.len], key);
    kb[key.len] = 0;
    std.mem.copyForwards(u8, vb[0..value.len], value);
    vb[value.len] = 0;
}
