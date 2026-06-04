//! Small runtime shim for the Zig 0.16 port.
//!
//! Zig 0.16 removed `std.Thread.Mutex` / `std.Thread.Condition` (synchronization
//! now lives under the `std.Io` interface, which requires threading an `Io`
//! value through every call site) and `std.time.sleep`. This library links
//! libc and runs all of its blocking I/O on dedicated OS threads, so rather
//! than adopt the new `Io` plumbing we provide the two primitives the session
//! and bore layers actually need:
//!
//!   * `Mutex` — a tiny test-and-set spinlock. Every critical section in this
//!     codebase is short and non-blocking (an ArrayList push/pop or a peer-list
//!     snapshot), so a spinlock is correct and avoids any `Io` dependency.
//!   * `sleep` — libc `nanosleep`, used only by the in-tree unit tests that
//!     poll for asynchronous socket activity.

const std = @import("std");

extern "c" fn nanosleep(req: *const timespec, rem: ?*timespec) c_int;

const timespec = extern struct {
    tv_sec: isize,
    tv_nsec: isize,
};

/// Test-and-set spinlock. Default-initializable so it can be embedded as a
/// struct field with `= .{}`, matching the old `std.Thread.Mutex` ergonomics.
pub const Mutex = struct {
    state: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    pub fn lock(self: *Mutex) void {
        while (self.state.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {
            std.atomic.spinLoopHint();
        }
    }

    pub fn unlock(self: *Mutex) void {
        self.state.store(false, .release);
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
