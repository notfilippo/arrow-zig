//! Struct array view.
//!
//! Struct arrays expose child fields by index or name while sharing the parent
//! logical range.

const std = @import("std");
const datatype = @import("datatype.zig");
const array_data = @import("array_data.zig");
const common = @import("array_view_common.zig");
const Buffer = @import("buffer.zig").Buffer;
const ArrayData = array_data.ArrayData;

pub const StructArray = struct {
    data: *const ArrayData,
    offset: usize,
    len: usize,
    null_count: usize,

    pub fn fromData(data: *const ArrayData) common.ViewError!StructArray {
        if (data.type.id() != .struct_) return error.TypeMismatch;
        if (data.buffers.len != 1 or data.children.len != data.type.struct_.fields.len) return error.InvalidBufferLayout;
        return .{
            .data = data,
            .offset = data.offset,
            .len = data.len,
            .null_count = data.null_count,
        };
    }

    pub fn dataType(self: StructArray) datatype.DataType {
        return self.data.type;
    }

    pub fn baseData(self: StructArray) *const ArrayData {
        return self.data;
    }

    pub fn fieldCount(self: StructArray) usize {
        return self.data.children.len;
    }

    pub fn fieldBaseData(self: StructArray, index: usize) ?*const ArrayData {
        if (index >= self.data.children.len) return null;
        return self.data.children[index];
    }

    pub fn fieldOwned(self: StructArray, index: usize) array_data.DataSliceError!?*ArrayData {
        const child = self.fieldBaseData(index) orelse return null;
        return child.slice(self.offset, self.len);
    }

    pub fn fieldName(self: StructArray, index: usize) ?[]const u8 {
        if (index >= self.data.type.struct_.fields.len) return null;
        return self.data.type.struct_.fields[index].name;
    }

    pub fn fieldBaseNamed(self: StructArray, name: []const u8) ?*const ArrayData {
        const index = self.fieldIndexNamed(name) orelse return null;
        return self.data.children[index];
    }

    pub fn fieldNamedOwned(self: StructArray, name: []const u8) array_data.DataSliceError!?*ArrayData {
        const index = self.fieldIndexNamed(name) orelse return null;
        return self.fieldOwned(index);
    }

    pub fn isValid(self: StructArray, i: usize) bool {
        return common.slotIsValid(self.data, self.offset, i);
    }

    pub fn isNull(self: StructArray, i: usize) bool {
        return !self.isValid(i);
    }

    pub fn nullCount(self: StructArray) usize {
        return common.viewNullCount(self.data, self.offset, self.len, self.null_count);
    }

    pub fn slice(self: StructArray, off: usize, length: usize) StructArray {
        return self.sliceChecked(off, length) catch unreachable;
    }

    pub fn sliceChecked(self: StructArray, off: usize, length: usize) common.SliceError!StructArray {
        const clamped = try common.clampedLen(self.len, off, length);
        return .{
            .data = self.data,
            .offset = self.offset + off,
            .len = clamped,
            .null_count = array_data.slicedNullCount(self.null_count, self.len, off, clamped),
        };
    }

    pub fn sliceOwned(self: StructArray, off: usize, length: usize) array_data.DataSliceError!*ArrayData {
        const clamped = try common.clampedLen(self.len, off, length);
        const data_off = try common.dataRelativeOffset(self.data.offset, self.offset, off);
        return self.data.slice(data_off, clamped);
    }

    pub fn cloneRetained(self: StructArray) array_data.DataSliceError!*ArrayData {
        return self.sliceOwned(0, self.len);
    }

    fn fieldIndexNamed(self: StructArray, name: []const u8) ?usize {
        for (self.data.type.struct_.fields, 0..) |field_meta, i| {
            if (std.mem.eql(u8, field_meta.name, name)) return i;
        }
        return null;
    }
};

test "StructArray exposes child fields" {
    const allocator = std.testing.allocator;
    const builder = @import("builder.zig");
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
    const fields = [_]datatype.Field{
        .{ .name = "number", .type = &number_ty },
        .{ .name = "flag", .type = &flag_ty },
    };
    const struct_ty = datatype.DataType{ .struct_ = .{ .fields = &fields } };
    const data = try ArrayData.initRetained(allocator, struct_ty, 3, 0, 1, &.{validity}, &.{ number_data, flag_data }, null);
    defer data.deinit();
    try data.validate();

    const arr = try StructArray.fromData(data);
    try std.testing.expectEqual(@as(usize, 2), arr.fieldCount());
    try std.testing.expectEqualStrings("number", arr.fieldName(0).?);
    try std.testing.expect(arr.fieldBaseNamed("flag") != null);
    try std.testing.expect(arr.fieldBaseNamed("missing") == null);
    try std.testing.expect(arr.isNull(1));
    try std.testing.expectEqual(@as(usize, 1), arr.nullCount());

    const sliced = arr.slice(1, 9);
    try std.testing.expectEqual(@as(usize, 2), sliced.len);
    try std.testing.expectEqual(@as(usize, 1), sliced.offset);

    const sliced_numbers = (try sliced.fieldNamedOwned("number")).?;
    defer sliced_numbers.deinit();
    const sliced_number_arr = try @import("array.zig").NumericArray(i32).fromData(sliced_numbers);
    try std.testing.expectEqual(@as(usize, 2), sliced_number_arr.len);
    try std.testing.expectEqual(@as(i32, 20), sliced_number_arr.value(0));

    const sliced_owned = try sliced.sliceOwned(0, 1);
    defer sliced_owned.deinit();
    const sliced_owned_arr = try StructArray.fromData(sliced_owned);
    const owned_numbers = (try sliced_owned_arr.fieldNamedOwned("number")).?;
    defer owned_numbers.deinit();
    const owned_number_arr = try @import("array.zig").NumericArray(i32).fromData(owned_numbers);
    try std.testing.expectEqual(@as(i32, 20), owned_number_arr.value(0));

    const sliced_clone = try sliced.cloneRetained();
    defer sliced_clone.deinit();
    const sliced_clone_arr = try StructArray.fromData(sliced_clone);
    const clone_numbers = (try sliced_clone_arr.fieldNamedOwned("number")).?;
    defer clone_numbers.deinit();
    const clone_number_arr = try @import("array.zig").NumericArray(i32).fromData(clone_numbers);
    try std.testing.expectEqual(@as(i32, 20), clone_number_arr.value(0));

    try std.testing.expectError(error.OffsetOutOfBounds, arr.sliceChecked(4, 1));
}

test "StructArray rejects non struct data" {
    const allocator = std.testing.allocator;
    const builder = @import("builder.zig");
    var numbers = builder.NumericBuilder(i32).init(allocator);
    defer numbers.deinit();
    try numbers.append(1);
    const data = try numbers.finish();
    defer data.deinit();

    try std.testing.expectError(error.TypeMismatch, StructArray.fromData(data));
}
