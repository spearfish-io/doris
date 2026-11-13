# Spearfish fork of Apache Doris

Prod runs this fork's BE (and FE) images from `spearfish.azurecr.io/apache/doris`. The fork is
**upstream release tag + a short stack of our commits**, rebased (never merged) onto each new
upstream 4.1.x release. There is no CI in this fork: images are built by hand with
`spearfish/build-images.sh` on the build PC (32 cores / 121G RAM, local
`apache/doris:build-env-ldb-toolchain-latest`).

## Current line: `spearfish/4.1.5-p67552`

Base: upstream tag `4.1.5-release` (`917b20be838`). Our commits on top:

| Commit (4.1.4 line) | What | Status |
|---|---|---|
| `c2a275c56` | [fix](iceberg) commit the catalog URI for delete files | **Kept.** Upstream apache/doris#67552 is still open. Drop it once a release contains it. |
| `aaf48d7e0` | fix(core): never dereference hollow (moved-from) composite columns | **Kept**, extended by the next row. |
| (new) | backport of upstream `c5a8e0d1c38` (#65087): read-only `for_each_subcolumn`, plus `checked_subcolumn()` null guards in traversal and `sanity_check()` | **Root-cause fix** for the `ColumnNullable::sanity_check` SIGSEGV (see below). Drop the backport part once a 4.1.x release contains #65087. Keep the guards unless upstream adds equivalents. |
| `a8aa768e1` | build shims (thrift 0.24, `generated_annotations=suppress`) | **Dropped.** 4.1.5 already has them (`8080085d0aa`, thrift 0.24.0 in `fe/pom.xml`, the Makefile flag, no `GlobalOutput`). |

### Why the hollow column happened (2026-09-10, 2026-10-31, 2026-11-13)

In 4.1.x, `ColumnNullable::for_each_subcolumn` **moved `_null_map` out** for the duration of the
callback. `ColumnArray` and `ColumnMap` did the same with their offsets. It is a write disguised as
a read. `Block::clear_column_data` calls it through `is_recursively_exclusive` and
`is_recursively_intact` (the latter added in `aaf48d7e0`) on columns that are **shared** with other
pipeline tasks.

While one task walked such a column, another task saw `_null_map == nullptr`. In the
2026-11-13 crash the other task was the local-shuffle partitioner calling `sanity_check()` from
`VExprContext::execute`, and it faulted at `@0x18`. Two walkers running at once could also leave
the null permanently.

`is_recursively_intact` runs the walk on exactly the non-exclusive (shared) columns, so
`aaf48d7e0` widened the race window. be-4.1.4-p67552-2 did contain that code, despite logging
commitID `c2a275c5`: it was built from an uncommitted tree.

Upstream `c5a8e0d1c38` makes the traversal const and read-only. Mutation moves to
`mutate_subcolumns()`, used only by COW `mutate()`. On top of that, every traversal and composite
`sanity_check()` goes through `IColumn::checked_subcolumn()`. A hollow child therefore throws
`doris::Exception` (the query fails) instead of crashing the BE. Tests:
`be/test/core/column/column_hollow_test.cpp` and
`regression-test/suites/external_table_p0/iceberg/test_iceberg_sys_table_files_shuffle.groovy`.

## Rebasing onto the next upstream 4.1.x release

```bash
git fetch https://github.com/apache/doris.git refs/tags/4.1.N-release:refs/tags/4.1.N-release
git switch -c spearfish/4.1.N-p67552 4.1.N-release
# Cherry-pick the previous line's fork commits, oldest first: everything after the old base tag.
git log --oneline --reverse 4.1.(N-1)-release..spearfish/4.1.(N-1)-p67552
git cherry-pick -x <each commit>
```

For each commit, before picking:

1. Check whether upstream already has it: `git log 4.1.N-release --grep '<PR number>'`, and look at
   the touched lines. If it is already there, drop the commit.
2. On a conflict, resolve toward upstream's version and keep only our delta. Note what you kept or
   dropped and why in this README's table.
3. Build and test (`./run-be-ut.sh --run --filter='ColumnHollowTest.*:ColumnMutateSubcolumnsTest.*:BlockTest.*'`),
   then build images (below), then canary in prod (BE on one pod first; see the runbook).

Never merge upstream into a fork branch. Each release gets a fresh branch from its tag.

## Building images

Run this on a **clean, committed** checkout of the fork branch. The script refuses a dirty tree,
because the BE logs `Current BE git commitID` from `git log -1`.

```bash
az acr login --name spearfish
bash spearfish/build-images.sh --suffix p67552-1          # be-4.1.5-p67552-1 / fe-4.1.5-p67552-1
bash spearfish/build-images.sh --suffix p67552-1 --push   # refuses to overwrite an existing tag
```

The images overlay fresh `output/` onto proven bases. The BE base is `be-4.1.1`, the same base as
every p67552 image. The FE base is `fe-4.1.4`. Override them with `BE_BASE_IMAGE` /
`FE_BASE_IMAGE`. Before you push, diff the base image's `entry_point.sh` / `init_*.sh` against
`docker/runtime/` when the base changes.
