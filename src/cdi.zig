//! Arrow C Data Interface export for flat arrays.
//! Child and dictionary export need separate ownership tables, so nested arrays are rejected for now.

const std = @import("std");
const Allocator = std.mem.Allocator;
const array = @import("array.zig");
const datatype = @import("datatype.zig");

const ArrayData = array.ArrayData;

pub const nullable: i64 = 2;

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
};

const ArrayPrivate = struct {
    allocator: Allocator,
    data: *ArrayData,
    buffers: []?*const anyopaque,
};

pub fn exportType(allocator: Allocator, ty: datatype.DataType, out: *ArrowSchema) !void {
    try ty.validate();
    const format = try formatForType(allocator, ty);
    errdefer allocator.free(format);

    const private = try allocator.create(SchemaPrivate);
    errdefer allocator.destroy(private);
    private.* = .{
        .allocator = allocator,
        .format = format,
    };

    out.* = .{
        .format = format.ptr,
        .name = null,
        .metadata = null,
        .flags = nullable,
        .n_children = 0,
        .children = null,
        .dictionary = null,
        .release = releaseSchema,
        .private_data = private,
    };
}

pub fn exportArray(allocator: Allocator, data: *ArrayData, out: *ArrowArray) !void {
    try data.validate();
    if (!canExportBufferOnlyArray(data.type)) return error.UnsupportedType;
    if (data.children.len != 0 or data.dictionary != null) return error.UnsupportedType;

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

    const private = try allocator.create(ArrayPrivate);
    errdefer allocator.destroy(private);
    errdefer data.release();
    private.* = .{
        .allocator = allocator,
        .data = data.retain(),
        .buffers = buffers,
    };

    out.* = .{
        .length = length,
        .null_count = null_count,
        .offset = offset,
        .n_buffers = n_buffers,
        .n_children = 0,
        .buffers = buffers.ptr,
        .children = null,
        .dictionary = null,
        .release = releaseArray,
        .private_data = private,
    };
}

pub fn schemaIsReleased(schema: *const ArrowSchema) bool {
    return schema.release == null;
}

pub fn arrayIsReleased(arr: *const ArrowArray) bool {
    return arr.release == null;
}

fn releaseSchema(schema: *ArrowSchema) callconv(.c) void {
    if (schema.release == null) return;
    const private: *SchemaPrivate = @ptrCast(@alignCast(schema.private_data.?));
    const allocator = private.allocator;
    allocator.free(private.format);
    allocator.destroy(private);
    schema.release = null;
}

fn releaseArray(arr: *ArrowArray) callconv(.c) void {
    if (arr.release == null) return;
    const private: *ArrayPrivate = @ptrCast(@alignCast(arr.private_data.?));
    const allocator = private.allocator;
    private.data.release();
    allocator.free(private.buffers);
    allocator.destroy(private);
    arr.release = null;
}

fn bufferPointer(buf: *const @import("buffer.zig").Buffer) ?*const anyopaque {
    if (buf.size == 0) return null;
    return @ptrCast(buf.data);
}

fn usizeToI64(value: usize) !i64 {
    if (value > @as(usize, @intCast(std.math.maxInt(i64)))) return error.ValueOutOfRange;
    return @intCast(value);
}

fn formatForType(allocator: Allocator, ty: datatype.DataType) ![:0]u8 {
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
        else => error.UnsupportedType,
    };
}

fn canExportBufferOnlyArray(ty: datatype.DataType) bool {
    return switch (ty) {
        .null_, .bool, .int8, .uint8, .int16, .uint16, .int32, .uint32, .int64, .uint64, .float16, .float32, .float64, .date32, .date64, .time32, .time64, .timestamp, .duration, .binary, .utf8, .large_binary, .large_utf8 => true,
        else => false,
    };
}

fn timeUnitCode(unit: datatype.TimeUnit) []const u8 {
    return switch (unit) {
        .second => "s",
        .millisecond => "m",
        .microsecond => "u",
        .nanosecond => "n",
    };
}

test "exportType primitive schema" {
    const allocator = std.testing.allocator;
    var schema: ArrowSchema = undefined;
    try exportType(allocator, .int32, &schema);
    defer schema.release.?(&schema);

    try std.testing.expectEqualStrings("i", std.mem.span(schema.format.?));
    try std.testing.expectEqual(nullable, schema.flags);
    try std.testing.expect(!schemaIsReleased(&schema));
}

test "exportType binary schemas" {
    const allocator = std.testing.allocator;
    var schema: ArrowSchema = undefined;
    try exportType(allocator, .utf8, &schema);
    defer schema.release.?(&schema);
    try std.testing.expectEqualStrings("u", std.mem.span(schema.format.?));
}

test "exportArray keeps array data alive" {
    const allocator = std.testing.allocator;
    const builder = @import("builder.zig");
    var b = builder.BinaryBuilder.init(allocator);
    defer b.deinit();
    try b.append("abc");
    try b.appendNull();

    const data = try b.finish();
    defer data.release();

    var exported: ArrowArray = undefined;
    try exportArray(allocator, data, &exported);
    try std.testing.expectEqual(@as(usize, 2), data.refCount());
    try std.testing.expectEqual(@as(i64, 2), exported.length);
    try std.testing.expectEqual(@as(i64, 1), exported.null_count);
    try std.testing.expectEqual(@as(i64, 3), exported.n_buffers);
    try std.testing.expect(exported.buffers.?[1] != null);
    try std.testing.expect(exported.buffers.?[2] != null);

    exported.release.?(&exported);
    try std.testing.expect(arrayIsReleased(&exported));
    try std.testing.expectEqual(@as(usize, 1), data.refCount());
}

test "exportArray rejects nested arrays until child export exists" {
    const allocator = std.testing.allocator;
    const values = try @import("buffer.zig").Buffer.allocate(allocator, 2 * @sizeOf(i32));
    errdefer values.release();
    values.freeze();
    const child = try ArrayData.init(allocator, .int32, 2, 0, 0, &.{ null, values }, &.{}, null, false);
    defer child.release();

    const offsets = try @import("buffer.zig").Buffer.allocate(allocator, 3 * @sizeOf(i32));
    errdefer offsets.release();
    std.mem.writeInt(i32, offsets.data[0..4], 0, .little);
    std.mem.writeInt(i32, offsets.data[4..8], 1, .little);
    std.mem.writeInt(i32, offsets.data[8..12], 2, .little);
    offsets.freeze();
    defer offsets.release();

    const value_ty: datatype.DataType = .int32;
    const list_ty = datatype.DataType{ .list = .{ .child = .{ .type = &value_ty } } };
    const data = try ArrayData.init(allocator, list_ty, 2, 0, 0, &.{ null, offsets }, &.{child}, null, true);
    defer data.release();

    var exported: ArrowArray = undefined;
    try std.testing.expectError(error.UnsupportedType, exportArray(allocator, data, &exported));
}
