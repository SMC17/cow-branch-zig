# Changelog

## 0.0.1 — 2026-05-28

createRoot + fork + writePage + readPage with LSN-bounded reads + parent fallback.
Forking is O(1); child writes don't affect parent; child reads at historical LSN
honour parent state (clamped to branch_point_lsn). 11/11 tests pass on Zig 0.16.
