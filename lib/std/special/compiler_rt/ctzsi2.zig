// SPDX-License-Identifier: MIT
// Copyright (c) 2015-2021 Zig Contributors
// This file is part of [zig](https://ziglang.org/), which is MIT licensed.
// The MIT license requires this copyright notice to be included in all copies
// and substantial portions of the software.
const std = @import("std");
const builtin = std.builtin;

fn __ctzsi2_generic(a: i32) callconv(.C) i32 {
    @setRuntimeSafety(builtin.is_test);

    var x = @bitCast(u32, a);
    var n: i32 = 32;

    // Count last bit set using binary search, from Hacker's Delight
    var y: u32 = 0;
    inline for ([_]i32{ 16, 8, 4, 2, 1 }) |shift| {
        y = x << shift;
        if (y != 0) {
            n = n - shift;
            x = y;
        }
    }

    return n - @bitCast(i32, x >> 31);
}

pub const __ctzsi2 = __ctzsi2_generic;

test "test ctzsi2" {
    _ = @import("ctzsi2_test.zig");
}
