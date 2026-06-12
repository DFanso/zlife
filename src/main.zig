//! zlife CLI — animate Conway's Game of Life in your terminal.
//!
//! Examples:
//!   zlife                         # a random soup on a 40x20 torus
//!   zlife --pattern gun -w 60     # watch a Gosper glider gun fire
//!   zlife -p pulsar --delay 200   # a slow period-3 pulsar
//!   zlife --gens 50 --seed 7      # 50 reproducible random generations

const std = @import("std");
const builtin = @import("builtin");
const zlife = @import("zlife");

const Options = struct {
    width: usize = 40,
    height: usize = 20,
    /// Number of generations to run; 0 means "forever" (until Ctrl+C).
    gens: u64 = 0,
    delay_ms: u64 = 80,
    pattern: []const u8 = "random",
    density: f32 = 0.28,
    seed: ?u64 = null,
    alive: u8 = 'O',
    dead: u8 = ' ',
};

const usage =
    \\zlife — Conway's Game of Life in your terminal.
    \\
    \\Usage: zlife [options]
    \\
    \\Options:
    \\  -p, --pattern NAME   starting pattern (default: random)
    \\                       random, glider, blinker, beacon, block, pulsar, gun
    \\  -w, --width N        board width in cells   (default: 40)
    \\  -H, --height N       board height in cells  (default: 20)
    \\  -g, --gens N         generations to run, 0 = forever (default: 0)
    \\  -d, --delay MS       milliseconds between frames (default: 80)
    \\      --density F      live fraction for random soup, 0..1 (default: 0.28)
    \\      --seed N         seed the random soup for reproducible runs
    \\      --alive C        glyph for living cells (default: 'O')
    \\      --dead C         glyph for dead cells   (default: ' ')
    \\  -h, --help           show this help and exit
    \\
;

const CliError = error{ MissingValue, BadValue, UnknownFlag };

pub fn main() !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const args = try std.process.argsAlloc(arena);

    const opts = parseArgs(args) catch |err| {
        switch (err) {
            error.Help => {
                try printStderr(usage, .{});
                return;
            },
            error.MissingValue, error.BadValue, error.UnknownFlag => {
                try printStderr("zlife: invalid arguments. Try `zlife --help`.\n", .{});
                std.process.exit(2);
            },
            else => return err,
        }
    };

    try run(arena, opts);
}

const ParseError = CliError || error{Help};

fn parseArgs(args: []const [:0]u8) ParseError!Options {
    var opts = Options{};
    var i: usize = 1; // skip the executable name
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (match(arg, "-h", "--help")) {
            return error.Help;
        } else if (match(arg, "-p", "--pattern")) {
            opts.pattern = try nextValue(args, &i);
        } else if (match(arg, "-w", "--width")) {
            opts.width = try parseUsize(try nextValue(args, &i));
        } else if (match(arg, "-H", "--height")) {
            opts.height = try parseUsize(try nextValue(args, &i));
        } else if (match(arg, "-g", "--gens")) {
            opts.gens = try parseU64(try nextValue(args, &i));
        } else if (match(arg, "-d", "--delay")) {
            opts.delay_ms = try parseU64(try nextValue(args, &i));
        } else if (match(arg, null, "--density")) {
            opts.density = try parseDensity(try nextValue(args, &i));
        } else if (match(arg, null, "--seed")) {
            opts.seed = try parseU64(try nextValue(args, &i));
        } else if (match(arg, null, "--alive")) {
            opts.alive = try parseGlyph(try nextValue(args, &i));
        } else if (match(arg, null, "--dead")) {
            opts.dead = try parseGlyph(try nextValue(args, &i));
        } else {
            return error.UnknownFlag;
        }
    }
    if (opts.width == 0 or opts.height == 0) return error.BadValue;
    return opts;
}

fn match(arg: []const u8, short: ?[]const u8, long: []const u8) bool {
    if (short) |s| {
        if (std.mem.eql(u8, arg, s)) return true;
    }
    return std.mem.eql(u8, arg, long);
}

fn nextValue(args: []const [:0]u8, i: *usize) CliError![]const u8 {
    if (i.* + 1 >= args.len) return error.MissingValue;
    i.* += 1;
    return args[i.*];
}

fn parseUsize(s: []const u8) CliError!usize {
    return std.fmt.parseInt(usize, s, 10) catch error.BadValue;
}

fn parseU64(s: []const u8) CliError!u64 {
    return std.fmt.parseInt(u64, s, 10) catch error.BadValue;
}

fn parseDensity(s: []const u8) CliError!f32 {
    const v = std.fmt.parseFloat(f32, s) catch return error.BadValue;
    if (v < 0 or v > 1) return error.BadValue;
    return v;
}

fn parseGlyph(s: []const u8) CliError!u8 {
    if (s.len != 1) return error.BadValue;
    return s[0];
}

fn run(allocator: std.mem.Allocator, opts: Options) !void {
    enableAnsi();

    var board = try zlife.Board.init(allocator, opts.width, opts.height);
    defer board.deinit();

    seedBoard(&board, opts);

    // A buffer comfortably larger than one rendered frame.
    const frame_bytes = (opts.width + 16) * (opts.height + 4) + 256;
    const buf = try allocator.alloc(u8, frame_bytes);
    var file_writer = std.fs.File.stdout().writer(buf);
    const out = &file_writer.interface;

    try out.writeAll("\x1b[2J\x1b[?25l"); // clear screen, hide cursor
    defer {
        out.writeAll("\x1b[?25h\n") catch {}; // restore cursor
        out.flush() catch {};
    }

    var gen: u64 = 0;
    while (opts.gens == 0 or gen < opts.gens) : (gen += 1) {
        try out.writeAll("\x1b[H"); // cursor home
        try out.print(
            "zlife  \x1b[1m{s}\x1b[0m  gen {d}  pop {d}  {d}x{d}\x1b[K\n",
            .{ opts.pattern, board.generation, board.population(), board.width, board.height },
        );
        try board.render(out, opts.alive, opts.dead);
        try out.flush();

        std.Thread.sleep(opts.delay_ms * std.time.ns_per_ms);
        _ = board.step();
    }
}

fn seedBoard(board: *zlife.Board, opts: Options) void {
    if (std.mem.eql(u8, opts.pattern, "random")) {
        if (opts.seed) |s| {
            var prng = std.Random.DefaultPrng.init(s);
            board.randomize(prng.random(), opts.density);
        } else {
            board.randomize(std.crypto.random, opts.density);
        }
        return;
    }

    if (zlife.patternByName(opts.pattern)) |points| {
        // Drop the pattern a couple of cells in from the top-left corner.
        board.stamp(2, 2, points);
    } else {
        // Unknown pattern name: fall back to a random soup so we still show
        // something rather than a blank board.
        board.randomize(std.crypto.random, opts.density);
    }
}

/// On Windows, switch the console into virtual-terminal mode so ANSI escape
/// sequences are interpreted. No-op (and harmless) everywhere else.
fn enableAnsi() void {
    if (builtin.os.tag != .windows) return;
    const w = std.os.windows;
    const handle = w.GetStdHandle(w.STD_OUTPUT_HANDLE) catch return;
    var mode: w.DWORD = 0;
    if (w.kernel32.GetConsoleMode(handle, &mode) == 0) return;
    const enable_vt: w.DWORD = 0x0004; // ENABLE_VIRTUAL_TERMINAL_PROCESSING
    _ = w.kernel32.SetConsoleMode(handle, mode | enable_vt);
}

fn printStderr(comptime fmt: []const u8, args: anytype) !void {
    var buf: [1024]u8 = undefined;
    var fw = std.fs.File.stderr().writer(&buf);
    const w = &fw.interface;
    try w.print(fmt, args);
    try w.flush();
}

test "parseArgs reads flags" {
    const a = std.testing.allocator;
    const argv = try makeArgv(a, &.{ "zlife", "--pattern", "gun", "-w", "60", "--seed", "7" });
    defer freeArgv(a, argv);

    const opts = try parseArgs(argv);
    try std.testing.expectEqualStrings("gun", opts.pattern);
    try std.testing.expectEqual(@as(usize, 60), opts.width);
    try std.testing.expectEqual(@as(?u64, 7), opts.seed);
}

test "parseArgs rejects unknown flags" {
    const a = std.testing.allocator;
    const argv = try makeArgv(a, &.{ "zlife", "--bogus" });
    defer freeArgv(a, argv);

    try std.testing.expectError(error.UnknownFlag, parseArgs(argv));
}

/// Test helper: build an owned `argv` of zero-terminated strings.
fn makeArgv(a: std.mem.Allocator, items: []const []const u8) ![]const [:0]u8 {
    const argv = try a.alloc([:0]u8, items.len);
    for (items, 0..) |s, idx| argv[idx] = try a.dupeZ(u8, s);
    return argv;
}

fn freeArgv(a: std.mem.Allocator, argv: []const [:0]u8) void {
    for (argv) |s| a.free(s);
    a.free(argv);
}
