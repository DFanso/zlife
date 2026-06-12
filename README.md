# zlife

> Conway's Game of Life — a tiny, dependency-free engine and an animated terminal CLI, written in [Zig](https://ziglang.org).

```
zlife  gun  gen 0  pop 36  45x12
                          #
                        # #
              ##      ##            ##
             #   #    ##            ##
  ##        #     #   ##
  ##        #   # ##    # #
            #     #       #
             #   #
              ##
```

The board is a **torus**: anything that flies off one edge reappears on the
opposite side, so gliders loop around forever. Evolution follows the classic
**B3/S23** rule (born with 3 neighbors, survives with 2 or 3).

## Features

- 🔬 Clean, well-tested library core (`Board`) with double-buffered stepping
- 🌀 Toroidal (wrap-around) topology
- 🎩 Built-in patterns: `glider`, `blinker`, `beacon`, `block`, `pulsar`, and the
  **Gosper glider gun**
- 🎲 Seedable random soups for reproducible runs
- 🖥️ Smooth ANSI terminal animation (auto-enables VT mode on Windows)
- 📦 Zero dependencies — just the Zig standard library

## Requirements

[Zig 0.15.2](https://ziglang.org/download/) or newer.

## Build & run

```sh
zig build            # build the executable into zig-out/bin/
zig build run        # build and run with defaults (a random soup)
zig build test       # run the unit tests
```

Pass CLI arguments after `--`:

```sh
zig build run -- --pattern gun --width 60 --height 24
```

Or run the built binary directly:

```sh
./zig-out/bin/zlife --pattern pulsar --delay 200
```

## Usage

```
Usage: zlife [options]

Options:
  -p, --pattern NAME   starting pattern (default: random)
                       random, glider, blinker, beacon, block, pulsar, gun
  -w, --width N        board width in cells   (default: 40)
  -H, --height N       board height in cells  (default: 20)
  -g, --gens N         generations to run, 0 = forever (default: 0)
  -d, --delay MS       milliseconds between frames (default: 80)
      --density F      live fraction for random soup, 0..1 (default: 0.28)
      --seed N         seed the random soup for reproducible runs
      --alive C        glyph for living cells (default: 'O')
      --dead C         glyph for dead cells   (default: ' ')
  -h, --help           show this help and exit
```

Press `Ctrl+C` to stop an endless run (`--gens 0`, the default).

### Examples

```sh
zlife                              # random soup on a 40x20 torus
zlife -p gun -w 60 -H 24           # a Gosper glider gun firing forever
zlife -p pulsar --delay 200        # a slow period-3 pulsar
zlife --gens 50 --seed 7           # 50 reproducible generations
zlife -p glider --alive '@'        # a lone glider drawn with '@'
```

## Using zlife as a library

`zlife` exposes its engine as a Zig module, so you can drop it into your own
project. Add it to your `build.zig.zon`:

```sh
zig fetch --save git+https://github.com/DFanso/zlife
```

Wire the module into your executable in `build.zig`:

```zig
const zlife = b.dependency("zlife", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("zlife", zlife.module("zlife"));
```

Then evolve a board:

```zig
const std = @import("std");
const zlife = @import("zlife");

pub fn main() !void {
    var board = try zlife.Board.init(std.heap.page_allocator, 20, 20);
    defer board.deinit();

    board.stamp(1, 1, zlife.patterns.glider);

    var i: usize = 0;
    while (i < 10) : (i += 1) {
        const pop = board.step();
        std.debug.print("gen {d}: {d} alive\n", .{ board.generation, pop });
    }
}
```

## How it works

Each generation is computed into a separate `scratch` buffer and then swapped in,
so every cell sees a consistent snapshot of the previous state. Neighbor counts
wrap with modular arithmetic, giving the grid its torus topology. Cells are
stored as a packed `enum(u1)`, so a board is just two flat slices of bits.

## Project layout

```
build.zig          # build graph: library module + executable + tests
build.zig.zon      # package manifest
src/root.zig       # the engine: Board, patterns, and its unit tests
src/main.zig       # the CLI: argument parsing and terminal animation
```

## License

[MIT](LICENSE)
