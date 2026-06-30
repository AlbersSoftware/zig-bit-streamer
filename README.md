# zig-bitstream

A small, dependency-free bitstream reader for Zig. Reads arbitrary-width
unsigned bitfields from an in-memory byte slice, in either MSB-first order
(the convention used by most audio/video formats — JPEG, MPEG, H.264/H.265,
AAC) or LSB-first order (used by formats like DEFLATE).

Written and tested against **Zig 0.16.0** (current stable as of this
writing). The library itself only uses core language features — structs,
comptime, slices, error unions — and does no allocation or I/O, so it isn't
exposed to the `std.Io` interface changes that were the headline change in
0.16; it should remain usable with minimal changes across nearby versions.
The one part more likely to need adjusting on a different Zig version is
`build.zig`, since the build-system API (`.root_module = b.createModule(...)`)
has changed shape release to release.

---

## Quick start

```zig
const std = @import("std");
const BitReader = @import("bit_reader.zig").BitReader;

pub fn main() !void {
    const data = [_]u8{ 0xB6, 0x2A };
    var br = BitReader(.msb_first).init(&data);

    const flag = try br.readBit();           // u1
    const value = try br.readBits(u16, 12);  // 12-bit field, MSB-first
    try br.skipBits(3);
    br.alignToByte();

    std.debug.print("flag={} value={}\n", .{ flag, value });
}
```

`DefaultBitReader` is a shorthand for the common MSB-first case:

```zig
const DefaultBitReader = @import("bit_reader.zig").DefaultBitReader;
var br = DefaultBitReader.init(data);
```

---

## Build and test

```bash
zig build test
```

If for any reason `zig build test`'s build-system glue doesn't match your
installed Zig version, the library itself doesn't depend on `build.zig` at
all — you can always fall back to testing the file directly:

```bash
zig test src/bit_reader.zig
```

### Run the example

This is a library, not an application — there's no `main()` of its own, so
running the project means either running its tests (above) or running the
small included demo, which imports the library and prints something:

```bash
zig build run
```

Expected output:

```
flag = 1
version = 5
payload_length = 42
bits remaining = 0
exp-golomb value = 3
```

See `examples/example.zig` for the source — it's a good starting point to
copy from when wiring the library into your own project.

---

## API

| Function | Description |
|---|---|
| `BitReader(comptime order: BitOrder) type` | Returns a reader type for `.msb_first` or `.lsb_first` bit order. |
| `.init(bytes: []const u8) Self` | Creates a reader over a byte slice. |
| `.readBit() Error!u1` | Reads a single bit. |
| `.readBits(comptime T: type, n: u6) Error!T` | Reads `n` bits into an unsigned integer `T` (`n <= @bitSizeOf(T)`). |
| `.peekBits(comptime T: type, n: u6) Error!T` | Like `readBits`, but doesn't advance the position. |
| `.skipBits(n: usize) Error!void` | Advances `n` bits without reading them. |
| `.alignToByte() void` | Advances to the next byte boundary; no-op if already aligned. |
| `.bitsRemaining() usize` | Bits left before the end of the stream. |
| `.bytePosition() usize` | Index of the byte currently being read from. |
| `.isByteAligned() bool` | True if positioned exactly on a byte boundary. |
| `.isAtEnd() bool` | True if no bits remain. |
| `.readExpGolomb() Error!u32` | Reads an unsigned Exp-Golomb code (`ue(v)`), as used in H.264/H.265 SPS/PPS parsing. Assumes `.msb_first`. |
| `.readSignedExpGolomb() Error!i32` | Reads a signed Exp-Golomb code (`se(v)`). |

The only error is `Error.EndOfStream`, returned when a read would run past
the end of the underlying byte slice. Calling `readBits` with `n` greater
than the bit width of the requested type `T` is treated as a programming
error (`std.debug.assert`), not a recoverable one — fix the call site, don't
catch it.

---

## Bit-order semantics, concretely

For the byte `0xB6` (`1011_0110`):

```zig
// MSB-first: first bit read is the byte's high bit.
var msb = BitReader(.msb_first).init(&.{0xB6});
try msb.readBit();        // 1
try msb.readBits(u8, 3);  // 0b011 = 3
try msb.readBits(u8, 4);  // 0b0110 = 6

// LSB-first: first bit read is the byte's low bit; multi-bit fields
// assemble with the first-read bit as the *least*-significant bit of
// the result (matching DEFLATE's convention).
var lsb = BitReader(.lsb_first).init(&.{0xB6});
try lsb.readBit();        // 0
try lsb.readBits(u8, 3);  // 3
try lsb.readBits(u8, 4);  // 11
```

---

## Using as a dependency

`build.zig` exposes a `bit_reader` module via `b.addModule`, so another
project can depend on this one through `build.zig.zon` and
`b.dependency("zig_bitstream", .{}).module("bit_reader")`. That file isn't
included here — exact required fields (`.fingerprint`, `.minimum_zig_version`,
etc.) have shifted across recent Zig releases, and for a library this small,
copying `src/bit_reader.zig` directly into your project is often simpler
than wiring up the package manager. If you do want to publish it, `zig init`
in an empty directory will generate a `build.zig.zon` template matching your
exact installed Zig version to crib from.
