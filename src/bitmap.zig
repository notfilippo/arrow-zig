//! Bitmap helpers and builder facade.
//!
//! Arrow validity and boolean arrays use least significant bit first packing.
//! This facade exposes bit access, copying, counting, boolean operations, and
//! bitmap building.

const bits = @import("bitmap_bits.zig");
const ops = @import("bitmap_ops.zig");
const builder = @import("bitmap_builder.zig");

pub const unknown_null_count = bits.unknown_null_count;
pub const BitmapBuilder = builder.BitmapBuilder;

pub const byteLen = bits.byteLen;
pub const byteLenChecked = bits.byteLenChecked;
pub const clearBit = bits.clearBit;
pub const copyBits = bits.copyBits;
pub const countSetBits = bits.countSetBits;
pub const getBit = bits.getBit;
pub const invertBits = bits.invertBits;
pub const nullCountFor = bits.nullCountFor;
pub const setBit = bits.setBit;
pub const setBitTo = bits.setBitTo;
pub const setBitsTo = bits.setBitsTo;

pub const andBits = ops.andBits;
pub const andNotBits = ops.andNotBits;
pub const countAndSetBits = ops.countAndSetBits;
pub const orBits = ops.orBits;
pub const orNotBits = ops.orNotBits;
pub const xorBits = ops.xorBits;

test {
    _ = bits;
    _ = ops;
    _ = builder;
}
