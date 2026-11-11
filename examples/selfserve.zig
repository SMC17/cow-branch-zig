//! Synthetic branch task: later parent writes stay outside a fork's snapshot.
const std = @import("std");
const lib = @import("lib");
pub fn main() !void {
    var tree = lib.BranchTree.init(std.heap.page_allocator);
    defer tree.deinit();
    const parent = try tree.createRoot("fixture-main");
    try tree.writePage(parent, 1, 1, "before");
    const child = try tree.fork(parent, "fixture-child");
    try tree.writePage(parent, 1, 2, "after");
    const old = (try tree.readPage(child, 1, 9)) orelse return error.MissingPage;
    const new = (try tree.readPage(parent, 1, 9)) orelse return error.MissingPage;
    if (!std.mem.eql(u8, old, "before") or !std.mem.eql(u8, new, "after")) return error.IsolationMismatch;
    std.debug.print("fixture: parent=after fork=before snapshot_isolation=true\n", .{});
}
