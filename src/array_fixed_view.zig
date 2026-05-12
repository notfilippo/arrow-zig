// Copyright 2026 Filippo Rossi
// SPDX-License-Identifier: Apache-2.0

//! Fixed width typed array views.
//!
//! Includes booleans, numeric physical types, and logical temporal views backed
//! by int32 or int64 storage.

const std = @import("std");
const datatype = @import("datatype.zig");
const bitmap = @import("bitmap.zig");
const array_data = @import("array_data.zig");
const common = @import("array_view_common.zig");
const ArrayData = array_data.ArrayData;

pub const ArrayKind = common.ArrayKind;

fn valueTypeFor(comptime kind: ArrayKind) type {
    return switch (kind) {
        .bool => bool,
        .numeric => |T| T,
        .date32, .time32 => i32,
        .date64, .time64, .timestamp, .duration => i64,
    };
}

fn dataTypeMatchesKind(comptime kind: ArrayKind, ty: datatype.DataType) bool {
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

pub fn FixedWidthView(comptime kind: ArrayKind) type {
    const VT = valueTypeFor(kind);

    return struct {
        const Self = @This();
        pub const ValueType = VT;

        data: *const ArrayData,
        offset: usize,
        len: usize,
        null_count: usize,

        pub fn fromData(data: *const ArrayData) common.ViewError!Self {
            if (!dataTypeMatchesKind(kind, data.type)) return error.TypeMismatch;
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

        pub fn value(self: Self, i: usize) VT {
            const buf = self.data.buffers[1].?;
            if (comptime switch (kind) {
                .bool => true,
                else => false,
            }) {
                return bitmap.getBit(buf.dataSlice(), self.offset + i);
            } else {
                const ptr: [*]const VT = @ptrCast(@alignCast(buf.data));
                return ptr[self.offset + i];
            }
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

        pub fn trueCount(self: Self) usize {
            if (comptime switch (kind) {
                .bool => false,
                else => true,
            }) @compileError("trueCount is only available on BooleanArray");
            const values = self.data.buffers[1].?.dataSlice();
            const validity = self.data.buffers[0] orelse
                return bitmap.countSetBits(values, self.offset, self.len);
            return bitmap.countAndSetBits(values, self.offset, validity.dataSlice(), self.offset, self.len);
        }

        pub fn falseCount(self: Self) usize {
            if (comptime switch (kind) {
                .bool => false,
                else => true,
            }) @compileError("falseCount is only available on BooleanArray");
            return self.len - self.nullCount() - self.trueCount();
        }
    };
}

pub fn NumericArray(comptime T: type) type {
    _ = common.typeIdFor(T);
    return FixedWidthView(.{ .numeric = T });
}

pub const BooleanArray = FixedWidthView(.bool);
pub const Date32Array = FixedWidthView(.date32);
pub const Date64Array = FixedWidthView(.date64);
pub const Time32Array = FixedWidthView(.time32);
pub const Time64Array = FixedWidthView(.time64);
pub const TimestampArray = FixedWidthView(.timestamp);
pub const DurationArray = FixedWidthView(.duration);

test "NumericArray basic slices and ownership" {
    const bld = @import("builder.zig");
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
    try std.testing.expect(arr.isNull(1));

    const sliced = arr.slice(1, 3);
    try std.testing.expectEqual(array_data.unknown_null_count, sliced.null_count);
    try std.testing.expectEqual(@as(usize, 2), sliced.nullCount());
    try std.testing.expectEqual(@as(i32, 30), sliced.value(1));

    const sliced_owned = try sliced.sliceOwned(0, 2);
    defer sliced_owned.deinit();
    const sliced_owned_arr = try NumericArray(i32).fromData(sliced_owned);
    try std.testing.expect(sliced_owned_arr.isNull(0));
    try std.testing.expectEqual(@as(i32, 30), sliced_owned_arr.value(1));

    const sliced_clone = try sliced.cloneRetained();
    defer sliced_clone.deinit();
    const sliced_clone_arr = try NumericArray(i32).fromData(sliced_clone);
    try std.testing.expectEqual(@as(i32, 30), sliced_clone_arr.value(1));

    const owned = try arr.sliceOwned(0, 3);
    defer owned.deinit();
    const owned_arr = try NumericArray(i32).fromData(owned);
    try std.testing.expectEqual(@as(i32, 10), owned_arr.value(0));
    try std.testing.expectError(error.OffsetOutOfBounds, arr.sliceChecked(6, 1));
}

test "NumericArray all valid and all null slice counts" {
    const bld = @import("builder.zig");
    const allocator = std.testing.allocator;

    var valid_builder = bld.NumericBuilder(i32).init(allocator);
    defer valid_builder.deinit();
    try valid_builder.appendSlice(&.{ 1, 2, 3, 4, 5 });
    const valid_data = try valid_builder.finish();
    defer valid_data.deinit();
    const valid = try NumericArray(i32).fromData(valid_data);
    try std.testing.expectEqual(@as(usize, 0), valid.slice(1, 3).null_count);

    var null_builder = bld.NumericBuilder(i32).init(allocator);
    defer null_builder.deinit();
    try null_builder.appendNulls(5);
    const null_data = try null_builder.finish();
    defer null_data.deinit();
    const all_null = try NumericArray(i32).fromData(null_data);
    try std.testing.expectEqual(@as(usize, 3), all_null.slice(1, 3).null_count);
}

test "logical temporal arrays validate type" {
    const bld = @import("builder.zig");
    const allocator = std.testing.allocator;

    var date_builder = try bld.NumericBuilder(i32).initType(allocator, .date32);
    defer date_builder.deinit();
    try date_builder.appendSlice(&.{ 1, 2, 3 });
    const date_data = try date_builder.finish();
    defer date_data.deinit();
    const date_arr = try Date32Array.fromData(date_data);
    try std.testing.expectEqual(.date32, date_arr.dataType());
    try std.testing.expectError(error.TypeMismatch, NumericArray(i32).fromData(date_data));

    var time_builder = try bld.NumericBuilder(i32).initType(allocator, .{ .time32 = .millisecond });
    defer time_builder.deinit();
    try time_builder.appendSlice(&.{ 10, 20 });
    const time_data = try time_builder.finish();
    defer time_data.deinit();
    const time_arr = try Time32Array.fromData(time_data);
    try std.testing.expect(time_arr.dataType().id() == .time32);
}

test "BooleanArray counts and slicing" {
    const bld = @import("builder.zig");
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
    const sliced = arr.slice(1, 99);
    try std.testing.expectEqual(@as(usize, 3), sliced.len);
    try std.testing.expectEqual(@as(usize, 1), sliced.nullCount());
    try std.testing.expectError(error.OffsetOutOfBounds, arr.sliceOwned(5, 1));
}
