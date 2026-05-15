// Copyright 2026 Filippo Rossi
// SPDX-License-Identifier: Apache-2.0

pub fn releaseSchema(schema: anytype) void {
    if (schema.release) |release| release(schema);
}

pub fn releaseArray(arr: anytype) void {
    if (arr.release) |release| release(arr);
}
