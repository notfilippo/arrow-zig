const std = @import("std");

pub const TypeId = enum(u8) {
    bool,
    int8,
    int16,
    int32,
    int64,
    uint8,
    uint16,
    uint32,
    uint64,
    float16,
    float32,
    float64,
    date32,
    date64,
    time32,
    time64,
    timestamp,
    duration,
};

/// Temporal resolution for time32, time64, timestamp, and duration types.
pub const TimeUnit = enum { second, millisecond, microsecond, nanosecond };

/// Metadata for the timestamp type (unit + optional timezone string).
pub const TimestampMeta = struct { unit: TimeUnit, tz: ?[]const u8 };

pub const ValidationError = error{InvalidTimeUnit};

/// Tagged union of supported logical types. A payload is present only for
/// parametric types: time32, time64, timestamp, duration.
pub const DataType = union(TypeId) {
    bool,
    int8,
    int16,
    int32,
    int64,
    uint8,
    uint16,
    uint32,
    uint64,
    float16,
    float32,
    float64,
    date32,
    date64,
    time32: TimeUnit,
    time64: TimeUnit,
    timestamp: TimestampMeta,
    duration: TimeUnit,

    /// Return the TypeId tag without the payload.
    pub fn id(self: DataType) TypeId {
        return @as(TypeId, self);
    }

    /// Return the physical bit width of a single value.
    pub fn bitWidth(self: DataType) u16 {
        return switch (self) {
            .bool => 1,
            .int8, .uint8 => 8,
            .int16, .uint16, .float16 => 16,
            .int32, .uint32, .float32, .date32, .time32 => 32,
            .int64, .uint64, .float64, .date64, .time64, .timestamp, .duration => 64,
        };
    }

    /// Return a canonical string name for the type (e.g. "int32", "timestamp").
    pub fn name(self: DataType) []const u8 {
        return switch (self) {
            .bool => "bool",
            .int8 => "int8",
            .int16 => "int16",
            .int32 => "int32",
            .int64 => "int64",
            .uint8 => "uint8",
            .uint16 => "uint16",
            .uint32 => "uint32",
            .uint64 => "uint64",
            .float16 => "float16",
            .float32 => "float32",
            .float64 => "float64",
            .date32 => "date32",
            .date64 => "date64",
            .time32 => "time32",
            .time64 => "time64",
            .timestamp => "timestamp",
            .duration => "duration",
        };
    }

    /// Validate parametric invariants.
    pub fn validate(self: DataType) ValidationError!void {
        switch (self) {
            .time32 => |unit| switch (unit) {
                .second, .millisecond => {},
                .microsecond, .nanosecond => return error.InvalidTimeUnit,
            },
            .time64 => |unit| switch (unit) {
                .microsecond, .nanosecond => {},
                .second, .millisecond => return error.InvalidTimeUnit,
            },
            else => {},
        }
    }

    /// Deep equality including parametric metadata (unit, timezone).
    pub fn equals(a: DataType, b: DataType) bool {
        if (a.id() != b.id()) return false;
        return switch (a) {
            .time32 => a.time32 == b.time32,
            .time64 => a.time64 == b.time64,
            .duration => a.duration == b.duration,
            .timestamp => a.timestamp.unit == b.timestamp.unit and
                std.mem.eql(u8, a.timestamp.tz orelse "", b.timestamp.tz orelse ""),
            else => true,
        };
    }
};

test "DataType.equals" {
    try std.testing.expect(DataType.equals(.int32, .int32));
    try std.testing.expect(!DataType.equals(.int32, .int64));
    const ts_a = DataType{ .timestamp = .{ .unit = .microsecond, .tz = "UTC" } };
    const ts_b = DataType{ .timestamp = .{ .unit = .microsecond, .tz = "UTC" } };
    const ts_c = DataType{ .timestamp = .{ .unit = .millisecond, .tz = "UTC" } };
    try std.testing.expect(DataType.equals(ts_a, ts_b));
    try std.testing.expect(!DataType.equals(ts_a, ts_c));
}

test "DataType.bitWidth" {
    try std.testing.expectEqual(@as(u16, 1), DataType.bitWidth(.bool));
    try std.testing.expectEqual(@as(u16, 32), DataType.bitWidth(.int32));
    try std.testing.expectEqual(@as(u16, 64), DataType.bitWidth(.float64));
}

test "DataType.validate" {
    try DataType.validate(.{ .time32 = .second });
    try DataType.validate(.{ .time64 = .nanosecond });
    try std.testing.expectError(error.InvalidTimeUnit, DataType.validate(.{ .time32 = .microsecond }));
    try std.testing.expectError(error.InvalidTimeUnit, DataType.validate(.{ .time64 = .millisecond }));
}
