// Copyright 2026 Filippo Rossi
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");
const array = @import("../array.zig");
const builder = @import("../builder.zig");
const cdi = @import("../cdi.zig");
const datatype = @import("../datatype.zig");

const ArrayData = array.ArrayData;
const ArrowArray = cdi.ArrowArray;
const ArrowArrayStream = cdi.ArrowArrayStream;
const ArrowSchema = cdi.ArrowSchema;

test "exportArrayStream yields schema arrays and end" {
    const allocator = std.testing.allocator;
    const first = try int32Array(allocator, &.{ 1, 2 });
    defer first.deinit();
    const second = try int32Array(allocator, &.{3});
    defer second.deinit();

    var stream: ArrowArrayStream = undefined;
    try cdi.exportArrayStream(allocator, .int32, &.{ first, second }, &stream);
    try std.testing.expectEqual(@as(usize, 2), first.refCount());
    try std.testing.expectEqual(@as(usize, 2), second.refCount());

    var schema: ArrowSchema = undefined;
    try std.testing.expectEqual(@as(c_int, 0), stream.get_schema.?(&stream, &schema));
    defer schema.release.?(&schema);
    var imported_type = try cdi.importType(allocator, &schema);
    defer datatype.deinitOwned(allocator, &imported_type);
    try std.testing.expect(datatype.DataType.equals(.int32, imported_type));

    try expectNextInts(allocator, &stream, &.{ 1, 2 });
    try std.testing.expectEqual(@as(usize, 2), first.refCount());
    try expectNextInts(allocator, &stream, &.{3});
    try std.testing.expectEqual(@as(usize, 2), second.refCount());

    var end: ArrowArray = undefined;
    try std.testing.expectEqual(@as(c_int, 0), stream.get_next.?(&stream, &end));
    try std.testing.expect(cdi.arrayIsReleased(&end));

    stream.release.?(&stream);
    try std.testing.expect(cdi.arrayStreamIsReleased(&stream));
    try std.testing.expectEqual(@as(usize, 1), first.refCount());
    try std.testing.expectEqual(@as(usize, 1), second.refCount());
}

test "importArrayStream consumes stream and imports arrays" {
    const allocator = std.testing.allocator;
    const first = try int32Array(allocator, &.{ 10, 20 });
    defer first.deinit();
    const second = try int32Array(allocator, &.{30});
    defer second.deinit();

    var stream: ArrowArrayStream = undefined;
    try cdi.exportArrayStream(allocator, .int32, &.{ first, second }, &stream);

    const imported_stream = try cdi.importArrayStream(allocator, &stream);
    try std.testing.expect(cdi.arrayStreamIsReleased(&stream));
    try std.testing.expect(datatype.DataType.equals(.int32, imported_stream.type));

    const first_imported = (try imported_stream.next()).?;
    try expectInts(first_imported, &.{ 10, 20 });
    try std.testing.expectEqual(@as(usize, 3), first.refCount());
    first_imported.deinit();
    try std.testing.expectEqual(@as(usize, 2), first.refCount());

    const second_imported = (try imported_stream.next()).?;
    try expectInts(second_imported, &.{30});
    second_imported.deinit();
    try std.testing.expectEqual(@as(usize, 2), second.refCount());

    try std.testing.expect((try imported_stream.next()) == null);

    imported_stream.deinit();
    try std.testing.expectEqual(@as(usize, 1), first.refCount());
    try std.testing.expectEqual(@as(usize, 1), second.refCount());
}

test "exportArrayStream rejects mismatched array type" {
    const allocator = std.testing.allocator;
    const first = try int32Array(allocator, &.{1});
    defer first.deinit();
    const second = try int64Array(allocator, &.{2});
    defer second.deinit();

    var stream: ArrowArrayStream = undefined;
    try std.testing.expectError(
        error.ArrayTypeMismatch,
        cdi.exportArrayStream(allocator, .int32, &.{ first, second }, &stream),
    );
    try std.testing.expectEqual(@as(usize, 1), first.refCount());
    try std.testing.expectEqual(@as(usize, 1), second.refCount());
}

test "importArrayStream rejects invalid streams" {
    const allocator = std.testing.allocator;
    var released = minimalStream();
    try std.testing.expectError(error.ReleasedArrayStream, cdi.importArrayStream(allocator, &released));

    var missing_get_schema = minimalStream();
    missing_get_schema.release = noopStreamRelease;
    try std.testing.expectError(error.MissingCallback, cdi.importArrayStream(allocator, &missing_get_schema));

    var failing_schema = minimalStream();
    failing_schema.release = noopStreamRelease;
    failing_schema.get_schema = failGetSchema;
    failing_schema.get_next = failGetNext;
    try std.testing.expectError(error.StreamCallbackFailed, cdi.importArrayStream(allocator, &failing_schema));
}

test "importArrayStream releases callback output on failure" {
    const allocator = std.testing.allocator;
    var schema_ctx = FailCtx{};
    var schema_stream = minimalStream();
    schema_stream.get_schema = failGetAllocatedSchema;
    schema_stream.get_next = failGetNext;
    schema_stream.release = noopStreamRelease;
    schema_stream.private_data = &schema_ctx;

    try std.testing.expectError(error.StreamCallbackFailed, cdi.importArrayStream(allocator, &schema_stream));
    try std.testing.expectEqual(@as(usize, 1), schema_ctx.release_count);

    var array_ctx = FailCtx{};
    var array_stream = minimalStream();
    array_stream.get_schema = getInt32Schema;
    array_stream.get_next = failGetAllocatedArray;
    array_stream.release = noopStreamRelease;
    array_stream.private_data = &array_ctx;

    const imported_stream = try cdi.importArrayStream(allocator, &array_stream);
    defer imported_stream.deinit();
    try std.testing.expectError(error.StreamCallbackFailed, imported_stream.next());
    try std.testing.expectEqual(@as(usize, 1), array_ctx.release_count);
}

fn expectNextInts(allocator: std.mem.Allocator, stream: *ArrowArrayStream, expected: []const i32) !void {
    var arr: ArrowArray = undefined;
    try std.testing.expectEqual(@as(c_int, 0), stream.get_next.?(&stream.*, &arr));
    try std.testing.expect(!cdi.arrayIsReleased(&arr));

    const imported = try cdi.importArray(allocator, .int32, &arr);
    defer imported.deinit();
    try expectInts(imported, expected);
}

fn expectInts(data: *ArrayData, expected: []const i32) !void {
    const view = try array.NumericArray(i32).fromData(data);
    try std.testing.expectEqual(expected.len, view.view.base.len);
    for (expected, 0..) |value, i| {
        try std.testing.expectEqual(value, view.value(i));
    }
}

fn int32Array(allocator: std.mem.Allocator, values: []const i32) !*ArrayData {
    var b = builder.NumericBuilder(i32).init(allocator);
    defer b.deinit();
    try b.appendSlice(values);
    return try b.finish();
}

fn int64Array(allocator: std.mem.Allocator, values: []const i64) !*ArrayData {
    var b = builder.NumericBuilder(i64).init(allocator);
    defer b.deinit();
    try b.appendSlice(values);
    return try b.finish();
}

fn minimalStream() ArrowArrayStream {
    return .{
        .get_schema = null,
        .get_next = null,
        .get_last_error = null,
        .release = null,
        .private_data = null,
    };
}

const FailCtx = struct {
    release_count: usize = 0,
};

fn noopStreamRelease(stream: *ArrowArrayStream) callconv(.c) void {
    stream.release = null;
}

fn countSchemaRelease(schema: *ArrowSchema) callconv(.c) void {
    const ctx: *FailCtx = @ptrCast(@alignCast(schema.private_data.?));
    ctx.release_count += 1;
    schema.release = null;
}

fn countArrayRelease(arr: *ArrowArray) callconv(.c) void {
    const ctx: *FailCtx = @ptrCast(@alignCast(arr.private_data.?));
    ctx.release_count += 1;
    arr.release = null;
}

fn getInt32Schema(stream: *ArrowArrayStream, out: *ArrowSchema) callconv(.c) c_int {
    _ = stream;
    out.* = int32Schema(null);
    return 0;
}

fn failGetSchema(stream: *ArrowArrayStream, out: *ArrowSchema) callconv(.c) c_int {
    _ = stream;
    out.release = null;
    return 22;
}

fn failGetAllocatedSchema(stream: *ArrowArrayStream, out: *ArrowSchema) callconv(.c) c_int {
    const ctx: *FailCtx = @ptrCast(@alignCast(stream.private_data.?));
    out.* = int32Schema(ctx);
    return 22;
}

fn failGetNext(stream: *ArrowArrayStream, out: *ArrowArray) callconv(.c) c_int {
    _ = stream;
    out.release = null;
    return 22;
}

fn failGetAllocatedArray(stream: *ArrowArrayStream, out: *ArrowArray) callconv(.c) c_int {
    const ctx: *FailCtx = @ptrCast(@alignCast(stream.private_data.?));
    out.* = .{
        .length = 0,
        .null_count = 0,
        .offset = 0,
        .n_buffers = 0,
        .n_children = 0,
        .buffers = null,
        .children = null,
        .dictionary = null,
        .release = countArrayRelease,
        .private_data = ctx,
    };
    return 22;
}

fn int32Schema(ctx: ?*FailCtx) ArrowSchema {
    return .{
        .format = "i",
        .name = null,
        .metadata = null,
        .flags = cdi.schema_flag_nullable,
        .n_children = 0,
        .children = null,
        .dictionary = null,
        .release = if (ctx == null) noopSchemaRelease else countSchemaRelease,
        .private_data = ctx,
    };
}

fn noopSchemaRelease(schema: *ArrowSchema) callconv(.c) void {
    schema.release = null;
}
