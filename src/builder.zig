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

const numeric = @import("builder_numeric.zig");
const null_builder = @import("builder_null.zig");
const boolean = @import("builder_boolean.zig");
const binary = @import("builder_binary.zig");
const decimal = @import("builder_decimal.zig");
const interval = @import("builder_interval.zig");
const list = @import("builder_list.zig");
const map_builder = @import("builder_map.zig");
const dictionary = @import("builder_dictionary.zig");
const structs = @import("builder_struct.zig");
const unions = @import("builder_union.zig");
const run_end = @import("builder_run_end.zig");
const base = @import("builder_base.zig");

pub const kMinBuilderCapacity = base.kMinBuilderCapacity;

pub const NumericBuilder = numeric.NumericBuilder;
pub const NumericBuilderError = numeric.NumericBuilderError;
pub const NumericBuilderInitError = numeric.NumericBuilderInitError;
pub const NullBuilder = null_builder.NullBuilder;
pub const NullBuilderError = null_builder.NullBuilderError;
pub const BooleanBuilder = boolean.BooleanBuilder;
pub const BooleanBuilderError = boolean.BooleanBuilderError;
pub const VarBinaryBuilder = binary.VarBinaryBuilder;
pub const BinaryBuilderError = binary.BinaryBuilderError;
pub const BinaryBuilder = binary.BinaryBuilder;
pub const Utf8Builder = binary.Utf8Builder;
pub const LargeBinaryBuilder = binary.LargeBinaryBuilder;
pub const LargeUtf8Builder = binary.LargeUtf8Builder;
pub const FixedSizeBinaryBuilder = binary.FixedSizeBinaryBuilder;
pub const DecimalBuilder = decimal.DecimalBuilder;
pub const Decimal128Builder = decimal.Decimal128Builder;
pub const Decimal256Builder = decimal.Decimal256Builder;
pub const DecimalBuilderError = decimal.DecimalBuilderError;
pub const IntervalBuilder = interval.IntervalBuilder;
pub const MonthIntervalBuilder = interval.MonthIntervalBuilder;
pub const DayTimeIntervalBuilder = interval.DayTimeIntervalBuilder;
pub const MonthDayNanoIntervalBuilder = interval.MonthDayNanoIntervalBuilder;
pub const IntervalBuilderError = interval.IntervalBuilderError;
pub const VarListBuilder = list.VarListBuilder;
pub const ListBuilderError = list.ListBuilderError;
pub const ListBuilder = list.ListBuilder;
pub const LargeListBuilder = list.LargeListBuilder;
pub const FixedSizeListBuilder = list.FixedSizeListBuilder;
pub const MapOptions = map_builder.MapOptions;
pub const MapBuilderError = map_builder.MapBuilderError;
pub const DictionaryOptions = dictionary.DictionaryOptions;
pub const DictionaryBuilderError = dictionary.DictionaryBuilderError;
pub const StructFieldOptions = structs.FieldOptions;
pub const StructBuilderError = structs.StructBuilderError;
pub const UnionFieldOptions = unions.FieldOptions;
pub const UnionBuilderError = unions.UnionBuilderError;
pub const RunEndEncodedBuilder = run_end.RunEndEncodedBuilder;
pub const RunEndEncodedBuilderError = run_end.RunEndEncodedBuilderError;

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
