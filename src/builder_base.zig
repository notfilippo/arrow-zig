// Copyright 2026 Filippo Rossi
// SPDX-License-Identifier: Apache-2.0

//! Shared builder primitives.
//!
//! `kMinBuilderCapacity` matches the C++ ArrayBuilder floor. `AppendValuesMixin`
//! generates `appendValues` and `appendValuesBitmap` from a per-builder value
//! writer, eliminating the duplicate preamble across NumericBuilder and BooleanBuilder.

const checked = @import("checked.zig");
const bitmap = @import("bitmap.zig");

/// Minimum element capacity allocated on the first reserve call, matching C++ kMinBuilderCapacity.
pub const kMinBuilderCapacity: usize = 32;

/// Returns a struct with `appendValues` and `appendValuesBitmap` methods for `Self`.
///
/// `writeValuesFn` must write all values in `vs` to `self` WITHOUT touching validity or len.
/// The mixin handles the validity update and len increment after calling `writeValuesFn`.
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
            for (0..vs.len) |i| self.validity.unsafeAppend(vb[i] != 0);
            self.len = try checked.add(self.len, vs.len);
        }

        pub fn appendValuesBitmap(self: *Self, vs: []const V, validity: []const u8, validity_offset: usize) Self.Error!void {
            if (vs.len == 0) return;
            const needed = try bitmap.byteLenChecked(try checked.add(validity_offset, vs.len));
            if (validity.len < needed) return error.ValidityBufferTooSmall;
            try self.reserve(vs.len);
            writeValuesFn(self, vs);
            self.validity.unsafeAppendBits(validity, validity_offset, vs.len);
            self.len = try checked.add(self.len, vs.len);
        }
    };
}
