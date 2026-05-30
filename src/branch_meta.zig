//! branch_meta: v0.0.10 — unified BranchAge + BranchLabel view.
//!
//! v0.0.8 ships BranchAgeRegistry, v0.0.9 ships BranchLabelRegistry.
//! Every dashboard wants both at once: "main (created 30 days ago,
//! age 31d 4h, has 3 children, labelled feature-x)." Without a
//! join view, every caller writes two lookups.
//!
//! Port a tiny view struct that holds REFERENCES to both registries
//! and exposes meta(branch_id, now_ns) returning a unified
//! BranchMeta record.
//!
//! Scope of this revision:
//!   BranchMeta { branch_id, age_ns: ?i64, label: ?[]const u8 }.
//!   BranchMetaView { age, label } holds pointers to the two
//!     registries.
//!   init(age, label) returns the view.
//!   meta(branch_id, now_ns) returns the unified record. Both
//!     fields nullable for unknown branches in either registry.
//!
//! Out of scope: registry-owning constructor (caller composes
//! the two registries first and passes pointers; substrate stays
//! decoupled), age-without-label or label-without-age dedicated
//! views (caller asks the registry directly).

const std = @import("std");
const branch = @import("branch.zig");
const branch_age = @import("branch_age.zig");
const branch_label = @import("branch_label.zig");

pub const BranchId = branch.BranchId;
pub const BranchAgeRegistry = branch_age.BranchAgeRegistry;
pub const BranchLabelRegistry = branch_label.BranchLabelRegistry;

pub const BranchMeta = struct {
    branch_id: BranchId,
    age_ns: ?i64,
    label: ?[]const u8,
};

pub const BranchMetaView = struct {
    age: *const BranchAgeRegistry,
    label: *const BranchLabelRegistry,

    pub fn init(age: *const BranchAgeRegistry, label: *const BranchLabelRegistry) BranchMetaView {
        return .{ .age = age, .label = label };
    }

    pub fn meta(self: BranchMetaView, branch_id: BranchId, now_ns: i64) BranchMeta {
        return .{
            .branch_id = branch_id,
            .age_ns = self.age.ageNs(branch_id, now_ns),
            .label = self.label.get(branch_id),
        };
    }
};

// --- Tests -----------------------------------------------------------------

const testing = std.testing;

test "meta returns null/null for fully-unknown branch" {
    var age: BranchAgeRegistry = .init(testing.allocator);
    defer age.deinit();
    var label: BranchLabelRegistry = .init(testing.allocator);
    defer label.deinit();
    const view: BranchMetaView = .init(&age, &label);
    const m = view.meta(99, 1_000_000_000);
    try testing.expectEqual(@as(BranchId, 99), m.branch_id);
    try testing.expectEqual(@as(?i64, null), m.age_ns);
    try testing.expectEqual(@as(?[]const u8, null), m.label);
}

test "meta returns age + label for fully-known branch" {
    var age: BranchAgeRegistry = .init(testing.allocator);
    defer age.deinit();
    var label: BranchLabelRegistry = .init(testing.allocator);
    defer label.deinit();
    try age.record(1, 1_000_000_000);
    try label.set(1, "main");
    const view: BranchMetaView = .init(&age, &label);
    const m = view.meta(1, 2_000_000_000);
    try testing.expectEqual(@as(?i64, 1_000_000_000), m.age_ns);
    try testing.expectEqualStrings("main", m.label.?);
}

test "meta returns age only when label missing" {
    var age: BranchAgeRegistry = .init(testing.allocator);
    defer age.deinit();
    var label: BranchLabelRegistry = .init(testing.allocator);
    defer label.deinit();
    try age.record(1, 1_000_000_000);
    const view: BranchMetaView = .init(&age, &label);
    const m = view.meta(1, 1_500_000_000);
    try testing.expectEqual(@as(?i64, 500_000_000), m.age_ns);
    try testing.expectEqual(@as(?[]const u8, null), m.label);
}

test "meta returns label only when age missing" {
    var age: BranchAgeRegistry = .init(testing.allocator);
    defer age.deinit();
    var label: BranchLabelRegistry = .init(testing.allocator);
    defer label.deinit();
    try label.set(1, "main");
    const view: BranchMetaView = .init(&age, &label);
    const m = view.meta(1, 1_500_000_000);
    try testing.expectEqual(@as(?i64, null), m.age_ns);
    try testing.expectEqualStrings("main", m.label.?);
}

test "meta is read-only (does not mutate either registry)" {
    var age: BranchAgeRegistry = .init(testing.allocator);
    defer age.deinit();
    var label: BranchLabelRegistry = .init(testing.allocator);
    defer label.deinit();
    try age.record(1, 100);
    try label.set(1, "main");
    const before_count_age = age.count();
    const before_count_label = label.count();
    const view: BranchMetaView = .init(&age, &label);
    _ = view.meta(1, 200);
    _ = view.meta(99, 200);
    try testing.expectEqual(before_count_age, age.count());
    try testing.expectEqual(before_count_label, label.count());
}
