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

pub const ownership_marker = @import("ownership_marker.zig");
pub const Ownership = ownership_marker.Ownership;
pub const Tagged = ownership_marker.Tagged;
pub const OwnershipError = ownership_marker.Error;

pub const branch_age = @import("branch_age.zig");
pub const BranchAgeRegistry = branch_age.BranchAgeRegistry;
pub const BranchAgeError = branch_age.Error;

pub const branch_label = @import("branch_label.zig");
pub const BranchLabelRegistry = branch_label.BranchLabelRegistry;
pub const BranchLabelError = branch_label.Error;

pub const branch_meta = @import("branch_meta.zig");
pub const BranchMeta = branch_meta.BranchMeta;
pub const BranchMetaView = branch_meta.BranchMetaView;

pub const branch_audit_log = @import("branch_audit_log.zig");
pub const BranchEventKind = branch_audit_log.BranchEventKind;
pub const BranchEvent = branch_audit_log.BranchEvent;
pub const BranchAuditLog = branch_audit_log.BranchAuditLog;
pub const BranchAuditError = branch_audit_log.Error;

test {
    @import("std").testing.refAllDecls(@This());
}
