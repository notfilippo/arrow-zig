// Copyright 2026 Filippo Rossi
// SPDX-License-Identifier: Apache-2.0

//! Map builders.

const std = @import("std");
const Allocator = std.mem.Allocator;
const checked = @import("../checked.zig");
const datatype = @import("../datatype.zig");
const offset_data = @import("../offsets.zig");
const array = @import("../array.zig");
const ArrayData = array.ArrayData;
const common = @import("common.zig");

pub const MapOptions = struct {
    entries_name: []const u8 = "entries",
    key_name: []const u8 = "key",
    value_name: []const u8 = "value",
    value_nullable: bool = true,
    keys_sorted: bool = false,
};

pub fn MapBuilderError(comptime KeyBuilder: type, comptime ValueBuilder: type) type {
    return Allocator.Error || checked.Error || error{ UnclosedMapEntries, MapKeyNulls, MapValueNulls } || KeyBuilder.Error || ValueBuilder.Error;
}

pub fn MapBuilder(comptime KeyBuilder: type, comptime ValueBuilder: type) type {
    return struct {
        const Self = @This();
        pub const Array = array.MapArray;
        pub const Key = KeyBuilder;
        pub const Value = ValueBuilder;
        pub const Error = MapBuilderError(KeyBuilder, ValueBuilder);

        allocator: Allocator,
        key_builder: KeyBuilder,
        value_builder: ValueBuilder,
        offsets: offset_data.Builder(i32),
        slots: common.Slots,
        last_entry_len: usize,
        entries_name: []const u8,
        key_name: []const u8,
        value_name: []const u8,
        owned_entries_name: ?[]u8,
        owned_key_name: ?[]u8,
        owned_value_name: ?[]u8,
        value_nullable: bool,
        keys_sorted: bool,

        pub fn init(allocator: Allocator) Self {
            return .{
                .allocator = allocator,
                .key_builder = KeyBuilder.init(allocator),
                .value_builder = ValueBuilder.init(allocator),
                .offsets = offset_data.Builder(i32).init(),
                .slots = common.Slots.init(),
                .last_entry_len = 0,
                .entries_name = "entries",
                .key_name = "key",
                .value_name = "value",
                .owned_entries_name = null,
                .owned_key_name = null,
                .owned_value_name = null,
                .value_nullable = true,
                .keys_sorted = false,
            };
        }

        pub fn initOptions(allocator: Allocator, options: MapOptions) Error!Self {
            var self = init(allocator);
            errdefer self.deinit();
            self.owned_entries_name = try allocator.dupe(u8, options.entries_name);
            self.entries_name = self.owned_entries_name.?;
            self.owned_key_name = try allocator.dupe(u8, options.key_name);
            self.key_name = self.owned_key_name.?;
            self.owned_value_name = try allocator.dupe(u8, options.value_name);
            self.value_name = self.owned_value_name.?;
            self.value_nullable = options.value_nullable;
            self.keys_sorted = options.keys_sorted;
            return self;
        }

        pub fn deinit(self: *Self) void {
            self.key_builder.deinit();
            self.value_builder.deinit();
            self.clearMapState(true);
        }

        pub fn reset(self: *Self) void {
            if (comptime !@hasDecl(KeyBuilder, "reset")) {
                @compileError("MapBuilder.reset requires KeyBuilder.reset");
            }
            if (comptime !@hasDecl(ValueBuilder, "reset")) {
                @compileError("MapBuilder.reset requires ValueBuilder.reset");
            }
            self.key_builder.reset();
            self.value_builder.reset();
            self.clearMapState(false);
        }

        pub fn keys(self: *Self) *KeyBuilder {
            return &self.key_builder;
        }

        pub fn values(self: *Self) *ValueBuilder {
            return &self.value_builder;
        }

        pub fn reserve(self: *Self, additional: usize) Error!void {
            if (additional == 0) return;
            const new_len = try checked.add(self.slots.len, additional);
            const capped_len = @max(new_len, common.kMinBuilderCapacity);
            try self.offsets.reserveSlots(self.allocator, try checked.add(capped_len, 1));
            try self.slots.reserve(self.allocator, additional);
        }

        pub fn append(self: *Self) Error!void {
            const entry_len = try self.entryLength();
            if (entry_len < self.last_entry_len) return error.UnclosedMapEntries;
            try self.reserve(1);
            try self.appendOffset(entry_len, true);
        }

        pub fn appendEmpty(self: *Self) Error!void {
            try self.appendEmptyValue();
        }

        pub fn appendNull(self: *Self) Error!void {
            try self.appendNulls(1);
        }

        pub fn appendNulls(self: *Self, n: usize) Error!void {
            if (n == 0) return;
            try self.ensureNoPending();
            try self.reserve(n);
            try self.offsets.appendRepeat(self.allocator, n, self.last_entry_len);
            try self.slots.unsafeAppendN(false, n);
        }

        pub fn appendEmptyValue(self: *Self) Error!void {
            try self.ensureNoPending();
            try self.reserve(1);
            try self.appendOffset(self.last_entry_len, true);
        }

        pub fn appendEmptyValues(self: *Self, n: usize) Error!void {
            if (n == 0) return;
            try self.ensureNoPending();
            try self.reserve(n);
            try self.offsets.appendRepeat(self.allocator, n, self.last_entry_len);
            try self.slots.unsafeAppendN(true, n);
        }

        pub fn length(self: Self) usize {
            return self.slots.length();
        }

        pub fn finish(self: *Self) Error!*ArrayData {
            const entry_len = try self.entryLength();
            if (entry_len != self.last_entry_len) return error.UnclosedMapEntries;

            var consumed = false;
            errdefer if (consumed) {
                self.slots.len = 0;
                self.last_entry_len = 0;
            };

            const offsets_buf = try self.offsets.finish(self.allocator);
            consumed = true;
            errdefer offsets_buf.deinit();

            const key_data = try self.key_builder.finish();
            var child_data_owned = true;
            errdefer if (child_data_owned) key_data.deinit();
            if (key_data.nullCount() != 0) return error.MapKeyNulls;

            const value_data = try self.value_builder.finish();
            errdefer if (child_data_owned) value_data.deinit();
            if (!self.value_nullable and value_data.nullCount() != 0) return error.MapValueNulls;

            const key_field = try datatype.Field.create(self.allocator, self.key_name, &key_data.type, false, &.{});
            var key_field_owned = true;
            errdefer if (key_field_owned) key_field.deinit();
            const value_field = try datatype.Field.create(self.allocator, self.value_name, &value_data.type, self.value_nullable, &.{});
            var value_field_owned = true;
            errdefer if (value_field_owned) value_field.deinit();
            const entry_fields = [_]*const datatype.Field{ key_field, value_field };
            const entry_ty = datatype.DataType{ .struct_ = .{ .fields = &entry_fields } };

            const entries_data = try ArrayData.initOwned(self.allocator, entry_ty, entry_len, 0, 0, &.{null}, &.{ key_data, value_data }, null);
            child_data_owned = false;
            errdefer entries_data.deinit();
            key_field.deinit();
            key_field_owned = false;
            value_field.deinit();
            value_field_owned = false;

            const slots = try self.slots.finish(self.allocator);
            errdefer if (slots.validity) |buf| buf.deinit();

            const entries_field = try datatype.Field.create(self.allocator, self.entries_name, &entries_data.type, false, &.{});
            errdefer entries_field.deinit();
            const ty = datatype.DataType{ .map = .{
                .entries = entries_field,
                .keys_sorted = self.keys_sorted,
            } };
            const data = try ArrayData.initOwned(self.allocator, ty, slots.len, 0, slots.null_count, &.{ slots.validity, offsets_buf }, &.{entries_data}, null);
            entries_field.deinit();
            self.last_entry_len = 0;
            return data;
        }

        fn appendOffset(self: *Self, entry_len: usize, valid: bool) Error!void {
            try self.offsets.append(self.allocator, entry_len);
            self.slots.unsafeAppend(valid);
            self.last_entry_len = entry_len;
        }

        fn entryLength(self: Self) Error!usize {
            const key_len = self.key_builder.length();
            if (key_len != self.value_builder.length()) return error.UnclosedMapEntries;
            return key_len;
        }

        fn ensureNoPending(self: *Self) Error!void {
            const entry_len = try self.entryLength();
            if (entry_len != self.last_entry_len) return error.UnclosedMapEntries;
        }

        fn clearMapState(self: *Self, comptime clear_field_options: bool) void {
            self.offsets.deinit();
            self.slots.deinit();
            if (clear_field_options) {
                if (self.owned_entries_name) |name| self.allocator.free(name);
                if (self.owned_key_name) |name| self.allocator.free(name);
                if (self.owned_value_name) |name| self.allocator.free(name);
                self.entries_name = "entries";
                self.key_name = "key";
                self.value_name = "value";
                self.owned_entries_name = null;
                self.owned_key_name = null;
                self.owned_value_name = null;
                self.value_nullable = true;
                self.keys_sorted = false;
            }
            self.last_entry_len = 0;
        }
    };
}

test "MapBuilder builds maps" {
    const allocator = std.testing.allocator;
    const builder = @import("../builder.zig");
    var b = try MapBuilder(builder.NumericBuilder(i32), builder.Utf8Builder).initOptions(allocator, .{ .keys_sorted = true });
    defer b.deinit();

    try b.keys().append(1);
    try b.values().append("one");
    try b.keys().append(2);
    try b.values().append("two");
    try b.append();
    try b.appendEmpty();
    try b.appendNull();
    try b.keys().append(3);
    try b.values().append("three");
    try b.append();

    const data = try b.finish();
    defer data.deinit();
    try data.validate();

    const arr = try array.MapArray.fromData(data);
    try std.testing.expect(arr.keysSorted());
    try std.testing.expectEqual(@as(usize, 4), arr.view.base.len);
    try std.testing.expectEqual(@as(usize, 1), arr.view.nullCount());
    try std.testing.expectEqual(@as(usize, 2), arr.entryRange(0).len);
    try std.testing.expectEqual(@as(usize, 0), arr.entryRange(1).len);
    try std.testing.expect(arr.view.isNull(2));
    try std.testing.expectEqualStrings("entries", data.type.map.entries.name);
    try std.testing.expect(!data.type.map.entries.nullable);

    const keys = try array.NumericArray(i32).fromData(arr.keysBaseData());
    try std.testing.expectEqual(@as(usize, 3), keys.view.base.len);
    try std.testing.expectEqual(@as(i32, 3), keys.value(2));

    const values = try array.Utf8Array.fromData(arr.valuesBaseData());
    try std.testing.expectEqualStrings("three", values.value(2));
}

test "MapBuilder rejects unfinished entries" {
    const allocator = std.testing.allocator;
    const builder = @import("../builder.zig");
    var b = MapBuilder(builder.NumericBuilder(i32), builder.Utf8Builder).init(allocator);
    defer b.deinit();

    try b.keys().append(1);
    try std.testing.expectError(error.UnclosedMapEntries, b.append());
    try b.values().append("one");
    try b.append();
    const data = try b.finish();
    defer data.deinit();
    try data.validate();
}

test "MapBuilder rejects null keys and nonnullable values" {
    const allocator = std.testing.allocator;
    const builder = @import("../builder.zig");
    var null_keys = MapBuilder(builder.NumericBuilder(i32), builder.Utf8Builder).init(allocator);
    defer null_keys.deinit();

    try null_keys.keys().appendNull();
    try null_keys.values().append("one");
    try null_keys.append();
    try std.testing.expectError(error.MapKeyNulls, null_keys.finish());

    var null_values = try MapBuilder(builder.NumericBuilder(i32), builder.Utf8Builder).initOptions(allocator, .{ .value_nullable = false });
    defer null_values.deinit();

    try null_values.keys().append(1);
    try null_values.values().appendNull();
    try null_values.append();
    try std.testing.expectError(error.MapValueNulls, null_values.finish());
}

test "MapBuilder reset preserves options" {
    const allocator = std.testing.allocator;
    const builder = @import("../builder.zig");
    var b = try MapBuilder(builder.NumericBuilder(i32), builder.NumericBuilder(i32)).initOptions(allocator, .{
        .entries_name = "pairs",
        .key_name = "id",
        .value_name = "score",
        .value_nullable = false,
        .keys_sorted = true,
    });
    defer b.deinit();

    try b.appendEmptyValue();
    b.reset();
    try b.appendEmptyValue();

    const data = try b.finish();
    defer data.deinit();
    try data.validate();
    try std.testing.expectEqualStrings("pairs", data.type.map.entries.name);
    try std.testing.expect(data.type.map.keys_sorted);
    try std.testing.expectEqualStrings("id", data.type.map.entries.type.struct_.fields[0].name);
    try std.testing.expectEqualStrings("score", data.type.map.entries.type.struct_.fields[1].name);
    try std.testing.expect(!data.type.map.entries.type.struct_.fields[1].nullable);
}
