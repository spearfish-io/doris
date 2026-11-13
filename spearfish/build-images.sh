#!/usr/bin/env bash
# Licensed to the Apache Software Foundation (ASF) under one
# or more contributor license agreements.  See the NOTICE file
# distributed with this work for additional information
# regarding copyright ownership.  The ASF licenses this file
# to you under the Apache License, Version 2.0 (the
# "License"); you may not use this file except in compliance
# with the License.  You may obtain a copy of the License at
#
#   http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing,
# software distributed under the License is distributed on an
# "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
# KIND, either express or implied.  See the License for the
# specific language governing permissions and limitations
# under the License.

# Spearfish fork: build the Doris FE/BE runtime images from a CLEAN, COMMITTED checkout.
#
#   checkout-clean-check -> build in the toolchain container -> docker build -> (optional) push
#
# Why "clean and committed": gensrc/script/gen_build_version.sh embeds `git log -1` as the
# "Current BE git commitID" in the BE log. be-4.1.4-p67552-2 was built from an uncommitted tree,
# so prod logged c2a275c5 while running aaf48d7e0's code. This script refuses a dirty tree.
#
# Usage (from the repo root, on the fork branch, e.g. spearfish/4.1.5-p67552):
#   spearfish/build-images.sh --suffix p67552-1            # build only, prints the tags
#   spearfish/build-images.sh --suffix p67552-1 --push     # build and push to ACR
# Options:
#   --suffix S        tag suffix; tags become be-<ver>-S / fe-<ver>-S (required)
#   --be-only|--fe-only
#   --push            push to ${REGISTRY}/apache/doris (az acr login first)
#   --skip-build      reuse ./output (only if it was built from the SAME commit by this script)
#   -j N              build parallelism (default: nproc)
# Env:
#   REGISTRY          default spearfish.azurecr.io
#   TOOLCHAIN_IMAGE   default ${REGISTRY}/dockerhub/apache/doris:build-env-ldb-toolchain-latest
#   BE_BASE_IMAGE     default spearfish.azurecr.io/apache/doris:be-4.1.1 (base of every p67552 BE
#                     image: entrypoint/init scripts proven in prod; only be/{lib,bin,www,dict}
#                     are replaced)
#   FE_BASE_IMAGE     default spearfish.azurecr.io/apache/doris:fe-4.1.4 (only fe/{lib,bin,webroot}
#                     are replaced; conf comes from the DorisCluster ConfigMap anyway)

set -euo pipefail

REGISTRY="${REGISTRY:-spearfish.azurecr.io}"
REPO="${REGISTRY}/apache/doris"
# Through our ACR's Docker Hub mirror, not docker.io. It must be recent: 4.1.5 needs Lance/Paimon in the
# prebuilt third-party tree (the 2026-09-06 image lacks them and build.sh stops before compiling).
TOOLCHAIN_IMAGE="${TOOLCHAIN_IMAGE:-${REGISTRY}/dockerhub/apache/doris:build-env-ldb-toolchain-latest}"
BE_BASE_IMAGE="${BE_BASE_IMAGE:-${REGISTRY}/apache/doris:be-4.1.1}"
FE_BASE_IMAGE="${FE_BASE_IMAGE:-${REGISTRY}/apache/doris:fe-4.1.4}"

SUFFIX=""
BUILD_BE=1
BUILD_FE=1
PUSH=0
SKIP_BUILD=0
PARALLEL="$(nproc)"

while [[ $# -gt 0 ]]; do
    case "$1" in
    --suffix) SUFFIX="$2"; shift 2 ;;
    --be-only) BUILD_FE=0; shift ;;
    --fe-only) BUILD_BE=0; shift ;;
    --push) PUSH=1; shift ;;
    --skip-build) SKIP_BUILD=1; shift ;;
    -j) PARALLEL="$2"; shift 2 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done
[[ -n "${SUFFIX}" ]] || { echo "--suffix is required (e.g. p67552-1)" >&2; exit 2; }

ROOT="$(git rev-parse --show-toplevel)"
cd "${ROOT}"

# ---- 1. checkout-clean-check ------------------------------------------------------------------
if [[ -n "$(git status --porcelain --untracked-files=normal)" ]]; then
    echo "REFUSING: the working tree is not clean; the embedded commitID would not match." >&2
    git status --short >&2
    exit 1
fi
# contrib/{faiss,apache-orc,clucene,...} are submodules; CMake fails without them.
git submodule update --init --recursive
COMMIT="$(git rev-parse HEAD)"
SHORT="$(git rev-parse --short=8 HEAD)"
BRANCH="$(git rev-parse --abbrev-ref HEAD)"
# Version from gen_build_version.sh defaults, e.g. 4.1.5.
VERSION="$(sed -n -E 's/^build_version_(major|minor|patch)="\$\{DORIS_BUILD_VERSION_[A-Z]+-([0-9]+)\}"$/\2/p' \
    gensrc/script/gen_build_version.sh | head -3 | paste -sd.)"
[[ "${VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "cannot read version: '${VERSION}'" >&2; exit 1; }
BE_TAG="be-${VERSION}-${SUFFIX}"
FE_TAG="fe-${VERSION}-${SUFFIX}"
echo "branch=${BRANCH} commit=${COMMIT} version=${VERSION}"
[[ ${BUILD_BE} -eq 1 ]] && echo "BE image: ${REPO}:${BE_TAG}"
[[ ${BUILD_FE} -eq 1 ]] && echo "FE image: ${REPO}:${FE_TAG}"

# Never overwrite a tag that is already in ACR: prod pins tags, a moved tag is an unannounced deploy.
if [[ ${PUSH} -eq 1 ]]; then
    for tag in $([[ ${BUILD_BE} -eq 1 ]] && echo "${BE_TAG}") $([[ ${BUILD_FE} -eq 1 ]] && echo "${FE_TAG}"); do
        if docker manifest inspect "${REPO}:${tag}" >/dev/null 2>&1; then
            echo "REFUSING: ${REPO}:${tag} already exists; pick a new --suffix." >&2
            exit 1
        fi
    done
fi

# ---- 2. build in the toolchain container ------------------------------------------------------
# Same absolute paths inside the container so a git worktree's .git file still resolves; run as
# the invoking user so ./output is not root-owned.
if [[ ${SKIP_BUILD} -eq 0 ]]; then
    GIT_COMMON_DIR="$(cd "$(git rev-parse --git-common-dir)" && pwd)"
    BUILD_ARGS=()
    [[ ${BUILD_BE} -eq 1 ]] && BUILD_ARGS+=(--be)
    [[ ${BUILD_FE} -eq 1 ]] && BUILD_ARGS+=(--fe)
    rm -rf output
    # Maven takes user.home from /etc/passwd (mounted above), not $HOME, so ~/.m2 is mounted at its real
    # path. Mounted at /tmp/.m2 the FE build failed: "Could not create local repository at ~/.m2/repository".
    mkdir -p "${HOME}/.m2"
    docker run --rm --user "$(id -u):$(id -g)" -e HOME=/tmp \
        -v /etc/passwd:/etc/passwd:ro -v /etc/group:/etc/group:ro \
        -v "${ROOT}:${ROOT}" -v "${GIT_COMMON_DIR}:${GIT_COMMON_DIR}:ro" \
        -v "${HOME}/.m2:${HOME}/.m2" \
        -w "${ROOT}" "${TOOLCHAIN_IMAGE}" \
        bash -c "git config --global --add safe.directory '*' && ./build.sh ${BUILD_ARGS[*]} -j ${PARALLEL}"
    echo "${COMMIT}" >output/.spearfish-commit
fi
[[ "$(cat output/.spearfish-commit 2>/dev/null)" == "${COMMIT}" ]] ||
    { echo "output/ was not built from ${COMMIT} by this script; rebuild without --skip-build" >&2; exit 1; }

# The build must still match the tree: a stray edit during the build would also desync the commitID.
if [[ -n "$(git status --porcelain --untracked-files=no)" ]]; then
    echo "REFUSING: tracked files changed during the build." >&2
    exit 1
fi
if [[ ${BUILD_BE} -eq 1 ]] && ! grep -aq "${COMMIT}" output/be/lib/doris_be; then
    echo "REFUSING: output/be/lib/doris_be does not embed ${COMMIT}." >&2
    exit 1
fi

# ---- 3. docker build the runtime images -------------------------------------------------------
LABELS=(--label "org.opencontainers.image.revision=${COMMIT}"
    --label "org.opencontainers.image.source=https://github.com/spearfish-io/doris"
    --label "ai.spearfish.doris.branch=${BRANCH}")
if [[ ${BUILD_BE} -eq 1 ]]; then
    docker build "${LABELS[@]}" --build-arg BASE="${BE_BASE_IMAGE}" -t "${REPO}:${BE_TAG}" -f - . <<'EOF'
ARG BASE
FROM ${BASE}
RUN rm -rf /opt/apache-doris/be/lib /opt/apache-doris/be/bin /opt/apache-doris/be/www /opt/apache-doris/be/dict
COPY output/be/lib /opt/apache-doris/be/lib
COPY output/be/bin /opt/apache-doris/be/bin
COPY output/be/www /opt/apache-doris/be/www
COPY output/be/dict /opt/apache-doris/be/dict
RUN chmod +x /opt/apache-doris/be/bin/*.sh /opt/apache-doris/be/lib/doris_be
EOF
fi
if [[ ${BUILD_FE} -eq 1 ]]; then
    docker build "${LABELS[@]}" --build-arg BASE="${FE_BASE_IMAGE}" -t "${REPO}:${FE_TAG}" -f - . <<'EOF'
ARG BASE
FROM ${BASE}
RUN rm -rf /opt/apache-doris/fe/lib /opt/apache-doris/fe/bin /opt/apache-doris/fe/webroot
COPY output/fe/lib /opt/apache-doris/fe/lib
COPY output/fe/bin /opt/apache-doris/fe/bin
COPY output/fe/webroot /opt/apache-doris/fe/webroot
RUN chmod +x /opt/apache-doris/fe/bin/*.sh
EOF
fi

# ---- 4. push ----------------------------------------------------------------------------------
if [[ ${PUSH} -eq 1 ]]; then
    for tag in $([[ ${BUILD_BE} -eq 1 ]] && echo "${BE_TAG}") $([[ ${BUILD_FE} -eq 1 ]] && echo "${FE_TAG}"); do
        docker push "${REPO}:${tag}"
        # Verify the tag is really in ACR (an expired token once made a "successful" push vanish).
        az acr manifest show-metadata --registry "${REGISTRY%%.*}" --name "apache/doris:${tag}" \
            --query digest -o tsv
    done
fi
echo "done: commit ${SHORT}; check pods log 'Current BE git commitID: ${SHORT}'"
