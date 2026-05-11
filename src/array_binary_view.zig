const std = @import("std");
const datatype = @import("datatype.zig");
const offset_data = @import("offsets.zig");
const array_data = @import("array_data.zig");
const common = @import("array_view_common.zig");
const Buffer = @import("buffer.zig").Buffer;
const ArrayData = array_data.ArrayData;

pub const VarBinaryKind = enum {
    binary,
    utf8,
    large_binary,
    large_utf8,
};

fn offsetTypeFor(comptime kind: VarBinaryKind) type {
    return switch (kind) {
        .binary, .utf8 => i32,
        .large_binary, .large_utf8 => i64,
    };
}

fn dataTypeMatches(comptime kind: VarBinaryKind, ty: datatype.DataType) bool {
    return switch (kind) {
        .binary => ty == .binary,
        .utf8 => ty == .utf8,
        .large_binary => ty == .large_binary,
        .large_utf8 => ty == .large_utf8,
    };
}

pub fn VarBinaryView(comptime kind: VarBinaryKind) type {
    const Offset = offsetTypeFor(kind);

    return struct {
        const Self = @This();

        data: *const ArrayData,
        offset: usize,
        len: usize,
        null_count: usize,

        pub fn fromData(data: *const ArrayData) common.ViewError!Self {
            if (!dataTypeMatches(kind, data.type)) return error.TypeMismatch;
            if (data.buffers.len < 3 or data.buffers[2] == null) return error.InvalidBufferLayout;
            if (data.len > 0 and data.buffers[1] == null) return error.InvalidBufferLayout;
            return .{
                .data = data,
                .offset = data.offset,
                .len = data.len,
                .null_count = data.null_count,
            };
        }

        pub fn dataType(self: Self) datatype.DataType {
            return self.data.type;
        }

        pub fn baseData(self: Self) *const ArrayData {
            return self.data;
        }

        pub fn valueBytes(self: Self, i: usize) []const u8 {
            const offsets = self.data.buffers[1].?;
            const values = self.data.buffers[2].?;
            const range = offset_data.rangeAt(Offset, offsets, self.offset + i);
            return values.dataSlice()[range.offset..][0..range.len];
        }

        pub fn value(self: Self, i: usize) []const u8 {
            return self.valueBytes(i);
        }

        pub fn isValid(self: Self, i: usize) bool {
            return common.slotIsValid(self.data, self.offset, i);
        }

        pub fn isNull(self: Self, i: usize) bool {
            return !self.isValid(i);
        }

        pub fn nullCount(self: Self) usize {
            return common.viewNullCount(self.data, self.offset, self.len, self.null_count);
        }

        pub fn slice(self: Self, off: usize, length: usize) Self {
            const clamped = common.clampedLen(self.len, off, length) catch unreachable;
            return .{
                .data = self.data,
                .offset = self.offset + off,
                .len = clamped,
                .null_count = array_data.slicedNullCount(self.null_count, self.len, off, clamped),
            };
        }

        pub fn sliceChecked(self: Self, off: usize, length: usize) common.SliceError!Self {
            const clamped = try common.clampedLen(self.len, off, length);
            return .{
                .data = self.data,
                .offset = self.offset + off,
                .len = clamped,
                .null_count = array_data.slicedNullCount(self.null_count, self.len, off, clamped),
            };
        }

        pub fn sliceOwned(self: Self, off: usize, length: usize) !*ArrayData {
            const clamped = try common.clampedLen(self.len, off, length);
            return self.data.slice(off, clamped);
        }

        pub fn cloneRetained(self: Self) !*ArrayData {
            return self.data.cloneRetained();
        }
    };
}

pub const BinaryArray = VarBinaryView(.binary);
pub const Utf8Array = VarBinaryView(.utf8);
pub const LargeBinaryArray = VarBinaryView(.large_binary);
pub const LargeUtf8Array = VarBinaryView(.large_utf8);

test "BinaryArray reads ranges and slices" {
    const allocator = std.testing.allocator;
    const offsets = try Buffer.allocate(allocator, 4 * @sizeOf(i32));
    errdefer offsets.release();
    try offset_data.write(i32, offsets, 0, 0);
    try offset_data.write(i32, offsets, 1, 2);
    try offset_data.write(i32, offsets, 2, 2);
    try offset_data.write(i32, offsets, 3, 5);
    offsets.freeze();

    const values = try Buffer.allocate(allocator, 5);
    errdefer values.release();
    @memcpy(values.data[0..5], "abcde");
    values.freeze();

    const data = try ArrayData.initOwned(allocator, .binary, 3, 0, 0, &.{ null, offsets, values }, &.{}, null);
    defer data.release();
    const arr = try BinaryArray.fromData(data);

    try std.testing.expectEqualStrings("ab", arr.valueBytes(0));
    try std.testing.expectEqualStrings("", arr.value(1));
    try std.testing.expectEqualStrings("cde", arr.value(2));
    try std.testing.expectEqualStrings("", arr.slice(1, 2).valueBytes(0));
    try std.testing.expectError(error.OffsetOutOfBounds, arr.sliceChecked(4, 1));
}
