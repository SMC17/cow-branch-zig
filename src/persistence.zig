//! persistence — v0.0.2 snapshot/restore via tableformat-zig manifest.
//!
//! v0.0.1 ships in-memory BranchTree. v0.0.2 ships byte-level
//! snapshot/restore so branches survive process restart. The on-disk
//! representation is intentionally minimal and self-describing:
//!
//!   [u32 magic = 'CBR1']
//!   [u32 branch_count]
//!   For each branch:
//!     [u64 branch_id]
//!     [u64 parent_id_or_zero]   (0 sentinel for root)
//!     [u64 branch_point_lsn]
//!     [u64 last_lsn]
//!     [u32 name_len] [name bytes] [pad to 8]
//!     [u32 page_count]
//!     For each page:
//!       [u64 page_id]
//!       [u64 lsn]
//!       [u32 byte_len] [pad to 8]
//!       [byte_len bytes]
//!
//! v0.0.3 will wire this into tableformat-zig's manifest as a
//! first-class snapshot artifact; v0.0.2 ships the byte primitive.

const std = @import("std");
const branch = @import("branch.zig");

pub const BranchTree = branch.BranchTree;
pub const Branch = branch.Branch;
pub const BranchId = branch.BranchId;
pub const Lsn = branch.Lsn;
pub const PageId = branch.PageId;

pub const Error = error{
    OutOfMemory,
    Truncated,
    BadMagic,
    DuplicateBranch,
    OrphanBranch,
};

const magic: u32 = 0x43_42_52_31; // 'CBR1'

/// Serialise a BranchTree to bytes. Caller-owned buffer.
pub fn snapshot(tree: *BranchTree, allocator: std.mem.Allocator) Error![]u8 {
    var out: std.array_list.Managed(u8) = .init(allocator);
    errdefer out.deinit();

    appendU32(&out, magic) catch return Error.OutOfMemory;
    appendU32(&out, @intCast(tree.branches.count())) catch return Error.OutOfMemory;

    var it = tree.branches.iterator();
    while (it.next()) |kv| {
        const b = kv.value_ptr;
        appendU64(&out, b.branch_id) catch return Error.OutOfMemory;
        appendU64(&out, b.parent_id orelse 0) catch return Error.OutOfMemory;
        appendU64(&out, b.branch_point_lsn) catch return Error.OutOfMemory;
        appendU64(&out, b.last_lsn) catch return Error.OutOfMemory;
        appendU32(&out, @intCast(b.name.len)) catch return Error.OutOfMemory;
        out.appendSlice(b.name) catch return Error.OutOfMemory;
        padTo8(&out) catch return Error.OutOfMemory;
        appendU32(&out, @intCast(b.pages.count())) catch return Error.OutOfMemory;
        var pit = b.pages.iterator();
        while (pit.next()) |pkv| {
            appendU64(&out, pkv.key_ptr.*.page_id) catch return Error.OutOfMemory;
            appendU64(&out, pkv.key_ptr.*.lsn) catch return Error.OutOfMemory;
            const bytes = pkv.value_ptr.*;
            appendU32(&out, @intCast(bytes.len)) catch return Error.OutOfMemory;
            padTo8(&out) catch return Error.OutOfMemory;
            out.appendSlice(bytes) catch return Error.OutOfMemory;
            padTo8(&out) catch return Error.OutOfMemory;
        }
    }
    return out.toOwnedSlice() catch return Error.OutOfMemory;
}

/// Bundle returned by `restore`: the rebuilt BranchTree plus the
/// list of byte slices the persistence layer allocated to back the
/// branch pages. Caller is responsible for freeing both via
/// `RestoreResult.deinit`.
pub const RestoreResult = struct {
    tree: BranchTree,
    owned_page_bytes: std.array_list.Managed([]u8),

    pub fn deinit(self: *RestoreResult, allocator: std.mem.Allocator) void {
        for (self.owned_page_bytes.items) |b| allocator.free(b);
        self.owned_page_bytes.deinit();
        self.tree.deinit();
    }
};

/// Deserialise a BranchTree from bytes. Returns the rebuilt tree
/// together with the owned page byte allocations so callers can
/// free both deterministically.
pub fn restoreOwned(bytes: []const u8, allocator: std.mem.Allocator) Error!RestoreResult {
    if (bytes.len < 8) return Error.Truncated;
    var p: usize = 0;
    const got_magic = std.mem.readInt(u32, bytes[p..][0..4], .little);
    if (got_magic != magic) return Error.BadMagic;
    p += 4;
    const branch_count = std.mem.readInt(u32, bytes[p..][0..4], .little);
    p += 4;

    var tree: BranchTree = .init(allocator);
    errdefer tree.deinit();
    var owned: std.array_list.Managed([]u8) = .init(allocator);
    errdefer {
        for (owned.items) |b| allocator.free(b);
        owned.deinit();
    }

    var max_branch_id: BranchId = 0;
    var i: u32 = 0;
    while (i < branch_count) : (i += 1) {
        if (bytes.len < p + 8 + 8 + 8 + 8 + 4) return Error.Truncated;
        const bid = std.mem.readInt(u64, bytes[p..][0..8], .little);
        p += 8;
        const parent_raw = std.mem.readInt(u64, bytes[p..][0..8], .little);
        p += 8;
        const bp_lsn = std.mem.readInt(u64, bytes[p..][0..8], .little);
        p += 8;
        const last_lsn = std.mem.readInt(u64, bytes[p..][0..8], .little);
        p += 8;
        const name_len = std.mem.readInt(u32, bytes[p..][0..4], .little);
        p += 4;
        if (bytes.len < p + name_len) return Error.Truncated;
        const name_copy = allocator.dupe(u8, bytes[p .. p + name_len]) catch return Error.OutOfMemory;
        p += name_len;
        p = alignUp8(p);

        if (bytes.len < p + 4) return Error.Truncated;
        const page_count = std.mem.readInt(u32, bytes[p..][0..4], .little);
        p += 4;

        var b: Branch = .{
            .branch_id = bid,
            .name = name_copy,
            .parent_id = if (parent_raw == 0) null else parent_raw,
            .branch_point_lsn = bp_lsn,
            .last_lsn = last_lsn,
            .pages = .init(allocator),
        };
        errdefer b.deinit(allocator);

        var j: u32 = 0;
        while (j < page_count) : (j += 1) {
            if (bytes.len < p + 8 + 8 + 4) return Error.Truncated;
            const page_id = std.mem.readInt(u64, bytes[p..][0..8], .little);
            p += 8;
            const lsn = std.mem.readInt(u64, bytes[p..][0..8], .little);
            p += 8;
            const byte_len = std.mem.readInt(u32, bytes[p..][0..4], .little);
            p += 4;
            p = alignUp8(p);
            if (bytes.len < p + byte_len) return Error.Truncated;
            const page_copy = allocator.dupe(u8, bytes[p .. p + byte_len]) catch return Error.OutOfMemory;
            owned.append(page_copy) catch {
                allocator.free(page_copy);
                return Error.OutOfMemory;
            };
            p += byte_len;
            p = alignUp8(p);
            const key: Branch.PageKey = .{ .page_id = page_id, .lsn = lsn };
            b.pages.put(key, page_copy) catch return Error.OutOfMemory;
        }

        if (tree.branches.contains(bid)) return Error.DuplicateBranch;
        tree.branches.put(bid, b) catch return Error.OutOfMemory;
        if (bid > max_branch_id) max_branch_id = bid;
    }

    var bit = tree.branches.valueIterator();
    while (bit.next()) |bp| {
        if (bp.parent_id) |pid| if (!tree.branches.contains(pid)) return Error.OrphanBranch;
    }

    tree.next_branch_id = max_branch_id + 1;
    return .{ .tree = tree, .owned_page_bytes = owned };
}

/// Legacy API for v0.0.2 — returns the tree only, leaking page
/// byte allocations. Callers that want deterministic ownership
/// should use `restoreOwned` and call `RestoreResult.deinit`.
pub fn restore(bytes: []const u8, allocator: std.mem.Allocator) Error!BranchTree {
    if (bytes.len < 8) return Error.Truncated;
    var p: usize = 0;
    const got_magic = std.mem.readInt(u32, bytes[p..][0..4], .little);
    if (got_magic != magic) return Error.BadMagic;
    p += 4;
    const branch_count = std.mem.readInt(u32, bytes[p..][0..4], .little);
    p += 4;

    var tree: BranchTree = .init(allocator);
    errdefer tree.deinit();

    var max_branch_id: BranchId = 0;
    var i: u32 = 0;
    while (i < branch_count) : (i += 1) {
        if (bytes.len < p + 8 + 8 + 8 + 8 + 4) return Error.Truncated;
        const bid = std.mem.readInt(u64, bytes[p..][0..8], .little);
        p += 8;
        const parent_raw = std.mem.readInt(u64, bytes[p..][0..8], .little);
        p += 8;
        const bp_lsn = std.mem.readInt(u64, bytes[p..][0..8], .little);
        p += 8;
        const last_lsn = std.mem.readInt(u64, bytes[p..][0..8], .little);
        p += 8;
        const name_len = std.mem.readInt(u32, bytes[p..][0..4], .little);
        p += 4;
        if (bytes.len < p + name_len) return Error.Truncated;
        const name_copy = allocator.dupe(u8, bytes[p .. p + name_len]) catch return Error.OutOfMemory;
        p += name_len;
        p = alignUp8(p);

        if (bytes.len < p + 4) return Error.Truncated;
        const page_count = std.mem.readInt(u32, bytes[p..][0..4], .little);
        p += 4;

        var b: Branch = .{
            .branch_id = bid,
            .name = name_copy,
            .parent_id = if (parent_raw == 0) null else parent_raw,
            .branch_point_lsn = bp_lsn,
            .last_lsn = last_lsn,
            .pages = .init(allocator),
        };
        errdefer b.deinit(allocator);

        var j: u32 = 0;
        while (j < page_count) : (j += 1) {
            if (bytes.len < p + 8 + 8 + 4) return Error.Truncated;
            const page_id = std.mem.readInt(u64, bytes[p..][0..8], .little);
            p += 8;
            const lsn = std.mem.readInt(u64, bytes[p..][0..8], .little);
            p += 8;
            const byte_len = std.mem.readInt(u32, bytes[p..][0..4], .little);
            p += 4;
            p = alignUp8(p);
            if (bytes.len < p + byte_len) return Error.Truncated;
            const page_copy = allocator.dupe(u8, bytes[p .. p + byte_len]) catch return Error.OutOfMemory;
            p += byte_len;
            p = alignUp8(p);
            const key: Branch.PageKey = .{ .page_id = page_id, .lsn = lsn };
            b.pages.put(key, page_copy) catch return Error.OutOfMemory;
        }

        if (tree.branches.contains(bid)) return Error.DuplicateBranch;
        tree.branches.put(bid, b) catch return Error.OutOfMemory;
        if (bid > max_branch_id) max_branch_id = bid;
    }

    // Verify orphans: every non-null parent_id must point to a known branch.
    var bit = tree.branches.valueIterator();
    while (bit.next()) |bp| {
        if (bp.parent_id) |pid| if (!tree.branches.contains(pid)) return Error.OrphanBranch;
    }

    tree.next_branch_id = max_branch_id + 1;
    return tree;
}

// --- helpers --------------------------------------------------------------

fn appendU32(out: *std.array_list.Managed(u8), v: u32) !void {
    var b: [4]u8 = undefined;
    std.mem.writeInt(u32, &b, v, .little);
    try out.appendSlice(&b);
}
fn appendU64(out: *std.array_list.Managed(u8), v: u64) !void {
    var b: [8]u8 = undefined;
    std.mem.writeInt(u64, &b, v, .little);
    try out.appendSlice(&b);
}
fn padTo8(out: *std.array_list.Managed(u8)) !void {
    while (out.items.len % 8 != 0) try out.append(0);
}
fn alignUp8(v: usize) usize {
    return (v + 7) & ~@as(usize, 7);
}

// --- Tests ----------------------------------------------------------------

const testing = std.testing;

test "snapshot empty tree starts with CBR1 magic + zero count" {
    const alloc = testing.allocator;
    var tree: BranchTree = .init(alloc);
    defer tree.deinit();
    const bytes = try snapshot(&tree, alloc);
    defer alloc.free(bytes);
    try testing.expect(bytes.len >= 8);
    const got_magic = std.mem.readInt(u32, bytes[0..4], .little);
    try testing.expectEqual(magic, got_magic);
    const count = std.mem.readInt(u32, bytes[4..8], .little);
    try testing.expectEqual(@as(u32, 0), count);
}

test "snapshot + restore round-trips a root + child branch" {
    const alloc = testing.allocator;
    var tree: BranchTree = .init(alloc);
    defer tree.deinit();
    const root = try tree.createRoot("main");
    try tree.writePage(root, 7, 1, "hello");
    try tree.writePage(root, 8, 2, "world");
    const child = try tree.fork(root, "dev");
    try tree.writePage(child, 7, 3, "branch-page");

    const bytes = try snapshot(&tree, alloc);
    defer alloc.free(bytes);

    var restored = try restoreOwned(bytes, alloc);
    defer restored.deinit(alloc);

    try testing.expectEqual(@as(usize, 2), restored.tree.branches.count());
    // Restored child reads its own page at lsn 3.
    const p7_at_3 = try restored.tree.readPage(child, 7, 3);
    try testing.expect(p7_at_3 != null);
    try testing.expectEqualSlices(u8, "branch-page", p7_at_3.?);
    // Restored child reads page 8 by parent fallback (only exists in root).
    const p8 = try restored.tree.readPage(child, 8, 3);
    try testing.expect(p8 != null);
    try testing.expectEqualSlices(u8, "world", p8.?);
}

test "restore rejects bad magic" {
    const alloc = testing.allocator;
    const bad_bytes = [_]u8{ 0, 0, 0, 0, 0, 0, 0, 0 };
    try testing.expectError(Error.BadMagic, restore(&bad_bytes, alloc));
}

test "restore rejects truncated bytes" {
    const alloc = testing.allocator;
    const short = [_]u8{ 1, 2, 3 };
    try testing.expectError(Error.Truncated, restore(&short, alloc));
}

test "snapshot preserves branch_point_lsn for time-travel reads after restore" {
    const alloc = testing.allocator;
    var tree: BranchTree = .init(alloc);
    defer tree.deinit();
    const root = try tree.createRoot("main");
    try tree.writePage(root, 1, 10, "v10");
    try tree.writePage(root, 1, 20, "v20");
    const child = try tree.fork(root, "dev"); // forks at lsn 20

    const bytes = try snapshot(&tree, alloc);
    defer alloc.free(bytes);
    var restored = try restoreOwned(bytes, alloc);
    defer restored.deinit(alloc);

    // Child reads page 1 at lsn 15 — falls through to parent, clamped
    // to branch_point_lsn=20, so it should see "v10" (the latest
    // ≤ lsn 15).
    const got = try restored.tree.readPage(child, 1, 15);
    try testing.expect(got != null);
    try testing.expectEqualSlices(u8, "v10", got.?);
}

test "snapshot+restore preserves next_branch_id so subsequent fork is unique" {
    const alloc = testing.allocator;
    var tree: BranchTree = .init(alloc);
    defer tree.deinit();
    const root = try tree.createRoot("main");
    const c1 = try tree.fork(root, "c1");
    _ = c1;

    const bytes = try snapshot(&tree, alloc);
    defer alloc.free(bytes);
    var restored = try restoreOwned(bytes, alloc);
    defer restored.deinit(alloc);

    const c2 = try restored.tree.fork(root, "c2");
    // c2 must be > c1 because next_branch_id was preserved.
    try testing.expect(c2 > root);
}

test "restore rejects orphan parent_id" {
    const alloc = testing.allocator;
    // Hand-craft snapshot bytes with one branch whose parent_id
    // references an unknown branch.
    var bytes: std.array_list.Managed(u8) = .init(alloc);
    defer bytes.deinit();
    try appendU32(&bytes, magic);
    try appendU32(&bytes, 1); // branch_count
    try appendU64(&bytes, 100); // branch_id
    try appendU64(&bytes, 999); // parent_id (orphan)
    try appendU64(&bytes, 0); // branch_point_lsn
    try appendU64(&bytes, 0); // last_lsn
    try appendU32(&bytes, 0); // name_len = 0
    try padTo8(&bytes);
    try appendU32(&bytes, 0); // page_count = 0
    try testing.expectError(Error.OrphanBranch, restore(bytes.items, alloc));
}
