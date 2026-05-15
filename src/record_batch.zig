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
const array_data = @import("array_data.zig");
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
        try validateColumns(batch_schema, columns, len);

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

    /// Create a batch from fields by constructing an empty metadata schema.
    pub fn initFieldsRetained(
        allocator: Allocator,
        field_meta: []const datatype.Field,
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
        try data.validate();
        if (data.nullCount() != 0) return error.StructNullsUnsupported;

        const fields_meta = data.type.struct_.fields;
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

        const batch = try initFieldsRetained(allocator, fields_meta, data.len, sliced_columns);
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

    pub fn fieldCount(self: *const RecordBatch) usize {
        return self.schema.fieldCount();
    }

    pub fn fields(self: *const RecordBatch) []const datatype.Field {
        return self.schema.fields();
    }

    pub fn field(self: *const RecordBatch, index: usize) ?datatype.Field {
        return self.schema.field(index);
    }

    pub fn column(self: *const RecordBatch, index: usize) ?*const ArrayData {
        if (index >= self.columns.len) return null;
        return self.columns[index];
    }

    pub fn columnNamed(self: *const RecordBatch, name: []const u8) ?*const ArrayData {
        for (self.fields(), 0..) |field_meta, i| {
            if (std.mem.eql(u8, field_meta.name, name)) return self.columns[i];
        }
        return null;
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

fn validateColumns(batch_schema: *const Schema, columns: []const *ArrayData, len: usize) Error!void {
    try batch_schema.validate();
    if (batch_schema.fieldCount() != columns.len) return error.FieldColumnCountMismatch;

    for (columns, 0..) |column_data, i| {
        try column_data.validate();
        if (!datatype.DataType.equals(batch_schema.field(i).?.type.*, column_data.type)) return error.ColumnTypeMismatch;
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
    const fields_meta = [_]datatype.Field{
        .{ .name = "number", .type = &number_ty },
        .{ .name = "flag", .type = &flag_ty, .nullable = false },
    };

    const batch_schema = try Schema.init(allocator, &fields_meta, &.{});
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
        try std.testing.expect(!batch.field(1).?.nullable);
        try std.testing.expect(batch.column(3) == null);
        try std.testing.expect(batch.columnNamed("flag") != null);
        try std.testing.expect(batch.columnNamed("missing") == null);

        _ = batch.retain();
        try std.testing.expectEqual(@as(usize, 2), batch.refCount());
        batch.deinit();
        try std.testing.expectEqual(@as(usize, 1), batch.refCount());
    }
    try std.testing.expectEqual(@as(usize, 1), batch_schema.refCount());
}

test "RecordBatch converts to struct data" {
    const allocator = std.testing.allocator;
    const numbers = try numberArray(allocator, &.{ 10, 20, 30 });
    defer numbers.deinit();
    const flags = try boolArray(allocator, &.{ true, false, true });
    defer flags.deinit();

    const number_ty: datatype.DataType = .int32;
    const flag_ty: datatype.DataType = .bool;
    const fields_meta = [_]datatype.Field{
        .{ .name = "number", .type = &number_ty },
        .{ .name = "flag", .type = &flag_ty },
    };
    const batch = try RecordBatch.initFieldsRetained(allocator, &fields_meta, 3, &.{ numbers, flags });
    defer batch.deinit();

    const struct_data = try batch.toStructData();
    defer struct_data.deinit();
    try struct_data.validate();

    try std.testing.expectEqual(datatype.TypeId.struct_, struct_data.type.id());
    try std.testing.expectEqual(@as(usize, 3), struct_data.len);
    try std.testing.expectEqual(@as(usize, 0), struct_data.null_count);
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
    const fields_meta = [_]datatype.Field{
        .{ .name = "number", .type = &number_ty },
        .{ .name = "flag", .type = &flag_ty },
    };
    const struct_ty = datatype.DataType{ .struct_ = .{ .fields = &fields_meta } };
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

test "RecordBatch rejects inconsistent inputs" {
    const allocator = std.testing.allocator;
    const numbers = try numberArray(allocator, &.{ 1, 2 });
    defer numbers.deinit();
    const short = try numberArray(allocator, &.{1});
    defer short.deinit();
    const flags = try boolArray(allocator, &.{ true, false });
    defer flags.deinit();

    const number_ty: datatype.DataType = .int32;
    const flag_ty: datatype.DataType = .bool;
    const number_fields = [_]datatype.Field{
        .{ .name = "number", .type = &number_ty },
    };
    const flag_fields = [_]datatype.Field{
        .{ .name = "number", .type = &flag_ty },
    };

    try std.testing.expectError(
        error.FieldColumnCountMismatch,
        RecordBatch.initFieldsRetained(allocator, &number_fields, 2, &.{ numbers, flags }),
    );
    try std.testing.expectError(
        error.ColumnTypeMismatch,
        RecordBatch.initFieldsRetained(allocator, &flag_fields, 2, &.{numbers}),
    );
    try std.testing.expectError(
        error.ColumnLengthMismatch,
        RecordBatch.initFieldsRetained(allocator, &.{ number_fields[0], number_fields[0] }, 2, &.{ numbers, short }),
    );
    try std.testing.expectError(error.NotStructArray, RecordBatch.fromStructData(allocator, numbers));

    var validity_builder = bitmap.BitmapBuilder.init();
    defer validity_builder.deinit();
    try validity_builder.append(allocator, true);
    try validity_builder.append(allocator, false);
    const validity = try validity_builder.finish(allocator);
    defer validity.deinit();

    const nullable_struct_ty = datatype.DataType{ .struct_ = .{ .fields = &number_fields } };
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
    const fields_meta = [_]datatype.Field{
        .{ .name = "number", .type = &number_ty },
        .{ .name = "flag", .type = &flag_ty },
    };

    const batch = try RecordBatch.initFieldsRetained(allocator, &fields_meta, 3, &.{ numbers, flags });
    defer batch.deinit();

    const struct_data = try batch.toStructData();
    defer struct_data.deinit();

    const roundtrip = try RecordBatch.fromStructData(allocator, struct_data);
    defer roundtrip.deinit();
}
