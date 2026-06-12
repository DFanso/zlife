//! zlife — a tiny, dependency-free engine for Conway's Game of Life.
//!
//! The board uses a *toroidal* topology: the grid wraps around at every edge,
//! so gliders that fly off the right side reappear on the left. The simulation
//! follows the classic B3/S23 rule:
//!
//!   * a live cell with 2 or 3 live neighbors survives,
//!   * a dead cell with exactly 3 live neighbors is born,
//!   * everything else dies or stays dead.
//!
//! This file is the library root. The companion `main.zig` turns it into an
//! animated terminal CLI.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// A single grid cell. Backed by one bit so a board is just a packed slice.
pub const Cell = enum(u1) {
    dead = 0,
    alive = 1,

    pub fn isAlive(self: Cell) bool {
        return self == .alive;
    }
};

/// A wrapping rectangular grid of cells plus the machinery to evolve it.
pub const Board = struct {
    width: usize,
    height: usize,
    /// Current generation, stored row-major (`cells[y * width + x]`).
    cells: []Cell,
    /// Double-buffer that the next generation is computed into.
    scratch: []Cell,
    allocator: Allocator,
    generation: u64 = 0,

    /// Allocate an all-dead board of `width` x `height` cells.
    pub fn init(allocator: Allocator, width: usize, height: usize) Allocator.Error!Board {
        std.debug.assert(width > 0 and height > 0);
        const len = width * height;

        const cells = try allocator.alloc(Cell, len);
        errdefer allocator.free(cells);
        @memset(cells, .dead);

        const scratch = try allocator.alloc(Cell, len);
        @memset(scratch, .dead);

        return .{
            .width = width,
            .height = height,
            .cells = cells,
            .scratch = scratch,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Board) void {
        self.allocator.free(self.cells);
        self.allocator.free(self.scratch);
        self.* = undefined;
    }

    inline fn index(self: Board, x: usize, y: usize) usize {
        return y * self.width + x;
    }

    pub fn get(self: Board, x: usize, y: usize) Cell {
        return self.cells[self.index(x, y)];
    }

    pub fn set(self: *Board, x: usize, y: usize, cell: Cell) void {
        self.cells[self.index(x, y)] = cell;
    }

    /// Reset every cell to dead and rewind the generation counter.
    pub fn clear(self: *Board) void {
        @memset(self.cells, .dead);
        self.generation = 0;
    }

    /// Number of living cells in the current generation.
    pub fn population(self: Board) usize {
        var count: usize = 0;
        for (self.cells) |c| {
            if (c.isAlive()) count += 1;
        }
        return count;
    }

    /// Count living cells in the 8-neighborhood of `(x, y)`, wrapping at edges.
    pub fn liveNeighbors(self: Board, x: usize, y: usize) u8 {
        var count: u8 = 0;
        var dy: i8 = -1;
        while (dy <= 1) : (dy += 1) {
            var dx: i8 = -1;
            while (dx <= 1) : (dx += 1) {
                if (dx == 0 and dy == 0) continue;
                const nx = wrap(x, dx, self.width);
                const ny = wrap(y, dy, self.height);
                if (self.get(nx, ny).isAlive()) count += 1;
            }
        }
        return count;
    }

    /// Advance the board by one generation and return the new population.
    pub fn step(self: *Board) usize {
        var y: usize = 0;
        while (y < self.height) : (y += 1) {
            var x: usize = 0;
            while (x < self.width) : (x += 1) {
                const alive = self.get(x, y).isAlive();
                const n = self.liveNeighbors(x, y);
                // B3/S23.
                const next: Cell = if (alive)
                    (if (n == 2 or n == 3) .alive else .dead)
                else
                    (if (n == 3) .alive else .dead);
                self.scratch[self.index(x, y)] = next;
            }
        }
        std.mem.swap([]Cell, &self.cells, &self.scratch);
        self.generation += 1;
        return self.population();
    }

    /// Fill the board randomly. `density` is the probability in [0, 1] that any
    /// given cell starts alive.
    pub fn randomize(self: *Board, rand: std.Random, density: f32) void {
        for (self.cells) |*c| {
            c.* = if (rand.float(f32) < density) .alive else .dead;
        }
    }

    /// Stamp a pattern (a slice of `.{x, y}` offsets) onto the board with its
    /// top-left at `(origin_x, origin_y)`. Offsets wrap around the torus.
    pub fn stamp(self: *Board, origin_x: usize, origin_y: usize, points: []const [2]usize) void {
        for (points) |p| {
            const x = (origin_x + p[0]) % self.width;
            const y = (origin_y + p[1]) % self.height;
            self.set(x, y, .alive);
        }
    }

    /// Write the board to `writer`, one row per line, using the `alive`/`dead`
    /// glyphs. Generic over the writer so it works with files, fixed buffers,
    /// or anything else exposing `writeByte`.
    pub fn render(self: Board, writer: anytype, alive: u8, dead: u8) !void {
        var y: usize = 0;
        while (y < self.height) : (y += 1) {
            var x: usize = 0;
            while (x < self.width) : (x += 1) {
                try writer.writeByte(if (self.get(x, y).isAlive()) alive else dead);
            }
            try writer.writeByte('\n');
        }
    }
};

/// Compute `(v + delta) mod n` for a small signed `delta`, never going negative.
fn wrap(v: usize, delta: i8, n: usize) usize {
    if (delta >= 0) {
        return (v + @as(usize, @intCast(delta))) % n;
    }
    const back = @as(usize, @intCast(-delta));
    return (v + n - (back % n)) % n;
}

/// A handful of well-known starting patterns. Each is a slice of `.{x, y}`
/// offsets suitable for `Board.stamp`.
pub const patterns = struct {
    /// Still life: a 2x2 block that never changes.
    pub const block: []const [2]usize = &.{
        .{ 0, 0 }, .{ 1, 0 },
        .{ 0, 1 }, .{ 1, 1 },
    };

    /// Period-2 oscillator: a row of three that flips between horizontal and
    /// vertical.
    pub const blinker: []const [2]usize = &.{
        .{ 0, 1 }, .{ 1, 1 }, .{ 2, 1 },
    };

    /// Period-2 oscillator made of two blocks that "blink" at each other.
    pub const beacon: []const [2]usize = &.{
        .{ 0, 0 }, .{ 1, 0 },
        .{ 0, 1 }, .{ 3, 2 },
        .{ 2, 3 }, .{ 3, 3 },
    };

    /// The classic 5-cell spaceship that travels diagonally forever.
    pub const glider: []const [2]usize = &.{
        .{ 1, 0 },
        .{ 2, 1 },
        .{ 0, 2 },
        .{ 1, 2 },
        .{ 2, 2 },
    };

    /// Period-3 oscillator (built at comptime from its fourfold symmetry).
    pub const pulsar: []const [2]usize = &pulsar_cells;

    /// Gosper glider gun — the first known pattern of unbounded growth, firing a
    /// fresh glider every 30 generations.
    pub const gosper_glider_gun: []const [2]usize = &.{
        // left block
        .{ 0, 4 },  .{ 0, 5 },  .{ 1, 4 },  .{ 1, 5 },
        // left shuttle
        .{ 10, 4 }, .{ 10, 5 }, .{ 10, 6 }, .{ 11, 3 },
        .{ 11, 7 }, .{ 12, 2 }, .{ 12, 8 }, .{ 13, 2 },
        .{ 13, 8 }, .{ 14, 5 }, .{ 15, 3 }, .{ 15, 7 },
        .{ 16, 4 }, .{ 16, 5 }, .{ 16, 6 }, .{ 17, 5 },
        // right ship
        .{ 20, 2 }, .{ 20, 3 }, .{ 20, 4 }, .{ 21, 2 },
        .{ 21, 3 }, .{ 21, 4 }, .{ 22, 1 }, .{ 22, 5 },
        .{ 24, 0 }, .{ 24, 1 }, .{ 24, 5 }, .{ 24, 6 },
        // right block
        .{ 34, 2 }, .{ 34, 3 }, .{ 35, 2 }, .{ 35, 3 },
    };
};

const pulsar_cells = buildPulsar();

fn buildPulsar() [48][2]usize {
    @setEvalBranchQuota(2000);
    var pts: [48][2]usize = undefined;
    var i: usize = 0;

    // Four horizontal triplets per side, at rows 0, 5, 7, 12.
    for ([_]usize{ 0, 5, 7, 12 }) |y| {
        for ([_]usize{ 2, 3, 4, 8, 9, 10 }) |x| {
            pts[i] = .{ x, y };
            i += 1;
        }
    }
    // Four vertical triplets per side, at columns 0, 5, 7, 12.
    for ([_]usize{ 2, 3, 4, 8, 9, 10 }) |y| {
        for ([_]usize{ 0, 5, 7, 12 }) |x| {
            pts[i] = .{ x, y };
            i += 1;
        }
    }

    return pts;
}

/// Look up a built-in pattern by name. Returns `null` for unknown names.
pub fn patternByName(name: []const u8) ?[]const [2]usize {
    const eql = std.mem.eql;
    if (eql(u8, name, "block")) return patterns.block;
    if (eql(u8, name, "blinker")) return patterns.blinker;
    if (eql(u8, name, "beacon")) return patterns.beacon;
    if (eql(u8, name, "glider")) return patterns.glider;
    if (eql(u8, name, "pulsar")) return patterns.pulsar;
    if (eql(u8, name, "gun") or eql(u8, name, "glider-gun")) return patterns.gosper_glider_gun;
    return null;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "fresh board is empty" {
    var b = try Board.init(testing.allocator, 8, 8);
    defer b.deinit();
    try testing.expectEqual(@as(usize, 0), b.population());
    try testing.expectEqual(@as(u64, 0), b.generation);
}

test "block is a still life" {
    var b = try Board.init(testing.allocator, 6, 6);
    defer b.deinit();
    b.stamp(2, 2, patterns.block);
    try testing.expectEqual(@as(usize, 4), b.population());

    _ = b.step();
    try testing.expectEqual(@as(usize, 4), b.population());
    try testing.expect(b.get(2, 2).isAlive());
    try testing.expect(b.get(3, 2).isAlive());
    try testing.expect(b.get(2, 3).isAlive());
    try testing.expect(b.get(3, 3).isAlive());
}

test "blinker oscillates with period 2" {
    var b = try Board.init(testing.allocator, 5, 5);
    defer b.deinit();
    b.stamp(1, 1, patterns.blinker); // horizontal: (1,2) (2,2) (3,2)
    try testing.expect(b.get(1, 2).isAlive() and b.get(2, 2).isAlive() and b.get(3, 2).isAlive());

    _ = b.step(); // becomes vertical: (2,1) (2,2) (2,3)
    try testing.expectEqual(@as(usize, 3), b.population());
    try testing.expect(b.get(2, 1).isAlive() and b.get(2, 2).isAlive() and b.get(2, 3).isAlive());
    try testing.expect(!b.get(1, 2).isAlive() and !b.get(3, 2).isAlive());

    _ = b.step(); // back to horizontal
    try testing.expect(b.get(1, 2).isAlive() and b.get(2, 2).isAlive() and b.get(3, 2).isAlive());
}

test "lone cell dies of underpopulation" {
    var b = try Board.init(testing.allocator, 4, 4);
    defer b.deinit();
    b.set(1, 1, .alive);
    _ = b.step();
    try testing.expectEqual(@as(usize, 0), b.population());
}

test "dead cell with three neighbors is born" {
    var b = try Board.init(testing.allocator, 5, 5);
    defer b.deinit();
    // An L of three around the empty cell (2,2).
    b.set(1, 1, .alive);
    b.set(2, 1, .alive);
    b.set(1, 2, .alive);
    _ = b.step();
    try testing.expect(b.get(2, 2).isAlive());
}

test "glider conserves five cells and advances" {
    var b = try Board.init(testing.allocator, 16, 16);
    defer b.deinit();
    b.stamp(1, 1, patterns.glider);
    try testing.expectEqual(@as(usize, 5), b.population());

    var i: usize = 0;
    while (i < 4) : (i += 1) _ = b.step();

    // After one full period a glider has the same shape, shifted by (1, 1).
    // It was stamped at (1, 1), so its cells move from
    //   (2,1) (3,2) (1,3) (2,3) (3,3)  to  (3,2) (4,3) (2,4) (3,4) (4,4).
    try testing.expectEqual(@as(usize, 5), b.population());
    try testing.expectEqual(@as(u64, 4), b.generation);
    for ([_][2]usize{ .{ 3, 2 }, .{ 4, 3 }, .{ 2, 4 }, .{ 3, 4 }, .{ 4, 4 } }) |c| {
        try testing.expect(b.get(c[0], c[1]).isAlive());
    }
    try testing.expect(!b.get(2, 1).isAlive()); // vacated origin cell
}

test "neighbors wrap around the torus" {
    var b = try Board.init(testing.allocator, 3, 3);
    defer b.deinit();
    // Corner cell's neighbors include the opposite corners.
    b.set(2, 2, .alive);
    b.set(0, 0, .alive);
    try testing.expectEqual(@as(u8, 1), b.liveNeighbors(0, 0));
    try testing.expectEqual(@as(u8, 1), b.liveNeighbors(2, 2));
}

test "pulsar has 48 cells and period 3" {
    try testing.expectEqual(@as(usize, 48), patterns.pulsar.len);

    var b = try Board.init(testing.allocator, 17, 17);
    defer b.deinit();
    b.stamp(2, 2, patterns.pulsar);
    const start = b.population();
    try testing.expectEqual(@as(usize, 48), start);

    var i: usize = 0;
    while (i < 3) : (i += 1) _ = b.step();
    try testing.expectEqual(@as(usize, 48), b.population());
    try testing.expect(b.get(2 + 2, 2 + 0).isAlive()); // a known live cell returns
}

test "render produces the expected glyphs" {
    var b = try Board.init(testing.allocator, 3, 2);
    defer b.deinit();
    b.set(0, 0, .alive);
    b.set(2, 1, .alive);

    var buf: [32]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try b.render(&w, '#', '.');
    try testing.expectEqualStrings("#..\n..#\n", w.buffered());
}

test "patternByName resolves known names" {
    try testing.expect(patternByName("glider") != null);
    try testing.expect(patternByName("gun") != null);
    try testing.expect(patternByName("nope") == null);
}
