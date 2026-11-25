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

# Spearfish fork: build the arm64 FE/BE images NATIVELY on a Cobalt node in dev AKS, then (optionally) push
# them and join them with the amd64 images into one multi-arch tag. The arm64 twin of build-images.sh.
#
#   compile in a pod on cirunnerarm -> kaniko on the same node (overlay onto arm64 bases) -> push -> multi-arch
#
# Usage (repo root, clean checkout of the fork branch, HEAD pushed to origin; the pod clones from GitHub):
#   spearfish/build-arm64.sh --suffix p67552-2                    # compile only (~100 min first time)
#   spearfish/build-arm64.sh --suffix p67552-2 --push             # + be/fe-<ver>-p67552-2-arm64
#   spearfish/build-arm64.sh --suffix p67552-2 --push \
#       --amd64-be be-4.1.5-p67552-1 --amd64-fe fe-4.1.5-p67552-2  # + be/fe-<ver>-p67552-2-multiarch
#   spearfish/build-arm64.sh --cleanup                            # delete the namespace (PVC, ~256 GiB)
# Env: REGISTRY (spearfish.azurecr.io), CTX (dev-sf-aks-us-east2), BE_BASE_IMAGE / FE_BASE_IMAGE (the amd64
#   bases build-images.sh uses; their arm64 siblings are imported from Docker Hub BY DIGEST of the same index).
#
# Tags are never overwritten (prod pins tags). The arm64 BE runs only on v6 (Cobalt) ARM: see arm64/build.sh.
# History and numbers: README.md "arm64 images".
set -euo pipefail

REGISTRY="${REGISTRY:-spearfish.azurecr.io}"
REPO="${REGISTRY}/apache/doris"
CTX="${CTX:-dev-sf-aks-us-east2}"
NS=doris-arm-build
BE_BASE_IMAGE="${BE_BASE_IMAGE:-${REGISTRY}/apache/doris:be-4.1.1}"
FE_BASE_IMAGE="${FE_BASE_IMAGE:-${REGISTRY}/apache/doris:fe-4.1.4}"
KANIKO_IMAGE="${KANIKO_IMAGE:-gcr.io/kaniko-project/executor:v1.23.2}"

SUFFIX="" PUSH=0 AMD_BE="" AMD_FE="" CLEANUP=0
while [[ $# -gt 0 ]]; do
    case "$1" in
    --suffix) SUFFIX="$2"; shift 2 ;;
    --push) PUSH=1; shift ;;
    --amd64-be) AMD_BE="$2"; shift 2 ;;
    --amd64-fe) AMD_FE="$2"; shift 2 ;;
    --cleanup) CLEANUP=1; shift ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done
K() { kubectl --context "$CTX" "$@"; }
ts() { echo "=== [$(date -u +%H:%M:%SZ)] $*"; }

if [[ ${CLEANUP} -eq 1 ]]; then
    K delete namespace "$NS" --wait=false
    exit 0
fi
[[ -n "${SUFFIX}" ]] || { echo "--suffix is required (e.g. p67552-2)" >&2; exit 2; }
[[ -z "${AMD_BE}${AMD_FE}" || ( -n "${AMD_BE}" && -n "${AMD_FE}" && ${PUSH} -eq 1 ) ]] ||
    { echo "--amd64-be and --amd64-fe go together, with --push" >&2; exit 2; }

ROOT="$(git rev-parse --show-toplevel)"
cd "${ROOT}"
if [[ -n "$(git status --porcelain --untracked-files=normal)" ]]; then
    echo "REFUSING: the working tree is not clean; the embedded commitID would not match." >&2
    exit 1
fi
COMMIT="$(git rev-parse HEAD)"
BRANCH="$(git rev-parse --abbrev-ref HEAD)"
git fetch -q origin "${BRANCH}"
git merge-base --is-ancestor "${COMMIT}" "origin/${BRANCH}" ||
    { echo "REFUSING: ${COMMIT} is not on origin/${BRANCH}; push it first (the pod clones from GitHub)." >&2; exit 1; }
VERSION="$(sed -n -E 's/^build_version_(major|minor|patch)="\$\{DORIS_BUILD_VERSION_[A-Z]+-([0-9]+)\}"$/\2/p' \
    gensrc/script/gen_build_version.sh | head -3 | paste -sd.)"
[[ "${VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "cannot read version: '${VERSION}'" >&2; exit 1; }
BE_TAG="be-${VERSION}-${SUFFIX}-arm64"
FE_TAG="fe-${VERSION}-${SUFFIX}-arm64"
echo "branch=${BRANCH} commit=${COMMIT} version=${VERSION} -> ${REPO}:{${BE_TAG},${FE_TAG}}"

exists() { docker manifest inspect "${REPO}:$1" >/dev/null 2>&1; }
if [[ ${PUSH} -eq 1 ]]; then
    for t in "${BE_TAG}" "${FE_TAG}" ${AMD_BE:+"be-${VERSION}-${SUFFIX}-multiarch" "fe-${VERSION}-${SUFFIX}-multiarch"}; do
        exists "$t" && { echo "REFUSING: ${REPO}:$t already exists; pick a new --suffix." >&2; exit 1; }
    done
    for t in ${AMD_BE:+"${AMD_BE}" "${AMD_FE}"}; do
        exists "$t" || { echo "amd64 tag ${REPO}:$t not found" >&2; exit 1; }
    done
fi

# ---- 1. compile in the build pod ---------------------------------------------------------------------------
ts "build pod (dev ${CTX}, cirunnerarm)"
K get namespace "$NS" >/dev/null 2>&1 || K create namespace "$NS"
K -n "$NS" create configmap build-script --from-file=build.sh=spearfish/arm64/build.sh --dry-run=client -o yaml | K apply -f - >/dev/null
K -n "$NS" delete pod build --ignore-not-found --wait=true >/dev/null
sed -e "s|__COMMIT__|${COMMIT}|" -e "s|__BRANCH__|${BRANCH}|" spearfish/arm64/build-pod.yaml | K apply -f - >/dev/null
until K -n "$NS" logs build 2>/dev/null | grep -qE '^BUILD-(OK|FAILED)$'; do sleep 60; done
K -n "$NS" logs build | grep -E '^=== ' | tail -4
K -n "$NS" logs build | grep -q '^BUILD-OK$' ||
    { echo "BUILD FAILED. The pod is still up: K -n $NS exec -it build -- bash   (re-run: bash /script/build.sh)" >&2; exit 1; }
[[ ${PUSH} -eq 1 ]] || { ts "compiled; re-run with --push to build and push the images"; exit 0; }

# ---- 2. arm64 bases: the arm64 entries of the SAME upstream indexes our amd64 bases came from ------------------
arm_base() { # <our amd64 base image> -> prints our arm64 base ref, importing it once
    local amd="$1" tag digest up arm
    tag="${amd##*:}"
    digest="$(docker buildx imagetools inspect "$amd" --format '{{json .Manifest}}' | python3 -c 'import sys,json;print(json.load(sys.stdin)["digest"])')"
    up="docker.io/apache/doris:${tag}"
    docker buildx imagetools inspect "$up" | grep -q "$digest" ||
        { echo "upstream ${up} no longer lists our amd64 digest ${digest}; pick the arm64 base by hand" >&2; return 1; }
    arm="$(docker buildx imagetools inspect "$up" | awk '/Name:/{n=$2} /Platform: +linux\/arm64/{print n; exit}')"
    arm="${arm##*@}"
    exists "${tag}-arm64" || az acr import -n "${REGISTRY%%.*}" --source "docker.io/apache/doris@${arm}" --image "apache/doris:${tag}-arm64" -o none
    echo "${REPO}:${tag}-arm64"
}
BE_ARM_BASE="$(arm_base "${BE_BASE_IMAGE}")"
FE_ARM_BASE="$(arm_base "${FE_BASE_IMAGE}")"
echo "arm64 bases: ${BE_ARM_BASE} ${FE_ARM_BASE}"

# ---- 3. kaniko on the same node: overlay exactly like build-images.sh, push --------------------------------
ts "kaniko"
TOK="$(az acr login -n "${REGISTRY%%.*}" --expose-token --query accessToken -o tsv)"
K -n "$NS" create secret docker-registry acr-push --docker-server="${REGISTRY}" \
    --docker-username=00000000-0000-0000-0000-000000000000 --docker-password="${TOK}" --dry-run=client -o yaml | K apply -f - >/dev/null
unset TOK
trap 'K -n "$NS" delete secret acr-push --ignore-not-found >/dev/null' EXIT
K -n "$NS" create configmap dockerfiles --dry-run=client -o yaml \
    --from-literal=be.Dockerfile="$(printf '%s\n' 'ARG BASE' 'FROM ${BASE}' \
        'RUN rm -rf /opt/apache-doris/be/lib /opt/apache-doris/be/bin /opt/apache-doris/be/www /opt/apache-doris/be/dict' \
        'COPY output/be/lib /opt/apache-doris/be/lib' 'COPY output/be/bin /opt/apache-doris/be/bin' \
        'COPY output/be/www /opt/apache-doris/be/www' 'COPY output/be/dict /opt/apache-doris/be/dict' \
        'RUN chmod +x /opt/apache-doris/be/bin/*.sh /opt/apache-doris/be/lib/doris_be')" \
    --from-literal=fe.Dockerfile="$(printf '%s\n' 'ARG BASE' 'FROM ${BASE}' \
        'RUN rm -rf /opt/apache-doris/fe/lib /opt/apache-doris/fe/bin /opt/apache-doris/fe/webroot' \
        'COPY output/fe/lib /opt/apache-doris/fe/lib' 'COPY output/fe/bin /opt/apache-doris/fe/bin' \
        'COPY output/fe/webroot /opt/apache-doris/fe/webroot' 'RUN chmod +x /opt/apache-doris/fe/bin/*.sh')" | K apply -f - >/dev/null
kaniko() { # <be|fe> <base> <tag>
    K -n "$NS" delete pod "kaniko-$1" --ignore-not-found --wait=true >/dev/null
    K apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata: {name: kaniko-$1, namespace: ${NS}}
spec:
  restartPolicy: Never
  nodeSelector: {agentpool: cirunnerarm}
  tolerations: [{key: workload-type, operator: Equal, value: ci-runner, effect: NoSchedule}]
  containers:
  - name: kaniko
    image: ${KANIKO_IMAGE}
    args: [--context=dir:///work/doris, --dockerfile=/df/$1.Dockerfile, --build-arg=BASE=$2,
           --destination=${REPO}:$3, --custom-platform=linux/arm64, --snapshot-mode=redo, --single-snapshot,
           --label=org.opencontainers.image.revision=${COMMIT},
           --label=org.opencontainers.image.source=https://github.com/spearfish-io/doris,
           --label=ai.spearfish.doris.branch=${BRANCH}, --label=ai.spearfish.doris.arch=arm64]
    resources: {requests: {cpu: 100m, memory: 256Mi}, limits: {cpu: "4", memory: 12Gi}}
    volumeMounts: [{name: work, mountPath: /work}, {name: df, mountPath: /df}, {name: docker, mountPath: /kaniko/.docker}]
  volumes:
  - {name: work, persistentVolumeClaim: {claimName: work}}
  - {name: df, configMap: {name: dockerfiles}}
  - {name: docker, secret: {secretName: acr-push, items: [{key: .dockerconfigjson, path: config.json}]}}
EOF
}
kaniko be "${BE_ARM_BASE}" "${BE_TAG}"
kaniko fe "${FE_ARM_BASE}" "${FE_TAG}"
for c in be fe; do
    until [[ "$(K -n "$NS" get pod "kaniko-$c" -o jsonpath='{.status.phase}')" =~ Succeeded|Failed ]]; do sleep 15; done
    [[ "$(K -n "$NS" get pod "kaniko-$c" -o jsonpath='{.status.phase}')" == Succeeded ]] ||
        { K -n "$NS" logs "kaniko-$c" | tail -20; echo "kaniko $c failed" >&2; exit 1; }
done
for t in "${BE_TAG}" "${FE_TAG}"; do
    docker buildx imagetools inspect "${REPO}:$t" | grep -q "linux/arm64" || { echo "${REPO}:$t is not arm64" >&2; exit 1; }
done
ts "pushed ${REPO}:${BE_TAG} ${REPO}:${FE_TAG}"

# ---- 4. multi-arch tags: amd64 half = the exact amd64 image, arm64 half = this build ------------------------
if [[ -n "${AMD_BE}" ]]; then
    docker buildx imagetools create -t "${REPO}:be-${VERSION}-${SUFFIX}-multiarch" "${REPO}:${AMD_BE}" "${REPO}:${BE_TAG}"
    docker buildx imagetools create -t "${REPO}:fe-${VERSION}-${SUFFIX}-multiarch" "${REPO}:${AMD_FE}" "${REPO}:${FE_TAG}"
    for c in be fe; do
        docker buildx imagetools inspect "${REPO}:${c}-${VERSION}-${SUFFIX}-multiarch" | grep -E "Platform: +linux/(amd64|arm64)"
    done
fi
ts "DONE. Free the 256 GiB PVC when you no longer need to resume: spearfish/build-arm64.sh --cleanup"
