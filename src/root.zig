const branch = @import("branch.zig");

pub const BranchId = branch.BranchId;
pub const Lsn = branch.Lsn;
pub const PageId = branch.PageId;
pub const Page = branch.Page;
pub const Branch = branch.Branch;
pub const BranchTree = branch.BranchTree;
pub const Error = branch.Error;

pub const persistence = @import("persistence.zig");
pub const snapshot = persistence.snapshot;
pub const restore = persistence.restore;
pub const restoreOwned = persistence.restoreOwned;
pub const RestoreResult = persistence.RestoreResult;
pub const PersistenceError = persistence.Error;

pub const incremental = @import("incremental.zig");
pub const snapshotIncremental = incremental.snapshotIncremental;
pub const restoreIncrementalInto = incremental.restoreIncrementalInto;
pub const IncrementalResult = incremental.IncrementalResult;
pub const IncrementalError = incremental.Error;

pub const dedup = @import("dedup.zig");
pub const branchStateHash = dedup.branchStateHash;
pub const findDuplicates = dedup.findDuplicates;
pub const freeDuplicates = dedup.freeDuplicates;
pub const DuplicateGroup = dedup.DuplicateGroup;

pub const gc = @import("gc.zig");
pub const markReachable = gc.markReachable;
pub const sweepUnreachable = gc.sweepUnreachable;
pub const collectUnreachable = gc.collectUnreachable;

pub const mvcc = @import("mvcc.zig");
pub const MvccStore = mvcc.MvccStore;
pub const MvccItemId = mvcc.ItemId;

test {
    @import("std").testing.refAllDecls(@This());
}
