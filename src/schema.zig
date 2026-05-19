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
pub const AccessError = error{ IndexOutOfBounds, FieldNotFound };

pub const Schema = struct {
    allocator: Allocator,
    field_meta: []const *const datatype.Field,
    schema_metadata: []const MetadataEntry,
    ref_count: RefCount,

    /// Create a schema by retaining fields and cloning metadata.
    pub fn init(allocator: Allocator, field_meta: []const *const datatype.Field, schema_meta: []const MetadataEntry) Error!*Schema {
        const owned_fields = try allocator.alloc(*const datatype.Field, field_meta.len);
        errdefer allocator.free(owned_fields);
        var retained: usize = 0;
        errdefer for (owned_fields[0..retained]) |f| f.deinit();
        for (field_meta, 0..) |f, i| {
            owned_fields[i] = f.retain();
            retained += 1;
        }
        const owned_meta = try datatype.cloneOwnedMetadata(allocator, schema_meta);
        errdefer datatype.deinitOwnedMetadata(allocator, owned_meta);
        return initOwned(allocator, owned_fields, owned_meta);
    }

    /// Create a schema by consuming owned fields slice and metadata.
    /// On success, caller must not deinit those inputs separately.
    /// On error, caller still owns every input.
    pub fn initOwned(allocator: Allocator, field_meta: []const *const datatype.Field, schema_meta: []const MetadataEntry) Error!*Schema {
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

    pub fn cloneRetained(self: *const Schema) Error!*Schema {
        return Schema.init(self.allocator, self.field_meta, self.schema_metadata);
    }

    pub fn deinit(self: *Schema) void {
        if (self.ref_count.fetchSub(1, .acq_rel) != 1) return;
        const allocator = self.allocator;
        for (self.field_meta) |f| f.deinit();
        allocator.free(self.field_meta);
        datatype.deinitOwnedMetadata(allocator, self.schema_metadata);
        allocator.destroy(self);
    }

    pub fn refCount(self: *const Schema) usize {
        return self.ref_count.load(.monotonic);
    }

    pub fn validate(self: *const Schema) datatype.ValidationError!void {
        for (self.field_meta) |f| try f.type.validate();
    }

    pub fn equals(a: *const Schema, b: *const Schema) bool {
        return fieldsEqual(a.field_meta, b.field_meta) and
            metadataEqual(a.schema_metadata, b.schema_metadata);
    }

    pub fn fieldCount(self: *const Schema) usize {
        return self.field_meta.len;
    }

    pub fn fields(self: *const Schema) []const *const datatype.Field {
        return self.field_meta;
    }

    pub fn field(self: *const Schema, index: usize) ?*const datatype.Field {
        if (index >= self.field_meta.len) return null;
        return self.field_meta[index];
    }

    pub fn fieldChecked(self: *const Schema, index: usize) AccessError!*const datatype.Field {
        return self.field(index) orelse error.IndexOutOfBounds;
    }

    pub fn fieldIndex(self: *const Schema, name: []const u8) ?usize {
        for (self.field_meta, 0..) |f, i| {
            if (std.mem.eql(u8, f.name, name)) return i;
        }
        return null;
    }

    pub fn fieldNamed(self: *const Schema, name: []const u8) ?*const datatype.Field {
        const index = self.fieldIndex(name) orelse return null;
        return self.field_meta[index];
    }

    pub fn fieldNamedChecked(self: *const Schema, name: []const u8) AccessError!*const datatype.Field {
        return self.fieldNamed(name) orelse error.FieldNotFound;
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

    pub fn replaceMetadata(self: *const Schema, schema_metadata: []const MetadataEntry) Error!*Schema {
        return Schema.init(self.allocator, self.field_meta, schema_metadata);
    }

    pub fn removeMetadata(self: *const Schema) Error!*Schema {
        return self.replaceMetadata(&.{});
    }

    pub fn addField(self: *const Schema, index: usize, field_meta: *const datatype.Field) (Error || AccessError)!*Schema {
        if (index > self.field_meta.len) return error.IndexOutOfBounds;

        const new_fields = try self.allocator.alloc(*const datatype.Field, self.field_meta.len + 1);
        defer self.allocator.free(new_fields);
        @memcpy(new_fields[0..index], self.field_meta[0..index]);
        new_fields[index] = field_meta;
        @memcpy(new_fields[index + 1 ..], self.field_meta[index..]);
        return Schema.init(self.allocator, new_fields, self.schema_metadata);
    }

    pub fn setField(self: *const Schema, index: usize, field_meta: *const datatype.Field) (Error || AccessError)!*Schema {
        if (index >= self.field_meta.len) return error.IndexOutOfBounds;

        const new_fields = try self.allocator.alloc(*const datatype.Field, self.field_meta.len);
        defer self.allocator.free(new_fields);
        @memcpy(new_fields, self.field_meta);
        new_fields[index] = field_meta;
        return Schema.init(self.allocator, new_fields, self.schema_metadata);
    }

    pub fn removeField(self: *const Schema, index: usize) (Error || AccessError)!*Schema {
        if (index >= self.field_meta.len) return error.IndexOutOfBounds;

        const new_fields = try self.allocator.alloc(*const datatype.Field, self.field_meta.len - 1);
        defer self.allocator.free(new_fields);
        @memcpy(new_fields[0..index], self.field_meta[0..index]);
        @memcpy(new_fields[index..], self.field_meta[index + 1 ..]);
        return Schema.init(self.allocator, new_fields, self.schema_metadata);
    }

    pub fn selectFields(self: *const Schema, indices: []const usize) (Error || AccessError)!*Schema {
        const new_fields = try self.allocator.alloc(*const datatype.Field, indices.len);
        defer self.allocator.free(new_fields);
        for (indices, 0..) |index, i| {
            new_fields[i] = try self.fieldChecked(index);
        }
        return Schema.init(self.allocator, new_fields, self.schema_metadata);
    }
};

fn fieldsEqual(a: []const *const datatype.Field, b: []const *const datatype.Field) bool {
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
    const number_field = try datatype.Field.create(allocator, "number", &int_ty, true, &field_metadata);
    defer number_field.deinit();
    const metadata = [_]MetadataEntry{
        .{ .key = "source", .value = "test" },
        .{ .key = "source", .value = "duplicate" },
    };

    const s = try Schema.init(allocator, &.{number_field}, &metadata);
    defer s.deinit();

    try std.testing.expectEqual(@as(usize, 1), s.refCount());
    _ = s.retain();
    try std.testing.expectEqual(@as(usize, 2), s.refCount());
    s.deinit();
    try std.testing.expectEqual(@as(usize, 1), s.refCount());

    try std.testing.expectEqual(@as(usize, 1), s.fieldCount());
    try std.testing.expectEqualStrings("number", s.field(0).?.name);
    try std.testing.expectEqualStrings("number", (try s.fieldChecked(0)).name);
    try std.testing.expect(s.field(0).?.type != &int_ty);
    try std.testing.expectEqualStrings("ms", s.field(0).?.metadata[0].value);
    try std.testing.expect(s.field(9) == null);
    try std.testing.expectError(error.IndexOutOfBounds, s.fieldChecked(9));
    try std.testing.expectEqual(@as(?usize, 0), s.fieldIndex("number"));
    try std.testing.expect(s.fieldNamed("number") != null);
    try std.testing.expectEqualStrings("number", (try s.fieldNamedChecked("number")).name);
    try std.testing.expect(s.fieldNamed("missing") == null);
    try std.testing.expectError(error.FieldNotFound, s.fieldNamedChecked("missing"));
    try std.testing.expectEqualStrings("test", s.metadataValue("source").?);
    try std.testing.expect(s.metadataValue("missing") == null);

    const clone = try s.cloneRetained();
    defer clone.deinit();
    try std.testing.expect(Schema.equals(s, clone));

    const no_metadata = try s.removeMetadata();
    defer no_metadata.deinit();
    try std.testing.expectEqual(@as(usize, 0), no_metadata.metadata().len);

    const bool_ty: datatype.DataType = .bool;
    const flag_field = try datatype.Field.create(allocator, "flag", &bool_ty, false, &.{});
    defer flag_field.deinit();

    const added = try s.addField(1, flag_field);
    defer added.deinit();
    try std.testing.expectEqual(@as(usize, 2), added.fieldCount());
    try std.testing.expectEqualStrings("flag", added.field(1).?.name);

    const set = try added.setField(0, flag_field);
    defer set.deinit();
    try std.testing.expectEqualStrings("flag", set.field(0).?.name);

    const selected = try added.selectFields(&.{1});
    defer selected.deinit();
    try std.testing.expectEqual(@as(usize, 1), selected.fieldCount());
    try std.testing.expectEqualStrings("flag", selected.field(0).?.name);

    const removed = try added.removeField(0);
    defer removed.deinit();
    try std.testing.expectEqualStrings("flag", removed.field(0).?.name);
    try std.testing.expectError(error.IndexOutOfBounds, added.removeField(9));
}

test "Schema equality includes ordered metadata" {
    const allocator = std.testing.allocator;
    const int_ty: datatype.DataType = .int32;
    const number_field = try datatype.Field.create(allocator, "number", &int_ty, true, &.{});
    defer number_field.deinit();
    const metadata_a = [_]MetadataEntry{
        .{ .key = "a", .value = "1" },
        .{ .key = "b", .value = "2" },
    };
    const metadata_b = [_]MetadataEntry{
        .{ .key = "b", .value = "2" },
        .{ .key = "a", .value = "1" },
    };

    const a = try Schema.init(allocator, &.{number_field}, &metadata_a);
    defer a.deinit();
    const a2 = try Schema.init(allocator, &.{number_field}, &metadata_a);
    defer a2.deinit();
    const b = try Schema.init(allocator, &.{number_field}, &metadata_b);
    defer b.deinit();

    try std.testing.expect(Schema.equals(a, a2));
    try std.testing.expect(!Schema.equals(a, b));
}

test "Schema allocation failures" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, checkSchemaAllocationFailure, .{});
}

fn checkSchemaAllocationFailure(allocator: Allocator) !void {
    const setup = std.testing.allocator;
    const int_ty: datatype.DataType = .int32;
    const field_metadata = [_]MetadataEntry{
        .{ .key = "unit", .value = "ms" },
    };
    const number_field = try datatype.Field.create(setup, "number", &int_ty, true, &field_metadata);
    defer number_field.deinit();
    const metadata = [_]MetadataEntry{
        .{ .key = "source", .value = "test" },
    };

    const s = try Schema.init(allocator, &.{number_field}, &metadata);
    defer s.deinit();
    try s.validate();
}
