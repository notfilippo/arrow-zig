const std = @import("std");

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

pub fn layout(ty: anytype) Layout {
    return switch (ty) {
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

    try std.testing.expectEqual(@as(usize, 2), int32_ty.layout().buffers.len);
    try std.testing.expectEqual(BufferKind.values, int32_ty.layout().buffers[1].kind);
    try std.testing.expectEqual(@as(usize, 4), int32_ty.layout().buffers[1].byte_width);
    try std.testing.expectEqual(@as(usize, 3), binary_ty.layout().buffers.len);
    try std.testing.expectEqual(BufferKind.offsets, binary_ty.layout().buffers[1].kind);
    try std.testing.expectEqual(NullLayout.none, (datatype.DataType{ .dense_union = .{ .fields = &.{}, .type_ids = &.{} } }).layout().null_layout);
}
