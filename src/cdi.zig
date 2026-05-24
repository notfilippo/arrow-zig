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
//! Imported buffers are immutable views. The importer trusts producer padding
//! by Arrow contract and preserves producer pointer alignment.
//!
//! Record batch interop uses a schema plus struct array pair. Batch import
//! rejects top level struct null rows before consuming the array.
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
//! Export one record batch as a schema plus struct array pair.
//!
//! ```zig
//! var schema: arrow.cdi.ArrowSchema = undefined;
//! var array: arrow.cdi.ArrowArray = undefined;
//! try arrow.cdi.exportRecordBatch(allocator, batch, &schema, &array);
//! defer if (schema.release) |release| release(&schema);
//! defer if (array.release) |release| release(&array);
//!
//! const imported = try arrow.cdi.importRecordBatch(allocator, &schema, &array);
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
const datatype = @import("datatype.zig");
const record_batch_mod = @import("record_batch.zig");
const schema_mod = @import("schema.zig");

const array_export = @import("cdi/array_export.zig");
const array_import = @import("cdi/array_import.zig");
const cdi_stream = @import("cdi/stream.zig");
const cdi_types = @import("cdi/types.zig");
const schema_export = @import("cdi/schema_export.zig");
const schema_import = @import("cdi/schema_import.zig");

const ArrayData = array.ArrayData;
const RecordBatch = record_batch_mod.RecordBatch;
const Schema = schema_mod.Schema;

pub const schema_flag_dictionary_ordered = cdi_types.schema_flag_dictionary_ordered;
pub const schema_flag_map_keys_sorted = cdi_types.schema_flag_map_keys_sorted;
pub const schema_flag_nullable = cdi_types.schema_flag_nullable;

pub const ArrowSchema = cdi_types.ArrowSchema;
pub const ArrowArray = cdi_types.ArrowArray;
pub const ArrowArrayStream = cdi_types.ArrowArrayStream;
pub const ImportedArrayStream = cdi_stream.ImportedArrayStream;

pub const SchemaExportError = schema_export.Error;
pub const SchemaImportError = schema_import.Error;
pub const ArrayExportError = array_export.Error;
pub const ArrayImportError = array_import.Error;
pub const SchemaArrayImportError = SchemaImportError || ArrayImportError;
pub const RecordBatchExportError = SchemaExportError || ArrayExportError || record_batch_mod.Error;
pub const RecordBatchImportError = SchemaImportError || ArrayImportError || record_batch_mod.Error;
pub const ArrayStreamExportError = cdi_stream.ExportError;
pub const ArrayStreamImportError = cdi_stream.ImportError;

/// Export a data type as an `ArrowSchema`.
/// The caller must release `out` unless ownership is transferred.
pub fn exportType(allocator: Allocator, ty: datatype.DataType, out: *ArrowSchema) SchemaExportError!void {
    try schema_export.exportType(allocator, ty, out);
}

/// Export a field as an `ArrowSchema`.
/// The caller must release `out` unless ownership is transferred.
pub fn exportField(allocator: Allocator, field: *const datatype.Field, out: *ArrowSchema) SchemaExportError!void {
    try schema_export.exportField(allocator, field, out);
}

/// Export a schema as a struct `ArrowSchema`.
/// The caller must release `out` unless ownership is transferred.
pub fn exportSchema(allocator: Allocator, input_schema: *const Schema, out: *ArrowSchema) SchemaExportError!void {
    try schema_export.exportSchema(allocator, input_schema, out);
}

/// Export a record batch as a schema and struct array pair.
/// The caller must release both outputs unless ownership is transferred.
pub fn exportRecordBatch(
    allocator: Allocator,
    batch: *const RecordBatch,
    out_schema: *ArrowSchema,
    out_array: *ArrowArray,
) RecordBatchExportError!void {
    out_schema.* = schema_export.released();
    out_array.* = array_export.released();

    try exportSchema(allocator, batch.schema, out_schema);
    errdefer schema_export.releaseIfNeeded(out_schema);

    const data = try batch.toStructData();
    defer data.deinit();

    try exportArray(allocator, data, out_array);
}

/// Import a C Data Interface schema into an owned data type.
/// The schema is not consumed. Deinitialize the returned type with
/// `datatype.deinitOwned()` when done.
pub fn importType(allocator: Allocator, schema: *const ArrowSchema) SchemaImportError!datatype.DataType {
    return schema_import.importType(allocator, schema);
}

/// Import a C Data Interface schema into an owned field.
/// The schema is not consumed. Call `field.deinit()` when done.
pub fn importField(allocator: Allocator, schema: *const ArrowSchema) SchemaImportError!*const datatype.Field {
    return schema_import.importField(allocator, schema);
}

/// Import a C Data Interface schema into an owned schema.
/// The schema is not consumed. Deinitialize the returned schema when done.
pub fn importSchema(allocator: Allocator, schema: *const ArrowSchema) SchemaImportError!*Schema {
    return schema_import.importSchema(allocator, schema);
}

/// Import a record batch from a schema and struct array pair.
/// The schema is not consumed.
/// The array is consumed after top level row null checks pass.
pub fn importRecordBatch(allocator: Allocator, schema: *const ArrowSchema, arr: *ArrowArray) RecordBatchImportError!*RecordBatch {
    const batch_schema = try importSchema(allocator, schema);
    defer batch_schema.deinit();

    try rejectStructNullRows(arr);

    const ty = datatype.DataType{ .struct_ = .{ .fields = batch_schema.fields() } };
    const data = try importArray(allocator, ty, arr);
    defer data.deinit();

    return try RecordBatch.fromStructDataAssumeValidated(allocator, batch_schema, data);
}

/// Import a C Data Interface array by first importing its schema.
/// On success, consumes only the top level `ArrowArray`.
pub fn importArrayFromSchema(allocator: Allocator, schema: *const ArrowSchema, arr: *ArrowArray) SchemaArrayImportError!*ArrayData {
    var ty = try importType(allocator, schema);
    defer datatype.deinitOwned(allocator, &ty);
    return try importArray(allocator, ty, arr);
}

/// Export array storage as an `ArrowArray`.
/// The export retains `data` until the C release callback is invoked.
pub fn exportArray(allocator: Allocator, data: *ArrayData, out: *ArrowArray) ArrayExportError!void {
    try array_export.exportArray(allocator, data, out);
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
    try cdi_stream.exportArrayStream(allocator, ty, arrays, out);
}

/// Import one typed Arrow C Data Interface array without copying buffers.
/// On success, consumes only the top level `ArrowArray` and marks it released.
/// The moved C array is released when the last imported data or buffer drops.
/// Imported buffer padding is trusted and producer alignment is preserved.
pub fn importArray(allocator: Allocator, ty: datatype.DataType, arr: *ArrowArray) ArrayImportError!*ArrayData {
    return array_import.importArray(allocator, ty, arr);
}

/// Import a C Data Interface array stream.
/// On success, consumes the top level `ArrowArrayStream`.
/// Deinitialize the returned stream when done.
pub fn importArrayStream(allocator: Allocator, stream: *ArrowArrayStream) ArrayStreamImportError!*ImportedArrayStream {
    return cdi_stream.importArrayStream(allocator, stream);
}

/// True when an `ArrowSchema` has no release callback.
pub fn schemaIsReleased(schema: *const ArrowSchema) bool {
    return schema_export.isReleased(schema);
}

/// True when an `ArrowArray` has no release callback.
pub fn arrayIsReleased(arr: *const ArrowArray) bool {
    return array_export.isReleased(arr);
}

/// True when an `ArrowArrayStream` has no release callback.
pub fn arrayStreamIsReleased(stream: *const ArrowArrayStream) bool {
    return cdi_stream.isReleased(stream);
}

fn rejectStructNullRows(arr: *const ArrowArray) RecordBatchImportError!void {
    if (arr.null_count == 0) return;
    if (arr.null_count > 0) return error.StructNullsUnsupported;
    if (arr.null_count < -1) return error.InvalidNullCount;

    if (arr.length < 0) return error.NegativeLength;
    if (arr.offset < 0) return error.NegativeOffset;
    if (arr.n_buffers < 0) return error.InvalidBufferCount;
    if (arr.n_buffers != 1) return error.InvalidBufferCount;
    const buffers = arr.buffers orelse return error.InvalidBufferCount;
    const validity_ptr = buffers[0] orelse return;

    const len = try i64ToUsize(arr.length);
    const offset = try i64ToUsize(arr.offset);
    if (len == 0) return;
    const validity: [*]const u8 = @ptrCast(validity_ptr);
    const null_count = len - bitmap.countSetBits(validity[0..try bitmap.byteLenChecked(try std.math.add(usize, offset, len))], offset, len);
    if (null_count != 0) return error.StructNullsUnsupported;
}

fn i64ToUsize(value: i64) RecordBatchImportError!usize {
    const unsigned: u64 = @intCast(value);
    if (@as(u128, unsigned) > @as(u128, std.math.maxInt(usize))) return error.ValueOutOfRange;
    return @intCast(unsigned);
}
