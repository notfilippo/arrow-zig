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

    /// Validate storage layout invariants implied by the logical type.
    pub fn validate(self: *const ArrayData) (ValidateError || checked.Error || datatype.ValidationError)!void {
        try self.type.validate();
        const total = try checked.add(self.offset, self.len);
        try validateData(self, self.type, total);
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
        if (self.type.id() == .null_) return self.len;
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

const NullLayout = enum { bitmap, none, always_null };

fn validateData(data: *const ArrayData, ty: datatype.DataType, total: usize) (ValidateError || checked.Error || datatype.ValidationError)!void {
    try validateChildCount(data, ty.childCount());
    if (ty.id() != .dictionary and data.dictionary != null) return error.UnexpectedDictionary;

    switch (ty) {
        .null_ => {
            try expectBufferCount(data, 1);
            try validateNulls(data, total, .always_null);
        },
        .bool, .int8, .int16, .int32, .int64, .uint8, .uint16, .uint32, .uint64, .float16, .float32, .float64, .date32, .date64, .time32, .time64, .timestamp, .duration => {
            try validateFixedWidth(data, total, ty);
        },
        .binary, .utf8 => try validateBinaryLike(data, total, i32),
        .large_binary, .large_utf8 => try validateBinaryLike(data, total, i64),
        .list => |meta| try validateListLike(data, total, meta.child, i32),
        .large_list => |meta| try validateListLike(data, total, meta.child, i64),
        .fixed_size_list => |meta| try validateFixedSizeList(data, total, meta),
        .struct_ => |meta| try validateStruct(data, total, meta),
        .sparse_union => |meta| try validateUnion(data, total, meta, false),
        .dense_union => |meta| try validateUnion(data, total, meta, true),
        .dictionary => |meta| try validateDictionary(data, total, meta),
    }
}

fn validateChildCount(data: *const ArrayData, expected: usize) ValidateError!void {
    if (data.children.len == expected) return;
    if (expected == 0) return error.UnexpectedChild;
    return error.InvalidChildCount;
}

fn expectBufferCount(data: *const ArrayData, expected: usize) ValidateError!void {
    if (data.buffers.len != expected) return error.InvalidBufferCount;
}

fn validateNulls(data: *const ArrayData, total: usize, layout: NullLayout) (ValidateError || checked.Error)!void {
    switch (layout) {
        .always_null => {
            if (data.null_count != data.len) return error.NullCountMismatch;
        },
        .none => {
            if (data.null_count != 0 and data.null_count != unknown_null_count)
                return error.NullCountWithoutValidity;
        },
        .bitmap => {
            if (data.null_count != unknown_null_count and data.null_count > data.len)
                return error.NullCountOutOfBounds;

            if (data.buffers[0]) |validity_buf| {
                const needed = if (data.len == 0) 0 else try bitmap.byteLenChecked(total);
                if (validity_buf.size < needed) return error.ValidityBufferTooSmall;
                if (data.null_count != unknown_null_count) {
                    const actual = data.len - bitmap.countSetBits(validity_buf.dataSlice(), data.offset, data.len);
                    if (actual != data.null_count) return error.NullCountMismatch;
                }
            } else if (data.null_count != 0 and data.null_count != unknown_null_count) {
                return error.NullCountWithoutValidity;
            }
        },
    }
}

fn validateFixedWidth(data: *const ArrayData, total: usize, ty: datatype.DataType) (ValidateError || checked.Error)!void {
    try expectBufferCount(data, 2);
    try validateNulls(data, total, .bitmap);

    const value_needed: usize = if (data.len == 0)
        0
    else if (ty.id() == .bool)
        try bitmap.byteLenChecked(total)
    else
        try checked.mul(total, @as(usize, ty.bitWidth()) / 8);

    if (data.buffers[1]) |values_buf| {
        if (values_buf.size < value_needed) return error.ValuesBufferTooSmall;
    } else if (data.len > 0) {
        return error.MissingValuesBuffer;
    }
}

fn validateBinaryLike(data: *const ArrayData, total: usize, comptime Offset: type) (ValidateError || checked.Error)!void {
    try expectBufferCount(data, 3);
    try validateNulls(data, total, .bitmap);
    const values = data.buffers[2] orelse return error.MissingValuesBuffer;
    const offsets = try validateOffsetsBuffer(data, total, Offset);
    if (offsets) |offset_buf| try validateOffsets(data, offset_buf, values.size, Offset);
}

fn validateListLike(data: *const ArrayData, total: usize, child_field: datatype.Field, comptime Offset: type) (ValidateError || checked.Error || datatype.ValidationError)!void {
    try expectBufferCount(data, 2);
    try validateNulls(data, total, .bitmap);

    const child = data.children[0];
    if (!datatype.DataType.equals(child.type, child_field.type.*)) return error.ChildTypeMismatch;
    try child.validate();

    const offsets = try validateOffsetsBuffer(data, total, Offset);
    if (offsets) |offset_buf| try validateOffsets(data, offset_buf, child.len, Offset);
}

fn validateFixedSizeList(data: *const ArrayData, total: usize, meta: datatype.FixedSizeListMeta) (ValidateError || checked.Error || datatype.ValidationError)!void {
    try expectBufferCount(data, 1);
    try validateNulls(data, total, .bitmap);

    const child = data.children[0];
    if (!datatype.DataType.equals(child.type, meta.child.type.*)) return error.ChildTypeMismatch;
    try child.validate();

    const needed = try checked.mul(total, meta.len);
    if (child.len < needed) return error.ChildLengthTooSmall;
}

fn validateStruct(data: *const ArrayData, total: usize, meta: datatype.StructMeta) (ValidateError || checked.Error || datatype.ValidationError)!void {
    try expectBufferCount(data, 1);
    try validateNulls(data, total, .bitmap);

    for (data.children, meta.fields) |child, field| {
        try child.validate();
        if (!datatype.DataType.equals(child.type, field.type.*)) return error.ChildTypeMismatch;
        if (child.len < total) return error.ChildLengthTooSmall;
    }
}

fn validateUnion(data: *const ArrayData, total: usize, meta: datatype.UnionMeta, comptime dense: bool) (ValidateError || checked.Error || datatype.ValidationError)!void {
    try expectBufferCount(data, if (dense) 3 else 2);
    try validateNulls(data, total, .none);

    for (data.children, meta.fields) |child, field| {
        try child.validate();
        if (!datatype.DataType.equals(child.type, field.type.*)) return error.ChildTypeMismatch;
        if (!dense and child.len < total) return error.ChildLengthTooSmall;
    }

    const type_ids = data.buffers[1] orelse return error.MissingTypeIdsBuffer;
    const needed_type_ids = try checked.add(data.offset, data.len);
    if (type_ids.size < needed_type_ids) return error.TypeIdsBufferTooSmall;

    const offsets: ?*Buffer = if (dense) blk: {
        const buf = data.buffers[2] orelse return error.MissingUnionOffsetsBuffer;
        const needed = try checked.mul(needed_type_ids, @sizeOf(i32));
        if (buf.size < needed) return error.UnionOffsetsBufferTooSmall;
        break :blk buf;
    } else null;

    var last_offsets = [_]usize{0} ** 128;
    for (0..data.len) |i| {
        const code = readInt(i8, type_ids, data.offset + i);
        const child_index = childIndexFor(meta, code) orelse return error.UnionTypeIdOutOfBounds;
        if (offsets) |offset_buf| {
            const off = try offsetToUsize(readInt(i32, offset_buf, data.offset + i));
            if (off >= data.children[child_index].len) return error.UnionOffsetOutOfBounds;
            const code_index: usize = @intCast(code);
            if (off < last_offsets[code_index]) return error.UnionOffsetNotMonotonic;
            last_offsets[code_index] = off;
        }
    }
}

fn validateDictionary(data: *const ArrayData, total: usize, meta: datatype.DictionaryMeta) (ValidateError || checked.Error || datatype.ValidationError)!void {
    if (data.dictionary == null) return error.MissingDictionary;
    if (!meta.index_type.isInteger()) return error.InvalidDictionaryIndexType;
    try validateFixedWidth(data, total, meta.index_type.*);

    const dict = data.dictionary.?;
    try dict.validate();
    if (!datatype.DataType.equals(dict.type, meta.value_type.*)) return error.DictionaryTypeMismatch;
}

fn validateOffsetsBuffer(data: *const ArrayData, total: usize, comptime Offset: type) (ValidateError || checked.Error)!?*Buffer {
    const offsets = data.buffers[1] orelse {
        if (data.len == 0) return null;
        return error.MissingOffsetsBuffer;
    };

    const required_offsets = if (data.len > 0 or offsets.size > 0) try checked.add(total, 1) else 0;
    const needed = try checked.mul(required_offsets, @sizeOf(Offset));
    if (offsets.size < needed) return error.OffsetsBufferTooSmall;
    return offsets;
}

fn validateOffsets(data: *const ArrayData, offsets: *Buffer, limit: usize, comptime Offset: type) ValidateError!void {
    if (data.len == 0) return;
    var previous = try offsetToUsize(readInt(Offset, offsets, data.offset));
    if (previous > limit) return error.OffsetValueOutOfBounds;
    for (1..data.len + 1) |i| {
        const current = try offsetToUsize(readInt(Offset, offsets, data.offset + i));
        if (current < previous) return error.OffsetsNotMonotonic;
        if (current > limit) return error.OffsetValueOutOfBounds;
        previous = current;
    }
}

fn childIndexFor(meta: datatype.UnionMeta, code: i8) ?usize {
    if (code < 0) return null;
    for (meta.type_ids, 0..) |id, i| {
        if (id == code) return i;
    }
    return null;
}

fn readInt(comptime T: type, buffer: *Buffer, index: usize) T {
    const start = index * @sizeOf(T);
    const bytes = buffer.dataSlice()[start..][0..@sizeOf(T)];
    return std.mem.readInt(T, bytes, .little);
}

fn writeTestInt(comptime T: type, buffer: *Buffer, index: usize, value: T) void {
    const start = index * @sizeOf(T);
    std.mem.writeInt(T, buffer.data[start..][0..@sizeOf(T)], value, .little);
}

fn offsetToUsize(value: anytype) ValidateError!usize {
    if (value < 0) return error.NegativeOffset;
    return @intCast(value);
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
    InvalidChildCount,
    MissingValuesBuffer,
    MissingOffsetsBuffer,
    MissingDictionary,
    MissingTypeIdsBuffer,
    MissingUnionOffsetsBuffer,
    ValuesBufferTooSmall,
    ValidityBufferTooSmall,
    OffsetsBufferTooSmall,
    TypeIdsBufferTooSmall,
    UnionOffsetsBufferTooSmall,
    NullCountMismatch,
    NullCountWithoutValidity,
    NullCountOutOfBounds,
    NegativeOffset,
    OffsetValueOutOfBounds,
    OffsetsNotMonotonic,
    UnionTypeIdOutOfBounds,
    UnionOffsetOutOfBounds,
    UnionOffsetNotMonotonic,
    ChildTypeMismatch,
    ChildLengthTooSmall,
    DictionaryTypeMismatch,
    InvalidDictionaryIndexType,
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
            return slotIsValid(self.data, self.offset, i);
        }

        pub fn isNull(self: Self, i: usize) bool {
            return !self.isValid(i);
        }

        pub fn nullCount(self: Self) usize {
            return viewNullCount(self.data, self.offset, self.len, self.null_count);
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

pub const VarBinaryKind = enum {
    binary,
    utf8,
    large_binary,
    large_utf8,
};

fn offsetTypeFor(comptime kind: VarBinaryKind) type {
    return switch (kind) {
        .binary, .utf8 => i32,
        .large_binary, .large_utf8 => i64,
    };
}

fn dataTypeMatchesVarBinary(comptime kind: VarBinaryKind, ty: datatype.DataType) bool {
    return switch (kind) {
        .binary => ty == .binary,
        .utf8 => ty == .utf8,
        .large_binary => ty == .large_binary,
        .large_utf8 => ty == .large_utf8,
    };
}

pub fn VarBinaryView(comptime kind: VarBinaryKind) type {
    const Offset = offsetTypeFor(kind);

    return struct {
        const Self = @This();

        data: *const ArrayData,
        offset: usize,
        len: usize,
        null_count: usize,

        pub fn fromData(data: *const ArrayData) ViewError!Self {
            if (!dataTypeMatchesVarBinary(kind, data.type)) return error.TypeMismatch;
            if (data.buffers.len < 3 or data.buffers[2] == null) return error.InvalidBufferLayout;
            if (data.len > 0 and data.buffers[1] == null) return error.InvalidBufferLayout;
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

        pub fn valueBytes(self: Self, i: usize) []const u8 {
            const offsets = self.data.buffers[1].?;
            const values = self.data.buffers[2].?;
            const start: usize = @intCast(readInt(Offset, offsets, self.offset + i));
            const end: usize = @intCast(readInt(Offset, offsets, self.offset + i + 1));
            return values.dataSlice()[start..end];
        }

        pub fn value(self: Self, i: usize) []const u8 {
            return self.valueBytes(i);
        }

        pub fn isValid(self: Self, i: usize) bool {
            return slotIsValid(self.data, self.offset, i);
        }

        pub fn isNull(self: Self, i: usize) bool {
            return !self.isValid(i);
        }

        pub fn nullCount(self: Self) usize {
            return viewNullCount(self.data, self.offset, self.len, self.null_count);
        }

        pub fn slice(self: Self, off: usize, length: usize) Self {
            const clamped = clampedLen(self.len, off, length) catch unreachable;
            return .{
                .data = self.data,
                .offset = self.offset + off,
                .len = clamped,
                .null_count = slicedNullCount(self.null_count, self.len, off, clamped),
            };
        }

        pub fn sliceChecked(self: Self, off: usize, length: usize) SliceError!Self {
            const clamped = try clampedLen(self.len, off, length);
            return .{
                .data = self.data,
                .offset = self.offset + off,
                .len = clamped,
                .null_count = slicedNullCount(self.null_count, self.len, off, clamped),
            };
        }

        pub fn sliceOwned(self: Self, off: usize, length: usize) !*ArrayData {
            const clamped = try clampedLen(self.len, off, length);
            return self.data.slice(off, clamped);
        }

        pub fn cloneRetained(self: Self) !*ArrayData {
            return self.data.cloneRetained();
        }
    };
}

fn slotIsValid(data: *const ArrayData, offset: usize, i: usize) bool {
    const validity = data.buffers[0] orelse return true;
    return bitmap.getBit(validity.dataSlice(), offset + i);
}

fn viewNullCount(data: *const ArrayData, offset: usize, len: usize, hint: usize) usize {
    if (data.type.id() == .null_) return len;
    const validity = data.buffers[0];
    return bitmap.nullCountFor(
        if (validity) |v| v.dataSlice() else null,
        offset,
        len,
        hint,
    );
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
pub const BinaryArray = VarBinaryView(.binary);
pub const Utf8Array = VarBinaryView(.utf8);
pub const LargeBinaryArray = VarBinaryView(.large_binary);
pub const LargeUtf8Array = VarBinaryView(.large_utf8);

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

test "ArrayData validate null layout" {
    const allocator = std.testing.allocator;
    const data = try ArrayData.init(allocator, .null_, 3, 0, 3, &.{null}, &.{}, null, false);
    defer data.release();

    try data.validate();
    try std.testing.expectEqual(@as(usize, 3), data.nullCount());

    data.null_count = 0;
    try std.testing.expectError(error.NullCountMismatch, data.validate());
}

test "ArrayData validate binary layout" {
    const allocator = std.testing.allocator;
    const offsets = try Buffer.allocate(allocator, 3 * @sizeOf(i32));
    errdefer offsets.release();
    writeTestInt(i32, offsets, 0, 0);
    writeTestInt(i32, offsets, 1, 2);
    writeTestInt(i32, offsets, 2, 5);
    offsets.freeze();

    const values = try Buffer.allocate(allocator, 5);
    errdefer values.release();
    @memcpy(values.data[0..5], "abcde");
    values.freeze();

    const data = try ArrayData.init(allocator, .binary, 2, 0, 0, &.{ null, offsets, values }, &.{}, null, false);
    defer data.release();
    try data.validate();

    const short_offsets = try Buffer.allocate(allocator, 2 * @sizeOf(i32));
    errdefer short_offsets.release();
    short_offsets.freeze();
    const invalid = try ArrayData.init(allocator, .binary, 2, 0, 0, &.{ null, short_offsets, values.retain() }, &.{}, null, false);
    defer invalid.release();
    try std.testing.expectError(error.OffsetsBufferTooSmall, invalid.validate());
}

test "ArrayData validate list layout" {
    const allocator = std.testing.allocator;
    const child_values = try Buffer.allocate(allocator, 5 * @sizeOf(i32));
    errdefer child_values.release();
    child_values.freeze();
    const child = try ArrayData.init(allocator, .int32, 5, 0, 0, &.{ null, child_values }, &.{}, null, false);
    defer child.release();

    const offsets = try Buffer.allocate(allocator, 3 * @sizeOf(i32));
    errdefer offsets.release();
    writeTestInt(i32, offsets, 0, 0);
    writeTestInt(i32, offsets, 1, 2);
    writeTestInt(i32, offsets, 2, 5);
    offsets.freeze();
    defer offsets.release();

    const value_ty: datatype.DataType = .int32;
    const list_ty = datatype.DataType{ .list = .{ .child = .{ .name = "item", .type = &value_ty } } };
    const data = try ArrayData.init(allocator, list_ty, 2, 0, 0, &.{ null, offsets }, &.{child}, null, true);
    defer data.release();
    try data.validate();

    const short_child_values = try Buffer.allocate(allocator, 4 * @sizeOf(i32));
    errdefer short_child_values.release();
    short_child_values.freeze();
    const short_child = try ArrayData.init(allocator, .int32, 4, 0, 0, &.{ null, short_child_values }, &.{}, null, false);
    defer short_child.release();
    const invalid = try ArrayData.init(allocator, list_ty, 2, 0, 0, &.{ null, offsets }, &.{short_child}, null, true);
    defer invalid.release();
    try std.testing.expectError(error.OffsetValueOutOfBounds, invalid.validate());
}

test "ArrayData validate struct layout" {
    const allocator = std.testing.allocator;
    const child_values = try Buffer.allocate(allocator, 3 * @sizeOf(i32));
    errdefer child_values.release();
    child_values.freeze();
    const child = try ArrayData.init(allocator, .int32, 3, 0, 0, &.{ null, child_values }, &.{}, null, false);
    defer child.release();

    const field_ty: datatype.DataType = .int32;
    const fields = [_]datatype.Field{.{ .name = "a", .type = &field_ty }};
    const struct_ty = datatype.DataType{ .struct_ = .{ .fields = &fields } };
    const data = try ArrayData.init(allocator, struct_ty, 3, 0, 0, &.{null}, &.{child}, null, true);
    defer data.release();
    try data.validate();

    const invalid = try ArrayData.init(allocator, struct_ty, 4, 0, 0, &.{null}, &.{child}, null, true);
    defer invalid.release();
    try std.testing.expectError(error.ChildLengthTooSmall, invalid.validate());
}

test "ArrayData validate dictionary layout" {
    const allocator = std.testing.allocator;
    const index_values = try Buffer.allocate(allocator, 3 * @sizeOf(i8));
    errdefer index_values.release();
    index_values.freeze();
    defer index_values.release();

    const dict_values = try Buffer.allocate(allocator, 4 * @sizeOf(i32));
    errdefer dict_values.release();
    dict_values.freeze();
    const dict = try ArrayData.init(allocator, .int32, 4, 0, 0, &.{ null, dict_values }, &.{}, null, false);
    defer dict.release();

    const index_ty: datatype.DataType = .int8;
    const value_ty: datatype.DataType = .int32;
    const dict_ty = datatype.DataType{ .dictionary = .{ .index_type = &index_ty, .value_type = &value_ty } };
    const data = try ArrayData.init(allocator, dict_ty, 3, 0, 0, &.{ null, index_values }, &.{}, dict, true);
    defer data.release();
    try data.validate();

    const missing = try ArrayData.init(allocator, dict_ty, 3, 0, 0, &.{ null, index_values.retain() }, &.{}, null, false);
    defer missing.release();
    try std.testing.expectError(error.MissingDictionary, missing.validate());
}

test "ArrayData validate dense union layout" {
    const allocator = std.testing.allocator;
    const int_values = try Buffer.allocate(allocator, 2 * @sizeOf(i32));
    errdefer int_values.release();
    int_values.freeze();
    const int_child = try ArrayData.init(allocator, .int32, 2, 0, 0, &.{ null, int_values }, &.{}, null, false);
    defer int_child.release();

    const bool_values = try Buffer.allocate(allocator, bitmap.byteLen(1));
    errdefer bool_values.release();
    bool_values.data[0] = 1;
    bool_values.freeze();
    const bool_child = try ArrayData.init(allocator, .bool, 1, 0, 0, &.{ null, bool_values }, &.{}, null, false);
    defer bool_child.release();

    const type_ids = try Buffer.allocate(allocator, 3);
    errdefer type_ids.release();
    type_ids.data[0] = 7;
    type_ids.data[1] = 8;
    type_ids.data[2] = 7;
    type_ids.freeze();
    defer type_ids.release();

    const offsets = try Buffer.allocate(allocator, 3 * @sizeOf(i32));
    errdefer offsets.release();
    writeTestInt(i32, offsets, 0, 0);
    writeTestInt(i32, offsets, 1, 0);
    writeTestInt(i32, offsets, 2, 1);
    offsets.freeze();
    defer offsets.release();

    const int_ty: datatype.DataType = .int32;
    const bool_ty: datatype.DataType = .bool;
    const fields = [_]datatype.Field{
        .{ .name = "i", .type = &int_ty },
        .{ .name = "b", .type = &bool_ty },
    };
    const ids = [_]i8{ 7, 8 };
    const union_ty = datatype.DataType{ .dense_union = .{ .fields = &fields, .type_ids = &ids } };
    const data = try ArrayData.init(allocator, union_ty, 3, 0, 0, &.{ null, type_ids, offsets }, &.{ int_child, bool_child }, null, true);
    defer data.release();
    try data.validate();

    const bad_offsets = try Buffer.allocate(allocator, 3 * @sizeOf(i32));
    errdefer bad_offsets.release();
    writeTestInt(i32, bad_offsets, 0, 0);
    writeTestInt(i32, bad_offsets, 1, 1);
    writeTestInt(i32, bad_offsets, 2, 1);
    bad_offsets.freeze();
    defer bad_offsets.release();
    const invalid = try ArrayData.init(allocator, union_ty, 3, 0, 0, &.{ null, type_ids, bad_offsets }, &.{ int_child, bool_child }, null, true);
    defer invalid.release();
    try std.testing.expectError(error.UnionOffsetOutOfBounds, invalid.validate());
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
