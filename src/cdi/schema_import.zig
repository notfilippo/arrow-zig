// Copyright 2026 Filippo Rossi
// SPDX-License-Identifier: Apache-2.0

//! Arrow C Data Interface schema parsing.

const std = @import("std");
const Allocator = std.mem.Allocator;
const cdi_types = @import("types.zig");
const cdi_metadata = @import("metadata.zig");
const datatype = @import("../datatype.zig");
const schema_mod = @import("../schema.zig");

const ArrowSchema = cdi_types.ArrowSchema;
const schema_flag_dictionary_ordered = cdi_types.schema_flag_dictionary_ordered;
const schema_flag_map_keys_sorted = cdi_types.schema_flag_map_keys_sorted;
const schema_flag_nullable = cdi_types.schema_flag_nullable;

pub const Error =
    cdi_metadata.ImportError ||
    datatype.ValidationError ||
    error{
        ReleasedSchema,
        MissingFormat,
        InvalidFormat,
        InvalidChildCount,
        InvalidDictionaryIndexType,
    };

pub fn importType(allocator: Allocator, schema: *const ArrowSchema) Error!datatype.DataType {
    var ty = try importTypeNode(allocator, schema);
    errdefer datatype.deinitOwned(allocator, &ty);
    try ty.validate();
    return ty;
}

pub fn importField(allocator: Allocator, schema: *const ArrowSchema) Error!*const datatype.Field {
    const field = try importFieldNode(allocator, schema);
    errdefer field.deinit();
    try field.type.validate();
    return field;
}

pub fn importSchema(allocator: Allocator, schema: *const ArrowSchema) Error!*schema_mod.Schema {
    if (schema.release == null) return error.ReleasedSchema;
    const format_ptr = schema.format orelse return error.MissingFormat;
    if (!std.mem.eql(u8, std.mem.span(format_ptr), "+s")) return error.InvalidFormat;
    if (schema.dictionary != null) return error.InvalidFormat;

    const fields = try importSchemaFields(allocator, schema);
    var fields_owned = true;
    errdefer if (fields_owned) {
        for (fields) |f| f.deinit();
        allocator.free(fields);
    };

    const schema_meta = try cdi_metadata.importOwned(allocator, schema.metadata);
    var metadata_owned = true;
    errdefer if (metadata_owned) datatype.deinitOwnedMetadata(allocator, schema_meta);

    const out = try schema_mod.Schema.initOwned(allocator, fields, schema_meta);
    fields_owned = false;
    metadata_owned = false;
    return out;
}

fn importTypeNode(allocator: Allocator, schema: *const ArrowSchema) Error!datatype.DataType {
    if (schema.release == null) return error.ReleasedSchema;
    const format_ptr = schema.format orelse return error.MissingFormat;
    var ty = try importFormatType(allocator, schema, std.mem.span(format_ptr));
    var ty_owned = true;
    errdefer if (ty_owned) datatype.deinitOwned(allocator, &ty);

    if (schema.dictionary) |dictionary_schema| {
        if (!ty.isInteger()) return error.InvalidDictionaryIndexType;

        const index_type = try allocator.create(datatype.DataType);
        index_type.* = ty;
        ty_owned = false;
        errdefer {
            datatype.deinitOwned(allocator, index_type);
            allocator.destroy(index_type);
        }

        var value_ty = try importTypeNode(allocator, dictionary_schema);
        var value_owned = true;
        errdefer if (value_owned) datatype.deinitOwned(allocator, &value_ty);

        const value_type = try allocator.create(datatype.DataType);
        value_type.* = value_ty;
        value_owned = false;
        errdefer {
            datatype.deinitOwned(allocator, value_type);
            allocator.destroy(value_type);
        }

        return .{ .dictionary = .{
            .index_type = index_type,
            .value_type = value_type,
            .ordered = schema.flags & schema_flag_dictionary_ordered != 0,
        } };
    }

    ty_owned = false;
    return ty;
}

fn importFormatType(
    allocator: Allocator,
    schema: *const ArrowSchema,
    format: []const u8,
) Error!datatype.DataType {
    if (std.mem.eql(u8, format, "n")) return noChildType(schema, .null_);
    if (std.mem.eql(u8, format, "b")) return noChildType(schema, .bool);
    if (std.mem.eql(u8, format, "c")) return noChildType(schema, .int8);
    if (std.mem.eql(u8, format, "C")) return noChildType(schema, .uint8);
    if (std.mem.eql(u8, format, "s")) return noChildType(schema, .int16);
    if (std.mem.eql(u8, format, "S")) return noChildType(schema, .uint16);
    if (std.mem.eql(u8, format, "i")) return noChildType(schema, .int32);
    if (std.mem.eql(u8, format, "I")) return noChildType(schema, .uint32);
    if (std.mem.eql(u8, format, "l")) return noChildType(schema, .int64);
    if (std.mem.eql(u8, format, "L")) return noChildType(schema, .uint64);
    if (std.mem.eql(u8, format, "e")) return noChildType(schema, .float16);
    if (std.mem.eql(u8, format, "f")) return noChildType(schema, .float32);
    if (std.mem.eql(u8, format, "g")) return noChildType(schema, .float64);
    if (std.mem.eql(u8, format, "z")) return noChildType(schema, .binary);
    if (std.mem.eql(u8, format, "u")) return noChildType(schema, .utf8);
    if (std.mem.eql(u8, format, "Z")) return noChildType(schema, .large_binary);
    if (std.mem.eql(u8, format, "U")) return noChildType(schema, .large_utf8);
    if (std.mem.eql(u8, format, "vz")) return noChildType(schema, .binary_view);
    if (std.mem.eql(u8, format, "vu")) return noChildType(schema, .utf8_view);
    if (std.mem.startsWith(u8, format, "w:")) return try importFixedSizeBinaryType(schema, format[2..]);
    if (std.mem.startsWith(u8, format, "d:")) return try importDecimalType(schema, format[2..]);
    if (format.len == 0) return error.InvalidFormat;
    return switch (format[0]) {
        't' => importTemporalType(allocator, schema, format),
        '+' => importNestedType(allocator, schema, format),
        else => error.InvalidFormat,
    };
}

fn noChildType(schema: *const ArrowSchema, ty: datatype.DataType) Error!datatype.DataType {
    try expectSchemaChildCount(schema, 0);
    return ty;
}

fn importTemporalType(
    allocator: Allocator,
    schema: *const ArrowSchema,
    format: []const u8,
) Error!datatype.DataType {
    try expectSchemaChildCount(schema, 0);
    if (std.mem.eql(u8, format, "tdD")) return .date32;
    if (std.mem.eql(u8, format, "tdm")) return .date64;
    if (std.mem.eql(u8, format, "tts")) return .{ .time32 = .second };
    if (std.mem.eql(u8, format, "ttm")) return .{ .time32 = .millisecond };
    if (std.mem.eql(u8, format, "ttu")) return .{ .time64 = .microsecond };
    if (std.mem.eql(u8, format, "ttn")) return .{ .time64 = .nanosecond };
    if (std.mem.eql(u8, format, "tiM")) return .month_interval;
    if (std.mem.eql(u8, format, "tiD")) return .day_time_interval;
    if (std.mem.eql(u8, format, "tin")) return .month_day_nano_interval;
    if (format.len == 3 and format[0] == 't' and format[1] == 'D') {
        return .{ .duration = try timeUnitFromCode(format[2]) };
    }
    if (format.len >= 3 and format[0] == 't' and format[1] == 's') {
        if (format.len > 3 and format[3] != ':') return error.InvalidFormat;
        const tz_src = if (format.len > 4) format[4..] else "";
        return .{ .timestamp = .{
            .unit = try timeUnitFromCode(format[2]),
            .tz = if (tz_src.len == 0) null else try allocator.dupe(u8, tz_src),
        } };
    }
    return error.InvalidFormat;
}

fn importNestedType(
    allocator: Allocator,
    schema: *const ArrowSchema,
    format: []const u8,
) Error!datatype.DataType {
    if (std.mem.eql(u8, format, "+l")) return .{ .list = .{ .child = try importSingleChildField(allocator, schema) } };
    if (std.mem.eql(u8, format, "+L")) return .{ .large_list = .{ .child = try importSingleChildField(allocator, schema) } };
    if (std.mem.eql(u8, format, "+m")) return .{ .map = .{
        .entries = try importSingleChildField(allocator, schema),
        .keys_sorted = schema.flags & schema_flag_map_keys_sorted != 0,
    } };
    if (std.mem.startsWith(u8, format, "+w:")) return try importFixedSizeListType(allocator, schema, format[3..]);
    if (std.mem.eql(u8, format, "+s")) return .{ .struct_ = .{ .fields = try importSchemaFields(allocator, schema) } };
    if (std.mem.startsWith(u8, format, "+us:")) return try importUnionType(allocator, schema, format[4..], false);
    if (std.mem.startsWith(u8, format, "+ud:")) return try importUnionType(allocator, schema, format[4..], true);
    if (std.mem.eql(u8, format, "+r")) return try importRunEndEncodedType(allocator, schema);
    return error.InvalidFormat;
}

fn importFixedSizeListType(
    allocator: Allocator,
    schema: *const ArrowSchema,
    len_text: []const u8,
) Error!datatype.DataType {
    const len = try parseUsize(len_text);
    return .{ .fixed_size_list = .{
        .child = try importSingleChildField(allocator, schema),
        .len = len,
    } };
}

fn importFixedSizeBinaryType(
    schema: *const ArrowSchema,
    width_text: []const u8,
) Error!datatype.DataType {
    try expectSchemaChildCount(schema, 0);
    return .{ .fixed_size_binary = .{ .byte_width = try parseUsize(width_text) } };
}

fn importDecimalType(
    schema: *const ArrowSchema,
    format: []const u8,
) Error!datatype.DataType {
    try expectSchemaChildCount(schema, 0);
    var parts = std.mem.splitScalar(u8, format, ',');
    const precision_text = parts.next() orelse return error.InvalidFormat;
    const scale_text = parts.next() orelse return error.InvalidFormat;
    const precision = try parseU8(precision_text);
    const scale = try parseI32(scale_text);
    const width = if (parts.next()) |width_text| try parseUsize(width_text) else 128;
    if (parts.next() != null) return error.InvalidFormat;
    return switch (width) {
        128 => .{ .decimal128 = .{ .precision = precision, .scale = scale } },
        256 => .{ .decimal256 = .{ .precision = precision, .scale = scale } },
        else => error.InvalidFormat,
    };
}

fn importSingleChildField(allocator: Allocator, schema: *const ArrowSchema) Error!*const datatype.Field {
    try expectSchemaChildCount(schema, 1);
    return try importFieldNode(allocator, schema.children.?[0]);
}

fn importSchemaFields(allocator: Allocator, schema: *const ArrowSchema) Error![]const *const datatype.Field {
    const count = try schemaChildCount(schema);
    if (count > 0 and schema.children == null) return error.InvalidChildCount;
    const fields = try allocator.alloc(*const datatype.Field, count);
    errdefer allocator.free(fields);

    var imported: usize = 0;
    errdefer for (fields[0..imported]) |f| f.deinit();

    for (0..count) |i| {
        fields[i] = try importFieldNode(allocator, schema.children.?[i]);
        imported += 1;
    }
    return fields;
}

fn importFieldNode(allocator: Allocator, schema: *const ArrowSchema) Error!*const datatype.Field {
    var ty = try importTypeNode(allocator, schema);
    var ty_owned = true;
    errdefer if (ty_owned) datatype.deinitOwned(allocator, &ty);

    const name_src = if (schema.name) |name| std.mem.span(name) else "";
    const name = try allocator.dupe(u8, name_src);
    errdefer allocator.free(name);

    const type_ptr = try allocator.create(datatype.DataType);
    var type_ptr_valid = false;
    errdefer {
        if (type_ptr_valid) datatype.deinitOwned(allocator, type_ptr);
        allocator.destroy(type_ptr);
    }
    type_ptr.* = ty;
    ty_owned = false;
    type_ptr_valid = true;

    const metadata = try cdi_metadata.importOwned(allocator, schema.metadata);
    errdefer datatype.deinitOwnedMetadata(allocator, metadata);

    const field = try datatype.Field.initOwned(
        allocator,
        name,
        type_ptr,
        schema.flags & schema_flag_nullable != 0,
        metadata,
    );
    type_ptr_valid = false;
    return field;
}

fn importUnionType(
    allocator: Allocator,
    schema: *const ArrowSchema,
    ids_text: []const u8,
    dense: bool,
) Error!datatype.DataType {
    const fields = try importSchemaFields(allocator, schema);
    errdefer {
        for (fields) |f| f.deinit();
        allocator.free(fields);
    }

    const type_ids = try parseUnionTypeIds(allocator, ids_text);
    errdefer allocator.free(type_ids);
    if (type_ids.len != fields.len) return error.InvalidChildCount;

    return if (dense)
        .{ .dense_union = .{ .fields = fields, .type_ids = type_ids } }
    else
        .{ .sparse_union = .{ .fields = fields, .type_ids = type_ids } };
}

fn importRunEndEncodedType(
    allocator: Allocator,
    schema: *const ArrowSchema,
) Error!datatype.DataType {
    try expectSchemaChildCount(schema, 2);
    const run_ends = try importFieldNode(allocator, schema.children.?[0]);
    errdefer run_ends.deinit();
    const values = try importFieldNode(allocator, schema.children.?[1]);
    errdefer values.deinit();
    return .{ .run_end_encoded = .{
        .run_ends = run_ends,
        .values = values,
    } };
}

fn expectSchemaChildCount(schema: *const ArrowSchema, expected: usize) Error!void {
    const actual = try schemaChildCount(schema);
    if (actual != expected) return error.InvalidChildCount;
    if (actual > 0 and schema.children == null) return error.InvalidChildCount;
}

fn schemaChildCount(schema: *const ArrowSchema) Error!usize {
    if (schema.n_children < 0) return error.InvalidChildCount;
    const unsigned: u64 = @intCast(schema.n_children);
    if (@as(u128, unsigned) > @as(u128, std.math.maxInt(usize))) return error.ValueOutOfRange;
    return @intCast(unsigned);
}

fn parseUsize(text: []const u8) Error!usize {
    if (text.len == 0) return error.InvalidFormat;
    const parsed = std.fmt.parseUnsigned(u64, text, 10) catch |err| switch (err) {
        error.Overflow => return error.ValueOutOfRange,
        error.InvalidCharacter => return error.InvalidFormat,
    };
    if (@as(u128, parsed) > @as(u128, std.math.maxInt(usize))) return error.ValueOutOfRange;
    return @intCast(parsed);
}

fn parseU8(text: []const u8) Error!u8 {
    const parsed = try parseUsize(text);
    if (parsed > std.math.maxInt(u8)) return error.ValueOutOfRange;
    return @intCast(parsed);
}

fn parseI32(text: []const u8) Error!i32 {
    if (text.len == 0) return error.InvalidFormat;
    return std.fmt.parseInt(i32, text, 10) catch |err| switch (err) {
        error.Overflow => return error.ValueOutOfRange,
        error.InvalidCharacter => return error.InvalidFormat,
    };
}

fn parseUnionTypeIds(allocator: Allocator, text: []const u8) Error![]const i8 {
    if (text.len == 0) return try allocator.alloc(i8, 0);
    var list: std.ArrayList(i8) = .empty;
    errdefer list.deinit(allocator);

    var parts = std.mem.splitScalar(u8, text, ',');
    while (parts.next()) |part| {
        if (part.len == 0) return error.InvalidFormat;
        const id = std.fmt.parseInt(i8, part, 10) catch return error.InvalidFormat;
        try list.append(allocator, id);
    }
    return try list.toOwnedSlice(allocator);
}

fn timeUnitFromCode(code: u8) Error!datatype.TimeUnit {
    return switch (code) {
        's' => .second,
        'm' => .millisecond,
        'u' => .microsecond,
        'n' => .nanosecond,
        else => error.InvalidFormat,
    };
}
