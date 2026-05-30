//! branch_label: v0.0.9 — per-branch label registry.
//!
//! BranchAgeRegistry (v0.0.8) tracks creation_ns. Production
//! callers also want a human-readable label per branch so logs
//! and dashboards can show "main" or "dev-2026-05-30" instead of
//! a u64 BranchId. Port a small label registry; caller owns the
//! string lifetime, the registry just maps.
//!
//! Scope of this revision:
//!   BranchLabelRegistry { allocator, by_branch: BranchId ->
//!     []const u8 (non-owning slice) }.
//!   set(branch_id, label) registers / overwrites.
//!   get(branch_id) returns the label or null.
//!   forget(branch_id) removes.
//!   count() reports the number of labelled branches.
//!
//! Out of scope: label-uniqueness enforcement (caller-policy),
//! interning (caller boundary), reverse-lookup by label (caller
//! composes a sibling map if needed).
//!
//! Lifetime contract: the caller-supplied label slice must
//! outlive the registry entry. Forget before the slice is
//! freed.

const std = @import("std");
const branch = @import("branch.zig");

pub const BranchId = branch.BranchId;

pub const Error = error{
    OutOfMemory,
};

pub const BranchLabelRegistry = struct {
    allocator: std.mem.Allocator,
    by_branch: std.AutoHashMap(BranchId, []const u8),

    pub fn init(allocator: std.mem.Allocator) BranchLabelRegistry {
        return .{
            .allocator = allocator,
            .by_branch = std.AutoHashMap(BranchId, []const u8).init(allocator),
        };
    }

    pub fn deinit(self: *BranchLabelRegistry) void {
        self.by_branch.deinit();
    }

    pub fn set(self: *BranchLabelRegistry, branch_id: BranchId, label: []const u8) Error!void {
        self.by_branch.put(branch_id, label) catch return Error.OutOfMemory;
    }

    pub fn get(self: BranchLabelRegistry, branch_id: BranchId) ?[]const u8 {
        return self.by_branch.get(branch_id);
    }

    pub fn forget(self: *BranchLabelRegistry, branch_id: BranchId) bool {
        return self.by_branch.remove(branch_id);
    }

    pub fn count(self: BranchLabelRegistry) usize {
        return self.by_branch.count();
    }
};

// --- Tests -----------------------------------------------------------------

const testing = std.testing;

test "set then get round-trips the label" {
    var r: BranchLabelRegistry = .init(testing.allocator);
    defer r.deinit();
    try r.set(1, "main");
    try testing.expectEqualStrings("main", r.get(1).?);
}

test "get on unknown returns null" {
    var r: BranchLabelRegistry = .init(testing.allocator);
    defer r.deinit();
    try testing.expectEqual(@as(?[]const u8, null), r.get(99));
}

test "set overwrites existing label" {
    var r: BranchLabelRegistry = .init(testing.allocator);
    defer r.deinit();
    try r.set(1, "old");
    try r.set(1, "new");
    try testing.expectEqualStrings("new", r.get(1).?);
}

test "forget removes the entry" {
    var r: BranchLabelRegistry = .init(testing.allocator);
    defer r.deinit();
    try r.set(1, "main");
    try testing.expect(r.forget(1));
    try testing.expectEqual(@as(?[]const u8, null), r.get(1));
    try testing.expect(!r.forget(99));
}

test "count tracks labelled branches" {
    var r: BranchLabelRegistry = .init(testing.allocator);
    defer r.deinit();
    try testing.expectEqual(@as(usize, 0), r.count());
    try r.set(1, "main");
    try r.set(2, "dev");
    try r.set(3, "feature-x");
    try testing.expectEqual(@as(usize, 3), r.count());
    _ = r.forget(2);
    try testing.expectEqual(@as(usize, 2), r.count());
}

test "empty label string is allowed (caller-policy)" {
    var r: BranchLabelRegistry = .init(testing.allocator);
    defer r.deinit();
    try r.set(1, "");
    try testing.expectEqualStrings("", r.get(1).?);
}
