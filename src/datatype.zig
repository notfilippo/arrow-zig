const std = @import("std");
const Allocator = std.mem.Allocator;

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

pub const NullLayout = enum { bitmap, none, always_null };

pub const BufferKind = enum {
    validity,
    values,
    offsets,
    type_ids,
    union_offsets,
    always_null,
};

pub const BufferSpec = struct {
    kind: BufferKind,
    byte_width: usize = 0,
    bit_width: u16 = 0,
};

pub const Layout = struct {
    buffers: []const BufferSpec,
    null_layout: NullLayout = .bitmap,
    has_dictionary: bool = false,
};

const null_buffers = [_]BufferSpec{.{ .kind = .always_null }};
const bool_buffers = [_]BufferSpec{
    .{ .kind = .validity },
    .{ .kind = .values, .bit_width = 1 },
};
const fixed_1_buffers = [_]BufferSpec{
    .{ .kind = .validity },
    .{ .kind = .values, .byte_width = 1 },
};
const fixed_2_buffers = [_]BufferSpec{
    .{ .kind = .validity },
    .{ .kind = .values, .byte_width = 2 },
};
const fixed_4_buffers = [_]BufferSpec{
    .{ .kind = .validity },
    .{ .kind = .values, .byte_width = 4 },
};
const fixed_8_buffers = [_]BufferSpec{
    .{ .kind = .validity },
    .{ .kind = .values, .byte_width = 8 },
};
const binary_buffers = [_]BufferSpec{
    .{ .kind = .validity },
    .{ .kind = .offsets, .byte_width = 4 },
    .{ .kind = .values },
};
const large_binary_buffers = [_]BufferSpec{
    .{ .kind = .validity },
    .{ .kind = .offsets, .byte_width = 8 },
    .{ .kind = .values },
};
const list_buffers = [_]BufferSpec{
    .{ .kind = .validity },
    .{ .kind = .offsets, .byte_width = 4 },
};
const large_list_buffers = [_]BufferSpec{
    .{ .kind = .validity },
    .{ .kind = .offsets, .byte_width = 8 },
};
const nested_validity_buffers = [_]BufferSpec{.{ .kind = .validity }};
const sparse_union_buffers = [_]BufferSpec{
    .{ .kind = .always_null },
    .{ .kind = .type_ids, .byte_width = 1 },
};
const dense_union_buffers = [_]BufferSpec{
    .{ .kind = .always_null },
    .{ .kind = .type_ids, .byte_width = 1 },
    .{ .kind = .union_offsets, .byte_width = 4 },
};

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
        .dictionary => |meta| .{ .dictionary = .{
            .index_type = try cloneTypePtr(allocator, meta.index_type.*),
            .value_type = try cloneTypePtr(allocator, meta.value_type.*),
            .ordered = meta.ordered,
        } },
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
        return switch (self) {
            .null_ => .{ .buffers = &null_buffers, .null_layout = .always_null },
            .bool => .{ .buffers = &bool_buffers },
            .int8, .uint8 => .{ .buffers = &fixed_1_buffers },
            .int16, .uint16, .float16 => .{ .buffers = &fixed_2_buffers },
            .int32, .uint32, .float32, .date32, .time32 => .{ .buffers = &fixed_4_buffers },
            .int64, .uint64, .float64, .date64, .time64, .timestamp, .duration => .{ .buffers = &fixed_8_buffers },
            .binary, .utf8 => .{ .buffers = &binary_buffers },
            .large_binary, .large_utf8 => .{ .buffers = &large_binary_buffers },
            .list => .{ .buffers = &list_buffers },
            .large_list => .{ .buffers = &large_list_buffers },
            .fixed_size_list, .struct_ => .{ .buffers = &nested_validity_buffers },
            .sparse_union => .{ .buffers = &sparse_union_buffers, .null_layout = .none },
            .dense_union => .{ .buffers = &dense_union_buffers, .null_layout = .none },
            .dictionary => |meta| blk: {
                var child_layout = meta.index_type.layout();
                child_layout.has_dictionary = true;
                break :blk child_layout;
            },
        };
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
    for (meta.type_ids) |id| {
        if (id < 0) return error.InvalidUnionTypeIds;
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

test "DataType.layout" {
    const int32_ty: DataType = .int32;
    const binary_ty: DataType = .binary;
    try std.testing.expectEqual(@as(usize, 2), int32_ty.layout().buffers.len);
    try std.testing.expectEqual(BufferKind.values, int32_ty.layout().buffers[1].kind);
    try std.testing.expectEqual(@as(usize, 4), int32_ty.layout().buffers[1].byte_width);
    try std.testing.expectEqual(@as(usize, 3), binary_ty.layout().buffers.len);
    try std.testing.expectEqual(BufferKind.offsets, binary_ty.layout().buffers[1].kind);
    try std.testing.expectEqual(NullLayout.none, (DataType{ .dense_union = .{ .fields = &.{}, .type_ids = &.{} } }).layout().null_layout);
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
