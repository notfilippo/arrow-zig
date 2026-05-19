// Copyright 2026 Filippo Rossi
// SPDX-License-Identifier: Apache-2.0

//! Extension array typed view.
//!
//! Extension arrays use their storage type layout. This view exposes extension
//! metadata and can produce retained storage-typed `ArrayData`.

const std = @import("std");
const datatype = @import("../datatype.zig");
const array_data = @import("data.zig");
const common = @import("common.zig");
const ArrayData = array_data.ArrayData;

pub const ExtensionArray = struct {
    view: common.View,
    null_count: ?usize,

    pub fn fromData(data: *const ArrayData) common.ViewError!ExtensionArray {
        if (data.type.id() != .extension) return error.TypeMismatch;
        return .{ .view = common.View.init(data), .null_count = data.null_count };
    }

    pub fn name(self: ExtensionArray) []const u8 {
        return self.view.data.type.extension.name;
    }

    pub fn metadata(self: ExtensionArray) []const u8 {
        return self.view.data.type.extension.metadata;
    }

    pub fn storageType(self: ExtensionArray) datatype.DataType {
        return self.view.data.type.extension.storage_type.*;
    }

    pub fn storageOwned(self: ExtensionArray) array_data.DataSliceError!*ArrayData {
        return ArrayData.initRetained(
            self.view.data.allocator,
            self.storageType(),
            self.view.len,
            self.view.offset,
            self.null_count,
            self.view.data.buffers,
            self.view.data.children,
            self.view.data.dictionary,
        );
    }

    pub fn slice(self: ExtensionArray, off: usize, length: usize) ExtensionArray {
        return self.sliceChecked(off, length) catch unreachable;
    }

    pub fn sliceChecked(self: ExtensionArray, off: usize, length: usize) common.SliceError!ExtensionArray {
        const sliced = try self.view.sliceChecked(off, length);
        return .{
            .view = sliced,
            .null_count = array_data.slicedNullCount(self.null_count, self.view.len, off, sliced.len),
        };
    }
};

test "ExtensionArray exposes storage data" {
    const allocator = std.testing.allocator;
    const values = try @import("../buffer.zig").Buffer.allocate(allocator, 3 * @sizeOf(i32));
    errdefer values.deinit();
    std.mem.writeInt(i32, values.data[0..4], 10, .little);
    std.mem.writeInt(i32, values.data[4..8], 20, .little);
    std.mem.writeInt(i32, values.data[8..12], 30, .little);
    values.freeze();

    const storage_ty: datatype.DataType = .int32;
    const ty = datatype.DataType{ .extension = .{
        .storage_type = &storage_ty,
        .name = "example.int32",
        .metadata = "v1",
    } };
    const data = try ArrayData.initOwned(allocator, ty, 3, 0, 0, &.{ null, values }, &.{}, null);
    defer data.deinit();
    try data.validate();

    const arr = try ExtensionArray.fromData(data);
    try std.testing.expectEqualStrings("example.int32", arr.name());
    try std.testing.expectEqualStrings("v1", arr.metadata());

    const storage = try arr.storageOwned();
    defer storage.deinit();
    const ints = try @import("primitive.zig").NumericArray(i32).fromData(storage);
    try std.testing.expectEqual(@as(i32, 20), ints.value(1));
}
