// Copyright 2026 Filippo Rossi
// SPDX-License-Identifier: Apache-2.0

//! Arrow C Data Interface key value metadata encoding.

const std = @import("std");
const Allocator = std.mem.Allocator;
const datatype = @import("../datatype.zig");

pub const ImportError = Allocator.Error || error{
    InvalidMetadata,
    ValueOutOfRange,
};

pub const ExportError = Allocator.Error || error{
    ValueOutOfRange,
};

pub fn importOwned(allocator: Allocator, metadata: ?[*]const u8) ImportError![]datatype.MetadataEntry {
    const ptr = metadata orelse return try allocator.alloc(datatype.MetadataEntry, 0);
    var reader = Reader{ .ptr = ptr };
    return parseOwned(allocator, &reader);
}

pub fn exportOwned(allocator: Allocator, metadata: []const datatype.MetadataEntry) ExportError!?[]u8 {
    if (metadata.len == 0) return null;

    var total: usize = @sizeOf(i32);
    _ = try usizeToI32(metadata.len);
    for (metadata) |entry| {
        _ = try usizeToI32(entry.key.len);
        _ = try usizeToI32(entry.value.len);
        total = try addSize(total, @sizeOf(i32));
        total = try addSize(total, entry.key.len);
        total = try addSize(total, @sizeOf(i32));
        total = try addSize(total, entry.value.len);
    }

    const bytes = try allocator.alloc(u8, total);
    errdefer allocator.free(bytes);

    var offset: usize = 0;
    writeInt(bytes, &offset, try usizeToI32(metadata.len));
    for (metadata) |entry| {
        writeInt(bytes, &offset, try usizeToI32(entry.key.len));
        @memcpy(bytes[offset..][0..entry.key.len], entry.key);
        offset += entry.key.len;
        writeInt(bytes, &offset, try usizeToI32(entry.value.len));
        @memcpy(bytes[offset..][0..entry.value.len], entry.value);
        offset += entry.value.len;
    }
    return bytes;
}

const Reader = struct {
    ptr: [*]const u8,
    bytes: ?[]const u8 = null,
    offset: usize = 0,

    fn readInt(self: *Reader) ImportError!i32 {
        const raw = try self.readBytes(@sizeOf(i32));
        return std.mem.readInt(i32, raw[0..@sizeOf(i32)], .native);
    }

    fn readLength(self: *Reader) ImportError!usize {
        const len = try self.readInt();
        if (len < 0) return error.InvalidMetadata;
        return @intCast(len);
    }

    fn readBytes(self: *Reader, len: usize) ImportError![]const u8 {
        if (len > std.math.maxInt(usize) - self.offset) return error.ValueOutOfRange;
        const start = self.offset;
        const end = self.offset + len;
        if (self.bytes) |bytes| {
            if (end > bytes.len) return error.InvalidMetadata;
            self.offset = end;
            return bytes[start..end];
        }
        self.offset = end;
        return self.ptr[start..end];
    }
};

fn parseOwned(allocator: Allocator, reader: *Reader) ImportError![]datatype.MetadataEntry {
    const count = try reader.readInt();
    if (count < 0) return error.InvalidMetadata;

    const entries = try allocator.alloc(datatype.MetadataEntry, @intCast(count));
    errdefer allocator.free(entries);

    var imported: usize = 0;
    errdefer {
        for (entries[0..imported]) |entry| {
            allocator.free(entry.key);
            allocator.free(entry.value);
        }
    }

    for (entries) |*entry| {
        const key_len = try reader.readLength();
        const key_src = try reader.readBytes(key_len);
        const value_len = try reader.readLength();
        const value_src = try reader.readBytes(value_len);

        entry.* = try cloneEntry(allocator, key_src, value_src);
        imported += 1;
    }
    return entries;
}

fn cloneEntry(allocator: Allocator, key_src: []const u8, value_src: []const u8) Allocator.Error!datatype.MetadataEntry {
    const key = try allocator.dupe(u8, key_src);
    errdefer allocator.free(key);

    const value = try allocator.dupe(u8, value_src);
    return .{
        .key = key,
        .value = value,
    };
}

fn usizeToI32(value: usize) ExportError!i32 {
    if (value > @as(usize, @intCast(std.math.maxInt(i32)))) return error.ValueOutOfRange;
    return @intCast(value);
}

fn addSize(a: usize, b: usize) ExportError!usize {
    return std.math.add(usize, a, b) catch error.ValueOutOfRange;
}

fn writeInt(bytes: []u8, offset: *usize, value: i32) void {
    std.mem.writeInt(i32, bytes[offset.*..][0..@sizeOf(i32)], value, .native);
    offset.* += @sizeOf(i32);
}

test "CDI metadata parser rejects truncated bytes" {
    const allocator = std.testing.allocator;

    var truncated_count = [_]u8{ 1, 0, 0 };
    var count_reader = Reader{ .ptr = undefined, .bytes = &truncated_count };
    try std.testing.expectError(error.InvalidMetadata, parseOwned(allocator, &count_reader));

    var truncated_value_len: [13]u8 = undefined;
    std.mem.writeInt(i32, truncated_value_len[0..4], 1, .native);
    std.mem.writeInt(i32, truncated_value_len[4..8], 1, .native);
    truncated_value_len[8] = 'k';
    std.mem.writeInt(i32, truncated_value_len[9..13], 3, .native);
    var value_reader = Reader{ .ptr = undefined, .bytes = &truncated_value_len };
    try std.testing.expectError(error.InvalidMetadata, parseOwned(allocator, &value_reader));
}

test "CDI metadata round trips key values" {
    const allocator = std.testing.allocator;
    const entries = [_]datatype.MetadataEntry{
        .{ .key = "key", .value = "value01" },
    };

    const exported = (try exportOwned(allocator, &entries)).?;
    defer allocator.free(exported);

    var reader = Reader{ .ptr = undefined, .bytes = exported };
    const imported = try parseOwned(allocator, &reader);
    defer datatype.deinitOwnedMetadata(allocator, imported);

    try std.testing.expectEqual(@as(usize, 1), imported.len);
    try std.testing.expectEqualStrings("key", imported[0].key);
    try std.testing.expectEqualStrings("value01", imported[0].value);
}
