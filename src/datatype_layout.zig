// Copyright 2026 Filippo Rossi
// SPDX-License-Identifier: Apache-2.0

//! Buffer layout rules for Arrow data types.
//!
//! Layouts state which buffers are required for each type and how nulls are
//! represented.

const std = @import("std");

pub const NullLayout = enum { bitmap, none, always_null };

pub const BufferKind = enum {
    validity,
    values,
    offsets,
    type_ids,
    union_offsets,
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
    variadic_buffers: bool = false,
};

const no_buffers = [_]BufferSpec{};
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
const fixed_16_buffers = [_]BufferSpec{
    .{ .kind = .validity },
    .{ .kind = .values, .byte_width = 16 },
};
const fixed_32_buffers = [_]BufferSpec{
    .{ .kind = .validity },
    .{ .kind = .values, .byte_width = 32 },
};
const fixed_size_binary_buffers = [_]BufferSpec{
    .{ .kind = .validity },
    .{ .kind = .values },
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
const binary_view_buffers = [_]BufferSpec{
    .{ .kind = .validity },
    .{ .kind = .values, .byte_width = 16 },
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
    .{ .kind = .type_ids, .byte_width = 1 },
};
const dense_union_buffers = [_]BufferSpec{
    .{ .kind = .type_ids, .byte_width = 1 },
    .{ .kind = .union_offsets, .byte_width = 4 },
};

pub fn layout(ty: anytype) Layout {
    return switch (ty) {
        .null_ => .{ .buffers = &no_buffers, .null_layout = .always_null },
        .bool => .{ .buffers = &bool_buffers },
        .int8, .uint8 => .{ .buffers = &fixed_1_buffers },
        .int16, .uint16, .float16 => .{ .buffers = &fixed_2_buffers },
        .int32, .uint32, .float32, .date32, .time32, .month_interval => .{ .buffers = &fixed_4_buffers },
        .int64, .uint64, .float64, .date64, .time64, .timestamp, .duration, .day_time_interval => .{ .buffers = &fixed_8_buffers },
        .decimal128, .month_day_nano_interval => .{ .buffers = &fixed_16_buffers },
        .decimal256 => .{ .buffers = &fixed_32_buffers },
        .fixed_size_binary => .{ .buffers = &fixed_size_binary_buffers },
        .binary, .utf8 => .{ .buffers = &binary_buffers },
        .large_binary, .large_utf8 => .{ .buffers = &large_binary_buffers },
        .binary_view, .utf8_view => .{ .buffers = &binary_view_buffers, .variadic_buffers = true },
        .list, .map => .{ .buffers = &list_buffers },
        .large_list => .{ .buffers = &large_list_buffers },
        .fixed_size_list, .struct_ => .{ .buffers = &nested_validity_buffers },
        .sparse_union => .{ .buffers = &sparse_union_buffers, .null_layout = .none },
        .dense_union => .{ .buffers = &dense_union_buffers, .null_layout = .none },
        .run_end_encoded => .{ .buffers = &no_buffers, .null_layout = .none },
        .dictionary => |meta| blk: {
            var child_layout = layout(meta.index_type.*);
            child_layout.has_dictionary = true;
            break :blk child_layout;
        },
    };
}

test "layout describes buffers" {
    const datatype = @import("datatype.zig");
    const int32_ty: datatype.DataType = .int32;
    const binary_ty: datatype.DataType = .binary;

    try std.testing.expectEqual(@as(usize, 0), (@as(datatype.DataType, .null_)).layout().buffers.len);
    try std.testing.expectEqual(@as(usize, 2), int32_ty.layout().buffers.len);
    try std.testing.expectEqual(BufferKind.values, int32_ty.layout().buffers[1].kind);
    try std.testing.expectEqual(@as(usize, 4), int32_ty.layout().buffers[1].byte_width);
    try std.testing.expectEqual(@as(usize, 16), (datatype.DataType{ .decimal128 = .{ .precision = 12, .scale = 2 } }).layout().buffers[1].byte_width);
    try std.testing.expectEqual(@as(usize, 32), (datatype.DataType{ .decimal256 = .{ .precision = 40, .scale = 2 } }).layout().buffers[1].byte_width);
    try std.testing.expectEqual(@as(usize, 4), (@as(datatype.DataType, .month_interval)).layout().buffers[1].byte_width);
    try std.testing.expectEqual(@as(usize, 8), (@as(datatype.DataType, .day_time_interval)).layout().buffers[1].byte_width);
    try std.testing.expectEqual(@as(usize, 16), (@as(datatype.DataType, .month_day_nano_interval)).layout().buffers[1].byte_width);
    try std.testing.expectEqual(@as(usize, 2), (datatype.DataType{ .fixed_size_binary = .{ .byte_width = 16 } }).layout().buffers.len);
    try std.testing.expectEqual(@as(usize, 3), binary_ty.layout().buffers.len);
    try std.testing.expectEqual(BufferKind.offsets, binary_ty.layout().buffers[1].kind);
    try std.testing.expectEqual(@as(usize, 2), (@as(datatype.DataType, .binary_view)).layout().buffers.len);
    try std.testing.expect((@as(datatype.DataType, .binary_view)).layout().variadic_buffers);
    try std.testing.expectEqual(BufferKind.type_ids, (datatype.DataType{ .sparse_union = .{ .fields = &.{}, .type_ids = &.{} } }).layout().buffers[0].kind);
    try std.testing.expectEqual(NullLayout.none, (datatype.DataType{ .dense_union = .{ .fields = &.{}, .type_ids = &.{} } }).layout().null_layout);
}
