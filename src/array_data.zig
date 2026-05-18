// Copyright 2026 Filippo Rossi
// SPDX-License-Identifier: Apache-2.0

//! Reference counted Arrow array storage.
//!
//! `ArrayData` stores the data type, logical range, null count, buffers,
//! children, and optional dictionary for one Arrow array. Callers can either
//! transfer ownership with `initOwned` or retain existing inputs with
//! `initRetained`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const checked = @import("checked.zig");
const datatype = @import("datatype.zig");
const bitmap = @import("bitmap.zig");
const array_validate = @import("array_validate.zig");
const offset_data = @import("offsets.zig");
const buffer_mod = @import("buffer.zig");
const Buffer = buffer_mod.Buffer;
const ExternalOwnerHandle = buffer_mod.ExternalOwnerHandle;
const RefCount = @import("refcount.zig").RefCount;

pub const ValidateError = array_validate.Error;
pub const InitError = Allocator.Error || checked.Error;
pub const DataSliceError = InitError || error{OffsetOutOfBounds};

pub const ArrayData = struct {
    allocator: Allocator,
    type: datatype.DataType,
    len: usize,
    offset: usize,
    null_count: ?usize,
    buffers: []?*Buffer,
    children: []*ArrayData,
    dictionary: ?*ArrayData,
    external_owner: ?*ExternalOwnerHandle,
    ref_count: RefCount,

    const Ownership = enum {
        owned,
        retained,
    };

    /// Create storage by consuming the supplied buffers, children, and dictionary.
    /// On success, caller must not deinit those inputs separately. On error, caller
    /// still owns every input. The returned data must be deinitialized by the caller.
    pub fn initOwned(
        allocator: Allocator,
        ty: datatype.DataType,
        len: usize,
        offset: usize,
        null_count: ?usize,
        buffers: []const ?*Buffer,
        children: []const *ArrayData,
        dictionary: ?*ArrayData,
    ) InitError!*ArrayData {
        return init(allocator, ty, len, offset, null_count, buffers, children, dictionary, .owned, null);
    }

    /// Create storage by consuming inputs and retaining an external owner.
    /// Used by importers whose buffers may all be absent or empty.
    pub fn initOwnedExternal(
        allocator: Allocator,
        ty: datatype.DataType,
        len: usize,
        offset: usize,
        null_count: ?usize,
        buffers: []const ?*Buffer,
        children: []const *ArrayData,
        dictionary: ?*ArrayData,
        owner: *ExternalOwnerHandle,
    ) InitError!*ArrayData {
        return init(allocator, ty, len, offset, null_count, buffers, children, dictionary, .owned, owner);
    }

    /// Create storage by retaining the supplied buffers, children, and dictionary.
    /// Caller keeps its existing references. The returned data must be deinitialized
    /// by the caller.
    pub fn initRetained(
        allocator: Allocator,
        ty: datatype.DataType,
        len: usize,
        offset: usize,
        null_count: ?usize,
        buffers: []const ?*Buffer,
        children: []const *ArrayData,
        dictionary: ?*ArrayData,
    ) InitError!*ArrayData {
        return init(allocator, ty, len, offset, null_count, buffers, children, dictionary, .retained, null);
    }

    fn init(
        allocator: Allocator,
        ty: datatype.DataType,
        len: usize,
        offset: usize,
        null_count: ?usize,
        buffers: []const ?*Buffer,
        children: []const *ArrayData,
        dictionary: ?*ArrayData,
        ownership: Ownership,
        external_owner: ?*ExternalOwnerHandle,
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
                    if (buf) |b| b.deinit();
                };
                for (children, 0..) |child, i| {
                    owned_children[i] = child.retain();
                }
                errdefer for (owned_children) |child| {
                    child.deinit();
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

        const owner = if (external_owner) |o| o.retain() else null;
        errdefer if (owner) |o| o.deinit();

        self.* = .{
            .allocator = allocator,
            .type = owned_type,
            .len = len,
            .offset = offset,
            .null_count = null_count,
            .buffers = owned_buffers,
            .children = owned_children,
            .dictionary = dict,
            .external_owner = owner,
            .ref_count = RefCount.init(1),
        };
        return self;
    }

    pub fn retain(self: *ArrayData) *ArrayData {
        _ = self.ref_count.fetchAdd(1, .monotonic);
        return self;
    }

    pub fn cloneRetained(self: *const ArrayData) InitError!*ArrayData {
        return init(self.allocator, self.type, self.len, self.offset, self.null_count, self.buffers, self.children, self.dictionary, .retained, self.external_owner);
    }

    pub fn validate(self: *const ArrayData) (ValidateError || checked.Error || datatype.ValidationError)!void {
        try array_validate.validate(self);
    }

    pub fn slice(self: *const ArrayData, off: usize, length: usize) DataSliceError!*ArrayData {
        if (off > self.len) return error.OffsetOutOfBounds;
        const clamped = @min(length, self.len - off);
        const abs_offset = try checked.add(self.offset, off);
        const nc = slicedNullCount(self.null_count, self.len, off, clamped);
        return init(self.allocator, self.type, clamped, abs_offset, nc, self.buffers, self.children, self.dictionary, .retained, self.external_owner);
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

    /// Drop one reference. Deinitializes child storage when the count reaches zero.
    pub fn deinit(self: *ArrayData) void {
        if (self.ref_count.fetchSub(1, .acq_rel) != 1) return;
        const allocator = self.allocator;
        for (self.buffers) |buf| {
            if (buf) |b| b.deinit();
        }
        for (self.children) |child| {
            child.deinit();
        }
        if (self.dictionary) |dict| dict.deinit();
        if (self.external_owner) |owner| owner.deinit();
        allocator.free(self.buffers);
        allocator.free(self.children);
        datatype.deinitOwned(allocator, &self.type);
        allocator.destroy(self);
    }
};

pub fn slicedNullCount(nc: ?usize, len: usize, off: usize, clamped: usize) ?usize {
    const known = nc orelse return null;
    if (known == 0) return 0;
    if (known == len) return clamped;
    if (off == 0 and clamped == len) return known;
    return null;
}

fn writeTestInt(comptime T: type, buffer: *Buffer, index: usize, value: T) void {
    offset_data.write(T, buffer, index, @intCast(value)) catch unreachable;
}

test "ArrayData init overflow" {
    const allocator = std.testing.allocator;
    const values = try Buffer.allocate(allocator, 8);
    defer values.deinit();
    values.freeze();

    try std.testing.expectError(
        error.Overflow,
        ArrayData.initOwned(allocator, .int32, 1, std.math.maxInt(usize), 0, &.{ null, values }, &.{}, null),
    );
}

test "ArrayData cloneRetained retains buffers" {
    const allocator = std.testing.allocator;
    const values = try Buffer.allocate(allocator, 16);
    errdefer values.deinit();
    values.freeze();

    const data = try ArrayData.initOwned(allocator, .int32, 4, 0, 0, &.{ null, values }, &.{}, null);
    defer data.deinit();

    const clone = try data.cloneRetained();
    defer clone.deinit();

    try std.testing.expectEqual(@as(usize, 2), values.refCount());
    try std.testing.expectEqual(@as(usize, 4), clone.len);
    try std.testing.expectEqual(@as(usize, 0), clone.offset);
}

test "ArrayData init owns nested type metadata" {
    const allocator = std.testing.allocator;
    const values = try Buffer.allocate(allocator, 4 * @sizeOf(i32));
    errdefer values.deinit();
    values.freeze();
    const child = try ArrayData.initOwned(allocator, .int32, 4, 0, 0, &.{ null, values }, &.{}, null);
    defer child.deinit();

    const child_ty: datatype.DataType = .int32;
    const items_field = try datatype.Field.create(allocator, "items", &child_ty, true, &.{});
    defer items_field.deinit();
    const ty = datatype.DataType{ .list = .{ .child = items_field } };

    const offsets = try Buffer.allocate(allocator, 2 * @sizeOf(i32));
    errdefer offsets.deinit();
    writeTestInt(i32, offsets, 0, 0);
    writeTestInt(i32, offsets, 1, 4);
    offsets.freeze();
    defer offsets.deinit();

    const data = try ArrayData.initRetained(allocator, ty, 1, 0, 0, &.{ null, offsets }, &.{child}, null);
    defer data.deinit();

    try std.testing.expect(data.type.list.child.type != &child_ty);
    try std.testing.expectEqualStrings("items", data.type.list.child.name);
    try data.validate();
}

test "ArrayData init retained retains buffers and children" {
    const allocator = std.testing.allocator;
    const values = try Buffer.allocate(allocator, 16);
    defer values.deinit();
    values.freeze();

    const child_values = try Buffer.allocate(allocator, 4);
    errdefer child_values.deinit();
    child_values.freeze();

    const child = try ArrayData.initOwned(allocator, .uint8, 4, 0, 0, &.{ null, child_values }, &.{}, null);
    defer child.deinit();

    const data = try ArrayData.initRetained(allocator, .int32, 4, 0, 0, &.{ null, values }, &.{child}, child);
    defer data.deinit();

    try std.testing.expectEqual(@as(usize, 2), values.refCount());
    try std.testing.expectEqual(@as(usize, 3), child.refCount());
}

test "ArrayData slice retains buffers and adjusts metadata" {
    const allocator = std.testing.allocator;
    const validity = try Buffer.allocate(allocator, 1);
    errdefer validity.deinit();
    validity.data[0] = 0b00010111;
    validity.freeze();

    const values = try Buffer.allocate(allocator, 5 * @sizeOf(i32));
    errdefer values.deinit();
    values.freeze();

    const data = try ArrayData.initOwned(allocator, .int32, 5, 0, 1, &.{ validity, values }, &.{}, null);
    defer data.deinit();

    const sliced = try data.slice(1, 3);
    defer sliced.deinit();

    try std.testing.expectEqual(@as(usize, 3), sliced.len);
    try std.testing.expectEqual(@as(usize, 1), sliced.offset);
    try std.testing.expectEqual(@as(?usize, null), sliced.null_count);
    try std.testing.expectEqual(@as(usize, 1), sliced.nullCount());
    try std.testing.expectEqual(@as(usize, 2), validity.refCount());
    try std.testing.expectEqual(@as(usize, 2), values.refCount());
}

test "ArrayData slice clamps length and rejects bad offset" {
    const allocator = std.testing.allocator;
    const values = try Buffer.allocate(allocator, 5 * @sizeOf(i32));
    errdefer values.deinit();
    values.freeze();

    const data = try ArrayData.initOwned(allocator, .int32, 5, 0, 0, &.{ null, values }, &.{}, null);
    defer data.deinit();

    const sliced = try data.slice(3, 99);
    defer sliced.deinit();
    try std.testing.expectEqual(@as(usize, 2), sliced.len);
    try std.testing.expectEqual(@as(usize, 3), sliced.offset);
    try std.testing.expectError(error.OffsetOutOfBounds, data.slice(6, 1));
}
