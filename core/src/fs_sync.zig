//! Filesystem-sync domain helpers. The actual FSEventStream watcher and the
//! delta-apply logic live on the Swift side (`macos/Sources/Session/FSSync.swift`)
//! because CoreServices integration is much less code through the platform SDK
//! than through CoreFoundation from Zig. This module owns the parts that are
//! wire-format adjacent and worth unit-testing in isolation:
//!
//!  - the "never sync" directory allow-list (`.git`, `node_modules`, etc.)
//!  - relative-path validation (`..` / absolute / NUL rejection) — peers must
//!    run this before applying a host's delta, otherwise a malicious host
//!    could escape the sync root.
//!
//! The Swift applier mirrors the validation; these tests pin the semantics.

const std = @import("std");

/// Directory names we refuse to scan on the host side. These are also names
/// peers refuse to apply into. Kept deliberately small — treat as "things
/// that essentially never belong in a source tree sync", not a full gitignore.
pub const excluded_dir_names = [_][]const u8{
    ".git",
    ".svn",
    ".hg",
    ".DS_Store",
    "node_modules",
    ".build",
    ".zig-cache",
    "build",
    "target",
    ".next",
    ".cache",
    ".venv",
    "__pycache__",
};

pub fn isExcludedName(name: []const u8) bool {
    for (excluded_dir_names) |n| {
        if (std.mem.eql(u8, n, name)) return true;
    }
    return false;
}

pub const PathError = error{
    EmptyPath,
    AbsolutePath,
    TraversalDenied,
    NulByte,
    BackslashComponent,
};

/// Reject anything that could let a host write outside a peer's chosen sync
/// root. Paths must be:
///   - non-empty
///   - relative (no leading `/`)
///   - free of NUL bytes and backslashes (Windows separator — we're
///     forward-slash-only on the wire to keep semantics unambiguous)
///   - free of `..` components
///
/// This is a structural check only — no filesystem normalization. Callers
/// should also resolve the combined root+path and verify the result still
/// starts with the root, belt-and-suspenders.
pub fn validateRelativePath(path: []const u8) PathError!void {
    if (path.len == 0) return error.EmptyPath;
    if (path[0] == '/') return error.AbsolutePath;
    if (std.mem.indexOfScalar(u8, path, 0) != null) return error.NulByte;
    if (std.mem.indexOfScalar(u8, path, '\\') != null) return error.BackslashComponent;

    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |comp| {
        if (std.mem.eql(u8, comp, "..")) return error.TraversalDenied;
    }
}

// --- tests ----------------------------------------------------------------

const testing = std.testing;

test "isExcludedName matches exact names only" {
    try testing.expect(isExcludedName(".git"));
    try testing.expect(isExcludedName("node_modules"));
    try testing.expect(isExcludedName("__pycache__"));
    try testing.expect(!isExcludedName("src"));
    try testing.expect(!isExcludedName(".gitignore"));
    try testing.expect(!isExcludedName("node_modules2"));
}

test "validateRelativePath accepts well-formed relative paths" {
    try validateRelativePath("a");
    try validateRelativePath("a/b");
    try validateRelativePath("src/main.zig");
    try validateRelativePath("deeply/nested/path/to/file.txt");
    try validateRelativePath(".hidden");
    try validateRelativePath("spaces in name.txt");
}

test "validateRelativePath rejects empty" {
    try testing.expectError(error.EmptyPath, validateRelativePath(""));
}

test "validateRelativePath rejects absolute" {
    try testing.expectError(error.AbsolutePath, validateRelativePath("/etc/passwd"));
}

test "validateRelativePath rejects traversal" {
    try testing.expectError(error.TraversalDenied, validateRelativePath(".."));
    try testing.expectError(error.TraversalDenied, validateRelativePath("../etc/passwd"));
    try testing.expectError(error.TraversalDenied, validateRelativePath("a/../b"));
    try testing.expectError(error.TraversalDenied, validateRelativePath("a/b/.."));
}

test "validateRelativePath rejects NUL" {
    try testing.expectError(error.NulByte, validateRelativePath("a\x00b"));
}

test "validateRelativePath rejects backslash" {
    try testing.expectError(error.BackslashComponent, validateRelativePath("a\\b"));
}

test "validateRelativePath does not confuse '..' with names that contain it" {
    try validateRelativePath("..a");
    try validateRelativePath("a..");
    try validateRelativePath("a/..b");
}
