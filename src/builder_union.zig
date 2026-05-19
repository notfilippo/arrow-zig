// Copyright 2026 Filippo Rossi
// SPDX-License-Identifier: Apache-2.0

//! Sparse and dense union builders.

const std = @import("std");
const Allocator = std.mem.Allocator;
const checked = @import("checked.zig");
const datatype = @import("datatype.zig");
const offset_data = @import("offsets.zig");
const array = @import("array.zig");
const ArrayData = array.ArrayData;
const Buffer = @import("buffer.zig").Buffer;
const builder_base = @import("builder_base.zig");

pub const FieldOptions = struct {
    name: []const u8,
    nullable: bool = true,
    type_id: i8,
};

pub fn UnionBuilderError(comptime ChildBuilders: type) type {
    return Allocator.Error || checked.Error || datatype.ValidationError || error{UnclosedUnionValues} || childErrorSet(ChildBuilders);
}

const UnionKind = enum {
    sparse,
    dense,
};

pub fn SparseUnionBuilder(comptime ChildBuilders: type) type {
    return UnionBuilder(.sparse, ChildBuilders);
}

pub fn DenseUnionBuilder(comptime ChildBuilders: type) type {
    return UnionBuilder(.dense, ChildBuilders);
}

fn UnionBuilder(comptime kind: UnionKind, comptime ChildBuilders: type) type {
    ensureStruct(ChildBuilders);
    const child_fields = std.meta.fields(ChildBuilders);
    const field_count = child_fields.len;
    if (field_count > 128) @compileError("union builders support at most 128 child fields");

    return struct {
        const Self = @This();
        pub const Array = switch (kind) {
            .sparse => array.SparseUnionArray,
            .dense => array.DenseUnionArray,
        };
        pub const Children = ChildBuilders;
        pub const Error = UnionBuilderError(ChildBuilders);

        allocator: Allocator,
        children: ChildBuilders,
        type_ids: IntBuffer(i8),
        offsets: IntBuffer(i32),
        len: usize,
        child_lengths: [field_count]usize,
        field_names: [field_count][]const u8,
        owned_field_names: [field_count]?[]u8,
        field_nullable: [field_count]bool,
        field_type_ids: [field_count]i8,

        pub fn init(allocator: Allocator) Self {
            return .{
                .allocator = allocator,
                .children = initChildBuilders(ChildBuilders, allocator),
                .type_ids = IntBuffer(i8).init(),
                .offsets = IntBuffer(i32).init(),
                .len = 0,
                .child_lengths = [_]usize{0} ** field_count,
                .field_names = defaultFieldNames(ChildBuilders),
                .owned_field_names = [_]?[]u8{null} ** field_count,
                .field_nullable = [_]bool{true} ** field_count,
                .field_type_ids = defaultTypeIds(field_count),
            };
        }

        pub fn initTypeIds(allocator: Allocator, type_ids: [field_count]i8) Error!Self {
            try validateTypeIds(&type_ids);
            var self = init(allocator);
            self.field_type_ids = type_ids;
            return self;
        }

        pub fn initFields(allocator: Allocator, options: [field_count]FieldOptions) Error!Self {
            var self = init(allocator);
            errdefer self.deinit();

            var ids: [field_count]i8 = undefined;
            inline for (0..field_count) |i| ids[i] = options[i].type_id;
            try validateTypeIds(&ids);
            self.field_type_ids = ids;

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
            self.clearUnionState(true);
        }

        pub fn reset(self: *Self) void {
            inline for (child_fields) |field_info| {
                if (comptime !@hasDecl(field_info.type, "reset")) {
                    @compileError("UnionBuilder.reset requires every child builder to expose reset");
                }
                @field(self.children, field_info.name).reset();
            }
            self.clearUnionState(false);
        }

        pub fn values(self: *Self) *ChildBuilders {
            return &self.children;
        }

        pub fn field(self: *Self, comptime name: []const u8) *fieldBuilderType(name) {
            return &@field(self.children, name);
        }

        pub fn reserve(self: *Self, additional: usize) Error!void {
            if (additional == 0) return;
            const capped = @max(additional, builder_base.kMinBuilderCapacity);
            try self.type_ids.reserve(self.allocator, capped);
            if (comptime kind == .dense) try self.offsets.reserve(self.allocator, capped);
        }

        pub fn append(self: *Self, comptime name: []const u8) Error!void {
            const index = comptime Self.fieldIndex(name);
            if (comptime kind == .sparse) {
                try self.appendSparse(index, false);
            } else {
                try self.appendDense(index, false);
            }
        }

        pub fn appendEmptyValue(self: *Self, comptime name: []const u8) Error!void {
            const index = comptime Self.fieldIndex(name);
            if (comptime kind == .sparse) {
                try self.appendSparse(index, true);
            } else {
                try self.appendDense(index, true);
            }
        }

        pub fn length(self: Self) usize {
            return self.len;
        }

        pub fn finish(self: *Self) Error!*ArrayData {
            if (comptime kind == .sparse) {
                inline for (0..field_count) |i| {
                    if (self.child_lengths[i] != self.len) return error.UnclosedUnionValues;
                }
            } else {
                inline for (child_fields, 0..) |field_info, i| {
                    if (@field(self.children, field_info.name).length() != self.child_lengths[i]) return error.UnclosedUnionValues;
                }
            }

            const n = self.len;
            var consumed = false;
            errdefer if (consumed) {
                self.len = 0;
                self.child_lengths = [_]usize{0} ** field_count;
            };

            const type_ids_buf = try self.type_ids.finish(self.allocator);
            consumed = true;
            errdefer type_ids_buf.deinit();

            const offsets_buf: ?*Buffer = if (comptime kind == .dense) blk: {
                const buf = try self.offsets.finish(self.allocator);
                break :blk buf;
            } else null;
            errdefer if (offsets_buf) |buf| buf.deinit();

            var child_data: [field_count]*ArrayData = undefined;
            var finished_children: usize = 0;
            errdefer {
                for (child_data[0..finished_children]) |child| child.deinit();
            }
            inline for (child_fields, 0..) |field_info, i| {
                child_data[i] = try @field(self.children, field_info.name).finish();
                finished_children += 1;
            }

            var field_meta: [field_count]*const datatype.Field = undefined;
            var created_fields: usize = 0;
            errdefer {
                for (field_meta[0..created_fields]) |field_ptr| field_ptr.deinit();
            }
            inline for (0..field_count) |i| {
                field_meta[i] = try datatype.Field.create(
                    self.allocator,
                    self.field_names[i],
                    &child_data[i].type,
                    self.field_nullable[i],
                    &.{},
                );
                created_fields += 1;
            }

            const ty: datatype.DataType = switch (kind) {
                .sparse => .{ .sparse_union = .{ .fields = &field_meta, .type_ids = &self.field_type_ids } },
                .dense => .{ .dense_union = .{ .fields = &field_meta, .type_ids = &self.field_type_ids } },
            };
            const buffers = if (comptime kind == .dense)
                [_]?*Buffer{ type_ids_buf, offsets_buf.? }
            else
                [_]?*Buffer{type_ids_buf};

            const data = try ArrayData.initOwned(self.allocator, ty, n, 0, 0, &buffers, child_data[0..], null);
            for (field_meta[0..created_fields]) |field_ptr| field_ptr.deinit();
            self.len = 0;
            self.child_lengths = [_]usize{0} ** field_count;
            return data;
        }

        fn appendSparse(self: *Self, comptime index: usize, comptime append_empty_selected: bool) Error!void {
            try self.expectSparseReady(index, append_empty_selected);
            try self.reserve(1);
            inline for (child_fields, 0..) |field_info, i| {
                if (i == index and !append_empty_selected) continue;
                if (comptime !@hasDecl(field_info.type, "appendEmptyValues")) {
                    @compileError("SparseUnionBuilder requires every child builder to expose appendEmptyValues");
                }
                try @field(self.children, field_info.name).appendEmptyValues(1);
            }
            try self.type_ids.append(self.allocator, self.field_type_ids[index]);
            self.len = try checked.add(self.len, 1);
            inline for (0..field_count) |i| self.child_lengths[i] = self.len;
        }

        fn appendDense(self: *Self, comptime index: usize, comptime append_empty_selected: bool) Error!void {
            if (append_empty_selected) {
                const field_info = child_fields[index];
                if (comptime !@hasDecl(field_info.type, "appendEmptyValues")) {
                    @compileError("DenseUnionBuilder appendEmptyValue requires the selected child builder to expose appendEmptyValues");
                }
                try @field(self.children, field_info.name).appendEmptyValues(1);
            }
            try self.expectDenseReady(index);
            try self.reserve(1);
            try self.type_ids.append(self.allocator, self.field_type_ids[index]);
            try self.offsets.append(self.allocator, self.child_lengths[index]);
            self.child_lengths[index] = try checked.add(self.child_lengths[index], 1);
            self.len = try checked.add(self.len, 1);
        }

        fn expectSparseReady(self: *Self, comptime index: usize, comptime append_empty_selected: bool) Error!void {
            inline for (child_fields, 0..) |field_info, i| {
                const expected = if (i == index and !append_empty_selected)
                    try checked.add(self.len, 1)
                else
                    self.len;
                if (@field(self.children, field_info.name).length() != expected) return error.UnclosedUnionValues;
            }
        }

        fn expectDenseReady(self: *Self, comptime index: usize) Error!void {
            inline for (child_fields, 0..) |field_info, i| {
                const expected = if (i == index)
                    try checked.add(self.child_lengths[i], 1)
                else
                    self.child_lengths[i];
                if (@field(self.children, field_info.name).length() != expected) return error.UnclosedUnionValues;
            }
        }

        fn fieldBuilderType(comptime name: []const u8) type {
            inline for (child_fields) |field_info| {
                if (std.mem.eql(u8, name, field_info.name)) return field_info.type;
            }
            @compileError("unknown union builder field: " ++ name);
        }

        fn fieldIndex(comptime name: []const u8) usize {
            inline for (child_fields, 0..) |field_info, i| {
                if (std.mem.eql(u8, name, field_info.name)) return i;
            }
            @compileError("unknown union builder field: " ++ name);
        }

        fn clearUnionState(self: *Self, comptime clear_field_options: bool) void {
            self.type_ids.deinit();
            self.offsets.deinit();
            if (clear_field_options) {
                inline for (0..field_count) |i| {
                    if (self.owned_field_names[i]) |name| self.allocator.free(name);
                    self.field_names[i] = child_fields[i].name;
                    self.owned_field_names[i] = null;
                    self.field_nullable[i] = true;
                    self.field_type_ids[i] = @intCast(i);
                }
            }
            self.len = 0;
            self.child_lengths = [_]usize{0} ** field_count;
        }
    };
}

fn IntBuffer(comptime T: type) type {
    return struct {
        const Self = @This();

        buffer: ?*Buffer,
        len: usize,

        fn init() Self {
            return .{ .buffer = null, .len = 0 };
        }

        fn deinit(self: *Self) void {
            if (self.buffer) |buf| buf.deinit();
            self.buffer = null;
            self.len = 0;
        }

        fn reserve(self: *Self, allocator: Allocator, additional: usize) (Allocator.Error || checked.Error)!void {
            if (additional == 0) return;
            const new_len = try checked.add(self.len, additional);
            const buf = try self.ensureBuffer(allocator);
            try buf.reserve(try checked.mul(new_len, @sizeOf(T)));
        }

        fn append(self: *Self, allocator: Allocator, value: anytype) (Allocator.Error || checked.Error)!void {
            try self.reserve(allocator, 1);
            const buf = self.buffer.?;
            try offset_data.write(T, buf, self.len, intAsUsize(value));
            self.len = try checked.add(self.len, 1);
            buf.size = try checked.mul(self.len, @sizeOf(T));
        }

        fn finish(self: *Self, allocator: Allocator) (Allocator.Error || checked.Error)!*Buffer {
            const buf = if (self.buffer) |b| blk: {
                self.buffer = null;
                break :blk b;
            } else try Buffer.allocate(allocator, 0);
            self.len = 0;
            buf.freeze();
            return buf;
        }

        fn ensureBuffer(self: *Self, allocator: Allocator) (Allocator.Error || checked.Error)!*Buffer {
            if (self.buffer == null) self.buffer = try Buffer.allocate(allocator, 0);
            return self.buffer.?;
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

fn defaultFieldNames(comptime ChildBuilders: type) [std.meta.fields(ChildBuilders).len][]const u8 {
    const child_fields = std.meta.fields(ChildBuilders);
    var names: [child_fields.len][]const u8 = undefined;
    inline for (child_fields, 0..) |field, i| {
        names[i] = field.name;
    }
    return names;
}

fn defaultTypeIds(comptime field_count: usize) [field_count]i8 {
    var ids: [field_count]i8 = undefined;
    inline for (0..field_count) |i| ids[i] = @intCast(i);
    return ids;
}

fn validateTypeIds(ids: []const i8) datatype.ValidationError!void {
    for (ids, 0..) |id, i| {
        if (id < 0) return error.InvalidUnionTypeIds;
        for (ids[0..i]) |seen| {
            if (seen == id) return error.InvalidUnionTypeIds;
        }
    }
}

fn intAsUsize(value: anytype) usize {
    const T = @TypeOf(value);
    const info = @typeInfo(T).int;
    if (info.signedness == .signed and value < 0) unreachable;
    return @intCast(value);
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
        else => @compileError("union builders require a struct of child builder fields"),
    }
}

test "DenseUnionBuilder builds offset based union arrays" {
    const allocator = std.testing.allocator;
    const builder = @import("builder.zig");

    const Children = struct {
        number: builder.NumericBuilder(i32),
        flag: builder.BooleanBuilder,
    };

    var b = try DenseUnionBuilder(Children).initTypeIds(allocator, .{ 7, 8 });
    defer b.deinit();

    try b.field("number").append(10);
    try b.append("number");
    try b.field("flag").append(true);
    try b.append("flag");
    try b.field("number").append(30);
    try b.append("number");
    try b.appendEmptyValue("flag");

    const data = try b.finish();
    defer data.deinit();
    try data.validate();

    const arr = try array.DenseUnionArray.fromData(data);
    try std.testing.expectEqual(@as(usize, 4), arr.view.base.len);
    try std.testing.expectEqual(@as(i8, 7), arr.typeId(0));
    try std.testing.expectEqual(@as(i8, 8), arr.typeId(1));
    try std.testing.expectEqual(@as(usize, 1), arr.valueOffset(2));
    try std.testing.expectEqual(@as(usize, 1), arr.valueOffset(3));
    try std.testing.expectEqualStrings("number", data.type.dense_union.fields[0].name);

    const value = (try arr.valueOwned(2)).?;
    defer value.deinit();
    const value_arr = try array.NumericArray(i32).fromData(value);
    try std.testing.expectEqual(@as(i32, 30), value_arr.value(0));
}

test "SparseUnionBuilder builds row aligned union arrays" {
    const allocator = std.testing.allocator;
    const builder = @import("builder.zig");

    const Children = struct {
        number: builder.NumericBuilder(i32),
        flag: builder.BooleanBuilder,
    };

    var b = try SparseUnionBuilder(Children).initTypeIds(allocator, .{ 7, 8 });
    defer b.deinit();

    try b.field("number").append(10);
    try b.append("number");
    try b.field("flag").append(true);
    try b.append("flag");
    try b.appendEmptyValue("number");

    const data = try b.finish();
    defer data.deinit();
    try data.validate();

    const arr = try array.SparseUnionArray.fromData(data);
    try std.testing.expectEqual(@as(usize, 3), arr.view.base.len);
    try std.testing.expectEqual(@as(i8, 7), arr.typeId(0));
    try std.testing.expectEqual(@as(i8, 8), arr.typeId(1));
    try std.testing.expectEqual(@as(usize, 3), data.children[0].len);
    try std.testing.expectEqual(@as(usize, 3), data.children[1].len);

    const value = (try arr.valueOwned(0)).?;
    defer value.deinit();
    const value_arr = try array.NumericArray(i32).fromData(value);
    try std.testing.expectEqual(@as(i32, 10), value_arr.value(0));
}

test "UnionBuilder rejects partial child values and invalid type ids" {
    const allocator = std.testing.allocator;
    const builder = @import("builder.zig");

    const Children = struct {
        number: builder.NumericBuilder(i32),
        flag: builder.BooleanBuilder,
    };

    try std.testing.expectError(error.InvalidUnionTypeIds, DenseUnionBuilder(Children).initTypeIds(allocator, .{ 7, 7 }));
    try std.testing.expectError(error.InvalidUnionTypeIds, SparseUnionBuilder(Children).initTypeIds(allocator, .{ -1, 8 }));

    var dense = try DenseUnionBuilder(Children).initTypeIds(allocator, .{ 7, 8 });
    defer dense.deinit();
    try dense.field("number").append(10);
    try dense.field("flag").append(true);
    try std.testing.expectError(error.UnclosedUnionValues, dense.append("number"));

    var sparse = try SparseUnionBuilder(Children).initTypeIds(allocator, .{ 7, 8 });
    defer sparse.deinit();
    try sparse.field("number").append(10);
    try sparse.field("flag").append(true);
    try std.testing.expectError(error.UnclosedUnionValues, sparse.append("number"));
}
