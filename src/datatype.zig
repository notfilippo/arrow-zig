// Copyright 2026 Filippo Rossi
// SPDX-License-Identifier: Apache-2.0

//! Arrow data type metadata.
//!
//! Data types describe physical storage, logical metadata, nested fields,
//! dictionaries, and layout expectations used by builders and validation.

const std = @import("std");
const Allocator = std.mem.Allocator;
const datatype_layout = @import("datatype_layout.zig");
const RefCount = @import("refcount.zig").RefCount;

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
    map,
    struct_,
    sparse_union,
    dense_union,
    dictionary,
};

/// Temporal resolution for time32, time64, timestamp, and duration types.
pub const TimeUnit = enum { second, millisecond, microsecond, nanosecond };

/// Metadata for the timestamp type (unit + optional timezone string).
pub const TimestampMeta = struct { unit: TimeUnit, tz: ?[]const u8 };

/// One schema or field metadata pair. Keys and values are byte strings.
pub const MetadataEntry = struct {
    key: []const u8,
    value: []const u8,

    pub fn equals(a: MetadataEntry, b: MetadataEntry) bool {
        return std.mem.eql(u8, a.key, b.key) and
            std.mem.eql(u8, a.value, b.value);
    }
};

pub const Field = struct {
    allocator: Allocator,
    name: []const u8,
    type: *const DataType,
    nullable: bool,
    metadata: []const MetadataEntry,
    ref_count: RefCount,

    /// Clone name, type, and metadata; return heap-allocated ref-counted Field.
    pub fn create(
        allocator: Allocator,
        name: []const u8,
        ty: *const DataType,
        nullable: bool,
        metadata: []const MetadataEntry,
    ) Allocator.Error!*const Field {
        const self = try allocator.create(Field);
        errdefer allocator.destroy(self);
        const owned_name = try allocator.dupe(u8, name);
        errdefer allocator.free(owned_name);
        const owned_type = try cloneTypePtr(allocator, ty.*);
        errdefer deinitTypePtr(allocator, owned_type);
        const owned_meta = try cloneOwnedMetadata(allocator, metadata);
        errdefer deinitOwnedMetadata(allocator, owned_meta);
        self.* = .{
            .allocator = allocator,
            .name = owned_name,
            .type = owned_type,
            .nullable = nullable,
            .metadata = owned_meta,
            .ref_count = RefCount.init(1),
        };
        return self;
    }

    /// Take ownership of pre-allocated name ([]u8), type (*DataType), metadata ([]MetadataEntry).
    /// On error, caller still owns all inputs.
    pub fn initOwned(
        allocator: Allocator,
        name: []u8,
        ty: *DataType,
        nullable: bool,
        metadata: []MetadataEntry,
    ) Allocator.Error!*const Field {
        const self = try allocator.create(Field);
        self.* = .{
            .allocator = allocator,
            .name = name,
            .type = ty,
            .nullable = nullable,
            .metadata = metadata,
            .ref_count = RefCount.init(1),
        };
        return self;
    }

    pub fn retain(self: *const Field) *const Field {
        const mutable = @constCast(self);
        _ = mutable.ref_count.fetchAdd(1, .monotonic);
        return self;
    }

    pub fn refCount(self: *const Field) usize {
        return self.ref_count.load(.monotonic);
    }

    pub fn deinit(self: *const Field) void {
        const mutable = @constCast(self);
        if (mutable.ref_count.fetchSub(1, .acq_rel) != 1) return;
        const allocator = mutable.allocator;
        allocator.free(mutable.name);
        deinitTypePtr(allocator, mutable.type);
        deinitOwnedMetadata(allocator, mutable.metadata);
        allocator.destroy(mutable);
    }

    pub fn equals(a: *const Field, b: *const Field) bool {
        return std.mem.eql(u8, a.name, b.name) and
            a.nullable == b.nullable and
            DataType.equals(a.type.*, b.type.*) and
            metadataEqual(a.metadata, b.metadata);
    }
};

pub const ListMeta = struct {
    child: *const Field,
};

pub const FixedSizeListMeta = struct {
    child: *const Field,
    len: usize,
};

pub const MapMeta = struct {
    entries: *const Field,
    keys_sorted: bool = false,
};

pub const StructMeta = struct {
    fields: []const *const Field,
};

pub const UnionMeta = struct {
    fields: []const *const Field,
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
    InvalidMapEntries,
    NullableMapEntries,
    NullableMapKey,
};

pub fn cloneOwned(allocator: Allocator, ty: DataType) Allocator.Error!DataType {
    return switch (ty) {
        .timestamp => |meta| .{ .timestamp = .{
            .unit = meta.unit,
            .tz = if (meta.tz) |tz| try allocator.dupe(u8, tz) else null,
        } },
        .list => |meta| .{ .list = .{ .child = meta.child.retain() } },
        .large_list => |meta| .{ .large_list = .{ .child = meta.child.retain() } },
        .fixed_size_list => |meta| .{ .fixed_size_list = .{
            .child = meta.child.retain(),
            .len = meta.len,
        } },
        .map => |meta| .{ .map = .{
            .entries = meta.entries.retain(),
            .keys_sorted = meta.keys_sorted,
        } },
        .struct_ => |meta| .{ .struct_ = .{ .fields = try retainFieldSlice(allocator, meta.fields) } },
        .sparse_union => |meta| .{ .sparse_union = try cloneUnionMeta(allocator, meta) },
        .dense_union => |meta| .{ .dense_union = try cloneUnionMeta(allocator, meta) },
        .dictionary => |meta| .{ .dictionary = try cloneDictionaryMeta(allocator, meta) },
        else => ty,
    };
}

pub fn deinitOwned(allocator: Allocator, ty: *DataType) void {
    switch (ty.*) {
        .timestamp => |meta| if (meta.tz) |tz| allocator.free(tz),
        .list => |meta| meta.child.deinit(),
        .large_list => |meta| meta.child.deinit(),
        .fixed_size_list => |meta| meta.child.deinit(),
        .map => |meta| meta.entries.deinit(),
        .struct_ => |meta| {
            for (meta.fields) |f| f.deinit();
            allocator.free(meta.fields);
        },
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

pub fn cloneOwnedMetadata(allocator: Allocator, metadata: []const MetadataEntry) Allocator.Error![]MetadataEntry {
    const cloned = try allocator.alloc(MetadataEntry, metadata.len);
    errdefer allocator.free(cloned);

    var cloned_len: usize = 0;
    errdefer {
        for (cloned[0..cloned_len]) |entry| deinitOwnedMetadataEntry(allocator, entry);
    }

    for (metadata, 0..) |entry, i| {
        cloned[i] = try cloneOwnedMetadataEntry(allocator, entry);
        cloned_len += 1;
    }
    return cloned;
}

pub fn deinitOwnedMetadata(allocator: Allocator, metadata: []const MetadataEntry) void {
    for (metadata) |entry| deinitOwnedMetadataEntry(allocator, entry);
    allocator.free(metadata);
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
    map: MapMeta,
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
            .binary, .utf8, .large_binary, .large_utf8, .list, .large_list, .fixed_size_list, .map, .struct_, .sparse_union, .dense_union => 0,
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
            .map => "map",
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
            .map => |meta| try validateMapMeta(meta),
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
            .map => 1,
            .struct_ => |meta| meta.fields.len,
            .sparse_union, .dense_union => |meta| meta.fields.len,
            else => 0,
        };
    }

    pub fn childField(self: DataType, index: usize) ?*const Field {
        return switch (self) {
            .list => |meta| if (index == 0) meta.child else null,
            .large_list => |meta| if (index == 0) meta.child else null,
            .fixed_size_list => |meta| if (index == 0) meta.child else null,
            .map => |meta| if (index == 0) meta.entries else null,
            .struct_ => |meta| if (index < meta.fields.len) meta.fields[index] else null,
            .sparse_union => |meta| if (index < meta.fields.len) meta.fields[index] else null,
            .dense_union => |meta| if (index < meta.fields.len) meta.fields[index] else null,
            else => null,
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
            .map => Field.equals(a.map.entries, b.map.entries) and
                a.map.keys_sorted == b.map.keys_sorted,
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

fn cloneTypePtr(allocator: Allocator, ty: DataType) Allocator.Error!*DataType {
    const ptr = try allocator.create(DataType);
    errdefer allocator.destroy(ptr);
    ptr.* = try cloneOwned(allocator, ty);
    return ptr;
}

fn retainFieldSlice(allocator: Allocator, fields: []const *const Field) Allocator.Error![]const *const Field {
    const owned = try allocator.alloc(*const Field, fields.len);
    for (fields, 0..) |f, i| owned[i] = f.retain();
    return owned;
}

fn cloneUnionMeta(allocator: Allocator, meta: UnionMeta) Allocator.Error!UnionMeta {
    const fields = try retainFieldSlice(allocator, meta.fields);
    errdefer {
        for (fields) |f| f.deinit();
        allocator.free(fields);
    }
    const type_ids = try allocator.dupe(i8, meta.type_ids);
    return .{ .fields = fields, .type_ids = type_ids };
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

fn deinitUnionMeta(allocator: Allocator, meta: UnionMeta) void {
    for (meta.fields) |f| f.deinit();
    allocator.free(meta.fields);
    allocator.free(meta.type_ids);
}

fn cloneOwnedMetadataEntry(allocator: Allocator, entry: MetadataEntry) Allocator.Error!MetadataEntry {
    const key = try allocator.dupe(u8, entry.key);
    errdefer allocator.free(key);

    const value = try allocator.dupe(u8, entry.value);
    return .{
        .key = key,
        .value = value,
    };
}

fn deinitOwnedMetadataEntry(allocator: Allocator, entry: MetadataEntry) void {
    allocator.free(entry.key);
    allocator.free(entry.value);
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

fn validateMapMeta(meta: MapMeta) ValidationError!void {
    if (meta.entries.nullable) return error.NullableMapEntries;
    if (meta.entries.type.id() != .struct_) return error.InvalidMapEntries;
    const fields = meta.entries.type.struct_.fields;
    if (fields.len != 2) return error.InvalidMapEntries;
    if (fields[0].nullable) return error.NullableMapKey;
    for (fields) |field| try field.type.validate();
}

fn fieldsEqual(a: []const *const Field, b: []const *const Field) bool {
    if (a.len != b.len) return false;
    for (a, b) |left, right| {
        if (!Field.equals(left, right)) return false;
    }
    return true;
}

fn metadataEqual(a: []const MetadataEntry, b: []const MetadataEntry) bool {
    if (a.len != b.len) return false;
    for (a, b) |left, right| {
        if (!MetadataEntry.equals(left, right)) return false;
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

    const allocator = std.testing.allocator;
    const value_ty: DataType = .int32;
    const item_field = try Field.create(allocator, "item", &value_ty, true, &.{});
    defer item_field.deinit();
    const list_a = DataType{ .list = .{ .child = item_field } };
    const list_b = DataType{ .list = .{ .child = item_field } };
    try std.testing.expect(DataType.equals(list_a, list_b));

    const key_field = try Field.create(allocator, "key", &value_ty, false, &.{});
    defer key_field.deinit();
    const value_field = try Field.create(allocator, "value", &value_ty, true, &.{});
    defer value_field.deinit();
    const entry_fields = [_]*const Field{ key_field, value_field };
    const entry_ty = DataType{ .struct_ = .{ .fields = &entry_fields } };
    const entries = try Field.create(allocator, "entries", &entry_ty, false, &.{});
    defer entries.deinit();
    const map_a = DataType{ .map = .{ .entries = entries, .keys_sorted = true } };
    const map_b = DataType{ .map = .{ .entries = entries, .keys_sorted = true } };
    const map_c = DataType{ .map = .{ .entries = entries, .keys_sorted = false } };
    try std.testing.expect(DataType.equals(map_a, map_b));
    try std.testing.expect(!DataType.equals(map_a, map_c));
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

    const allocator = std.testing.allocator;
    const union_field_ty: DataType = .int32;
    const field_a = try Field.create(allocator, "a", &union_field_ty, true, &.{});
    defer field_a.deinit();
    const field_b = try Field.create(allocator, "b", &union_field_ty, true, &.{});
    defer field_b.deinit();
    const fields_ptrs = [_]*const Field{ field_a, field_b };
    const duplicate_ids = [_]i8{ 1, 1 };
    const duplicate_union = DataType{ .dense_union = .{ .fields = &fields_ptrs, .type_ids = &duplicate_ids } };
    try std.testing.expectError(error.InvalidUnionTypeIds, duplicate_union.validate());

    const key_field = try Field.create(allocator, "key", &value_ty, false, &.{});
    defer key_field.deinit();
    const value_field = try Field.create(allocator, "value", &value_ty, true, &.{});
    defer value_field.deinit();
    const entry_fields = [_]*const Field{ key_field, value_field };
    const entry_ty = DataType{ .struct_ = .{ .fields = &entry_fields } };
    const entries = try Field.create(allocator, "entries", &entry_ty, false, &.{});
    defer entries.deinit();
    try DataType.validate(.{ .map = .{ .entries = entries, .keys_sorted = true } });

    const nullable_key = try Field.create(allocator, "key", &value_ty, true, &.{});
    defer nullable_key.deinit();
    const bad_entry_fields = [_]*const Field{ nullable_key, value_field };
    const bad_entry_ty = DataType{ .struct_ = .{ .fields = &bad_entry_fields } };
    const bad_entries = try Field.create(allocator, "entries", &bad_entry_ty, false, &.{});
    defer bad_entries.deinit();
    try std.testing.expectError(error.NullableMapKey, DataType.validate(.{ .map = .{ .entries = bad_entries } }));
}

test "DataType cloneOwned retains child fields" {
    const allocator = std.testing.allocator;
    const child_ty: DataType = .int32;
    const items_field = try Field.create(allocator, "items", &child_ty, true, &.{});
    defer items_field.deinit();

    const fields_ptrs = [_]*const Field{items_field};
    const source = DataType{ .struct_ = .{ .fields = &fields_ptrs } };

    var cloned = try cloneOwned(allocator, source);
    defer deinitOwned(allocator, &cloned);

    try std.testing.expect(DataType.equals(source, cloned));
    try std.testing.expect(cloned.struct_.fields.ptr != fields_ptrs[0..].ptr);
    try std.testing.expect(cloned.struct_.fields[0] == items_field);
    try std.testing.expectEqual(@as(usize, 2), items_field.refCount());
    try std.testing.expectEqualStrings("items", cloned.struct_.fields[0].name);
}

fn cloneDictionaryForFailureTest(allocator: Allocator) !void {
    const index_ty: DataType = .int32;
    const child_ty: DataType = .int64;
    const value_field = try Field.create(allocator, "value", &child_ty, true, &.{});
    defer value_field.deinit();
    const value_fields = [_]*const Field{value_field};
    const value_ty = DataType{ .struct_ = .{ .fields = &value_fields } };
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
