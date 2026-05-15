// Copyright 2026 Filippo Rossi
// SPDX-License-Identifier: Apache-2.0

//! Arrow C Data Interface array stream import and export.

const std = @import("std");
const Allocator = std.mem.Allocator;
const array = @import("../array.zig");
const array_export = @import("array_export.zig");
const array_import = @import("array_import.zig");
const cdi_types = @import("types.zig");
const datatype = @import("../datatype.zig");
const schema_export = @import("schema_export.zig");
const schema_import = @import("schema_import.zig");

const ArrayData = array.ArrayData;
const ArrowArray = cdi_types.ArrowArray;
const ArrowArrayStream = cdi_types.ArrowArrayStream;
const ArrowSchema = cdi_types.ArrowSchema;

pub const ExportError = array_export.Error || error{ArrayTypeMismatch};
pub const ImportError = schema_import.Error || array_import.Error || error{
    ReleasedArrayStream,
    MissingCallback,
    StreamCallbackFailed,
};

const stream_success: c_int = 0;
const stream_error_nomem: c_int = 12;
const stream_error_invalid: c_int = 22;
const stream_last_error_callback_failed: [*:0]const u8 = "ArrowArrayStream callback failed";

const ArrayStreamPrivate = struct {
    allocator: Allocator,
    type: datatype.DataType,
    arrays: []*ArrayData,
    index: usize,
    last_error: ?[*:0]const u8,
};

pub const ImportedArrayStream = struct {
    allocator: Allocator,
    type: datatype.DataType,
    stream: ArrowArrayStream,

    /// Import the next array. Returns null at end of stream.
    /// The caller owns the returned `ArrayData` reference.
    pub fn next(self: *ImportedArrayStream) ImportError!?*ArrayData {
        if (isReleased(&self.stream)) return error.ReleasedArrayStream;
        const get_next = self.stream.get_next orelse return error.MissingCallback;

        var arr: ArrowArray = array_export.released();
        const code = get_next(&self.stream, &arr);
        errdefer array_export.releaseIfNeeded(&arr);
        if (code != stream_success) return error.StreamCallbackFailed;
        if (array_export.isReleased(&arr)) return null;
        return try array_import.importArray(self.allocator, self.type, &arr);
    }

    /// Release the moved C stream and imported schema type.
    pub fn deinit(self: *ImportedArrayStream) void {
        const allocator = self.allocator;
        releaseIfNeeded(&self.stream);
        datatype.deinitOwned(allocator, &self.type);
        allocator.destroy(self);
    }
};

pub fn exportArrayStream(
    allocator: Allocator,
    ty: datatype.DataType,
    arrays: []const *ArrayData,
    out: *ArrowArrayStream,
) ExportError!void {
    try ty.validate();

    var owned_type = try datatype.cloneOwned(allocator, ty);
    errdefer datatype.deinitOwned(allocator, &owned_type);

    const retained_arrays = try allocator.alloc(*ArrayData, arrays.len);
    errdefer allocator.free(retained_arrays);

    var retained_count: usize = 0;
    errdefer {
        for (retained_arrays[0..retained_count]) |array_data| array_data.deinit();
    }

    for (arrays, 0..) |array_data, i| {
        try array_data.validate();
        if (!datatype.DataType.equals(ty, array_data.type)) return error.ArrayTypeMismatch;
        retained_arrays[i] = array_data.retain();
        retained_count += 1;
    }

    const private = try allocator.create(ArrayStreamPrivate);
    errdefer allocator.destroy(private);
    private.* = .{
        .allocator = allocator,
        .type = owned_type,
        .arrays = retained_arrays,
        .index = 0,
        .last_error = null,
    };

    out.* = .{
        .get_schema = streamGetSchema,
        .get_next = streamGetNext,
        .get_last_error = streamGetLastError,
        .release = releaseArrayStream,
        .private_data = private,
    };
}

pub fn importArrayStream(allocator: Allocator, stream: *ArrowArrayStream) ImportError!*ImportedArrayStream {
    if (isReleased(stream)) return error.ReleasedArrayStream;
    const get_schema = stream.get_schema orelse return error.MissingCallback;
    if (stream.get_next == null) return error.MissingCallback;

    var schema = schema_export.released();
    const code = get_schema(stream, &schema);
    defer schema_export.releaseIfNeeded(&schema);
    if (code != stream_success) return error.StreamCallbackFailed;

    var ty = try schema_import.importType(allocator, &schema);
    var ty_owned = true;
    errdefer if (ty_owned) datatype.deinitOwned(allocator, &ty);

    const imported = try allocator.create(ImportedArrayStream);
    errdefer allocator.destroy(imported);

    imported.* = .{
        .allocator = allocator,
        .type = ty,
        .stream = stream.*,
    };
    ty_owned = false;

    stream.release = null;
    stream.private_data = null;
    return imported;
}

pub fn isReleased(stream: *const ArrowArrayStream) bool {
    return stream.release == null;
}

fn releaseIfNeeded(stream: *ArrowArrayStream) void {
    if (stream.release) |release_fn| release_fn(stream);
}

fn streamGetSchema(stream: *ArrowArrayStream, out: *ArrowSchema) callconv(.c) c_int {
    out.* = schema_export.released();
    const private = streamPrivate(stream) orelse return stream_error_invalid;
    private.last_error = null;
    schema_export.exportType(private.allocator, private.type, out) catch |err| {
        private.last_error = stream_last_error_callback_failed;
        return streamErrorCode(err);
    };
    return stream_success;
}

fn streamGetNext(stream: *ArrowArrayStream, out: *ArrowArray) callconv(.c) c_int {
    out.* = array_export.released();
    const private = streamPrivate(stream) orelse return stream_error_invalid;
    private.last_error = null;

    if (private.index >= private.arrays.len) return stream_success;
    const array_data = private.arrays[private.index];
    array_export.exportArray(private.allocator, array_data, out) catch |err| {
        private.last_error = stream_last_error_callback_failed;
        return streamErrorCode(err);
    };
    private.index += 1;
    return stream_success;
}

fn streamGetLastError(stream: *ArrowArrayStream) callconv(.c) ?[*:0]const u8 {
    const private = streamPrivate(stream) orelse return stream_last_error_callback_failed;
    return private.last_error;
}

fn releaseArrayStream(stream: *ArrowArrayStream) callconv(.c) void {
    if (stream.release == null) return;
    const private: *ArrayStreamPrivate = @ptrCast(@alignCast(stream.private_data.?));
    const allocator = private.allocator;
    for (private.arrays) |array_data| array_data.deinit();
    allocator.free(private.arrays);
    datatype.deinitOwned(allocator, &private.type);
    allocator.destroy(private);
    stream.release = null;
    stream.private_data = null;
}

fn streamPrivate(stream: *ArrowArrayStream) ?*ArrayStreamPrivate {
    const private_data = stream.private_data orelse return null;
    if (stream.release == null) return null;
    return @ptrCast(@alignCast(private_data));
}

fn streamErrorCode(err: anyerror) c_int {
    return switch (err) {
        error.OutOfMemory => stream_error_nomem,
        else => stream_error_invalid,
    };
}
