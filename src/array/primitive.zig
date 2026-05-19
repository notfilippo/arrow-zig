// Copyright 2026 Filippo Rossi
// SPDX-License-Identifier: Apache-2.0

//! Fixed width primitive array types.
//!
//! Includes booleans, numeric physical types, and logical temporal arrays backed
//! by int32 or int64 storage.

const std = @import("std");
const datatype = @import("../datatype.zig");
const bitmap = @import("../bitmap.zig");
const array_data = @import("data.zig");
const common = @import("base.zig");
const ArrayData = array_data.ArrayData;

pub const FixedWidthKind = common.FixedWidthKind;

fn valueTypeFor(comptime kind: FixedWidthKind) type {
    return switch (kind) {
        .bool => bool,
        .numeric => |T| T,
        .date32, .time32 => i32,
        .date64, .time64, .timestamp, .duration => i64,
    };
}

fn dataTypeMatchesKind(comptime kind: FixedWidthKind, ty: datatype.DataType) bool {
    return switch (kind) {
        .bool => ty == .bool,
        .numeric => |T| ty.id() == common.typeIdFor(T),
        .date32 => ty == .date32,
        .date64 => ty == .date64,
        .time32 => switch (ty) {
            .time32 => |u| u == .second or u == .millisecond,
            else => false,
        },
        .time64 => switch (ty) {
            .time64 => |u| u == .microsecond or u == .nanosecond,
            else => false,
        },
        .timestamp => ty.id() == .timestamp,
        .duration => ty.id() == .duration,
    };
}

pub fn FixedWidthArray(comptime kind: FixedWidthKind) type {
    const VT = valueTypeFor(kind);

    return struct {
        const Self = @This();
        pub const ValueType = VT;

        view: common.ValidityView(.bitmap),

        pub fn fromData(data: *const ArrayData) common.ViewError!Self {
            if (!dataTypeMatchesKind(kind, data.type)) return error.TypeMismatch;
            if (data.buffers.len < 2 or data.buffers[1] == null) return error.InvalidBufferLayout;
            return .{ .view = common.ValidityView(.bitmap).init(data) };
        }

        pub fn value(self: Self, i: usize) VT {
            const buf = self.view.base.data.buffers[1].?;
            if (comptime switch (kind) {
                .bool => true,
                else => false,
            }) {
                return bitmap.getBit(buf.dataSlice(), self.view.base.offset + i);
            } else {
                const start = (self.view.base.offset + i) * @sizeOf(VT);
                return readValue(VT, buf.dataSlice()[start..][0..@sizeOf(VT)]);
            }
        }

        pub fn trueCount(self: Self) usize {
            if (comptime switch (kind) {
                .bool => false,
                else => true,
            }) @compileError("trueCount is only available on BooleanArray");
            const values = self.view.base.data.buffers[1].?.dataSlice();
            const validity = self.view.base.data.buffers[0] orelse
                return bitmap.countSetBits(values, self.view.base.offset, self.view.base.len);
            return bitmap.countAndSetBits(values, self.view.base.offset, validity.dataSlice(), self.view.base.offset, self.view.base.len);
        }

        pub fn falseCount(self: Self) usize {
            if (comptime switch (kind) {
                .bool => false,
                else => true,
            }) @compileError("falseCount is only available on BooleanArray");
            return self.view.base.len - self.view.nullCount() - self.trueCount();
        }
    };
}

fn readValue(comptime T: type, bytes: *const [@sizeOf(T)]u8) T {
    return switch (@typeInfo(T)) {
        .int => std.mem.readInt(T, bytes, .little),
        .float => @bitCast(std.mem.readInt(std.meta.Int(.unsigned, @bitSizeOf(T)), bytes, .little)),
        else => @compileError("unsupported Arrow fixed width value: " ++ @typeName(T)),
    };
}

pub fn NumericArray(comptime T: type) type {
    _ = common.typeIdFor(T);
    return FixedWidthArray(.{ .numeric = T });
}

pub const BooleanArray = FixedWidthArray(.bool);
pub const Date32Array = FixedWidthArray(.date32);
pub const Date64Array = FixedWidthArray(.date64);
pub const Time32Array = FixedWidthArray(.time32);
pub const Time64Array = FixedWidthArray(.time64);
pub const TimestampArray = FixedWidthArray(.timestamp);
pub const DurationArray = FixedWidthArray(.duration);

test "NumericArray basic slices and ownership" {
    const bld = @import("../builder.zig");
    const allocator = std.testing.allocator;
    var b = bld.NumericBuilder(i32).init(allocator);
    defer b.deinit();

    try b.append(10);
    try b.appendNull();
    try b.append(30);
    try b.appendNull();
    try b.append(50);
    const data = try b.finish();
    defer data.deinit();
    const arr = try NumericArray(i32).fromData(data);

    try std.testing.expectEqual(@as(i32, 30), arr.value(2));
    try std.testing.expect(arr.view.isNull(1));

    const sliced = NumericArray(i32){ .view = arr.view.slice(1, 3) };
    try std.testing.expectEqual(@as(?usize, null), sliced.view.null_count);
    try std.testing.expectEqual(@as(usize, 2), sliced.view.nullCount());
    try std.testing.expectEqual(@as(i32, 30), sliced.value(1));

    const sliced_owned = try sliced.view.base.sliceOwned(0, 2);
    defer sliced_owned.deinit();
    const sliced_owned_arr = try NumericArray(i32).fromData(sliced_owned);
    try std.testing.expect(sliced_owned_arr.view.isNull(0));
    try std.testing.expectEqual(@as(i32, 30), sliced_owned_arr.value(1));

    const sliced_clone = try sliced.view.base.cloneRetained();
    defer sliced_clone.deinit();
    const sliced_clone_arr = try NumericArray(i32).fromData(sliced_clone);
    try std.testing.expectEqual(@as(i32, 30), sliced_clone_arr.value(1));

    const owned = try arr.view.base.sliceOwned(0, 3);
    defer owned.deinit();
    const owned_arr = try NumericArray(i32).fromData(owned);
    try std.testing.expectEqual(@as(i32, 10), owned_arr.value(0));
    try std.testing.expectError(error.OffsetOutOfBounds, arr.view.sliceChecked(6, 1));
}

test "NumericArray all valid and all null slice counts" {
    const bld = @import("../builder.zig");
    const allocator = std.testing.allocator;

    var valid_builder = bld.NumericBuilder(i32).init(allocator);
    defer valid_builder.deinit();
    try valid_builder.appendSlice(&.{ 1, 2, 3, 4, 5 });
    const valid_data = try valid_builder.finish();
    defer valid_data.deinit();
    const valid = try NumericArray(i32).fromData(valid_data);
    try std.testing.expectEqual(@as(usize, 0), valid.view.slice(1, 3).null_count);

    var null_builder = bld.NumericBuilder(i32).init(allocator);
    defer null_builder.deinit();
    try null_builder.appendNulls(5);
    const null_data = try null_builder.finish();
    defer null_data.deinit();
    const all_null = try NumericArray(i32).fromData(null_data);
    try std.testing.expectEqual(@as(usize, 3), all_null.view.slice(1, 3).null_count);
}

test "logical temporal arrays validate type" {
    const bld = @import("../builder.zig");
    const allocator = std.testing.allocator;

    var date_builder = try bld.NumericBuilder(i32).initType(allocator, .date32);
    defer date_builder.deinit();
    try date_builder.appendSlice(&.{ 1, 2, 3 });
    const date_data = try date_builder.finish();
    defer date_data.deinit();
    const date_arr = try Date32Array.fromData(date_data);
    try std.testing.expectEqual(.date32, date_arr.view.base.data.type);
    try std.testing.expectError(error.TypeMismatch, NumericArray(i32).fromData(date_data));

    var time_builder = try bld.NumericBuilder(i32).initType(allocator, .{ .time32 = .millisecond });
    defer time_builder.deinit();
    try time_builder.appendSlice(&.{ 10, 20 });
    const time_data = try time_builder.finish();
    defer time_data.deinit();
    const time_arr = try Time32Array.fromData(time_data);
    try std.testing.expect(time_arr.view.base.data.type.id() == .time32);
}

test "BooleanArray counts and slicing" {
    const bld = @import("../builder.zig");
    const allocator = std.testing.allocator;
    var b = bld.BooleanBuilder.init(allocator);
    defer b.deinit();

    try b.append(true);
    try b.appendNull();
    try b.append(false);
    try b.append(true);
    const data = try b.finish();
    defer data.deinit();
    const arr = try BooleanArray.fromData(data);

    try std.testing.expectEqual(@as(usize, 2), arr.trueCount());
    try std.testing.expectEqual(@as(usize, 1), arr.falseCount());
    const sliced = arr.view.slice(1, 99);
    try std.testing.expectEqual(@as(usize, 3), sliced.base.len);
    try std.testing.expectEqual(@as(usize, 1), sliced.nullCount());
    try std.testing.expectError(error.OffsetOutOfBounds, arr.view.base.sliceOwned(5, 1));
}
