// Copyright 2026 Filippo Rossi
// SPDX-License-Identifier: Apache-2.0

//! Arrow C Data Interface array export.

const std = @import("std");
const Allocator = std.mem.Allocator;
const array = @import("../array.zig");
const buffer = @import("../buffer.zig");
const checked = @import("../checked.zig");
const cdi_types = @import("types.zig");
const schema_export = @import("schema_export.zig");

const ArrayData = array.ArrayData;
const ArrowArray = cdi_types.ArrowArray;
const Buffer = buffer.Buffer;

pub const Error = schema_export.Error || array.ValidateError || checked.Error;

pub fn exportArray(allocator: Allocator, data: *ArrayData, out: *ArrowArray) Error!void {
    try data.validate();

    const length = try usizeToI64(data.len);
    const null_count: i64 = if (data.null_count == array.unknown_null_count) -1 else try usizeToI64(data.null_count);
    const offset = try usizeToI64(data.offset);
    const n_buffers = try usizeToI64(data.buffers.len);
    const n_children = try usizeToI64(data.children.len);

    const buffers = try allocator.alloc(?*const anyopaque, data.buffers.len);
    errdefer allocator.free(buffers);

    for (data.buffers, 0..) |buf, i| {
        buffers[i] = if (buf) |b| bufferPointer(b) else null;
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

fn usizeToI64(value: usize) Error!i64 {
    if (value > @as(usize, @intCast(std.math.maxInt(i64)))) return error.ValueOutOfRange;
    return @intCast(value);
}
