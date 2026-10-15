#!/bin/sh
# SPDX-FileCopyrightText: Simon A. F. Lund <os@safl.dk>
#
# SPDX-License-Identifier: BSD-3-Clause
#
# Smoke-test a built image, no GPU needed: it must build exactly the targets
# ./targets lists; kernel.cl compiled for each, by file and by stdin, must be
# device code for that target; an sm_* target must fail without NVIDIA's
# image mounted, naming the mount, and build with it, also through PTX.
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
    tar -C "$here" -cf - kernel.cl smoke.h prelude.cl |
        $engine run --rm -i --network=none "$@" sh -euc 'cd "$(mktemp -d)" && tar -xf - && eval "$0"' "$script"
}

# shellcheck disable=SC2016 # expanded inside the container
script='
    gkcc --manifest
    for t in $(gkcc --targets); do
        case $t in sm_*) continue ;; esac
        gkcc --target "$t" --prelude prelude.cl -DSCALE=2.0f kernel.cl -o "$t.o"
        cat prelude.cl kernel.cl | gkcc --target "$t" -D SCALE=2.0f -I "$PWD" - -o "$t-stdin.o"
        set -- "$@" "$t.o=$t" "$t-stdin.o=$t"
    done
    if gkcc --target sm_86 --prelude prelude.cl -DSCALE=2.0f kernel.cl -o sm_86.o 2>err; then
        echo "sm_86 built without NVIDIA image mounted" >&2
        exit 1
    fi
    cat err
    if gkcc --target gfx900 -x spirv kernel.cl -o x.o; then
        echo "-x spirv accepted, which gkcc does not take yet" >&2
        exit 1
    fi
    grep -qF -- "--mount type=image,src=$NVIDIA,dst=/opt/nvidia" err
    kobj_check "$@"
'
run -e NVIDIA="$nvidia" "$image"

# shellcheck disable=SC2016
script='
    for t in $(gkcc --targets); do
        case $t in sm_*) ;; *) continue ;; esac
        gkcc --target "$t" --prelude prelude.cl -DSCALE=2.0f kernel.cl -o "$t.o"
        cat prelude.cl kernel.cl | gkcc --target "$t" -DSCALE=2.0f -I "$PWD" - -o "$t-stdin.o"
        gkcc --target "$t" --prelude prelude.cl -DSCALE=2.0f -S kernel.cl -o "$t.ptx"
        gkcc --target "$t" --ptxas --maxrregcount=32 "$t.ptx" -o "$t-ptx.o"
        set -- "$@" "$t.o=$t" "$t-stdin.o=$t" "$t-ptx.o=$t"
    done
    kobj_check "$@"
'
run --mount "type=image,src=$nvidia,dst=/opt/nvidia" "$image"
