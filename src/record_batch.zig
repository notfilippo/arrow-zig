// Copyright 2026 Filippo Rossi
// SPDX-License-Identifier: Apache-2.0

//! Record batch schema and column storage.
//!
//! A record batch is reference counted storage over a retained schema and
//! retained column references.
//! It can be converted to and from struct `ArrayData` for APIs that use Arrow
//! arrays as the batch container.

const std = @import("std");
const Allocator = std.mem.Allocator;
const array_data = @import("array/data.zig");
const bitmap = @import("bitmap.zig");
const checked = @import("checked.zig");
const datatype = @import("datatype.zig");
const schema_mod = @import("schema.zig");
const ArrayData = array_data.ArrayData;
const Schema = schema_mod.Schema;
const RefCount = @import("refcount.zig").RefCount;

pub const Error = schema_mod.Error || checked.Error || array_data.ValidateError || error{
    FieldColumnCountMismatch,
    ColumnTypeMismatch,
    ColumnLengthMismatch,
    NotStructArray,
    StructNullsUnsupported,
    OffsetOutOfBounds,
};
pub const AccessError = schema_mod.AccessError;

pub const RecordBatch = struct {
    allocator: Allocator,
    schema: *Schema,
    columns: []*ArrayData,
    len: usize,
    ref_count: RefCount,

    /// Create a batch by retaining schema and columns.
    /// Caller keeps ownership of the supplied inputs. Each column must have
    /// length `len`.
    pub fn initRetained(
        allocator: Allocator,
        batch_schema: *Schema,
        len: usize,
        columns: []const *ArrayData,
    ) Error!*RecordBatch {
        try validateColumnsFull(batch_schema, columns, len);
        return initRetainedAssumeValidColumns(allocator, batch_schema, len, columns);
    }

    /// Create a batch from fields by constructing an empty metadata schema.
    pub fn initFieldsRetained(
        allocator: Allocator,
        field_meta: []const *const datatype.Field,
        len: usize,
        columns: []const *ArrayData,
    ) Error!*RecordBatch {
        const batch_schema = try Schema.init(allocator, field_meta, &.{});
        defer batch_schema.deinit();
        return initRetained(allocator, batch_schema, len, columns);
    }

    /// Create a batch from struct storage.
    /// Sliced struct arrays become sliced columns in the batch.
    /// Struct row nulls are rejected because batches have no row validity.
    pub fn fromStructData(allocator: Allocator, data: *const ArrayData) Error!*RecordBatch {
        if (data.type.id() != .struct_) return error.NotStructArray;
        const batch_schema = try Schema.init(allocator, data.type.struct_.fields, &.{});
        defer batch_schema.deinit();
        return fromStructDataRetainedSchema(allocator, batch_schema, data);
    }

    /// Create a batch from struct storage and retain the supplied schema.
    /// Sliced struct arrays become sliced columns in the batch.
    /// Struct row nulls are rejected because batches have no row validity.
    ///
    /// Runs `validateFull()` on the struct data; if the caller has already
    /// validated the input (e.g. during CDI import), use
    /// `fromStructDataAssumeValidated()` to skip the second pass.
    pub fn fromStructDataRetainedSchema(
        allocator: Allocator,
        batch_schema: *Schema,
        data: *const ArrayData,
    ) Error!*RecordBatch {
        try data.validateFull();
        return fromStructDataAssumeValidated(allocator, batch_schema, data);
    }

    /// Same as `fromStructDataRetainedSchema` but trusts the caller that
    /// `data` has been validated and contains no struct-level nulls.
    /// This avoids a duplicate validation pass for callers like CDI import
    /// that already validated during construction.
    pub fn fromStructDataAssumeValidated(
        allocator: Allocator,
        batch_schema: *Schema,
        data: *const ArrayData,
    ) Error!*RecordBatch {
        if (data.type.id() != .struct_) return error.NotStructArray;
        if (data.logicalNullCount() != 0) return error.StructNullsUnsupported;

        const sliced_columns = try allocator.alloc(*ArrayData, data.children.len);
        defer allocator.free(sliced_columns);

        var sliced: usize = 0;
        errdefer {
            for (sliced_columns[0..sliced]) |column_data| column_data.deinit();
        }
        for (data.children, 0..) |child, i| {
            sliced_columns[i] = try child.slice(data.offset, data.len);
            sliced += 1;
        }

        const batch = try initRetainedAssumeValidColumns(allocator, batch_schema, data.len, sliced_columns);
        for (sliced_columns) |column_data| column_data.deinit();
        return batch;
    }

    /// Convert the batch to struct storage.
    /// The returned array has no validity bitmap, so every row is valid.
    pub fn toStructData(self: *const RecordBatch) Error!*ArrayData {
        const ty = datatype.DataType{ .struct_ = .{ .fields = self.schema.fields() } };
        return ArrayData.initRetained(
            self.allocator,
            ty,
            self.len,
            0,
            0,
            &.{null},
            self.columns,
            null,
        );
    }

    pub fn cloneRetained(self: *const RecordBatch) Error!*RecordBatch {
        return initRetained(self.allocator, self.schema, self.len, self.columns);
    }

    pub fn slice(self: *const RecordBatch, off: usize, length: usize) Error!*RecordBatch {
        return self.sliceChecked(off, length);
    }

    pub fn sliceChecked(self: *const RecordBatch, off: usize, length: usize) Error!*RecordBatch {
        if (off > self.len) return error.OffsetOutOfBounds;
        const clamped = @min(length, self.len - off);
        const sliced_columns = try self.allocator.alloc(*ArrayData, self.columns.len);
        defer self.allocator.free(sliced_columns);

        var sliced: usize = 0;
        errdefer {
            for (sliced_columns[0..sliced]) |column_data| column_data.deinit();
        }
        for (self.columns, 0..) |column_data, i| {
            sliced_columns[i] = try column_data.slice(off, clamped);
            sliced += 1;
        }

        const batch = try initRetained(self.allocator, self.schema, clamped, sliced_columns);
        for (sliced_columns) |column_data| column_data.deinit();
        return batch;
    }

    pub fn replaceSchemaMetadata(self: *const RecordBatch, schema_metadata: []const datatype.MetadataEntry) Error!*RecordBatch {
        const new_schema = try self.schema.replaceMetadata(schema_metadata);
        defer new_schema.deinit();
        return initRetained(self.allocator, new_schema, self.len, self.columns);
    }

    pub fn removeSchemaMetadata(self: *const RecordBatch) Error!*RecordBatch {
        return self.replaceSchemaMetadata(&.{});
    }

    pub fn addColumn(
        self: *const RecordBatch,
        index: usize,
        field_meta: *const datatype.Field,
        column_data: *ArrayData,
    ) (Error || AccessError)!*RecordBatch {
        if (column_data.len != self.len) return error.ColumnLengthMismatch;
        const new_schema = try self.schema.addField(index, field_meta);
        defer new_schema.deinit();

        const new_columns = try self.allocator.alloc(*ArrayData, self.columns.len + 1);
        defer self.allocator.free(new_columns);
        @memcpy(new_columns[0..index], self.columns[0..index]);
        new_columns[index] = column_data;
        @memcpy(new_columns[index + 1 ..], self.columns[index..]);
        return initRetained(self.allocator, new_schema, self.len, new_columns);
    }

    pub fn setColumn(
        self: *const RecordBatch,
        index: usize,
        field_meta: *const datatype.Field,
        column_data: *ArrayData,
    ) (Error || AccessError)!*RecordBatch {
        if (index >= self.columns.len) return error.IndexOutOfBounds;
        if (column_data.len != self.len) return error.ColumnLengthMismatch;
        const new_schema = try self.schema.setField(index, field_meta);
        defer new_schema.deinit();

        const new_columns = try self.allocator.alloc(*ArrayData, self.columns.len);
        defer self.allocator.free(new_columns);
        @memcpy(new_columns, self.columns);
        new_columns[index] = column_data;
        return initRetained(self.allocator, new_schema, self.len, new_columns);
    }

    pub fn removeColumn(self: *const RecordBatch, index: usize) (Error || AccessError)!*RecordBatch {
        if (index >= self.columns.len) return error.IndexOutOfBounds;
        const new_schema = try self.schema.removeField(index);
        defer new_schema.deinit();

        const new_columns = try self.allocator.alloc(*ArrayData, self.columns.len - 1);
        defer self.allocator.free(new_columns);
        @memcpy(new_columns[0..index], self.columns[0..index]);
        @memcpy(new_columns[index..], self.columns[index + 1 ..]);
        return initRetained(self.allocator, new_schema, self.len, new_columns);
    }

    pub fn selectColumns(self: *const RecordBatch, indices: []const usize) (Error || AccessError)!*RecordBatch {
        const new_schema = try self.schema.selectFields(indices);
        defer new_schema.deinit();

        const new_columns = try self.allocator.alloc(*ArrayData, indices.len);
        defer self.allocator.free(new_columns);
        for (indices, 0..) |index, i| {
            new_columns[i] = @constCast(try self.columnChecked(index));
        }
        return initRetained(self.allocator, new_schema, self.len, new_columns);
    }

    pub fn validateFull(self: *const RecordBatch) Error!void {
        try validateColumnsFull(self.schema, self.columns, self.len);
    }

    pub fn fieldCount(self: *const RecordBatch) usize {
        return self.schema.fieldCount();
    }

    pub fn fields(self: *const RecordBatch) []const *const datatype.Field {
        return self.schema.fields();
    }

    pub fn field(self: *const RecordBatch, index: usize) ?*const datatype.Field {
        return self.schema.field(index);
    }

    pub fn fieldChecked(self: *const RecordBatch, index: usize) AccessError!*const datatype.Field {
        return self.schema.fieldChecked(index);
    }

    pub fn column(self: *const RecordBatch, index: usize) ?*const ArrayData {
        if (index >= self.columns.len) return null;
        return self.columns[index];
    }

    pub fn columnChecked(self: *const RecordBatch, index: usize) AccessError!*const ArrayData {
        if (index >= self.columns.len) return error.IndexOutOfBounds;
        return self.columns[index];
    }

    pub fn columnIndex(self: *const RecordBatch, name: []const u8) ?usize {
        return self.schema.fieldIndex(name);
    }

    pub fn columnNamed(self: *const RecordBatch, name: []const u8) ?*const ArrayData {
        const index = self.columnIndex(name) orelse return null;
        return self.columns[index];
    }

    pub fn columnNamedChecked(self: *const RecordBatch, name: []const u8) AccessError!*const ArrayData {
        return self.columnNamed(name) orelse error.FieldNotFound;
    }

    pub fn retain(self: *RecordBatch) *RecordBatch {
        _ = self.ref_count.fetchAdd(1, .monotonic);
        return self;
    }

    pub fn refCount(self: *const RecordBatch) usize {
        return self.ref_count.load(.monotonic);
    }

    pub fn deinit(self: *RecordBatch) void {
        if (self.ref_count.fetchSub(1, .acq_rel) != 1) return;
        const allocator = self.allocator;
        releaseColumns(allocator, self.columns);
        self.schema.deinit();
        allocator.destroy(self);
    }
};

fn initRetainedAssumeValidColumns(
    allocator: Allocator,
    batch_schema: *Schema,
    len: usize,
    columns: []const *ArrayData,
) Error!*RecordBatch {
    try validateColumnContracts(batch_schema, columns, len);

    const retained_schema = batch_schema.retain();
    errdefer retained_schema.deinit();

    const owned_columns = try retainColumns(allocator, columns);
    errdefer releaseColumns(allocator, owned_columns);

    const self = try allocator.create(RecordBatch);
    self.* = .{
        .allocator = allocator,
        .schema = retained_schema,
        .columns = owned_columns,
        .len = len,
        .ref_count = RefCount.init(1),
    };
    return self;
}

fn validateColumnsFull(batch_schema: *const Schema, columns: []const *ArrayData, len: usize) Error!void {
    try batch_schema.validate();
    if (batch_schema.fieldCount() != columns.len) return error.FieldColumnCountMismatch;

    for (columns, 0..) |column_data, i| {
        try column_data.validateFull();
        const field_meta = batch_schema.field(i).?;
        if (!datatype.DataType.equals(field_meta.type.*, column_data.type)) return error.ColumnTypeMismatch;
        if (!field_meta.nullable and column_data.logicalNullCount() != 0) return error.NonNullableNulls;
        if (column_data.len != len) return error.ColumnLengthMismatch;
    }
}

fn validateColumnContracts(batch_schema: *const Schema, columns: []const *ArrayData, len: usize) Error!void {
    try batch_schema.validate();
    if (batch_schema.fieldCount() != columns.len) return error.FieldColumnCountMismatch;

    for (columns, 0..) |column_data, i| {
        const field_meta = batch_schema.field(i).?;
        if (!datatype.DataType.equals(field_meta.type.*, column_data.type)) return error.ColumnTypeMismatch;
        if (!field_meta.nullable and column_data.logicalNullCount() != 0) return error.NonNullableNulls;
        if (column_data.len != len) return error.ColumnLengthMismatch;
    }
}

fn retainColumns(allocator: Allocator, columns: []const *ArrayData) Allocator.Error![]*ArrayData {
    const owned_columns = try allocator.alloc(*ArrayData, columns.len);
    errdefer allocator.free(owned_columns);

    var retained: usize = 0;
    errdefer {
        for (owned_columns[0..retained]) |column_data| column_data.deinit();
    }
    for (columns, 0..) |column_data, i| {
        owned_columns[i] = column_data.retain();
        retained += 1;
    }
    return owned_columns;
}

fn releaseColumns(allocator: Allocator, columns: []*ArrayData) void {
    for (columns) |column_data| column_data.deinit();
    allocator.free(columns);
}

fn numberArray(allocator: Allocator, values: []const i32) !*ArrayData {
    const builder = @import("builder.zig");
    var b = builder.NumericBuilder(i32).init(allocator);
    defer b.deinit();
    try b.appendSlice(values);
    return b.finish();
}

fn numberArrayWithNull(allocator: Allocator) !*ArrayData {
    const builder = @import("builder.zig");
    var b = builder.NumericBuilder(i32).init(allocator);
    defer b.deinit();
    try b.append(1);
    try b.appendNull();
    return b.finish();
}

fn boolArray(allocator: Allocator, values: []const bool) !*ArrayData {
    const builder = @import("builder.zig");
    var b = builder.BooleanBuilder.init(allocator);
    defer b.deinit();
    try b.appendSlice(values);
    return b.finish();
}

test "RecordBatch retains schema and columns" {
    const allocator = std.testing.allocator;
    const numbers = try numberArray(allocator, &.{ 10, 20, 30 });
    defer numbers.deinit();
    const flags = try boolArray(allocator, &.{ true, false, true });
    defer flags.deinit();

    const number_ty: datatype.DataType = .int32;
    const flag_ty: datatype.DataType = .bool;
    const number_field = try datatype.Field.create(allocator, "number", &number_ty, true, &.{});
    defer number_field.deinit();
    const flag_field = try datatype.Field.create(allocator, "flag", &flag_ty, false, &.{});
    defer flag_field.deinit();

    const batch_schema = try Schema.init(allocator, &.{ number_field, flag_field }, &.{});
    defer batch_schema.deinit();

    {
        const batch = try RecordBatch.initRetained(allocator, batch_schema, 3, &.{ numbers, flags });
        defer batch.deinit();

        try std.testing.expectEqual(@as(usize, 3), batch.len);
        try std.testing.expectEqual(@as(usize, 2), batch.fieldCount());
        try std.testing.expectEqual(@as(usize, 1), batch.refCount());
        try std.testing.expectEqual(@as(usize, 2), batch_schema.refCount());
        try std.testing.expectEqual(@as(usize, 2), numbers.refCount());
        try std.testing.expectEqual(@as(usize, 2), flags.refCount());
        try std.testing.expect(batch.fields()[0].type != &number_ty);
        try std.testing.expectEqualStrings("number", batch.field(0).?.name);
        try std.testing.expectEqualStrings("number", (try batch.fieldChecked(0)).name);
        try std.testing.expectError(error.IndexOutOfBounds, batch.fieldChecked(9));
        try std.testing.expect(!batch.field(1).?.nullable);
        try std.testing.expect(batch.column(3) == null);
        try std.testing.expectError(error.IndexOutOfBounds, batch.columnChecked(3));
        try std.testing.expectEqual(@as(?usize, 1), batch.columnIndex("flag"));
        try std.testing.expect(batch.columnNamed("flag") != null);
        try std.testing.expect(try batch.columnNamedChecked("flag") == flags);
        try std.testing.expect(batch.columnNamed("missing") == null);
        try std.testing.expectError(error.FieldNotFound, batch.columnNamedChecked("missing"));

        const clone = try batch.cloneRetained();
        defer clone.deinit();
        try std.testing.expectEqual(@as(usize, 3), clone.len);
        try std.testing.expectEqual(@as(usize, 3), batch_schema.refCount());

        const sliced = try batch.sliceChecked(1, 9);
        defer sliced.deinit();
        try std.testing.expectEqual(@as(usize, 2), sliced.len);
        const sliced_numbers = try @import("array.zig").NumericArray(i32).fromData(try sliced.columnChecked(0));
        try std.testing.expectEqual(@as(i32, 20), sliced_numbers.value(0));
        try std.testing.expectError(error.OffsetOutOfBounds, batch.sliceChecked(4, 1));

        _ = batch.retain();
        try std.testing.expectEqual(@as(usize, 2), batch.refCount());
        batch.deinit();
        try std.testing.expectEqual(@as(usize, 1), batch.refCount());
    }
    try std.testing.expectEqual(@as(usize, 1), batch_schema.refCount());
}

test "RecordBatch returns transformed batches" {
    const allocator = std.testing.allocator;
    const numbers = try numberArray(allocator, &.{ 10, 20, 30 });
    defer numbers.deinit();
    const flags = try boolArray(allocator, &.{ true, false, true });
    defer flags.deinit();
    const scores = try numberArray(allocator, &.{ 1, 2, 3 });
    defer scores.deinit();

    const number_ty: datatype.DataType = .int32;
    const flag_ty: datatype.DataType = .bool;
    const number_field = try datatype.Field.create(allocator, "number", &number_ty, true, &.{});
    defer number_field.deinit();
    const flag_field = try datatype.Field.create(allocator, "flag", &flag_ty, true, &.{});
    defer flag_field.deinit();
    const score_field = try datatype.Field.create(allocator, "score", &number_ty, true, &.{});
    defer score_field.deinit();

    const metadata = [_]datatype.MetadataEntry{.{ .key = "source", .value = "test" }};
    const batch_schema = try Schema.init(allocator, &.{ number_field, flag_field }, &metadata);
    defer batch_schema.deinit();
    const batch = try RecordBatch.initRetained(allocator, batch_schema, 3, &.{ numbers, flags });
    defer batch.deinit();

    const added = try batch.addColumn(1, score_field, scores);
    defer added.deinit();
    try std.testing.expectEqual(@as(usize, 3), added.fieldCount());
    try std.testing.expectEqualStrings("score", added.field(1).?.name);

    const set = try added.setColumn(2, score_field, scores);
    defer set.deinit();
    try std.testing.expectEqualStrings("score", set.field(2).?.name);

    const selected = try added.selectColumns(&.{ 2, 0 });
    defer selected.deinit();
    try std.testing.expectEqual(@as(usize, 2), selected.fieldCount());
    try std.testing.expectEqualStrings("flag", selected.field(0).?.name);
    try std.testing.expectEqualStrings("number", selected.field(1).?.name);

    const removed = try added.removeColumn(1);
    defer removed.deinit();
    try std.testing.expectEqual(@as(usize, 2), removed.fieldCount());
    try std.testing.expectEqualStrings("flag", removed.field(1).?.name);

    const no_metadata = try batch.removeSchemaMetadata();
    defer no_metadata.deinit();
    try std.testing.expectEqual(@as(usize, 0), no_metadata.schema.metadata().len);
    const replaced = try no_metadata.replaceSchemaMetadata(&metadata);
    defer replaced.deinit();
    try std.testing.expectEqualStrings("test", replaced.schema.metadataValue("source").?);

    const short = try numberArray(allocator, &.{1});
    defer short.deinit();
    try std.testing.expectError(error.ColumnLengthMismatch, batch.addColumn(1, score_field, short));
    try std.testing.expectError(error.IndexOutOfBounds, batch.removeColumn(9));
    try std.testing.expectError(error.IndexOutOfBounds, batch.selectColumns(&.{9}));
}

test "RecordBatch converts to struct data" {
    const allocator = std.testing.allocator;
    const numbers = try numberArray(allocator, &.{ 10, 20, 30 });
    defer numbers.deinit();
    const flags = try boolArray(allocator, &.{ true, false, true });
    defer flags.deinit();

    const number_ty: datatype.DataType = .int32;
    const flag_ty: datatype.DataType = .bool;
    const number_field = try datatype.Field.create(allocator, "number", &number_ty, true, &.{});
    defer number_field.deinit();
    const flag_field = try datatype.Field.create(allocator, "flag", &flag_ty, true, &.{});
    defer flag_field.deinit();
    const batch = try RecordBatch.initFieldsRetained(allocator, &.{ number_field, flag_field }, 3, &.{ numbers, flags });
    defer batch.deinit();

    const struct_data = try batch.toStructData();
    defer struct_data.deinit();
    try struct_data.validate();

    try std.testing.expectEqual(datatype.TypeId.struct_, struct_data.type.id());
    try std.testing.expectEqual(@as(usize, 3), struct_data.len);
    try std.testing.expectEqual(@as(?usize, 0), struct_data.null_count);
    try std.testing.expect(struct_data.buffers[0] == null);
    try std.testing.expectEqual(@as(usize, 2), struct_data.children.len);
    try std.testing.expectEqualStrings("flag", struct_data.type.struct_.fields[1].name);
}

test "RecordBatch supports zero column batches" {
    const allocator = std.testing.allocator;
    const batch = try RecordBatch.initFieldsRetained(allocator, &.{}, 4, &.{});
    defer batch.deinit();

    try std.testing.expectEqual(@as(usize, 4), batch.len);
    try std.testing.expectEqual(@as(usize, 0), batch.fieldCount());

    const struct_data = try batch.toStructData();
    defer struct_data.deinit();
    try struct_data.validate();
    try std.testing.expectEqual(@as(usize, 4), struct_data.len);
    try std.testing.expectEqual(@as(usize, 0), struct_data.children.len);
}

test "RecordBatch creates sliced columns from struct data" {
    const allocator = std.testing.allocator;
    const numbers = try numberArray(allocator, &.{ 10, 20, 30 });
    defer numbers.deinit();
    const flags = try boolArray(allocator, &.{ true, false, true });
    defer flags.deinit();

    const number_ty: datatype.DataType = .int32;
    const flag_ty: datatype.DataType = .bool;
    const number_field = try datatype.Field.create(allocator, "number", &number_ty, true, &.{});
    defer number_field.deinit();
    const flag_field = try datatype.Field.create(allocator, "flag", &flag_ty, true, &.{});
    defer flag_field.deinit();
    const struct_fields = [_]*const datatype.Field{ number_field, flag_field };
    const struct_ty = datatype.DataType{ .struct_ = .{ .fields = &struct_fields } };
    const struct_data = try ArrayData.initRetained(allocator, struct_ty, 3, 0, 0, &.{null}, &.{ numbers, flags }, null);
    defer struct_data.deinit();

    const sliced = try struct_data.slice(1, 9);
    defer sliced.deinit();

    const batch = try RecordBatch.fromStructData(allocator, sliced);
    defer batch.deinit();

    try std.testing.expectEqual(@as(usize, 2), batch.len);
    const sliced_numbers = try @import("array.zig").NumericArray(i32).fromData(batch.columnNamed("number").?);
    try std.testing.expectEqual(@as(i32, 20), sliced_numbers.value(0));
    try std.testing.expectEqual(@as(i32, 30), sliced_numbers.value(1));
    const sliced_flags = try @import("array.zig").BooleanArray.fromData(batch.columnNamed("flag").?);
    try std.testing.expect(!sliced_flags.value(0));
    try std.testing.expect(sliced_flags.value(1));
}

test "RecordBatch assume validated skips duplicate child validation" {
    const allocator = std.testing.allocator;

    const invalid_numbers = try ArrayData.initOwned(allocator, .int32, 2, 0, 0, &.{ null, null }, &.{}, null);
    defer invalid_numbers.deinit();

    const number_ty: datatype.DataType = .int32;
    const number_field = try datatype.Field.create(allocator, "number", &number_ty, true, &.{});
    defer number_field.deinit();
    const batch_schema = try Schema.init(allocator, &.{number_field}, &.{});
    defer batch_schema.deinit();

    const struct_fields = [_]*const datatype.Field{number_field};
    const struct_ty = datatype.DataType{ .struct_ = .{ .fields = &struct_fields } };
    const struct_data = try ArrayData.initRetained(allocator, struct_ty, 2, 0, 0, &.{null}, &.{invalid_numbers}, null);
    defer struct_data.deinit();

    try std.testing.expectError(error.MissingValuesBuffer, RecordBatch.fromStructDataRetainedSchema(allocator, batch_schema, struct_data));

    const batch = try RecordBatch.fromStructDataAssumeValidated(allocator, batch_schema, struct_data);
    defer batch.deinit();
    try std.testing.expectEqual(@as(usize, 2), batch.len);
    try std.testing.expectError(error.MissingValuesBuffer, batch.validateFull());
}

test "RecordBatch rejects inconsistent inputs" {
    const allocator = std.testing.allocator;
    const numbers = try numberArray(allocator, &.{ 1, 2 });
    defer numbers.deinit();
    const numbers_with_null = try numberArrayWithNull(allocator);
    defer numbers_with_null.deinit();
    const short = try numberArray(allocator, &.{1});
    defer short.deinit();
    const flags = try boolArray(allocator, &.{ true, false });
    defer flags.deinit();

    const number_ty: datatype.DataType = .int32;
    const flag_ty: datatype.DataType = .bool;
    const number_field = try datatype.Field.create(allocator, "number", &number_ty, true, &.{});
    defer number_field.deinit();
    const flag_typed_field = try datatype.Field.create(allocator, "number", &flag_ty, true, &.{});
    defer flag_typed_field.deinit();
    const required_number_field = try datatype.Field.create(allocator, "number", &number_ty, false, &.{});
    defer required_number_field.deinit();

    try std.testing.expectError(
        error.FieldColumnCountMismatch,
        RecordBatch.initFieldsRetained(allocator, &.{ number_field, number_field }, 2, &.{numbers}),
    );
    try std.testing.expectError(
        error.ColumnTypeMismatch,
        RecordBatch.initFieldsRetained(allocator, &.{flag_typed_field}, 2, &.{numbers}),
    );
    try std.testing.expectError(
        error.ColumnLengthMismatch,
        RecordBatch.initFieldsRetained(allocator, &.{ number_field, number_field }, 2, &.{ numbers, short }),
    );
    try std.testing.expectError(
        error.NonNullableNulls,
        RecordBatch.initFieldsRetained(allocator, &.{required_number_field}, 2, &.{numbers_with_null}),
    );

    const builder = @import("builder.zig");
    var dict_values_builder = builder.NumericBuilder(i32).init(allocator);
    defer dict_values_builder.deinit();
    try dict_values_builder.appendNull();
    try dict_values_builder.append(10);
    const dictionary = try dict_values_builder.finish();
    defer dictionary.deinit();

    var dict_builder = builder.DictionaryBuilder(i8).init(allocator, dictionary);
    defer dict_builder.deinit();
    try dict_builder.append(0);
    try dict_builder.append(1);
    const dict_data = try dict_builder.finish();
    defer dict_data.deinit();
    try std.testing.expectEqual(@as(usize, 1), dict_data.logicalNullCount());

    const required_dict_field = try datatype.Field.create(allocator, "dict", &dict_data.type, false, &.{});
    defer required_dict_field.deinit();
    try std.testing.expectError(
        error.NonNullableNulls,
        RecordBatch.initFieldsRetained(allocator, &.{required_dict_field}, 2, &.{dict_data}),
    );

    try std.testing.expectError(error.NotStructArray, RecordBatch.fromStructData(allocator, numbers));

    var validity_builder = bitmap.BitmapBuilder.init();
    defer validity_builder.deinit();
    try validity_builder.append(allocator, true);
    try validity_builder.append(allocator, false);
    const validity = try validity_builder.finish(allocator);
    defer validity.deinit();

    const number_field2 = try datatype.Field.create(allocator, "number", &number_ty, true, &.{});
    defer number_field2.deinit();
    const struct_fields2 = [_]*const datatype.Field{number_field2};
    const nullable_struct_ty = datatype.DataType{ .struct_ = .{ .fields = &struct_fields2 } };
    const nullable_struct = try ArrayData.initRetained(
        allocator,
        nullable_struct_ty,
        2,
        0,
        1,
        &.{validity},
        &.{numbers},
        null,
    );
    defer nullable_struct.deinit();
    try std.testing.expectError(error.StructNullsUnsupported, RecordBatch.fromStructData(allocator, nullable_struct));
}

test "RecordBatch allocation failures" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, checkRecordBatchAllocationFailure, .{});
}

fn checkRecordBatchAllocationFailure(allocator: Allocator) !void {
    const setup = std.testing.allocator;
    const numbers = try numberArray(setup, &.{ 10, 20, 30 });
    defer numbers.deinit();
    const flags = try boolArray(setup, &.{ true, false, true });
    defer flags.deinit();

    const number_ty: datatype.DataType = .int32;
    const flag_ty: datatype.DataType = .bool;
    const number_field = try datatype.Field.create(setup, "number", &number_ty, true, &.{});
    defer number_field.deinit();
    const flag_field = try datatype.Field.create(setup, "flag", &flag_ty, true, &.{});
    defer flag_field.deinit();

    const batch = try RecordBatch.initFieldsRetained(allocator, &.{ number_field, flag_field }, 3, &.{ numbers, flags });
    defer batch.deinit();

    const struct_data = try batch.toStructData();
    defer struct_data.deinit();

    const roundtrip = try RecordBatch.fromStructData(allocator, struct_data);
    defer roundtrip.deinit();
}
