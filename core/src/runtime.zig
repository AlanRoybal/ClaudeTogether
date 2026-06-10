//! Small runtime shim for the Zig 0.16 port.
//!
//! Zig 0.16 removed `std.Thread.Mutex` / `std.Thread.Condition` (synchronization
//! now lives under the `std.Io` interface, which requires threading an `Io`
//! value through every call site) and `std.time.sleep`. This library links
//! libc and runs all of its blocking I/O on dedicated OS threads, so rather
//! than adopt the new `Io` plumbing we provide the two primitives the session
//! and bore layers actually need:
//!
//!   * `Mutex` — wraps a libc `pthread_mutex_t`. Some critical sections in
//!     the session layer span blocking socket writes (a peer's `write_mutex`
//!     is held across `sendFrame`), so a spinlock is NOT acceptable here: a
//!     contending thread would burn a full core for as long as a slow peer
//!     stalls the write.
//!   * `sleep` — libc `nanosleep`, used only by the in-tree unit tests that
//!     poll for asynchronous socket activity.

const std = @import("std");

extern "c" fn nanosleep(req: *const timespec, rem: ?*timespec) c_int;

const timespec = extern struct {
    tv_sec: isize,
    tv_nsec: isize,
};

/// Blocking mutex over libc pthreads. Default-initializable so it can be
/// embedded as a struct field with `= .{}`, matching the old
/// `std.Thread.Mutex` ergonomics (`PTHREAD_MUTEX_INITIALIZER` is all the
/// default field values on darwin).
pub const Mutex = struct {
    inner: std.c.pthread_mutex_t = .{},

    pub fn lock(self: *Mutex) void {
        const rc = std.c.pthread_mutex_lock(&self.inner);
        std.debug.assert(rc == .SUCCESS);
    }

    pub fn unlock(self: *Mutex) void {
        const rc = std.c.pthread_mutex_unlock(&self.inner);
        std.debug.assert(rc == .SUCCESS);
    }
};

/// Sleep for `ns` nanoseconds. Coarse; intended for test polling loops.
pub fn sleep(ns: u64) void {
    const ns_per_s = 1_000_000_000;
    var req = timespec{
        .tv_sec = @intCast(ns / ns_per_s),
        .tv_nsec = @intCast(ns % ns_per_s),
    };
    _ = nanosleep(&req, null);
}

pub const ns_per_ms: u64 = 1_000_000;
