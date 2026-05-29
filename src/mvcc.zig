//! mvcc — v0.0.6 port of P1402 (Memgraph MVCC).
//!
//! Ports P1402 (Memgraph MVCC from L67-graph-frontier). MVCC keeps
//! a version chain per data item; readers pick the version visible
//! at their snapshot LSN. This is the foundation under cow-branch
//! page reads (we already do per-page LSN lookup) — v0.0.6 lifts the
//! same primitive into a standalone MVCC reader for application-
//! level data items.
//!
//! Each item is a chain of (lsn, value_bytes) versions sorted by
//! LSN descending. A read at snapshot_lsn returns the newest version
//! with `lsn ≤ snapshot_lsn`. Writes prepend; reads scan.

const std = @import("std");

pub const ItemId = u64;
pub const Lsn = u64;

pub const Error = error{ OutOfMemory };

const Version = struct {
    lsn: Lsn,
    bytes: []const u8,
};

pub const MvccStore = struct {
    allocator: std.mem.Allocator,
    chains: std.AutoHashMap(ItemId, std.array_list.Managed(Version)),

    pub fn init(allocator: std.mem.Allocator) MvccStore {
        return .{
            .allocator = allocator,
            .chains = .init(allocator),
        };
    }

    pub fn deinit(self: *MvccStore) void {
        var it = self.chains.valueIterator();
        while (it.next()) |v| v.deinit();
        self.chains.deinit();
    }

    /// Append a new version to the item's chain. Caller owns
    /// `bytes` — the store borrows.
    pub fn write(
        self: *MvccStore,
        item: ItemId,
        lsn: Lsn,
        bytes: []const u8,
    ) Error!void {
        const gop = self.chains.getOrPut(item) catch return Error.OutOfMemory;
        if (!gop.found_existing) gop.value_ptr.* = .init(self.allocator);
        // Versions are kept LSN-descending so reads find the newest
        // visible version with a linear scan from the front.
        gop.value_ptr.insert(0, .{ .lsn = lsn, .bytes = bytes }) catch return Error.OutOfMemory;
    }

    /// Read the value visible at `snapshot_lsn`. Returns null if no
    /// version exists at or below the snapshot.
    pub fn read(self: *MvccStore, item: ItemId, snapshot_lsn: Lsn) ?[]const u8 {
        const chain = self.chains.getPtr(item) orelse return null;
        for (chain.items) |v| {
            if (v.lsn <= snapshot_lsn) return v.bytes;
        }
        return null;
    }

    pub fn versionCount(self: *MvccStore, item: ItemId) usize {
        const chain = self.chains.getPtr(item) orelse return 0;
        return chain.items.len;
    }

    /// Drop versions older than `keep_at_or_above` (compaction).
    /// Keeps every version with `lsn >= keep_at_or_above`.
    pub fn compactBelow(self: *MvccStore, keep_at_or_above: Lsn) void {
        var it = self.chains.valueIterator();
        while (it.next()) |chain| {
            // chain is LSN-descending. Walk from the back; drop while
            // last < threshold.
            while (chain.items.len > 0 and chain.items[chain.items.len - 1].lsn < keep_at_or_above) {
                _ = chain.pop();
            }
        }
    }
};

// --- Tests ----------------------------------------------------------------

const testing = std.testing;

test "MvccStore.write + read at exact LSN" {
    var store: MvccStore = .init(testing.allocator);
    defer store.deinit();
    try store.write(1, 100, "v100");
    try testing.expectEqualStrings("v100", store.read(1, 100).?);
}

test "read picks newest version at or below snapshot" {
    var store: MvccStore = .init(testing.allocator);
    defer store.deinit();
    try store.write(1, 10, "v10");
    try store.write(1, 20, "v20");
    try store.write(1, 30, "v30");

    try testing.expectEqualStrings("v10", store.read(1, 10).?);
    try testing.expectEqualStrings("v10", store.read(1, 15).?);
    try testing.expectEqualStrings("v20", store.read(1, 20).?);
    try testing.expectEqualStrings("v20", store.read(1, 25).?);
    try testing.expectEqualStrings("v30", store.read(1, 30).?);
    try testing.expectEqualStrings("v30", store.read(1, 999).?);
}

test "read before any write returns null" {
    var store: MvccStore = .init(testing.allocator);
    defer store.deinit();
    try store.write(1, 100, "v100");
    try testing.expectEqual(@as(?[]const u8, null), store.read(1, 50));
}

test "read of unknown item returns null" {
    var store: MvccStore = .init(testing.allocator);
    defer store.deinit();
    try testing.expectEqual(@as(?[]const u8, null), store.read(99, 100));
}

test "versionCount grows with each write" {
    var store: MvccStore = .init(testing.allocator);
    defer store.deinit();
    try store.write(1, 10, "a");
    try testing.expectEqual(@as(usize, 1), store.versionCount(1));
    try store.write(1, 20, "b");
    try testing.expectEqual(@as(usize, 2), store.versionCount(1));
    try store.write(1, 30, "c");
    try testing.expectEqual(@as(usize, 3), store.versionCount(1));
}

test "compactBelow drops old versions" {
    var store: MvccStore = .init(testing.allocator);
    defer store.deinit();
    try store.write(1, 10, "v10");
    try store.write(1, 20, "v20");
    try store.write(1, 30, "v30");
    try store.write(1, 40, "v40");

    store.compactBelow(25);
    try testing.expectEqual(@as(usize, 2), store.versionCount(1));
    // Reads at LSN < 25 now miss the lost early versions.
    try testing.expectEqual(@as(?[]const u8, null), store.read(1, 15));
    try testing.expectEqualStrings("v30", store.read(1, 30).?);
}

test "compactBelow preserves chain when nothing to drop" {
    var store: MvccStore = .init(testing.allocator);
    defer store.deinit();
    try store.write(1, 100, "v100");
    try store.write(1, 200, "v200");
    store.compactBelow(50);
    try testing.expectEqual(@as(usize, 2), store.versionCount(1));
}

test "multiple items maintain independent version chains" {
    var store: MvccStore = .init(testing.allocator);
    defer store.deinit();
    try store.write(1, 10, "item1-a");
    try store.write(2, 20, "item2-a");
    try store.write(1, 30, "item1-b");

    try testing.expectEqualStrings("item1-b", store.read(1, 30).?);
    try testing.expectEqualStrings("item2-a", store.read(2, 20).?);
    try testing.expectEqualStrings("item1-a", store.read(1, 15).?);
}
