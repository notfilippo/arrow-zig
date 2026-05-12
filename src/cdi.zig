//! Arrow C Data Interface export.
//!
//! Exported schemas and arrays retain the source metadata and array storage
//! until the C Data Interface release callback is invoked.

const std = @import("std");
const Allocator = std.mem.Allocator;
const array = @import("array.zig");
const checked = @import("checked.zig");
const datatype = @import("datatype.zig");

const ArrayData = array.ArrayData;

pub const schema_flag_dictionary_ordered: i64 = 1;
pub const schema_flag_nullable: i64 = 2;

pub const SchemaExportError = Allocator.Error || datatype.ValidationError || error{
    InvalidTimeUnit,
    ValueOutOfRange,
};

pub const ArrayExportError = SchemaExportError || array.ValidateError || checked.Error;

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

pub fn exportType(allocator: Allocator, ty: datatype.DataType, out: *ArrowSchema) SchemaExportError!void {
    try exportSchemaNode(allocator, ty, null, true, out);
}

pub fn exportField(allocator: Allocator, field: datatype.Field, out: *ArrowSchema) SchemaExportError!void {
    try exportSchemaNode(allocator, field.type.*, field, field.nullable, out);
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

fn bufferPointer(buf: *const @import("buffer.zig").Buffer) ?*const anyopaque {
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

test "exportType primitive schema" {
    const allocator = std.testing.allocator;
    var schema: ArrowSchema = undefined;
    try exportType(allocator, .int32, &schema);
    defer schema.release.?(&schema);

    try std.testing.expectEqualStrings("i", std.mem.span(schema.format.?));
    try std.testing.expectEqual(schema_flag_nullable, schema.flags);
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

test "exportArray keeps array data alive" {
    const allocator = std.testing.allocator;
    const builder = @import("builder.zig");
    var b = builder.BinaryBuilder.init(allocator);
    defer b.deinit();
    try b.append("abc");
    try b.appendNull();

    const data = try b.finish();
    defer data.deinit();

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

test "exportArray exports nested list arrays" {
    const allocator = std.testing.allocator;
    const values = try @import("buffer.zig").Buffer.allocate(allocator, 2 * @sizeOf(i32));
    errdefer values.deinit();
    values.freeze();
    const child = try ArrayData.initOwned(allocator, .int32, 2, 0, 0, &.{ null, values }, &.{}, null);
    defer child.deinit();

    const offsets = try @import("buffer.zig").Buffer.allocate(allocator, 3 * @sizeOf(i32));
    errdefer offsets.deinit();
    std.mem.writeInt(i32, offsets.data[0..4], 0, .little);
    std.mem.writeInt(i32, offsets.data[4..8], 1, .little);
    std.mem.writeInt(i32, offsets.data[8..12], 2, .little);
    offsets.freeze();
    defer offsets.deinit();

    const value_ty: datatype.DataType = .int32;
    const list_ty = datatype.DataType{ .list = .{ .child = .{ .type = &value_ty } } };
    const data = try ArrayData.initRetained(allocator, list_ty, 2, 0, 0, &.{ null, offsets }, &.{child}, null);
    defer data.deinit();

    var exported: ArrowArray = undefined;
    try exportArray(allocator, data, &exported);
    try std.testing.expectEqual(@as(usize, 2), data.refCount());
    try std.testing.expectEqual(@as(usize, 3), child.refCount());
    try std.testing.expectEqual(@as(i64, 1), exported.n_children);
    try std.testing.expect(exported.children != null);
    try std.testing.expectEqual(@as(i64, 2), exported.children.?[0].length);
    try std.testing.expect(exported.children.?[0].buffers.?[1] != null);

    exported.release.?(&exported);
    try std.testing.expect(arrayIsReleased(&exported));
    try std.testing.expectEqual(@as(usize, 1), data.refCount());
    try std.testing.expectEqual(@as(usize, 2), child.refCount());
}
