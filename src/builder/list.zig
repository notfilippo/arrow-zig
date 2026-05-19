// Copyright 2026 Filippo Rossi
// SPDX-License-Identifier: Apache-2.0

//! List and large list builders.
//!
//! The child builder owns values. Each appended list slot records the current
//! child length as the next offset.

const std = @import("std");
const Allocator = std.mem.Allocator;
const checked = @import("../checked.zig");
const datatype = @import("../datatype.zig");
const offset_data = @import("../offsets.zig");
const array = @import("../array.zig");
const array_list = @import("../array/list.zig");
const ArrayData = array.ArrayData;
const Buffer = @import("../buffer.zig").Buffer;
const common = @import("common.zig");

pub const FieldOptions = struct {
    name: []const u8 = "item",
    nullable: bool = true,
};

pub fn ListBuilderError(comptime ChildBuilder: type) type {
    return Allocator.Error || checked.Error || error{ UnclosedListValues, ViewOutOfBounds } || ChildBuilder.Error;
}

pub fn VarListBuilder(comptime kind: array_list.ListKind, comptime ChildBuilder: type) type {
    const Offset = switch (kind) {
        .list => i32,
        .large_list => i64,
    };

    return struct {
        const Self = @This();
        pub const Array = array_list.VarListArray(kind);
        pub const Child = ChildBuilder;
        pub const Error = ListBuilderError(ChildBuilder);

        allocator: Allocator,
        child: ChildBuilder,
        offsets: offset_data.Builder(Offset),
        slots: common.Slots,
        last_child_len: usize,
        child_name: []const u8,
        owned_child_name: ?[]u8,
        child_nullable: bool,

        pub fn init(allocator: Allocator) Self {
            return .{
                .allocator = allocator,
                .child = ChildBuilder.init(allocator),
                .offsets = offset_data.Builder(Offset).init(),
                .slots = common.Slots.init(),
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
            self.clearListState(true);
        }

        /// Release all held memory and return to the post-`init` state.
        pub fn reset(self: *Self) void {
            if (comptime !@hasDecl(ChildBuilder, "reset")) {
                @compileError("ListBuilder.reset requires ChildBuilder.reset");
            }
            self.resetChild();
            self.clearListState(false);
        }

        pub fn values(self: *Self) *ChildBuilder {
            return &self.child;
        }

        pub fn reserve(self: *Self, additional: usize) Error!void {
            if (additional == 0) return;
            const new_len = try checked.add(self.slots.len, additional);
            const capped_len = @max(new_len, common.kMinBuilderCapacity);
            try self.offsets.reserveSlots(self.allocator, try checked.add(capped_len, 1));
            try self.slots.reserve(self.allocator, additional);
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
            try self.slots.unsafeAppendN(false, n);
        }

        /// Append a valid empty list slot with no pending child values.
        pub fn appendEmptyValue(self: *Self) Error!void {
            if (self.child.length() != self.last_child_len) return error.UnclosedListValues;
            try self.reserve(1);
            try self.appendOffset(self.last_child_len, true);
        }

        /// Append `n` valid empty list slots with no pending child values.
        pub fn appendEmptyValues(self: *Self, n: usize) Error!void {
            if (n == 0) return;
            if (self.child.length() != self.last_child_len) return error.UnclosedListValues;
            try self.reserve(n);
            try self.offsets.appendRepeat(self.allocator, n, self.last_child_len);
            try self.slots.unsafeAppendN(true, n);
        }

        pub fn length(self: Self) usize {
            return self.slots.length();
        }

        /// Finish the builder and transfer the result to the caller.
        /// Caller owns the returned data and must call `deinit`.
        pub fn finish(self: *Self) Error!*ArrayData {
            if (self.child.length() != self.last_child_len) return error.UnclosedListValues;

            var consumed = false;
            errdefer if (consumed) {
                self.slots.len = 0;
                self.last_child_len = 0;
            };

            const offsets_buf = try self.offsets.finish(self.allocator);
            consumed = true;
            errdefer offsets_buf.deinit();

            const child_data = try self.child.finish();
            errdefer child_data.deinit();

            const slots = try self.slots.finish(self.allocator);
            errdefer if (slots.validity) |buf| buf.deinit();

            const child_field = try datatype.Field.create(self.allocator, self.child_name, &child_data.type, self.child_nullable, &.{});
            errdefer child_field.deinit();
            const ty = dataTypeForKind(kind, child_field);
            const data = try ArrayData.initOwned(self.allocator, ty, slots.len, 0, slots.null_count, &.{ slots.validity, offsets_buf }, &.{child_data}, null);
            child_field.deinit();
            self.last_child_len = 0;
            return data;
        }

        fn appendOffset(self: *Self, child_len: usize, valid: bool) Error!void {
            try self.offsets.append(self.allocator, child_len);
            self.slots.unsafeAppend(valid);
            self.last_child_len = child_len;
        }

        fn resetChild(self: *Self) void {
            self.child.reset();
        }

        fn clearListState(self: *Self, comptime clear_field_options: bool) void {
            self.offsets.deinit();
            self.slots.deinit();
            if (clear_field_options) {
                if (self.owned_child_name) |name| self.allocator.free(name);
                self.child_name = "item";
                self.owned_child_name = null;
                self.child_nullable = true;
            }
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

const ListViewKind = enum {
    list_view,
    large_list_view,
};

fn VarListViewBuilder(comptime kind: ListViewKind, comptime ChildBuilder: type) type {
    const Offset = switch (kind) {
        .list_view => i32,
        .large_list_view => i64,
    };

    return struct {
        const Self = @This();
        pub const Array = switch (kind) {
            .list_view => array.ListViewArray,
            .large_list_view => array.LargeListViewArray,
        };
        pub const Child = ChildBuilder;
        pub const Error = ListBuilderError(ChildBuilder);

        allocator: Allocator,
        child: ChildBuilder,
        offsets: ?*Buffer,
        sizes: ?*Buffer,
        slots: common.Slots,
        last_child_len: usize,
        child_name: []const u8,
        owned_child_name: ?[]u8,
        child_nullable: bool,

        pub fn init(allocator: Allocator) Self {
            return .{
                .allocator = allocator,
                .child = ChildBuilder.init(allocator),
                .offsets = null,
                .sizes = null,
                .slots = common.Slots.init(),
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
            self.clearListState(true);
        }

        pub fn reset(self: *Self) void {
            if (comptime !@hasDecl(ChildBuilder, "reset")) {
                @compileError("ListViewBuilder.reset requires ChildBuilder.reset");
            }
            self.resetChild();
            self.clearListState(false);
        }

        pub fn values(self: *Self) *ChildBuilder {
            return &self.child;
        }

        pub fn reserve(self: *Self, additional: usize) Error!void {
            if (additional == 0) return;
            const new_len = try checked.add(self.slots.len, additional);
            const capped_len = @max(new_len, common.kMinBuilderCapacity);
            try reserveOffsetSlots(Offset, self.allocator, &self.offsets, capped_len);
            try reserveOffsetSlots(Offset, self.allocator, &self.sizes, capped_len);
            try self.slots.reserve(self.allocator, additional);
        }

        pub fn append(self: *Self) Error!void {
            const child_len = self.child.length();
            if (child_len < self.last_child_len) return error.UnclosedListValues;
            const len = child_len - self.last_child_len;
            try self.appendSlot(self.last_child_len, len, true);
            self.last_child_len = child_len;
        }

        pub fn appendEmpty(self: *Self) Error!void {
            try self.append();
        }

        pub fn appendView(self: *Self, offset: usize, len: usize) Error!void {
            const end = try checked.add(offset, len);
            if (end > self.child.length()) return error.ViewOutOfBounds;
            try self.appendSlot(offset, len, true);
            self.last_child_len = @max(self.last_child_len, end);
        }

        pub fn appendNull(self: *Self) Error!void {
            if (self.child.length() != self.last_child_len) return error.UnclosedListValues;
            try self.appendSlot(self.last_child_len, 0, false);
        }

        pub fn appendNulls(self: *Self, n: usize) Error!void {
            if (n == 0) return;
            if (self.child.length() != self.last_child_len) return error.UnclosedListValues;
            try self.reserve(n);
            for (0..n) |_| self.unsafeAppendSlot(self.last_child_len, 0, false);
        }

        pub fn appendEmptyValue(self: *Self) Error!void {
            if (self.child.length() != self.last_child_len) return error.UnclosedListValues;
            try self.appendSlot(self.last_child_len, 0, true);
        }

        pub fn appendEmptyValues(self: *Self, n: usize) Error!void {
            if (n == 0) return;
            if (self.child.length() != self.last_child_len) return error.UnclosedListValues;
            try self.reserve(n);
            for (0..n) |_| self.unsafeAppendSlot(self.last_child_len, 0, true);
        }

        pub fn length(self: Self) usize {
            return self.slots.length();
        }

        pub fn finish(self: *Self) Error!*ArrayData {
            if (self.child.length() != self.last_child_len) return error.UnclosedListValues;

            var consumed = false;
            errdefer if (consumed) {
                self.slots.len = 0;
                self.last_child_len = 0;
            };

            const offsets_buf = try finishOffsetBuffer(Offset, self.allocator, &self.offsets);
            consumed = true;
            errdefer offsets_buf.deinit();

            const sizes_buf = try finishOffsetBuffer(Offset, self.allocator, &self.sizes);
            errdefer sizes_buf.deinit();

            const child_data = try self.child.finish();
            errdefer child_data.deinit();

            const slots = try self.slots.finish(self.allocator);
            errdefer if (slots.validity) |buf| buf.deinit();

            const child_field = try datatype.Field.create(self.allocator, self.child_name, &child_data.type, self.child_nullable, &.{});
            errdefer child_field.deinit();
            const ty = dataTypeForListViewKind(kind, child_field);
            const data = try ArrayData.initOwned(self.allocator, ty, slots.len, 0, slots.null_count, &.{ slots.validity, offsets_buf, sizes_buf }, &.{child_data}, null);
            child_field.deinit();
            self.last_child_len = 0;
            return data;
        }

        fn appendSlot(self: *Self, offset: usize, len: usize, valid: bool) Error!void {
            try self.reserve(1);
            self.unsafeAppendSlot(offset, len, valid);
        }

        fn unsafeAppendSlot(self: *Self, offset: usize, len: usize, valid: bool) void {
            appendOffsetSlot(Offset, self.offsets.?, offset) catch unreachable;
            appendOffsetSlot(Offset, self.sizes.?, len) catch unreachable;
            self.slots.unsafeAppend(valid);
        }

        fn resetChild(self: *Self) void {
            self.child.reset();
        }

        fn clearListState(self: *Self, comptime clear_field_options: bool) void {
            if (self.offsets) |buf| buf.deinit();
            if (self.sizes) |buf| buf.deinit();
            self.offsets = null;
            self.sizes = null;
            self.slots.deinit();
            if (clear_field_options) {
                if (self.owned_child_name) |name| self.allocator.free(name);
                self.child_name = "item";
                self.owned_child_name = null;
                self.child_nullable = true;
            }
            self.last_child_len = 0;
        }
    };
}

pub fn ListViewBuilder(comptime ChildBuilder: type) type {
    return VarListViewBuilder(.list_view, ChildBuilder);
}

pub fn LargeListViewBuilder(comptime ChildBuilder: type) type {
    return VarListViewBuilder(.large_list_view, ChildBuilder);
}

pub fn FixedSizeListBuilder(comptime ChildBuilder: type) type {
    return struct {
        const Self = @This();
        pub const Array = array.FixedSizeListArray;
        pub const Child = ChildBuilder;
        pub const Error = ListBuilderError(ChildBuilder);

        allocator: Allocator,
        child: ChildBuilder,
        slots: common.Slots,
        last_child_len: usize,
        list_size: usize,
        child_name: []const u8,
        owned_child_name: ?[]u8,
        child_nullable: bool,

        pub fn init(allocator: Allocator, list_size: usize) Self {
            return .{
                .allocator = allocator,
                .child = ChildBuilder.init(allocator),
                .slots = common.Slots.init(),
                .last_child_len = 0,
                .list_size = list_size,
                .child_name = "item",
                .owned_child_name = null,
                .child_nullable = true,
            };
        }

        pub fn initField(allocator: Allocator, list_size: usize, options: FieldOptions) Error!Self {
            var self = init(allocator, list_size);
            errdefer self.deinit();
            const name = try allocator.dupe(u8, options.name);
            self.child_name = name;
            self.owned_child_name = name;
            self.child_nullable = options.nullable;
            return self;
        }

        pub fn deinit(self: *Self) void {
            self.child.deinit();
            self.clearListState(true);
        }

        pub fn reset(self: *Self) void {
            if (comptime !@hasDecl(ChildBuilder, "reset")) {
                @compileError("FixedSizeListBuilder.reset requires ChildBuilder.reset");
            }
            self.resetChild();
            self.clearListState(false);
        }

        pub fn values(self: *Self) *ChildBuilder {
            return &self.child;
        }

        pub fn reserve(self: *Self, additional: usize) Error!void {
            if (additional == 0) return;
            try self.slots.reserve(self.allocator, @max(additional, common.kMinBuilderCapacity));
        }

        pub fn append(self: *Self) Error!void {
            const child_len = self.child.length();
            if (child_len < self.last_child_len) return error.UnclosedListValues;
            if (child_len - self.last_child_len != self.list_size) return error.UnclosedListValues;
            try self.appendSlot(child_len, true);
        }

        pub fn appendNull(self: *Self) Error!void {
            try self.ensureNoPending();
            try self.reserve(1);
            try self.appendChildEmptyValues(self.list_size);
            try self.slots.unsafeAppendN(false, 1);
            self.last_child_len = self.child.length();
        }

        pub fn appendNulls(self: *Self, n: usize) Error!void {
            if (n == 0) return;
            try self.ensureNoPending();
            try self.reserve(n);
            try self.appendChildEmptyValues(try checked.mul(n, self.list_size));
            try self.slots.unsafeAppendN(false, n);
            self.last_child_len = self.child.length();
        }

        pub fn appendEmptyValue(self: *Self) Error!void {
            try self.ensureNoPending();
            try self.reserve(1);
            try self.appendChildEmptyValues(self.list_size);
            try self.slots.unsafeAppendN(true, 1);
            self.last_child_len = self.child.length();
        }

        pub fn appendEmptyValues(self: *Self, n: usize) Error!void {
            if (n == 0) return;
            try self.ensureNoPending();
            try self.reserve(n);
            try self.appendChildEmptyValues(try checked.mul(n, self.list_size));
            try self.slots.unsafeAppendN(true, n);
            self.last_child_len = self.child.length();
        }

        pub fn length(self: Self) usize {
            return self.slots.length();
        }

        pub fn finish(self: *Self) Error!*ArrayData {
            const expected_child_len = try checked.mul(self.slots.len, self.list_size);
            if (self.child.length() != expected_child_len) return error.UnclosedListValues;

            var consumed = false;
            errdefer if (consumed) {
                self.slots.len = 0;
                self.last_child_len = 0;
            };

            const child_data = try self.child.finish();
            consumed = true;
            errdefer child_data.deinit();

            const slots = try self.slots.finish(self.allocator);
            errdefer if (slots.validity) |buf| buf.deinit();

            const child_field = try datatype.Field.create(self.allocator, self.child_name, &child_data.type, self.child_nullable, &.{});
            errdefer child_field.deinit();
            const ty = datatype.DataType{ .fixed_size_list = .{ .child = child_field, .len = self.list_size } };
            const data = try ArrayData.initOwned(self.allocator, ty, slots.len, 0, slots.null_count, &.{slots.validity}, &.{child_data}, null);
            child_field.deinit();
            self.last_child_len = 0;
            return data;
        }

        fn appendSlot(self: *Self, child_len: usize, valid: bool) Error!void {
            try self.reserve(1);
            try self.slots.unsafeAppendN(valid, 1);
            self.last_child_len = child_len;
        }

        fn ensureNoPending(self: *Self) Error!void {
            if (self.child.length() != self.last_child_len) return error.UnclosedListValues;
        }

        fn appendChildEmptyValues(self: *Self, n: usize) Error!void {
            if (n == 0) return;
            if (comptime !@hasDecl(ChildBuilder, "appendEmptyValues")) {
                @compileError("FixedSizeListBuilder null and empty appends require ChildBuilder.appendEmptyValues");
            }
            try self.child.appendEmptyValues(n);
        }

        fn resetChild(self: *Self) void {
            self.child.reset();
        }

        fn clearListState(self: *Self, comptime clear_field_options: bool) void {
            self.slots.deinit();
            if (clear_field_options) {
                if (self.owned_child_name) |name| self.allocator.free(name);
                self.child_name = "item";
                self.owned_child_name = null;
                self.child_nullable = true;
            }
            self.last_child_len = 0;
        }
    };
}

fn dataTypeForKind(comptime kind: array_list.ListKind, child: *const datatype.Field) datatype.DataType {
    return switch (kind) {
        .list => .{ .list = .{ .child = child } },
        .large_list => .{ .large_list = .{ .child = child } },
    };
}

fn dataTypeForListViewKind(comptime kind: ListViewKind, child: *const datatype.Field) datatype.DataType {
    return switch (kind) {
        .list_view => .{ .list_view = .{ .child = child } },
        .large_list_view => .{ .large_list_view = .{ .child = child } },
    };
}

fn reserveOffsetSlots(comptime Offset: type, allocator: Allocator, buffer: *?*Buffer, slots: usize) (Allocator.Error || checked.Error)!void {
    if (slots == 0) return;
    const buf = try ensureOffsetBuffer(allocator, buffer);
    try buf.reserve(try checked.mul(slots, @sizeOf(Offset)));
}

fn appendOffsetSlot(comptime Offset: type, buffer: *Buffer, value: usize) checked.Error!void {
    const index = buffer.size / @sizeOf(Offset);
    try offset_data.write(Offset, buffer, index, value);
    buffer.size = try checked.add(buffer.size, @sizeOf(Offset));
}

fn finishOffsetBuffer(comptime Offset: type, allocator: Allocator, buffer: *?*Buffer) (Allocator.Error || checked.Error)!*Buffer {
    _ = Offset;
    const buf = try ensureOffsetBuffer(allocator, buffer);
    buffer.* = null;
    buf.freeze();
    return buf;
}

fn ensureOffsetBuffer(allocator: Allocator, buffer: *?*Buffer) (Allocator.Error || checked.Error)!*Buffer {
    if (buffer.* == null) buffer.* = try Buffer.allocate(allocator, 0);
    return buffer.*.?;
}

test "ListBuilder builds numeric child lists" {
    const allocator = std.testing.allocator;
    const builder = @import("../builder.zig");
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
    try std.testing.expectEqual(@as(usize, 4), arr.view.base.len);
    try std.testing.expectEqual(@as(usize, 1), arr.view.nullCount());
    try std.testing.expectEqual(@as(usize, 0), arr.valueRange(0).offset);
    try std.testing.expectEqual(@as(usize, 2), arr.valueRange(0).len);
    try std.testing.expectEqual(@as(usize, 0), arr.valueRange(1).len);
    try std.testing.expect(arr.view.isNull(3));

    const child = try array.NumericArray(i32).fromData(arr.childBaseData());
    try std.testing.expectEqual(@as(usize, 3), child.view.base.len);
    try std.testing.expectEqual(@as(i32, 3), child.value(2));
}

test "ListBuilder rejects pending child values for null slots" {
    const allocator = std.testing.allocator;
    const builder = @import("../builder.zig");
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
    const builder = @import("../builder.zig");
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

test "ListViewBuilder builds non monotonic child views" {
    const allocator = std.testing.allocator;
    const builder = @import("../builder.zig");
    var b = ListViewBuilder(builder.NumericBuilder(i32)).init(allocator);
    defer b.deinit();

    try b.values().appendSlice(&.{ 10, 20, 30, 40 });
    try b.appendView(2, 2);
    try b.appendView(0, 3);
    try b.appendEmptyValue();
    try b.appendNull();

    const data = try b.finish();
    defer data.deinit();
    try data.validate();

    const arr = try array.ListViewArray.fromData(data);
    try std.testing.expectEqual(@as(usize, 4), arr.view.base.len);
    try std.testing.expectEqual(@as(usize, 1), arr.view.nullCount());
    try std.testing.expectEqual(@as(usize, 2), arr.valueRange(0).offset);
    try std.testing.expectEqual(@as(usize, 2), arr.valueRange(0).len);
    try std.testing.expectEqual(@as(usize, 0), arr.valueRange(1).offset);
    try std.testing.expectEqual(@as(usize, 3), arr.valueRange(1).len);
    try std.testing.expectEqual(@as(usize, 4), arr.valueRange(2).offset);
    try std.testing.expectEqual(@as(usize, 0), arr.valueRange(2).len);
    try std.testing.expect(arr.view.isNull(3));

    const child = try array.NumericArray(i32).fromData(arr.childBaseData());
    try std.testing.expectEqual(@as(i32, 40), child.value(3));
}

test "LargeListViewBuilder uses large offsets and field options" {
    const allocator = std.testing.allocator;
    const builder = @import("../builder.zig");
    var b = try LargeListViewBuilder(builder.Utf8Builder).initField(allocator, .{ .name = "words", .nullable = false });
    defer b.deinit();

    try b.values().append("alpha");
    try b.values().append("beta");
    try b.appendView(1, 1);

    const data = try b.finish();
    defer data.deinit();
    try data.validate();

    const arr = try array.LargeListViewArray.fromData(data);
    try std.testing.expectEqual(@as(usize, 1), arr.valueRange(0).offset);
    try std.testing.expectEqual(@as(usize, 1), arr.valueRange(0).len);
    try std.testing.expectEqualStrings("words", data.type.large_list_view.child.name);
    try std.testing.expect(!data.type.large_list_view.child.nullable);
}

test "ListViewBuilder rejects out of bounds views" {
    const allocator = std.testing.allocator;
    const builder = @import("../builder.zig");
    var b = ListViewBuilder(builder.NumericBuilder(i32)).init(allocator);
    defer b.deinit();

    try b.values().append(1);
    try std.testing.expectError(error.ViewOutOfBounds, b.appendView(0, 2));
}

test "ListBuilder deinit supports child builders without reset" {
    const allocator = std.testing.allocator;
    const ChildWithoutReset = struct {
        const Self = @This();
        pub const Error = Allocator.Error || checked.Error;

        allocator: Allocator,

        pub fn init(child_allocator: Allocator) Self {
            return .{ .allocator = child_allocator };
        }

        pub fn deinit(self: *Self) void {
            _ = self;
        }

        pub fn length(self: Self) usize {
            _ = self;
            return 0;
        }

        pub fn finish(self: *Self) Error!*ArrayData {
            const values = try Buffer.allocate(self.allocator, 0);
            errdefer values.deinit();
            values.freeze();
            return ArrayData.initOwned(self.allocator, .int32, 0, 0, 0, &.{ null, values }, &.{}, null);
        }
    };

    var b = ListBuilder(ChildWithoutReset).init(allocator);
    defer b.deinit();

    try b.appendEmptyValue();
    const data = try b.finish();
    defer data.deinit();

    const arr = try array.ListArray.fromData(data);
    try std.testing.expectEqual(@as(usize, 1), arr.view.base.len);
    try std.testing.expectEqual(@as(usize, 0), arr.view.nullCount());
}

test "ListBuilder reset preserves field options" {
    const allocator = std.testing.allocator;
    const builder = @import("../builder.zig");
    var b = try LargeListBuilder(builder.Utf8Builder).initField(allocator, .{ .name = "words", .nullable = false });
    defer b.deinit();

    try b.appendEmptyValue();
    b.reset();
    try std.testing.expectEqual(@as(usize, 0), b.length());

    try b.appendEmptyValue();
    const data = try b.finish();
    defer data.deinit();

    try std.testing.expectEqualStrings("words", data.type.large_list.child.name);
    try std.testing.expect(!data.type.large_list.child.nullable);
}

test "FixedSizeListBuilder builds numeric child lists" {
    const allocator = std.testing.allocator;
    const builder = @import("../builder.zig");
    var b = FixedSizeListBuilder(builder.NumericBuilder(i32)).init(allocator, 2);
    defer b.deinit();

    try b.values().appendSlice(&.{ 1, 2 });
    try b.append();
    try b.appendNull();
    try b.values().appendSlice(&.{ 3, 4 });
    try b.append();

    const data = try b.finish();
    defer data.deinit();
    try data.validate();

    const arr = try array.FixedSizeListArray.fromData(data);
    try std.testing.expectEqual(@as(usize, 3), arr.view.base.len);
    try std.testing.expectEqual(@as(usize, 2), arr.listSize());
    try std.testing.expectEqual(@as(usize, 1), arr.view.nullCount());
    try std.testing.expectEqual(@as(usize, 0), arr.valueRange(0).offset);
    try std.testing.expectEqual(@as(usize, 2), arr.valueRange(1).offset);
    try std.testing.expectEqual(@as(usize, 4), arr.valueRange(2).offset);
    try std.testing.expect(arr.view.isNull(1));

    const child = try array.NumericArray(i32).fromData(arr.childBaseData());
    try std.testing.expectEqual(@as(usize, 6), child.view.base.len);
    try std.testing.expectEqual(@as(i32, 1), child.value(0));
    try std.testing.expectEqual(@as(i32, 2), child.value(1));
    try std.testing.expectEqual(@as(i32, 0), child.value(2));
    try std.testing.expectEqual(@as(i32, 0), child.value(3));
    try std.testing.expectEqual(@as(i32, 3), child.value(4));
    try std.testing.expectEqual(@as(i32, 4), child.value(5));
}

test "FixedSizeListBuilder rejects partial child values" {
    const allocator = std.testing.allocator;
    const builder = @import("../builder.zig");
    var b = FixedSizeListBuilder(builder.NumericBuilder(i32)).init(allocator, 2);
    defer b.deinit();

    try b.values().append(1);
    try std.testing.expectError(error.UnclosedListValues, b.append());
    try std.testing.expectError(error.UnclosedListValues, b.appendNull());

    try b.values().append(2);
    try b.append();
    const data = try b.finish();
    defer data.deinit();
    try data.validate();
}

test "FixedSizeListBuilder reset and field options" {
    const allocator = std.testing.allocator;
    const builder = @import("../builder.zig");
    var b = try FixedSizeListBuilder(builder.NumericBuilder(i32)).initField(allocator, 3, .{ .name = "coords", .nullable = false });
    defer b.deinit();

    try b.appendEmptyValue();
    b.reset();
    try std.testing.expectEqual(@as(usize, 0), b.length());

    try b.appendNull();
    const data = try b.finish();
    defer data.deinit();
    try data.validate();

    try std.testing.expectEqualStrings("coords", data.type.fixed_size_list.child.name);
    try std.testing.expect(!data.type.fixed_size_list.child.nullable);
    const child = try array.NumericArray(i32).fromData(data.children[0]);
    try std.testing.expectEqual(@as(usize, 3), child.view.base.len);
    try std.testing.expectEqual(@as(usize, 0), child.view.nullCount());
}
