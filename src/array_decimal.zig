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

        view: common.NullableView,

        pub fn fromData(data: *const ArrayData) common.ViewError!Self {
            if (!dataTypeMatches(kind, data.type)) return error.TypeMismatch;
            if (data.buffers.len < 2 or data.buffers[1] == null) return error.InvalidBufferLayout;
            return .{ .view = common.NullableView.init(data) };
        }

        pub fn precision(self: Self) u8 {
            return decimalMeta(self.view.base.data.type).precision;
        }

        pub fn scale(self: Self) i32 {
            return decimalMeta(self.view.base.data.type).scale;
        }

        pub fn byteWidth(self: Self) usize {
            _ = self;
            return width;
        }

        pub fn valueBytes(self: Self, i: usize) []const u8 {
            const start = (self.view.base.offset + i) * width;
            return self.view.base.data.buffers[1].?.dataSlice()[start..][0..width];
        }

        pub fn value(self: Self, i: usize) Value {
            const bytes = self.valueBytes(i);
            return switch (kind) {
                .decimal128 => std.mem.readInt(i128, bytes[0..16], .little),
                .decimal256 => std.mem.readInt(i256, bytes[0..32], .little),
            };
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
    const sliced = Decimal128Array{ .view = arr.view.slice(2, 1) };
    try std.testing.expectEqual(@as(i128, 42), sliced.value(0));

    const view_slice = arr.view.slice(1, 2);
    const owned = try view_slice.base.sliceOwned(0, 1);
    defer owned.deinit();
    const owned_arr = try Decimal128Array.fromData(owned);
    try std.testing.expectEqual(@as(i128, -67890), owned_arr.value(0));

    const clone = try view_slice.base.cloneRetained();
    defer clone.deinit();
    const clone_arr = try Decimal128Array.fromData(clone);
    try std.testing.expectEqual(@as(i128, 42), clone_arr.value(1));

    try std.testing.expectError(error.OffsetOutOfBounds, arr.view.sliceChecked(4, 1));
}

test "Decimal256Array reads values and bytes" {
    const allocator = std.testing.allocator;
    const values = try Buffer.allocate(allocator, 2 * 32);
    var values_owned = false;
    errdefer if (!values_owned) values.deinit();
    std.mem.writeInt(i256, values.data[0..32], 12345, .little);
    std.mem.writeInt(i256, values.data[32..64], -67890, .little);
    values.freeze();

    const ty = datatype.DataType{ .decimal256 = .{ .precision = 40, .scale = -2 } };
    const data = try ArrayData.initOwned(allocator, ty, 2, 0, 0, &.{ null, values }, &.{}, null);
    values_owned = true;
    defer data.deinit();
    try data.validate();

    const arr = try Decimal256Array.fromData(data);
    try std.testing.expectEqual(@as(usize, 32), arr.byteWidth());
    try std.testing.expectEqual(@as(u8, 40), arr.precision());
    try std.testing.expectEqual(@as(i32, -2), arr.scale());
    try std.testing.expectEqual(@as(i256, 12345), arr.value(0));
    try std.testing.expectEqual(@as(i256, -67890), arr.value(1));
    try std.testing.expectEqual(@as(u8, 0xce), arr.valueBytes(1)[0]);
}
