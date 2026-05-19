// Copyright 2026 Filippo Rossi
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");
const arrow = @import("arrow");
const array = arrow.array;
const bitmap = arrow.bitmap;
const cdi = arrow.cdi;

const ArrayData = array.ArrayData;
const StructArray = array.StructArray;
const MakeFixture = *const fn (*cdi.ArrowSchema, *cdi.ArrowArray) callconv(.c) c_int;

extern fn arrow_zig_nanoarrow_make_null(schema: *cdi.ArrowSchema, arr: *cdi.ArrowArray) c_int;
extern fn arrow_zig_nanoarrow_make_bool(schema: *cdi.ArrowSchema, arr: *cdi.ArrowArray) c_int;
extern fn arrow_zig_nanoarrow_make_int32(schema: *cdi.ArrowSchema, arr: *cdi.ArrowArray) c_int;
extern fn arrow_zig_nanoarrow_make_string(schema: *cdi.ArrowSchema, arr: *cdi.ArrowArray) c_int;
extern fn arrow_zig_nanoarrow_make_list_int32(schema: *cdi.ArrowSchema, arr: *cdi.ArrowArray) c_int;
extern fn arrow_zig_nanoarrow_make_struct(schema: *cdi.ArrowSchema, arr: *cdi.ArrowArray) c_int;
extern fn arrow_zig_nanoarrow_make_dictionary(schema: *cdi.ArrowSchema, arr: *cdi.ArrowArray) c_int;

test "importArrayFromSchema imports nanoarrow null array" {
    const imported = try importFixture(arrow_zig_nanoarrow_make_null);
    defer imported.deinit();

    try std.testing.expectEqual(.null_, imported.type);
    try std.testing.expectEqual(@as(usize, 3), imported.len);
    try std.testing.expectEqual(@as(usize, 3), imported.null_count);
    try imported.validate();
}

test "importArrayFromSchema imports nanoarrow bool array" {
    const imported = try importFixture(arrow_zig_nanoarrow_make_bool);
    defer imported.deinit();

    const view = try array.BooleanArray.fromData(imported);
    try std.testing.expectEqual(@as(usize, 3), view.view.base.len);
    try std.testing.expectEqual(@as(usize, 1), view.view.nullCount());
    try std.testing.expect(view.value(0));
    try std.testing.expect(view.view.isNull(1));
    try std.testing.expect(!view.value(2));
}

test "importArrayFromSchema imports nanoarrow int32 array" {
    const imported = try importFixture(arrow_zig_nanoarrow_make_int32);
    defer imported.deinit();

    const view = try array.NumericArray(i32).fromData(imported);
    try std.testing.expectEqual(@as(usize, 3), view.view.base.len);
    try std.testing.expectEqual(@as(usize, 1), view.view.nullCount());
    try std.testing.expectEqual(@as(i32, 11), view.value(0));
    try std.testing.expect(view.view.isNull(1));
    try std.testing.expectEqual(@as(i32, 33), view.value(2));
}

test "importArrayFromSchema imports nanoarrow string array" {
    const imported = try importFixture(arrow_zig_nanoarrow_make_string);
    defer imported.deinit();

    const view = try array.Utf8Array.fromData(imported);
    try std.testing.expectEqual(@as(usize, 3), view.view.base.len);
    try std.testing.expectEqual(@as(usize, 1), view.view.nullCount());
    try std.testing.expectEqualStrings("aa", view.value(0));
    try std.testing.expect(view.view.isNull(1));
    try std.testing.expectEqualStrings("bbb", view.value(2));
}

test "importArrayFromSchema imports nanoarrow list array" {
    const imported = try importFixture(arrow_zig_nanoarrow_make_list_int32);
    defer imported.deinit();

    const view = try array.ListArray.fromData(imported);
    try std.testing.expectEqual(@as(usize, 4), view.view.base.len);
    try std.testing.expectEqual(@as(usize, 1), view.view.nullCount());
    try std.testing.expectEqual(@as(usize, 2), view.valueRange(0).len);
    try std.testing.expectEqual(@as(usize, 0), view.valueRange(1).len);
    try std.testing.expect(view.view.isNull(2));
    try std.testing.expectEqual(@as(usize, 1), view.valueRange(3).len);

    const child = try array.NumericArray(i32).fromData(view.childBaseData());
    try std.testing.expectEqual(@as(i32, 1), child.value(0));
    try std.testing.expectEqual(@as(i32, 2), child.value(1));
    try std.testing.expectEqual(@as(i32, 3), child.value(2));
}

test "importArrayFromSchema imports nanoarrow struct array" {
    const imported = try importFixture(arrow_zig_nanoarrow_make_struct);
    defer imported.deinit();

    const view = try StructArray.fromData(imported);
    try std.testing.expectEqual(@as(usize, 2), view.view.base.len);
    try std.testing.expectEqual(@as(usize, 2), view.fieldCount());
    try std.testing.expectEqualStrings("number", view.fieldName(0).?);
    try std.testing.expectEqualStrings("word", view.fieldName(1).?);

    const numbers = try array.NumericArray(i32).fromData(view.fieldBaseNamed("number").?);
    const words = try array.Utf8Array.fromData(view.fieldBaseNamed("word").?);
    try std.testing.expectEqual(@as(i32, 4), numbers.value(0));
    try std.testing.expectEqual(@as(i32, 5), numbers.value(1));
    try std.testing.expectEqualStrings("four", words.value(0));
    try std.testing.expectEqualStrings("five", words.value(1));
}

test "importRecordBatch imports nanoarrow struct array" {
    const allocator = std.testing.allocator;

    var schema: cdi.ArrowSchema = undefined;
    var arr: cdi.ArrowArray = undefined;
    try expectOk(arrow_zig_nanoarrow_make_struct(&schema, &arr));
    defer releaseSchema(&schema);
    defer releaseArray(&arr);

    const batch = try cdi.importRecordBatch(allocator, &schema, &arr);
    defer batch.deinit();

    try std.testing.expect(!cdi.schemaIsReleased(&schema));
    try std.testing.expect(cdi.arrayIsReleased(&arr));
    try std.testing.expectEqual(@as(usize, 2), batch.len);
    try std.testing.expectEqual(@as(usize, 2), batch.fieldCount());
    try std.testing.expectEqualStrings("number", batch.field(0).?.name);
    try std.testing.expectEqualStrings("word", batch.field(1).?.name);

    const numbers = try array.NumericArray(i32).fromData(batch.columnNamed("number").?);
    const words = try array.Utf8Array.fromData(batch.columnNamed("word").?);
    try std.testing.expectEqual(@as(i32, 4), numbers.value(0));
    try std.testing.expectEqual(@as(i32, 5), numbers.value(1));
    try std.testing.expectEqualStrings("four", words.value(0));
    try std.testing.expectEqualStrings("five", words.value(1));
}

test "importArrayFromSchema imports nanoarrow dictionary array" {
    const imported = try importFixture(arrow_zig_nanoarrow_make_dictionary);
    defer imported.deinit();

    try std.testing.expect(imported.dictionary != null);
    try std.testing.expectEqual(@as(usize, 4), imported.len);
    try std.testing.expectEqual(@as(usize, 1), imported.null_count);
    const index_bytes = imported.buffers[1].?.dataSlice();
    try std.testing.expectEqual(@as(i16, 0), std.mem.readInt(i16, index_bytes[0..2], .little));
    try std.testing.expectEqual(@as(i16, 1), std.mem.readInt(i16, index_bytes[2..4], .little));
    try std.testing.expect(!bitmap.getBit(imported.buffers[0].?.dataSlice(), 2));
    try std.testing.expectEqual(@as(i16, 0), std.mem.readInt(i16, index_bytes[6..8], .little));

    const values = try array.Utf8Array.fromData(imported.dictionary.?);
    try std.testing.expectEqualStrings("alpha", values.value(0));
    try std.testing.expectEqualStrings("beta", values.value(1));
}

fn importFixture(make: MakeFixture) !*ArrayData {
    const allocator = std.testing.allocator;

    var schema: cdi.ArrowSchema = undefined;
    var arr: cdi.ArrowArray = undefined;
    try expectOk(make(&schema, &arr));
    defer releaseSchema(&schema);
    defer releaseArray(&arr);

    const imported = try cdi.importArrayFromSchema(allocator, &schema, &arr);
    errdefer imported.deinit();

    try std.testing.expect(!cdi.schemaIsReleased(&schema));
    try std.testing.expect(cdi.arrayIsReleased(&arr));
    try imported.validate();
    return imported;
}

fn expectOk(code: anytype) !void {
    if (code != 0) return error.NanoArrowError;
}

fn releaseSchema(schema: *cdi.ArrowSchema) void {
    if (schema.release) |release| release(schema);
}

fn releaseArray(arr: *cdi.ArrowArray) void {
    if (arr.release) |release| release(arr);
}
