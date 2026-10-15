<!--
SPDX-FileCopyrightText: Simon A. F. Lund <os@safl.dk>

SPDX-License-Identifier: BSD-3-Clause
-->

# gpu-kernel-compiler

A container image that compiles GPU kernels ahead of time, for AMD, Intel and
NVIDIA GPUs, on any x86-64 machine, with no GPU. `gkcc` is its compiler
driver: one command line for every target, so a build calls each vendor the
same way and gets the same kernel object whichever machine ran it.

```
ghcr.io/safl/gpu-kernel-compiler
```

| Target    | Device              | Toolchain                                | Output          |
|-----------|---------------------|------------------------------------------|-----------------|
| `sm_86`   | NVIDIA Ampere       | LLVM clang 21 to PTX, NVIDIA's `ptxas`    | cubin           |
| `sm_120`  | NVIDIA Blackwell    | LLVM clang 21 to PTX, NVIDIA's `ptxas`    | cubin           |
| `gfx900`  | AMD Vega 10         | ROCm's clang and device libraries         | AMD code object |
| `gfx1012` | AMD Navi 14         | ROCm's clang and device libraries         | AMD code object |
| `gfx1101` | AMD Navi 32         | ROCm's clang and device libraries         | AMD code object |
| `dg2`     | Intel Arc A-series  | Intel's `ocloc` and IGC                   | zebin           |

The input language is OpenCL C. Other inputs, such as SPIR-V, may come later
as further values of `-x`; none is implemented.

## gkcc

```
gkcc --target TARGET [OPTION...] IN -o OUT
gkcc --targets
gkcc --manifest
```

`IN` may be `-` for stdin. The defaults are `-cl-std=CL2.0 -O3`.

| Option             | Meaning                                                              |
|--------------------|----------------------------------------------------------------------|
| `-DNAME[=VAL]`, `-IDIR`, `-cl-*` | OpenCL build options, for every target            |
| `-cl-intel-*`      | to `ocloc`'s `-internal_options`, for `dg2`                          |
| `--prelude FILE`   | prepended to the source, repeatable; `IN`'s directory stays on the include path |
| `-x LANG`          | `cl` (the default), or `ptx` for `sm_*` (the default for `*.ptx`)    |
| `-S`               | `sm_*`: stop at PTX, which `gkcc` assembles when given back          |
| `--ptxas OPT`      | `sm_*`: passed to `ptxas`, repeatable                                |
| anything else      | passed to clang as is, for `sm_*` and `gfx*`                         |

clang has no OpenCL builtin library for nvptx64, so an `sm_*` kernel brings
its own work-item functions, typically in a prelude. NVIDIA's libdevice is
linked, so its `__nv_*` math functions are there.

`gkcc --manifest` prints what the image holds, one component a line: its
name, its version, and what the tool reports of itself. The license texts of
what is in it are in `/usr/share/gpu-kernel-compiler/licenses`.

## NVIDIA

Nothing of NVIDIA's is in this repository or in the image. The CUDA EULA does
not let anyone redistribute `ptxas`, and the license of NVIDIA's container
images does not let us publish a derivative of one under our terms. So
`gkcc` uses NVIDIA's own `ptxas` and libdevice from NVIDIA's image, mounted
read-only at `/opt/nvidia` when the container runs. Nothing is copied out of
it or fetched. Using it is between you and NVIDIA, under their license.

The image to mount is pinned in [nvidia-image](nvidia-image), which the smoke
test reads too, so the one tested is the one callers mount:

```
nvidia=$(cat nvidia-image)
podman pull "$nvidia"
podman run --rm --network=none -v "$PWD:/work" \
    --mount "type=image,src=$nvidia,dst=/opt/nvidia" \
    ghcr.io/safl/gpu-kernel-compiler \
    gkcc --target sm_120 --prelude prelude.cl kernel.cl -o kernel.o
```

Without the mount, an `sm_*` target stops and names the mount to add. AMD and
Intel targets never need it:

```
docker run --rm -v "$PWD:/work" ghcr.io/safl/gpu-kernel-compiler \
    gkcc --target gfx1101 -I include kernel.cl -o kernel.o
```

Image mounts work in Podman. Docker has them since Engine 28.0, but only with
the containerd image store, which Docker 28, the version on GitHub's hosted
runners, does not enable by default; CI uses Podman for that.

## Building

```
make build smoke            # ENGINE=podman for Podman
make test                   # kobj_check's unit tests
```

`make smoke` compiles [tests/kernel.cl](tests/kernel.cl) for every target, by
file, by stdin and through PTX, with and without NVIDIA's image mounted, and
checks with [kobj_check.py](kobj_check.py) that each output is device code for
its target. Every version in the [Dockerfile](Dockerfile) is pinned: the base
image by digest, ROCm and clang by package version, IGC and ocloc by
checksum. CI builds and smoke-tests the image when any of it changes, and
publishes it from `main` as `latest` and as the commit.

## License

BSD-3-Clause, see [LICENSE](LICENSE). The image also holds ROCm's LLVM
(Apache-2.0 WITH LLVM-exception), ROCm's device libraries (NCSA), Intel's IGC
and compute-runtime (MIT), and Ubuntu's packages under their own licenses.
