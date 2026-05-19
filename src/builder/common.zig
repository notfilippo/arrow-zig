// Copyright 2026 Filippo Rossi
// SPDX-License-Identifier: Apache-2.0

//! Common builder slot state and helpers.
//!
//! Nullable builders embed `Slots` for logical length and validity. Concrete
//! builders still own their value buffers.

const std = @import("std");
const Allocator = std.mem.Allocator;
const checked = @import("../checked.zig");
const bitmap = @import("../bitmap.zig");
const Buffer = @import("../buffer.zig").Buffer;

/// Minimum element capacity allocated on the first reserve call, matching C++ kMinBuilderCapacity.
pub const kMinBuilderCapacity: usize = 32;

pub const Slots = struct {
    validity: bitmap.BitmapBuilder,
    len: usize,

    pub const Error = bitmap.BitmapBuilder.Error;

    pub const Finished = struct {
        len: usize,
        null_count: usize,
        validity: ?*Buffer,
    };

    pub fn init() Slots {
        return .{
            .validity = bitmap.BitmapBuilder.init(),
            .len = 0,
        };
    }

    pub fn deinit(self: *Slots) void {
        self.validity.deinit();
        self.len = 0;
    }

    pub fn reserve(self: *Slots, allocator: Allocator, additional: usize) Error!void {
        try self.validity.ensureCapacityForBits(allocator, additional);
    }

    pub fn length(self: Slots) usize {
        return self.len;
    }

    pub fn unsafeAppend(self: *Slots, valid: bool) void {
        self.validity.unsafeAppend(valid);
        self.len += 1;
    }

    pub fn unsafeAppendN(self: *Slots, valid: bool, n: usize) checked.Error!void {
        self.validity.unsafeAppendN(valid, n);
        self.len = try checked.add(self.len, n);
    }

    pub fn unsafeAppendValidityBytes(self: *Slots, valid_bytes: []const u8) checked.Error!void {
        for (valid_bytes) |b| self.validity.unsafeAppend(b != 0);
        self.len = try checked.add(self.len, valid_bytes.len);
    }

    pub fn unsafeAppendValidityBitmap(self: *Slots, validity: []const u8, offset: usize, n: usize) checked.Error!void {
        self.validity.unsafeAppendBits(validity, offset, n);
        self.len = try checked.add(self.len, n);
    }

    pub fn finish(self: *Slots, allocator: Allocator) Error!Finished {
        const result = Finished{
            .len = self.len,
            .null_count = self.validity.false_count,
            .validity = try self.validity.finishNullable(allocator),
        };
        self.len = 0;
        return result;
    }
};

/// Returns a struct with `appendValues` and `appendValuesBitmap` methods for `Self`.
///
/// `writeValuesFn` writes values only. The mixin updates slots after that.
pub fn AppendValuesMixin(
    comptime Self: type,
    comptime V: type,
    comptime writeValuesFn: fn (*Self, []const V) void,
) type {
    return struct {
        pub fn appendValues(self: *Self, vs: []const V, valid_bytes: ?[]const u8) Self.Error!void {
            if (vs.len == 0) return;
            if (valid_bytes == null) return self.appendSlice(vs);
            const vb = valid_bytes.?;
            if (vb.len < vs.len) return error.ValidityBufferTooSmall;
            try self.reserve(vs.len);
            writeValuesFn(self, vs);
            try self.slots.unsafeAppendValidityBytes(vb[0..vs.len]);
        }

        pub fn appendValuesBitmap(self: *Self, vs: []const V, validity: []const u8, validity_offset: usize) Self.Error!void {
            if (vs.len == 0) return;
            const needed = try bitmap.byteLenChecked(try checked.add(validity_offset, vs.len));
            if (validity.len < needed) return error.ValidityBufferTooSmall;
            try self.reserve(vs.len);
            writeValuesFn(self, vs);
            try self.slots.unsafeAppendValidityBitmap(validity, validity_offset, vs.len);
        }
    };
}

test "Slots tracks nullable length and finish state" {
    const allocator = std.testing.allocator;
    var slots = Slots.init();
    defer slots.deinit();

    try slots.reserve(allocator, 3);
    slots.unsafeAppend(true);
    try slots.unsafeAppendN(false, 2);

    try std.testing.expectEqual(@as(usize, 3), slots.length());
    const finished = try slots.finish(allocator);
    defer if (finished.validity) |buf| buf.deinit();

    try std.testing.expectEqual(@as(usize, 3), finished.len);
    try std.testing.expectEqual(@as(usize, 2), finished.null_count);
    try std.testing.expect(finished.validity != null);
    try std.testing.expectEqual(@as(usize, 0), slots.length());
}
