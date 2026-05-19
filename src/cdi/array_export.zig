// Copyright 2026 Filippo Rossi
// SPDX-License-Identifier: Apache-2.0

//! Arrow C Data Interface array export.

const std = @import("std");
const Allocator = std.mem.Allocator;
const array = @import("../array.zig");
const array_data = @import("../array/data.zig");
const buffer = @import("../buffer.zig");
const checked = @import("../checked.zig");
const cdi_types = @import("types.zig");
const datatype = @import("../datatype.zig");
const schema_export = @import("schema_export.zig");

const ArrayData = array.ArrayData;
const ArrowArray = cdi_types.ArrowArray;
const Buffer = buffer.Buffer;

pub const Error = schema_export.Error || array_data.ValidateError || checked.Error;

pub fn exportArray(allocator: Allocator, data: *ArrayData, out: *ArrowArray) Error!void {
    try data.validate();

    const length = try usizeToI64(data.len);
    const null_count: i64 = if (data.null_count) |nc| try usizeToI64(nc) else -1;
    const offset = try usizeToI64(data.offset);
    const exports_binary_view = isBinaryViewLike(storageType(data.type));
    const exported_buffer_count = if (exports_binary_view) try checked.add(data.buffers.len, 1) else data.buffers.len;
    const n_buffers = try usizeToI64(exported_buffer_count);
    const n_children = try usizeToI64(data.children.len);

    const buffers = try allocator.alloc(?*const anyopaque, exported_buffer_count);
    errdefer allocator.free(buffers);

    for (data.buffers, 0..) |buf, i| {
        buffers[i] = if (buf) |b| bufferPointer(b) else null;
    }

    var buffer_sizes: ?[]i64 = null;
    errdefer if (buffer_sizes) |sizes| allocator.free(sizes);
    if (exports_binary_view) {
        const data_buffer_count = data.buffers.len - 2;
        const sizes = try allocator.alloc(i64, data_buffer_count);
        for (data.buffers[2..], 0..) |buf, i| {
            sizes[i] = if (buf) |b| try usizeToI64(b.size) else 0;
        }
        buffers[data.buffers.len] = if (sizes.len == 0) null else @ptrCast(sizes.ptr);
        buffer_sizes = sizes;
    }

    const children_storage = try allocator.alloc(ArrowArray, data.children.len);
    errdefer allocator.free(children_storage);

    const child_ptrs = try allocator.alloc(*ArrowArray, data.children.len);
    errdefer allocator.free(child_ptrs);

    var exported_children: usize = 0;
    errdefer releaseArrays(children_storage[0..exported_children]);

    for (data.children, 0..) |child, i| {
        try exportArray(allocator, child, &children_storage[i]);
        child_ptrs[i] = &children_storage[i];
        exported_children += 1;
    }

    var dictionary: ?*ArrowArray = null;
    var dictionary_exported = false;
    errdefer if (dictionary) |dict| {
        if (dictionary_exported) releaseIfNeeded(dict);
        allocator.destroy(dict);
    };

    if (data.dictionary) |dict_data| {
        dictionary = try allocator.create(ArrowArray);
        try exportArray(allocator, dict_data, dictionary.?);
        dictionary_exported = true;
    }

    const private = try allocator.create(ArrayPrivate);
    errdefer allocator.destroy(private);
    private.* = .{
        .allocator = allocator,
        .data = data.retain(),
        .buffers = buffers,
        .buffer_sizes = buffer_sizes,
        .children_storage = children_storage,
        .child_ptrs = child_ptrs,
        .dictionary = dictionary,
    };

    out.* = .{
        .length = length,
        .null_count = null_count,
        .offset = offset,
        .n_buffers = n_buffers,
        .n_children = n_children,
        .buffers = buffers.ptr,
        .children = if (child_ptrs.len == 0) null else child_ptrs.ptr,
        .dictionary = dictionary,
        .release = releaseArray,
        .private_data = private,
    };
}

pub fn isReleased(arr: *const ArrowArray) bool {
    return arr.release == null;
}

pub fn releaseIfNeeded(arr: *ArrowArray) void {
    if (arr.release) |release_fn| release_fn(arr);
}

pub fn released() ArrowArray {
    return .{
        .length = 0,
        .null_count = 0,
        .offset = 0,
        .n_buffers = 0,
        .n_children = 0,
        .buffers = null,
        .children = null,
        .dictionary = null,
        .release = null,
        .private_data = null,
    };
}

const ArrayPrivate = struct {
    allocator: Allocator,
    data: *ArrayData,
    buffers: []?*const anyopaque,
    buffer_sizes: ?[]i64,
    children_storage: []ArrowArray,
    child_ptrs: []*ArrowArray,
    dictionary: ?*ArrowArray,
};

fn releaseArray(arr: *ArrowArray) callconv(.c) void {
    if (arr.release == null) return;
    const private: *ArrayPrivate = @ptrCast(@alignCast(arr.private_data.?));
    const allocator = private.allocator;
    releaseArrays(private.children_storage);
    if (private.dictionary) |dict| {
        releaseIfNeeded(dict);
        allocator.destroy(dict);
    }
    private.data.deinit();
    if (private.buffer_sizes) |sizes| allocator.free(sizes);
    allocator.free(private.buffers);
    allocator.free(private.child_ptrs);
    allocator.free(private.children_storage);
    allocator.destroy(private);
    arr.release = null;
    arr.private_data = null;
}

fn releaseArrays(arrays: []ArrowArray) void {
    for (arrays) |*arr| releaseIfNeeded(arr);
}

fn bufferPointer(buf: *const Buffer) ?*const anyopaque {
    if (buf.size == 0) return null;
    return @ptrCast(buf.data);
}

fn isBinaryViewLike(ty: datatype.DataType) bool {
    return ty == .binary_view or ty == .utf8_view;
}

fn storageType(ty: datatype.DataType) datatype.DataType {
    return switch (ty) {
        .extension => |meta| storageType(meta.storage_type.*),
        else => ty,
    };
}

fn usizeToI64(value: usize) Error!i64 {
    if (value > @as(usize, @intCast(std.math.maxInt(i64)))) return error.ValueOutOfRange;
    return @intCast(value);
}
