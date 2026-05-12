// Copyright 2026 Filippo Rossi
// SPDX-License-Identifier: Apache-2.0

//! Array builder facade.
//!
//! Builders collect mutable values and null state, then transfer immutable
//! `ArrayData` storage to the caller with `finish`.

const numeric = @import("builder_numeric.zig");
const boolean = @import("builder_boolean.zig");
const binary = @import("builder_binary.zig");
const list = @import("builder_list.zig");

pub const NumericBuilder = numeric.NumericBuilder;
pub const NumericBuilderError = numeric.NumericBuilderError;
pub const NumericBuilderInitError = numeric.NumericBuilderInitError;
pub const BooleanBuilder = boolean.BooleanBuilder;
pub const BooleanBuilderError = boolean.BooleanBuilderError;
pub const VarBinaryBuilder = binary.VarBinaryBuilder;
pub const BinaryBuilderError = binary.BinaryBuilderError;
pub const BinaryBuilder = binary.BinaryBuilder;
pub const Utf8Builder = binary.Utf8Builder;
pub const LargeBinaryBuilder = binary.LargeBinaryBuilder;
pub const LargeUtf8Builder = binary.LargeUtf8Builder;
pub const VarListBuilder = list.VarListBuilder;
pub const ListBuilderError = list.ListBuilderError;
pub const ListBuilder = list.ListBuilder;
pub const LargeListBuilder = list.LargeListBuilder;

test {
    _ = numeric;
    _ = boolean;
    _ = binary;
    _ = list;
}
