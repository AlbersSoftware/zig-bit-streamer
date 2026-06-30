//! A small, dependency-free bitstream reader.
//!
//! Operates directly on an in-memory `[]const u8` — no allocation, no I/O,
//! nothing version-sensitive beyond core language features. Reads
//! arbitrary-width unsigned bitfields in either MSB-first order (the
//! convention used by most audio/video bitstream formats — JPEG, MPEG,
//! H.264/H.265, AAC, etc.) or LSB-first order (used by formats like
//! DEFLATE).
//!
//! Basic usage:
//!
//!     const BitReader = @import("bit_reader.zig").BitReader;
//!     var br = BitReader(.msb_first).init(data);
//!     const flag = try br.readBit();
//!     const value = try br.readBits(u16, 12);
//!
//! `DefaultBitReader` is provided as a shorthand for the common MSB-first case.

const std = @import("std");

/// Which end of each byte bits are read from first.
pub const BitOrder = enum {
    /// First bit read is the most-significant bit of the current byte.
    /// Used by most audio/video bitstream formats.
    msb_first,
    /// First bit read is the least-significant bit of the current byte.
    /// Used by formats like DEFLATE/zlib.
    lsb_first,
};

pub const Error = error{
    /// Ran out of bytes before satisfying the requested read.
    EndOfStream,
};

/// Returns a bitstream reader type for the given bit order.
pub fn BitReader(comptime order: BitOrder) type {
    return struct {
        bytes: []const u8,
        byte_index: usize = 0,
        /// Bits already consumed from `bytes[byte_index]`, always in 0..7.
        /// Typed u4 (not u3) so the increment-then-check-for-8 logic below
        /// never overflows partway through.
        bit_index: u4 = 0,

        const Self = @This();

        pub fn init(bytes: []const u8) Self {
            return .{ .bytes = bytes };
        }

        /// Reads a single bit, advancing the position by one.
        pub fn readBit(self: *Self) Error!u1 {
            if (self.byte_index >= self.bytes.len) return error.EndOfStream;
            const byte = self.bytes[self.byte_index];
            const idx: u3 = @intCast(self.bit_index); // safe: invariant keeps bit_index in 0..7 here

            const bit: u1 = switch (order) {
                .msb_first => @intCast((byte >> (7 - idx)) & 1),
                .lsb_first => @intCast((byte >> idx) & 1),
            };

            self.bit_index += 1;
            if (self.bit_index == 8) {
                self.bit_index = 0;
                self.byte_index += 1;
            }
            return bit;
        }

        /// Reads `n` bits and assembles them into an unsigned integer of
        /// type `T`. `n` must be <= the bit width of `T` (checked via
        /// `std.debug.assert` — a caller passing too-large `n` for the
        /// chosen `T` is a programming error, not a data error). `n` is
        /// capped at 127 by its type (u7) — comfortably covers any
        /// realistic single field (codec headers rarely exceed 32-64 bits),
        /// but note this means n=64 *is* representable, unlike a u6 cap
        /// would allow (u6 maxes out at 63, which would make a full
        /// 64-bit read impossible to even call).
        ///
        /// In `.msb_first` order the first bit read becomes the
        /// most-significant bit of the result (the field, read in order,
        /// reads the same as written). In `.lsb_first` order the first bit
        /// read becomes the *least*-significant bit of the result, matching
        /// how formats like DEFLATE assemble multi-bit fields.
        pub fn readBits(self: *Self, comptime T: type, n: u7) Error!T {
            comptime {
                const info = @typeInfo(T);
                if (info != .int or info.int.signedness != .unsigned) {
                    @compileError("BitReader.readBits requires an unsigned integer type");
                }
            }
            std.debug.assert(n <= @bitSizeOf(T));

            var result: T = 0;
            var i: u7 = 0;
            while (i < n) : (i += 1) {
                const bit = try self.readBit();
                switch (order) {
                    .msb_first => result = (result << 1) | @as(T, bit),
                    .lsb_first => result |= @as(T, bit) << @as(std.math.Log2Int(T), @intCast(i)),
                }
            }
            return result;
        }

        /// Reads `n` bits like `readBits`, but restores the position
        /// afterward — useful for lookahead (e.g. inspecting a variable-
        /// length code before deciding how many bits it actually consumes).
        pub fn peekBits(self: *Self, comptime T: type, n: u7) Error!T {
            const saved = self.*;
            defer self.* = saved;
            return self.readBits(T, n);
        }

        /// Advances the position by `n` bits without returning them.
        pub fn skipBits(self: *Self, n: usize) Error!void {
            var remaining = n;
            // Fast path: skip whole bytes directly while byte-aligned.
            while (remaining >= 8 and self.bit_index == 0) {
                if (self.byte_index >= self.bytes.len) return error.EndOfStream;
                self.byte_index += 1;
                remaining -= 8;
            }
            while (remaining > 0) : (remaining -= 1) {
                _ = try self.readBit();
            }
        }

        /// Advances to the next byte boundary, discarding any partially
        /// consumed byte. A no-op if already aligned. Common after parsing
        /// a bit-packed header, before reading byte-aligned payload data.
        pub fn alignToByte(self: *Self) void {
            if (self.bit_index != 0) {
                self.bit_index = 0;
                self.byte_index += 1;
            }
        }

        /// Number of bits left to read before hitting the end of the stream.
        pub fn bitsRemaining(self: *const Self) usize {
            if (self.byte_index >= self.bytes.len) return 0;
            return (self.bytes.len - self.byte_index) * 8 - self.bit_index;
        }

        /// Index of the byte currently being read from.
        pub fn bytePosition(self: *const Self) usize {
            return self.byte_index;
        }

        pub fn isByteAligned(self: *const Self) bool {
            return self.bit_index == 0;
        }

        pub fn isAtEnd(self: *const Self) bool {
            return self.bitsRemaining() == 0;
        }

        // ── Video-codec helpers ──────────────────────────────────────────
        //
        // Exponential-Golomb coding, as used by H.264/H.265/HEVC for
        // syntax elements like ue(v)/se(v). These assume `.msb_first`
        // order (the order those specs are defined in) — they'll still
        // run procedurally under `.lsb_first`, just without matching any
        // real codec's bitstream semantics.

        /// Reads an unsigned Exp-Golomb code (ue(v)).
        pub fn readExpGolomb(self: *Self) Error!u32 {
            // u6 (not u5) so incrementing up to the guard value of 32 below
            // can never overflow the counter itself — with u5 (max 31),
            // the increment that's supposed to trigger the malformed-input
            // guard would panic first, defeating the guard entirely.
            var leading_zero_bits: u6 = 0;
            while (true) {
                const bit = try self.readBit();
                if (bit == 1) break;
                leading_zero_bits += 1;
                if (leading_zero_bits >= 32) return error.EndOfStream; // malformed/adversarial input guard
            }
            if (leading_zero_bits == 0) return 0;
            const lzb: u5 = @intCast(leading_zero_bits); // safe: guarded to be < 32 above
            const info = try self.readBits(u32, lzb);
            return (@as(u32, 1) << lzb) - 1 + info;
        }

        /// Reads a signed Exp-Golomb code (se(v)), per the standard
        /// codeNum -> se(v) mapping (even codeNum -> negative, odd -> positive).
        pub fn readSignedExpGolomb(self: *Self) Error!i32 {
            const code = try self.readExpGolomb();
            const k: i64 = code;
            const signed: i64 = if (code % 2 == 0) -@divTrunc(k, 2) else @divTrunc(k + 1, 2);
            return @intCast(signed);
        }
    };
}

/// Shorthand for the common case — MSB-first bit order.
pub const DefaultBitReader = BitReader(.msb_first);

// ── Tests ───────────────────────────────────────────────────────────────

test "msb_first basic reads" {
    const data = [_]u8{0xB6}; // 1011_0110
    var br = BitReader(.msb_first).init(&data);
    try std.testing.expectEqual(@as(u1, 1), try br.readBit());
    try std.testing.expectEqual(@as(u8, 3), try br.readBits(u8, 3)); // 011
    try std.testing.expectEqual(@as(u8, 6), try br.readBits(u8, 4)); // 0110
    try std.testing.expect(br.isAtEnd());
}

test "lsb_first basic reads" {
    const data = [_]u8{0xB6}; // 1011_0110, bit 0 (LSB) read first
    var br = BitReader(.lsb_first).init(&data);
    try std.testing.expectEqual(@as(u1, 0), try br.readBit());
    try std.testing.expectEqual(@as(u8, 3), try br.readBits(u8, 3));
    try std.testing.expectEqual(@as(u8, 11), try br.readBits(u8, 4));
    try std.testing.expect(br.isAtEnd());
}

test "msb_first read spans a byte boundary" {
    const data = [_]u8{ 0xFF, 0x00 };
    var br = BitReader(.msb_first).init(&data);
    const v = try br.readBits(u16, 12);
    try std.testing.expectEqual(@as(u16, 0xFF0), v);
    try std.testing.expectEqual(@as(usize, 1), br.bytePosition());
    try std.testing.expectEqual(@as(usize, 4), br.bitsRemaining());
}

test "peekBits does not advance position" {
    const data = [_]u8{0xAB}; // 1010_1011
    var br = BitReader(.msb_first).init(&data);
    const peeked = try br.peekBits(u8, 4);
    const read = try br.readBits(u8, 4);
    try std.testing.expectEqual(peeked, read);
    try std.testing.expectEqual(@as(usize, 4), br.bitsRemaining());
}

test "skipBits and alignToByte" {
    const data = [_]u8{ 0xAB, 0xCD, 0xEF };
    var br = BitReader(.msb_first).init(&data);

    try br.skipBits(4);
    const v = try br.readBits(u8, 4);
    try std.testing.expectEqual(@as(u8, 0xB), v);
    try std.testing.expect(br.isByteAligned());

    try br.skipBits(12); // rest of byte1 + high nibble of byte2
    try std.testing.expect(!br.isByteAligned());
    br.alignToByte();
    try std.testing.expect(br.isByteAligned());
    try std.testing.expectEqual(@as(usize, 3), br.bytePosition());
    try std.testing.expect(br.isAtEnd());
}

test "EndOfStream when reading past the end" {
    const data = [_]u8{0xFF};
    var br = BitReader(.msb_first).init(&data);
    _ = try br.readBits(u8, 8);
    try std.testing.expectError(error.EndOfStream, br.readBit());
}

test "unsigned Exp-Golomb decoding" {
    // codeNum 3 -> bit pattern "00100", packed into the high 5 bits.
    const data = [_]u8{0b00100_000};
    var br = BitReader(.msb_first).init(&data);
    try std.testing.expectEqual(@as(u32, 3), try br.readExpGolomb());
}

test "signed Exp-Golomb decoding" {
    // codeNum 4 -> bit pattern "00101" -> se(v) = -2.
    const data = [_]u8{0b00101_000};
    var br = BitReader(.msb_first).init(&data);
    try std.testing.expectEqual(@as(i32, -2), try br.readSignedExpGolomb());
}

test "DefaultBitReader is msb_first" {
    const data = [_]u8{0x80}; // 1000_0000
    var br = DefaultBitReader.init(&data);
    try std.testing.expectEqual(@as(u1, 1), try br.readBit());
}
