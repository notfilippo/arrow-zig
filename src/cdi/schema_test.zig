// Copyright 2026 Filippo Rossi
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");
const cdi = @import("../cdi.zig");
const datatype = @import("../datatype.zig");
const schema_mod = @import("../schema.zig");

const ArrowSchema = cdi.ArrowSchema;
const MetadataEntry = schema_mod.MetadataEntry;

const exportField = cdi.exportField;
const exportSchema = cdi.exportSchema;
const exportType = cdi.exportType;
const importField = cdi.importField;
const importSchema = cdi.importSchema;
const importType = cdi.importType;
const schemaIsReleased = cdi.schemaIsReleased;
const schema_flag_dictionary_ordered = cdi.schema_flag_dictionary_ordered;
const schema_flag_map_keys_sorted = cdi.schema_flag_map_keys_sorted;

test "exportType primitive schema" {
    const allocator = std.testing.allocator;
    var schema: ArrowSchema = undefined;
    try exportType(allocator, .int32, &schema);
    defer schema.release.?(&schema);

    try std.testing.expectEqualStrings("i", std.mem.span(schema.format.?));
    try std.testing.expectEqual(cdi.schema_flag_nullable, schema.flags);
    try std.testing.expect(!schemaIsReleased(&schema));
}

test "exportType nested list schema" {
    const allocator = std.testing.allocator;
    const value_ty: datatype.DataType = .int32;
    const item_field = try datatype.Field.create(allocator, "item", &value_ty, true, &.{});
    defer item_field.deinit();
    const list_ty = datatype.DataType{ .list = .{ .child = item_field } };

    var schema: ArrowSchema = undefined;
    try exportType(allocator, list_ty, &schema);
    defer schema.release.?(&schema);

    try std.testing.expectEqualStrings("+l", std.mem.span(schema.format.?));
    try std.testing.expectEqual(@as(i64, 1), schema.n_children);
    try std.testing.expect(schema.children != null);
    try std.testing.expectEqualStrings("item", std.mem.span(schema.children.?[0].name.?));
    try std.testing.expectEqualStrings("i", std.mem.span(schema.children.?[0].format.?));
}

test "exportType map schema" {
    const allocator = std.testing.allocator;
    const key_ty: datatype.DataType = .int32;
    const value_ty: datatype.DataType = .utf8;
    const key_field = try datatype.Field.create(allocator, "key", &key_ty, false, &.{});
    defer key_field.deinit();
    const value_field = try datatype.Field.create(allocator, "value", &value_ty, true, &.{});
    defer value_field.deinit();
    const entry_fields = [_]*const datatype.Field{ key_field, value_field };
    const entry_ty = datatype.DataType{ .struct_ = .{ .fields = &entry_fields } };
    const entries_field = try datatype.Field.create(allocator, "entries", &entry_ty, false, &.{});
    defer entries_field.deinit();
    const map_ty = datatype.DataType{ .map = .{ .entries = entries_field, .keys_sorted = true } };

    var schema: ArrowSchema = undefined;
    try exportType(allocator, map_ty, &schema);
    defer schema.release.?(&schema);

    try std.testing.expectEqualStrings("+m", std.mem.span(schema.format.?));
    try std.testing.expect(schema.flags & schema_flag_map_keys_sorted != 0);
    try std.testing.expectEqual(@as(i64, 1), schema.n_children);
    try std.testing.expectEqualStrings("entries", std.mem.span(schema.children.?[0].name.?));
    try std.testing.expectEqualStrings("+s", std.mem.span(schema.children.?[0].format.?));
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
        .{ .fixed_size_binary = .{ .byte_width = 16 } },
        .{ .decimal128 = .{ .precision = 12, .scale = 5 } },
        .{ .decimal128 = .{ .precision = 5, .scale = -3 } },
        .{ .decimal256 = .{ .precision = 40, .scale = 2 } },
    };

    for (cases) |ty| try expectImportTypeRoundTrip(allocator, ty);
}

test "importType parses decimal formats" {
    const allocator = std.testing.allocator;

    var decimal128_default = minimalSchema("d:12,5");
    var imported128_default = try importType(allocator, &decimal128_default);
    defer datatype.deinitOwned(allocator, &imported128_default);
    try std.testing.expect(datatype.DataType.equals(
        .{ .decimal128 = .{ .precision = 12, .scale = 5 } },
        imported128_default,
    ));

    var decimal128_explicit = minimalSchema("d:12,5,128");
    var imported128_explicit = try importType(allocator, &decimal128_explicit);
    defer datatype.deinitOwned(allocator, &imported128_explicit);
    try std.testing.expect(datatype.DataType.equals(
        .{ .decimal128 = .{ .precision = 12, .scale = 5 } },
        imported128_explicit,
    ));

    var decimal256 = minimalSchema("d:40,-2,256");
    var imported256 = try importType(allocator, &decimal256);
    defer datatype.deinitOwned(allocator, &imported256);
    try std.testing.expect(datatype.DataType.equals(
        .{ .decimal256 = .{ .precision = 40, .scale = -2 } },
        imported256,
    ));

    var bad_width = minimalSchema("d:12,5,64");
    try std.testing.expectError(error.InvalidFormat, importType(allocator, &bad_width));

    var bad_precision = minimalSchema("d:39,5");
    try std.testing.expectError(error.InvalidDecimalPrecision, importType(allocator, &bad_precision));
}

test "importField round trips field schema" {
    const allocator = std.testing.allocator;
    const value_ty: datatype.DataType = .int32;
    const item_field = try datatype.Field.create(allocator, "item", &value_ty, false, &.{});
    defer item_field.deinit();
    const list_ty = datatype.DataType{ .list = .{ .child = item_field } };
    const field = try datatype.Field.create(allocator, "values", &list_ty, false, &.{.{ .key = "field_key", .value = "field_value" }});
    defer field.deinit();

    var schema: ArrowSchema = undefined;
    try exportField(allocator, field, &schema);
    defer schema.release.?(&schema);

    const imported = try importField(allocator, &schema);
    defer imported.deinit();

    try std.testing.expect(datatype.Field.equals(field, imported));
    try std.testing.expectEqualStrings("field_value", imported.metadata[0].value);
    try std.testing.expect(!schemaIsReleased(&schema));
}

test "importSchema round trips schema metadata" {
    const allocator = std.testing.allocator;
    const number_ty: datatype.DataType = .int32;
    const text_ty: datatype.DataType = .utf8;
    const field_metadata = [_]MetadataEntry{
        .{ .key = "unit", .value = "ms" },
    };
    const number_field = try datatype.Field.create(allocator, "number", &number_ty, false, &field_metadata);
    defer number_field.deinit();
    const text_field = try datatype.Field.create(allocator, "text", &text_ty, true, &.{});
    defer text_field.deinit();
    const metadata = [_]MetadataEntry{
        .{ .key = "source", .value = "test" },
        .{ .key = "source", .value = "duplicate" },
    };
    const original = try schema_mod.Schema.init(allocator, &.{ number_field, text_field }, &metadata);
    defer original.deinit();

    var exported: ArrowSchema = undefined;
    try exportSchema(allocator, original, &exported);
    defer exported.release.?(&exported);

    try std.testing.expectEqualStrings("+s", std.mem.span(exported.format.?));
    try std.testing.expectEqual(@as(i64, 0), exported.flags);
    try std.testing.expect(exported.metadata != null);
    try std.testing.expect(exported.children.?[0].metadata != null);

    const imported = try importSchema(allocator, &exported);
    defer imported.deinit();

    try std.testing.expect(schema_mod.Schema.equals(original, imported));
    try std.testing.expectEqualStrings("test", imported.metadataValue("source").?);
    try std.testing.expectEqualStrings("ms", imported.fieldNamed("number").?.metadata[0].value);
}

test "importSchema accepts absent and empty metadata" {
    const allocator = std.testing.allocator;

    var null_metadata = minimalSchema("+s");
    const imported_null = try importSchema(allocator, &null_metadata);
    defer imported_null.deinit();
    try std.testing.expectEqual(@as(usize, 0), imported_null.metadata().len);

    var empty_metadata_bytes: [4]u8 = undefined;
    std.mem.writeInt(i32, empty_metadata_bytes[0..4], 0, .native);
    var empty_metadata = minimalSchema("+s");
    empty_metadata.metadata = empty_metadata_bytes[0..].ptr;
    const imported_empty = try importSchema(allocator, &empty_metadata);
    defer imported_empty.deinit();
    try std.testing.expectEqual(@as(usize, 0), imported_empty.metadata().len);
}

test "importType round trips nested and dictionary schemas" {
    const allocator = std.testing.allocator;
    const value_ty: datatype.DataType = .int32;
    const bool_ty: datatype.DataType = .bool;

    const item_field = try datatype.Field.create(allocator, "item", &value_ty, false, &.{});
    defer item_field.deinit();
    const list_ty = datatype.DataType{ .list = .{ .child = item_field } };
    try expectImportTypeRoundTrip(allocator, list_ty);

    const large_item_field = try datatype.Field.create(allocator, "large_item", &value_ty, true, &.{});
    defer large_item_field.deinit();
    const large_list_ty = datatype.DataType{ .large_list = .{ .child = large_item_field } };
    try expectImportTypeRoundTrip(allocator, large_list_ty);

    const slot_field = try datatype.Field.create(allocator, "slot", &value_ty, true, &.{});
    defer slot_field.deinit();
    const fixed_ty = datatype.DataType{ .fixed_size_list = .{ .child = slot_field, .len = 3 } };
    try expectImportTypeRoundTrip(allocator, fixed_ty);

    const number_field = try datatype.Field.create(allocator, "number", &value_ty, false, &.{});
    defer number_field.deinit();
    const flag_field = try datatype.Field.create(allocator, "flag", &bool_ty, true, &.{});
    defer flag_field.deinit();
    const struct_fields = [_]*const datatype.Field{ number_field, flag_field };
    const struct_ty = datatype.DataType{ .struct_ = .{ .fields = &struct_fields } };
    try expectImportTypeRoundTrip(allocator, struct_ty);

    const key_field = try datatype.Field.create(allocator, "key", &value_ty, false, &.{});
    defer key_field.deinit();
    const value_field = try datatype.Field.create(allocator, "value", &bool_ty, true, &.{});
    defer value_field.deinit();
    const entry_fields = [_]*const datatype.Field{ key_field, value_field };
    const entry_ty = datatype.DataType{ .struct_ = .{ .fields = &entry_fields } };
    const entries_field = try datatype.Field.create(allocator, "entries", &entry_ty, false, &.{});
    defer entries_field.deinit();
    const map_ty = datatype.DataType{ .map = .{ .entries = entries_field, .keys_sorted = true } };
    try expectImportTypeRoundTrip(allocator, map_ty);

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

test "importSchema rejects malformed metadata" {
    const allocator = std.testing.allocator;

    var negative_count_bytes: [4]u8 = undefined;
    std.mem.writeInt(i32, negative_count_bytes[0..4], -1, .native);
    var negative_count = minimalSchema("+s");
    negative_count.metadata = negative_count_bytes[0..].ptr;
    try std.testing.expectError(error.InvalidMetadata, importSchema(allocator, &negative_count));

    var negative_len_bytes: [8]u8 = undefined;
    std.mem.writeInt(i32, negative_len_bytes[0..4], 1, .native);
    std.mem.writeInt(i32, negative_len_bytes[4..8], -1, .native);
    var negative_len = minimalSchema("+s");
    negative_len.metadata = negative_len_bytes[0..].ptr;
    try std.testing.expectError(error.InvalidMetadata, importSchema(allocator, &negative_len));
}

test "importSchema rejects non schema layouts" {
    const allocator = std.testing.allocator;

    var scalar = minimalSchema("i");
    try std.testing.expectError(error.InvalidFormat, importSchema(allocator, &scalar));

    var dictionary_schema = minimalSchema("u");
    var schema_with_dictionary = minimalSchema("+s");
    schema_with_dictionary.dictionary = &dictionary_schema;
    try std.testing.expectError(error.InvalidFormat, importSchema(allocator, &schema_with_dictionary));
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
