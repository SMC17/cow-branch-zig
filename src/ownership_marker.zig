//! ownership_marker: v0.0.7 substrate from L87 Aletheia zlindblad.
//!
//! zlindblad's RK4 stepper consistently distinguishes Owned
//! tensors (allocated and managed by the stepper) from Borrowed
//! tensors (caller-owned, passed in for one step only). The
//! convention catches a class of bugs at the type level: a
//! Borrowed input cannot be freed by the stepper, and an Owned
//! workspace cannot be returned to the caller as if it were a
//! borrowed view.
//!
//! cow-branch already speaks shared/cloned/forked state. This
//! port adds the Ownership tag as a substrate primitive so any
//! caller composing buffers across cow-branch APIs can mark the
//! lifetime contract at the type level.
//!
//! Scope of this revision:
//!   Ownership enum { owned, borrowed }.
//!   Tagged(T) wraps a T value with an Ownership tag.
//!   isOwned(t) and isBorrowed(t) accessors.
//!   intoBorrowed(t) and intoOwned(t) constructors. Once a value
//!     is constructed, the tag is immutable; mutation requires
//!     explicit reconstruction.
//!   assertOwned(t) and assertBorrowed(t) trip a runtime check
//!     useful at API boundaries that contractually require one
//!     ownership flavor.
//!
//! Out of scope: lifetime-tracked move semantics (Zig's type
//! system already covers single-owner moves at compile time;
//! this primitive is for runtime API-boundary contracts), refcount
//! arithmetic (caller composes via a separate primitive if
//! needed).

const std = @import("std");

pub const Ownership = enum(u8) {
    owned = 0,
    borrowed = 1,
};

pub fn Tagged(comptime T: type) type {
    return struct {
        value: T,
        tag: Ownership,

        const Self = @This();

        pub fn intoOwned(v: T) Self {
            return .{ .value = v, .tag = .owned };
        }

        pub fn intoBorrowed(v: T) Self {
            return .{ .value = v, .tag = .borrowed };
        }

        pub fn isOwned(self: Self) bool {
            return self.tag == .owned;
        }

        pub fn isBorrowed(self: Self) bool {
            return self.tag == .borrowed;
        }

        pub fn assertOwned(self: Self) Error!void {
            if (self.tag != .owned) return Error.ExpectedOwned;
        }

        pub fn assertBorrowed(self: Self) Error!void {
            if (self.tag != .borrowed) return Error.ExpectedBorrowed;
        }
    };
}

pub const Error = error{
    ExpectedOwned,
    ExpectedBorrowed,
};

// --- Tests -----------------------------------------------------------------

const testing = std.testing;

test "Ownership enum is exactly two variants" {
    try testing.expectEqual(@as(usize, 2), @typeInfo(Ownership).@"enum".fields.len);
}

test "intoOwned tags as owned, intoBorrowed tags as borrowed" {
    const TI = Tagged(i64);
    const o = TI.intoOwned(42);
    const b = TI.intoBorrowed(99);
    try testing.expect(o.isOwned());
    try testing.expect(!o.isBorrowed());
    try testing.expect(b.isBorrowed());
    try testing.expect(!b.isOwned());
    try testing.expectEqual(@as(i64, 42), o.value);
    try testing.expectEqual(@as(i64, 99), b.value);
}

test "assertOwned trips on borrowed and succeeds on owned" {
    const TI = Tagged(i64);
    const o = TI.intoOwned(5);
    try o.assertOwned();
    const b = TI.intoBorrowed(5);
    try testing.expectError(Error.ExpectedOwned, b.assertOwned());
}

test "assertBorrowed trips on owned and succeeds on borrowed" {
    const TI = Tagged(i64);
    const o = TI.intoOwned(5);
    try testing.expectError(Error.ExpectedBorrowed, o.assertBorrowed());
    const b = TI.intoBorrowed(5);
    try b.assertBorrowed();
}

test "Tagged is generic over the wrapped type" {
    const TSlice = Tagged([]const u8);
    const s = TSlice.intoOwned("hello");
    try testing.expectEqualStrings("hello", s.value);
    try testing.expect(s.isOwned());
}

test "L87 zlindblad-style: stepper distinguishes Owned workspace from Borrowed input" {
    const Buf = Tagged([]f64);
    var ws_bytes = [_]f64{ 0.0, 0.0, 0.0 };
    var inp_bytes = [_]f64{ 1.0, 2.0, 3.0 };
    const ws = Buf.intoOwned(&ws_bytes);
    const inp = Buf.intoBorrowed(&inp_bytes);
    try ws.assertOwned();
    try inp.assertBorrowed();
    try testing.expectError(Error.ExpectedBorrowed, ws.assertBorrowed());
    try testing.expectError(Error.ExpectedOwned, inp.assertOwned());
}

test "Tagged round-trips through assignment" {
    const TI = Tagged(i64);
    var o = TI.intoOwned(1);
    const o2 = o;
    try testing.expect(o2.isOwned());
    o.value = 99;
    try testing.expectEqual(@as(i64, 99), o.value);
    try testing.expectEqual(@as(i64, 1), o2.value);
}

test "Ownership.owned has explicit u8 value 0 for stable C-ABI" {
    try testing.expectEqual(@as(u8, 0), @intFromEnum(Ownership.owned));
    try testing.expectEqual(@as(u8, 1), @intFromEnum(Ownership.borrowed));
}
