//! branch_age: v0.0.8 small primitive — per-branch age in ns.
//!
//! cow-branch already tracks BranchId and Lsn, but not wall-clock
//! creation time. Production deploys want to know "how old is
//! this branch" for prune scheduling, fork detection (a branch
//! created 30 days ago that hasn't been merged), and SLA gauges
//! (how long has dev-branch-X been alive vs the 7-day window).
//!
//! Port a minimal per-branch creation-ns registry. Caller owns
//! the clock; the substrate just maps BranchId -> creation_ns
//! and exposes ageNs(branch_id, now_ns).
//!
//! Scope of this revision:
//!   BranchAgeRegistry { allocator, by_branch: BranchId ->
//!     creation_ns }.
//!   record(branch_id, creation_ns) registers a branch's birth.
//!   ageNs(branch_id, now_ns) returns now - creation; null if
//!     unknown.
//!   countOlderThan(threshold_ns, now_ns) counts how many
//!     registered branches exceed the threshold age. Useful for
//!     prune-decision dashboards.
//!
//! Out of scope: branch-deletion bookkeeping (caller calls
//! deinit), branch-rename tracking, age-based eviction (compose
//! with wflog retention_tiers at the caller boundary).

const std = @import("std");
const branch = @import("branch.zig");

pub const BranchId = branch.BranchId;

pub const Error = error{
    OutOfMemory,
    DuplicateBranch,
};

pub const BranchAgeRegistry = struct {
    allocator: std.mem.Allocator,
    by_branch: std.AutoHashMap(BranchId, i64),

    pub fn init(allocator: std.mem.Allocator) BranchAgeRegistry {
        return .{
            .allocator = allocator,
            .by_branch = std.AutoHashMap(BranchId, i64).init(allocator),
        };
    }

    pub fn deinit(self: *BranchAgeRegistry) void {
        self.by_branch.deinit();
    }

    pub fn record(self: *BranchAgeRegistry, branch_id: BranchId, creation_ns: i64) Error!void {
        if (self.by_branch.contains(branch_id)) return Error.DuplicateBranch;
        self.by_branch.put(branch_id, creation_ns) catch return Error.OutOfMemory;
    }

    pub fn ageNs(self: BranchAgeRegistry, branch_id: BranchId, now_ns: i64) ?i64 {
        const c = self.by_branch.get(branch_id) orelse return null;
        return now_ns - c;
    }

    pub fn countOlderThan(self: BranchAgeRegistry, threshold_ns: i64, now_ns: i64) usize {
        var n: usize = 0;
        var it = self.by_branch.valueIterator();
        while (it.next()) |c| {
            if ((now_ns - c.*) > threshold_ns) n += 1;
        }
        return n;
    }

    pub fn count(self: BranchAgeRegistry) usize {
        return self.by_branch.count();
    }

    pub fn forget(self: *BranchAgeRegistry, branch_id: BranchId) bool {
        return self.by_branch.remove(branch_id);
    }
};

// --- Tests -----------------------------------------------------------------

const testing = std.testing;

test "record then ageNs returns the elapsed delta" {
    var r: BranchAgeRegistry = .init(testing.allocator);
    defer r.deinit();
    try r.record(1, 1_000_000_000);
    try testing.expectEqual(@as(?i64, 500_000_000), r.ageNs(1, 1_500_000_000));
}

test "ageNs on unknown branch returns null" {
    var r: BranchAgeRegistry = .init(testing.allocator);
    defer r.deinit();
    try testing.expectEqual(@as(?i64, null), r.ageNs(99, 0));
}

test "record refuses duplicate" {
    var r: BranchAgeRegistry = .init(testing.allocator);
    defer r.deinit();
    try r.record(1, 100);
    try testing.expectError(Error.DuplicateBranch, r.record(1, 200));
}

test "countOlderThan tallies branches beyond the threshold" {
    var r: BranchAgeRegistry = .init(testing.allocator);
    defer r.deinit();
    const now: i64 = 10_000_000_000;
    try r.record(1, now - 2_000_000_000);
    try r.record(2, now - 8_000_000_000);
    try r.record(3, now - 500_000_000);
    try testing.expectEqual(@as(usize, 2), r.countOlderThan(1_000_000_000, now));
    try testing.expectEqual(@as(usize, 1), r.countOlderThan(5_000_000_000, now));
    try testing.expectEqual(@as(usize, 0), r.countOlderThan(10_000_000_000, now));
}

test "forget removes a branch from the registry" {
    var r: BranchAgeRegistry = .init(testing.allocator);
    defer r.deinit();
    try r.record(1, 100);
    try testing.expect(r.forget(1));
    try testing.expectEqual(@as(?i64, null), r.ageNs(1, 1000));
    try testing.expect(!r.forget(99));
}

test "count tracks registered branches" {
    var r: BranchAgeRegistry = .init(testing.allocator);
    defer r.deinit();
    try testing.expectEqual(@as(usize, 0), r.count());
    try r.record(1, 1);
    try r.record(2, 2);
    try testing.expectEqual(@as(usize, 2), r.count());
}

test "negative age (clock skew) is preserved (caller-policy)" {
    var r: BranchAgeRegistry = .init(testing.allocator);
    defer r.deinit();
    try r.record(1, 1000);
    try testing.expectEqual(@as(?i64, -500), r.ageNs(1, 500));
}
