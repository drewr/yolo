const util = @import("util.zig");
const Ctx = util.Ctx;

pub fn syncPins(ctx: Ctx, root: []const u8) u8 {
    _ = ctx;
    _ = root;
    util.die("not ported yet");
}

pub fn buildDatum(ctx: Ctx, root: []const u8, cls: []const u8, hs: []const []const u8) u8 {
    _ = ctx;
    _ = root;
    _ = cls;
    _ = hs;
    util.die("build --backend datum not ported yet");
}
