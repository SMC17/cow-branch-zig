//! branch_audit_log: v0.0.11 — append-only branch lifecycle log.
//!
//! Cross-primitive composition: v0.0.5 GC + v0.0.7 ownership_marker
//! + v0.0.8 BranchAgeRegistry + v0.0.9 BranchLabelRegistry + v0.0.10
//! BranchMetaView all benefit from a deterministic record of
//! every branch lifecycle event (create, fork, merge, gc-delete,
//! rename). Existing primitives just provide point-in-time
//! views; the audit log provides the history.
//!
//! Port a small append-only event log keyed on BranchId with
//! caller-supplied timestamps + event kinds.
//!
//! Scope of this revision:
//!   BranchEventKind enum (create, fork, merge, gc_delete,
//!     rename, snapshot).
//!   BranchEvent { branch_id, ts_ns, kind, parent_id (optional),
//!     payload_hash (16 bytes; caller-defined semantics) }.
//!   BranchAuditLog append-only via std.ArrayList; eventsOf
//!     (branch_id, allocator) returns ordered slice.
//!
//! Out of scope: persistence (caller composes with tableformat
//! / wflog Triple), event-stream subscription (caller polls
//! eventsOf for now; pub/sub stays caller-policy), event
//! invalidation (append-only by design).

const std = @import("std");
const branch = @import("branch.zig");

pub const BranchId = branch.BranchId;

pub const Error = error{
    OutOfMemory,
};

pub const BranchEventKind = enum(u8) {
    create = 0,
    fork = 1,
    merge = 2,
    gc_delete = 3,
    rename = 4,
    snapshot = 5,
};

pub const BranchEvent = struct {
    branch_id: BranchId,
    ts_ns: i64,
    kind: BranchEventKind,
    parent_id: ?BranchId = null,
    payload_hash: [16]u8 = .{0} ** 16,
};

pub const BranchAuditLog = struct {
    allocator: std.mem.Allocator,
    events: std.ArrayList(BranchEvent),

    pub fn init(allocator: std.mem.Allocator) BranchAuditLog {
        return .{ .allocator = allocator, .events = .empty };
    }

    pub fn deinit(self: *BranchAuditLog) void {
        self.events.deinit(self.allocator);
    }

    pub fn record(self: *BranchAuditLog, event: BranchEvent) Error!void {
        self.events.append(self.allocator, event) catch return Error.OutOfMemory;
    }

    pub fn len(self: BranchAuditLog) usize {
        return self.events.items.len;
    }

    pub fn eventsOf(
        self: BranchAuditLog,
        branch_id: BranchId,
        allocator: std.mem.Allocator,
    ) Error![]BranchEvent {
        var matches: std.ArrayList(BranchEvent) = .empty;
        errdefer matches.deinit(allocator);
        for (self.events.items) |e| {
            if (e.branch_id == branch_id) {
                matches.append(allocator, e) catch return Error.OutOfMemory;
            }
        }
        return matches.toOwnedSlice(allocator) catch return Error.OutOfMemory;
    }

    pub fn countOfKind(self: BranchAuditLog, kind: BranchEventKind) usize {
        var n: usize = 0;
        for (self.events.items) |e| {
            if (e.kind == kind) n += 1;
        }
        return n;
    }
};

// --- Tests -----------------------------------------------------------------

const testing = std.testing;

test "record then len" {
    var log: BranchAuditLog = .init(testing.allocator);
    defer log.deinit();
    try log.record(.{ .branch_id = 1, .ts_ns = 100, .kind = .create });
    try log.record(.{ .branch_id = 2, .ts_ns = 200, .kind = .fork, .parent_id = 1 });
    try testing.expectEqual(@as(usize, 2), log.len());
}

test "eventsOf filters by branch_id in insertion order" {
    var log: BranchAuditLog = .init(testing.allocator);
    defer log.deinit();
    try log.record(.{ .branch_id = 1, .ts_ns = 100, .kind = .create });
    try log.record(.{ .branch_id = 2, .ts_ns = 200, .kind = .create });
    try log.record(.{ .branch_id = 1, .ts_ns = 300, .kind = .snapshot });
    try log.record(.{ .branch_id = 1, .ts_ns = 400, .kind = .gc_delete });
    const e1 = try log.eventsOf(1, testing.allocator);
    defer testing.allocator.free(e1);
    try testing.expectEqual(@as(usize, 3), e1.len);
    try testing.expectEqual(@as(i64, 100), e1[0].ts_ns);
    try testing.expectEqual(@as(i64, 300), e1[1].ts_ns);
    try testing.expectEqual(@as(i64, 400), e1[2].ts_ns);
}

test "eventsOf on unknown branch returns empty slice" {
    var log: BranchAuditLog = .init(testing.allocator);
    defer log.deinit();
    try log.record(.{ .branch_id = 1, .ts_ns = 100, .kind = .create });
    const e = try log.eventsOf(99, testing.allocator);
    defer testing.allocator.free(e);
    try testing.expectEqual(@as(usize, 0), e.len);
}

test "countOfKind tallies events per kind" {
    var log: BranchAuditLog = .init(testing.allocator);
    defer log.deinit();
    try log.record(.{ .branch_id = 1, .ts_ns = 1, .kind = .create });
    try log.record(.{ .branch_id = 2, .ts_ns = 2, .kind = .fork, .parent_id = 1 });
    try log.record(.{ .branch_id = 3, .ts_ns = 3, .kind = .fork, .parent_id = 1 });
    try log.record(.{ .branch_id = 2, .ts_ns = 4, .kind = .gc_delete });
    try testing.expectEqual(@as(usize, 1), log.countOfKind(.create));
    try testing.expectEqual(@as(usize, 2), log.countOfKind(.fork));
    try testing.expectEqual(@as(usize, 1), log.countOfKind(.gc_delete));
    try testing.expectEqual(@as(usize, 0), log.countOfKind(.merge));
}

test "payload_hash defaults to zeros" {
    var log: BranchAuditLog = .init(testing.allocator);
    defer log.deinit();
    try log.record(.{ .branch_id = 1, .ts_ns = 1, .kind = .create });
    const e = try log.eventsOf(1, testing.allocator);
    defer testing.allocator.free(e);
    for (e[0].payload_hash) |b| try testing.expectEqual(@as(u8, 0), b);
}

test "BranchEventKind underlying u8 stable for C-ABI" {
    try testing.expectEqual(@as(u8, 0), @intFromEnum(BranchEventKind.create));
    try testing.expectEqual(@as(u8, 5), @intFromEnum(BranchEventKind.snapshot));
}
