// Copyright 2026 Filippo Rossi
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");
const cdi = @import("../cdi.zig");
const datatype = @import("../datatype.zig");

const ArrowSchema = cdi.ArrowSchema;

const exportField = cdi.exportField;
const exportType = cdi.exportType;
const importField = cdi.importField;
const importType = cdi.importType;
const schemaIsReleased = cdi.schemaIsReleased;
const schema_flag_dictionary_ordered = cdi.schema_flag_dictionary_ordered;

test "exportType primitive schema" {
    const allocator = std.testing.allocator;
    var schema: ArrowSchema = undefined;
    try exportType(allocator, .int32, &schema);
    defer schema.release.?(&schema);

    try std.testing.expectEqualStrings("i", std.mem.span(schema.format.?));
    try std.testing.expectEqual(cdi.schema_flag_nullable, schema.flags);
    try std.testing.expect(!schemaIsReleased(&schema));
}

test "exportType binary schemas" {
    const allocator = std.testing.allocator;
    var schema: ArrowSchema = undefined;
    try exportType(allocator, .utf8, &schema);
    defer schema.release.?(&schema);
    try std.testing.expectEqualStrings("u", std.mem.span(schema.format.?));
}

test "exportType nested list schema" {
    const allocator = std.testing.allocator;
    const value_ty: datatype.DataType = .int32;
    const list_ty = datatype.DataType{ .list = .{ .child = .{ .name = "item", .type = &value_ty } } };

    var schema: ArrowSchema = undefined;
    try exportType(allocator, list_ty, &schema);
    defer schema.release.?(&schema);

    try std.testing.expectEqualStrings("+l", std.mem.span(schema.format.?));
    try std.testing.expectEqual(@as(i64, 1), schema.n_children);
    try std.testing.expect(schema.children != null);
    try std.testing.expectEqualStrings("item", std.mem.span(schema.children.?[0].name.?));
    try std.testing.expectEqualStrings("i", std.mem.span(schema.children.?[0].format.?));
}

test "exportType dictionary schema" {
    const allocator = std.testing.allocator;
    const index_ty: datatype.DataType = .int8;
    const value_ty: datatype.DataType = .utf8;
    const dictionary_ty = datatype.DataType{ .dictionary = .{
        .index_type = &index_ty,
        .value_type = &value_ty,
        .ordered = true,
    } };

    var schema: ArrowSchema = undefined;
    try exportType(allocator, dictionary_ty, &schema);
    defer schema.release.?(&schema);

    try std.testing.expectEqualStrings("c", std.mem.span(schema.format.?));
    try std.testing.expect(schema.flags & schema_flag_dictionary_ordered != 0);
    try std.testing.expect(schema.dictionary != null);
    try std.testing.expectEqualStrings("u", std.mem.span(schema.dictionary.?.format.?));
}

test "importType round trips scalar schemas" {
    const allocator = std.testing.allocator;
    const cases = [_]datatype.DataType{
        .null_,
        .bool,
        .int8,
        .uint8,
        .int16,
        .uint16,
        .int32,
        .uint32,
        .int64,
        .uint64,
        .float16,
        .float32,
        .float64,
        .date32,
        .date64,
        .{ .time32 = .second },
        .{ .time32 = .millisecond },
        .{ .time64 = .microsecond },
        .{ .time64 = .nanosecond },
        .{ .timestamp = .{ .unit = .nanosecond, .tz = "UTC" } },
        .{ .duration = .microsecond },
        .binary,
        .utf8,
        .large_binary,
        .large_utf8,
    };

    for (cases) |ty| try expectImportTypeRoundTrip(allocator, ty);
}

test "importField round trips field schema" {
    const allocator = std.testing.allocator;
    const value_ty: datatype.DataType = .int32;
    const list_ty = datatype.DataType{ .list = .{ .child = .{
        .name = "item",
        .type = &value_ty,
        .nullable = false,
    } } };
    const field = datatype.Field{
        .name = "values",
        .type = &list_ty,
        .nullable = false,
    };

    var schema: ArrowSchema = undefined;
    try exportField(allocator, field, &schema);
    defer schema.release.?(&schema);

    const imported = try importField(allocator, &schema);
    defer datatype.deinitOwnedField(allocator, imported);

    try std.testing.expect(datatype.Field.equals(field, imported));
    try std.testing.expect(!schemaIsReleased(&schema));
}

test "importType round trips nested and dictionary schemas" {
    const allocator = std.testing.allocator;
    const value_ty: datatype.DataType = .int32;
    const bool_ty: datatype.DataType = .bool;

    const list_ty = datatype.DataType{ .list = .{ .child = .{
        .name = "item",
        .type = &value_ty,
        .nullable = false,
    } } };
    try expectImportTypeRoundTrip(allocator, list_ty);

    const large_list_ty = datatype.DataType{ .large_list = .{ .child = .{
        .name = "large_item",
        .type = &value_ty,
    } } };
    try expectImportTypeRoundTrip(allocator, large_list_ty);

    const fixed_ty = datatype.DataType{ .fixed_size_list = .{
        .child = .{ .name = "slot", .type = &value_ty },
        .len = 3,
    } };
    try expectImportTypeRoundTrip(allocator, fixed_ty);

    const struct_fields = [_]datatype.Field{
        .{ .name = "number", .type = &value_ty, .nullable = false },
        .{ .name = "flag", .type = &bool_ty },
    };
    const struct_ty = datatype.DataType{ .struct_ = .{ .fields = &struct_fields } };
    try expectImportTypeRoundTrip(allocator, struct_ty);

    const union_ids = [_]i8{ 7, 8 };
    const union_ty = datatype.DataType{ .dense_union = .{
        .fields = &struct_fields,
        .type_ids = &union_ids,
    } };
    try expectImportTypeRoundTrip(allocator, union_ty);

    const dict_ty = datatype.DataType{ .dictionary = .{
        .index_type = &value_ty,
        .value_type = &struct_ty,
        .ordered = true,
    } };
    try expectImportTypeRoundTrip(allocator, dict_ty);
}

test "importType rejects invalid schemas" {
    const allocator = std.testing.allocator;

    var released = minimalSchema("n");
    released.release = null;
    try std.testing.expectError(error.ReleasedSchema, importType(allocator, &released));

    var missing_format = minimalSchema(null);
    try std.testing.expectError(error.MissingFormat, importType(allocator, &missing_format));

    var bad_format = minimalSchema("?");
    try std.testing.expectError(error.InvalidFormat, importType(allocator, &bad_format));

    var negative_children = minimalSchema("+s");
    negative_children.n_children = -1;
    try std.testing.expectError(error.InvalidChildCount, importType(allocator, &negative_children));

    var missing_child_storage = minimalSchema("+l");
    missing_child_storage.n_children = 1;
    try std.testing.expectError(error.InvalidChildCount, importType(allocator, &missing_child_storage));

    var dict_schema = minimalSchema("i");
    var bad_dictionary = minimalSchema("g");
    bad_dictionary.dictionary = &dict_schema;
    try std.testing.expectError(error.InvalidDictionaryIndexType, importType(allocator, &bad_dictionary));

    var int_child = minimalSchema("i");
    var bool_child = minimalSchema("b");
    var children = [_]*ArrowSchema{ &int_child, &bool_child };
    var duplicate_union = minimalSchema("+ud:7,7");
    duplicate_union.n_children = 2;
    duplicate_union.children = &children;
    try std.testing.expectError(error.InvalidUnionTypeIds, importType(allocator, &duplicate_union));
}

fn noopSchemaRelease(schema: *ArrowSchema) callconv(.c) void {
    schema.release = null;
}

fn minimalSchema(format: ?[*:0]const u8) ArrowSchema {
    return .{
        .format = format,
        .name = null,
        .metadata = null,
        .flags = cdi.schema_flag_nullable,
        .n_children = 0,
        .children = null,
        .dictionary = null,
        .release = noopSchemaRelease,
        .private_data = null,
    };
}

fn expectImportTypeRoundTrip(allocator: std.mem.Allocator, ty: datatype.DataType) !void {
    var schema: ArrowSchema = undefined;
    try exportType(allocator, ty, &schema);
    defer schema.release.?(&schema);

    var imported = try importType(allocator, &schema);
    defer datatype.deinitOwned(allocator, &imported);

    try std.testing.expect(datatype.DataType.equals(ty, imported));
    try std.testing.expect(!schemaIsReleased(&schema));
}
