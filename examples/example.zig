const std = @import("std");
const bit_reader = @import("bit_reader");
const BitReader = bit_reader.BitReader;

/// A tiny demo "header" format to show the library doing real work:
///   1 bit   flag
///   4 bits  version
///   3 bits  reserved (skipped)
///   1 byte  payload_length
pub fn main() !void {
    const data = [_]u8{ 0b1_0101_010, 0x2A };
    var br = BitReader(.msb_first).init(&data);

    const flag = try br.readBit();
    const version = try br.readBits(u8, 4);
    try br.skipBits(3);
    const payload_length = try br.readBits(u8, 8);

    std.debug.print("flag = {}\n", .{flag});
    std.debug.print("version = {}\n", .{version});
    std.debug.print("payload_length = {}\n", .{payload_length});
    std.debug.print("bits remaining = {}\n", .{br.bitsRemaining()});

    // Exp-Golomb demo — the kind of field you'd see in an H.264 SPS/PPS.
    const eg_data = [_]u8{0b00100_000}; // codeNum 3, packed in the high 5 bits
    var eg = BitReader(.msb_first).init(&eg_data);
    const value = try eg.readExpGolomb();
    std.debug.print("exp-golomb value = {}\n", .{value});
}
