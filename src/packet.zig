const std = @import("std");

/// Niimbot wire packet: 0x55 0x55, type, length, payload, XOR checksum, 0xAA 0xAA.
/// The layout matches niimprint and niimprint-rs.
pub const Packet = struct {
    packet_type: u8,
    data: []const u8,

    pub const max_data: usize = 255;
    pub const max_wire: usize = max_data + 7;

    pub fn toBytes(self: Packet, out: []u8) error{TooLong, NoSpace}![]u8 {
        if (self.data.len > max_data) return error.TooLong;
        const n = self.data.len + 7;
        if (out.len < n) return error.NoSpace;
        out[0] = 0x55;
        out[1] = 0x55;
        out[2] = self.packet_type;
        out[3] = @intCast(self.data.len);
        @memcpy(out[4..][0..self.data.len], self.data);
        out[4 + self.data.len] = checksum(self.packet_type, self.data);
        out[5 + self.data.len] = 0xAA;
        out[6 + self.data.len] = 0xAA;
        return out[0..n];
    }

    pub fn fromBytes(bytes: []const u8, data_out: []u8) !Packet {
        if (bytes.len < 7) return error.TooShort;
        if (bytes[0] != 0x55 or bytes[1] != 0x55) return error.InvalidHeader;
        if (bytes[bytes.len - 2] != 0xAA or bytes[bytes.len - 1] != 0xAA) return error.InvalidFooter;
        const packet_type = bytes[2];
        const data_len: usize = bytes[3];
        if (bytes.len != data_len + 7) return error.InvalidLength;
        if (data_out.len < data_len) return error.NoSpace;
        const data = bytes[4 .. 4 + data_len];
        const expect = checksum(packet_type, data);
        const actual = bytes[bytes.len - 3];
        if (expect != actual) return error.InvalidChecksum;
        @memcpy(data_out[0..data_len], data);
        return .{ .packet_type = packet_type, .data = data_out[0..data_len] };
    }
};

pub fn checksum(packet_type: u8, data: []const u8) u8 {
    var sum: u8 = packet_type ^ @as(u8, @intCast(data.len));
    for (data) |byte| sum ^= byte;
    return sum;
}

pub const Request = enum(u8) {
    start_print = 0x01,
    start_page = 0x03,
    set_dimension = 0x13,
    set_quantity = 0x15,
    get_rfid = 0x1A,
    allow_print_clear = 0x20,
    set_density = 0x21,
    set_label_type = 0x23,
    get_info = 0x40,
    image = 0x85,
    get_print_status = 0xA3,
    heartbeat = 0xDC,
    end_page = 0xE3,
    end_print = 0xF3,
};

test "packet round trip" {
    var wire: [Packet.max_wire]u8 = undefined;
    const data = [_]u8{ 0x01, 0x02, 0x03 };
    const encoded = try (Packet{ .packet_type = 0x40, .data = &data }).toBytes(&wire);
    var copy: [8]u8 = undefined;
    const decoded = try Packet.fromBytes(encoded, &copy);
    try std.testing.expectEqual(@as(u8, 0x40), decoded.packet_type);
    try std.testing.expectEqualSlices(u8, &data, decoded.data);
}

test "packet rejects a bad checksum" {
    var wire: [Packet.max_wire]u8 = undefined;
    const data = [_]u8{0x01};
    const encoded = try (Packet{ .packet_type = 0x01, .data = &data }).toBytes(&wire);
    encoded[encoded.len - 3] ^= 0xFF;
    var copy: [8]u8 = undefined;
    try std.testing.expectError(error.InvalidChecksum, Packet.fromBytes(encoded, &copy));
}
