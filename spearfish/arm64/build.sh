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

# Spearfish fork: the arm64 BE/FE compile. Runs INSIDE the build pod (spearfish/arm64/build-pod.yaml) on a
# Cobalt (Neoverse N2, v6) node, started by spearfish/build-arm64.sh. Everything lives on the /work PVC, so a
# restarted pod resumes: tools, source and the third-party tree are reused.
#
# Env: COMMIT (required), BRANCH (required), J (parallelism, default 8), TP_CONTINUE (resume the third-party
# build from that package, e.g. aws_sdk).
#
# Three settings make arm64 work. Each one cost a failed build to find (2026-11-25):
#   DISABLE_BUILD_AZURE=OFF     env.sh:104 defaults it ON for aarch64/Darwin. That is the ONLY reason upstream's
#                               arm64 images have no Azure and abort on the first ADLS read
#                               ("BE is not compiled with azure support").
#   VCPKG_FORCE_SYSTEM_BINARIES vcpkg (builds the Azure SDK) refuses to run on ARM Linux without it.
#   ARM_MARCH=armv9-a+bf16+i8mm OpenBLAS (ANN index) has no DYNAMIC_ARCH on aarch64, so it targets the BUILD CPU;
#                               the default armv8-a+crc lacks SVE and its SVE kernels fail to compile. The
#                               binary therefore needs v6 (Cobalt) ARM: on older ARM (v5 Altra) it SIGILLs.
set -euo pipefail
: "${COMMIT:?}" "${BRANCH:?}"
T0=$(date +%s)
ts() { echo "=== [$(date -u +%H:%M:%SZ)] +$((($(date +%s) - T0) / 60))m $*"; }
J=${J:-8}
export DEBIAN_FRONTEND=noninteractive

ts "apt"
apt-get update -qq
apt-get install -y -qq git wget curl ca-certificates xz-utils bzip2 unzip zip patch byacc bison flex \
    automake autoconf libtool make python3 python-is-python3 file pkg-config gettext autopoint perl rsync \
    libncurses-dev gcc g++ >/dev/null

# Toolchain = the versions in the x86 build-env image, aarch64 builds.
T=/work/tools
mkdir -p $T
if [ ! -x $T/ldb/test/a ]; then # the installer self-tests by writing test/a
    ts "ldb toolchain v0.25 aarch64"
    rm -rf $T/ldb
    wget -q https://github.com/amosbird/ldb_toolchain_gen/releases/download/v0.25/ldb_toolchain_gen_aarch64.sh -O /tmp/ldb.sh
    # MUST be bash: under sh it prints "Unknown architecture", unpacks without patching, and clang later fails
    # with "libclang-cpp.so.20.1 not found".
    bash /tmp/ldb.sh $T/ldb >/dev/null
fi
if [ ! -x $T/jdk17/bin/java ]; then
    ts "jdk 17"
    mkdir -p $T/jdk17
    curl -sL https://api.adoptium.net/v3/binary/latest/17/ga/linux/aarch64/jdk/hotspot/normal/eclipse | tar xz -C $T/jdk17 --strip-components=1
fi
if [ ! -x $T/maven/bin/mvn ]; then
    ts "maven 3.9.9"
    mkdir -p $T/maven
    curl -sL https://archive.apache.org/dist/maven/maven-3/3.9.9/binaries/apache-maven-3.9.9-bin.tar.gz | tar xz -C $T/maven --strip-components=1
fi
if [ ! -x $T/node/bin/node ]; then
    ts "node 22.12.0"
    mkdir -p $T/node
    curl -sL https://nodejs.org/dist/v22.12.0/node-v22.12.0-linux-arm64.tar.xz | tar xJ -C $T/node --strip-components=1
fi
export CARGO_HOME=$T/cargo RUSTUP_HOME=$T/rustup
if [ ! -x $CARGO_HOME/bin/cargo ]; then
    ts "rust 1.94.0" # lance-c requires 1.94
    curl -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal --default-toolchain 1.94.0 --no-modify-path >/dev/null
fi
export JAVA_HOME=$T/jdk17 MAVEN_HOME=$T/maven
export PATH=$CARGO_HOME/bin:$T/node/bin:$T/maven/bin:$T/ldb/bin:$JAVA_HOME/bin:$PATH
export CARGO_TARGET_AARCH64_UNKNOWN_LINUX_GNU_LINKER=/usr/bin/gcc
export REPOSITORY_URL=https://doris-thirdparty-repo.bj.bcebos.com/thirdparty
export USE_AVX2=0 HOME=/work/home VCPKG_FORCE_SYSTEM_BINARIES=1
mkdir -p "$HOME"
export DISABLE_BUILD_AZURE=OFF
export ARM_MARCH=armv9-a+bf16+i8mm

S=/work/doris
if [ ! -d $S/.git ]; then
    ts "clone"
    git clone -q --branch "$BRANCH" https://github.com/spearfish-io/doris.git $S
fi
cd $S
git config --global --add safe.directory '*'
git fetch -q origin "$BRANCH"
git checkout -q "$COMMIT"
git submodule update --init --recursive -q
ts "commit $(git rev-parse HEAD)"
export DORIS_THIRDPARTY=$S/thirdparty

if [ ! -f thirdparty/.done ]; then
    ts "thirdparty (-j $J)" # ~25 min on 8 cores
    bash thirdparty/build-thirdparty.sh -j "$J" ${TP_CONTINUE:+--continue $TP_CONTINUE}
    touch thirdparty/.done
fi
if ! ls thirdparty/installed/lib*/ | grep -qi azure; then
    ts "thirdparty: azure"
    bash thirdparty/build-thirdparty.sh -j "$J" azure
fi
ts "azure libs:"
ls thirdparty/installed/lib*/ | grep -i azure || { echo "NO AZURE LIBS: refusing to build a BE that cannot read ADLS"; exit 1; }

ts "build.sh --be --fe (-j $J)" # ~76 min on 8 cores
rm -rf output
./build.sh --be --fe -j "$J"
echo "$COMMIT" >output/.spearfish-commit

ts "verify"
file output/be/lib/doris_be | grep -q "ARM aarch64" || { echo "doris_be is not aarch64"; exit 1; }
grep -aq "$COMMIT" output/be/lib/doris_be || { echo "doris_be does not embed $COMMIT"; exit 1; }
if strings output/be/lib/doris_be | grep -q "is not compiled with azure support"; then
    echo "doris_be was compiled WITHOUT Azure"
    exit 1
fi
ts "DONE"
