// Copyright 2026 Filippo Rossi
// SPDX-License-Identifier: Apache-2.0

//! Arrow C Data Interface array import.

const std = @import("std");
const Allocator = std.mem.Allocator;
const array = @import("../array.zig");
const bitmap = @import("../bitmap.zig");
const buffer = @import("../buffer.zig");
const checked = @import("../checked.zig");
const cdi_types = @import("types.zig");
const datatype = @import("../datatype.zig");

const ArrayData = array.ArrayData;
const ArrowArray = cdi_types.ArrowArray;
const Buffer = buffer.Buffer;
const ExternalOwnerHandle = buffer.ExternalOwnerHandle;

pub const Error =
    Allocator.Error ||
    checked.Error ||
    datatype.ValidationError ||
    array.ValidateError ||
    error{
        ReleasedArray,
        NegativeLength,
        InvalidNullCount,
        ValueOutOfRange,
    };

// Children and dictionaries stay owned by the moved top level ArrowArray.
const ImportedArrayOwner = struct {
    allocator: Allocator,
    handle: ExternalOwnerHandle,
    moved: ArrowArray,
    moved_valid: bool,
};

/// Import one typed Arrow C Data Interface array without copying buffers.
/// On success, consumes only the top level `ArrowArray` and marks it released.
/// Imported buffers are immutable views. Padding is trusted by CDI contract.
/// Pointer alignment is preserved as supplied by the producer.
pub fn importArray(allocator: Allocator, ty: datatype.DataType, arr: *ArrowArray) Error!*ArrayData {
    if (isReleased(arr)) return error.ReleasedArray;
    try ty.validate();

    const owner = try allocator.create(ImportedArrayOwner);
    owner.* = undefined;
    owner.allocator = allocator;
    owner.moved_valid = false;
    owner.handle = ExternalOwnerHandle.init(owner, releaseImportedArrayOwner);

    errdefer owner.handle.deinit();

    const data = try importArrayNode(allocator, ty, arr, &owner.handle);
    errdefer data.deinit();

    try data.validate();

    owner.moved = arr.*;
    owner.moved_valid = true;
    arr.release = null;
    arr.private_data = null;

    owner.handle.deinit();
    return data;
}

pub fn isReleased(arr: *const ArrowArray) bool {
    return arr.release == null;
}

fn importArrayNode(
    allocator: Allocator,
    ty: datatype.DataType,
    arr: *ArrowArray,
    owner: *ExternalOwnerHandle,
) Error!*ArrayData {
    if (isReleased(arr)) return error.ReleasedArray;

    const len = try importLength(arr.length);
    const offset = try importOffset(arr.offset);
    const null_count = try importNullCount(ty, arr.null_count, len);
    const layout = ty.layout();

    if (arr.n_buffers < 0) return error.InvalidBufferCount;
    const n_buffers = try i64ToUsize(arr.n_buffers);
    if (n_buffers != layout.buffers.len) return error.InvalidBufferCount;
    if (layout.buffers.len > 0 and arr.buffers == null) return error.InvalidBufferCount;

    const child_count = ty.childCount();
    if (arr.n_children < 0) return error.InvalidChildCount;
    const n_children = try i64ToUsize(arr.n_children);
    if (n_children != child_count) return error.InvalidChildCount;
    if (child_count > 0 and arr.children == null) return error.InvalidChildCount;

    if (layout.has_dictionary) {
        if (arr.dictionary == null) return error.MissingDictionary;
    } else if (arr.dictionary != null) {
        return error.UnexpectedDictionary;
    }

    const buffers = try allocator.alloc(?*Buffer, layout.buffers.len);
    defer allocator.free(buffers);
    @memset(buffers, null);

    var objects_owned = false;
    errdefer if (!objects_owned) {
        for (buffers) |buf| {
            if (buf) |b| b.deinit();
        }
    };

    for (layout.buffers, 0..) |spec, i| {
        buffers[i] = try importBuffer(allocator, owner, ty, arr, spec, i, len, offset);
    }

    const children = try allocator.alloc(*ArrayData, child_count);
    defer allocator.free(children);

    var imported_children: usize = 0;
    errdefer if (!objects_owned) {
        for (children[0..imported_children]) |child| child.deinit();
    };

    for (0..child_count) |i| {
        const child_ty = childFieldAt(ty, i).?.type.*;
        children[i] = try importArrayNode(allocator, child_ty, arr.children.?[i], owner);
        imported_children += 1;
    }

    var dictionary: ?*ArrayData = null;
    errdefer if (!objects_owned) {
        if (dictionary) |dict| dict.deinit();
    };

    if (layout.has_dictionary) {
        const dict_ty = ty.dictionary.value_type.*;
        dictionary = try importArrayNode(allocator, dict_ty, arr.dictionary.?, owner);
    }

    const data = try ArrayData.initOwnedExternal(
        allocator,
        ty,
        len,
        offset,
        null_count,
        buffers,
        children,
        dictionary,
        owner,
    );
    objects_owned = true;
    return data;
}

fn importBuffer(
    allocator: Allocator,
    owner: *ExternalOwnerHandle,
    ty: datatype.DataType,
    arr: *const ArrowArray,
    spec: datatype.BufferSpec,
    index: usize,
    len: usize,
    offset: usize,
) Error!?*Buffer {
    const size = try visibleBufferSize(ty, arr, spec, index, len, offset);
    const ptr = arr.buffers.?[index] orelse {
        if (spec.kind == .validity) return null;
        if (size == 0) return wrapImportedBuffer(allocator, owner, &.{});
        return missingBufferError(spec.kind);
    };
    const bytes: [*]const u8 = @ptrCast(ptr);
    return wrapImportedBuffer(allocator, owner, bytes[0..size]);
}

fn wrapImportedBuffer(
    allocator: Allocator,
    owner: *ExternalOwnerHandle,
    bytes: []const u8,
) Allocator.Error!*Buffer {
    return Buffer.wrapConst(allocator, owner, bytes.len, bytes) catch |err| switch (err) {
        error.SizeExceedsCapacity => unreachable,
        else => |e| return e,
    };
}

fn visibleBufferSize(
    ty: datatype.DataType,
    arr: *const ArrowArray,
    spec: datatype.BufferSpec,
    index: usize,
    len: usize,
    offset: usize,
) Error!usize {
    const total = try checked.add(offset, len);
    return switch (spec.kind) {
        .validity => if (len == 0) 0 else try bitmap.byteLenChecked(total),
        .values => try valuesBufferSize(ty, arr, spec, len, total),
        .offsets => try offsetsBufferSize(arr, index, spec.byte_width, len, total),
        .type_ids, .union_offsets => try checked.mul(total, spec.byte_width),
    };
}

fn valuesBufferSize(
    ty: datatype.DataType,
    arr: *const ArrowArray,
    spec: datatype.BufferSpec,
    len: usize,
    total: usize,
) Error!usize {
    if (len == 0) return 0;
    if (spec.bit_width == 1) return try bitmap.byteLenChecked(total);
    if (spec.byte_width != 0) return try checked.mul(total, spec.byte_width);
    const offset_width: usize = switch (ty) {
        .binary, .utf8 => @sizeOf(i32),
        .large_binary, .large_utf8 => @sizeOf(i64),
        else => unreachable,
    };
    const offsets = arr.buffers.?[1] orelse return error.MissingOffsetsBuffer;
    return try readOffsetAt(offsets, total, offset_width);
}

fn offsetsBufferSize(
    arr: *const ArrowArray,
    index: usize,
    byte_width: usize,
    len: usize,
    total: usize,
) Error!usize {
    if (len == 0) return 0;
    if (arr.buffers.?[index] == null) return error.MissingOffsetsBuffer;
    return try checked.mul(try checked.add(total, 1), byte_width);
}

fn readOffsetAt(ptr: *const anyopaque, index: usize, byte_width: usize) Error!usize {
    const bytes: [*]const u8 = @ptrCast(ptr);
    const start = try checked.mul(index, byte_width);
    return switch (byte_width) {
        @sizeOf(i32) => try signedOffsetToUsize(std.mem.readInt(i32, bytes[start..][0..@sizeOf(i32)], .little)),
        @sizeOf(i64) => try signedOffsetToUsize(std.mem.readInt(i64, bytes[start..][0..@sizeOf(i64)], .little)),
        else => unreachable,
    };
}

fn signedOffsetToUsize(value: anytype) Error!usize {
    if (value < 0) return error.NegativeOffset;
    if (@as(u128, @intCast(value)) > @as(u128, std.math.maxInt(usize))) return error.ValueOutOfRange;
    return @intCast(value);
}

fn missingBufferError(kind: datatype.BufferKind) Error {
    return switch (kind) {
        .validity => unreachable,
        .values => error.MissingValuesBuffer,
        .offsets => error.MissingOffsetsBuffer,
        .type_ids => error.MissingTypeIdsBuffer,
        .union_offsets => error.MissingUnionOffsetsBuffer,
    };
}

fn importLength(value: i64) Error!usize {
    if (value < 0) return error.NegativeLength;
    return i64ToUsize(value);
}

fn importOffset(value: i64) Error!usize {
    if (value < 0) return error.NegativeOffset;
    return i64ToUsize(value);
}

fn importNullCount(ty: datatype.DataType, value: i64, len: usize) Error!usize {
    if (value == -1) return if (ty.id() == .null_) len else array.unknown_null_count;
    if (value < -1) return error.InvalidNullCount;
    const null_count = try i64ToUsize(value);
    if (null_count > len) return error.NullCountOutOfBounds;
    return null_count;
}

fn i64ToUsize(value: i64) Error!usize {
    const unsigned: u64 = @intCast(value);
    if (@as(u128, unsigned) > @as(u128, std.math.maxInt(usize))) return error.ValueOutOfRange;
    return @intCast(unsigned);
}

fn releaseImportedArrayOwner(ctx_ptr: *anyopaque) void {
    const owner: *ImportedArrayOwner = @ptrCast(@alignCast(ctx_ptr));
    const allocator = owner.allocator;
    if (owner.moved_valid) releaseIfNeeded(&owner.moved);
    allocator.destroy(owner);
}

fn releaseIfNeeded(arr: *ArrowArray) void {
    if (arr.release) |release_fn| release_fn(arr);
}

fn childFieldAt(ty: datatype.DataType, index: usize) ?datatype.Field {
    return switch (ty) {
        .list => |meta| if (index == 0) meta.child else null,
        .large_list => |meta| if (index == 0) meta.child else null,
        .fixed_size_list => |meta| if (index == 0) meta.child else null,
        .struct_ => |meta| if (index < meta.fields.len) meta.fields[index] else null,
        .sparse_union => |meta| if (index < meta.fields.len) meta.fields[index] else null,
        .dense_union => |meta| if (index < meta.fields.len) meta.fields[index] else null,
        else => null,
    };
}
