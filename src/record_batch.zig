// Copyright 2026 Filippo Rossi
// SPDX-License-Identifier: Apache-2.0

//! Record batch schema and column storage.
//!
//! A record batch owns a cloned struct schema and retained column references.
//! It can be converted to and from struct `ArrayData` for APIs that use Arrow
//! arrays as the batch container.

const std = @import("std");
const Allocator = std.mem.Allocator;
const array_data = @import("array_data.zig");
const checked = @import("checked.zig");
const datatype = @import("datatype.zig");
const ArrayData = array_data.ArrayData;

pub const Error = Allocator.Error || checked.Error || datatype.ValidationError || array_data.ValidateError || error{
    FieldColumnCountMismatch,
    ColumnTypeMismatch,
    ColumnLengthMismatch,
    NotStructArray,
    OffsetOutOfBounds,
};

pub const RecordBatch = struct {
    allocator: Allocator,
    schema: datatype.DataType,
    columns: []*ArrayData,
    len: usize,

    /// Create a batch by cloning fields and retaining columns.
    /// Caller keeps ownership of the supplied columns. Each column must have
    /// length `len`.
    pub fn initRetained(
        allocator: Allocator,
        field_meta: []const datatype.Field,
        len: usize,
        columns: []const *ArrayData,
    ) Error!*RecordBatch {
        try validateColumns(field_meta, columns, len);

        var schema = try cloneSchema(allocator, field_meta);
        errdefer datatype.deinitOwned(allocator, &schema);

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

        const self = try allocator.create(RecordBatch);
        self.* = .{
            .allocator = allocator,
            .schema = schema,
            .columns = owned_columns,
            .len = len,
        };
        return self;
    }

    /// Create a batch from struct storage.
    /// Sliced struct arrays become sliced columns in the batch.
    pub fn fromStructData(allocator: Allocator, data: *const ArrayData) Error!*RecordBatch {
        if (data.type.id() != .struct_) return error.NotStructArray;
        try data.validate();

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

        const batch = try initRetained(allocator, fields_meta, data.len, sliced_columns);
        for (sliced_columns) |column_data| column_data.deinit();
        return batch;
    }

    /// Convert the batch to struct storage.
    /// The returned array has no validity bitmap, so every row is valid.
    pub fn toStructData(self: *const RecordBatch) Error!*ArrayData {
        return ArrayData.initRetained(
            self.allocator,
            self.schema,
            self.len,
            0,
            0,
            &.{null},
            self.columns,
            null,
        );
    }

    pub fn fieldCount(self: *const RecordBatch) usize {
        return self.columns.len;
    }

    pub fn fields(self: *const RecordBatch) []const datatype.Field {
        return self.schema.struct_.fields;
    }

    pub fn field(self: *const RecordBatch, index: usize) ?datatype.Field {
        if (index >= self.fields().len) return null;
        return self.fields()[index];
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

    pub fn deinit(self: *RecordBatch) void {
        const allocator = self.allocator;
        for (self.columns) |column_data| column_data.deinit();
        allocator.free(self.columns);
        datatype.deinitOwned(allocator, &self.schema);
        allocator.destroy(self);
    }
};

fn cloneSchema(allocator: Allocator, fields: []const datatype.Field) Allocator.Error!datatype.DataType {
    return datatype.cloneOwned(allocator, .{ .struct_ = .{ .fields = fields } });
}

fn validateColumns(fields: []const datatype.Field, columns: []const *ArrayData, len: usize) Error!void {
    if (fields.len != columns.len) return error.FieldColumnCountMismatch;

    const schema = datatype.DataType{ .struct_ = .{ .fields = fields } };
    try schema.validate();

    for (columns, 0..) |column_data, i| {
        try column_data.validate();
        if (!datatype.DataType.equals(fields[i].type.*, column_data.type)) return error.ColumnTypeMismatch;
        if (column_data.len != len) return error.ColumnLengthMismatch;
    }
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

test "RecordBatch retains columns and clones schema" {
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

    const batch = try RecordBatch.initRetained(allocator, &fields_meta, 3, &.{ numbers, flags });
    defer batch.deinit();

    try std.testing.expectEqual(@as(usize, 3), batch.len);
    try std.testing.expectEqual(@as(usize, 2), batch.fieldCount());
    try std.testing.expectEqual(@as(usize, 2), numbers.refCount());
    try std.testing.expectEqual(@as(usize, 2), flags.refCount());
    try std.testing.expect(batch.fields()[0].type != &number_ty);
    try std.testing.expectEqualStrings("number", batch.field(0).?.name);
    try std.testing.expect(!batch.field(1).?.nullable);
    try std.testing.expect(batch.column(3) == null);
    try std.testing.expect(batch.columnNamed("flag") != null);
    try std.testing.expect(batch.columnNamed("missing") == null);
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
    const batch = try RecordBatch.initRetained(allocator, &fields_meta, 3, &.{ numbers, flags });
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
    const batch = try RecordBatch.initRetained(allocator, &.{}, 4, &.{});
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
        RecordBatch.initRetained(allocator, &number_fields, 2, &.{ numbers, flags }),
    );
    try std.testing.expectError(
        error.ColumnTypeMismatch,
        RecordBatch.initRetained(allocator, &flag_fields, 2, &.{numbers}),
    );
    try std.testing.expectError(
        error.ColumnLengthMismatch,
        RecordBatch.initRetained(allocator, &.{ number_fields[0], number_fields[0] }, 2, &.{ numbers, short }),
    );
    try std.testing.expectError(error.NotStructArray, RecordBatch.fromStructData(allocator, numbers));
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

    const batch = try RecordBatch.initRetained(allocator, &fields_meta, 3, &.{ numbers, flags });
    defer batch.deinit();

    const struct_data = try batch.toStructData();
    defer struct_data.deinit();

    const roundtrip = try RecordBatch.fromStructData(allocator, struct_data);
    defer roundtrip.deinit();
}
