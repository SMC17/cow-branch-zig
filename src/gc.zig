//! gc — v0.0.5 branch garbage collector.
//!
//! Long-running trees accumulate unreachable branches: forks that
//! were never used, intermediate branches whose children have been
//! abandoned, or transient branches from bandit experiments. v0.0.5
//! ships a mark-and-sweep GC primitive:
//!
//! 1. Caller passes the active leaf branches (workload-relevant tips).
//! 2. `markReachable` walks each leaf's ancestor chain marking every
//!    visited branch.
//! 3. `sweepUnreachable` returns the set of branches NOT in the
//!    reachable set — the caller decides whether to delete them
//!    (separation of mark/sweep from actual destruction).

const std = @import("std");
const branch_mod = @import("branch.zig");

pub const BranchTree = branch_mod.BranchTree;
pub const BranchId = branch_mod.BranchId;

pub const Error = error{ OutOfMemory };

/// Walk every active leaf's ancestor chain. Returns the SET of
/// reachable branch IDs (caller-owned hash set).
pub fn markReachable(
    tree: *BranchTree,
    leaves: []const BranchId,
    allocator: std.mem.Allocator,
) Error!std.AutoHashMap(BranchId, void) {
    var reachable: std.AutoHashMap(BranchId, void) = .init(allocator);
    errdefer reachable.deinit();
    for (leaves) |leaf| {
        var cur: ?BranchId = leaf;
        while (cur) |bid| {
            if (reachable.contains(bid)) break; // already walked
            reachable.put(bid, {}) catch return Error.OutOfMemory;
            const b = tree.branches.getPtr(bid) orelse break;
            cur = b.parent_id;
        }
    }
    return reachable;
}

/// Return branches NOT in `reachable`. Caller owns + frees.
pub fn sweepUnreachable(
    tree: *BranchTree,
    reachable: *std.AutoHashMap(BranchId, void),
    allocator: std.mem.Allocator,
) Error![]BranchId {
    var out = std.array_list.Managed(BranchId).init(allocator);
    errdefer out.deinit();
    var it = tree.branches.iterator();
    while (it.next()) |kv| {
        if (!reachable.contains(kv.key_ptr.*)) {
            out.append(kv.key_ptr.*) catch return Error.OutOfMemory;
        }
    }
    return out.toOwnedSlice() catch return Error.OutOfMemory;
}

/// One-shot: mark from leaves + sweep + return unreachable list.
pub fn collectUnreachable(
    tree: *BranchTree,
    leaves: []const BranchId,
    allocator: std.mem.Allocator,
) Error![]BranchId {
    var reachable = try markReachable(tree, leaves, allocator);
    defer reachable.deinit();
    return sweepUnreachable(tree, &reachable, allocator);
}

// --- Tests ----------------------------------------------------------------

const testing = std.testing;

test "markReachable walks ancestor chain" {
    const alloc = testing.allocator;
    var tree: BranchTree = .init(alloc);
    defer tree.deinit();
    const root = try tree.createRoot("main");
    const c1 = try tree.fork(root, "c1");
    const c2 = try tree.fork(c1, "c2");
    // Mark only c2 — root + c1 + c2 should be reachable.
    var reachable = try markReachable(&tree, &[_]BranchId{c2}, alloc);
    defer reachable.deinit();
    try testing.expect(reachable.contains(root));
    try testing.expect(reachable.contains(c1));
    try testing.expect(reachable.contains(c2));
}

test "sweepUnreachable finds branches not reachable from any leaf" {
    const alloc = testing.allocator;
    var tree: BranchTree = .init(alloc);
    defer tree.deinit();
    const root = try tree.createRoot("main");
    const c1 = try tree.fork(root, "c1");
    _ = try tree.fork(root, "c2");
    const c3 = try tree.fork(root, "c3");

    // Active leaves: only c1, c3.
    const unreachable_branches = try collectUnreachable(&tree, &[_]BranchId{ c1, c3 }, alloc);
    defer alloc.free(unreachable_branches);
    try testing.expectEqual(@as(usize, 1), unreachable_branches.len);
}

test "markReachable preserves shared ancestor across leaves" {
    const alloc = testing.allocator;
    var tree: BranchTree = .init(alloc);
    defer tree.deinit();
    const root = try tree.createRoot("main");
    const c1 = try tree.fork(root, "c1");
    const c2 = try tree.fork(root, "c2");
    const gc1 = try tree.fork(c1, "gc1");
    const gc2 = try tree.fork(c2, "gc2");
    var reachable = try markReachable(&tree, &[_]BranchId{ gc1, gc2 }, alloc);
    defer reachable.deinit();
    // Every branch should be reachable.
    try testing.expect(reachable.contains(root));
    try testing.expect(reachable.contains(c1));
    try testing.expect(reachable.contains(c2));
    try testing.expect(reachable.contains(gc1));
    try testing.expect(reachable.contains(gc2));
}

test "empty leaves yields empty reachable set" {
    const alloc = testing.allocator;
    var tree: BranchTree = .init(alloc);
    defer tree.deinit();
    _ = try tree.createRoot("main");
    var reachable = try markReachable(&tree, &[_]BranchId{}, alloc);
    defer reachable.deinit();
    try testing.expectEqual(@as(usize, 0), reachable.count());
}

test "collectUnreachable on empty tree returns empty slice" {
    const alloc = testing.allocator;
    var tree: BranchTree = .init(alloc);
    defer tree.deinit();
    const out = try collectUnreachable(&tree, &[_]BranchId{}, alloc);
    defer alloc.free(out);
    try testing.expectEqual(@as(usize, 0), out.len);
}

test "collectUnreachable with all-branches-as-leaves returns empty" {
    const alloc = testing.allocator;
    var tree: BranchTree = .init(alloc);
    defer tree.deinit();
    const root = try tree.createRoot("main");
    const c1 = try tree.fork(root, "c1");
    const c2 = try tree.fork(root, "c2");
    const out = try collectUnreachable(&tree, &[_]BranchId{ root, c1, c2 }, alloc);
    defer alloc.free(out);
    try testing.expectEqual(@as(usize, 0), out.len);
}
