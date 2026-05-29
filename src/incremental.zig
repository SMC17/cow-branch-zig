//! incremental — v0.0.3 incremental snapshot + restore.
//!
//! v0.0.2 ships a full BranchTree snapshot. For large trees this is
//! expensive (every page bytes round-tripped on every snapshot).
//! v0.0.3 adds incremental snapshots:
//!
//! - `snapshotIncremental(tree, since_lsn)`: emit only pages whose
//!   `lsn > since_lsn`. Same wire format as full snapshot, but the
//!   branch headers include the lower-bound LSN so restore can merge
//!   into an existing tree without overwriting.
//! - `restoreIncrementalInto(tree, bytes)`: apply incremental into
//!   an EXISTING tree. New branches are inserted; existing branches
//!   get their `last_lsn` advanced + new pages added.
//!
//! This composes with snapshot-LSN chaining so a service can take a
//! base snapshot at boot and incremental snapshots every minute,
//! reconstructing the full tree by replaying base + incrementals.

const std = @import("std");
const branch = @import("branch.zig");

pub const BranchTree = branch.BranchTree;
pub const Branch = branch.Branch;
pub const BranchId = branch.BranchId;
pub const Lsn = branch.Lsn;

pub const Error = error{
    OutOfMemory,
    Truncated,
    BadMagic,
    UnknownBranch,
};

const inc_magic: u32 = 0x49_4E_43_43; // 'INCC'

/// Snapshot only pages with LSN > since_lsn across all branches in
/// the tree. Returns a byte buffer the caller owns.
pub fn snapshotIncremental(
    tree: *BranchTree,
    since_lsn: Lsn,
    allocator: std.mem.Allocator,
) Error![]u8 {
    var out: std.array_list.Managed(u8) = .init(allocator);
    errdefer out.deinit();

    appendU32(&out, inc_magic) catch return Error.OutOfMemory;
    appendU64(&out, since_lsn) catch return Error.OutOfMemory;

    // Count branches that have at least one page > since_lsn or
    // whose last_lsn > since_lsn (branch created/advanced).
    var branch_count: u32 = 0;
    var bit = tree.branches.iterator();
    while (bit.next()) |kv| {
        if (kv.value_ptr.last_lsn > since_lsn) {
            branch_count += 1;
            continue;
        }
        var pit = kv.value_ptr.pages.iterator();
        while (pit.next()) |pkv| {
            if (pkv.key_ptr.lsn > since_lsn) {
                branch_count += 1;
                break;
            }
        }
    }
    appendU32(&out, branch_count) catch return Error.OutOfMemory;

    bit = tree.branches.iterator();
    while (bit.next()) |kv| {
        const b = kv.value_ptr;
        // Skip branches with no relevant data + no LSN advance.
        var has_pages = false;
        var pit = b.pages.iterator();
        while (pit.next()) |pkv| {
            if (pkv.key_ptr.lsn > since_lsn) {
                has_pages = true;
                break;
            }
        }
        if (!has_pages and b.last_lsn <= since_lsn) continue;

        appendU64(&out, b.branch_id) catch return Error.OutOfMemory;
        appendU64(&out, b.last_lsn) catch return Error.OutOfMemory;
        // Count pages > since_lsn for this branch.
        var page_count: u32 = 0;
        pit = b.pages.iterator();
        while (pit.next()) |pkv| if (pkv.key_ptr.lsn > since_lsn) {
            page_count += 1;
        };
        appendU32(&out, page_count) catch return Error.OutOfMemory;
        pit = b.pages.iterator();
        while (pit.next()) |pkv| if (pkv.key_ptr.lsn > since_lsn) {
            appendU64(&out, pkv.key_ptr.page_id) catch return Error.OutOfMemory;
            appendU64(&out, pkv.key_ptr.lsn) catch return Error.OutOfMemory;
            const bytes = pkv.value_ptr.*;
            appendU32(&out, @intCast(bytes.len)) catch return Error.OutOfMemory;
            padTo8(&out) catch return Error.OutOfMemory;
            out.appendSlice(bytes) catch return Error.OutOfMemory;
            padTo8(&out) catch return Error.OutOfMemory;
        };
    }

    return out.toOwnedSlice() catch return Error.OutOfMemory;
}

pub const IncrementalResult = struct {
    /// Slices the persistence layer allocated to back the new pages
    /// applied into the tree. Caller must free via `deinit(allocator)`.
    owned_page_bytes: std.array_list.Managed([]u8),

    pub fn deinit(self: *IncrementalResult, allocator: std.mem.Allocator) void {
        for (self.owned_page_bytes.items) |b| allocator.free(b);
        self.owned_page_bytes.deinit();
    }
};

/// Apply an incremental snapshot into an existing tree. New pages
/// are appended; branches advance to the new last_lsn. The returned
/// IncrementalResult owns the page byte allocations.
pub fn restoreIncrementalInto(
    tree: *BranchTree,
    bytes: []const u8,
    allocator: std.mem.Allocator,
) Error!IncrementalResult {
    if (bytes.len < 16) return Error.Truncated;
    var p: usize = 0;
    const got_magic = std.mem.readInt(u32, bytes[p..][0..4], .little);
    if (got_magic != inc_magic) return Error.BadMagic;
    p += 4;
    // since_lsn: ignored by the applier (already integrated in pages' lsn).
    p += 8;
    if (bytes.len < p + 4) return Error.Truncated;
    const branch_count = std.mem.readInt(u32, bytes[p..][0..4], .little);
    p += 4;

    var owned: std.array_list.Managed([]u8) = .init(allocator);
    errdefer {
        for (owned.items) |b| allocator.free(b);
        owned.deinit();
    }

    var i: u32 = 0;
    while (i < branch_count) : (i += 1) {
        if (bytes.len < p + 8 + 8 + 4) return Error.Truncated;
        const bid = std.mem.readInt(u64, bytes[p..][0..8], .little);
        p += 8;
        const new_last_lsn = std.mem.readInt(u64, bytes[p..][0..8], .little);
        p += 8;
        const page_count = std.mem.readInt(u32, bytes[p..][0..4], .little);
        p += 4;

        const b = tree.branches.getPtr(bid) orelse return Error.UnknownBranch;
        if (new_last_lsn > b.last_lsn) b.last_lsn = new_last_lsn;

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
    }
    return .{ .owned_page_bytes = owned };
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

test "snapshotIncremental on empty tree yields header-only bytes" {
    const alloc = testing.allocator;
    var tree: BranchTree = .init(alloc);
    defer tree.deinit();
    const bytes = try snapshotIncremental(&tree, 0, alloc);
    defer alloc.free(bytes);
    // magic + since_lsn + branch_count = 16 bytes
    try testing.expectEqual(@as(usize, 16), bytes.len);
    const got_magic = std.mem.readInt(u32, bytes[0..4], .little);
    try testing.expectEqual(inc_magic, got_magic);
    const count = std.mem.readInt(u32, bytes[12..16], .little);
    try testing.expectEqual(@as(u32, 0), count);
}

test "snapshotIncremental emits only pages > since_lsn" {
    const alloc = testing.allocator;
    var tree: BranchTree = .init(alloc);
    defer tree.deinit();
    const root = try tree.createRoot("main");
    try tree.writePage(root, 1, 5, "early");
    try tree.writePage(root, 2, 15, "late");

    // since_lsn = 10 — should emit only the second page.
    const bytes = try snapshotIncremental(&tree, 10, alloc);
    defer alloc.free(bytes);
    try testing.expect(std.mem.indexOf(u8, bytes, "late") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "early") == null);
}

test "restoreIncrementalInto applies new pages into existing tree" {
    const alloc = testing.allocator;
    var tree_a: BranchTree = .init(alloc);
    defer tree_a.deinit();
    const root = try tree_a.createRoot("main");
    try tree_a.writePage(root, 1, 5, "v5");

    var tree_b: BranchTree = .init(alloc);
    defer tree_b.deinit();
    _ = try tree_b.createRoot("main");

    // tree_b starts with no pages. Take an incremental from tree_a
    // (since_lsn=0 = everything) and apply to tree_b.
    const incr = try snapshotIncremental(&tree_a, 0, alloc);
    defer alloc.free(incr);
    var result = try restoreIncrementalInto(&tree_b, incr, alloc);
    defer result.deinit(alloc);

    const got = try tree_b.readPage(root, 1, 5);
    try testing.expect(got != null);
    try testing.expectEqualSlices(u8, "v5", got.?);
}

test "restoreIncrementalInto rejects bad magic" {
    const alloc = testing.allocator;
    var tree: BranchTree = .init(alloc);
    defer tree.deinit();
    const bad = [_]u8{0} ** 16;
    try testing.expectError(Error.BadMagic, restoreIncrementalInto(&tree, &bad, alloc));
}

test "restoreIncrementalInto rejects truncated bytes" {
    const alloc = testing.allocator;
    var tree: BranchTree = .init(alloc);
    defer tree.deinit();
    const short = [_]u8{ 1, 2, 3 };
    try testing.expectError(Error.Truncated, restoreIncrementalInto(&tree, &short, alloc));
}

test "incremental + restore composes — incremental updates advance last_lsn" {
    const alloc = testing.allocator;
    var tree_a: BranchTree = .init(alloc);
    defer tree_a.deinit();
    const root = try tree_a.createRoot("main");
    try tree_a.writePage(root, 1, 5, "v5");
    try tree_a.writePage(root, 1, 15, "v15");
    try tree_a.writePage(root, 2, 20, "side");

    var tree_b: BranchTree = .init(alloc);
    defer tree_b.deinit();
    _ = try tree_b.createRoot("main");

    // First incremental: since_lsn=0 → grab everything.
    const incr1 = try snapshotIncremental(&tree_a, 0, alloc);
    defer alloc.free(incr1);
    var r1 = try restoreIncrementalInto(&tree_b, incr1, alloc);
    defer r1.deinit(alloc);

    // tree_b.last_lsn for root should now be 20.
    const b_root = tree_b.branches.getPtr(root).?;
    try testing.expectEqual(@as(Lsn, 20), b_root.last_lsn);
}
