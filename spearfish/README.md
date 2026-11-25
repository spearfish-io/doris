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

## arm64 images (prod Doris runs on Cobalt since 2026-11-25)

Prod Doris runs on `bigdataarm` (Standard_E8ps_v6, Azure Cobalt 100) from the **multi-arch** tags
`be-4.1.5-p67552-2-multiarch` / `fe-4.1.5-p67552-2-multiarch`. In each, the amd64 half is the exact
`build-images.sh` image and the arm64 half is the same commit compiled natively on ARM. The prod
benchmark (8 of the heaviest query shapes, this fork on both arches) had E8ps_v6 **4% faster cold
and 7% faster warm** than E8as_v6, at ~23% less. An E8as_v6 is 4 cores with SMT; an E8ps_v6 is 8
real cores, and Doris spreads every query over all of them.

**Never use upstream's arm64 images.** `env.sh` sets `DISABLE_BUILD_AZURE=ON` for aarch64, so they
abort on the first ADLS read (`BE is not compiled with azure support`). A `count(*)` smoke test
passes anyway because it reads only metadata, so it proves nothing.

```bash
az acr login --name spearfish                                   # also needs kubectl access to dev AKS
bash spearfish/build-arm64.sh --suffix p67552-2                 # compile on dev cirunnerarm (~100 min)
bash spearfish/build-arm64.sh --suffix p67552-2 --push \
    --amd64-be be-4.1.5-p67552-1 --amd64-fe fe-4.1.5-p67552-2   # arm64 + multi-arch tags
bash spearfish/build-arm64.sh --cleanup                         # drop the namespace and its 256 GiB PVC
```

- **Where it runs:** a pod on the dev `cirunnerarm` node (D8pds_v6, already reserved for CI), not a
  laptop. No upstream arm64 build-env image exists, so `spearfish/arm64/build.sh` installs the same
  toolchain versions as the x86 build-env (ldb v0.25, JDK 17, Maven 3.9.9, node 22.12, rust 1.94),
  then builds the third-party tree and BE/FE. On 8 cores: third-party ~25 min, BE+FE ~76 min. The
  PVC keeps everything, so a re-run after a fix resumes.
- **The three settings that make it work** are explained in `arm64/build.sh`:
  - `DISABLE_BUILD_AZURE=OFF`.
  - `VCPKG_FORCE_SYSTEM_BINARIES=1`, needed by the Azure SDK's vcpkg on ARM.
  - `ARM_MARCH=armv9-a+bf16+i8mm`. OpenBLAS targets the build CPU on aarch64.
- **The arm64 BE runs only on v6 (Cobalt) ARM.** On older ARM it dies with SIGILL. Keep Doris pools
  `*ps_v6`.
- **Packaging matches `build-images.sh`:** the same overlay, done with kaniko on the same node, onto
  the arm64 entries of the same upstream base indexes (`be-4.1.1-arm64` / `fe-4.1.4-arm64`, imported
  by digest). Tags are never overwritten.
- **BE vs FE suffixes:** prod's amd64 BE is `p67552-1`. `-2` changed only FE code, so the
  `-2-multiarch` BE pairs the `-1` amd64 BE with an arm64 BE built at `-2`, which has the same BE code.
