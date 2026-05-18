// Copyright 2026 Filippo Rossi
// SPDX-License-Identifier: Apache-2.0

//! Arrow C Data Interface schema export.

const std = @import("std");
const Allocator = std.mem.Allocator;
const cdi_metadata = @import("metadata.zig");
const cdi_types = @import("types.zig");
const datatype = @import("../datatype.zig");
const schema_mod = @import("../schema.zig");

const ArrowSchema = cdi_types.ArrowSchema;
const Schema = schema_mod.Schema;

pub const Error = cdi_metadata.ExportError || datatype.ValidationError;

pub fn exportType(allocator: Allocator, ty: datatype.DataType, out: *ArrowSchema) Error!void {
    try exportSchemaNode(allocator, ty, null, true, &.{}, out);
}

pub fn exportField(allocator: Allocator, field: *const datatype.Field, out: *ArrowSchema) Error!void {
    try exportSchemaNode(allocator, field.type.*, field, field.nullable, field.metadata, out);
}

pub fn exportSchema(allocator: Allocator, input_schema: *const Schema, out: *ArrowSchema) Error!void {
    try input_schema.validate();
    const ty = datatype.DataType{ .struct_ = .{ .fields = input_schema.fields() } };
    try exportSchemaNode(allocator, ty, null, false, input_schema.metadata(), out);
}

pub fn isReleased(schema: *const ArrowSchema) bool {
    return schema.release == null;
}

pub fn releaseIfNeeded(schema: *ArrowSchema) void {
    if (schema.release) |release_fn| release_fn(schema);
}

pub fn released() ArrowSchema {
    return .{
        .format = null,
        .name = null,
        .metadata = null,
        .flags = 0,
        .n_children = 0,
        .children = null,
        .dictionary = null,
        .release = null,
        .private_data = null,
    };
}

const SchemaPrivate = struct {
    allocator: Allocator,
    format: [:0]u8,
    name: ?[:0]u8,
    metadata: ?[]u8,
    children_storage: []ArrowSchema,
    child_ptrs: []*ArrowSchema,
    dictionary: ?*ArrowSchema,
};

fn exportSchemaNode(
    allocator: Allocator,
    ty: datatype.DataType,
    field: ?*const datatype.Field,
    nullable: bool,
    metadata: []const datatype.MetadataEntry,
    out: *ArrowSchema,
) Error!void {
    try ty.validate();
    const format = try formatForType(allocator, ty);
    errdefer allocator.free(format);

    const owned_name = if (field) |f| try allocator.dupeZ(u8, f.name) else null;
    errdefer if (owned_name) |name| allocator.free(name);

    const owned_metadata = try cdi_metadata.exportOwned(allocator, metadata);
    errdefer if (owned_metadata) |data| allocator.free(data);

    const child_count = ty.childCount();
    const n_children = try usizeToI64(child_count);
    const children_storage = try allocator.alloc(ArrowSchema, child_count);
    errdefer allocator.free(children_storage);

    const child_ptrs = try allocator.alloc(*ArrowSchema, child_count);
    errdefer allocator.free(child_ptrs);

    var exported_children: usize = 0;
    errdefer releaseSchemas(children_storage[0..exported_children]);

    for (0..child_count) |i| {
        const child_field = ty.childField(i).?;
        try exportField(allocator, child_field, &children_storage[i]);
        child_ptrs[i] = &children_storage[i];
        exported_children += 1;
    }

    var dictionary: ?*ArrowSchema = null;
    var dictionary_exported = false;
    errdefer if (dictionary) |dict| {
        if (dictionary_exported) releaseIfNeeded(dict);
        allocator.destroy(dict);
    };

    var flags: i64 = if (nullable) cdi_types.schema_flag_nullable else 0;
    switch (ty) {
        .dictionary => |meta| {
            if (meta.ordered) flags |= cdi_types.schema_flag_dictionary_ordered;
            dictionary = try allocator.create(ArrowSchema);
            try exportType(allocator, meta.value_type.*, dictionary.?);
            dictionary_exported = true;
        },
        .map => |meta| {
            if (meta.keys_sorted) flags |= cdi_types.schema_flag_map_keys_sorted;
        },
        else => {},
    }

    const private = try allocator.create(SchemaPrivate);
    errdefer allocator.destroy(private);
    private.* = .{
        .allocator = allocator,
        .format = format,
        .name = owned_name,
        .metadata = owned_metadata,
        .children_storage = children_storage,
        .child_ptrs = child_ptrs,
        .dictionary = dictionary,
    };

    out.* = .{
        .format = format.ptr,
        .name = if (owned_name) |name| name.ptr else null,
        .metadata = if (owned_metadata) |data| data.ptr else null,
        .flags = flags,
        .n_children = n_children,
        .children = if (child_ptrs.len == 0) null else child_ptrs.ptr,
        .dictionary = dictionary,
        .release = releaseSchema,
        .private_data = private,
    };
}

fn releaseSchema(schema: *ArrowSchema) callconv(.c) void {
    if (schema.release == null) return;
    const private: *SchemaPrivate = @ptrCast(@alignCast(schema.private_data.?));
    const allocator = private.allocator;
    releaseSchemas(private.children_storage);
    if (private.dictionary) |dict| {
        releaseIfNeeded(dict);
        allocator.destroy(dict);
    }
    allocator.free(private.format);
    if (private.name) |name| allocator.free(name);
    if (private.metadata) |metadata| allocator.free(metadata);
    allocator.free(private.child_ptrs);
    allocator.free(private.children_storage);
    allocator.destroy(private);
    schema.release = null;
    schema.private_data = null;
}

fn releaseSchemas(schemas: []ArrowSchema) void {
    for (schemas) |*schema| releaseIfNeeded(schema);
}

fn usizeToI64(value: usize) Error!i64 {
    if (value > @as(usize, @intCast(std.math.maxInt(i64)))) return error.ValueOutOfRange;
    return @intCast(value);
}

fn formatForType(allocator: Allocator, ty: datatype.DataType) Error![:0]u8 {
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
        .map => allocator.dupeZ(u8, "+m"),
        .fixed_size_list => |meta| std.fmt.allocPrintSentinel(allocator, "+w:{d}", .{meta.len}, 0),
        .struct_ => allocator.dupeZ(u8, "+s"),
        .sparse_union => |meta| unionFormat(allocator, "s", meta.type_ids),
        .dense_union => |meta| unionFormat(allocator, "d", meta.type_ids),
        .dictionary => |meta| formatForType(allocator, meta.index_type.*),
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
