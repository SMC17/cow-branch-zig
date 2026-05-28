# cow-branch-zig

[![License: AGPL-3.0-or-later](https://img.shields.io/badge/License-AGPL--3.0--or--later-blue.svg)](LICENSE)
[![Zig](https://img.shields.io/badge/Zig-0.16-orange.svg)](https://ziglang.org/)

Copy-on-write branching substrate in Zig 0.16. Three-source synthesis: Neon L324 (Pageserver copy-on-write branches) + tableformat-zig L6 (zero-copy partition evolution) + PlanetScale L165 (database branching deploy-request workflow).

## Status

**v0.0.1 — 11/11 tests pass on Zig 0.16.** Data shapes + `createRoot` / `fork` / `writePage` / `readPage` with LSN-bounded reads + parent fallback. Forking is O(1) (no page-table copy). Child writes don't affect parent. Historical reads at any LSN reconstruct the page set visible at that point.

## What ships

- `BranchId` / `Lsn` / `PageId` — opaque integer types. The substrate is page-id-agnostic; callers map `PageId` to whatever address space makes sense (file + offset, tenant + table + row-group, etc.).
- `Branch { branch_id, name, parent_id, branch_point_lsn, last_lsn, pages }` — one node in the branch tree.
- `BranchTree { branches, next_branch_id }` — tree of branches with `createRoot` / `fork` / `writePage` / `readPage` / `branch` / `branchCount`.
- `Error { BranchNotFound, ParentNotFound, InvalidBranchPoint, LsnPredecessorViolation, OutOfMemory }`.

## The three properties tested

1. **O(1) fork.** `fork(parent_id, name)` creates a child whose `pages` table is empty. No copy of the parent's page table.
2. **Copy-on-write isolation.** Child writes to a page do not change what the parent sees on subsequent reads. Tested via `child write does NOT affect parent` test.
3. **LSN-clamped parent fallback.** When a child reads an unmodified page, it falls through to the parent — but the read LSN is clamped to the child's `branch_point_lsn`, so the child never sees parent state that occurred after the fork. Tested via `child read at historical LSN before branch point honours parent state` + `multi-level branching` tests.

## Build

```sh
zig build test                  # 11 unit tests
```

## What ships does NOT do (yet)

- **No WAL replay pipeline** (Neon L322 page-materialisation-from-WAL). v0.0.2 ships this.
- **No commit-or-retry snapshot transaction.** v0.0.2.
- **No cleanup quota + TTL** (Supabase L249 deploy pipeline). v0.0.3 ships per-tenant branch quotas + idle-timeout reaping.
- **No persistence.** Memory-only at v0.0.1. v0.0.2 wires the on-disk layer (composes with shipped `tableformat-zig` for manifest serialisation).
- **No clamping on fork at non-current LSN.** v0.0.1 always forks at the parent's `last_lsn`. Forking at a historical LSN is a v0.0.2 add.

## Composes with shipped substrate

- **`tableformat-zig` L6 zero-copy partition evolution** — same principle, different layer. tableformat-zig manages partition-spec evolution across data files; cow-branch-zig manages page-level branching across database history.
- **PlanetScale L165 branching workflow** — the operational shape (branch + deploy request + cutover) sits on top of cow-branch's storage primitive.
- **Neon L324 + Pageserver** — Neon's architectural pattern, ported here as a generic Zig substrate independent of Postgres.

## Honest non-claims

- Pre-1.0 substrate. v0.0.1 stores everything in memory; no durability guarantees.
- `readPage` does a linear scan over the branch's local pages for matches on `page_id`. Adequate at v0.0.1 scale; v0.0.2 swaps to a sorted index per `page_id`.
- No multi-writer coordination. Single-writer per branch at v0.0.1; commit-or-retry transactions ship in v0.0.2.

## Credit

Concepts adapted from Neon Pageserver (castle L324) + Iceberg via tableformat-zig (castle L6 / Airbnb origin) + PlanetScale branching workflow (castle L165). Frontier port by Sean Collins (`sean@sunlitmoon.online`).

## License

AGPL-3.0-or-later. See `LICENSE`.
