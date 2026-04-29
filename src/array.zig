const std = @import("std");
const Allocator = std.mem.Allocator;
const checked = @import("checked.zig");
const datatype = @import("datatype.zig");
const bitmap = @import("bitmap.zig");
const Buffer = @import("buffer.zig").Buffer;
const RefCount = @import("refcount.zig").RefCount;

pub const unknown_null_count = bitmap.unknown_null_count;

// ---------------------------------------------------------------------------
// ArrayData
// ---------------------------------------------------------------------------

/// Ref-counted owner for Arrow array storage.
///
/// One object owns the array metadata, buffers, child arrays, and optional
/// dictionary. Typed arrays are lightweight non-owning views built on top of this.
///
/// Do not copy by value; bitwise copy aliases the refcount and internal buffers.
/// Pass *ArrayData or call cloneRetained() to produce an independent owner.
pub const ArrayData = struct {
    allocator: Allocator,
    type: datatype.DataType,
    len: usize,
    offset: usize,
    null_count: usize,
    buffers: []?*Buffer,
    children: []*ArrayData,
    dictionary: ?*ArrayData,
    ref_count: RefCount,

    /// Create a new owner. When `retain` is true all buffers, children, and the
    /// dictionary are retained; when false they are taken as-is (ownership transfer).
    pub fn init(
        allocator: Allocator,
        ty: datatype.DataType,
        len: usize,
        offset: usize,
        null_count: usize,
        buffers: []const ?*Buffer,
        children: []const *ArrayData,
        dictionary: ?*ArrayData,
        comptime do_retain: bool,
    ) !*ArrayData {
        _ = try checked.add(offset, len);
        const self = try allocator.create(ArrayData);
        errdefer allocator.destroy(self);

        const owned_buffers = try allocator.alloc(?*Buffer, buffers.len);
        errdefer allocator.free(owned_buffers);

        const owned_children = try allocator.alloc(*ArrayData, children.len);
        errdefer allocator.free(owned_children);

        if (do_retain) {
            for (buffers, 0..) |buf, i| {
                owned_buffers[i] = if (buf) |b| b.retain() else null;
            }
            errdefer for (owned_buffers) |buf| {
                if (buf) |b| b.release();
            };
            for (children, 0..) |child, i| {
                owned_children[i] = child.retain();
            }
            errdefer for (owned_children) |child| {
                child.release();
            };
        } else {
            @memcpy(owned_buffers, buffers);
            @memcpy(owned_children, children);
        }

        const dict = if (do_retain) (if (dictionary) |d| d.retain() else null) else dictionary;

        self.* = .{
            .allocator = allocator,
            .type = ty,
            .len = len,
            .offset = offset,
            .null_count = null_count,
            .buffers = owned_buffers,
            .children = owned_children,
            .dictionary = dict,
            .ref_count = RefCount.init(1),
        };
        return self;
    }

    /// Retain this owner and return the same pointer for chaining.
    pub fn retain(self: *ArrayData) *ArrayData {
        _ = self.ref_count.fetchAdd(1, .monotonic);
        return self;
    }

    /// Clone by retaining all referenced buffers, children, and dictionary.
    pub fn cloneRetained(self: *const ArrayData) !*ArrayData {
        return init(self.allocator, self.type, self.len, self.offset, self.null_count, self.buffers, self.children, self.dictionary, true);
    }

    /// Validate fixed width layout invariants.
    pub fn validate(self: *const ArrayData) (ValidateError || checked.Error || datatype.ValidationError)!void {
        try self.type.validate();
        const total = try checked.add(self.offset, self.len);
        if (self.buffers.len != 2) return error.InvalidBufferCount;
        if (self.children.len != 0) return error.UnexpectedChild;
        if (self.dictionary != null) return error.UnexpectedDictionary;
        if (self.null_count != unknown_null_count and self.null_count > self.len)
            return error.NullCountOutOfBounds;

        if (self.buffers[0]) |validity_buf| {
            const needed = if (self.len == 0) 0 else try bitmap.byteLenChecked(total);
            if (validity_buf.size < needed) return error.ValidityBufferTooSmall;
        }

        const value_needed: usize = if (self.len == 0)
            0
        else if (self.type.id() == .bool)
            try bitmap.byteLenChecked(total)
        else
            try checked.mul(total, @as(usize, self.type.bitWidth()) / 8);
        if (self.buffers[1]) |values_buf| {
            if (values_buf.size < value_needed) return error.ValuesBufferTooSmall;
        } else if (self.len > 0) {
            return error.MissingValuesBuffer;
        }

        if (self.buffers[0]) |validity_buf| {
            if (self.null_count != unknown_null_count) {
                const actual = self.len - bitmap.countSetBits(validity_buf.dataSlice(), self.offset, self.len);
                if (actual != self.null_count) return error.NullCountMismatch;
            }
        } else {
            if (self.null_count != 0 and self.null_count != unknown_null_count)
                return error.NullCountWithoutValidity;
        }
    }

    /// Zero-copy owned slice over [off, off+length). Clamps length to available range.
    /// Returns error.OffsetOutOfBounds when off > len.
    pub fn slice(self: *const ArrayData, off: usize, length: usize) !*ArrayData {
        if (off > self.len) return error.OffsetOutOfBounds;
        const clamped = @min(length, self.len - off);
        const abs_offset = try checked.add(self.offset, off);
        const nc = slicedNullCount(self.null_count, self.len, off, clamped);
        return init(self.allocator, self.type, clamped, abs_offset, nc, self.buffers, self.children, self.dictionary, true);
    }

    /// Null count. If deferred (unknown_null_count), compute from validity bitmap.
    pub fn nullCount(self: *const ArrayData) usize {
        const validity = if (self.buffers.len > 0) self.buffers[0] else null;
        return bitmap.nullCountFor(
            if (validity) |v| v.dataSlice() else null,
            self.offset,
            self.len,
            self.null_count,
        );
    }

    /// Current reference count. For debug and testing only.
    pub fn refCount(self: *const ArrayData) usize {
        return self.ref_count.load(.monotonic);
    }

    /// Drop one owner reference. Releases buffers, children, and dictionary on zero.
    pub fn release(self: *ArrayData) void {
        if (self.ref_count.fetchSub(1, .acq_rel) != 1) return;
        const allocator = self.allocator;
        for (self.buffers) |buf| {
            if (buf) |b| b.release();
        }
        for (self.children) |child| {
            child.release();
        }
        if (self.dictionary) |dict| dict.release();
        allocator.free(self.buffers);
        allocator.free(self.children);
        allocator.destroy(self);
    }
};

fn slicedNullCount(nc: usize, len: usize, off: usize, clamped: usize) usize {
    if (nc == 0) return 0;
    if (nc == len) return clamped;
    if (off == 0 and clamped == len) return nc;
    return unknown_null_count;
}

// ---------------------------------------------------------------------------
// Type mapping helpers
// ---------------------------------------------------------------------------

/// Map a Zig scalar type to its Arrow TypeId. Compile error for unsupported types.
pub fn typeIdFor(comptime T: type) datatype.TypeId {
    return switch (T) {
        i8 => .int8,
        i16 => .int16,
        i32 => .int32,
        i64 => .int64,
        u8 => .uint8,
        u16 => .uint16,
        u32 => .uint32,
        u64 => .uint64,
        f16 => .float16,
        f32 => .float32,
        f64 => .float64,
        else => @compileError("unsupported Arrow numeric type: " ++ @typeName(T)),
    };
}

/// Whether the physical Zig type T is compatible with the given logical DataType.
pub fn dataTypeAcceptsZigType(comptime T: type, ty: datatype.DataType) bool {
    return switch (T) {
        i8 => ty == .int8,
        i16 => ty == .int16,
        i32 => switch (ty) {
            .int32, .date32, .time32 => true,
            else => false,
        },
        i64 => switch (ty) {
            .int64, .date64, .time64, .timestamp, .duration => true,
            else => false,
        },
        u8 => ty == .uint8,
        u16 => ty == .uint16,
        u32 => ty == .uint32,
        u64 => ty == .uint64,
        f16 => ty == .float16,
        f32 => ty == .float32,
        f64 => ty == .float64,
        else => false,
    };
}

// ---------------------------------------------------------------------------
// FixedWidthView: single template for all fixed-width array types
// ---------------------------------------------------------------------------

pub const ViewError = error{ TypeMismatch, InvalidBufferLayout };
pub const SliceError = error{OffsetOutOfBounds};
pub const ValidateError = error{
    InvalidBufferCount,
    MissingValuesBuffer,
    ValuesBufferTooSmall,
    ValidityBufferTooSmall,
    NullCountMismatch,
    NullCountWithoutValidity,
    NullCountOutOfBounds,
    UnexpectedChild,
    UnexpectedDictionary,
};

/// Comptime descriptor for a fixed-width array kind.
/// Numeric carries the Zig physical type; temporal/bool variants are unit tags.
pub const ArrayKind = union(enum) {
    bool,
    numeric: type,
    date32,
    date64,
    time32,
    time64,
    timestamp,
    duration,
};

fn valueTypeFor(comptime kind: ArrayKind) type {
    return switch (kind) {
        .bool => bool,
        .numeric => |T| T,
        .date32, .time32 => i32,
        .date64, .time64, .timestamp, .duration => i64,
    };
}

fn dataTypeMatchesKind(comptime kind: ArrayKind, ty: datatype.DataType) bool {
    return switch (kind) {
        .bool => ty == .bool,
        .numeric => |T| ty.id() == typeIdFor(T),
        .date32 => ty == .date32,
        .date64 => ty == .date64,
        .time32 => switch (ty) {
            .time32 => |u| u == .second or u == .millisecond,
            else => false,
        },
        .time64 => switch (ty) {
            .time64 => |u| u == .microsecond or u == .nanosecond,
            else => false,
        },
        .timestamp => ty.id() == .timestamp,
        .duration => ty.id() == .duration,
    };
}

/// Non-owning view over an ArrayData for a fixed-width Arrow type.
/// All named array types (NumericArray, BooleanArray, Date32Array, …) are aliases
/// produced by this template.
pub fn FixedWidthView(comptime kind: ArrayKind) type {
    const VT = valueTypeFor(kind);

    return struct {
        const Self = @This();
        pub const ValueType = VT;

        data: *const ArrayData,
        offset: usize,
        len: usize,
        null_count: usize,

        pub fn fromData(data: *const ArrayData) ViewError!Self {
            if (!dataTypeMatchesKind(kind, data.type)) return error.TypeMismatch;
            if (data.buffers.len < 2 or data.buffers[1] == null) return error.InvalidBufferLayout;
            return .{
                .data = data,
                .offset = data.offset,
                .len = data.len,
                .null_count = data.null_count,
            };
        }

        pub fn dataType(self: Self) datatype.DataType {
            return self.data.type;
        }

        pub fn baseData(self: Self) *const ArrayData {
            return self.data;
        }

        pub fn value(self: Self, i: usize) VT {
            const buf = self.data.buffers[1].?;
            if (comptime switch (kind) {
                .bool => true,
                else => false,
            }) {
                return bitmap.getBit(buf.dataSlice(), self.offset + i);
            } else {
                const ptr: [*]const VT = @ptrCast(@alignCast(buf.data));
                return ptr[self.offset + i];
            }
        }

        pub fn isValid(self: Self, i: usize) bool {
            const validity = self.data.buffers[0] orelse return true;
            return bitmap.getBit(validity.dataSlice(), self.offset + i);
        }

        pub fn isNull(self: Self, i: usize) bool {
            return !self.isValid(i);
        }

        pub fn nullCount(self: Self) usize {
            const validity = self.data.buffers[0];
            return bitmap.nullCountFor(
                if (validity) |v| v.dataSlice() else null,
                self.offset,
                self.len,
                self.null_count,
            );
        }

        /// Zero-copy non-owning slice. Clamps length; panics on overflow.
        pub fn slice(self: Self, off: usize, length: usize) Self {
            const clamped = clampedLen(self.len, off, length) catch unreachable;
            return .{
                .data = self.data,
                .offset = self.offset + off,
                .len = clamped,
                .null_count = slicedNullCount(self.null_count, self.len, off, clamped),
            };
        }

        /// Zero-copy non-owning slice. Returns error when off > len.
        pub fn sliceChecked(self: Self, off: usize, length: usize) SliceError!Self {
            const clamped = try clampedLen(self.len, off, length);
            return .{
                .data = self.data,
                .offset = self.offset + off,
                .len = clamped,
                .null_count = slicedNullCount(self.null_count, self.len, off, clamped),
            };
        }

        /// Create a retained ArrayData owner for [off, off+length). Returns error when off > len.
        pub fn sliceOwned(self: Self, off: usize, length: usize) !*ArrayData {
            const clamped = try clampedLen(self.len, off, length);
            return self.data.slice(off, clamped);
        }

        pub fn cloneRetained(self: Self) !*ArrayData {
            return self.data.cloneRetained();
        }

        /// Count of true (valid and set) bits. Only available on BooleanArray.
        pub fn trueCount(self: Self) usize {
            if (comptime switch (kind) {
                .bool => false,
                else => true,
            }) @compileError("trueCount is only available on BooleanArray");
            const values = self.data.buffers[1].?.dataSlice();
            const validity = self.data.buffers[0] orelse
                return bitmap.countSetBits(values, self.offset, self.len);
            return bitmap.countAndSetBits(values, self.offset, validity.dataSlice(), self.offset, self.len);
        }

        /// Count of false (valid and clear) bits. Only available on BooleanArray.
        pub fn falseCount(self: Self) usize {
            if (comptime switch (kind) {
                .bool => false,
                else => true,
            }) @compileError("falseCount is only available on BooleanArray");
            return self.len - self.nullCount() - self.trueCount();
        }
    };
}

fn clampedLen(current_len: usize, off: usize, requested: usize) SliceError!usize {
    if (off > current_len) return error.OffsetOutOfBounds;
    return @min(requested, current_len - off);
}

// ---------------------------------------------------------------------------
// Public array type aliases
// ---------------------------------------------------------------------------

pub fn NumericArray(comptime T: type) type {
    _ = typeIdFor(T); // compile-time check
    return FixedWidthView(.{ .numeric = T });
}

pub const BooleanArray = FixedWidthView(.bool);
pub const Date32Array = FixedWidthView(.date32);
pub const Date64Array = FixedWidthView(.date64);
pub const Time32Array = FixedWidthView(.time32);
pub const Time64Array = FixedWidthView(.time64);
pub const TimestampArray = FixedWidthView(.timestamp);
pub const DurationArray = FixedWidthView(.duration);

// ---------------------------------------------------------------------------
// Tests: ArrayData
// ---------------------------------------------------------------------------

test "ArrayData init overflow" {
    const allocator = std.testing.allocator;
    const values = try Buffer.allocate(allocator, 8);
    defer values.release();
    values.freeze();

    try std.testing.expectError(
        error.Overflow,
        ArrayData.init(allocator, .int32, 1, std.math.maxInt(usize), 0, &.{ null, values }, &.{}, null, false),
    );
}

test "ArrayData cloneRetained retains buffers" {
    const allocator = std.testing.allocator;
    const values = try Buffer.allocate(allocator, 16);
    errdefer values.release();
    values.freeze();

    const data = try ArrayData.init(allocator, .int32, 4, 0, 0, &.{ null, values }, &.{}, null, false);
    defer data.release();

    const clone = try data.cloneRetained();
    defer clone.release();

    try std.testing.expectEqual(@as(usize, 2), values.refCount());
    try std.testing.expectEqual(@as(usize, 4), clone.len);
    try std.testing.expectEqual(@as(usize, 0), clone.offset);
}

test "ArrayData init retained retains buffers and children" {
    const allocator = std.testing.allocator;
    const values = try Buffer.allocate(allocator, 16);
    defer values.release();
    values.freeze();

    const child_values = try Buffer.allocate(allocator, 4);
    errdefer child_values.release();
    child_values.freeze();

    const child = try ArrayData.init(allocator, .uint8, 4, 0, 0, &.{ null, child_values }, &.{}, null, false);
    defer child.release();

    const data = try ArrayData.init(
        allocator,
        .int32,
        4,
        0,
        0,
        &.{ null, values },
        &.{child},
        child,
        true,
    );
    defer data.release();

    try std.testing.expectEqual(@as(usize, 2), values.refCount());
    try std.testing.expectEqual(@as(usize, 3), child.refCount());
}

test "ArrayData slice retains buffers and adjusts metadata" {
    const allocator = std.testing.allocator;
    const validity = try Buffer.allocate(allocator, 1);
    errdefer validity.release();
    validity.data[0] = 0b00010111;
    validity.freeze();

    const values = try Buffer.allocate(allocator, 5 * @sizeOf(i32));
    errdefer values.release();
    values.freeze();

    const data = try ArrayData.init(allocator, .int32, 5, 0, 1, &.{ validity, values }, &.{}, null, false);
    defer data.release();

    const sliced = try data.slice(1, 3);
    defer sliced.release();

    try std.testing.expectEqual(@as(usize, 3), sliced.len);
    try std.testing.expectEqual(@as(usize, 1), sliced.offset);
    try std.testing.expectEqual(unknown_null_count, sliced.null_count);
    try std.testing.expectEqual(@as(usize, 1), sliced.nullCount());
    try std.testing.expectEqual(@as(usize, 2), validity.refCount());
    try std.testing.expectEqual(@as(usize, 2), values.refCount());
}

test "ArrayData slice clamps length and rejects bad offset" {
    const allocator = std.testing.allocator;
    const values = try Buffer.allocate(allocator, 5 * @sizeOf(i32));
    errdefer values.release();
    values.freeze();

    const data = try ArrayData.init(allocator, .int32, 5, 0, 0, &.{ null, values }, &.{}, null, false);
    defer data.release();

    const sliced = try data.slice(3, 99);
    defer sliced.release();
    try std.testing.expectEqual(@as(usize, 2), sliced.len);
    try std.testing.expectEqual(@as(usize, 3), sliced.offset);

    try std.testing.expectError(error.OffsetOutOfBounds, data.slice(6, 1));
}

// ---------------------------------------------------------------------------
// Tests: FixedWidthView / NumericArray
// ---------------------------------------------------------------------------

test "ArrayData validate int32 ok" {
    const allocator = std.testing.allocator;
    const values = try Buffer.allocate(allocator, 5 * @sizeOf(i32));
    errdefer values.release();
    values.freeze();

    const data = try ArrayData.init(allocator, .int32, 5, 0, 0, &.{ null, values }, &.{}, null, false);
    defer data.release();
    try data.validate();
}

test "ArrayData validate buffer too small" {
    const allocator = std.testing.allocator;
    const values = try Buffer.allocate(allocator, 3 * @sizeOf(i32));
    errdefer values.release();
    values.freeze();

    const data = try ArrayData.init(allocator, .int32, 5, 0, 0, &.{ null, values }, &.{}, null, false);
    defer data.release();
    try std.testing.expectError(error.ValuesBufferTooSmall, data.validate());
}

test "ArrayData validate bool ok" {
    const allocator = std.testing.allocator;
    const values = try Buffer.allocate(allocator, bitmap.byteLen(8));
    errdefer values.release();
    values.freeze();

    const data = try ArrayData.init(allocator, .bool, 8, 0, 0, &.{ null, values }, &.{}, null, false);
    defer data.release();
    try data.validate();
}

test "ArrayData validate bool too small" {
    const allocator = std.testing.allocator;
    const values = try Buffer.allocate(allocator, 0);
    errdefer values.release();
    values.freeze();

    const data = try ArrayData.init(allocator, .bool, 9, 0, 0, &.{ null, values }, &.{}, null, false);
    defer data.release();
    try std.testing.expectError(error.ValuesBufferTooSmall, data.validate());
}

test "ArrayData validate zero length permits null values buffer" {
    const allocator = std.testing.allocator;
    const data = try ArrayData.init(allocator, .int32, 0, 10, 0, &.{ null, null }, &.{}, null, false);
    defer data.release();
    try data.validate();
}

test "ArrayData validate with offset" {
    const allocator = std.testing.allocator;
    // 5 elements at offset 2 = need 7 * sizeof(i32) bytes
    const values = try Buffer.allocate(allocator, 7 * @sizeOf(i32));
    errdefer values.release();
    values.freeze();

    const data = try ArrayData.init(allocator, .int32, 5, 2, 0, &.{ null, values }, &.{}, null, false);
    defer data.release();
    try data.validate();

    const small = try Buffer.allocate(allocator, 6 * @sizeOf(i32));
    errdefer small.release();
    small.freeze();
    const data2 = try ArrayData.init(allocator, .int32, 5, 2, 0, &.{ null, small }, &.{}, null, false);
    defer data2.release();
    try std.testing.expectError(error.ValuesBufferTooSmall, data2.validate());
}

test "ArrayData validate null_count mismatch" {
    const bld = @import("builder.zig");
    const allocator = std.testing.allocator;
    var b = bld.NumericBuilder(i32).init(allocator);
    defer b.deinit();
    try b.append(1);
    try b.appendNull();
    try b.append(3);
    const data = try b.finish();
    defer data.release();
    // null_count=1 is correct; bump it to 2 to trigger mismatch.
    data.null_count = 2;
    try std.testing.expectError(error.NullCountMismatch, data.validate());
}

test "ArrayData validate null_count without validity" {
    const allocator = std.testing.allocator;
    const values = try Buffer.allocate(allocator, 3 * @sizeOf(i32));
    errdefer values.release();
    values.freeze();
    // null_count=1 with no validity buffer is inconsistent.
    const data = try ArrayData.init(allocator, .int32, 3, 0, 1, &.{ null, values }, &.{}, null, false);
    defer data.release();
    try std.testing.expectError(error.NullCountWithoutValidity, data.validate());
}

test "ArrayData validate null_count out of bounds" {
    const allocator = std.testing.allocator;
    const values = try Buffer.allocate(allocator, 3 * @sizeOf(i32));
    errdefer values.release();
    values.freeze();
    const data = try ArrayData.init(allocator, .int32, 3, 0, 4, &.{ null, values }, &.{}, null, false);
    defer data.release();
    try std.testing.expectError(error.NullCountOutOfBounds, data.validate());
}

test "ArrayData validate validity buffer too small" {
    const allocator = std.testing.allocator;
    const validity = try Buffer.allocate(allocator, 0);
    errdefer validity.release();
    validity.freeze();
    const values = try Buffer.allocate(allocator, 9 * @sizeOf(i32));
    errdefer values.release();
    values.freeze();
    const data = try ArrayData.init(allocator, .int32, 9, 0, unknown_null_count, &.{ validity, values }, &.{}, null, false);
    defer data.release();
    try std.testing.expectError(error.ValidityBufferTooSmall, data.validate());
}

test "ArrayData validate rejects child data for fixed width type" {
    const allocator = std.testing.allocator;
    // Child with undersized values buffer.
    const child_values = try Buffer.allocate(allocator, 2 * @sizeOf(i32));
    errdefer child_values.release();
    child_values.freeze();
    const child = try ArrayData.init(allocator, .int32, 5, 0, 0, &.{ null, child_values }, &.{}, null, false);
    defer child.release();

    // do_retain=true retains parent_values; caller must release its own reference.
    const parent_values = try Buffer.allocate(allocator, 4 * @sizeOf(i32));
    defer parent_values.release();
    parent_values.freeze();
    const parent = try ArrayData.init(allocator, .int32, 4, 0, 0, &.{ null, parent_values }, &.{child}, null, true);
    defer parent.release();

    try std.testing.expectError(error.UnexpectedChild, parent.validate());
}

test "ArrayData validate rejects dictionary for fixed width type" {
    const allocator = std.testing.allocator;
    // Dictionary with undersized values buffer.
    const dict_values = try Buffer.allocate(allocator, 2 * @sizeOf(i32));
    errdefer dict_values.release();
    dict_values.freeze();
    const dict = try ArrayData.init(allocator, .int32, 5, 0, 0, &.{ null, dict_values }, &.{}, null, false);
    defer dict.release();

    // do_retain=true retains index_values; caller must release its own reference.
    const index_values = try Buffer.allocate(allocator, 4 * @sizeOf(i32));
    defer index_values.release();
    index_values.freeze();
    const data = try ArrayData.init(allocator, .int32, 4, 0, 0, &.{ null, index_values }, &.{}, dict, true);
    defer data.release();

    try std.testing.expectError(error.UnexpectedDictionary, data.validate());
}

test "typeIdFor" {
    try std.testing.expectEqual(datatype.TypeId.int32, typeIdFor(i32));
    try std.testing.expectEqual(datatype.TypeId.float64, typeIdFor(f64));
}

test "NumericArray basic via builder" {
    const bld = @import("builder.zig");
    const allocator = std.testing.allocator;
    var b = bld.NumericBuilder(i32).init(allocator);
    defer b.deinit();

    try b.appendSlice(&.{ 1, 2, 3, 4 });
    const data = try b.finish();
    defer data.release();
    const arr = try NumericArray(i32).fromData(data);

    try std.testing.expectEqual(@as(usize, 4), arr.len);
    try std.testing.expectEqual(@as(i32, 3), arr.value(2));
    try std.testing.expect(arr.isValid(0));
    try std.testing.expect(!arr.isNull(1));
}

test "NumericArray with nulls via builder" {
    const bld = @import("builder.zig");
    const allocator = std.testing.allocator;
    var b = bld.NumericBuilder(i32).init(allocator);
    defer b.deinit();

    try b.append(10);
    try b.appendNull();
    try b.append(30);
    const data = try b.finish();
    defer data.release();
    const arr = try NumericArray(i32).fromData(data);

    try std.testing.expect(arr.isValid(0));
    try std.testing.expect(arr.isNull(1));
    try std.testing.expect(arr.isValid(2));
    try std.testing.expectEqual(@as(i32, 10), arr.value(0));
    try std.testing.expectEqual(@as(i32, 30), arr.value(2));
}

test "NumericArray slice zero-copy view" {
    const bld = @import("builder.zig");
    const allocator = std.testing.allocator;
    var b = bld.NumericBuilder(i32).init(allocator);
    defer b.deinit();

    try b.append(10);
    try b.appendNull();
    try b.append(30);
    try b.appendNull();
    try b.append(50);
    const data = try b.finish();
    defer data.release();
    const arr = try NumericArray(i32).fromData(data);

    const s = arr.slice(1, 3);
    try std.testing.expectEqual(@as(usize, 3), s.len);
    try std.testing.expectEqual(unknown_null_count, s.null_count);
    try std.testing.expectEqual(@as(usize, 2), s.nullCount());
    try std.testing.expect(s.isNull(0));
    try std.testing.expectEqual(@as(i32, 30), s.value(1));
    try std.testing.expect(s.isNull(2));
}

test "NumericArray slice preserves null_count=0 for all-valid" {
    const bld = @import("builder.zig");
    const allocator = std.testing.allocator;
    var b = bld.NumericBuilder(i32).init(allocator);
    defer b.deinit();
    try b.appendSlice(&.{ 1, 2, 3, 4, 5 });
    const data = try b.finish();
    defer data.release();
    const arr = try NumericArray(i32).fromData(data);

    const s = arr.slice(1, 3);
    try std.testing.expect(data.buffers[0] == null);
    try std.testing.expectEqual(@as(usize, 0), s.null_count);
}

test "NumericArray owned slice outlives original owner" {
    const bld = @import("builder.zig");
    const allocator = std.testing.allocator;

    var slice_data: *ArrayData = undefined;
    {
        var b = bld.NumericBuilder(i32).init(allocator);
        defer b.deinit();
        try b.append(1);
        try b.append(2);
        try b.append(3);
        const data = try b.finish();
        defer data.release();
        const arr = try NumericArray(i32).fromData(data);
        slice_data = try arr.sliceOwned(0, 3);
    }
    defer slice_data.release();

    const s = try NumericArray(i32).fromData(slice_data);
    try std.testing.expectEqual(@as(i32, 1), s.value(0));
    try std.testing.expectEqual(@as(i32, 3), s.value(2));
}

test "NumericArray slice all-null shortcut" {
    const bld = @import("builder.zig");
    const allocator = std.testing.allocator;
    var b = bld.NumericBuilder(i32).init(allocator);
    defer b.deinit();
    try b.appendNulls(5);
    const data = try b.finish();
    defer data.release();
    const arr = try NumericArray(i32).fromData(data);

    const s = arr.slice(1, 3);
    try std.testing.expectEqual(@as(usize, 3), s.null_count);
}

test "NumericArray slice clamps length" {
    const bld = @import("builder.zig");
    const allocator = std.testing.allocator;
    var b = bld.NumericBuilder(i32).init(allocator);
    defer b.deinit();
    try b.appendSlice(&.{ 1, 2, 3, 4, 5 });
    const data = try b.finish();
    defer data.release();
    const arr = try NumericArray(i32).fromData(data);

    const s = arr.slice(3, 99);
    try std.testing.expectEqual(@as(usize, 2), s.len);
    try std.testing.expectEqual(@as(i32, 4), s.value(0));
    try std.testing.expectEqual(@as(i32, 5), s.value(1));
}

test "NumericArray sliceChecked rejects offset past end" {
    const bld = @import("builder.zig");
    const allocator = std.testing.allocator;
    var b = bld.NumericBuilder(i32).init(allocator);
    defer b.deinit();
    try b.appendSlice(&.{ 1, 2, 3 });
    const data = try b.finish();
    defer data.release();
    const arr = try NumericArray(i32).fromData(data);

    try std.testing.expectError(error.OffsetOutOfBounds, arr.sliceChecked(4, 1));
    try std.testing.expectError(error.OffsetOutOfBounds, arr.sliceOwned(4, 1));
}

test "logical temporal arrays validate type" {
    const bld = @import("builder.zig");
    const allocator = std.testing.allocator;

    var date_builder = try bld.NumericBuilder(i32).initType(allocator, .date32);
    defer date_builder.deinit();
    try date_builder.appendSlice(&.{ 1, 2, 3 });
    const date_data = try date_builder.finish();
    defer date_data.release();
    const date_arr = try Date32Array.fromData(date_data);
    try std.testing.expectEqual(.date32, date_arr.dataType());
    try std.testing.expectError(error.TypeMismatch, NumericArray(i32).fromData(date_data));

    var time_builder = try bld.NumericBuilder(i32).initType(allocator, .{ .time32 = .millisecond });
    defer time_builder.deinit();
    try time_builder.appendSlice(&.{ 10, 20 });
    const time_data = try time_builder.finish();
    defer time_data.release();
    const time_arr = try Time32Array.fromData(time_data);
    try std.testing.expect(time_arr.dataType().id() == .time32);
}

// ---------------------------------------------------------------------------
// Tests: BooleanArray
// ---------------------------------------------------------------------------

test "BooleanArray basic via builder" {
    const bld = @import("builder.zig");
    const allocator = std.testing.allocator;
    var b = bld.BooleanBuilder.init(allocator);
    defer b.deinit();

    try b.appendSlice(&.{ true, false, true, true, false });
    const data = try b.finish();
    defer data.release();
    const arr = try BooleanArray.fromData(data);

    try std.testing.expectEqual(@as(usize, 5), arr.len);
    try std.testing.expect(arr.value(0));
    try std.testing.expect(!arr.value(1));
    try std.testing.expect(arr.value(2));
    try std.testing.expect(arr.value(3));
    try std.testing.expect(!arr.value(4));
    try std.testing.expectEqual(@as(usize, 3), arr.trueCount());
    try std.testing.expectEqual(@as(usize, 2), arr.falseCount());
}

test "BooleanArray nullCount does not cache" {
    const bld = @import("builder.zig");
    const allocator = std.testing.allocator;
    var b = bld.BooleanBuilder.init(allocator);
    defer b.deinit();

    try b.append(true);
    try b.appendNull();
    try b.append(false);
    try b.appendNull();
    const data = try b.finish();
    defer data.release();
    const arr = try BooleanArray.fromData(data);

    const s = arr.slice(1, 3);
    try std.testing.expectEqual(unknown_null_count, s.null_count);
    try std.testing.expectEqual(@as(usize, 2), s.nullCount());
    try std.testing.expectEqual(unknown_null_count, s.null_count);
}

test "BooleanArray slice clamps length" {
    const bld = @import("builder.zig");
    const allocator = std.testing.allocator;
    var b = bld.BooleanBuilder.init(allocator);
    defer b.deinit();
    try b.appendSlice(&.{ true, false, true, false });
    const data = try b.finish();
    defer data.release();
    const arr = try BooleanArray.fromData(data);

    const s = arr.slice(2, 99);
    try std.testing.expectEqual(@as(usize, 2), s.len);
    try std.testing.expect(s.value(0));
    try std.testing.expect(!s.value(1));
}

test "BooleanArray sliceChecked rejects offset past end" {
    const bld = @import("builder.zig");
    const allocator = std.testing.allocator;
    var b = bld.BooleanBuilder.init(allocator);
    defer b.deinit();
    try b.appendSlice(&.{ true, false, true });
    const data = try b.finish();
    defer data.release();
    const arr = try BooleanArray.fromData(data);

    try std.testing.expectError(error.OffsetOutOfBounds, arr.sliceChecked(4, 1));
    try std.testing.expectError(error.OffsetOutOfBounds, arr.sliceOwned(4, 1));
}
