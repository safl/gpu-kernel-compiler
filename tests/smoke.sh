#!/bin/sh
# SPDX-FileCopyrightText: Simon A. F. Lund <os@safl.dk>
#
# SPDX-License-Identifier: BSD-3-Clause
#
# Smoke-test a built image, no GPU needed: it must build exactly the targets
# ./targets lists; the kernel in each language compiled for each target that
# takes it, by file and by stdin, must be device code for that target holding
# the kernel; a language a target does not take must be refused; an sm_*
# target must fail without NVIDIA's image mounted, naming the mount, and
# build with it, also through PTX.
#
#   tests/smoke.sh IMAGE
set -eu

image=$1
here=$(cd "$(dirname "$0")" && pwd)
engine=${ENGINE:-docker}
nvidia=$(cat "$here/../nvidia-image")

want=$(cat "$here/../targets")
got=$($engine run --rm "$image" gkcc --targets)
if [ "$got" != "$want" ]; then
    printf 'the image builds\n%s\nbut ./targets lists\n%s\n' "$got" "$want" >&2
    exit 1
fi

$engine image inspect "$nvidia" >/dev/null 2>&1 || $engine pull -q "$nvidia" >/dev/null

# Runs $script in the image, without a network, in a directory holding tests/
run() {
    # shellcheck disable=SC2016 # expanded inside the container
    tar -C "$here" -cf - kernel.cl kernel.cu kernel.hip smoke.h prelude.cl printf.cl printf.hip |
        $engine run --rm -i --network=none "$@" sh -euc 'cd "$(mktemp -d)" && tar -xf - && eval "$0"' "$script"
}

# What each script starts with: refuse ARG... fails unless gkcc ARG... does
refuse='
    refuse() {
        if gkcc "$@" -o refused.o 2>refused.err; then
            echo "gkcc $* was accepted" >&2
            exit 1
        fi
        cat refused.err
    }
'

# shellcheck disable=SC2016 # expanded inside the container
script=$refuse'
    gkcc --manifest
    [ "$(gkcc --targets -x cuda)" = "$(gkcc --targets | grep "^sm_")" ]
    [ "$(gkcc --targets -x hip)" = "$(gkcc --targets | grep -e "^sm_" -e "^gfx")" ]
    [ "$(gkcc --targets -x spirv)" = "$(gkcc --targets | grep -v -e "^sm_" -e "^gfx")" ]
    for t in $(gkcc --targets); do
        case $t in sm_*) continue ;; esac
        gkcc --target "$t" --prelude prelude.cl -DSCALE=2.0f kernel.cl -o "$t.o"
        cat prelude.cl kernel.cl | gkcc --target "$t" -D SCALE=2.0f -I "$PWD" - -o "$t-stdin.o"
        set -- "$@" "$t.o=$t:smoke" "$t-stdin.o=$t:smoke"
    done
    # printf, which HIP on gfx* puts in the printf buffer, not through the host call buffer
    for t in $(gkcc --targets); do
        case $t in sm_*) continue ;; esac
        gkcc --target "$t" printf.cl -o "$t-printf.o"
        case $t in
        gfx*)
            # __printf_alloc of ockl linked, not left to a loader that has none
            if /opt/rocm/lib/llvm/bin/llvm-readelf -sW "$t-printf.o" | grep -q " UND __printf_alloc"; then
                echo "$t: OpenCL C printf calls an undefined __printf_alloc" >&2
                exit 1
            fi
            ;;
        esac
        set -- "$@" "$t-printf.o=$t:say"
    done
    for t in $(gkcc --targets -x hip); do
        case $t in sm_*) continue ;; esac
        gkcc --target "$t" printf.hip -o "$t-printf-hip.o"
        /opt/rocm/lib/llvm/bin/llvm-readelf --notes "$t-printf-hip.o" >notes
        grep -q hidden_printf_buffer notes
        if grep -q hidden_hostcall_buffer notes; then echo "$t: HIP printf through the host call buffer" >&2; exit 1; fi
        set -- "$@" "$t-printf-hip.o=$t:say"
    done
    for t in $(gkcc --targets -x hip); do
        case $t in sm_*) continue ;; esac
        gkcc --target "$t" --prelude prelude.cl -DSCALE=2.0f kernel.hip -o "$t-hip.o"
        cat prelude.cl kernel.hip | gkcc --target "$t" -x hip -DSCALE=2.0f - -o "$t-hip-stdin.o"
        set -- "$@" "$t-hip.o=$t:smoke" "$t-hip-stdin.o=$t:smoke"
    done
    # SPIR-V as an OpenCL compiler writes it, here the clang in the image, at
    # the version emu takes; the newer default is for emu to refuse
    clang --target=spirv64v1.2 -cl-std=CL2.0 -O3 -Xclang -finclude-default-header \
        -DSCALE=2.0f -include prelude.cl -c kernel.cl -o kernel.spv
    clang --target=spirv64 -cl-std=CL2.0 -O3 -Xclang -finclude-default-header \
        -DSCALE=2.0f -include prelude.cl -c kernel.cl -o kernel-default.spv
    for t in $(gkcc --targets -x spirv); do
        gkcc --target "$t" kernel.spv -o "$t-spv.o"
        gkcc --target "$t" -x spirv - -o "$t-spv-stdin.o" <kernel.spv
        set -- "$@" "$t-spv.o=$t:smoke" "$t-spv-stdin.o=$t:smoke"
    done
    gkcc --target dg2 kernel-default.spv -o dg2-spv-default.o
    set -- "$@" dg2-spv-default.o=dg2:smoke
    if gkcc --target sm_86 --prelude prelude.cl -DSCALE=2.0f kernel.cl -o sm_86.o 2>err; then
        echo "sm_86 built without NVIDIA image mounted" >&2
        exit 1
    fi
    cat err
    grep -qF -- "--mount type=image,src=$NVIDIA,dst=/opt/nvidia" err
    refuse --target sm_86 -DSCALE=2.0f -DOFFSET=1.0f kernel.cu
    grep -qF -- "--mount type=image,src=$NVIDIA,dst=/opt/nvidia" refused.err
    refuse --target gfx900 kernel.spv
    refuse --target sm_86 kernel.spv
    refuse --target dg2 --prelude prelude.cl kernel.spv
    refuse --target dg2 -DSCALE=2.0f kernel.spv
    refuse --target emu -cl-fast-relaxed-math kernel.spv
    refuse --target emu kernel-default.spv
    refuse --target emu -x spirv kernel.cl
    refuse --target emu -DSCALE=2.0f -DOFFSET=1.0f kernel.hip
    refuse --target dg2 -x fortran kernel.cl
    refuse --target sm_86 --cuda-compiler nvcc -DSCALE=2.0f -DOFFSET=1.0f kernel.cu
    refuse --target sm_86 --cuda-compiler nvcc -DSCALE=2.0f -DOFFSET=1.0f kernel.hip
    refuse --target sm_86 --cuda-compiler icc -DSCALE=2.0f -DOFFSET=1.0f kernel.cu
    refuse --target gfx1101 -DSCALE=2.0f -DOFFSET=1.0f kernel.cu
    refuse --target dg2 -x cuda -DSCALE=2.0f -DOFFSET=1.0f kernel.cu
    refuse --target dg2 -DSCALE=2.0f -DOFFSET=1.0f kernel.hip
    refuse --target sm_120 -DSCALE=2.0f -DOFFSET=1.0f kernel.hip
    kobj_check "$@"
'
run -e NVIDIA="$nvidia" "$image"

# shellcheck disable=SC2016
script=$refuse'
    for t in $(gkcc --targets); do
        case $t in sm_*) ;; *) continue ;; esac
        gkcc --target "$t" --prelude prelude.cl -DSCALE=2.0f kernel.cl -o "$t.o"
        cat prelude.cl kernel.cl | gkcc --target "$t" -DSCALE=2.0f -I "$PWD" - -o "$t-stdin.o"
        gkcc --target "$t" --prelude prelude.cl -DSCALE=2.0f -S kernel.cl -o "$t.ptx"
        gkcc --target "$t" --ptxas --maxrregcount=32 "$t.ptx" -o "$t-ptx.o"
        set -- "$@" "$t.o=$t:smoke" "$t-stdin.o=$t:smoke" "$t-ptx.o=$t:smoke"
    done
    # OpenCL C printf, a call of vprintf through the shim gkcc links, which the cubin leaves to the driver
    for t in $(gkcc --targets); do
        case $t in sm_*) ;; *) continue ;; esac
        gkcc --target "$t" printf.cl -o "$t-printf.o"
        gkcc --target "$t" -S printf.cl -o "$t-printf.ptx"
        grep -q "call.uni (retval0), vprintf," "$t-printf.ptx"
        if grep -qE "^\\.extern \\.func.* printf$" "$t-printf.ptx"; then echo "$t: printf left unresolved" >&2; exit 1; fi
        set -- "$@" "$t-printf.o=$t:say"
    done
    for t in $(gkcc --targets -x cuda); do
        gkcc --target "$t" --prelude prelude.cl -DSCALE=2.0f kernel.cu -o "$t-cu.o"
        cat prelude.cl kernel.cu | gkcc --target "$t" -x cuda -DSCALE=2.0f - -o "$t-cu-stdin.o"
        gkcc --target "$t" --prelude prelude.cl -DSCALE=2.0f -S kernel.cu -o "$t-cu.ptx"
        gkcc --target "$t" "$t-cu.ptx" -o "$t-cu-ptx.o"
        set -- "$@" "$t-cu.o=$t:smoke" "$t-cu-stdin.o=$t:smoke" "$t-cu-ptx.o=$t:smoke"
        gkcc --target "$t" --cuda-compiler nvcc --prelude prelude.cl -DSCALE=2.0f kernel.cu \
            -o "$t-nvcc.o"
        cat prelude.cl kernel.cu |
            gkcc --target "$t" --cuda-compiler=nvcc -x cuda -DSCALE=2.0f - -o "$t-nvcc-stdin.o"
        gkcc --target "$t" --cuda-compiler nvcc --prelude prelude.cl -DSCALE=2.0f -S kernel.cu \
            -o "$t-nvcc.ptx"
        gkcc --target "$t" "$t-nvcc.ptx" -o "$t-nvcc-ptx.o"
        set -- "$@" "$t-nvcc.o=$t:smoke" "$t-nvcc-stdin.o=$t:smoke" "$t-nvcc-ptx.o=$t:smoke"
    done
    for t in $(gkcc --targets -x hip); do
        case $t in sm_*) ;; *) continue ;; esac
        gkcc --target "$t" --prelude prelude.cl -DSCALE=2.0f kernel.hip -o "$t-hip.o"
        cat prelude.cl kernel.hip | gkcc --target "$t" -x hip -DSCALE=2.0f - -o "$t-hip-stdin.o"
        set -- "$@" "$t-hip.o=$t:smoke" "$t-hip-stdin.o=$t:smoke"
    done
    kobj_check "$@"
'
run --mount "type=image,src=$nvidia,dst=/opt/nvidia" "$image"
