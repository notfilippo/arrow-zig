// Copyright 2026 Filippo Rossi
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");
const array = @import("array.zig");
const buffer = @import("buffer.zig");
const cdi = @import("cdi.zig");
const datatype = @import("datatype.zig");

const ArrayData = array.ArrayData;
const ArrowArray = cdi.ArrowArray;
const ArrowSchema = cdi.ArrowSchema;
const Buffer = buffer.Buffer;

test "importType handles allocation failures" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, checkImportTypeAllocationFailure, .{});
}

test "importField handles allocation failures" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, checkImportFieldAllocationFailure, .{});
}

test "importArrayFromSchema handles allocation failures" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, checkImportArrayFromSchemaAllocationFailure, .{});
}

test "importArray handles nested allocation failures" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, checkImportArrayAllocationFailure, .{});
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
