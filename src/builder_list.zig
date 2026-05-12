// Copyright 2026 Filippo Rossi
// SPDX-License-Identifier: Apache-2.0

//! List and large list builders.
//!
//! The child builder owns values. Each appended list slot records the current
//! child length as the next offset.

const std = @import("std");
const Allocator = std.mem.Allocator;
const checked = @import("checked.zig");
const bitmap = @import("bitmap.zig");
const datatype = @import("datatype.zig");
const offset_data = @import("offsets.zig");
const array = @import("array.zig");
const ArrayData = array.ArrayData;
const Buffer = @import("buffer.zig").Buffer;

pub const FieldOptions = struct {
    name: []const u8 = "item",
    nullable: bool = true,
};

pub fn ListBuilderError(comptime ChildBuilder: type) type {
    return Allocator.Error || checked.Error || error{UnclosedListValues} || ChildBuilder.Error;
}

pub fn VarListBuilder(comptime kind: array.ListKind, comptime ChildBuilder: type) type {
    const Offset = switch (kind) {
        .list => i32,
        .large_list => i64,
    };

    return struct {
        const Self = @This();
        pub const Array = array.ListView(kind);
        pub const Child = ChildBuilder;
        pub const Error = ListBuilderError(ChildBuilder);

        allocator: Allocator,
        child: ChildBuilder,
        offsets: offset_data.Builder(Offset),
        validity: bitmap.BitmapBuilder,
        len: usize,
        last_child_len: usize,
        child_name: []const u8,
        owned_child_name: ?[]u8,
        child_nullable: bool,

        pub fn init(allocator: Allocator) Self {
            return .{
                .allocator = allocator,
                .child = ChildBuilder.init(allocator),
                .offsets = offset_data.Builder(Offset).init(),
                .validity = bitmap.BitmapBuilder.init(),
                .len = 0,
                .last_child_len = 0,
                .child_name = "item",
                .owned_child_name = null,
                .child_nullable = true,
            };
        }

        pub fn initField(allocator: Allocator, options: FieldOptions) Error!Self {
            var self = init(allocator);
            errdefer self.deinit();
            const name = try allocator.dupe(u8, options.name);
            self.child_name = name;
            self.owned_child_name = name;
            self.child_nullable = options.nullable;
            return self;
        }

        pub fn deinit(self: *Self) void {
            self.child.deinit();
            self.offsets.deinit();
            self.validity.deinit();
            if (self.owned_child_name) |name| self.allocator.free(name);
            self.len = 0;
            self.last_child_len = 0;
            self.child_name = "item";
            self.owned_child_name = null;
            self.child_nullable = true;
        }

        pub fn values(self: *Self) *ChildBuilder {
            return &self.child;
        }

        pub fn reserve(self: *Self, additional: usize) Error!void {
            if (additional == 0) return;
            const new_len = try checked.add(self.len, additional);
            try self.offsets.reserveSlots(self.allocator, try checked.add(new_len, 1));
            try self.validity.ensureCapacityForBits(self.allocator, additional);
        }

        pub fn append(self: *Self) Error!void {
            try self.reserve(1);
            try self.appendOffset(self.child.length(), true);
        }

        pub fn appendEmpty(self: *Self) Error!void {
            try self.append();
        }

        pub fn appendNull(self: *Self) Error!void {
            if (self.child.length() != self.last_child_len) return error.UnclosedListValues;
            try self.reserve(1);
            try self.appendOffset(self.last_child_len, false);
        }

        pub fn appendNulls(self: *Self, n: usize) Error!void {
            if (n == 0) return;
            if (self.child.length() != self.last_child_len) return error.UnclosedListValues;
            try self.reserve(n);
            try self.offsets.appendRepeat(self.allocator, n, self.last_child_len);
            self.validity.unsafeAppendN(false, n);
            self.len = try checked.add(self.len, n);
        }

        pub fn length(self: Self) usize {
            return self.len;
        }

        /// Finish the builder and transfer the result to the caller.
        /// Caller owns the returned data and must call `deinit`.
        pub fn finish(self: *Self) Error!*ArrayData {
            if (self.child.length() != self.last_child_len) return error.UnclosedListValues;

            const n = self.len;
            const null_count = self.validity.false_count;
            var consumed = false;
            errdefer if (consumed) self.resetSlots();

            const offsets_buf = try self.offsets.finish(self.allocator);
            consumed = true;
            errdefer offsets_buf.deinit();

            const child_data = try self.child.finish();
            errdefer child_data.deinit();

            const validity_buf: ?*Buffer = try self.validity.finishNullable(self.allocator);
            errdefer if (validity_buf) |buf| buf.deinit();

            const child_field = datatype.Field{
                .name = self.child_name,
                .type = &child_data.type,
                .nullable = self.child_nullable,
            };
            const ty = dataTypeForKind(kind, child_field);
            const data = try ArrayData.initOwned(self.allocator, ty, n, 0, null_count, &.{ validity_buf, offsets_buf }, &.{child_data}, null);
            self.resetSlots();
            return data;
        }

        fn appendOffset(self: *Self, child_len: usize, valid: bool) Error!void {
            try self.offsets.append(self.allocator, child_len);
            self.validity.unsafeAppend(valid);
            self.len += 1;
            self.last_child_len = child_len;
        }

        fn resetSlots(self: *Self) void {
            self.len = 0;
            self.last_child_len = 0;
        }
    };
}

pub fn ListBuilder(comptime ChildBuilder: type) type {
    return VarListBuilder(.list, ChildBuilder);
}

pub fn LargeListBuilder(comptime ChildBuilder: type) type {
    return VarListBuilder(.large_list, ChildBuilder);
}

fn dataTypeForKind(comptime kind: array.ListKind, child: datatype.Field) datatype.DataType {
    return switch (kind) {
        .list => .{ .list = .{ .child = child } },
        .large_list => .{ .large_list = .{ .child = child } },
    };
}

test "ListBuilder builds numeric child lists" {
    const allocator = std.testing.allocator;
    const builder = @import("builder.zig");
    var b = ListBuilder(builder.NumericBuilder(i32)).init(allocator);
    defer b.deinit();

    try b.values().appendSlice(&.{ 1, 2 });
    try b.append();
    try b.appendEmpty();
    try b.values().append(3);
    try b.append();
    try b.appendNull();

    const data = try b.finish();
    defer data.deinit();
    try data.validate();

    const arr = try array.ListArray.fromData(data);
    try std.testing.expectEqual(@as(usize, 4), arr.len);
    try std.testing.expectEqual(@as(usize, 1), arr.nullCount());
    try std.testing.expectEqual(@as(usize, 0), arr.valueRange(0).offset);
    try std.testing.expectEqual(@as(usize, 2), arr.valueRange(0).len);
    try std.testing.expectEqual(@as(usize, 0), arr.valueRange(1).len);
    try std.testing.expect(arr.isNull(3));

    const child = try array.NumericArray(i32).fromData(arr.childBaseData());
    try std.testing.expectEqual(@as(usize, 3), child.len);
    try std.testing.expectEqual(@as(i32, 3), child.value(2));
}

test "ListBuilder rejects pending child values for null slots" {
    const allocator = std.testing.allocator;
    const builder = @import("builder.zig");
    var b = ListBuilder(builder.NumericBuilder(i32)).init(allocator);
    defer b.deinit();

    try b.values().append(1);
    try std.testing.expectError(error.UnclosedListValues, b.appendNull());
    try b.append();
    const data = try b.finish();
    defer data.deinit();
    try data.validate();
}

test "LargeListBuilder uses large offsets and field options" {
    const allocator = std.testing.allocator;
    const builder = @import("builder.zig");
    var b = try LargeListBuilder(builder.Utf8Builder).initField(allocator, .{ .name = "words", .nullable = false });
    defer b.deinit();

    try b.values().append("alpha");
    try b.append();
    try b.values().append("beta");
    try b.values().append("gamma");
    try b.append();

    const data = try b.finish();
    defer data.deinit();
    try data.validate();

    const arr = try array.LargeListArray.fromData(data);
    try std.testing.expectEqual(@as(usize, 1), arr.valueRange(1).offset);
    try std.testing.expectEqual(@as(usize, 2), arr.valueRange(1).len);
    try std.testing.expectEqualStrings("words", data.type.large_list.child.name);
    try std.testing.expect(!data.type.large_list.child.nullable);
}
