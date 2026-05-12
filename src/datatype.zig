// Copyright 2026 Filippo Rossi
// SPDX-License-Identifier: Apache-2.0

//! Arrow data type metadata.
//!
//! Data types describe physical storage, logical metadata, nested fields,
//! dictionaries, and layout expectations used by builders and validation.

const std = @import("std");
const Allocator = std.mem.Allocator;
const datatype_layout = @import("datatype_layout.zig");

pub const TypeId = enum(u8) {
    null_,
    bool,
    int8,
    int16,
    int32,
    int64,
    uint8,
    uint16,
    uint32,
    uint64,
    float16,
    float32,
    float64,
    date32,
    date64,
    time32,
    time64,
    timestamp,
    duration,
    binary,
    utf8,
    large_binary,
    large_utf8,
    list,
    large_list,
    fixed_size_list,
    struct_,
    sparse_union,
    dense_union,
    dictionary,
};

/// Temporal resolution for time32, time64, timestamp, and duration types.
pub const TimeUnit = enum { second, millisecond, microsecond, nanosecond };

/// Metadata for the timestamp type (unit + optional timezone string).
pub const TimestampMeta = struct { unit: TimeUnit, tz: ?[]const u8 };

pub const Field = struct {
    name: []const u8 = "",
    type: *const DataType,
    nullable: bool = true,

    pub fn equals(a: Field, b: Field) bool {
        return std.mem.eql(u8, a.name, b.name) and
            a.nullable == b.nullable and
            DataType.equals(a.type.*, b.type.*);
    }
};

pub const ListMeta = struct {
    child: Field,
};

pub const FixedSizeListMeta = struct {
    child: Field,
    len: usize,
};

pub const StructMeta = struct {
    fields: []const Field,
};

pub const UnionMeta = struct {
    fields: []const Field,
    type_ids: []const i8,
};

pub const DictionaryMeta = struct {
    index_type: *const DataType,
    value_type: *const DataType,
    ordered: bool = false,
};

pub const NullLayout = datatype_layout.NullLayout;
pub const BufferKind = datatype_layout.BufferKind;
pub const BufferSpec = datatype_layout.BufferSpec;
pub const Layout = datatype_layout.Layout;

pub const ValidationError = error{
    InvalidTimeUnit,
    InvalidUnionTypeIds,
    InvalidDictionaryIndexType,
};

pub fn cloneOwned(allocator: Allocator, ty: DataType) Allocator.Error!DataType {
    return switch (ty) {
        .timestamp => |meta| .{ .timestamp = .{
            .unit = meta.unit,
            .tz = if (meta.tz) |tz| try allocator.dupe(u8, tz) else null,
        } },
        .list => |meta| .{ .list = .{ .child = try cloneField(allocator, meta.child) } },
        .large_list => |meta| .{ .large_list = .{ .child = try cloneField(allocator, meta.child) } },
        .fixed_size_list => |meta| .{ .fixed_size_list = .{
            .child = try cloneField(allocator, meta.child),
            .len = meta.len,
        } },
        .struct_ => |meta| .{ .struct_ = .{ .fields = try cloneFields(allocator, meta.fields) } },
        .sparse_union => |meta| .{ .sparse_union = try cloneUnionMeta(allocator, meta) },
        .dense_union => |meta| .{ .dense_union = try cloneUnionMeta(allocator, meta) },
        .dictionary => |meta| .{ .dictionary = try cloneDictionaryMeta(allocator, meta) },
        else => ty,
    };
}

pub fn deinitOwned(allocator: Allocator, ty: *DataType) void {
    switch (ty.*) {
        .timestamp => |meta| if (meta.tz) |tz| allocator.free(tz),
        .list => |meta| deinitField(allocator, meta.child),
        .large_list => |meta| deinitField(allocator, meta.child),
        .fixed_size_list => |meta| deinitField(allocator, meta.child),
        .struct_ => |meta| deinitFields(allocator, meta.fields),
        .sparse_union => |meta| deinitUnionMeta(allocator, meta),
        .dense_union => |meta| deinitUnionMeta(allocator, meta),
        .dictionary => |meta| {
            deinitTypePtr(allocator, meta.index_type);
            deinitTypePtr(allocator, meta.value_type);
        },
        else => {},
    }
    ty.* = .null_;
}

/// Deinitialize a field with owned name and type metadata.
pub fn deinitOwnedField(allocator: Allocator, field: Field) void {
    deinitField(allocator, field);
}

pub const DataType = union(TypeId) {
    null_,
    bool,
    int8,
    int16,
    int32,
    int64,
    uint8,
    uint16,
    uint32,
    uint64,
    float16,
    float32,
    float64,
    date32,
    date64,
    time32: TimeUnit,
    time64: TimeUnit,
    timestamp: TimestampMeta,
    duration: TimeUnit,
    binary,
    utf8,
    large_binary,
    large_utf8,
    list: ListMeta,
    large_list: ListMeta,
    fixed_size_list: FixedSizeListMeta,
    struct_: StructMeta,
    sparse_union: UnionMeta,
    dense_union: UnionMeta,
    dictionary: DictionaryMeta,

    /// Return the TypeId tag without the payload.
    pub fn id(self: DataType) TypeId {
        return @as(TypeId, self);
    }

    /// Return the physical bit width of a single value.
    pub fn bitWidth(self: DataType) u16 {
        return switch (self) {
            .null_ => 0,
            .bool => 1,
            .int8, .uint8 => 8,
            .int16, .uint16, .float16 => 16,
            .int32, .uint32, .float32, .date32, .time32 => 32,
            .int64, .uint64, .float64, .date64, .time64, .timestamp, .duration => 64,
            .binary, .utf8, .large_binary, .large_utf8, .list, .large_list, .fixed_size_list, .struct_, .sparse_union, .dense_union => 0,
            .dictionary => |meta| meta.index_type.bitWidth(),
        };
    }

    /// Return a canonical string name for the type (e.g. "int32", "timestamp").
    pub fn name(self: DataType) []const u8 {
        return switch (self) {
            .null_ => "null",
            .bool => "bool",
            .int8 => "int8",
            .int16 => "int16",
            .int32 => "int32",
            .int64 => "int64",
            .uint8 => "uint8",
            .uint16 => "uint16",
            .uint32 => "uint32",
            .uint64 => "uint64",
            .float16 => "float16",
            .float32 => "float32",
            .float64 => "float64",
            .date32 => "date32",
            .date64 => "date64",
            .time32 => "time32",
            .time64 => "time64",
            .timestamp => "timestamp",
            .duration => "duration",
            .binary => "binary",
            .utf8 => "utf8",
            .large_binary => "large_binary",
            .large_utf8 => "large_utf8",
            .list => "list",
            .large_list => "large_list",
            .fixed_size_list => "fixed_size_list",
            .struct_ => "struct",
            .sparse_union => "sparse_union",
            .dense_union => "dense_union",
            .dictionary => "dictionary",
        };
    }

    pub fn validate(self: DataType) ValidationError!void {
        switch (self) {
            .time32 => |unit| switch (unit) {
                .second, .millisecond => {},
                .microsecond, .nanosecond => return error.InvalidTimeUnit,
            },
            .time64 => |unit| switch (unit) {
                .microsecond, .nanosecond => {},
                .second, .millisecond => return error.InvalidTimeUnit,
            },
            .list => |meta| try meta.child.type.validate(),
            .large_list => |meta| try meta.child.type.validate(),
            .fixed_size_list => |meta| try meta.child.type.validate(),
            .struct_ => |meta| {
                for (meta.fields) |field| try field.type.validate();
            },
            .sparse_union => |meta| try validateUnionMeta(meta),
            .dense_union => |meta| try validateUnionMeta(meta),
            .dictionary => |meta| {
                try meta.index_type.validate();
                try meta.value_type.validate();
                if (!meta.index_type.isInteger()) return error.InvalidDictionaryIndexType;
            },
            else => {},
        }
    }

    pub fn isInteger(self: DataType) bool {
        return switch (self) {
            .int8, .int16, .int32, .int64, .uint8, .uint16, .uint32, .uint64 => true,
            else => false,
        };
    }

    pub fn childCount(self: DataType) usize {
        return switch (self) {
            .list, .large_list => 1,
            .fixed_size_list => 1,
            .struct_ => |meta| meta.fields.len,
            .sparse_union, .dense_union => |meta| meta.fields.len,
            else => 0,
        };
    }

    pub fn layout(self: DataType) Layout {
        return datatype_layout.layout(self);
    }

    pub fn equals(a: DataType, b: DataType) bool {
        if (a.id() != b.id()) return false;
        return switch (a) {
            .time32 => a.time32 == b.time32,
            .time64 => a.time64 == b.time64,
            .duration => a.duration == b.duration,
            .timestamp => a.timestamp.unit == b.timestamp.unit and
                std.mem.eql(u8, a.timestamp.tz orelse "", b.timestamp.tz orelse ""),
            .list => Field.equals(a.list.child, b.list.child),
            .large_list => Field.equals(a.large_list.child, b.large_list.child),
            .fixed_size_list => a.fixed_size_list.len == b.fixed_size_list.len and
                Field.equals(a.fixed_size_list.child, b.fixed_size_list.child),
            .struct_ => fieldsEqual(a.struct_.fields, b.struct_.fields),
            .sparse_union => unionEqual(a.sparse_union, b.sparse_union),
            .dense_union => unionEqual(a.dense_union, b.dense_union),
            .dictionary => DataType.equals(a.dictionary.index_type.*, b.dictionary.index_type.*) and
                DataType.equals(a.dictionary.value_type.*, b.dictionary.value_type.*) and
                a.dictionary.ordered == b.dictionary.ordered,
            else => true,
        };
    }
};

fn cloneTypePtr(allocator: Allocator, ty: DataType) Allocator.Error!*const DataType {
    const ptr = try allocator.create(DataType);
    errdefer allocator.destroy(ptr);
    ptr.* = try cloneOwned(allocator, ty);
    return ptr;
}

fn cloneField(allocator: Allocator, field: Field) Allocator.Error!Field {
    const name = try allocator.dupe(u8, field.name);
    errdefer allocator.free(name);

    const ty = try cloneTypePtr(allocator, field.type.*);
    return .{
        .name = name,
        .type = ty,
        .nullable = field.nullable,
    };
}

fn cloneFields(allocator: Allocator, fields: []const Field) Allocator.Error![]const Field {
    const cloned = try allocator.alloc(Field, fields.len);
    errdefer allocator.free(cloned);

    var cloned_len: usize = 0;
    errdefer {
        for (cloned[0..cloned_len]) |field| deinitField(allocator, field);
    }

    for (fields, 0..) |field, i| {
        cloned[i] = try cloneField(allocator, field);
        cloned_len += 1;
    }
    return cloned;
}

fn cloneUnionMeta(allocator: Allocator, meta: UnionMeta) Allocator.Error!UnionMeta {
    const fields = try cloneFields(allocator, meta.fields);
    errdefer deinitFields(allocator, fields);

    const type_ids = try allocator.dupe(i8, meta.type_ids);
    return .{
        .fields = fields,
        .type_ids = type_ids,
    };
}

fn cloneDictionaryMeta(allocator: Allocator, meta: DictionaryMeta) Allocator.Error!DictionaryMeta {
    const index_type = try cloneTypePtr(allocator, meta.index_type.*);
    errdefer deinitTypePtr(allocator, index_type);

    const value_type = try cloneTypePtr(allocator, meta.value_type.*);
    return .{
        .index_type = index_type,
        .value_type = value_type,
        .ordered = meta.ordered,
    };
}

fn deinitTypePtr(allocator: Allocator, ty: *const DataType) void {
    const ptr = @constCast(ty);
    deinitOwned(allocator, ptr);
    allocator.destroy(ptr);
}

fn deinitField(allocator: Allocator, field: Field) void {
    allocator.free(field.name);
    deinitTypePtr(allocator, field.type);
}

fn deinitFields(allocator: Allocator, fields: []const Field) void {
    for (fields) |field| deinitField(allocator, field);
    allocator.free(fields);
}

fn deinitUnionMeta(allocator: Allocator, meta: UnionMeta) void {
    deinitFields(allocator, meta.fields);
    allocator.free(meta.type_ids);
}

fn validateUnionMeta(meta: UnionMeta) ValidationError!void {
    if (meta.fields.len != meta.type_ids.len) return error.InvalidUnionTypeIds;
    for (meta.type_ids, 0..) |id, i| {
        if (id < 0) return error.InvalidUnionTypeIds;
        for (meta.type_ids[0..i]) |seen| {
            if (seen == id) return error.InvalidUnionTypeIds;
        }
    }
    for (meta.fields) |field| try field.type.validate();
}

fn fieldsEqual(a: []const Field, b: []const Field) bool {
    if (a.len != b.len) return false;
    for (a, b) |left, right| {
        if (!Field.equals(left, right)) return false;
    }
    return true;
}

fn unionEqual(a: UnionMeta, b: UnionMeta) bool {
    return fieldsEqual(a.fields, b.fields) and std.mem.eql(i8, a.type_ids, b.type_ids);
}

test "DataType.equals" {
    try std.testing.expect(DataType.equals(.int32, .int32));
    try std.testing.expect(!DataType.equals(.int32, .int64));
    const ts_a = DataType{ .timestamp = .{ .unit = .microsecond, .tz = "UTC" } };
    const ts_b = DataType{ .timestamp = .{ .unit = .microsecond, .tz = "UTC" } };
    const ts_c = DataType{ .timestamp = .{ .unit = .millisecond, .tz = "UTC" } };
    try std.testing.expect(DataType.equals(ts_a, ts_b));
    try std.testing.expect(!DataType.equals(ts_a, ts_c));

    const value_ty: DataType = .int32;
    const list_a = DataType{ .list = .{ .child = .{ .name = "item", .type = &value_ty } } };
    const list_b = DataType{ .list = .{ .child = .{ .name = "item", .type = &value_ty } } };
    try std.testing.expect(DataType.equals(list_a, list_b));
}

test "DataType.bitWidth" {
    try std.testing.expectEqual(@as(u16, 1), DataType.bitWidth(.bool));
    try std.testing.expectEqual(@as(u16, 32), DataType.bitWidth(.int32));
    try std.testing.expectEqual(@as(u16, 64), DataType.bitWidth(.float64));
    try std.testing.expectEqual(@as(u16, 0), DataType.bitWidth(.binary));
}

test "DataType.validate" {
    try DataType.validate(.{ .time32 = .second });
    try DataType.validate(.{ .time64 = .nanosecond });
    try std.testing.expectError(error.InvalidTimeUnit, DataType.validate(.{ .time32 = .microsecond }));
    try std.testing.expectError(error.InvalidTimeUnit, DataType.validate(.{ .time64 = .millisecond }));

    const index_ty: DataType = .float64;
    const value_ty: DataType = .int32;
    const dict = DataType{ .dictionary = .{ .index_type = &index_ty, .value_type = &value_ty } };
    try std.testing.expectError(error.InvalidDictionaryIndexType, dict.validate());

    const union_field_ty: DataType = .int32;
    const fields = [_]Field{
        .{ .name = "a", .type = &union_field_ty },
        .{ .name = "b", .type = &union_field_ty },
    };
    const duplicate_ids = [_]i8{ 1, 1 };
    const duplicate_union = DataType{ .dense_union = .{ .fields = &fields, .type_ids = &duplicate_ids } };
    try std.testing.expectError(error.InvalidUnionTypeIds, duplicate_union.validate());
}

test "DataType cloneOwned owns child pointers" {
    const allocator = std.testing.allocator;
    const child_ty: DataType = .int32;
    const fields = [_]Field{.{ .name = "items", .type = &child_ty }};
    const source = DataType{ .struct_ = .{ .fields = &fields } };

    var cloned = try cloneOwned(allocator, source);
    defer deinitOwned(allocator, &cloned);

    try std.testing.expect(DataType.equals(source, cloned));
    try std.testing.expect(cloned.struct_.fields.ptr != fields[0..].ptr);
    try std.testing.expect(cloned.struct_.fields[0].type != &child_ty);
    try std.testing.expectEqualStrings("items", cloned.struct_.fields[0].name);
}

fn cloneDictionaryForFailureTest(allocator: Allocator) !void {
    const index_ty: DataType = .int32;
    const child_ty: DataType = .int64;
    const fields = [_]Field{.{ .name = "value", .type = &child_ty }};
    const value_ty = DataType{ .struct_ = .{ .fields = &fields } };
    const source = DataType{ .dictionary = .{
        .index_type = &index_ty,
        .value_type = &value_ty,
    } };

    var cloned = try cloneOwned(allocator, source);
    defer deinitOwned(allocator, &cloned);
}

test "DataType cloneOwned dictionary handles allocation failures" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, cloneDictionaryForFailureTest, .{});
}
