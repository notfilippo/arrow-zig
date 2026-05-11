const std = @import("std");
const Allocator = std.mem.Allocator;
const checked = @import("checked.zig");
const datatype = @import("datatype.zig");
const bitmap = @import("bitmap.zig");
const array_validate = @import("array_validate.zig");
const offset_data = @import("offsets.zig");
const Buffer = @import("buffer.zig").Buffer;
const RefCount = @import("refcount.zig").RefCount;

pub const unknown_null_count = bitmap.unknown_null_count;
pub const ValidateError = array_validate.Error;
pub const InitError = Allocator.Error || checked.Error;
pub const SliceError = InitError || error{OffsetOutOfBounds};

pub const ArrayData = struct {
    allocator: Allocator,
    type: datatype.DataType,
    len: usize,
    offset: usize,
    null_count: usize,
    buffers: []?*Buffer,
    children: []*ArrayData,
    dictionary: ?*ArrayData,
    ref_count: RefCount,

    const Ownership = enum {
        owned,
        retained,
    };

    pub fn initOwned(
        allocator: Allocator,
        ty: datatype.DataType,
        len: usize,
        offset: usize,
        null_count: usize,
        buffers: []const ?*Buffer,
        children: []const *ArrayData,
        dictionary: ?*ArrayData,
    ) InitError!*ArrayData {
        return init(allocator, ty, len, offset, null_count, buffers, children, dictionary, .owned);
    }

    pub fn initRetained(
        allocator: Allocator,
        ty: datatype.DataType,
        len: usize,
        offset: usize,
        null_count: usize,
        buffers: []const ?*Buffer,
        children: []const *ArrayData,
        dictionary: ?*ArrayData,
    ) InitError!*ArrayData {
        return init(allocator, ty, len, offset, null_count, buffers, children, dictionary, .retained);
    }

    fn init(
        allocator: Allocator,
        ty: datatype.DataType,
        len: usize,
        offset: usize,
        null_count: usize,
        buffers: []const ?*Buffer,
        children: []const *ArrayData,
        dictionary: ?*ArrayData,
        ownership: Ownership,
    ) InitError!*ArrayData {
        _ = try checked.add(offset, len);
        const self = try allocator.create(ArrayData);
        errdefer allocator.destroy(self);

        var owned_type = try datatype.cloneOwned(allocator, ty);
        errdefer datatype.deinitOwned(allocator, &owned_type);

        const owned_buffers = try allocator.alloc(?*Buffer, buffers.len);
        errdefer allocator.free(owned_buffers);

        const owned_children = try allocator.alloc(*ArrayData, children.len);
        errdefer allocator.free(owned_children);

        switch (ownership) {
            .retained => {
                for (buffers, 0..) |buf, i| {
                    owned_buffers[i] = if (buf) |b| b.retain() else null;
                }
                errdefer for (owned_buffers) |buf| {
                    if (buf) |b| b.release();
                };
                for (children, 0..) |child, i| {
                    owned_children[i] = child.retain();
                }
                errdefer for (owned_children) |child| {
                    child.release();
                };
            },
            .owned => {
                @memcpy(owned_buffers, buffers);
                @memcpy(owned_children, children);
            },
        }

        const dict = switch (ownership) {
            .retained => if (dictionary) |d| d.retain() else null,
            .owned => dictionary,
        };

        self.* = .{
            .allocator = allocator,
            .type = owned_type,
            .len = len,
            .offset = offset,
            .null_count = null_count,
            .buffers = owned_buffers,
            .children = owned_children,
            .dictionary = dict,
            .ref_count = RefCount.init(1),
        };
        return self;
    }

    pub fn retain(self: *ArrayData) *ArrayData {
        _ = self.ref_count.fetchAdd(1, .monotonic);
        return self;
    }

    pub fn cloneRetained(self: *const ArrayData) InitError!*ArrayData {
        return initRetained(self.allocator, self.type, self.len, self.offset, self.null_count, self.buffers, self.children, self.dictionary);
    }

    pub fn validate(self: *const ArrayData) (ValidateError || checked.Error || datatype.ValidationError)!void {
        try array_validate.validate(self);
    }

    pub fn slice(self: *const ArrayData, off: usize, length: usize) SliceError!*ArrayData {
        if (off > self.len) return error.OffsetOutOfBounds;
        const clamped = @min(length, self.len - off);
        const abs_offset = try checked.add(self.offset, off);
        const nc = slicedNullCount(self.null_count, self.len, off, clamped);
        return initRetained(self.allocator, self.type, clamped, abs_offset, nc, self.buffers, self.children, self.dictionary);
    }

    pub fn nullCount(self: *const ArrayData) usize {
        if (self.type.id() == .null_) return self.len;
        const validity = if (self.buffers.len > 0) self.buffers[0] else null;
        return bitmap.nullCountFor(
            if (validity) |v| v.dataSlice() else null,
            self.offset,
            self.len,
            self.null_count,
        );
    }

    pub fn refCount(self: *const ArrayData) usize {
        return self.ref_count.load(.monotonic);
    }

    pub fn release(self: *ArrayData) void {
        if (self.ref_count.fetchSub(1, .acq_rel) != 1) return;
        const allocator = self.allocator;
        for (self.buffers) |buf| {
            if (buf) |b| b.release();
        }
        for (self.children) |child| {
            child.release();
        }
        if (self.dictionary) |dict| dict.release();
        allocator.free(self.buffers);
        allocator.free(self.children);
        datatype.deinitOwned(allocator, &self.type);
        allocator.destroy(self);
    }
};

pub fn slicedNullCount(nc: usize, len: usize, off: usize, clamped: usize) usize {
    if (nc == 0) return 0;
    if (nc == len) return clamped;
    if (off == 0 and clamped == len) return nc;
    return unknown_null_count;
}

fn writeTestInt(comptime T: type, buffer: *Buffer, index: usize, value: T) void {
    offset_data.write(T, buffer, index, @intCast(value)) catch unreachable;
}

test "ArrayData init overflow" {
    const allocator = std.testing.allocator;
    const values = try Buffer.allocate(allocator, 8);
    defer values.release();
    values.freeze();

    try std.testing.expectError(
        error.Overflow,
        ArrayData.initOwned(allocator, .int32, 1, std.math.maxInt(usize), 0, &.{ null, values }, &.{}, null),
    );
}

test "ArrayData cloneRetained retains buffers" {
    const allocator = std.testing.allocator;
    const values = try Buffer.allocate(allocator, 16);
    errdefer values.release();
    values.freeze();

    const data = try ArrayData.initOwned(allocator, .int32, 4, 0, 0, &.{ null, values }, &.{}, null);
    defer data.release();

    const clone = try data.cloneRetained();
    defer clone.release();

    try std.testing.expectEqual(@as(usize, 2), values.refCount());
    try std.testing.expectEqual(@as(usize, 4), clone.len);
    try std.testing.expectEqual(@as(usize, 0), clone.offset);
}

test "ArrayData init owns nested type metadata" {
    const allocator = std.testing.allocator;
    const values = try Buffer.allocate(allocator, 4 * @sizeOf(i32));
    errdefer values.release();
    values.freeze();
    const child = try ArrayData.initOwned(allocator, .int32, 4, 0, 0, &.{ null, values }, &.{}, null);
    defer child.release();

    const child_ty: datatype.DataType = .int32;
    const fields = [_]datatype.Field{.{ .name = "items", .type = &child_ty }};
    const ty = datatype.DataType{ .list = .{ .child = fields[0] } };

    const offsets = try Buffer.allocate(allocator, 2 * @sizeOf(i32));
    errdefer offsets.release();
    writeTestInt(i32, offsets, 0, 0);
    writeTestInt(i32, offsets, 1, 4);
    offsets.freeze();
    defer offsets.release();

    const data = try ArrayData.initRetained(allocator, ty, 1, 0, 0, &.{ null, offsets }, &.{child}, null);
    defer data.release();

    try std.testing.expect(data.type.list.child.type != &child_ty);
    try std.testing.expectEqualStrings("items", data.type.list.child.name);
    try data.validate();
}

test "ArrayData init retained retains buffers and children" {
    const allocator = std.testing.allocator;
    const values = try Buffer.allocate(allocator, 16);
    defer values.release();
    values.freeze();

    const child_values = try Buffer.allocate(allocator, 4);
    errdefer child_values.release();
    child_values.freeze();

    const child = try ArrayData.initOwned(allocator, .uint8, 4, 0, 0, &.{ null, child_values }, &.{}, null);
    defer child.release();

    const data = try ArrayData.initRetained(allocator, .int32, 4, 0, 0, &.{ null, values }, &.{child}, child);
    defer data.release();

    try std.testing.expectEqual(@as(usize, 2), values.refCount());
    try std.testing.expectEqual(@as(usize, 3), child.refCount());
}

test "ArrayData slice retains buffers and adjusts metadata" {
    const allocator = std.testing.allocator;
    const validity = try Buffer.allocate(allocator, 1);
    errdefer validity.release();
    validity.data[0] = 0b00010111;
    validity.freeze();

    const values = try Buffer.allocate(allocator, 5 * @sizeOf(i32));
    errdefer values.release();
    values.freeze();

    const data = try ArrayData.initOwned(allocator, .int32, 5, 0, 1, &.{ validity, values }, &.{}, null);
    defer data.release();

    const sliced = try data.slice(1, 3);
    defer sliced.release();

    try std.testing.expectEqual(@as(usize, 3), sliced.len);
    try std.testing.expectEqual(@as(usize, 1), sliced.offset);
    try std.testing.expectEqual(unknown_null_count, sliced.null_count);
    try std.testing.expectEqual(@as(usize, 1), sliced.nullCount());
    try std.testing.expectEqual(@as(usize, 2), validity.refCount());
    try std.testing.expectEqual(@as(usize, 2), values.refCount());
}

test "ArrayData slice clamps length and rejects bad offset" {
    const allocator = std.testing.allocator;
    const values = try Buffer.allocate(allocator, 5 * @sizeOf(i32));
    errdefer values.release();
    values.freeze();

    const data = try ArrayData.initOwned(allocator, .int32, 5, 0, 0, &.{ null, values }, &.{}, null);
    defer data.release();

    const sliced = try data.slice(3, 99);
    defer sliced.release();
    try std.testing.expectEqual(@as(usize, 2), sliced.len);
    try std.testing.expectEqual(@as(usize, 3), sliced.offset);
    try std.testing.expectError(error.OffsetOutOfBounds, data.slice(6, 1));
}
