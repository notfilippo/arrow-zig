// Copyright 2026 Filippo Rossi
// SPDX-License-Identifier: Apache-2.0

//! Arrow C Data Interface ABI structs and flags.

pub const schema_flag_dictionary_ordered: i64 = 1;
pub const schema_flag_nullable: i64 = 2;
pub const schema_flag_map_keys_sorted: i64 = 4;

pub const ArrowSchema = extern struct {
    format: ?[*:0]const u8,
    name: ?[*:0]const u8,
    metadata: ?[*]const u8,
    flags: i64,
    n_children: i64,
    children: ?[*]*ArrowSchema,
    dictionary: ?*ArrowSchema,
    release: ?*const fn (*ArrowSchema) callconv(.c) void,
    private_data: ?*anyopaque,
};

pub const ArrowArray = extern struct {
    length: i64,
    null_count: i64,
    offset: i64,
    n_buffers: i64,
    n_children: i64,
    buffers: ?[*]?*const anyopaque,
    children: ?[*]*ArrowArray,
    dictionary: ?*ArrowArray,
    release: ?*const fn (*ArrowArray) callconv(.c) void,
    private_data: ?*anyopaque,
};

pub const ArrowArrayStream = extern struct {
    get_schema: ?*const fn (*ArrowArrayStream, *ArrowSchema) callconv(.c) c_int,
    get_next: ?*const fn (*ArrowArrayStream, *ArrowArray) callconv(.c) c_int,
    get_last_error: ?*const fn (*ArrowArrayStream) callconv(.c) ?[*:0]const u8,
    release: ?*const fn (*ArrowArrayStream) callconv(.c) void,
    private_data: ?*anyopaque,
};
