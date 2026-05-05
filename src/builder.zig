// Builders follow the Reserve+UnsafeAppend protocol: `reserve(n)` pre-sizes
// both the values buffer and the validity bitmap before appending.

const std = @import("std");
const Allocator = std.mem.Allocator;
const checked = @import("checked.zig");
const bitmap = @import("bitmap.zig");
const datatype = @import("datatype.zig");
const offset_data = @import("offsets.zig");
const array = @import("array.zig");
const ArrayData = array.ArrayData;
const Buffer = @import("buffer.zig").Buffer;

// ---------------------------------------------------------------------------
// NumericBuilder
// ---------------------------------------------------------------------------

/// Builder for non-bit-packed fixed-width arrays backed by the physical Zig type `T`.
/// Logical type defaults to the plain numeric type; compatible logical types
/// (date/time/timestamp/duration) can be selected with `initType`.
///
/// Do not copy this struct by value; bitwise copy aliases the internal buffers.
/// Pass *NumericBuilder(T) or call cloneRetained() on the finished ArrayData.
pub fn NumericBuilder(comptime T: type) type {
    _ = array.typeIdFor(T); // compile-time type check

    return struct {
        const Self = @This();
        pub const Array = array.NumericArray(T);

        allocator: Allocator,
        ty: datatype.DataType,
        values: ?*Buffer,
        validity: bitmap.BitmapBuilder,
        len: usize,

        pub fn init(allocator: Allocator) Self {
            const id = comptime array.typeIdFor(T);
            return .{
                .allocator = allocator,
                .ty = @unionInit(datatype.DataType, @tagName(id), {}),
                .values = null,
                .validity = bitmap.BitmapBuilder.init(),
                .len = 0,
            };
        }

        pub fn initType(allocator: Allocator, ty: datatype.DataType) !Self {
            try ty.validate();
            if (!array.dataTypeAcceptsZigType(T, ty)) return error.TypeMismatch;
            var self = init(allocator);
            self.ty = ty;
            return self;
        }

        pub fn deinit(self: *Self) void {
            if (self.values) |v| v.release();
            self.values = null;
            self.validity.deinit();
            self.len = 0;
        }

        pub fn reserve(self: *Self, additional: usize) !void {
            if (additional == 0) return;
            const buf = try self.ensureValues();
            const new_len = try checked.add(self.len, additional);
            try buf.reserve(try checked.mul(new_len, @sizeOf(T)));
            try self.validity.ensureCapacityForBits(self.allocator, additional);
        }

        pub fn append(self: *Self, v: T) !void {
            try self.reserve(1);
            self.unsafeAppend(v);
        }

        pub fn appendNull(self: *Self) !void {
            try self.reserve(1);
            self.unsafeAppendNull();
        }

        pub fn appendNulls(self: *Self, n: usize) !void {
            if (n == 0) return;
            try self.reserve(n);
            const buf = self.values.?;
            const byte_len = try checked.mul(n, @sizeOf(T));
            const end = try checked.add(buf.size, byte_len);
            @memset(buf.data[buf.size..end], 0);
            buf.size = end;
            self.validity.unsafeAppendN(false, n);
            self.len = try checked.add(self.len, n);
        }

        pub fn appendSlice(self: *Self, vs: []const T) !void {
            if (vs.len == 0) return;
            try self.reserve(vs.len);
            const buf = self.values.?;
            const byte_len = try checked.mul(vs.len, @sizeOf(T));
            const end = try checked.add(buf.size, byte_len);
            const dst: [*]T = @ptrCast(@alignCast(buf.data + buf.size));
            @memcpy(dst[0..vs.len], vs);
            buf.size = end;
            self.validity.unsafeAppendN(true, vs.len);
            self.len = try checked.add(self.len, vs.len);
        }

        /// Append values with per-element validity bytes (Arrow C++ AppendValues style).
        /// valid_bytes[i] != 0 means valid. If null, all values are treated as valid.
        pub fn appendValues(self: *Self, vs: []const T, valid_bytes: ?[]const u8) !void {
            if (vs.len == 0) return;
            if (valid_bytes == null) return self.appendSlice(vs);
            const vb = valid_bytes.?;
            std.debug.assert(vb.len >= vs.len);
            try self.reserve(vs.len);
            const buf = self.values.?;
            const byte_len = try checked.mul(vs.len, @sizeOf(T));
            const end = try checked.add(buf.size, byte_len);
            const dst: [*]T = @ptrCast(@alignCast(buf.data + buf.size));
            @memcpy(dst[0..vs.len], vs);
            buf.size = end;
            for (0..vs.len) |i| self.validity.unsafeAppend(vb[i] != 0);
            self.len = try checked.add(self.len, vs.len);
        }

        /// Append values with a packed validity bitmap at a given bit offset.
        pub fn appendValuesBitmap(self: *Self, vs: []const T, validity: []const u8, validity_offset: usize) !void {
            if (vs.len == 0) return;
            try self.reserve(vs.len);
            const buf = self.values.?;
            const byte_len = try checked.mul(vs.len, @sizeOf(T));
            const end = try checked.add(buf.size, byte_len);
            const dst: [*]T = @ptrCast(@alignCast(buf.data + buf.size));
            @memcpy(dst[0..vs.len], vs);
            buf.size = end;
            self.validity.unsafeAppendBits(validity, validity_offset, vs.len);
            self.len = try checked.add(self.len, vs.len);
        }

        pub fn length(self: Self) usize {
            return self.len;
        }

        pub fn finish(self: *Self) !*ArrayData {
            const null_count = self.validity.false_count;

            const values_buf: *Buffer = blk: {
                if (self.values) |v| {
                    v.freeze();
                    self.values = null;
                    break :blk v;
                }
                const b = try Buffer.allocate(self.allocator, 0);
                b.freeze();
                break :blk b;
            };

            const n = self.len;
            self.len = 0;

            const validity_buf: ?*Buffer = try self.validity.finishNullable(self.allocator);

            return ArrayData.init(
                self.allocator,
                self.ty,
                n,
                0,
                null_count,
                &.{ validity_buf, values_buf },
                &.{},
                null,
                false,
            );
        }

        fn unsafeAppend(self: *Self, v: T) void {
            const buf = self.values.?;
            const ptr: *T = @ptrCast(@alignCast(buf.data + buf.size));
            ptr.* = v;
            buf.size += @sizeOf(T);
            self.validity.unsafeAppend(true);
            self.len += 1;
        }

        fn unsafeAppendNull(self: *Self) void {
            const buf = self.values.?;
            const ptr: *T = @ptrCast(@alignCast(buf.data + buf.size));
            ptr.* = std.mem.zeroes(T);
            buf.size += @sizeOf(T);
            self.validity.unsafeAppend(false);
            self.len += 1;
        }

        fn ensureValues(self: *Self) !*Buffer {
            if (self.values == null) {
                self.values = try Buffer.allocate(self.allocator, 0);
            }
            return self.values.?;
        }
    };
}

// ---------------------------------------------------------------------------
// BooleanBuilder
// ---------------------------------------------------------------------------

/// Do not copy this struct by value; bitwise copy aliases the internal bitmaps.
/// Pass *BooleanBuilder or call cloneRetained() on the finished ArrayData.
pub const BooleanBuilder = struct {
    allocator: Allocator,
    values: bitmap.BitmapBuilder,
    validity: bitmap.BitmapBuilder,
    len: usize,

    pub fn init(allocator: Allocator) BooleanBuilder {
        return .{
            .allocator = allocator,
            .values = bitmap.BitmapBuilder.init(),
            .validity = bitmap.BitmapBuilder.init(),
            .len = 0,
        };
    }

    pub fn deinit(self: *BooleanBuilder) void {
        self.values.deinit();
        self.validity.deinit();
        self.len = 0;
    }

    pub fn reserve(self: *BooleanBuilder, additional: usize) !void {
        if (additional == 0) return;
        try self.values.ensureCapacityForBits(self.allocator, additional);
        try self.validity.ensureCapacityForBits(self.allocator, additional);
    }

    pub fn append(self: *BooleanBuilder, v: bool) !void {
        try self.reserve(1);
        self.unsafeAppend(v);
    }

    pub fn appendNull(self: *BooleanBuilder) !void {
        try self.reserve(1);
        self.unsafeAppendNull();
    }

    pub fn appendNulls(self: *BooleanBuilder, n: usize) !void {
        if (n == 0) return;
        try self.reserve(n);
        self.values.unsafeAppendN(false, n);
        self.validity.unsafeAppendN(false, n);
        self.len = try checked.add(self.len, n);
    }

    pub fn appendSlice(self: *BooleanBuilder, vs: []const bool) !void {
        if (vs.len == 0) return;
        try self.reserve(vs.len);
        for (vs) |v| self.values.unsafeAppend(v);
        self.validity.unsafeAppendN(true, vs.len);
        self.len = try checked.add(self.len, vs.len);
    }

    /// Append bool values with per-element validity bytes (Arrow C++ AppendValues style).
    /// valid_bytes[i] != 0 means valid. If null, all values are treated as valid.
    pub fn appendValues(self: *BooleanBuilder, vs: []const bool, valid_bytes: ?[]const u8) !void {
        if (vs.len == 0) return;
        if (valid_bytes == null) return self.appendSlice(vs);
        const vb = valid_bytes.?;
        std.debug.assert(vb.len >= vs.len);
        try self.reserve(vs.len);
        for (vs, 0..) |v, i| {
            self.values.unsafeAppend(v);
            self.validity.unsafeAppend(vb[i] != 0);
        }
        self.len = try checked.add(self.len, vs.len);
    }

    /// Append bool values with a packed validity bitmap at a given bit offset.
    pub fn appendValuesBitmap(self: *BooleanBuilder, vs: []const bool, validity: []const u8, validity_offset: usize) !void {
        if (vs.len == 0) return;
        try self.reserve(vs.len);
        for (vs) |v| self.values.unsafeAppend(v);
        self.validity.unsafeAppendBits(validity, validity_offset, vs.len);
        self.len = try checked.add(self.len, vs.len);
    }

    pub fn length(self: BooleanBuilder) usize {
        return self.len;
    }

    pub fn finish(self: *BooleanBuilder) !*ArrayData {
        const n = self.len;
        const null_count = self.validity.false_count;
        self.len = 0;

        const values_buf = try self.values.finish(self.allocator);
        const validity_buf: ?*Buffer = try self.validity.finishNullable(self.allocator);

        return ArrayData.init(
            self.allocator,
            .bool,
            n,
            0,
            null_count,
            &.{ validity_buf, values_buf },
            &.{},
            null,
            false,
        );
    }

    fn unsafeAppend(self: *BooleanBuilder, v: bool) void {
        self.values.unsafeAppend(v);
        self.validity.unsafeAppend(true);
        self.len += 1;
    }

    fn unsafeAppendNull(self: *BooleanBuilder) void {
        self.values.unsafeAppend(false);
        self.validity.unsafeAppend(false);
        self.len += 1;
    }
};

pub fn VarBinaryBuilder(comptime kind: array.VarBinaryKind) type {
    const Offset = switch (kind) {
        .binary, .utf8 => i32,
        .large_binary, .large_utf8 => i64,
    };

    return struct {
        const Self = @This();
        pub const Array = array.VarBinaryView(kind);

        allocator: Allocator,
        offsets: offset_data.Builder(Offset),
        values: ?*Buffer,
        validity: bitmap.BitmapBuilder,
        len: usize,

        pub fn init(allocator: Allocator) Self {
            return .{
                .allocator = allocator,
                .offsets = offset_data.Builder(Offset).init(),
                .values = null,
                .validity = bitmap.BitmapBuilder.init(),
                .len = 0,
            };
        }

        pub fn deinit(self: *Self) void {
            self.offsets.deinit();
            if (self.values) |buf| buf.release();
            self.values = null;
            self.validity.deinit();
            self.len = 0;
        }

        pub fn reserve(self: *Self, additional: usize, additional_bytes: usize) !void {
            if (additional == 0 and additional_bytes == 0) return;
            const new_len = try checked.add(self.len, additional);
            try self.offsets.reserveSlots(self.allocator, try checked.add(new_len, 1));

            const values = try self.ensureValues();
            try values.reserve(try checked.add(values.size, additional_bytes));
            try self.validity.ensureCapacityForBits(self.allocator, additional);
        }

        pub fn append(self: *Self, bytes: []const u8) !void {
            if (comptime kind == .utf8 or kind == .large_utf8) {
                if (!std.unicode.utf8ValidateSlice(bytes)) return error.InvalidUtf8;
            }
            try self.appendUnchecked(bytes);
        }

        pub fn appendBytes(self: *Self, bytes: []const u8) !void {
            try self.appendUnchecked(bytes);
        }

        pub fn appendNull(self: *Self) !void {
            try self.reserve(1, 0);
            const values = self.values.?;
            try self.offsets.append(self.allocator, values.size);
            self.validity.unsafeAppend(false);
            self.len += 1;
        }

        pub fn appendNulls(self: *Self, n: usize) !void {
            if (n == 0) return;
            try self.reserve(n, 0);
            const values = self.values.?;
            try self.offsets.appendRepeat(self.allocator, n, values.size);
            self.validity.unsafeAppendN(false, n);
            self.len = try checked.add(self.len, n);
        }

        pub fn length(self: Self) usize {
            return self.len;
        }

        pub fn finish(self: *Self) !*ArrayData {
            const n = self.len;
            const null_count = self.validity.false_count;
            self.len = 0;

            const offsets_buf = try self.offsets.finish(self.allocator);
            const values_buf = try self.finishValues();
            const validity_buf = try self.validity.finishNullable(self.allocator);

            return ArrayData.init(
                self.allocator,
                dataTypeForKind(kind),
                n,
                0,
                null_count,
                &.{ validity_buf, offsets_buf, values_buf },
                &.{},
                null,
                false,
            );
        }

        fn appendUnchecked(self: *Self, bytes: []const u8) !void {
            try self.reserve(1, bytes.len);
            const values = self.values.?;
            const end = try checked.add(values.size, bytes.len);
            try offset_data.ensureRange(Offset, end);
            @memcpy(values.data[values.size..end], bytes);
            values.size = end;

            try self.offsets.append(self.allocator, end);
            self.validity.unsafeAppend(true);
            self.len += 1;
        }

        fn ensureValues(self: *Self) !*Buffer {
            if (self.values == null) {
                self.values = try Buffer.allocate(self.allocator, 0);
            }
            return self.values.?;
        }

        fn finishValues(self: *Self) !*Buffer {
            const values = if (self.values) |buf| blk: {
                self.values = null;
                break :blk buf;
            } else try Buffer.allocate(self.allocator, 0);
            values.freeze();
            return values;
        }
    };
}

pub const BinaryBuilder = VarBinaryBuilder(.binary);
pub const Utf8Builder = VarBinaryBuilder(.utf8);
pub const LargeBinaryBuilder = VarBinaryBuilder(.large_binary);
pub const LargeUtf8Builder = VarBinaryBuilder(.large_utf8);

fn dataTypeForKind(comptime kind: array.VarBinaryKind) datatype.DataType {
    return switch (kind) {
        .binary => .binary,
        .utf8 => .utf8,
        .large_binary => .large_binary,
        .large_utf8 => .large_utf8,
    };
}

// ---------------------------------------------------------------------------
// Tests: NumericBuilder
// ---------------------------------------------------------------------------

test "NumericBuilder Int32" {
    const allocator = std.testing.allocator;
    var b = NumericBuilder(i32).init(allocator);
    defer b.deinit();

    try b.append(10);
    try b.appendNull();
    try b.append(30);
    try std.testing.expectEqual(@as(usize, 3), b.length());

    const data = try b.finish();
    defer data.release();
    const arr = try array.NumericArray(i32).fromData(data);

    try std.testing.expectEqual(@as(usize, 3), arr.len);
    try std.testing.expectEqual(@as(usize, 1), arr.null_count);
    try std.testing.expectEqual(@as(i32, 10), arr.value(0));
    try std.testing.expect(arr.isNull(1));
    try std.testing.expectEqual(@as(i32, 30), arr.value(2));
}

test "NumericBuilder all valid drops validity" {
    const allocator = std.testing.allocator;
    var b = NumericBuilder(f64).init(allocator);
    defer b.deinit();

    try b.appendSlice(&.{ 1.0, 2.0, 3.0 });
    const data = try b.finish();
    defer data.release();
    const arr = try array.NumericArray(f64).fromData(data);

    try std.testing.expectEqual(@as(usize, 0), arr.null_count);
    try std.testing.expect(data.buffers[0] == null);
}

test "NumericBuilder appendSlice" {
    const allocator = std.testing.allocator;
    var b = NumericBuilder(u8).init(allocator);
    defer b.deinit();

    try b.appendSlice(&.{ 1, 2, 3 });
    try b.appendNulls(2);
    try b.appendSlice(&.{6});
    const data = try b.finish();
    defer data.release();
    const arr = try array.NumericArray(u8).fromData(data);

    try std.testing.expectEqual(@as(usize, 6), arr.len);
    try std.testing.expectEqual(@as(usize, 2), arr.null_count);
    try std.testing.expect(arr.isNull(3));
    try std.testing.expect(arr.isNull(4));
    try std.testing.expect(arr.isValid(5));
    try std.testing.expectEqual(@as(u8, 6), arr.value(5));
}

test "NumericBuilder reuse after finish" {
    const allocator = std.testing.allocator;
    var b = NumericBuilder(i32).init(allocator);
    defer b.deinit();

    try b.append(1);
    const data1 = try b.finish();
    defer data1.release();
    const arr1 = try array.NumericArray(i32).fromData(data1);

    try b.append(2);
    try b.append(3);
    const data2 = try b.finish();
    defer data2.release();
    const arr2 = try array.NumericArray(i32).fromData(data2);

    try std.testing.expectEqual(@as(i32, 1), arr1.value(0));
    try std.testing.expectEqual(@as(i32, 2), arr2.value(0));
    try std.testing.expectEqual(@as(i32, 3), arr2.value(1));
}

test "NumericBuilder reserve both buffers" {
    const allocator = std.testing.allocator;
    var b = NumericBuilder(i64).init(allocator);
    defer b.deinit();
    try b.reserve(100);
    try std.testing.expect(b.values != null);
    try std.testing.expect(b.values.?.capacity >= 100 * @sizeOf(i64));
}

test "NumericBuilder reserve overflow" {
    const allocator = std.testing.allocator;
    var b = NumericBuilder(i32).init(allocator);
    defer b.deinit();
    b.len = std.math.maxInt(usize);
    try std.testing.expectError(error.Overflow, b.reserve(1));
}

test "NumericBuilder initType validates logical type" {
    const allocator = std.testing.allocator;
    var date_builder = try NumericBuilder(i32).initType(allocator, .date32);
    defer date_builder.deinit();
    try std.testing.expectEqual(.date32, date_builder.ty);

    try std.testing.expectError(error.InvalidTimeUnit, NumericBuilder(i32).initType(allocator, .{ .time32 = .microsecond }));
    try std.testing.expectError(error.TypeMismatch, NumericBuilder(i32).initType(allocator, .date64));
}

// ---------------------------------------------------------------------------
// Tests: BooleanBuilder
// ---------------------------------------------------------------------------

test "BooleanBuilder" {
    const allocator = std.testing.allocator;
    var b = BooleanBuilder.init(allocator);
    defer b.deinit();

    try b.append(true);
    try b.appendNull();
    try b.append(false);
    try b.append(true);

    const data = try b.finish();
    defer data.release();
    const arr = try array.BooleanArray.fromData(data);

    try std.testing.expectEqual(@as(usize, 4), arr.len);
    try std.testing.expectEqual(@as(usize, 1), arr.null_count);
    try std.testing.expect(arr.value(0));
    try std.testing.expect(arr.isNull(1));
    try std.testing.expect(!arr.value(2));
    try std.testing.expect(arr.value(3));
}

test "NumericBuilder appendValues with valid_bytes" {
    const allocator = std.testing.allocator;
    var b = NumericBuilder(i32).init(allocator);
    defer b.deinit();

    const vals = [_]i32{ 10, 20, 30, 40 };
    const valid = [_]u8{ 1, 0, 1, 0 }; // elements 0 and 2 valid
    try b.appendValues(&vals, &valid);
    const data = try b.finish();
    defer data.release();
    const arr = try array.NumericArray(i32).fromData(data);

    try std.testing.expectEqual(@as(usize, 4), arr.len);
    try std.testing.expectEqual(@as(usize, 2), arr.nullCount());
    try std.testing.expect(arr.isValid(0));
    try std.testing.expectEqual(@as(i32, 10), arr.value(0));
    try std.testing.expect(arr.isNull(1));
    try std.testing.expect(arr.isValid(2));
    try std.testing.expectEqual(@as(i32, 30), arr.value(2));
    try std.testing.expect(arr.isNull(3));
}

test "NumericBuilder appendValues null valid_bytes = all valid" {
    const allocator = std.testing.allocator;
    var b = NumericBuilder(i32).init(allocator);
    defer b.deinit();

    const vals = [_]i32{ 1, 2, 3 };
    try b.appendValues(&vals, null);
    const data = try b.finish();
    defer data.release();
    const arr = try array.NumericArray(i32).fromData(data);

    try std.testing.expectEqual(@as(usize, 0), arr.nullCount());
    try std.testing.expect(data.buffers[0] == null);
}

test "NumericBuilder appendValuesBitmap" {
    const allocator = std.testing.allocator;
    var b = NumericBuilder(i32).init(allocator);
    defer b.deinit();

    const vals = [_]i32{ 10, 20, 30, 40 };
    // bits 4 and 6 of byte 0 set = elements 0 and 2 valid at offset 4
    // 0b01010000: bit4=(>>4)&1=1, bit5=(>>5)&1=0, bit6=(>>6)&1=1, bit7=(>>7)&1=0
    const validity = [_]u8{0b01010000};
    try b.appendValuesBitmap(&vals, &validity, 4);
    const data = try b.finish();
    defer data.release();
    const arr = try array.NumericArray(i32).fromData(data);

    try std.testing.expectEqual(@as(usize, 4), arr.len);
    try std.testing.expect(arr.isValid(0)); // bit 4 set
    try std.testing.expect(arr.isNull(1)); // bit 5 clear
    try std.testing.expect(arr.isValid(2)); // bit 6 set
    try std.testing.expect(arr.isNull(3)); // bit 7 clear
}

test "BooleanBuilder appendValues with valid_bytes" {
    const allocator = std.testing.allocator;
    var b = BooleanBuilder.init(allocator);
    defer b.deinit();

    const vals = [_]bool{ true, false, true, false };
    const valid = [_]u8{ 1, 1, 0, 1 }; // element 2 is null
    try b.appendValues(&vals, &valid);
    const data = try b.finish();
    defer data.release();
    const arr = try array.BooleanArray.fromData(data);

    try std.testing.expectEqual(@as(usize, 4), arr.len);
    try std.testing.expectEqual(@as(usize, 1), arr.nullCount());
    try std.testing.expect(arr.isValid(0));
    try std.testing.expect(arr.value(0));
    try std.testing.expect(arr.isValid(1));
    try std.testing.expect(!arr.value(1));
    try std.testing.expect(arr.isNull(2));
    try std.testing.expect(arr.isValid(3));
    try std.testing.expect(!arr.value(3));
}

test "BooleanBuilder appendValues null valid_bytes = all valid" {
    const allocator = std.testing.allocator;
    var b = BooleanBuilder.init(allocator);
    defer b.deinit();

    try b.appendValues(&.{ true, false, true }, null);
    const data = try b.finish();
    defer data.release();
    const arr = try array.BooleanArray.fromData(data);

    try std.testing.expectEqual(@as(usize, 0), arr.nullCount());
    try std.testing.expect(data.buffers[0] == null);
    try std.testing.expectEqual(@as(usize, 2), arr.trueCount());
}

test "BooleanBuilder appendValuesBitmap" {
    const allocator = std.testing.allocator;
    var b = BooleanBuilder.init(allocator);
    defer b.deinit();

    const vals = [_]bool{ true, true, true, true };
    // validity bitmap: bit 0 set, bit 1 clear, bit 2 set, bit 3 clear at offset 0
    const validity = [_]u8{0b00000101}; // bits 0,2 set
    try b.appendValuesBitmap(&vals, &validity, 0);
    const data = try b.finish();
    defer data.release();
    const arr = try array.BooleanArray.fromData(data);

    try std.testing.expectEqual(@as(usize, 4), arr.len);
    try std.testing.expect(arr.isValid(0));
    try std.testing.expect(arr.isNull(1));
    try std.testing.expect(arr.isValid(2));
    try std.testing.expect(arr.isNull(3));
    try std.testing.expectEqual(@as(usize, 2), arr.trueCount());
}

test "NumericBuilder appendValuesBitmap multi-word" {
    const allocator = std.testing.allocator;
    var b = NumericBuilder(i32).init(allocator);
    defer b.deinit();

    const n = 80;
    var vals: [n]i32 = undefined;
    // 10 bytes of validity: every other bit set (alternating valid/null).
    const validity_bytes = [_]u8{0b01010101} ** 10;
    for (&vals, 0..) |*v, i| v.* = @as(i32, @intCast(i));

    try b.appendValuesBitmap(&vals, &validity_bytes, 0);
    const data = try b.finish();
    defer data.release();
    const arr = try array.NumericArray(i32).fromData(data);

    try std.testing.expectEqual(@as(usize, n), arr.len);
    try std.testing.expectEqual(@as(usize, n / 2), arr.nullCount());
    for (0..n) |i| {
        const expect_valid = (i % 2 == 0); // even bits set in 0b01010101
        try std.testing.expectEqual(expect_valid, arr.isValid(i));
        if (expect_valid) try std.testing.expectEqual(@as(i32, @intCast(i)), arr.value(i));
    }
}

test "BooleanBuilder appendValuesBitmap multi-word" {
    const allocator = std.testing.allocator;
    var b = BooleanBuilder.init(allocator);
    defer b.deinit();

    const n = 80;
    var vals: [n]bool = undefined;
    const validity_bytes = [_]u8{0b01010101} ** 10;
    for (&vals, 0..) |*v, i| v.* = (i % 3 == 0);

    try b.appendValuesBitmap(&vals, &validity_bytes, 0);
    const data = try b.finish();
    defer data.release();
    const arr = try array.BooleanArray.fromData(data);

    try std.testing.expectEqual(@as(usize, n), arr.len);
    try std.testing.expectEqual(@as(usize, n / 2), arr.nullCount());
    for (0..n) |i| {
        const expect_valid = (i % 2 == 0);
        try std.testing.expectEqual(expect_valid, arr.isValid(i));
        if (expect_valid) try std.testing.expectEqual(i % 3 == 0, arr.value(i));
    }
}

test "BinaryBuilder basic" {
    const allocator = std.testing.allocator;
    var b = BinaryBuilder.init(allocator);
    defer b.deinit();

    try b.append("ab");
    try b.appendNull();
    try b.append("cde");

    const data = try b.finish();
    defer data.release();
    try data.validate();

    const arr = try array.BinaryArray.fromData(data);
    try std.testing.expectEqual(@as(usize, 3), arr.len);
    try std.testing.expectEqual(@as(usize, 1), arr.nullCount());
    try std.testing.expectEqualStrings("ab", arr.valueBytes(0));
    try std.testing.expect(arr.isNull(1));
    try std.testing.expectEqualStrings("cde", arr.value(2));
}

test "BinaryBuilder all valid drops validity" {
    const allocator = std.testing.allocator;
    var b = BinaryBuilder.init(allocator);
    defer b.deinit();

    try b.append("a");
    try b.append("");
    try b.append("bc");
    const data = try b.finish();
    defer data.release();
    try data.validate();

    const arr = try array.BinaryArray.fromData(data);
    try std.testing.expect(data.buffers[0] == null);
    try std.testing.expectEqual(@as(usize, 0), arr.nullCount());
    try std.testing.expectEqualStrings("", arr.valueBytes(1));

    const s = arr.slice(1, 99);
    try std.testing.expectEqual(@as(usize, 2), s.len);
    try std.testing.expectEqualStrings("", s.valueBytes(0));
    try std.testing.expectEqualStrings("bc", s.valueBytes(1));
}

test "BinaryBuilder reuse after finish" {
    const allocator = std.testing.allocator;
    var b = BinaryBuilder.init(allocator);
    defer b.deinit();

    try b.append("one");
    const data1 = try b.finish();
    defer data1.release();
    const arr1 = try array.BinaryArray.fromData(data1);

    try b.append("two");
    try b.append("three");
    const data2 = try b.finish();
    defer data2.release();
    const arr2 = try array.BinaryArray.fromData(data2);

    try std.testing.expectEqualStrings("one", arr1.valueBytes(0));
    try std.testing.expectEqualStrings("two", arr2.valueBytes(0));
    try std.testing.expectEqualStrings("three", arr2.valueBytes(1));
}

test "Utf8Builder validates input" {
    const allocator = std.testing.allocator;
    var b = Utf8Builder.init(allocator);
    defer b.deinit();

    try b.append("hello");
    const invalid = [_]u8{0xc0};
    try std.testing.expectError(error.InvalidUtf8, b.append(&invalid));

    const data = try b.finish();
    defer data.release();
    try data.validate();
    const arr = try array.Utf8Array.fromData(data);
    try std.testing.expectEqualStrings("hello", arr.value(0));
}

test "LargeBinaryBuilder uses large offsets" {
    const allocator = std.testing.allocator;
    var b = LargeBinaryBuilder.init(allocator);
    defer b.deinit();

    try b.append("alpha");
    try b.append("beta");
    const data = try b.finish();
    defer data.release();
    try data.validate();

    const arr = try array.LargeBinaryArray.fromData(data);
    try std.testing.expectEqual(.large_binary, arr.dataType());
    try std.testing.expectEqualStrings("alpha", arr.valueBytes(0));
    try std.testing.expectEqualStrings("beta", arr.valueBytes(1));
    try std.testing.expectEqual(@as(usize, 3 * @sizeOf(i64)), data.buffers[1].?.size);
}
