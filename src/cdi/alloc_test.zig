// Copyright 2026 Filippo Rossi
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");
const array = @import("../array.zig");
const buffer = @import("../buffer.zig");
const cdi = @import("../cdi.zig");
const datatype = @import("../datatype.zig");
const record_batch_mod = @import("../record_batch.zig");
const schema_mod = @import("../schema.zig");

const ArrayData = array.ArrayData;
const ArrowArray = cdi.ArrowArray;
const ArrowArrayStream = cdi.ArrowArrayStream;
const ArrowSchema = cdi.ArrowSchema;
const Buffer = buffer.Buffer;
const RecordBatch = record_batch_mod.RecordBatch;

test "importType handles allocation failures" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, checkImportTypeAllocationFailure, .{});
}

test "importField handles allocation failures" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, checkImportFieldAllocationFailure, .{});
}

test "importSchema handles allocation failures" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, checkImportSchemaAllocationFailure, .{});
}

test "exportSchema handles allocation failures" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, checkExportSchemaAllocationFailure, .{});
}

test "importArrayFromSchema handles allocation failures" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, checkImportArrayFromSchemaAllocationFailure, .{});
}

test "exportRecordBatch handles allocation failures" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, checkExportRecordBatchAllocationFailure, .{});
}

test "importRecordBatch handles allocation failures" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, checkImportRecordBatchAllocationFailure, .{});
}

test "importArray handles nested allocation failures" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, checkImportArrayAllocationFailure, .{});
}

test "exportArrayStream handles allocation failures" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, checkExportArrayStreamAllocationFailure, .{});
}

test "importArrayStream handles allocation failures" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, checkImportArrayStreamAllocationFailure, .{});
}

fn checkImportTypeAllocationFailure(allocator: std.mem.Allocator) !void {
    var int_child = testSchema("i", "number", false);
    var bool_child = testSchema("b", "flag", true);
    var struct_children = [_]*ArrowSchema{ &int_child, &bool_child };
    var struct_schema = testSchema("+s", "values", true);
    struct_schema.n_children = struct_children.len;
    struct_schema.children = &struct_children;

    var index_schema = testSchema("i", null, true);
    index_schema.dictionary = &struct_schema;

    var imported = try cdi.importType(allocator, &index_schema);
    defer datatype.deinitOwned(allocator, &imported);

    try imported.validate();
}

fn checkImportFieldAllocationFailure(allocator: std.mem.Allocator) !void {
    var child = testSchema("i", "item", false);
    var children = [_]*ArrowSchema{&child};
    var schema = testSchema("+l", "values", false);
    schema.n_children = children.len;
    schema.children = &children;

    const imported = try cdi.importField(allocator, &schema);
    defer datatype.deinitOwnedField(allocator, imported);

    try imported.type.validate();
}

fn checkImportSchemaAllocationFailure(allocator: std.mem.Allocator) !void {
    const setup = std.testing.allocator;
    const source = try testArrowSchema(setup);
    defer source.deinit();

    var exported: ArrowSchema = undefined;
    try cdi.exportSchema(setup, source, &exported);
    defer if (exported.release) |release| release(&exported);

    const imported = try cdi.importSchema(allocator, &exported);
    defer imported.deinit();

    try imported.validate();
}

fn checkExportSchemaAllocationFailure(allocator: std.mem.Allocator) !void {
    const setup = std.testing.allocator;
    const source = try testArrowSchema(setup);
    defer source.deinit();

    var exported: ArrowSchema = undefined;
    try cdi.exportSchema(allocator, source, &exported);
    defer if (exported.release) |release| release(&exported);
}

fn checkImportArrayFromSchemaAllocationFailure(allocator: std.mem.Allocator) !void {
    const setup = std.testing.allocator;
    const source = try binaryArray(setup);
    defer source.deinit();

    var schema: ArrowSchema = undefined;
    try cdi.exportType(setup, source.type, &schema);
    defer if (schema.release) |release| release(&schema);

    var exported: ArrowArray = undefined;
    try cdi.exportArray(setup, source, &exported);
    defer if (exported.release) |release| release(&exported);

    const imported = try cdi.importArrayFromSchema(allocator, &schema, &exported);
    defer imported.deinit();

    try imported.validate();
}

fn checkExportRecordBatchAllocationFailure(allocator: std.mem.Allocator) !void {
    const setup = std.testing.allocator;
    const batch = try testRecordBatch(setup);
    defer batch.deinit();

    var schema: ArrowSchema = undefined;
    var arr: ArrowArray = undefined;
    try cdi.exportRecordBatch(allocator, batch, &schema, &arr);
    defer if (schema.release) |release| release(&schema);
    defer if (arr.release) |release| release(&arr);
}

fn checkImportRecordBatchAllocationFailure(allocator: std.mem.Allocator) !void {
    const setup = std.testing.allocator;
    const batch = try testRecordBatch(setup);
    defer batch.deinit();

    var schema: ArrowSchema = undefined;
    var arr: ArrowArray = undefined;
    try cdi.exportRecordBatch(setup, batch, &schema, &arr);
    defer if (schema.release) |release| release(&schema);
    defer if (arr.release) |release| release(&arr);

    const imported = try cdi.importRecordBatch(allocator, &schema, &arr);
    defer imported.deinit();

    try imported.schema.validate();
}

fn checkImportArrayAllocationFailure(allocator: std.mem.Allocator) !void {
    const setup = std.testing.allocator;
    const source = try dictionaryListArray(setup);
    defer source.deinit();

    var exported: ArrowArray = undefined;
    try cdi.exportArray(setup, source, &exported);
    defer if (exported.release) |release| release(&exported);

    const imported = try cdi.importArray(allocator, source.type, &exported);
    defer imported.deinit();

    try imported.validate();
}

fn checkExportArrayStreamAllocationFailure(allocator: std.mem.Allocator) !void {
    const setup = std.testing.allocator;
    const source = try binaryArray(setup);
    defer source.deinit();

    var stream: ArrowArrayStream = undefined;
    try cdi.exportArrayStream(allocator, source.type, &.{source}, &stream);
    defer if (stream.release) |release| release(&stream);

    var schema: ArrowSchema = undefined;
    try expectStreamOk(stream.get_schema.?(&stream, &schema));
    defer if (schema.release) |release| release(&schema);

    var arr: ArrowArray = undefined;
    try expectStreamOk(stream.get_next.?(&stream, &arr));
    defer if (arr.release) |release| release(&arr);
}

fn checkImportArrayStreamAllocationFailure(allocator: std.mem.Allocator) !void {
    const setup = std.testing.allocator;
    const source = try binaryArray(setup);
    defer source.deinit();

    var stream: ArrowArrayStream = undefined;
    try cdi.exportArrayStream(setup, source.type, &.{source}, &stream);
    defer if (stream.release) |release| release(&stream);

    const imported_stream = try cdi.importArrayStream(allocator, &stream);
    defer imported_stream.deinit();

    const imported = (try imported_stream.next()).?;
    defer imported.deinit();

    try imported.validate();
}

fn binaryArray(allocator: std.mem.Allocator) !*ArrayData {
    const offsets = try Buffer.allocate(allocator, 3 * @sizeOf(i32));
    errdefer offsets.deinit();
    std.mem.writeInt(i32, offsets.data[0..4], 0, .little);
    std.mem.writeInt(i32, offsets.data[4..8], 2, .little);
    std.mem.writeInt(i32, offsets.data[8..12], 5, .little);
    offsets.freeze();

    const values = try Buffer.allocate(allocator, 5);
    errdefer values.deinit();
    @memcpy(values.data[0..5], "abcde");
    values.freeze();

    return try ArrayData.initOwned(allocator, .binary, 2, 0, 0, &.{ null, offsets, values }, &.{}, null);
}

fn testArrowSchema(allocator: std.mem.Allocator) !*schema_mod.Schema {
    const value_ty: datatype.DataType = .int32;
    const field_metadata = [_]schema_mod.MetadataEntry{
        .{ .key = "unit", .value = "ms" },
    };
    const fields = [_]datatype.Field{
        .{ .name = "number", .type = &value_ty, .metadata = &field_metadata },
    };
    const metadata = [_]schema_mod.MetadataEntry{
        .{ .key = "source", .value = "alloc" },
    };
    return schema_mod.Schema.init(allocator, &fields, &metadata);
}

fn testRecordBatch(allocator: std.mem.Allocator) !*RecordBatch {
    const values = try binaryArray(allocator);
    defer values.deinit();

    const value_ty: datatype.DataType = .binary;
    const fields = [_]datatype.Field{
        .{ .name = "data", .type = &value_ty },
    };
    const batch_schema = try schema_mod.Schema.init(allocator, &fields, &.{});
    defer batch_schema.deinit();

    return RecordBatch.initRetained(allocator, batch_schema, 2, &.{values});
}

fn dictionaryListArray(allocator: std.mem.Allocator) !*ArrayData {
    const index_values = try Buffer.allocate(allocator, 2 * @sizeOf(i8));
    errdefer index_values.deinit();
    index_values.data[0] = 0;
    index_values.data[1] = 1;
    index_values.freeze();
    defer index_values.deinit();

    const child_values = try Buffer.allocate(allocator, 3 * @sizeOf(i32));
    errdefer child_values.deinit();
    std.mem.writeInt(i32, child_values.data[0..4], 10, .little);
    std.mem.writeInt(i32, child_values.data[4..8], 20, .little);
    std.mem.writeInt(i32, child_values.data[8..12], 30, .little);
    child_values.freeze();
    const child = try ArrayData.initOwned(allocator, .int32, 3, 0, 0, &.{ null, child_values }, &.{}, null);
    defer child.deinit();

    const offsets = try Buffer.allocate(allocator, 3 * @sizeOf(i32));
    errdefer offsets.deinit();
    std.mem.writeInt(i32, offsets.data[0..4], 0, .little);
    std.mem.writeInt(i32, offsets.data[4..8], 1, .little);
    std.mem.writeInt(i32, offsets.data[8..12], 3, .little);
    offsets.freeze();
    defer offsets.deinit();

    const value_ty: datatype.DataType = .int32;
    const list_ty = datatype.DataType{ .list = .{ .child = .{ .name = "item", .type = &value_ty } } };
    const dictionary = try ArrayData.initRetained(allocator, list_ty, 2, 0, 0, &.{ null, offsets }, &.{child}, null);
    defer dictionary.deinit();

    const index_ty: datatype.DataType = .int8;
    const dict_ty = datatype.DataType{ .dictionary = .{
        .index_type = &index_ty,
        .value_type = &list_ty,
    } };
    return try ArrayData.initRetained(allocator, dict_ty, 2, 0, 0, &.{ null, index_values }, &.{}, dictionary);
}

fn noopSchemaRelease(schema: *ArrowSchema) callconv(.c) void {
    schema.release = null;
}

fn testSchema(format: ?[*:0]const u8, name: ?[*:0]const u8, nullable: bool) ArrowSchema {
    return .{
        .format = format,
        .name = name,
        .metadata = null,
        .flags = if (nullable) cdi.schema_flag_nullable else 0,
        .n_children = 0,
        .children = null,
        .dictionary = null,
        .release = noopSchemaRelease,
        .private_data = null,
    };
}

fn expectStreamOk(code: c_int) !void {
    return switch (code) {
        0 => {},
        12 => error.OutOfMemory,
        else => error.StreamCallbackFailed,
    };
}
