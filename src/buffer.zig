const std = @import("std");
const Allocator = std.mem.Allocator;
const checked = @import("checked.zig");
const RefCount = @import("refcount.zig").RefCount;

/// Arrow specification: all buffers must be aligned to 64 bytes for SIMD safety.
pub const arrow_alignment: usize = 64;

/// std.mem.Alignment for the Arrow 64-byte requirement.
const arrow_align: std.mem.Alignment = .fromByteUnits(arrow_alignment);

fn nextCapacity(current: usize, needed: usize) checked.Error!usize {
    const doubled = checked.mul(current, 2) catch needed;
    const cap = if (current == 0) needed else @max(needed, doubled);
    return checked.roundUpToPowerOfTwo(cap, 64);
}

pub const BufferContractError = error{
    InvalidCapacity,
    SizeExceedsCapacity,
    NonZeroPadding,
};

pub const AllocateError = Allocator.Error || checked.Error;
pub const ReserveError = Allocator.Error || checked.Error;
pub const SliceError = Allocator.Error || checked.Error || error{OffsetOutOfBounds};
pub const WrapError = Allocator.Error || BufferContractError;

pub const ExternalReleaseFn = *const fn (ctx: *anyopaque) void;

/// Ref-counted handle for memory owned outside the library.
///
/// The handle itself is caller-owned and must remain alive until the final
/// `deinit()` triggers `release_fn(ctx)`. In practice this means it should be
/// embedded in the external owner object or otherwise stored somewhere stable,
/// not copied after first use.
pub const ExternalOwnerHandle = struct {
    ctx: *anyopaque,
    release_fn: ExternalReleaseFn,
    ref_count: RefCount,

    pub fn init(ctx: *anyopaque, release_fn: ExternalReleaseFn) ExternalOwnerHandle {
        return .{
            .ctx = ctx,
            .release_fn = release_fn,
            .ref_count = RefCount.init(1),
        };
    }

    pub fn retain(self: *ExternalOwnerHandle) *ExternalOwnerHandle {
        _ = self.ref_count.fetchAdd(1, .monotonic);
        return self;
    }

    /// Drop one reference. Calls `release_fn` when the count reaches zero.
    pub fn deinit(self: *ExternalOwnerHandle) void {
        if (self.ref_count.fetchSub(1, .acq_rel) != 1) return;
        self.release_fn(self.ctx);
    }

    pub fn refCount(self: *const ExternalOwnerHandle) usize {
        return self.ref_count.load(.monotonic);
    }
};

/// Heap-allocated, reference-counted byte buffer.
///
/// `size` is the number of bytes of valid data. `capacity` is the number of
/// allocated bytes, always a multiple of 64 for internally allocated buffers.
/// Invariant: `size <= capacity`.
///
/// Root buffers may either own their allocation directly or retain an external
/// owner handle. Slice-child buffers hold a retained parent pointer and do not
/// own memory directly.
///
/// Thread safety: retain and deinit are atomic by default. Build with
/// `-Dsingle_threaded=true` to use plain integer ops (no fences, no lock prefix).
pub const Buffer = struct {
    data: [*]u8,
    size: usize,
    capacity: usize,
    allocator: Allocator,
    is_mutable: bool,
    parent: ?*Buffer,
    external_owner: ?*ExternalOwnerHandle,
    ref_count: RefCount,

    /// Allocate a new mutable buffer of the given logical size. Bytes in the
    /// logical range [0, size) are uninitialized; padding bytes [size, capacity)
    /// are zeroed. Capacity is rounded up to a multiple of 64.
    pub fn allocate(allocator: Allocator, size: usize) AllocateError!*Buffer {
        const self = try allocator.create(Buffer);
        errdefer allocator.destroy(self);

        if (size == 0) {
            self.* = .{
                .data = undefined,
                .size = 0,
                .capacity = 0,
                .allocator = allocator,
                .is_mutable = true,
                .parent = null,
                .external_owner = null,
                .ref_count = RefCount.init(1),
            };
            return self;
        }

        const padded = try checked.roundUpToPowerOfTwo(size, 64);
        const slice = try allocator.alignedAlloc(u8, arrow_align, padded);
        @memset(slice[size..padded], 0);

        self.* = .{
            .data = slice.ptr,
            .size = size,
            .capacity = padded,
            .allocator = allocator,
            .is_mutable = true,
            .parent = null,
            .external_owner = null,
            .ref_count = RefCount.init(1),
        };
        return self;
    }

    /// Take ownership of an externally allocated, 64-byte aligned and padded slice.
    /// `size` is the logical byte length; `bytes.len` must be 0 or a multiple of 64.
    /// Padding bytes [size, bytes.len) must be zero. The slice is freed via `allocator`
    /// when the final buffer reference is deinitialized. On error, ownership stays
    /// with the caller.
    pub fn fromOwned(
        allocator: Allocator,
        size: usize,
        bytes: []align(arrow_alignment) u8,
    ) WrapError!*Buffer {
        try validateExternalContract(size, bytes);
        const self = try allocator.create(Buffer);
        self.* = .{
            .data = bytes.ptr,
            .size = size,
            .capacity = bytes.len,
            .allocator = allocator,
            .is_mutable = false,
            .parent = null,
            .external_owner = null,
            .ref_count = RefCount.init(1),
        };
        return self;
    }

    /// Wrap externally owned mutable memory. `size` is the logical byte length;
    /// `bytes.len` must be 0 or a multiple of 64. Padding bytes [size, bytes.len) must be zero.
    /// `owner` is retained until the final buffer reference is deinitialized.
    pub fn wrap(
        allocator: Allocator,
        owner: *ExternalOwnerHandle,
        size: usize,
        bytes: []align(arrow_alignment) u8,
    ) WrapError!*Buffer {
        try validateExternalContract(size, bytes);
        return initExternal(allocator, owner, bytes.ptr, size, bytes.len, true);
    }

    /// Like `wrap` but for immutable external memory. `@constCast` is used internally;
    /// the buffer's `is_mutable` flag is cleared so `mutableSlice()` will assert.
    pub fn wrapConst(
        allocator: Allocator,
        owner: *ExternalOwnerHandle,
        size: usize,
        bytes: []align(arrow_alignment) const u8,
    ) WrapError!*Buffer {
        try validateExternalContract(size, bytes);
        return initExternal(allocator, owner, @constCast(bytes.ptr), size, bytes.len, false);
    }

    /// Create a child buffer whose data window is [off, off+len) within self's allocation.
    /// self is retained; the child has its own refcount and must be deinitialized separately.
    /// Child is frozen regardless of parent's mutability. No re-alignment check is
    /// performed: the parent must already satisfy the 64-byte alignment guarantee.
    pub fn sliceBuffer(self: *Buffer, allocator: Allocator, off: usize, len: usize) SliceError!*Buffer {
        const end = try checked.add(off, len);
        if (end > self.size) return error.OffsetOutOfBounds;
        const child = try allocator.create(Buffer);
        child.* = .{
            .data = self.data + off,
            .size = len,
            .capacity = 0,
            .allocator = allocator,
            .is_mutable = false,
            .parent = self.retain(),
            .external_owner = null,
            .ref_count = RefCount.init(1),
        };
        return child;
    }

    /// Bump refcount. Returns self for chaining.
    pub fn retain(self: *Buffer) *Buffer {
        _ = self.ref_count.fetchAdd(1, .monotonic);
        return self;
    }

    /// Drop one reference. Frees data and control block when count reaches zero.
    pub fn deinit(self: *Buffer) void {
        if (self.ref_count.fetchSub(1, .acq_rel) != 1) return;
        const allocator = self.allocator;
        if (self.parent) |p| {
            p.deinit();
        } else if (self.external_owner) |owner| {
            owner.deinit();
        } else if (self.capacity > 0) {
            const slice: []align(arrow_alignment) u8 = @alignCast(self.data[0..self.capacity]);
            allocator.free(slice);
        }
        allocator.destroy(self);
    }

    /// Mark buffer as immutable. Called by builders before handing off to array storage.
    pub fn freeze(self: *Buffer) void {
        self.is_mutable = false;
    }

    /// Read-only view of valid bytes.
    pub fn dataSlice(self: *const Buffer) []const u8 {
        return self.data[0..self.size];
    }

    /// Mutable view. Asserts is_mutable in debug builds.
    pub fn mutableSlice(self: *Buffer) []u8 {
        std.debug.assert(self.is_mutable);
        return self.data[0..self.size];
    }

    /// Return current reference count. For debug and testing only; not a synchronization primitive.
    pub fn refCount(self: *const Buffer) usize {
        return self.ref_count.load(.monotonic);
    }

    /// Grow capacity to at least new_capacity (rounded to next 64-byte boundary).
    /// Only valid on mutable, directly owned root buffers. Newly available bytes
    /// [size, capacity) are zeroed.
    pub fn reserve(self: *Buffer, new_capacity: usize) ReserveError!void {
        std.debug.assert(self.is_mutable);
        std.debug.assert(self.parent == null);
        std.debug.assert(self.external_owner == null);
        if (new_capacity <= self.capacity) return;
        const padded = try nextCapacity(self.capacity, new_capacity);
        if (self.capacity == 0) {
            const slice = try self.allocator.alignedAlloc(u8, arrow_align, padded);
            @memset(slice[self.size..padded], 0);
            self.data = slice.ptr;
        } else {
            const old_slice: []align(arrow_alignment) u8 = @alignCast(self.data[0..self.capacity]);
            const new_slice = try self.allocator.alignedAlloc(u8, arrow_align, padded);
            @memcpy(new_slice[0..self.size], old_slice[0..self.size]);
            @memset(new_slice[self.size..padded], 0);
            self.allocator.free(old_slice);
            self.data = new_slice.ptr;
        }
        self.capacity = padded;
    }

    fn initExternal(
        allocator: Allocator,
        owner: *ExternalOwnerHandle,
        ptr: [*]u8,
        size: usize,
        capacity: usize,
        is_mutable: bool,
    ) Allocator.Error!*Buffer {
        const self = try allocator.create(Buffer);
        self.* = .{
            .data = ptr,
            .size = size,
            .capacity = capacity,
            .allocator = allocator,
            .is_mutable = is_mutable,
            .parent = null,
            .external_owner = owner.retain(),
            .ref_count = RefCount.init(1),
        };
        return self;
    }
};

fn validateExternalContract(size: usize, bytes: []const u8) BufferContractError!void {
    if (size > bytes.len) return error.SizeExceedsCapacity;
    if (bytes.len == 0) return;
    if (bytes.len % arrow_alignment != 0) return error.InvalidCapacity;
    for (bytes[size..]) |byte| {
        if (byte != 0) return error.NonZeroPadding;
    }
}

const ExternalMemCtx = struct {
    allocator: Allocator,
    mem: []align(arrow_alignment) u8,
    release_count: *usize,
};

fn releaseExternalMem(ctx_ptr: *anyopaque) void {
    const ctx: *ExternalMemCtx = @ptrCast(@alignCast(ctx_ptr));
    ctx.release_count.* += 1;
    ctx.allocator.free(ctx.mem);
}

test "allocate and deinit" {
    const a = std.testing.allocator;
    const buf = try Buffer.allocate(a, 100);
    try std.testing.expectEqual(@as(usize, 100), buf.size);
    try std.testing.expectEqual(@as(usize, 1), buf.refCount());
    buf.deinit();
}

test "retain and double deinit" {
    const a = std.testing.allocator;
    const buf = try Buffer.allocate(a, 64);
    _ = buf.retain();
    try std.testing.expectEqual(@as(usize, 2), buf.refCount());
    buf.deinit();
    try std.testing.expectEqual(@as(usize, 1), buf.refCount());
    buf.deinit();
}

test "empty buffer deinit" {
    const a = std.testing.allocator;
    const buf = try Buffer.allocate(a, 0);
    try std.testing.expectEqual(@as(usize, 0), buf.size);
    try std.testing.expectEqual(@as(usize, 0), buf.capacity);
    buf.deinit();
}

test "sliceBuffer parent lifetime" {
    const a = std.testing.allocator;
    const parent = try Buffer.allocate(a, 128);
    parent.data[0] = 0xAB;
    parent.data[64] = 0xCD;
    parent.freeze();

    const child = try parent.sliceBuffer(a, 64, 64);
    try std.testing.expectEqual(@as(u8, 0xCD), child.data[0]);
    try std.testing.expectEqual(@as(usize, 2), parent.refCount());

    parent.deinit();
    try std.testing.expectEqual(@as(u8, 0xCD), child.data[0]);
    child.deinit();
}

test "sliceBuffer rejects out of bounds ranges" {
    const a = std.testing.allocator;
    const parent = try Buffer.allocate(a, 16);
    defer parent.deinit();

    try std.testing.expectError(error.OffsetOutOfBounds, parent.sliceBuffer(a, 8, 9));
}

test "three-deep chain" {
    const a = std.testing.allocator;
    const root_buf = try Buffer.allocate(a, 192);
    @memset(root_buf.data[0..192], 0x11);
    root_buf.freeze();

    const mid = try root_buf.sliceBuffer(a, 64, 128);
    const leaf = try mid.sliceBuffer(a, 64, 64);

    try std.testing.expectEqual(@as(u8, 0x11), leaf.data[0]);

    root_buf.deinit();
    mid.deinit();
    leaf.deinit();
}

test "allocate zeroes padding" {
    const a = std.testing.allocator;
    const buf = try Buffer.allocate(a, 65);
    defer buf.deinit();
    try std.testing.expectEqual(@as(usize, 128), buf.capacity);
    for (buf.data[65..buf.capacity]) |byte| {
        try std.testing.expectEqual(@as(u8, 0), byte);
    }
}

test "reserve grows exponentially and zeroes tail" {
    const a = std.testing.allocator;
    const buf = try Buffer.allocate(a, 0);
    try buf.reserve(10);
    const cap1 = buf.capacity;
    try std.testing.expect(cap1 >= 64);
    @memset(buf.data[0..8], 0xAA);
    buf.size = 8;
    try buf.reserve(cap1 + 1);
    try std.testing.expect(buf.capacity > cap1);
    for (buf.data[buf.size..buf.capacity]) |byte| {
        try std.testing.expectEqual(@as(u8, 0), byte);
    }
    buf.deinit();
}

test "fromOwned" {
    const a = std.testing.allocator;
    const mem = try a.alignedAlloc(u8, arrow_align, 64);
    @memset(mem, 0);
    mem[0] = 11;
    mem[1] = 22;
    const buf = try Buffer.fromOwned(a, 2, mem);
    defer buf.deinit();
    try std.testing.expectEqual(@as(usize, 2), buf.size);
    try std.testing.expectEqual(@as(usize, 64), buf.capacity);
    try std.testing.expect(!buf.is_mutable);
    try std.testing.expectEqual(@as(u8, 11), buf.dataSlice()[0]);
    try std.testing.expectEqual(@as(u8, 22), buf.dataSlice()[1]);
}

test "fromOwned contract rejects non-zero padding" {
    const a = std.testing.allocator;
    const mem = try a.alignedAlloc(u8, arrow_align, 64);
    defer a.free(mem);
    @memset(mem, 0);
    mem[2] = 1;
    try std.testing.expectError(error.NonZeroPadding, Buffer.fromOwned(a, 2, mem));
}

test "allocate overflow" {
    const a = std.testing.allocator;
    try std.testing.expectError(error.Overflow, Buffer.allocate(a, std.math.maxInt(usize)));
}

test "wrap uses logical size" {
    const a = std.testing.allocator;
    const mem = try a.alignedAlloc(u8, arrow_align, 64);
    @memset(mem, 0);
    mem[0] = 5;
    mem[1] = 6;

    var release_count: usize = 0;
    var ctx = ExternalMemCtx{ .allocator = a, .mem = mem, .release_count = &release_count };
    var owner = ExternalOwnerHandle.init(&ctx, releaseExternalMem);

    const buf = try Buffer.wrap(a, &owner, 2, mem);
    owner.deinit();
    defer buf.deinit();

    try std.testing.expectEqual(@as(usize, 2), buf.size);
    try std.testing.expectEqual(@as(usize, 64), buf.capacity);
    try std.testing.expectEqual(@as(u8, 5), buf.dataSlice()[0]);
    try std.testing.expectEqual(@as(u8, 6), buf.dataSlice()[1]);
}

test "external owner shared across buffers releases once" {
    const a = std.testing.allocator;
    const mem = try a.alignedAlloc(u8, arrow_align, 128);
    mem[0] = 7;
    mem[64] = 9;

    var release_count: usize = 0;
    var ctx = ExternalMemCtx{
        .allocator = a,
        .mem = mem,
        .release_count = &release_count,
    };

    var owner = ExternalOwnerHandle.init(&ctx, releaseExternalMem);

    const buf1 = try Buffer.wrap(a, &owner, 64, mem[0..64]);
    const second_half: []align(arrow_alignment) const u8 = @alignCast(mem[64..128]);
    const buf2 = try Buffer.wrapConst(a, &owner, 64, second_half);

    try std.testing.expectEqual(@as(usize, 3), owner.refCount());
    owner.deinit();
    try std.testing.expectEqual(@as(usize, 2), owner.refCount());

    buf1.mutableSlice()[0] = 42;
    try std.testing.expectEqual(@as(u8, 42), mem[0]);
    try std.testing.expectEqual(@as(u8, 9), buf2.dataSlice()[0]);

    const child = try buf2.sliceBuffer(a, 0, 32);
    try std.testing.expectEqual(@as(usize, 2), buf2.refCount());

    buf2.deinit();
    try std.testing.expectEqual(@as(usize, 0), release_count);

    child.deinit();
    try std.testing.expectEqual(@as(usize, 0), release_count);

    buf1.deinit();
    try std.testing.expectEqual(@as(usize, 1), release_count);
}
