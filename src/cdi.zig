// Copyright 2026 Filippo Rossi
// SPDX-License-Identifier: Apache-2.0

//! Arrow C Data Interface import and export.
//!
//! Export copies schemas into C Data Interface structs and retains exported
//! array storage until the C release callback is invoked.
//!
//! Schema import copies C Data Interface schemas into owned `DataType`,
//! `Field`, or `Schema` values. Array import consumes only the top level
//! `ArrowArray` on success and keeps its release callback alive until imported
//! data and buffers are dropped.
//!
//! Array stream import consumes the top level `ArrowArrayStream` on success.
//! Exported streams are one pass and retain their source arrays until release.
//!
//! Export one array to CDI, then import it back without copying buffers.
//!
//! ```zig
//! var out: arrow.cdi.ArrowArray = undefined;
//! try arrow.cdi.exportArray(allocator, data, &out);
//! errdefer if (out.release) |release| release(&out);
//!
//! const imported = try arrow.cdi.importArray(allocator, data.type, &out);
//! defer imported.deinit();
//! ```
//!
//! Stream export retains each array until the stream is released or consumed by
//! `importArrayStream`.
//!
//! ```zig
//! var stream: arrow.cdi.ArrowArrayStream = undefined;
//! try arrow.cdi.exportArrayStream(allocator, data.type, &.{data}, &stream);
//! errdefer if (stream.release) |release| release(&stream);
//!
//! const imported_stream = try arrow.cdi.importArrayStream(allocator, &stream);
//! defer imported_stream.deinit();
//!
//! while (try imported_stream.next()) |data| {
//!     defer data.deinit();
//!     const values = try arrow.array.NumericArray(i32).fromData(data);
//!     _ = values;
//! }
//! ```

const std = @import("std");
const Allocator = std.mem.Allocator;
const array = @import("array.zig");
const bitmap = @import("bitmap.zig");
const buffer = @import("buffer.zig");
const cdi_metadata = @import("cdi/metadata.zig");
const cdi_types = @import("cdi/types.zig");
const schema_import = @import("cdi/schema_import.zig");
const checked = @import("checked.zig");
const datatype = @import("datatype.zig");
const schema_mod = @import("schema.zig");

const ArrayData = array.ArrayData;
const Buffer = buffer.Buffer;
const ExternalOwnerHandle = buffer.ExternalOwnerHandle;
const Schema = schema_mod.Schema;

pub const schema_flag_dictionary_ordered = cdi_types.schema_flag_dictionary_ordered;
pub const schema_flag_nullable = cdi_types.schema_flag_nullable;

pub const SchemaExportError = cdi_metadata.ExportError || datatype.ValidationError;
pub const SchemaImportError = schema_import.Error;

pub const ArrayExportError = SchemaExportError || array.ValidateError || checked.Error;
pub const ArrayImportError =
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
pub const SchemaArrayImportError = SchemaImportError || ArrayImportError;
pub const ArrayStreamExportError = ArrayExportError || error{ArrayTypeMismatch};
pub const ArrayStreamImportError = SchemaImportError || ArrayImportError || error{
    ReleasedArrayStream,
    MissingCallback,
    StreamCallbackFailed,
};

pub const ArrowSchema = cdi_types.ArrowSchema;
pub const ArrowArray = cdi_types.ArrowArray;
pub const ArrowArrayStream = cdi_types.ArrowArrayStream;

const stream_success: c_int = 0;
const stream_error_nomem: c_int = 12;
const stream_error_invalid: c_int = 22;
const stream_last_error_callback_failed: [*:0]const u8 = "ArrowArrayStream callback failed";

const SchemaPrivate = struct {
    allocator: Allocator,
    format: [:0]u8,
    name: ?[:0]u8,
    metadata: ?[]u8,
    children_storage: []ArrowSchema,
    child_ptrs: []*ArrowSchema,
    dictionary: ?*ArrowSchema,
};

const ArrayPrivate = struct {
    allocator: Allocator,
    data: *ArrayData,
    buffers: []?*const anyopaque,
    children_storage: []ArrowArray,
    child_ptrs: []*ArrowArray,
    dictionary: ?*ArrowArray,
};

const ArrayStreamPrivate = struct {
    allocator: Allocator,
    type: datatype.DataType,
    arrays: []*ArrayData,
    index: usize,
    last_error: ?[*:0]const u8,
};

// Children and dictionaries stay owned by the moved top level ArrowArray.
const ImportedArrayOwner = struct {
    allocator: Allocator,
    handle: ExternalOwnerHandle,
    moved: ArrowArray,
    moved_valid: bool,
};

pub const ImportedArrayStream = struct {
    allocator: Allocator,
    type: datatype.DataType,
    stream: ArrowArrayStream,

    /// Import the next array. Returns null at end of stream.
    /// The caller owns the returned `ArrayData` reference.
    pub fn next(self: *ImportedArrayStream) ArrayStreamImportError!?*ArrayData {
        if (arrayStreamIsReleased(&self.stream)) return error.ReleasedArrayStream;
        const get_next = self.stream.get_next orelse return error.MissingCallback;

        var arr: ArrowArray = releasedArray();
        const code = get_next(&self.stream, &arr);
        errdefer releaseArrayIfNeeded(&arr);
        if (code != stream_success) return error.StreamCallbackFailed;
        if (arrayIsReleased(&arr)) return null;
        return try importArray(self.allocator, self.type, &arr);
    }

    /// Release the moved C stream and imported schema type.
    pub fn deinit(self: *ImportedArrayStream) void {
        const allocator = self.allocator;
        releaseArrayStreamIfNeeded(&self.stream);
        datatype.deinitOwned(allocator, &self.type);
        allocator.destroy(self);
    }
};

/// Export a data type as an `ArrowSchema`.
/// The caller must release `out` unless ownership is transferred.
pub fn exportType(allocator: Allocator, ty: datatype.DataType, out: *ArrowSchema) SchemaExportError!void {
    try exportSchemaNode(allocator, ty, null, true, &.{}, out);
}

/// Export a field as an `ArrowSchema`.
/// The caller must release `out` unless ownership is transferred.
pub fn exportField(allocator: Allocator, field: datatype.Field, out: *ArrowSchema) SchemaExportError!void {
    try exportSchemaNode(allocator, field.type.*, field, field.nullable, field.metadata, out);
}

/// Export a schema as a struct `ArrowSchema`.
/// The caller must release `out` unless ownership is transferred.
pub fn exportSchema(allocator: Allocator, input_schema: *const Schema, out: *ArrowSchema) SchemaExportError!void {
    try input_schema.validate();
    const ty = datatype.DataType{ .struct_ = .{ .fields = input_schema.fields() } };
    try exportSchemaNode(allocator, ty, null, false, input_schema.metadata(), out);
}

/// Import a C Data Interface schema into an owned data type.
/// The schema is not consumed. Deinitialize the returned type with
/// `datatype.deinitOwned()` when done.
pub fn importType(allocator: Allocator, schema: *const ArrowSchema) SchemaImportError!datatype.DataType {
    return schema_import.importType(allocator, schema);
}

/// Import a C Data Interface schema into an owned field.
/// The schema is not consumed. Deinitialize the returned field with
/// `datatype.deinitOwnedField()` when done.
pub fn importField(allocator: Allocator, schema: *const ArrowSchema) SchemaImportError!datatype.Field {
    return schema_import.importField(allocator, schema);
}

/// Import a C Data Interface schema into an owned schema.
/// The schema is not consumed. Deinitialize the returned schema when done.
pub fn importSchema(allocator: Allocator, schema: *const ArrowSchema) SchemaImportError!*Schema {
    return schema_import.importSchema(allocator, schema);
}

/// Import a C Data Interface array by first importing its schema.
/// On success, consumes only the top level `ArrowArray`.
pub fn importArrayFromSchema(allocator: Allocator, schema: *const ArrowSchema, arr: *ArrowArray) SchemaArrayImportError!*ArrayData {
    var ty = try importType(allocator, schema);
    defer datatype.deinitOwned(allocator, &ty);
    return try importArray(allocator, ty, arr);
}

/// Import a C Data Interface array stream.
/// On success, consumes the top level `ArrowArrayStream`.
/// Deinitialize the returned stream when done.
pub fn importArrayStream(allocator: Allocator, stream: *ArrowArrayStream) ArrayStreamImportError!*ImportedArrayStream {
    if (arrayStreamIsReleased(stream)) return error.ReleasedArrayStream;
    const get_schema = stream.get_schema orelse return error.MissingCallback;
    if (stream.get_next == null) return error.MissingCallback;

    var schema = releasedSchema();
    const code = get_schema(stream, &schema);
    defer releaseSchemaIfNeeded(&schema);
    if (code != stream_success) return error.StreamCallbackFailed;

    var ty = try importType(allocator, &schema);
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

fn exportSchemaNode(
    allocator: Allocator,
    ty: datatype.DataType,
    field: ?datatype.Field,
    nullable: bool,
    metadata: []const datatype.MetadataEntry,
    out: *ArrowSchema,
) SchemaExportError!void {
    try ty.validate();
    const format = try formatForType(allocator, ty);
    errdefer allocator.free(format);

    const owned_name = if (field) |f| try allocator.dupeZ(u8, f.name) else null;
    errdefer if (owned_name) |name| allocator.free(name);

    const owned_metadata = try cdi_metadata.exportOwned(allocator, metadata);
    errdefer if (owned_metadata) |data| allocator.free(data);

    const child_count = ty.childCount();
    const n_children = try usizeToI64(child_count);
    const children_storage = try allocator.alloc(ArrowSchema, child_count);
    errdefer allocator.free(children_storage);

    const child_ptrs = try allocator.alloc(*ArrowSchema, child_count);
    errdefer allocator.free(child_ptrs);

    var exported_children: usize = 0;
    errdefer releaseSchemas(children_storage[0..exported_children]);

    for (0..child_count) |i| {
        const child_field = childFieldAt(ty, i).?;
        try exportField(allocator, child_field, &children_storage[i]);
        child_ptrs[i] = &children_storage[i];
        exported_children += 1;
    }

    var dictionary: ?*ArrowSchema = null;
    var dictionary_exported = false;
    errdefer if (dictionary) |dict| {
        if (dictionary_exported) releaseSchemaIfNeeded(dict);
        allocator.destroy(dict);
    };

    var flags: i64 = if (nullable) schema_flag_nullable else 0;
    switch (ty) {
        .dictionary => |meta| {
            if (meta.ordered) flags |= schema_flag_dictionary_ordered;
            dictionary = try allocator.create(ArrowSchema);
            try exportType(allocator, meta.value_type.*, dictionary.?);
            dictionary_exported = true;
        },
        else => {},
    }

    const private = try allocator.create(SchemaPrivate);
    errdefer allocator.destroy(private);
    private.* = .{
        .allocator = allocator,
        .format = format,
        .name = owned_name,
        .metadata = owned_metadata,
        .children_storage = children_storage,
        .child_ptrs = child_ptrs,
        .dictionary = dictionary,
    };

    out.* = .{
        .format = format.ptr,
        .name = if (owned_name) |name| name.ptr else null,
        .metadata = if (owned_metadata) |data| data.ptr else null,
        .flags = flags,
        .n_children = n_children,
        .children = if (child_ptrs.len == 0) null else child_ptrs.ptr,
        .dictionary = dictionary,
        .release = releaseSchema,
        .private_data = private,
    };
}

/// Export array storage as an `ArrowArray`.
/// The export retains `data` until the C release callback is invoked.
pub fn exportArray(allocator: Allocator, data: *ArrayData, out: *ArrowArray) ArrayExportError!void {
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
        if (dictionary_exported) releaseArrayIfNeeded(dict);
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

/// Export a one pass C Data Interface array stream.
/// The stream retains each array until `release` is called.
/// Each `get_next` call exports the next retained array, then a released
/// `ArrowArray` marks end of stream.
pub fn exportArrayStream(
    allocator: Allocator,
    ty: datatype.DataType,
    arrays: []const *ArrayData,
    out: *ArrowArrayStream,
) ArrayStreamExportError!void {
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

/// Import one typed Arrow C Data Interface array without copying buffers.
/// On success, consumes only the top level `ArrowArray` and marks it released.
/// The moved C array is released when the last imported data or buffer drops.
pub fn importArray(allocator: Allocator, ty: datatype.DataType, arr: *ArrowArray) ArrayImportError!*ArrayData {
    if (arrayIsReleased(arr)) return error.ReleasedArray;
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

/// True when an `ArrowSchema` has no release callback.
pub fn schemaIsReleased(schema: *const ArrowSchema) bool {
    return schema.release == null;
}

/// True when an `ArrowArray` has no release callback.
pub fn arrayIsReleased(arr: *const ArrowArray) bool {
    return arr.release == null;
}

/// True when an `ArrowArrayStream` has no release callback.
pub fn arrayStreamIsReleased(stream: *const ArrowArrayStream) bool {
    return stream.release == null;
}

fn importArrayNode(
    allocator: Allocator,
    ty: datatype.DataType,
    arr: *ArrowArray,
    owner: *ExternalOwnerHandle,
) ArrayImportError!*ArrayData {
    if (arrayIsReleased(arr)) return error.ReleasedArray;

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
) ArrayImportError!?*Buffer {
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
) ArrayImportError!usize {
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
) ArrayImportError!usize {
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
) ArrayImportError!usize {
    if (len == 0) return 0;
    if (arr.buffers.?[index] == null) return error.MissingOffsetsBuffer;
    return try checked.mul(try checked.add(total, 1), byte_width);
}

fn readOffsetAt(ptr: *const anyopaque, index: usize, byte_width: usize) ArrayImportError!usize {
    const bytes: [*]const u8 = @ptrCast(ptr);
    const start = try checked.mul(index, byte_width);
    return switch (byte_width) {
        @sizeOf(i32) => try signedOffsetToUsize(std.mem.readInt(i32, bytes[start..][0..@sizeOf(i32)], .little)),
        @sizeOf(i64) => try signedOffsetToUsize(std.mem.readInt(i64, bytes[start..][0..@sizeOf(i64)], .little)),
        else => unreachable,
    };
}

fn signedOffsetToUsize(value: anytype) ArrayImportError!usize {
    if (value < 0) return error.NegativeOffset;
    if (@as(u128, @intCast(value)) > @as(u128, std.math.maxInt(usize))) return error.ValueOutOfRange;
    return @intCast(value);
}

fn missingBufferError(kind: datatype.BufferKind) ArrayImportError {
    return switch (kind) {
        .validity => unreachable,
        .values => error.MissingValuesBuffer,
        .offsets => error.MissingOffsetsBuffer,
        .type_ids => error.MissingTypeIdsBuffer,
        .union_offsets => error.MissingUnionOffsetsBuffer,
    };
}

fn importLength(value: i64) ArrayImportError!usize {
    if (value < 0) return error.NegativeLength;
    return i64ToUsize(value);
}

fn importOffset(value: i64) ArrayImportError!usize {
    if (value < 0) return error.NegativeOffset;
    return i64ToUsize(value);
}

fn importNullCount(ty: datatype.DataType, value: i64, len: usize) ArrayImportError!usize {
    if (value == -1) return if (ty.id() == .null_) len else array.unknown_null_count;
    if (value < -1) return error.InvalidNullCount;
    const null_count = try i64ToUsize(value);
    if (null_count > len) return error.NullCountOutOfBounds;
    return null_count;
}

fn i64ToUsize(value: i64) ArrayImportError!usize {
    const unsigned: u64 = @intCast(value);
    if (@as(u128, unsigned) > @as(u128, std.math.maxInt(usize))) return error.ValueOutOfRange;
    return @intCast(unsigned);
}

fn releaseImportedArrayOwner(ctx_ptr: *anyopaque) void {
    const owner: *ImportedArrayOwner = @ptrCast(@alignCast(ctx_ptr));
    const allocator = owner.allocator;
    if (owner.moved_valid) releaseArrayIfNeeded(&owner.moved);
    allocator.destroy(owner);
}

fn releaseSchema(schema: *ArrowSchema) callconv(.c) void {
    if (schema.release == null) return;
    const private: *SchemaPrivate = @ptrCast(@alignCast(schema.private_data.?));
    const allocator = private.allocator;
    releaseSchemas(private.children_storage);
    if (private.dictionary) |dict| {
        releaseSchemaIfNeeded(dict);
        allocator.destroy(dict);
    }
    allocator.free(private.format);
    if (private.name) |name| allocator.free(name);
    if (private.metadata) |metadata| allocator.free(metadata);
    allocator.free(private.child_ptrs);
    allocator.free(private.children_storage);
    allocator.destroy(private);
    schema.release = null;
    schema.private_data = null;
}

fn releaseArray(arr: *ArrowArray) callconv(.c) void {
    if (arr.release == null) return;
    const private: *ArrayPrivate = @ptrCast(@alignCast(arr.private_data.?));
    const allocator = private.allocator;
    releaseArrays(private.children_storage);
    if (private.dictionary) |dict| {
        releaseArrayIfNeeded(dict);
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

fn streamGetSchema(stream: *ArrowArrayStream, out: *ArrowSchema) callconv(.c) c_int {
    out.* = releasedSchema();
    const private = streamPrivate(stream) orelse return stream_error_invalid;
    private.last_error = null;
    exportType(private.allocator, private.type, out) catch |err| {
        private.last_error = stream_last_error_callback_failed;
        return streamErrorCode(err);
    };
    return stream_success;
}

fn streamGetNext(stream: *ArrowArrayStream, out: *ArrowArray) callconv(.c) c_int {
    out.* = releasedArray();
    const private = streamPrivate(stream) orelse return stream_error_invalid;
    private.last_error = null;

    if (private.index >= private.arrays.len) return stream_success;
    const array_data = private.arrays[private.index];
    exportArray(private.allocator, array_data, out) catch |err| {
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

fn releasedSchema() ArrowSchema {
    return .{
        .format = null,
        .name = null,
        .metadata = null,
        .flags = 0,
        .n_children = 0,
        .children = null,
        .dictionary = null,
        .release = null,
        .private_data = null,
    };
}

fn releasedArray() ArrowArray {
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

fn streamErrorCode(err: anyerror) c_int {
    return switch (err) {
        error.OutOfMemory => stream_error_nomem,
        else => stream_error_invalid,
    };
}

fn releaseSchemas(schemas: []ArrowSchema) void {
    for (schemas) |*schema| releaseSchemaIfNeeded(schema);
}

fn releaseSchemaIfNeeded(schema: *ArrowSchema) void {
    if (schema.release) |release| release(schema);
}

fn releaseArrays(arrays: []ArrowArray) void {
    for (arrays) |*arr| releaseArrayIfNeeded(arr);
}

fn releaseArrayIfNeeded(arr: *ArrowArray) void {
    if (arr.release) |release| release(arr);
}

fn releaseArrayStreamIfNeeded(stream: *ArrowArrayStream) void {
    if (stream.release) |release| release(stream);
}

fn bufferPointer(buf: *const Buffer) ?*const anyopaque {
    if (buf.size == 0) return null;
    return @ptrCast(buf.data);
}

fn usizeToI64(value: usize) !i64 {
    if (value > @as(usize, @intCast(std.math.maxInt(i64)))) return error.ValueOutOfRange;
    return @intCast(value);
}

fn formatForType(allocator: Allocator, ty: datatype.DataType) SchemaExportError![:0]u8 {
    return switch (ty) {
        .null_ => allocator.dupeZ(u8, "n"),
        .bool => allocator.dupeZ(u8, "b"),
        .int8 => allocator.dupeZ(u8, "c"),
        .uint8 => allocator.dupeZ(u8, "C"),
        .int16 => allocator.dupeZ(u8, "s"),
        .uint16 => allocator.dupeZ(u8, "S"),
        .int32 => allocator.dupeZ(u8, "i"),
        .uint32 => allocator.dupeZ(u8, "I"),
        .int64 => allocator.dupeZ(u8, "l"),
        .uint64 => allocator.dupeZ(u8, "L"),
        .float16 => allocator.dupeZ(u8, "e"),
        .float32 => allocator.dupeZ(u8, "f"),
        .float64 => allocator.dupeZ(u8, "g"),
        .date32 => allocator.dupeZ(u8, "tdD"),
        .date64 => allocator.dupeZ(u8, "tdm"),
        .time32 => |unit| switch (unit) {
            .second => allocator.dupeZ(u8, "tts"),
            .millisecond => allocator.dupeZ(u8, "ttm"),
            else => error.InvalidTimeUnit,
        },
        .time64 => |unit| switch (unit) {
            .microsecond => allocator.dupeZ(u8, "ttu"),
            .nanosecond => allocator.dupeZ(u8, "ttn"),
            else => error.InvalidTimeUnit,
        },
        .timestamp => |meta| std.fmt.allocPrintSentinel(allocator, "ts{s}:{s}", .{ timeUnitCode(meta.unit), meta.tz orelse "" }, 0),
        .duration => |unit| std.fmt.allocPrintSentinel(allocator, "tD{s}", .{timeUnitCode(unit)}, 0),
        .binary => allocator.dupeZ(u8, "z"),
        .utf8 => allocator.dupeZ(u8, "u"),
        .large_binary => allocator.dupeZ(u8, "Z"),
        .large_utf8 => allocator.dupeZ(u8, "U"),
        .list => allocator.dupeZ(u8, "+l"),
        .large_list => allocator.dupeZ(u8, "+L"),
        .fixed_size_list => |meta| std.fmt.allocPrintSentinel(allocator, "+w:{d}", .{meta.len}, 0),
        .struct_ => allocator.dupeZ(u8, "+s"),
        .sparse_union => |meta| unionFormat(allocator, "s", meta.type_ids),
        .dense_union => |meta| unionFormat(allocator, "d", meta.type_ids),
        .dictionary => |meta| formatForType(allocator, meta.index_type.*),
    };
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

fn unionFormat(allocator: Allocator, comptime mode: []const u8, type_ids: []const i8) Allocator.Error![:0]u8 {
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(allocator);

    try list.print(allocator, "+u{s}:", .{mode});
    for (type_ids, 0..) |id, i| {
        if (i != 0) try list.append(allocator, ',');
        try list.print(allocator, "{d}", .{id});
    }
    return try list.toOwnedSliceSentinel(allocator, 0);
}

fn timeUnitCode(unit: datatype.TimeUnit) []const u8 {
    return switch (unit) {
        .second => "s",
        .millisecond => "m",
        .microsecond => "u",
        .nanosecond => "n",
    };
}

test {
    std.testing.refAllDecls(@import("cdi/metadata.zig"));
    std.testing.refAllDecls(@import("cdi/alloc_test.zig"));
    std.testing.refAllDecls(@import("cdi/array_test.zig"));
    std.testing.refAllDecls(@import("cdi/schema_test.zig"));
    std.testing.refAllDecls(@import("cdi/stream_test.zig"));
}
