#!/bin/sh
# SPDX-FileCopyrightText: Simon A. F. Lund <os@safl.dk>
#
# SPDX-License-Identifier: BSD-3-Clause
#
# CUTLASS, NVIDIA's header-only CUDA GEMM library, through gkcc: its GEMM
# kernel in cutlass_gemm.cu, compiled for sm_86 by clang and by nvcc, must
# be a cubin holding the kernel, its tensor-core MMAs in it. CUTLASS
# (BSD-3-Clause) is fetched at a pinned release and checksum, used, and
# deleted; it is in neither this repository nor the image.
#
#   tests/cutlass.sh IMAGE
set -eu

version=4.8.0
sha256=b7bb2ba0473a5a5d699c62e5feb42caa11cb109ec58ba82ca458af9cd139f39b

image=$1
here=$(cd "$(dirname "$0")" && pwd)
engine=${ENGINE:-docker}
nvidia=$(cat "$here/../nvidia-image")

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
curl -fsSL -o "$work/cutlass.tar.gz" \
    "https://github.com/NVIDIA/cutlass/archive/refs/tags/v$version.tar.gz"
echo "$sha256  $work/cutlass.tar.gz" | sha256sum -c -
mkdir "$work/cutlass"
tar -C "$work/cutlass" --strip-components=1 -xzf "$work/cutlass.tar.gz" \
    "cutlass-$version/include" "cutlass-$version/LICENSE.txt"
cp "$here/cutlass_gemm.cu" "$work"

$engine image inspect "$nvidia" >/dev/null 2>&1 || $engine pull -q "$nvidia" >/dev/null

# clang defines no __CUDACC_VER_*, which CUTLASS gates its paths on; its own
# CMake passes the CUDA's for clang. clang lacks the __nv_atomic_* that
# CUTLASS uses from 12.8, so it gets the paths for 12.6, the CUDA before.
# --expt-relaxed-constexpr is what CUTLASS's CMake gives nvcc.
# shellcheck disable=SC2016 # expanded inside the container
script='
    gkcc --target sm_86 -std=c++17 -I cutlass/include \
        -D__CUDACC_VER_MAJOR__=12 -D__CUDACC_VER_MINOR__=6 cutlass_gemm.cu -o clang.cubin
    gkcc --target sm_86 --cuda-compiler nvcc -std=c++17 --expt-relaxed-constexpr \
        -I cutlass/include cutlass_gemm.cu -o nvcc.cubin
    kobj_check clang.cubin=sm_86:cutlass_gemm nvcc.cubin=sm_86:cutlass_gemm
    for cuda in /opt/nvidia/usr/local/cuda-*; do :; done
    for c in clang nvcc; do
        mma=$("$cuda/bin/nvdisasm" "$c.cubin" | grep -c HMMA || :)
        echo "$c.cubin: $mma HMMA"
        [ "$mma" -gt 0 ]
    done
'
# shellcheck disable=SC2016 # expanded inside the container
tar -C "$work" -cf - cutlass_gemm.cu cutlass |
    $engine run --rm -i --network=none --mount "type=image,src=$nvidia,dst=/opt/nvidia" "$image" \
        sh -euc 'cd "$(mktemp -d)" && tar -xf - && eval "$0"' "$script"
