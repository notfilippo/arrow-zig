// Copyright 2026 Filippo Rossi
// SPDX-License-Identifier: Apache-2.0

//! Struct builders.

const std = @import("std");
const Allocator = std.mem.Allocator;
const checked = @import("../checked.zig");
const datatype = @import("../datatype.zig");
const array = @import("../array.zig");
const ArrayData = array.ArrayData;
const common = @import("common.zig");

pub const FieldOptions = struct {
    name: []const u8,
    nullable: bool = true,
};

pub fn StructBuilderError(comptime ChildBuilders: type) type {
    return Allocator.Error || checked.Error || error{UnclosedStructValues} || childErrorSet(ChildBuilders);
}

pub fn StructBuilder(comptime ChildBuilders: type) type {
    ensureStruct(ChildBuilders);
    const child_fields = std.meta.fields(ChildBuilders);
    const field_count = child_fields.len;

    return struct {
        const Self = @This();
        pub const Array = array.StructArray;
        pub const Children = ChildBuilders;
        pub const Error = StructBuilderError(ChildBuilders);

        allocator: Allocator,
        children: ChildBuilders,
        slots: common.Slots,
        field_names: [field_count][]const u8,
        owned_field_names: [field_count]?[]u8,
        field_nullable: [field_count]bool,

        pub fn init(allocator: Allocator) Self {
            return .{
                .allocator = allocator,
                .children = initChildBuilders(ChildBuilders, allocator),
                .slots = common.Slots.init(),
                .field_names = defaultStructFieldNames(ChildBuilders),
                .owned_field_names = [_]?[]u8{null} ** field_count,
                .field_nullable = [_]bool{true} ** field_count,
            };
        }

        pub fn initFields(allocator: Allocator, options: [field_count]FieldOptions) Error!Self {
            var self = init(allocator);
            errdefer self.deinit();
            inline for (0..field_count) |i| {
                const name = try allocator.dupe(u8, options[i].name);
                self.field_names[i] = name;
                self.owned_field_names[i] = name;
                self.field_nullable[i] = options[i].nullable;
            }
            return self;
        }

        pub fn deinit(self: *Self) void {
            inline for (child_fields) |field_info| {
                @field(self.children, field_info.name).deinit();
            }
            self.clearStructState(true);
        }

        pub fn reset(self: *Self) void {
            inline for (child_fields) |field_info| {
                if (comptime !@hasDecl(field_info.type, "reset")) {
                    @compileError("StructBuilder.reset requires every child builder to expose reset");
                }
                @field(self.children, field_info.name).reset();
            }
            self.clearStructState(false);
        }

        pub fn values(self: *Self) *ChildBuilders {
            return &self.children;
        }

        pub fn field(self: *Self, comptime name: []const u8) *fieldBuilderType(name) {
            return &@field(self.children, name);
        }

        pub fn reserve(self: *Self, additional: usize) Error!void {
            if (additional == 0) return;
            try self.slots.reserve(self.allocator, @max(additional, common.kMinBuilderCapacity));
        }

        pub fn append(self: *Self) Error!void {
            try self.expectChildLengths(try checked.add(self.slots.len, 1));
            try self.reserve(1);
            try self.slots.unsafeAppendN(true, 1);
        }

        pub fn appendNull(self: *Self) Error!void {
            try self.appendNulls(1);
        }

        pub fn appendNulls(self: *Self, n: usize) Error!void {
            if (n == 0) return;
            try self.expectChildLengths(self.slots.len);
            try self.reserve(n);
            try self.appendChildEmptyValues(n);
            try self.slots.unsafeAppendN(false, n);
        }

        pub fn appendEmptyValue(self: *Self) Error!void {
            try self.appendEmptyValues(1);
        }

        pub fn appendEmptyValues(self: *Self, n: usize) Error!void {
            if (n == 0) return;
            try self.expectChildLengths(self.slots.len);
            try self.reserve(n);
            try self.appendChildEmptyValues(n);
            try self.slots.unsafeAppendN(true, n);
        }

        pub fn length(self: Self) usize {
            return self.slots.length();
        }

        pub fn finish(self: *Self) Error!*ArrayData {
            try self.expectChildLengths(self.slots.len);

            var consumed = false;
            errdefer if (consumed) {
                self.slots.len = 0;
            };

            var child_data: [field_count]*ArrayData = undefined;
            var finished_children: usize = 0;
            errdefer {
                for (child_data[0..finished_children]) |child| child.deinit();
            }

            inline for (child_fields, 0..) |field_info, i| {
                child_data[i] = try @field(self.children, field_info.name).finish();
                finished_children += 1;
                consumed = true;
            }

            var field_meta: [field_count]*const datatype.Field = undefined;
            var created_fields: usize = 0;
            errdefer {
                for (field_meta[0..created_fields]) |field_ptr| field_ptr.deinit();
            }

            inline for (child_fields, 0..) |_, i| {
                field_meta[i] = try datatype.Field.create(
                    self.allocator,
                    self.field_names[i],
                    &child_data[i].type,
                    self.field_nullable[i],
                    &.{},
                );
                created_fields += 1;
            }

            const slots = try self.slots.finish(self.allocator);
            errdefer if (slots.validity) |buf| buf.deinit();

            const ty = datatype.DataType{ .struct_ = .{ .fields = &field_meta } };
            const data = try ArrayData.initOwned(self.allocator, ty, slots.len, 0, slots.null_count, &.{slots.validity}, child_data[0..], null);
            for (field_meta[0..created_fields]) |field_ptr| field_ptr.deinit();
            return data;
        }

        fn fieldBuilderType(comptime name: []const u8) type {
            inline for (child_fields) |field_info| {
                if (std.mem.eql(u8, name, field_info.name)) return field_info.type;
            }
            @compileError("unknown struct builder field: " ++ name);
        }

        fn expectChildLengths(self: *Self, expected: usize) Error!void {
            inline for (child_fields) |field_info| {
                if (@field(self.children, field_info.name).length() != expected) return error.UnclosedStructValues;
            }
        }

        fn appendChildEmptyValues(self: *Self, n: usize) Error!void {
            inline for (child_fields) |field_info| {
                if (comptime !@hasDecl(field_info.type, "appendEmptyValues")) {
                    @compileError("StructBuilder null and empty appends require every child builder to expose appendEmptyValues");
                }
                try @field(self.children, field_info.name).appendEmptyValues(n);
            }
        }

        fn clearStructState(self: *Self, comptime clear_field_options: bool) void {
            self.slots.deinit();
            if (clear_field_options) {
                inline for (0..field_count) |i| {
                    if (self.owned_field_names[i]) |name| self.allocator.free(name);
                    self.field_names[i] = child_fields[i].name;
                    self.owned_field_names[i] = null;
                    self.field_nullable[i] = true;
                }
            }
        }
    };
}

fn initChildBuilders(comptime ChildBuilders: type, allocator: Allocator) ChildBuilders {
    var children: ChildBuilders = undefined;
    inline for (std.meta.fields(ChildBuilders)) |field| {
        @field(children, field.name) = field.type.init(allocator);
    }
    return children;
}

fn defaultStructFieldNames(comptime ChildBuilders: type) [std.meta.fields(ChildBuilders).len][]const u8 {
    const child_fields = std.meta.fields(ChildBuilders);
    var names: [child_fields.len][]const u8 = undefined;
    inline for (child_fields, 0..) |field, i| {
        names[i] = field.name;
    }
    return names;
}

fn childErrorSet(comptime ChildBuilders: type) type {
    ensureStruct(ChildBuilders);
    var errors: type = error{};
    inline for (std.meta.fields(ChildBuilders)) |field| {
        errors = errors || field.type.Error;
    }
    return errors;
}

fn ensureStruct(comptime T: type) void {
    switch (@typeInfo(T)) {
        .@"struct" => {},
        else => @compileError("StructBuilder requires a struct of child builder fields"),
    }
}

test "StructBuilder builds rows from child builders" {
    const allocator = std.testing.allocator;
    const builder = @import("../builder.zig");

    const Children = struct {
        number: builder.NumericBuilder(i32),
        flag: builder.BooleanBuilder,
    };

    var b = StructBuilder(Children).init(allocator);
    defer b.deinit();

    try b.values().number.append(10);
    try b.values().flag.append(true);
    try b.append();
    try b.appendNull();
    try b.field("number").append(30);
    try b.field("flag").append(false);
    try b.append();

    const data = try b.finish();
    defer data.deinit();
    try data.validate();

    const arr = try array.StructArray.fromData(data);
    try std.testing.expectEqual(@as(usize, 3), arr.view.base.len);
    try std.testing.expectEqual(@as(usize, 1), arr.view.nullCount());
    try std.testing.expectEqualStrings("number", arr.fieldName(0).?);
    try std.testing.expectEqualStrings("flag", arr.fieldName(1).?);
    try std.testing.expect(arr.view.isNull(1));

    const numbers = try array.NumericArray(i32).fromData(arr.fieldBaseNamed("number").?);
    try std.testing.expectEqual(@as(usize, 3), numbers.view.base.len);
    try std.testing.expectEqual(@as(i32, 10), numbers.value(0));
    try std.testing.expectEqual(@as(i32, 0), numbers.value(1));
    try std.testing.expectEqual(@as(i32, 30), numbers.value(2));

    const flags = try array.BooleanArray.fromData(arr.fieldBaseNamed("flag").?);
    try std.testing.expect(flags.value(0));
    try std.testing.expect(!flags.value(1));
    try std.testing.expect(!flags.value(2));
}

test "StructBuilder rejects partial child rows" {
    const allocator = std.testing.allocator;
    const builder = @import("../builder.zig");

    const Children = struct {
        number: builder.NumericBuilder(i32),
        flag: builder.BooleanBuilder,
    };

    var b = StructBuilder(Children).init(allocator);
    defer b.deinit();

    try b.values().number.append(10);
    try std.testing.expectError(error.UnclosedStructValues, b.append());
    try std.testing.expectError(error.UnclosedStructValues, b.appendNull());

    try b.values().flag.append(true);
    try b.append();
    const data = try b.finish();
    defer data.deinit();
    try data.validate();
}

test "StructBuilder reset and field options" {
    const allocator = std.testing.allocator;
    const builder = @import("../builder.zig");

    const Children = struct {
        number: builder.NumericBuilder(i32),
        flag: builder.BooleanBuilder,
    };

    var b = try StructBuilder(Children).initFields(allocator, .{
        .{ .name = "id", .nullable = false },
        .{ .name = "enabled", .nullable = false },
    });
    defer b.deinit();

    try b.appendEmptyValue();
    b.reset();
    try std.testing.expectEqual(@as(usize, 0), b.length());

    try b.appendNull();
    const data = try b.finish();
    defer data.deinit();
    try data.validate();

    const arr = try array.StructArray.fromData(data);
    try std.testing.expectEqual(@as(usize, 1), arr.view.base.len);
    try std.testing.expect(arr.view.isNull(0));
    try std.testing.expectEqualStrings("id", arr.fieldName(0).?);
    try std.testing.expectEqualStrings("enabled", arr.fieldName(1).?);
    try std.testing.expect(!data.type.struct_.fields[0].nullable);
    try std.testing.expect(!data.type.struct_.fields[1].nullable);

    const numbers = try array.NumericArray(i32).fromData(arr.fieldBaseNamed("id").?);
    const flags = try array.BooleanArray.fromData(arr.fieldBaseNamed("enabled").?);
    try std.testing.expectEqual(@as(usize, 0), numbers.view.nullCount());
    try std.testing.expectEqual(@as(usize, 0), flags.view.nullCount());
}
