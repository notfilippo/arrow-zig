// Copyright 2026 Filippo Rossi
// SPDX-License-Identifier: Apache-2.0

//! Run end encoded array typed views.

const std = @import("std");
const datatype = @import("../datatype.zig");
const offset_data = @import("../offsets.zig");
const array_data = @import("data.zig");
const common = @import("base.zig");
const ArrayData = array_data.ArrayData;

pub fn RunEndView(comptime RunEnd: type) type {
    ensureRunEnd(RunEnd);

    return struct {
        const Self = @This();

        base: common.View,

        pub fn init(data: *const ArrayData) Self {
            return .{ .base = common.View.init(data) };
        }

        pub fn isValid(self: Self, i: usize) bool {
            return !self.isNull(i);
        }

        pub fn isNull(self: Self, i: usize) bool {
            return self.valueIsNull(self.runIndex(i));
        }

        pub fn nullCount(self: Self) usize {
            var count: usize = 0;
            const logical_start = self.base.offset;
            const logical_end = self.base.offset + self.base.len;
            for (0..self.runCount()) |run_index| {
                if (!self.valueIsNull(run_index)) continue;
                const end = runEndAsUsize(self.runEnd(run_index));
                const start = self.runStart(run_index);
                const overlap_start = @max(start, logical_start);
                const overlap_end = @min(end, logical_end);
                if (overlap_end > overlap_start) count += overlap_end - overlap_start;
            }
            return count;
        }

        pub fn slice(self: Self, off: usize, length: usize) Self {
            return self.sliceChecked(off, length) catch unreachable;
        }

        pub fn sliceChecked(self: Self, off: usize, length: usize) common.SliceError!Self {
            return .{ .base = try self.base.sliceChecked(off, length) };
        }

        fn runEndsData(self: Self) *const ArrayData {
            return self.base.data.children[0];
        }

        fn valuesData(self: Self) *const ArrayData {
            return self.base.data.children[1];
        }

        fn runCount(self: Self) usize {
            return self.runEndsData().len;
        }

        fn runEnd(self: Self, run_index: usize) RunEnd {
            const run_ends = self.runEndsData();
            const values = run_ends.buffers[1].?;
            return offset_data.read(RunEnd, values, run_ends.offset + run_index);
        }

        fn runIndex(self: Self, i: usize) usize {
            const logical = self.base.offset + i;
            var lo: usize = 0;
            var hi: usize = self.runCount();
            while (lo < hi) {
                const mid = lo + (hi - lo) / 2;
                if (runEndAsUsize(self.runEnd(mid)) > logical) {
                    hi = mid;
                } else {
                    lo = mid + 1;
                }
            }
            return lo;
        }

        fn valueIsNull(self: Self, run_index: usize) bool {
            const values = self.valuesData();
            if (values.type.id() == .null_) return true;
            return !common.slotIsValid(values, values.offset, run_index);
        }

        fn runStart(self: Self, run_index: usize) usize {
            if (run_index == 0) {
                const run_ends = self.runEndsData();
                if (run_ends.offset == 0) return 0;
                const values = run_ends.buffers[1].?;
                return runEndAsUsize(offset_data.read(RunEnd, values, run_ends.offset - 1));
            }
            return runEndAsUsize(self.runEnd(run_index - 1));
        }
    };
}

pub fn RunEndEncodedArray(comptime RunEnd: type) type {
    ensureRunEnd(RunEnd);

    return struct {
        const Self = @This();
        pub const RunEndType = RunEnd;

        view: RunEndView(RunEnd),

        pub fn fromData(data: *const ArrayData) common.ViewError!Self {
            if (data.type.id() != .run_end_encoded) return error.TypeMismatch;
            if (data.type.run_end_encoded.run_ends.type.id() != common.typeIdFor(RunEnd)) return error.TypeMismatch;
            if (data.buffers.len != 0 or data.children.len != 2) return error.InvalidBufferLayout;
            return .{ .view = RunEndView(RunEnd).init(data) };
        }

        pub fn runEndsData(self: Self) *const ArrayData {
            return self.view.base.data.children[0];
        }

        pub fn valuesData(self: Self) *const ArrayData {
            return self.view.base.data.children[1];
        }

        pub fn runCount(self: Self) usize {
            return self.runEndsData().len;
        }

        pub fn runEnd(self: Self, run_index: usize) RunEnd {
            const run_ends = self.runEndsData();
            const values = run_ends.buffers[1].?;
            return offset_data.read(RunEnd, values, run_ends.offset + run_index);
        }

        pub fn runIndex(self: Self, i: usize) usize {
            return self.view.runIndex(i);
        }

        pub fn runValueOwned(self: Self, run_index: usize) array_data.DataSliceError!*ArrayData {
            return self.valuesData().slice(run_index, 1);
        }

        pub fn valueOwned(self: Self, i: usize) array_data.DataSliceError!?*ArrayData {
            const run_index = self.runIndex(i);
            if (self.view.valueIsNull(run_index)) return null;
            return try self.runValueOwned(run_index);
        }
    };
}

fn ensureRunEnd(comptime T: type) void {
    switch (T) {
        i16, i32, i64 => {},
        else => @compileError("run end type must be i16, i32, or i64"),
    }
}

fn runEndAsUsize(value: anytype) usize {
    if (value < 0) unreachable;
    return @intCast(value);
}

test "RunEndEncodedArray maps logical slots to runs" {
    const allocator = std.testing.allocator;
    const Buffer = @import("../buffer.zig").Buffer;
    const builder = @import("../builder.zig");

    const run_values = try Buffer.allocate(allocator, 3 * @sizeOf(i32));
    errdefer run_values.deinit();
    offset_data.write(i32, run_values, 0, 2) catch unreachable;
    offset_data.write(i32, run_values, 1, 5) catch unreachable;
    offset_data.write(i32, run_values, 2, 7) catch unreachable;
    run_values.size = 3 * @sizeOf(i32);
    run_values.freeze();

    const run_ends = try ArrayData.initOwned(allocator, .int32, 3, 0, 0, &.{ null, run_values }, &.{}, null);
    errdefer run_ends.deinit();

    var value_builder = builder.NumericBuilder(i32).init(allocator);
    defer value_builder.deinit();
    try value_builder.append(10);
    try value_builder.append(20);
    try value_builder.appendNull();
    const values = try value_builder.finish();
    errdefer values.deinit();

    const run_ty: datatype.DataType = .int32;
    const value_ty: datatype.DataType = .int32;
    const run_field = try datatype.Field.create(allocator, "run_ends", &run_ty, false, &.{});
    defer run_field.deinit();
    const value_field = try datatype.Field.create(allocator, "values", &value_ty, true, &.{});
    defer value_field.deinit();
    const ty = datatype.DataType{ .run_end_encoded = .{ .run_ends = run_field, .values = value_field } };
    const data = try ArrayData.initOwned(allocator, ty, 7, 0, 0, &.{}, &.{ run_ends, values }, null);
    defer data.deinit();
    try data.validate();

    const arr = try RunEndEncodedArray(i32).fromData(data);
    try std.testing.expectEqual(@as(usize, 0), arr.runIndex(0));
    try std.testing.expectEqual(@as(usize, 1), arr.runIndex(2));
    try std.testing.expectEqual(@as(usize, 2), arr.runIndex(6));
    try std.testing.expect(arr.view.isValid(0));
    try std.testing.expect(arr.view.isNull(5));
    try std.testing.expectEqual(@as(usize, 2), arr.view.nullCount());

    const value = (try arr.valueOwned(3)).?;
    defer value.deinit();
    const value_arr = try @import("../array.zig").NumericArray(i32).fromData(value);
    try std.testing.expectEqual(@as(i32, 20), value_arr.value(0));
    try std.testing.expect((try arr.valueOwned(5)) == null);

    const sliced = RunEndEncodedArray(i32){ .view = arr.view.slice(1, 5) };
    try std.testing.expectEqual(@as(usize, 1), sliced.view.base.offset);
    try std.testing.expectEqual(@as(usize, 1), sliced.runIndex(1));
    try std.testing.expectEqual(@as(usize, 1), sliced.view.nullCount());
}
