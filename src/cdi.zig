// Copyright 2026 Filippo Rossi
// SPDX-License-Identifier: Apache-2.0

//! Arrow C Data Interface import and export.
//!
//! Export copies schemas into C Data Interface structs and retains exported
//! array storage until the C release callback is invoked.
//!
//! Schema import copies C Data Interface schemas into owned `DataType` values.
//! Array import consumes only the top level `ArrowArray` on success and keeps
//! its release callback alive until imported data and buffers are dropped.

const std = @import("std");
const Allocator = std.mem.Allocator;
const array = @import("array.zig");
const bitmap = @import("bitmap.zig");
const buffer = @import("buffer.zig");
const cdi_schema_import = @import("cdi_schema_import.zig");
const checked = @import("checked.zig");
const datatype = @import("datatype.zig");

const ArrayData = array.ArrayData;
const Buffer = buffer.Buffer;
const ExternalOwnerHandle = buffer.ExternalOwnerHandle;

pub const schema_flag_dictionary_ordered: i64 = 1;
pub const schema_flag_nullable: i64 = 2;

pub const SchemaExportError = Allocator.Error || datatype.ValidationError || error{
    InvalidTimeUnit,
    ValueOutOfRange,
};
pub const SchemaImportError = cdi_schema_import.Error;

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

pub const ArrowSchema = extern struct {
    format: ?[*:0]const u8,
    name: ?[*:0]const u8,
    metadata: ?[*:0]const u8,
    flags: i64,
    n_children: i64,
    children: ?[*]*ArrowSchema,
    dictionary: ?*ArrowSchema,
    release: ?*const fn (*ArrowSchema) callconv(.c) void,
    private_data: ?*anyopaque,
};

pub const ArrowArray = extern struct {
    length: i64,
    null_count: i64,
    offset: i64,
    n_buffers: i64,
    n_children: i64,
    buffers: ?[*]?*const anyopaque,
    children: ?[*]*ArrowArray,
    dictionary: ?*ArrowArray,
    release: ?*const fn (*ArrowArray) callconv(.c) void,
    private_data: ?*anyopaque,
};

const SchemaPrivate = struct {
    allocator: Allocator,
    format: [:0]u8,
    name: ?[:0]u8,
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

// Children and dictionaries stay owned by the moved top level ArrowArray.
const ImportedArrayOwner = struct {
    allocator: Allocator,
    handle: ExternalOwnerHandle,
    moved: ArrowArray,
    moved_valid: bool,
};

pub fn exportType(allocator: Allocator, ty: datatype.DataType, out: *ArrowSchema) SchemaExportError!void {
    try exportSchemaNode(allocator, ty, null, true, out);
}

pub fn exportField(allocator: Allocator, field: datatype.Field, out: *ArrowSchema) SchemaExportError!void {
    try exportSchemaNode(allocator, field.type.*, field, field.nullable, out);
}

/// Import a C Data Interface schema into an owned data type.
/// The schema is not consumed. Deinitialize the returned type with
/// `datatype.deinitOwned()` when done.
pub fn importType(allocator: Allocator, schema: *const ArrowSchema) SchemaImportError!datatype.DataType {
    return cdi_schema_import.importType(allocator, schema);
}

/// Import a C Data Interface schema into an owned field.
/// The schema is not consumed. Deinitialize the returned field with
/// `datatype.deinitOwnedField()` when done.
pub fn importField(allocator: Allocator, schema: *const ArrowSchema) SchemaImportError!datatype.Field {
    return cdi_schema_import.importField(allocator, schema);
}

/// Import a C Data Interface array by first importing its schema.
/// On success, consumes only the top level `ArrowArray`.
pub fn importArrayFromSchema(allocator: Allocator, schema: *const ArrowSchema, arr: *ArrowArray) SchemaArrayImportError!*ArrayData {
    var ty = try importType(allocator, schema);
    defer datatype.deinitOwned(allocator, &ty);
    return try importArray(allocator, ty, arr);
}

fn exportSchemaNode(
    allocator: Allocator,
    ty: datatype.DataType,
    field: ?datatype.Field,
    nullable: bool,
    out: *ArrowSchema,
) SchemaExportError!void {
    try ty.validate();
    const format = try formatForType(allocator, ty);
    errdefer allocator.free(format);

    const owned_name = if (field) |f| try allocator.dupeZ(u8, f.name) else null;
    errdefer if (owned_name) |name| allocator.free(name);

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
        .children_storage = children_storage,
        .child_ptrs = child_ptrs,
        .dictionary = dictionary,
    };

    out.* = .{
        .format = format.ptr,
        .name = if (owned_name) |name| name.ptr else null,
        .metadata = null,
        .flags = flags,
        .n_children = n_children,
        .children = if (child_ptrs.len == 0) null else child_ptrs.ptr,
        .dictionary = dictionary,
        .release = releaseSchema,
        .private_data = private,
    };
}

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

pub fn schemaIsReleased(schema: *const ArrowSchema) bool {
    return schema.release == null;
}

pub fn arrayIsReleased(arr: *const ArrowArray) bool {
    return arr.release == null;
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
    _ = @import("cdi_alloc_test.zig");
    _ = @import("cdi_test.zig");
}
