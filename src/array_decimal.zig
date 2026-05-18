// Copyright 2026 Filippo Rossi
// SPDX-License-Identifier: Apache-2.0

//! Decimal array typed views.

const std = @import("std");
const datatype = @import("datatype.zig");
const array_data = @import("array_data.zig");
const common = @import("array_base.zig");
const Buffer = @import("buffer.zig").Buffer;
const ArrayData = array_data.ArrayData;

pub const DecimalKind = enum {
    decimal128,
    decimal256,
};

fn byteWidthFor(comptime kind: DecimalKind) usize {
    return switch (kind) {
        .decimal128 => 16,
        .decimal256 => 32,
    };
}

fn dataTypeMatches(comptime kind: DecimalKind, ty: datatype.DataType) bool {
    return switch (kind) {
        .decimal128 => ty.id() == .decimal128,
        .decimal256 => ty.id() == .decimal256,
    };
}

fn decimalMeta(ty: datatype.DataType) datatype.DecimalMeta {
    return switch (ty) {
        .decimal128 => |meta| meta,
        .decimal256 => |meta| meta,
        else => unreachable,
    };
}

pub fn DecimalArray(comptime kind: DecimalKind) type {
    const width = byteWidthFor(kind);
    const Value = switch (kind) {
        .decimal128 => i128,
        .decimal256 => i256,
    };

    return struct {
        const Self = @This();
        pub const ValueType = Value;

        data: *const ArrayData,
        offset: usize,
        len: usize,
        null_count: ?usize,

        pub fn fromData(data: *const ArrayData) common.ViewError!Self {
            if (!dataTypeMatches(kind, data.type)) return error.TypeMismatch;
            if (data.buffers.len < 2 or data.buffers[1] == null) return error.InvalidBufferLayout;
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

        pub fn precision(self: Self) u8 {
            return decimalMeta(self.data.type).precision;
        }

        pub fn scale(self: Self) i32 {
            return decimalMeta(self.data.type).scale;
        }

        pub fn byteWidth(self: Self) usize {
            _ = self;
            return width;
        }

        pub fn valueBytes(self: Self, i: usize) []const u8 {
            const start = (self.offset + i) * width;
            return self.data.buffers[1].?.dataSlice()[start..][0..width];
        }

        pub fn value(self: Self, i: usize) Value {
            const bytes = self.valueBytes(i);
            return switch (kind) {
                .decimal128 => std.mem.readInt(i128, bytes[0..16], .little),
                .decimal256 => std.mem.readInt(i256, bytes[0..32], .little),
            };
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
            return self.sliceChecked(off, length) catch unreachable;
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

        pub fn sliceOwned(self: Self, off: usize, length: usize) array_data.DataSliceError!*ArrayData {
            const clamped = try common.clampedLen(self.len, off, length);
            const data_off = try common.dataRelativeOffset(self.data.offset, self.offset, off);
            return self.data.slice(data_off, clamped);
        }

        pub fn cloneRetained(self: Self) array_data.DataSliceError!*ArrayData {
            return self.sliceOwned(0, self.len);
        }
    };
}

pub const Decimal128Array = DecimalArray(.decimal128);
pub const Decimal256Array = DecimalArray(.decimal256);

test "Decimal128Array reads values and slices" {
    const allocator = std.testing.allocator;
    const values = try Buffer.allocate(allocator, 3 * 16);
    errdefer values.deinit();
    std.mem.writeInt(i128, values.data[0..16], 12345, .little);
    std.mem.writeInt(i128, values.data[16..32], -67890, .little);
    std.mem.writeInt(i128, values.data[32..48], 42, .little);
    values.freeze();

    const ty = datatype.DataType{ .decimal128 = .{ .precision = 12, .scale = 2 } };
    const data = try ArrayData.initOwned(allocator, ty, 3, 0, 0, &.{ null, values }, &.{}, null);
    defer data.deinit();
    try data.validate();

    const arr = try Decimal128Array.fromData(data);
    try std.testing.expectEqual(@as(u8, 12), arr.precision());
    try std.testing.expectEqual(@as(i32, 2), arr.scale());
    try std.testing.expectEqual(@as(i128, 12345), arr.value(0));
    try std.testing.expectEqual(@as(i128, -67890), arr.value(1));
    try std.testing.expectEqual(@as(i128, 42), arr.slice(2, 1).value(0));

    const owned = try arr.slice(1, 2).sliceOwned(0, 1);
    defer owned.deinit();
    const owned_arr = try Decimal128Array.fromData(owned);
    try std.testing.expectEqual(@as(i128, -67890), owned_arr.value(0));

    const clone = try arr.slice(1, 2).cloneRetained();
    defer clone.deinit();
    const clone_arr = try Decimal128Array.fromData(clone);
    try std.testing.expectEqual(@as(i128, 42), clone_arr.value(1));

    try std.testing.expectError(error.OffsetOutOfBounds, arr.sliceChecked(4, 1));
}

test "Decimal256Array reads values and bytes" {
    const allocator = std.testing.allocator;
    const values = try Buffer.allocate(allocator, 2 * 32);
    errdefer values.deinit();
    std.mem.writeInt(i256, values.data[0..32], 12345, .little);
    std.mem.writeInt(i256, values.data[32..64], -67890, .little);
    values.freeze();

    const ty = datatype.DataType{ .decimal256 = .{ .precision = 40, .scale = -2 } };
    const data = try ArrayData.initOwned(allocator, ty, 2, 0, 0, &.{ null, values }, &.{}, null);
    defer data.deinit();
    try data.validate();

    const arr = try Decimal256Array.fromData(data);
    try std.testing.expectEqual(@as(usize, 32), arr.byteWidth());
    try std.testing.expectEqual(@as(u8, 40), arr.precision());
    try std.testing.expectEqual(@as(i32, -2), arr.scale());
    try std.testing.expectEqual(@as(i256, 12345), arr.value(0));
    try std.testing.expectEqual(@as(i256, -67890), arr.value(1));
    try std.testing.expectEqual(@as(u8, 0xc6), arr.valueBytes(1)[0]);
}
