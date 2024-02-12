const std = @import("../std.zig");
const builtin = @import("builtin");
const testing = std.testing;
const mem = std.mem;

const assert = std.debug.assert;
const use_vectors = builtin.zig_backend != .stage2_x86_64;

pub const State = enum {
    /// Begin header parsing states.
    invalid,
    start,
    seen_n,
    seen_r,
    seen_rn,
    seen_rnr,
    headers_end,
    /// Begin transfer-encoding: chunked parsing states.
    chunk_head_size,
    chunk_head_ext,
    chunk_head_r,
    chunk_data,
    chunk_data_suffix,
    chunk_data_suffix_r,
    /// When the parser has finished parsing a complete message. A message is
    /// only complete after the entire body has been read and any trailing
    /// headers have been parsed.
    complete,

    /// Returns true if the parser is in a content state (ie. not waiting for more headers).
    pub fn isContent(self: State) bool {
        return switch (self) {
            .invalid,
            .start,
            .seen_n,
            .seen_r,
            .seen_rn,
            .seen_rnr,
            => false,

            .headers_end,
            .chunk_head_size,
            .chunk_head_ext,
            .chunk_head_r,
            .chunk_data,
            .chunk_data_suffix,
            .chunk_data_suffix_r,
            .complete,
            => true,
        };
    }
};

pub const HeadersParser = struct {
    state: State,
    /// A fixed buffer of len `max_header_bytes`.
    /// Pointers into this buffer are not stable until after a message is complete.
    header_bytes_buffer: []u8,
    header_bytes_len: u32,
    next_chunk_length: u64,

    /// Initializes the parser with a provided buffer `buf`.
    pub fn init(buf: []u8) HeadersParser {
        return .{
            .state = .start,
            .header_bytes_buffer = buf,
            .header_bytes_len = 0,
            .next_chunk_length = 0,
        };
    }

    /// Reinitialize the parser.
    /// Asserts the parser is in the `complete` state.
    pub fn reset(hp: *HeadersParser) void {
        assert(hp.state == .complete);
        hp.* = .{
            .state = .start,
            .header_bytes_buffer = hp.header_bytes_buffer,
            .header_bytes_len = 0,
            .next_chunk_length = 0,
        };
    }

    pub fn get(hp: HeadersParser) []u8 {
        return hp.header_bytes_buffer[0..hp.header_bytes_len];
    }

    /// Returns the number of bytes consumed by headers. This is always less
    /// than or equal to `bytes.len`.
    /// You should check `r.state.isContent()` after this to check if the
    /// headers are done.
    ///
    /// If the amount returned is less than `bytes.len`, you may assume that
    /// the parser is in a content state and the
    /// first byte of content is located at `bytes[result]`.
    pub fn findHeadersEnd(r: *HeadersParser, bytes: []const u8) u32 {
        const vector_len: comptime_int = @max(std.simd.suggestVectorLength(u8) orelse 1, 8);
        const len: u32 = @intCast(bytes.len);
        var index: u32 = 0;

        while (true) {
            switch (r.state) {
                .invalid => unreachable,
                .complete => unreachable,
                .headers_end => return index,
                .start => switch (len - index) {
                    0 => return index,
                    1 => {
                        switch (bytes[index]) {
                            '\r' => r.state = .seen_r,
                            '\n' => r.state = .seen_n,
                            else => {},
                        }

                        return index + 1;
                    },
                    2 => {
                        const b16 = int16(bytes[index..][0..2]);
                        const b8 = intShift(u8, b16);

                        switch (b8) {
                            '\r' => r.state = .seen_r,
                            '\n' => r.state = .seen_n,
                            else => {},
                        }

                        switch (b16) {
                            int16("\r\n") => r.state = .seen_rn,
                            int16("\n\n") => r.state = .headers_end,
                            else => {},
                        }

                        return index + 2;
                    },
                    3 => {
                        const b24 = int24(bytes[index..][0..3]);
                        const b16 = intShift(u16, b24);
                        const b8 = intShift(u8, b24);

                        switch (b8) {
                            '\r' => r.state = .seen_r,
                            '\n' => r.state = .seen_n,
                            else => {},
                        }

                        switch (b16) {
                            int16("\r\n") => r.state = .seen_rn,
                            int16("\n\n") => r.state = .headers_end,
                            else => {},
                        }

                        switch (b24) {
                            int24("\r\n\r") => r.state = .seen_rnr,
                            else => {},
                        }

                        return index + 3;
                    },
                    4...vector_len - 1 => {
                        const b32 = int32(bytes[index..][0..4]);
                        const b24 = intShift(u24, b32);
                        const b16 = intShift(u16, b32);
                        const b8 = intShift(u8, b32);

                        switch (b8) {
                            '\r' => r.state = .seen_r,
                            '\n' => r.state = .seen_n,
                            else => {},
                        }

                        switch (b16) {
                            int16("\r\n") => r.state = .seen_rn,
                            int16("\n\n") => r.state = .headers_end,
                            else => {},
                        }

                        switch (b24) {
                            int24("\r\n\r") => r.state = .seen_rnr,
                            else => {},
                        }

                        switch (b32) {
                            int32("\r\n\r\n") => r.state = .headers_end,
                            else => {},
                        }

                        index += 4;
                        continue;
                    },
                    else => {
                        const chunk = bytes[index..][0..vector_len];
                        const matches = if (use_vectors) matches: {
                            const Vector = @Vector(vector_len, u8);
                            // const BoolVector = @Vector(vector_len, bool);
                            const BitVector = @Vector(vector_len, u1);
                            const SizeVector = @Vector(vector_len, u8);

                            const v: Vector = chunk.*;
                            const matches_r: BitVector = @bitCast(v == @as(Vector, @splat('\r')));
                            const matches_n: BitVector = @bitCast(v == @as(Vector, @splat('\n')));
                            const matches_or: SizeVector = matches_r | matches_n;

                            break :matches @reduce(.Add, matches_or);
                        } else matches: {
                            var matches: u8 = 0;
                            for (chunk) |byte| switch (byte) {
                                '\r', '\n' => matches += 1,
                                else => {},
                            };
                            break :matches matches;
                        };
                        switch (matches) {
                            0 => {},
                            1 => switch (chunk[vector_len - 1]) {
                                '\r' => r.state = .seen_r,
                                '\n' => r.state = .seen_n,
                                else => {},
                            },
                            2 => {
                                const b16 = int16(chunk[vector_len - 2 ..][0..2]);
                                const b8 = intShift(u8, b16);

                                switch (b8) {
                                    '\r' => r.state = .seen_r,
                                    '\n' => r.state = .seen_n,
                                    else => {},
                                }

                                switch (b16) {
                                    int16("\r\n") => r.state = .seen_rn,
                                    int16("\n\n") => r.state = .headers_end,
                                    else => {},
                                }
                            },
                            3 => {
                                const b24 = int24(chunk[vector_len - 3 ..][0..3]);
                                const b16 = intShift(u16, b24);
                                const b8 = intShift(u8, b24);

                                switch (b8) {
                                    '\r' => r.state = .seen_r,
                                    '\n' => r.state = .seen_n,
                                    else => {},
                                }

                                switch (b16) {
                                    int16("\r\n") => r.state = .seen_rn,
                                    int16("\n\n") => r.state = .headers_end,
                                    else => {},
                                }

                                switch (b24) {
                                    int24("\r\n\r") => r.state = .seen_rnr,
                                    else => {},
                                }
                            },
                            4...vector_len => {
                                inline for (0..vector_len - 3) |i_usize| {
                                    const i = @as(u32, @truncate(i_usize));

                                    const b32 = int32(chunk[i..][0..4]);
                                    const b16 = intShift(u16, b32);

                                    if (b32 == int32("\r\n\r\n")) {
                                        r.state = .headers_end;
                                        return index + i + 4;
                                    } else if (b16 == int16("\n\n")) {
                                        r.state = .headers_end;
                                        return index + i + 2;
                                    }
                                }

                                const b24 = int24(chunk[vector_len - 3 ..][0..3]);
                                const b16 = intShift(u16, b24);
                                const b8 = intShift(u8, b24);

                                switch (b8) {
                                    '\r' => r.state = .seen_r,
                                    '\n' => r.state = .seen_n,
                                    else => {},
                                }

                                switch (b16) {
                                    int16("\r\n") => r.state = .seen_rn,
                                    int16("\n\n") => r.state = .headers_end,
                                    else => {},
                                }

                                switch (b24) {
                                    int24("\r\n\r") => r.state = .seen_rnr,
                                    else => {},
                                }
                            },
                            else => unreachable,
                        }

                        index += vector_len;
                        continue;
                    },
                },
                .seen_n => switch (len - index) {
                    0 => return index,
                    else => {
                        switch (bytes[index]) {
                            '\n' => r.state = .headers_end,
                            else => r.state = .start,
                        }

                        index += 1;
                        continue;
                    },
                },
                .seen_r => switch (len - index) {
                    0 => return index,
                    1 => {
                        switch (bytes[index]) {
                            '\n' => r.state = .seen_rn,
                            '\r' => r.state = .seen_r,
                            else => r.state = .start,
                        }

                        return index + 1;
                    },
                    2 => {
                        const b16 = int16(bytes[index..][0..2]);
                        const b8 = intShift(u8, b16);

                        switch (b8) {
                            '\r' => r.state = .seen_r,
                            '\n' => r.state = .seen_rn,
                            else => r.state = .start,
                        }

                        switch (b16) {
                            int16("\r\n") => r.state = .seen_rn,
                            int16("\n\r") => r.state = .seen_rnr,
                            int16("\n\n") => r.state = .headers_end,
                            else => {},
                        }

                        return index + 2;
                    },
                    else => {
                        const b24 = int24(bytes[index..][0..3]);
                        const b16 = intShift(u16, b24);
                        const b8 = intShift(u8, b24);

                        switch (b8) {
                            '\r' => r.state = .seen_r,
                            '\n' => r.state = .seen_n,
                            else => r.state = .start,
                        }

                        switch (b16) {
                            int16("\r\n") => r.state = .seen_rn,
                            int16("\n\n") => r.state = .headers_end,
                            else => {},
                        }

                        switch (b24) {
                            int24("\n\r\n") => r.state = .headers_end,
                            else => {},
                        }

                        index += 3;
                        continue;
                    },
                },
                .seen_rn => switch (len - index) {
                    0 => return index,
                    1 => {
                        switch (bytes[index]) {
                            '\r' => r.state = .seen_rnr,
                            '\n' => r.state = .seen_n,
                            else => r.state = .start,
                        }

                        return index + 1;
                    },
                    else => {
                        const b16 = int16(bytes[index..][0..2]);
                        const b8 = intShift(u8, b16);

                        switch (b8) {
                            '\r' => r.state = .seen_rnr,
                            '\n' => r.state = .seen_n,
                            else => r.state = .start,
                        }

                        switch (b16) {
                            int16("\r\n") => r.state = .headers_end,
                            int16("\n\n") => r.state = .headers_end,
                            else => {},
                        }

                        index += 2;
                        continue;
                    },
                },
                .seen_rnr => switch (len - index) {
                    0 => return index,
                    else => {
                        switch (bytes[index]) {
                            '\n' => r.state = .headers_end,
                            else => r.state = .start,
                        }

                        index += 1;
                        continue;
                    },
                },
                .chunk_head_size => unreachable,
                .chunk_head_ext => unreachable,
                .chunk_head_r => unreachable,
                .chunk_data => unreachable,
                .chunk_data_suffix => unreachable,
                .chunk_data_suffix_r => unreachable,
            }

            return index;
        }
    }

    /// Returns the number of bytes consumed by the chunk size. This is always
    /// less than or equal to `bytes.len`.
    /// You should check `r.state == .chunk_data` after this to check if the
    /// chunk size has been fully parsed.
    ///
    /// If the amount returned is less than `bytes.len`, you may assume that
    /// the parser is in the `chunk_data` state and that the first byte of the
    /// chunk is at `bytes[result]`.
    pub fn findChunkedLen(r: *HeadersParser, bytes: []const u8) u32 {
        const len = @as(u32, @intCast(bytes.len));

        for (bytes[0..], 0..) |c, i| {
            const index = @as(u32, @intCast(i));
            switch (r.state) {
                .chunk_data_suffix => switch (c) {
                    '\r' => r.state = .chunk_data_suffix_r,
                    '\n' => r.state = .chunk_head_size,
                    else => {
                        r.state = .invalid;
                        return index;
                    },
                },
                .chunk_data_suffix_r => switch (c) {
                    '\n' => r.state = .chunk_head_size,
                    else => {
                        r.state = .invalid;
                        return index;
                    },
                },
                .chunk_head_size => {
                    const digit = switch (c) {
                        '0'...'9' => |b| b - '0',
                        'A'...'Z' => |b| b - 'A' + 10,
                        'a'...'z' => |b| b - 'a' + 10,
                        '\r' => {
                            r.state = .chunk_head_r;
                            continue;
                        },
                        '\n' => {
                            r.state = .chunk_data;
                            return index + 1;
                        },
                        else => {
                            r.state = .chunk_head_ext;
                            continue;
                        },
                    };

                    const new_len = r.next_chunk_length *% 16 +% digit;
                    if (new_len <= r.next_chunk_length and r.next_chunk_length != 0) {
                        r.state = .invalid;
                        return index;
                    }

                    r.next_chunk_length = new_len;
                },
                .chunk_head_ext => switch (c) {
                    '\r' => r.state = .chunk_head_r,
                    '\n' => {
                        r.state = .chunk_data;
                        return index + 1;
                    },
                    else => continue,
                },
                .chunk_head_r => switch (c) {
                    '\n' => {
                        r.state = .chunk_data;
                        return index + 1;
                    },
                    else => {
                        r.state = .invalid;
                        return index;
                    },
                },
                else => unreachable,
            }
        }

        return len;
    }

    pub const CheckCompleteHeadError = error{HttpHeadersOversize};

    /// Pushes `in` into the parser. Returns the number of bytes consumed by
    /// the header. Any header bytes are appended to `header_bytes_buffer`.
    pub fn checkCompleteHead(hp: *HeadersParser, in: []const u8) CheckCompleteHeadError!u32 {
        if (hp.state.isContent()) return 0;

        const i = hp.findHeadersEnd(in);
        const data = in[0..i];
        if (hp.header_bytes_len + data.len > hp.header_bytes_buffer.len)
            return error.HttpHeadersOversize;

        @memcpy(hp.header_bytes_buffer[hp.header_bytes_len..][0..data.len], data);
        hp.header_bytes_len += @intCast(data.len);

        return i;
    }

    pub const ReadError = error{
        HttpChunkInvalid,
    };

    /// Reads the body of the message into `buffer`. Returns the number of
    /// bytes placed in the buffer.
    ///
    /// If `skip` is true, the buffer will be unused and the body will be skipped.
    ///
    /// See `std.http.Client.Connection for an example of `conn`.
    pub fn read(r: *HeadersParser, conn: anytype, buffer: []u8, skip: bool) !usize {
        assert(r.state.isContent());
        var out_index: usize = 0;
        while (true) {
            switch (r.state) {
                .complete => return out_index,
                .invalid, .start, .seen_n, .seen_r, .seen_rn, .seen_rnr => unreachable,
                .headers_end => {
                    const data_avail = r.next_chunk_length;

                    if (skip) {
                        try conn.fill();

                        const nread = @min(conn.peek().len, data_avail);
                        conn.drop(@intCast(nread));
                        r.next_chunk_length -= nread;

                        if (r.next_chunk_length == 0 or nread == 0)
                            r.state = .complete;

                        return out_index;
                    } else if (out_index < buffer.len) {
                        const out_avail = buffer.len - out_index;

                        const can_read = @as(usize, @intCast(@min(data_avail, out_avail)));
                        const nread = try conn.read(buffer[0..can_read]);
                        r.next_chunk_length -= nread;

                        if (r.next_chunk_length == 0 or nread == 0)
                            r.state = .complete;

                        return nread;
                    } else {
                        return out_index;
                    }
                },
                .chunk_data_suffix, .chunk_data_suffix_r, .chunk_head_size, .chunk_head_ext, .chunk_head_r => {
                    try conn.fill();

                    const i = r.findChunkedLen(conn.peek());
                    conn.drop(@intCast(i));

                    switch (r.state) {
                        .invalid => return error.HttpChunkInvalid,
                        .chunk_data => if (r.next_chunk_length == 0) {
                            if (std.mem.eql(u8, conn.peek(), "\r\n")) {
                                r.state = .complete;
                            } else {
                                // The trailer section is formatted identically
                                // to the header section.
                                r.state = .seen_rn;
                            }
                            return out_index;
                        },
                        else => return out_index,
                    }

                    continue;
                },
                .chunk_data => {
                    const data_avail = r.next_chunk_length;
                    const out_avail = buffer.len - out_index;

                    if (skip) {
                        try conn.fill();

                        const nread = @min(conn.peek().len, data_avail);
                        conn.drop(@intCast(nread));
                        r.next_chunk_length -= nread;
                    } else if (out_avail > 0) {
                        const can_read: usize = @intCast(@min(data_avail, out_avail));
                        const nread = try conn.read(buffer[out_index..][0..can_read]);
                        r.next_chunk_length -= nread;
                        out_index += nread;
                    }

                    if (r.next_chunk_length == 0) {
                        r.state = .chunk_data_suffix;
                        continue;
                    }

                    return out_index;
                },
            }
        }
    }
};

inline fn int16(array: *const [2]u8) u16 {
    return @bitCast(array.*);
}

inline fn int24(array: *const [3]u8) u24 {
    return @bitCast(array.*);
}

inline fn int32(array: *const [4]u8) u32 {
    return @bitCast(array.*);
}

inline fn intShift(comptime T: type, x: anytype) T {
    switch (@import("builtin").cpu.arch.endian()) {
        .little => return @truncate(x >> (@bitSizeOf(@TypeOf(x)) - @bitSizeOf(T))),
        .big => return @truncate(x),
    }
}

/// A buffered (and peekable) Connection.
const MockBufferedConnection = struct {
    pub const buffer_size = 0x2000;

    conn: std.io.FixedBufferStream([]const u8),
    buf: [buffer_size]u8 = undefined,
    start: u16 = 0,
    end: u16 = 0,

    pub fn fill(conn: *MockBufferedConnection) ReadError!void {
        if (conn.end != conn.start) return;

        const nread = try conn.conn.read(conn.buf[0..]);
        if (nread == 0) return error.EndOfStream;
        conn.start = 0;
        conn.end = @as(u16, @truncate(nread));
    }

    pub fn peek(conn: *MockBufferedConnection) []const u8 {
        return conn.buf[conn.start..conn.end];
    }

    pub fn drop(conn: *MockBufferedConnection, num: u16) void {
        conn.start += num;
    }

    pub fn readAtLeast(conn: *MockBufferedConnection, buffer: []u8, len: usize) ReadError!usize {
        var out_index: u16 = 0;
        while (out_index < len) {
            const available = conn.end - conn.start;
            const left = buffer.len - out_index;

            if (available > 0) {
                const can_read = @as(u16, @truncate(@min(available, left)));

                @memcpy(buffer[out_index..][0..can_read], conn.buf[conn.start..][0..can_read]);
                out_index += can_read;
                conn.start += can_read;

                continue;
            }

            if (left > conn.buf.len) {
                // skip the buffer if the output is large enough
                return conn.conn.read(buffer[out_index..]);
            }

            try conn.fill();
        }

        return out_index;
    }

    pub fn read(conn: *MockBufferedConnection, buffer: []u8) ReadError!usize {
        return conn.readAtLeast(buffer, 1);
    }

    pub const ReadError = std.io.FixedBufferStream([]const u8).ReadError || error{EndOfStream};
    pub const Reader = std.io.Reader(*MockBufferedConnection, ReadError, read);

    pub fn reader(conn: *MockBufferedConnection) Reader {
        return Reader{ .context = conn };
    }

    pub fn writeAll(conn: *MockBufferedConnection, buffer: []const u8) WriteError!void {
        return conn.conn.writeAll(buffer);
    }

    pub fn write(conn: *MockBufferedConnection, buffer: []const u8) WriteError!usize {
        return conn.conn.write(buffer);
    }

    pub const WriteError = std.io.FixedBufferStream([]const u8).WriteError;
    pub const Writer = std.io.Writer(*MockBufferedConnection, WriteError, write);

    pub fn writer(conn: *MockBufferedConnection) Writer {
        return Writer{ .context = conn };
    }
};

test "HeadersParser.findHeadersEnd" {
    var r: HeadersParser = undefined;
    const data = "GET / HTTP/1.1\r\nHost: localhost\r\n\r\nHello";

    for (0..36) |i| {
        r = HeadersParser.init(&.{});
        try std.testing.expectEqual(@as(u32, @intCast(i)), r.findHeadersEnd(data[0..i]));
        try std.testing.expectEqual(@as(u32, @intCast(35 - i)), r.findHeadersEnd(data[i..]));
    }
}

test "HeadersParser.findChunkedLen" {
    var r: HeadersParser = undefined;
    const data = "Ff\r\nf0f000 ; ext\n0\r\nffffffffffffffffffffffffffffffffffffffff\r\n";

    r = HeadersParser.init(&.{});
    r.state = .chunk_head_size;
    r.next_chunk_length = 0;

    const first = r.findChunkedLen(data[0..]);
    try testing.expectEqual(@as(u32, 4), first);
    try testing.expectEqual(@as(u64, 0xff), r.next_chunk_length);
    try testing.expectEqual(State.chunk_data, r.state);
    r.state = .chunk_head_size;
    r.next_chunk_length = 0;

    const second = r.findChunkedLen(data[first..]);
    try testing.expectEqual(@as(u32, 13), second);
    try testing.expectEqual(@as(u64, 0xf0f000), r.next_chunk_length);
    try testing.expectEqual(State.chunk_data, r.state);
    r.state = .chunk_head_size;
    r.next_chunk_length = 0;

    const third = r.findChunkedLen(data[first + second ..]);
    try testing.expectEqual(@as(u32, 3), third);
    try testing.expectEqual(@as(u64, 0), r.next_chunk_length);
    try testing.expectEqual(State.chunk_data, r.state);
    r.state = .chunk_head_size;
    r.next_chunk_length = 0;

    const fourth = r.findChunkedLen(data[first + second + third ..]);
    try testing.expectEqual(@as(u32, 16), fourth);
    try testing.expectEqual(@as(u64, 0xffffffffffffffff), r.next_chunk_length);
    try testing.expectEqual(State.invalid, r.state);
}

test "HeadersParser.read length" {
    // mock BufferedConnection for read
    var headers_buf: [256]u8 = undefined;

    var r = HeadersParser.init(&headers_buf);
    const data = "GET / HTTP/1.1\r\nHost: localhost\r\nContent-Length: 5\r\n\r\nHello";

    var conn: MockBufferedConnection = .{
        .conn = std.io.fixedBufferStream(data),
    };

    while (true) { // read headers
        try conn.fill();

        const nchecked = try r.checkCompleteHead(conn.peek());
        conn.drop(@intCast(nchecked));

        if (r.state.isContent()) break;
    }

    var buf: [8]u8 = undefined;

    r.next_chunk_length = 5;
    const len = try r.read(&conn, &buf, false);
    try std.testing.expectEqual(@as(usize, 5), len);
    try std.testing.expectEqualStrings("Hello", buf[0..len]);

    try std.testing.expectEqualStrings("GET / HTTP/1.1\r\nHost: localhost\r\nContent-Length: 5\r\n\r\n", r.get());
}

test "HeadersParser.read chunked" {
    // mock BufferedConnection for read

    var headers_buf: [256]u8 = undefined;
    var r = HeadersParser.init(&headers_buf);
    const data = "GET / HTTP/1.1\r\nHost: localhost\r\n\r\n2\r\nHe\r\n2\r\nll\r\n1\r\no\r\n0\r\n\r\n";

    var conn: MockBufferedConnection = .{
        .conn = std.io.fixedBufferStream(data),
    };

    while (true) { // read headers
        try conn.fill();

        const nchecked = try r.checkCompleteHead(conn.peek());
        conn.drop(@intCast(nchecked));

        if (r.state.isContent()) break;
    }
    var buf: [8]u8 = undefined;

    r.state = .chunk_head_size;
    const len = try r.read(&conn, &buf, false);
    try std.testing.expectEqual(@as(usize, 5), len);
    try std.testing.expectEqualStrings("Hello", buf[0..len]);

    try std.testing.expectEqualStrings("GET / HTTP/1.1\r\nHost: localhost\r\n\r\n", r.get());
}

test "HeadersParser.read chunked trailer" {
    // mock BufferedConnection for read

    var headers_buf: [256]u8 = undefined;
    var r = HeadersParser.init(&headers_buf);
    const data = "GET / HTTP/1.1\r\nHost: localhost\r\n\r\n2\r\nHe\r\n2\r\nll\r\n1\r\no\r\n0\r\nContent-Type: text/plain\r\n\r\n";

    var conn: MockBufferedConnection = .{
        .conn = std.io.fixedBufferStream(data),
    };

    while (true) { // read headers
        try conn.fill();

        const nchecked = try r.checkCompleteHead(conn.peek());
        conn.drop(@intCast(nchecked));

        if (r.state.isContent()) break;
    }
    var buf: [8]u8 = undefined;

    r.state = .chunk_head_size;
    const len = try r.read(&conn, &buf, false);
    try std.testing.expectEqual(@as(usize, 5), len);
    try std.testing.expectEqualStrings("Hello", buf[0..len]);

    while (true) { // read headers
        try conn.fill();

        const nchecked = try r.checkCompleteHead(conn.peek());
        conn.drop(@intCast(nchecked));

        if (r.state.isContent()) break;
    }

    try std.testing.expectEqualStrings("GET / HTTP/1.1\r\nHost: localhost\r\n\r\nContent-Type: text/plain\r\n\r\n", r.get());
}
