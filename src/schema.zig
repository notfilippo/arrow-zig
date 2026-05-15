// Copyright 2026 Filippo Rossi
// SPDX-License-Identifier: Apache-2.0

//! Reference counted Arrow schemas.
//!
//! A schema owns fields and schema level key value metadata. Record batches
//! retain schemas so several batches can share one logical layout.
//! Metadata keys and values are byte strings, and order is preserved.

const std = @import("std");
const Allocator = std.mem.Allocator;
const datatype = @import("datatype.zig");
const RefCount = @import("refcount.zig").RefCount;

pub const MetadataEntry = datatype.MetadataEntry;
pub const Error = Allocator.Error || datatype.ValidationError;

pub const Schema = struct {
    allocator: Allocator,
    field_meta: []const datatype.Field,
    schema_metadata: []const MetadataEntry,
    ref_count: RefCount,

    /// Create a schema by cloning fields and metadata.
    pub fn init(allocator: Allocator, field_meta: []const datatype.Field, schema_meta: []const MetadataEntry) Error!*Schema {
        const owned_fields = try datatype.cloneOwnedFields(allocator, field_meta);
        var fields_owned = true;
        errdefer if (fields_owned) datatype.deinitOwnedFields(allocator, owned_fields);

        const owned_metadata = try datatype.cloneOwnedMetadata(allocator, schema_meta);
        var metadata_owned = true;
        errdefer if (metadata_owned) datatype.deinitOwnedMetadata(allocator, owned_metadata);

        const self = try initOwned(allocator, owned_fields, owned_metadata);
        fields_owned = false;
        metadata_owned = false;
        return self;
    }

    /// Create a schema by consuming owned fields and metadata.
    /// On success, caller must not deinit those inputs separately.
    /// On error, caller still owns every input.
    pub fn initOwned(allocator: Allocator, field_meta: []const datatype.Field, schema_meta: []const MetadataEntry) Error!*Schema {
        for (field_meta) |item| try item.type.validate();

        const self = try allocator.create(Schema);
        self.* = .{
            .allocator = allocator,
            .field_meta = field_meta,
            .schema_metadata = schema_meta,
            .ref_count = RefCount.init(1),
        };
        return self;
    }

    pub fn retain(self: *Schema) *Schema {
        _ = self.ref_count.fetchAdd(1, .monotonic);
        return self;
    }

    pub fn deinit(self: *Schema) void {
        if (self.ref_count.fetchSub(1, .acq_rel) != 1) return;
        const allocator = self.allocator;
        datatype.deinitOwnedFields(allocator, self.field_meta);
        datatype.deinitOwnedMetadata(allocator, self.schema_metadata);
        allocator.destroy(self);
    }

    pub fn refCount(self: *const Schema) usize {
        return self.ref_count.load(.monotonic);
    }

    pub fn validate(self: *const Schema) datatype.ValidationError!void {
        for (self.field_meta) |field_meta| try field_meta.type.validate();
    }

    pub fn equals(a: *const Schema, b: *const Schema) bool {
        return fieldsEqual(a.field_meta, b.field_meta) and
            metadataEqual(a.schema_metadata, b.schema_metadata);
    }

    pub fn fieldCount(self: *const Schema) usize {
        return self.field_meta.len;
    }

    pub fn fields(self: *const Schema) []const datatype.Field {
        return self.field_meta;
    }

    pub fn field(self: *const Schema, index: usize) ?datatype.Field {
        if (index >= self.field_meta.len) return null;
        return self.field_meta[index];
    }

    pub fn fieldNamed(self: *const Schema, name: []const u8) ?datatype.Field {
        for (self.field_meta) |field_meta| {
            if (std.mem.eql(u8, field_meta.name, name)) return field_meta;
        }
        return null;
    }

    pub fn metadata(self: *const Schema) []const MetadataEntry {
        return self.schema_metadata;
    }

    pub fn metadataValue(self: *const Schema, key: []const u8) ?[]const u8 {
        for (self.schema_metadata) |entry| {
            if (std.mem.eql(u8, entry.key, key)) return entry.value;
        }
        return null;
    }
};

fn fieldsEqual(a: []const datatype.Field, b: []const datatype.Field) bool {
    if (a.len != b.len) return false;
    for (a, b) |left, right| {
        if (!datatype.Field.equals(left, right)) return false;
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

test "Schema owns fields metadata and ref count" {
    const allocator = std.testing.allocator;
    const int_ty: datatype.DataType = .int32;
    const field_metadata = [_]MetadataEntry{
        .{ .key = "unit", .value = "ms" },
    };
    const fields = [_]datatype.Field{
        .{ .name = "number", .type = &int_ty, .metadata = &field_metadata },
    };
    const metadata = [_]MetadataEntry{
        .{ .key = "source", .value = "test" },
        .{ .key = "source", .value = "duplicate" },
    };

    const s = try Schema.init(allocator, &fields, &metadata);
    defer s.deinit();

    try std.testing.expectEqual(@as(usize, 1), s.refCount());
    _ = s.retain();
    try std.testing.expectEqual(@as(usize, 2), s.refCount());
    s.deinit();
    try std.testing.expectEqual(@as(usize, 1), s.refCount());

    try std.testing.expectEqual(@as(usize, 1), s.fieldCount());
    try std.testing.expectEqualStrings("number", s.field(0).?.name);
    try std.testing.expect(s.field(0).?.type != &int_ty);
    try std.testing.expectEqualStrings("ms", s.field(0).?.metadata[0].value);
    try std.testing.expect(s.field(9) == null);
    try std.testing.expect(s.fieldNamed("number") != null);
    try std.testing.expect(s.fieldNamed("missing") == null);
    try std.testing.expectEqualStrings("test", s.metadataValue("source").?);
    try std.testing.expect(s.metadataValue("missing") == null);
}

test "Schema equality includes ordered metadata" {
    const allocator = std.testing.allocator;
    const int_ty: datatype.DataType = .int32;
    const fields = [_]datatype.Field{
        .{ .name = "number", .type = &int_ty },
    };
    const metadata_a = [_]MetadataEntry{
        .{ .key = "a", .value = "1" },
        .{ .key = "b", .value = "2" },
    };
    const metadata_b = [_]MetadataEntry{
        .{ .key = "b", .value = "2" },
        .{ .key = "a", .value = "1" },
    };

    const a = try Schema.init(allocator, &fields, &metadata_a);
    defer a.deinit();
    const a2 = try Schema.init(allocator, &fields, &metadata_a);
    defer a2.deinit();
    const b = try Schema.init(allocator, &fields, &metadata_b);
    defer b.deinit();

    try std.testing.expect(Schema.equals(a, a2));
    try std.testing.expect(!Schema.equals(a, b));
}

test "Schema allocation failures" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, checkSchemaAllocationFailure, .{});
}

fn checkSchemaAllocationFailure(allocator: Allocator) !void {
    const int_ty: datatype.DataType = .int32;
    const field_metadata = [_]MetadataEntry{
        .{ .key = "unit", .value = "ms" },
    };
    const fields = [_]datatype.Field{
        .{ .name = "number", .type = &int_ty, .metadata = &field_metadata },
    };
    const metadata = [_]MetadataEntry{
        .{ .key = "source", .value = "test" },
    };

    const s = try Schema.init(allocator, &fields, &metadata);
    defer s.deinit();
    try s.validate();
}
