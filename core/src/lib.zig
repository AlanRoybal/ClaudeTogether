const std = @import("std");

export fn ct_hello(buf: [*]u8, len: usize) c_int {
    const msg = "core says: ok";
    if (len < msg.len) return -1;
    @memcpy(buf[0..msg.len], msg);
    return @intCast(msg.len);
}

export fn ct_version() c_int {
    return 1;
}
