// Copyright 2026 Filippo Rossi
// SPDX-License-Identifier: Apache-2.0

//! Nested struct array type.
//!
//! Struct arrays expose child fields by index or name while sharing the parent
//! logical range.

const std = @import("std");
const datatype = @import("../datatype.zig");
const array_data = @import("data.zig");
const common = @import("base.zig");
const Buffer = @import("../buffer.zig").Buffer;
const ArrayData = array_data.ArrayData;

pub const StructArray = struct {
    view: common.ValidityView(.bitmap),

    pub fn fromData(data: *const ArrayData) common.ViewError!StructArray {
        if (data.type.id() != .struct_) return error.TypeMismatch;
        if (data.buffers.len != 1 or data.children.len != data.type.struct_.fields.len) return error.InvalidBufferLayout;
        return .{ .view = common.ValidityView(.bitmap).init(data) };
    }

    pub fn fieldCount(self: StructArray) usize {
        return self.view.base.data.children.len;
    }

    pub fn fieldBaseData(self: StructArray, index: usize) ?*const ArrayData {
        if (index >= self.view.base.data.children.len) return null;
        return self.view.base.data.children[index];
    }

    pub fn fieldOwned(self: StructArray, index: usize) array_data.DataSliceError!?*ArrayData {
        const child = self.fieldBaseData(index) orelse return null;
        return child.slice(self.view.base.offset, self.view.base.len);
    }

    pub fn fieldName(self: StructArray, index: usize) ?[]const u8 {
        if (index >= self.view.base.data.type.struct_.fields.len) return null;
        return self.view.base.data.type.struct_.fields[index].name;
    }

    pub fn fieldBaseNamed(self: StructArray, name: []const u8) ?*const ArrayData {
        const index = self.fieldIndexNamed(name) orelse return null;
        return self.view.base.data.children[index];
    }

    pub fn fieldNamedOwned(self: StructArray, name: []const u8) array_data.DataSliceError!?*ArrayData {
        const index = self.fieldIndexNamed(name) orelse return null;
        return self.fieldOwned(index);
    }

    fn fieldIndexNamed(self: StructArray, name: []const u8) ?usize {
        for (self.view.base.data.type.struct_.fields, 0..) |field_meta, i| {
            if (std.mem.eql(u8, field_meta.name, name)) return i;
        }
        return null;
    }
};

test "StructArray exposes child fields" {
    const allocator = std.testing.allocator;
    const builder = @import("../builder.zig");
    var numbers = builder.NumericBuilder(i32).init(allocator);
    defer numbers.deinit();
    try numbers.appendSlice(&.{ 10, 20, 30 });
    const number_data = try numbers.finish();
    defer number_data.deinit();

    var flags = builder.BooleanBuilder.init(allocator);
    defer flags.deinit();
    try flags.appendSlice(&.{ true, false, true });
    const flag_data = try flags.finish();
    defer flag_data.deinit();

    const validity = try Buffer.allocate(allocator, 1);
    errdefer validity.deinit();
    validity.data[0] = 0b00000101;
    validity.freeze();
    defer validity.deinit();

    const number_ty: datatype.DataType = .int32;
    const flag_ty: datatype.DataType = .bool;
    const number_field = try datatype.Field.create(allocator, "number", &number_ty, true, &.{});
    defer number_field.deinit();
    const flag_field = try datatype.Field.create(allocator, "flag", &flag_ty, true, &.{});
    defer flag_field.deinit();
    const struct_fields = [_]*const datatype.Field{ number_field, flag_field };
    const struct_ty = datatype.DataType{ .struct_ = .{ .fields = &struct_fields } };
    const data = try ArrayData.initRetained(allocator, struct_ty, 3, 0, 1, &.{validity}, &.{ number_data, flag_data }, null);
    defer data.deinit();
    try data.validate();

    const arr = try StructArray.fromData(data);
    try std.testing.expectEqual(@as(usize, 2), arr.fieldCount());
    try std.testing.expectEqualStrings("number", arr.fieldName(0).?);
    try std.testing.expect(arr.fieldBaseNamed("flag") != null);
    try std.testing.expect(arr.fieldBaseNamed("missing") == null);
    try std.testing.expect(arr.view.isNull(1));
    try std.testing.expectEqual(@as(usize, 1), arr.view.nullCount());

    const sliced = StructArray{ .view = arr.view.slice(1, 9) };
    try std.testing.expectEqual(@as(usize, 2), sliced.view.base.len);
    try std.testing.expectEqual(@as(usize, 1), sliced.view.base.offset);

    const sliced_numbers = (try sliced.fieldNamedOwned("number")).?;
    defer sliced_numbers.deinit();
    const sliced_number_arr = try @import("../array.zig").NumericArray(i32).fromData(sliced_numbers);
    try std.testing.expectEqual(@as(usize, 2), sliced_number_arr.view.base.len);
    try std.testing.expectEqual(@as(i32, 20), sliced_number_arr.value(0));

    const sliced_owned = try sliced.view.base.sliceOwned(0, 1);
    defer sliced_owned.deinit();
    const sliced_owned_arr = try StructArray.fromData(sliced_owned);
    const owned_numbers = (try sliced_owned_arr.fieldNamedOwned("number")).?;
    defer owned_numbers.deinit();
    const owned_number_arr = try @import("../array.zig").NumericArray(i32).fromData(owned_numbers);
    try std.testing.expectEqual(@as(i32, 20), owned_number_arr.value(0));

    const sliced_clone = try sliced.view.base.cloneRetained();
    defer sliced_clone.deinit();
    const sliced_clone_arr = try StructArray.fromData(sliced_clone);
    const clone_numbers = (try sliced_clone_arr.fieldNamedOwned("number")).?;
    defer clone_numbers.deinit();
    const clone_number_arr = try @import("../array.zig").NumericArray(i32).fromData(clone_numbers);
    try std.testing.expectEqual(@as(i32, 20), clone_number_arr.value(0));

    try std.testing.expectError(error.OffsetOutOfBounds, arr.view.sliceChecked(4, 1));
}

test "StructArray rejects non struct data" {
    const allocator = std.testing.allocator;
    const builder = @import("../builder.zig");
    var numbers = builder.NumericBuilder(i32).init(allocator);
    defer numbers.deinit();
    try numbers.append(1);
    const data = try numbers.finish();
    defer data.deinit();

    try std.testing.expectError(error.TypeMismatch, StructArray.fromData(data));
}
