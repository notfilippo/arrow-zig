// Copyright 2026 Filippo Rossi
// SPDX-License-Identifier: Apache-2.0

//! Array builder facade.
//!
//! Builders collect mutable values and null state, then transfer immutable
//! `ArrayData` storage to the caller with `finish`.
//!
//! `finish()` returns a reference counted `*array.ArrayData`. Call `deinit()`
//! when done. Typed array views do not retain the storage.
//!
//! ```zig
//! var b = arrow.builder.Utf8Builder.init(allocator);
//! defer b.deinit();
//!
//! try b.append("alpha");
//! try b.appendNull();
//! try b.append("beta");
//!
//! const data = try b.finish();
//! defer data.deinit();
//!
//! const values = try arrow.array.Utf8Array.fromData(data);
//! std.debug.print("{s}\n", .{values.value(2)});
//! ```
//!
//! Numeric builders can also produce compatible logical Arrow types.
//!
//! ```zig
//! var dates = try arrow.builder.NumericBuilder(i32).initType(allocator, .date32);
//! defer dates.deinit();
//! ```

const numeric = @import("builder/numeric.zig");
const null_builder = @import("builder/null.zig");
const boolean = @import("builder/boolean.zig");
const binary = @import("builder/binary.zig");
const decimal = @import("builder/decimal.zig");
const interval = @import("builder/interval.zig");
const list = @import("builder/list.zig");
const map_builder = @import("builder/map.zig");
const dictionary = @import("builder/dictionary.zig");
const structs = @import("builder/struct.zig");
const unions = @import("builder/union.zig");
const run_end = @import("builder/run_end.zig");

pub const NumericBuilder = numeric.NumericBuilder;
pub const NullBuilder = null_builder.NullBuilder;
pub const BooleanBuilder = boolean.BooleanBuilder;
pub const BinaryBuilder = binary.BinaryBuilder;
pub const Utf8Builder = binary.Utf8Builder;
pub const LargeBinaryBuilder = binary.LargeBinaryBuilder;
pub const LargeUtf8Builder = binary.LargeUtf8Builder;
pub const BinaryViewBuilder = binary.BinaryViewBuilder;
pub const Utf8ViewBuilder = binary.Utf8ViewBuilder;
pub const FixedSizeBinaryBuilder = binary.FixedSizeBinaryBuilder;
pub const Decimal128Builder = decimal.Decimal128Builder;
pub const Decimal256Builder = decimal.Decimal256Builder;
pub const MonthIntervalBuilder = interval.MonthIntervalBuilder;
pub const DayTimeIntervalBuilder = interval.DayTimeIntervalBuilder;
pub const MonthDayNanoIntervalBuilder = interval.MonthDayNanoIntervalBuilder;
pub const ListBuilder = list.ListBuilder;
pub const LargeListBuilder = list.LargeListBuilder;
pub const ListViewBuilder = list.ListViewBuilder;
pub const LargeListViewBuilder = list.LargeListViewBuilder;
pub const FixedSizeListBuilder = list.FixedSizeListBuilder;
pub const RunEndEncodedBuilder = run_end.RunEndEncodedBuilder;

pub fn DictionaryBuilder(comptime Index: type) type {
    return dictionary.DictionaryBuilder(Index);
}

pub fn MapBuilder(comptime KeyBuilder: type, comptime ValueBuilder: type) type {
    return map_builder.MapBuilder(KeyBuilder, ValueBuilder);
}

pub fn StructBuilder(comptime ChildBuilders: type) type {
    return structs.StructBuilder(ChildBuilders);
}

pub fn SparseUnionBuilder(comptime ChildBuilders: type) type {
    return unions.SparseUnionBuilder(ChildBuilders);
}

pub fn DenseUnionBuilder(comptime ChildBuilders: type) type {
    return unions.DenseUnionBuilder(ChildBuilders);
}
