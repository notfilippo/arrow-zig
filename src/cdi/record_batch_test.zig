// Copyright 2026 Filippo Rossi
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");
const array = @import("../array.zig");
const builder = @import("../builder.zig");
const buffer = @import("../buffer.zig");
const cdi = @import("../cdi.zig");
const datatype = @import("../datatype.zig");
const record_batch_mod = @import("../record_batch.zig");
const schema_mod = @import("../schema.zig");
const test_helpers = @import("test_helpers.zig");

const ArrayData = array.ArrayData;
const ArrowArray = cdi.ArrowArray;
const ArrowSchema = cdi.ArrowSchema;
const Buffer = buffer.Buffer;
const MetadataEntry = schema_mod.MetadataEntry;
const RecordBatch = record_batch_mod.RecordBatch;
const Schema = schema_mod.Schema;

test "exportRecordBatch and importRecordBatch round trip schema and columns" {
    const allocator = std.testing.allocator;
    const numbers = try int32Array(allocator);
    defer numbers.deinit();
    const text = try utf8Array(allocator);
    defer text.deinit();

    const number_ty: datatype.DataType = .int32;
    const text_ty: datatype.DataType = .utf8;
    const number_metadata = [_]MetadataEntry{
        .{ .key = "unit", .value = "ms" },
    };
    const fields = [_]datatype.Field{
        .{ .name = "number", .type = &number_ty, .metadata = &number_metadata },
        .{ .name = "text", .type = &text_ty },
    };
    const schema_metadata = [_]MetadataEntry{
        .{ .key = "source", .value = "record_batch_test" },
    };
    const batch_schema = try Schema.init(allocator, &fields, &schema_metadata);
    defer batch_schema.deinit();

    const batch = try RecordBatch.initRetained(allocator, batch_schema, 3, &.{ numbers, text });
    defer batch.deinit();

    var out_schema: ArrowSchema = undefined;
    var out_array: ArrowArray = undefined;
    try cdi.exportRecordBatch(allocator, batch, &out_schema, &out_array);
    defer test_helpers.releaseSchema(&out_schema);
    defer test_helpers.releaseArray(&out_array);

    const imported = try cdi.importRecordBatch(allocator, &out_schema, &out_array);
    defer imported.deinit();

    try std.testing.expect(cdi.arrayIsReleased(&out_array));
    try std.testing.expect(!cdi.schemaIsReleased(&out_schema));
    try std.testing.expect(Schema.equals(batch_schema, imported.schema));
    try std.testing.expectEqual(@as(usize, 3), imported.len);
    try std.testing.expectEqualStrings("ms", imported.schema.fieldNamed("number").?.metadata[0].value);
    try std.testing.expectEqualStrings("record_batch_test", imported.schema.metadataValue("source").?);

    const imported_numbers = try array.NumericArray(i32).fromData(imported.columnNamed("number").?);
    try std.testing.expectEqual(@as(i32, 10), imported_numbers.value(0));
    try std.testing.expect(imported_numbers.isNull(1));
    try std.testing.expectEqual(@as(i32, 30), imported_numbers.value(2));

    const imported_text = try array.Utf8Array.fromData(imported.columnNamed("text").?);
    try std.testing.expectEqualStrings("alpha", imported_text.value(0));
    try std.testing.expectEqualStrings("beta", imported_text.value(1));
    try std.testing.expect(imported_text.isNull(2));
}

test "record batch CDI round trips zero column batch" {
    const allocator = std.testing.allocator;
    const schema_metadata = [_]MetadataEntry{
        .{ .key = "kind", .value = "empty" },
    };
    const batch_schema = try Schema.init(allocator, &.{}, &schema_metadata);
    defer batch_schema.deinit();

    const batch = try RecordBatch.initRetained(allocator, batch_schema, 4, &.{});
    defer batch.deinit();

    var out_schema: ArrowSchema = undefined;
    var out_array: ArrowArray = undefined;
    try cdi.exportRecordBatch(allocator, batch, &out_schema, &out_array);
    defer test_helpers.releaseSchema(&out_schema);
    defer test_helpers.releaseArray(&out_array);

    const imported = try cdi.importRecordBatch(allocator, &out_schema, &out_array);
    defer imported.deinit();

    try std.testing.expectEqual(@as(usize, 4), imported.len);
    try std.testing.expectEqual(@as(usize, 0), imported.fieldCount());
    try std.testing.expectEqualStrings("empty", imported.schema.metadataValue("kind").?);
}

test "importRecordBatch rejects nullable top level struct rows" {
    const allocator = std.testing.allocator;
    const numbers = try int32ArrayNoNulls(allocator);
    defer numbers.deinit();

    const number_ty: datatype.DataType = .int32;
    const fields = [_]datatype.Field{
        .{ .name = "number", .type = &number_ty },
    };
    const batch_schema = try Schema.init(allocator, &fields, &.{});
    defer batch_schema.deinit();

    var validity_builder = @import("../bitmap.zig").BitmapBuilder.init();
    defer validity_builder.deinit();
    try validity_builder.append(allocator, true);
    try validity_builder.append(allocator, false);
    const validity = try validity_builder.finish(allocator);
    defer validity.deinit();

    const struct_ty = datatype.DataType{ .struct_ = .{ .fields = &fields } };
    const data = try ArrayData.initRetained(
        allocator,
        struct_ty,
        2,
        0,
        1,
        &.{validity},
        &.{numbers},
        null,
    );
    defer data.deinit();

    var out_schema: ArrowSchema = undefined;
    try cdi.exportSchema(allocator, batch_schema, &out_schema);
    defer test_helpers.releaseSchema(&out_schema);

    var out_array: ArrowArray = undefined;
    try cdi.exportArray(allocator, data, &out_array);
    defer test_helpers.releaseArray(&out_array);

    try std.testing.expectError(
        error.StructNullsUnsupported,
        cdi.importRecordBatch(allocator, &out_schema, &out_array),
    );
    try std.testing.expect(!cdi.arrayIsReleased(&out_array));
    try std.testing.expect(!cdi.schemaIsReleased(&out_schema));
}

test "importRecordBatch rejects unknown top level struct nulls before consuming" {
    const allocator = std.testing.allocator;
    const numbers = try int32ArrayNoNulls(allocator);
    defer numbers.deinit();

    const number_ty: datatype.DataType = .int32;
    const fields = [_]datatype.Field{
        .{ .name = "number", .type = &number_ty },
    };
    const batch_schema = try Schema.init(allocator, &fields, &.{});
    defer batch_schema.deinit();

    const validity = try validityBitmap(allocator, false);
    defer validity.deinit();

    const struct_ty = datatype.DataType{ .struct_ = .{ .fields = &fields } };
    const data = try ArrayData.initRetained(
        allocator,
        struct_ty,
        2,
        0,
        array.unknown_null_count,
        &.{validity},
        &.{numbers},
        null,
    );
    defer data.deinit();

    var out_schema: ArrowSchema = undefined;
    try cdi.exportSchema(allocator, batch_schema, &out_schema);
    defer test_helpers.releaseSchema(&out_schema);

    var out_array: ArrowArray = undefined;
    try cdi.exportArray(allocator, data, &out_array);
    defer test_helpers.releaseArray(&out_array);

    try std.testing.expectError(
        error.StructNullsUnsupported,
        cdi.importRecordBatch(allocator, &out_schema, &out_array),
    );
    try std.testing.expect(!cdi.arrayIsReleased(&out_array));
}

test "importRecordBatch accepts unknown top level count with valid rows" {
    const allocator = std.testing.allocator;
    const numbers = try int32ArrayNoNulls(allocator);
    defer numbers.deinit();

    const number_ty: datatype.DataType = .int32;
    const fields = [_]datatype.Field{
        .{ .name = "number", .type = &number_ty },
    };
    const batch_schema = try Schema.init(allocator, &fields, &.{});
    defer batch_schema.deinit();

    const validity = try validityBitmap(allocator, true);
    defer validity.deinit();

    const struct_ty = datatype.DataType{ .struct_ = .{ .fields = &fields } };
    const data = try ArrayData.initRetained(
        allocator,
        struct_ty,
        2,
        0,
        array.unknown_null_count,
        &.{validity},
        &.{numbers},
        null,
    );
    defer data.deinit();

    var out_schema: ArrowSchema = undefined;
    try cdi.exportSchema(allocator, batch_schema, &out_schema);
    defer test_helpers.releaseSchema(&out_schema);

    var out_array: ArrowArray = undefined;
    try cdi.exportArray(allocator, data, &out_array);
    defer test_helpers.releaseArray(&out_array);

    const imported = try cdi.importRecordBatch(allocator, &out_schema, &out_array);
    defer imported.deinit();

    try std.testing.expect(cdi.arrayIsReleased(&out_array));
    try std.testing.expectEqual(@as(usize, 2), imported.len);
}

fn int32Array(allocator: std.mem.Allocator) !*ArrayData {
    var b = builder.NumericBuilder(i32).init(allocator);
    defer b.deinit();
    try b.append(10);
    try b.appendNull();
    try b.append(30);
    return b.finish();
}

fn int32ArrayNoNulls(allocator: std.mem.Allocator) !*ArrayData {
    var b = builder.NumericBuilder(i32).init(allocator);
    defer b.deinit();
    try b.appendSlice(&.{ 1, 2 });
    return b.finish();
}

fn utf8Array(allocator: std.mem.Allocator) !*ArrayData {
    var b = builder.Utf8Builder.init(allocator);
    defer b.deinit();
    try b.append("alpha");
    try b.append("beta");
    try b.appendNull();
    return b.finish();
}

fn validityBitmap(allocator: std.mem.Allocator, all_valid: bool) !*Buffer {
    var validity_builder = @import("../bitmap.zig").BitmapBuilder.init();
    defer validity_builder.deinit();
    try validity_builder.append(allocator, true);
    try validity_builder.append(allocator, all_valid);
    return validity_builder.finish(allocator);
}
