//! cow-branch — copy-on-write branching substrate.
//!
//! Three-source synthesis: Neon L324 (Pageserver copy-on-write
//! branching) + tableformat-zig L6 (zero-copy partition evolution) +
//! PlanetScale L165 (database branching deploy-request workflow).
//!
//! The seed: a branch is metadata pointing at a parent. Pages
//! materialise into the branch only when the branch writes them.
//! Reads on unmodified pages fall through to the parent via timeline
//! pointer. Forking is O(1). Each branch maintains its own LSN
//! cursor so historical reads at any LSN reconstruct the page set
//! visible at that point.
//!
//! v0.0.1 ships the data shapes + branch-create + page lookup with
//! parent fallback + LSN-bounded reads. v0.0.2 ships the WAL replay
//! pipeline (Neon L322 page-materialisation-from-WAL) + commit-or-
//! retry transaction. v0.0.3 ships the cleanup quota + TTL (Supabase
//! L249 deploy pipeline).

const std = @import("std");

/// Branch identifier. Stable across the branch's lifetime.
pub const BranchId = u64;

/// Log sequence number. Monotonic per-branch; sortable across the
/// whole branch tree because each child's LSN-zero is at the parent's
/// `branch_point_lsn`.
pub const Lsn = u64;

/// One physical-page address. Caller-defined semantics: could be
/// (file_id, page_offset), tenant + table + row-group, etc. The
/// branching substrate is page-id agnostic.
pub const PageId = u64;

/// One materialised page in a branch's local store. Bytes are
/// borrowed; the substrate doesn't copy them. Caller manages the
/// underlying allocator + lifetime.
pub const Page = struct {
    page_id: PageId,
    /// LSN at which this materialised page became visible. Reads at
    /// `read_at <  lsn` fall through to the parent.
    lsn: Lsn,
    /// Page bytes — caller-owned.
    bytes: []const u8,
};

pub const Error = error{
    BranchNotFound,
    ParentNotFound,
    InvalidBranchPoint,
    LsnPredecessorViolation,
    OutOfMemory,
};

/// A single branch. Holds:
/// - identity (branch_id, name, parent_id, branch_point_lsn)
/// - the local page table for pages this branch has materialised
/// - the branch's own write cursor (`last_lsn`)
pub const Branch = struct {
    branch_id: BranchId,
    name: []const u8,
    parent_id: ?BranchId,
    /// LSN of the parent at which this branch forked. Bytes-equal
    /// reads at `branch_point_lsn` against parent + child must
    /// return identical pages (the zero-copy property).
    branch_point_lsn: Lsn,
    last_lsn: Lsn,
    /// `(page_id × lsn) → bytes` for pages materialised in this
    /// branch. A branch only stores pages it has written; reads of
    /// unmodified pages fall through to parent.
    pages: std.AutoHashMap(PageKey, []const u8),

    pub const PageKey = struct {
        page_id: PageId,
        lsn: Lsn,
    };

    pub fn deinit(self: *Branch, allocator: std.mem.Allocator) void {
        self.pages.deinit();
        allocator.free(self.name);
    }
};

/// The branch tree — every branch known to the system, addressable
/// by ID. The substrate enforces:
/// - One root branch (`parent_id == null`).
/// - Every child's `branch_point_lsn <= parent.last_lsn` at the
///   moment of fork.
/// - Page reads always honour the LSN cap.
pub const BranchTree = struct {
    allocator: std.mem.Allocator,
    branches: std.AutoHashMap(BranchId, Branch),
    next_branch_id: BranchId,

    pub fn init(allocator: std.mem.Allocator) BranchTree {
        return .{
            .allocator = allocator,
            .branches = .init(allocator),
            .next_branch_id = 1,
        };
    }

    pub fn deinit(self: *BranchTree) void {
        var it = self.branches.valueIterator();
        while (it.next()) |b| b.deinit(self.allocator);
        self.branches.deinit();
    }

    /// Create the root branch. Must be called exactly once before any
    /// child branch is forked.
    pub fn createRoot(self: *BranchTree, name: []const u8) !BranchId {
        const id = self.next_branch_id;
        self.next_branch_id += 1;
        const name_copy = try self.allocator.dupe(u8, name);
        const root_branch: Branch = .{
            .branch_id = id,
            .name = name_copy,
            .parent_id = null,
            .branch_point_lsn = 0,
            .last_lsn = 0,
            .pages = .init(self.allocator),
        };
        try self.branches.put(id, root_branch);
        return id;
    }

    /// Fork a child from `parent_id` at the parent's current
    /// `last_lsn`. Returns the new branch's ID. **O(1)** — no
    /// page-table copy.
    pub fn fork(
        self: *BranchTree,
        parent_id: BranchId,
        name: []const u8,
    ) Error!BranchId {
        const parent = self.branches.getPtr(parent_id) orelse return Error.ParentNotFound;
        const id = self.next_branch_id;
        self.next_branch_id += 1;
        const name_copy = self.allocator.dupe(u8, name) catch return Error.OutOfMemory;
        const child: Branch = .{
            .branch_id = id,
            .name = name_copy,
            .parent_id = parent_id,
            .branch_point_lsn = parent.last_lsn,
            .last_lsn = parent.last_lsn,
            .pages = .init(self.allocator),
        };
        self.branches.put(id, child) catch return Error.OutOfMemory;
        return id;
    }

    /// Materialise a page write in the given branch. Bumps the
    /// branch's `last_lsn` to `lsn`. Caller's `bytes` slice is
    /// borrowed — the substrate does not copy. `lsn` must be strictly
    /// greater than the branch's current `last_lsn`.
    pub fn writePage(
        self: *BranchTree,
        branch_id: BranchId,
        page_id: PageId,
        lsn: Lsn,
        bytes: []const u8,
    ) Error!void {
        const b = self.branches.getPtr(branch_id) orelse return Error.BranchNotFound;
        if (lsn <= b.last_lsn) return Error.LsnPredecessorViolation;
        const key: Branch.PageKey = .{ .page_id = page_id, .lsn = lsn };
        b.pages.put(key, bytes) catch return Error.OutOfMemory;
        b.last_lsn = lsn;
    }

    /// Read a page at `read_at` LSN from `branch_id`. Walk the local
    /// branch first; if no version with `lsn <= read_at` exists in
    /// the branch, recurse into the parent (clamping `read_at` to
    /// the branch's `branch_point_lsn`).
    pub fn readPage(
        self: *BranchTree,
        branch_id: BranchId,
        page_id: PageId,
        read_at: Lsn,
    ) Error!?[]const u8 {
        const b = self.branches.getPtr(branch_id) orelse return Error.BranchNotFound;

        // Search this branch for the latest version of `page_id` at
        // or before `read_at`.
        var best_lsn: ?Lsn = null;
        var best_bytes: ?[]const u8 = null;
        var it = b.pages.iterator();
        while (it.next()) |kv| {
            const k = kv.key_ptr.*;
            if (k.page_id != page_id) continue;
            if (k.lsn > read_at) continue;
            if (best_lsn == null or k.lsn > best_lsn.?) {
                best_lsn = k.lsn;
                best_bytes = kv.value_ptr.*;
            }
        }
        if (best_lsn != null) return best_bytes.?;

        // Fall through to parent. The clamping rule: a child can
        // only see parent pages whose LSN is ≤ the branch_point_lsn.
        const parent_id = b.parent_id orelse return null;
        const clamped_read_at = @min(read_at, b.branch_point_lsn);
        return self.readPage(parent_id, page_id, clamped_read_at);
    }

    pub fn branch(self: *BranchTree, branch_id: BranchId) ?*Branch {
        return self.branches.getPtr(branch_id);
    }

    pub fn branchCount(self: BranchTree) usize {
        return self.branches.count();
    }
};

// --- Tests ---------------------------------------------------------------

const testing = std.testing;

test "createRoot installs a single root branch" {
    var tree: BranchTree = .init(testing.allocator);
    defer tree.deinit();
    const root = try tree.createRoot("main");
    try testing.expectEqual(@as(usize, 1), tree.branchCount());
    const b = tree.branch(root).?;
    try testing.expect(b.parent_id == null);
    try testing.expectEqualStrings("main", b.name);
    try testing.expectEqual(@as(Lsn, 0), b.last_lsn);
}

test "writePage bumps last_lsn and stores the bytes" {
    var tree: BranchTree = .init(testing.allocator);
    defer tree.deinit();
    const root = try tree.createRoot("main");
    try tree.writePage(root, 100, 10, "hello");
    const b = tree.branch(root).?;
    try testing.expectEqual(@as(Lsn, 10), b.last_lsn);
    const read = (try tree.readPage(root, 100, 20)).?;
    try testing.expectEqualStrings("hello", read);
}

test "writePage rejects non-monotonic LSN" {
    var tree: BranchTree = .init(testing.allocator);
    defer tree.deinit();
    const root = try tree.createRoot("main");
    try tree.writePage(root, 1, 5, "a");
    try testing.expectError(Error.LsnPredecessorViolation, tree.writePage(root, 1, 5, "b"));
    try testing.expectError(Error.LsnPredecessorViolation, tree.writePage(root, 1, 4, "c"));
}

test "fork is O(1) — no page-table copy" {
    var tree: BranchTree = .init(testing.allocator);
    defer tree.deinit();
    const root = try tree.createRoot("main");
    try tree.writePage(root, 1, 5, "v1");
    try tree.writePage(root, 1, 10, "v2");
    try tree.writePage(root, 2, 15, "p2");

    const dev = try tree.fork(root, "dev");
    const dev_branch = tree.branch(dev).?;

    // The dev branch starts with EMPTY local pages.
    try testing.expectEqual(@as(usize, 0), dev_branch.pages.count());
    try testing.expectEqual(@as(Lsn, 15), dev_branch.branch_point_lsn);
    try testing.expectEqual(@as(Lsn, 15), dev_branch.last_lsn);

    // But reads on dev see parent pages without copying.
    const p1 = (try tree.readPage(dev, 1, 100)).?;
    try testing.expectEqualStrings("v2", p1); // latest at branch_point_lsn=15
    const p2 = (try tree.readPage(dev, 2, 100)).?;
    try testing.expectEqualStrings("p2", p2);
}

test "child write does NOT affect parent — copy-on-write isolation" {
    var tree: BranchTree = .init(testing.allocator);
    defer tree.deinit();
    const root = try tree.createRoot("main");
    try tree.writePage(root, 1, 5, "main-v1");

    const dev = try tree.fork(root, "dev");
    try tree.writePage(dev, 1, 20, "dev-modified");

    // Parent still sees its own version.
    const main_read = (try tree.readPage(root, 1, 30)).?;
    try testing.expectEqualStrings("main-v1", main_read);
    // Child sees its own write.
    const dev_read = (try tree.readPage(dev, 1, 30)).?;
    try testing.expectEqualStrings("dev-modified", dev_read);
}

test "child read at historical LSN before branch point honours parent state" {
    var tree: BranchTree = .init(testing.allocator);
    defer tree.deinit();
    const root = try tree.createRoot("main");
    try tree.writePage(root, 1, 5, "early"); // LSN 5
    try tree.writePage(root, 1, 15, "late"); // LSN 15
    const dev = try tree.fork(root, "dev"); // branch_point_lsn = 15

    // Read on dev at LSN 10 should see the parent's page at LSN 5
    // (the latest version ≤ min(read_at=10, branch_point=15) = 10).
    const r10 = (try tree.readPage(dev, 1, 10)).?;
    try testing.expectEqualStrings("early", r10);

    // Read on dev at LSN 100 should see the parent's page at LSN 15
    // (clamped to branch_point_lsn).
    const r100 = (try tree.readPage(dev, 1, 100)).?;
    try testing.expectEqualStrings("late", r100);
}

test "missing pages return null without error" {
    var tree: BranchTree = .init(testing.allocator);
    defer tree.deinit();
    const root = try tree.createRoot("main");
    try testing.expect((try tree.readPage(root, 999, 100)) == null);
}

test "fork rejects unknown parent" {
    var tree: BranchTree = .init(testing.allocator);
    defer tree.deinit();
    try testing.expectError(Error.ParentNotFound, tree.fork(999, "ghost"));
}

test "multi-level branching — grandchild walks up two parents" {
    var tree: BranchTree = .init(testing.allocator);
    defer tree.deinit();
    const root = try tree.createRoot("main");
    try tree.writePage(root, 1, 10, "root-v1");

    const dev = try tree.fork(root, "dev");
    try tree.writePage(dev, 2, 20, "dev-only");

    const feature = try tree.fork(dev, "feature");

    // feature reads page 1 → not in feature → fall to dev (branch
    // point 20) → not in dev → fall to root (clamped to 20) → root
    // has "root-v1" at LSN 10.
    const p1 = (try tree.readPage(feature, 1, 100)).?;
    try testing.expectEqualStrings("root-v1", p1);

    // feature reads page 2 → not in feature → fall to dev (clamped
    // to 20) → dev has "dev-only" at LSN 20.
    const p2 = (try tree.readPage(feature, 2, 100)).?;
    try testing.expectEqualStrings("dev-only", p2);
}

test "branchCount tracks created + forked branches" {
    var tree: BranchTree = .init(testing.allocator);
    defer tree.deinit();
    const root = try tree.createRoot("main");
    _ = try tree.fork(root, "dev");
    _ = try tree.fork(root, "staging");
    try testing.expectEqual(@as(usize, 3), tree.branchCount());
}
