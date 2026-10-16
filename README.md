<!--
SPDX-FileCopyrightText: Simon A. F. Lund <os@safl.dk>

SPDX-License-Identifier: BSD-3-Clause
-->

# gpu-kernel-compiler

[![image](https://github.com/safl/gpu-kernel-compiler/actions/workflows/image.yml/badge.svg)](https://github.com/safl/gpu-kernel-compiler/actions/workflows/image.yml)
[![lint](https://github.com/safl/gpu-kernel-compiler/actions/workflows/lint.yml/badge.svg)](https://github.com/safl/gpu-kernel-compiler/actions/workflows/lint.yml)
[![REUSE status](https://api.reuse.software/badge/github.com/safl/gpu-kernel-compiler)](https://api.reuse.software/info/github.com/safl/gpu-kernel-compiler)

A container image that compiles GPU kernels ahead of time, for AMD, Intel and
NVIDIA GPUs, on any x86-64 machine, with no GPU. `gkcc` is its compiler
driver: one command line for every target, so a build calls each vendor the
same way and gets the same kernel object whichever machine ran it. One
target, `emu`, is no GPU: it is SPIR-V for PoCL's CPU device, so a kernel
built for the GPUs runs, through OpenCL, where there is none.

```
ghcr.io/safl/gpu-kernel-compiler
```

| Target    | Device              | Toolchain                                | Output          |
|-----------|---------------------|------------------------------------------|-----------------|
| `sm_86`   | NVIDIA Ampere       | LLVM clang 22 to PTX, NVIDIA's `ptxas`    | cubin           |
| `sm_120`  | NVIDIA Blackwell    | LLVM clang 22 to PTX, NVIDIA's `ptxas`    | cubin           |
| `gfx900`  | AMD Vega 10         | ROCm's clang and device libraries         | AMD code object |
| `gfx1012` | AMD Navi 14         | ROCm's clang and device libraries         | AMD code object |
| `gfx1101` | AMD Navi 32         | ROCm's clang and device libraries         | AMD code object |
| `dg2`     | Intel Arc A-series  | Intel's `ocloc` and IGC                   | zebin           |
| `emu`     | PoCL's CPU device   | LLVM clang 22's SPIR-V backend            | SPIR-V 1.2      |

The input languages, `-x` or by the file's extension:

| `-x`    | Language             | Extension           | Targets        |
|---------|----------------------|---------------------|----------------|
| `cl`    | OpenCL C             | `.cl`, and the rest | all            |
| `ptx`   | PTX                  | `.ptx`              | `sm_*`         |
| `cuda`  | CUDA C++ device code | `.cu`               | `sm_*`         |
| `hip`   | HIP C++ device code  | `.hip`              | `sm_*`, `gfx*` |
| `spirv` | OpenCL SPIR-V        | `.spv`              | `dg2`, `emu`   |

A target refuses a language it does not take, naming why.
`gkcc --targets -x LANG` lists the targets that take `LANG`.

## gkcc

```
gkcc --target TARGET [OPTION...] IN -o OUT
gkcc --targets [-x LANG]
gkcc --manifest
```

`IN` may be `-` for stdin. The defaults are `-cl-std=CL2.0 -O3` for `cl` and
`-O3` for `cuda` and `hip`.

| Option             | Meaning                                                              |
|--------------------|----------------------------------------------------------------------|
| `-DNAME[=VAL]`, `-IDIR`, `-cl-*` | build options, for every target; for `spirv`, only `-cl-*` and only for `dg2` |
| `-cl-intel-*`      | to `ocloc`'s `-internal_options`, for `dg2`                          |
| `--prelude FILE`   | prepended to the source, repeatable, not for `spirv`; `IN`'s directory stays on the include path |
| `-x LANG`          | the input language, see above                                        |
| `-S`               | `sm_*`: stop at PTX, which `gkcc` assembles when given back          |
| `--ptxas OPT`      | `sm_*`: passed to `ptxas`, repeatable                                |
| `--cuda-compiler C` | `cuda`: `clang`, the default, or `nvcc`                             |
| anything else      | passed to clang, or nvcc, as is, for `sm_*` and `gfx*`               |

clang has no OpenCL builtin library for nvptx64, so an `sm_*` kernel brings
its own work-item functions, typically in a prelude. NVIDIA's libdevice is
linked, so its `__nv_*` math functions are there.

CUDA is compiled by clang, device code only, with the headers, CCCL and
libdevice of the mounted CUDA, to PTX that `ptxas` assembles. A kernel meant
to be found by name is `extern "C"`; otherwise its name is C++-mangled. The
mounted CUDA is newer than clang 22 knows of, which clang compiles all the
same, but clang does not define `__CUDACC_VER_MAJOR__` and lacks some of
what nvcc's newest headers give, such as CUDA 12.8's `__nv_atomic_*`.

`--cuda-compiler nvcc` compiles CUDA with NVIDIA's nvcc instead, from the
mounted image, to a cubin, or to PTX with `-S`. nvcc runs a host compiler on
device code too. NVIDIA's image has one, but it does not run outside that
image's root, so this image carries g++ 15, a version CUDA 13 supports, for
nvcc to use.

HIP for a `gfx*` target is compiled by ROCm's clang, device code only, to
the linked code object `hipcc --genco` makes. For an `sm_*` target it is
what HIP on NVIDIA is, CUDA with HIP's headers, which take their
`nvidia_detail` side, compiled as CUDA above. The headers are HIP's, from
ROCm's `amdrocm-runtime-dev` package, and hipother's `nvidia_detail`, from
the same ROCm release's source; nothing else of either package is in the
image.

SPIR-V, as an OpenCL compiler writes it, is compiled by `ocloc` for `dg2`.
It is not implemented for `gfx*` and `sm_*`. The way there would be
SPIRV-LLVM-Translator, SPIR-V to LLVM IR, then clang for the target, but the
IR the translator writes keeps SPIR's address spaces and calling
conventions: amdgcn rejects it, and nvptx compiles it wrong, loading a
generic pointer as constant memory and emitting the kernel as a plain
function. ROCm 10.1's translator can remap the address spaces
(`--spirv-addrspace-map`) but not retarget the module; Ubuntu's
`llvm-spirv-21` can do neither. `--spirv-target-triple`, which retargets it
for amdgcn, is in newer translators than either.

For `emu`, SPIR-V is checked and copied, PoCL compiling it when it is
loaded. What `gkcc` checks is that PoCL takes it: a module for OpenCL with
64-bit addresses, at SPIR-V 1.2 at most, the newest PoCL 6.0 lists. clang's
SPIR-V backend writes 1.4 unless told otherwise, so `gkcc` asks it for 1.2
when it compiles OpenCL C for `emu`, and refuses a newer module given as
`-x spirv`.

`gkcc --manifest` prints what the image holds, one component a line: its
name, its version, and what the tool reports of itself. The license texts of
what is in it are in `/usr/share/gpu-kernel-compiler/licenses`.

## NVIDIA

Nothing of NVIDIA's is in this repository or in the image. The CUDA EULA does
not let anyone redistribute `ptxas`, and the license of NVIDIA's container
images does not let us publish a derivative of one under our terms. So
`gkcc` uses NVIDIA's own `ptxas`, libdevice, CUDA headers and nvcc from
NVIDIA's image, mounted read-only at `/opt/nvidia` when the container runs.
Nothing is copied out of it or fetched. Using it is between you and NVIDIA,
under their license.

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

`make smoke` compiles the kernel in each language, such as
[tests/kernel.cl](tests/kernel.cl), for every target that takes it, by file,
by stdin and through PTX, with and without NVIDIA's image mounted, and checks
with [kobj_check.py](kobj_check.py) that each output is device code for its
target holding the kernel. It also checks that a target refuses a language
it does not take, and, in [tests/cutlass.sh](tests/cutlass.sh), that a
CUTLASS GEMM kernel compiles for `sm_86` with clang and with nvcc, its
tensor-core instructions in the cubin. CUTLASS (BSD-3-Clause) is fetched for
the test at a pinned release and checksum; it is in neither this repository
nor the image. Every version in the [Dockerfile](Dockerfile) is pinned: the base
image by digest, ROCm and clang by package version, IGC and ocloc by
checksum. CI builds and smoke-tests the image when any of it changes, and
publishes it from `main` as `latest` and as the commit.

## License

BSD-3-Clause, see [LICENSE](LICENSE). The image also holds ROCm's LLVM
(Apache-2.0 WITH LLVM-exception), ROCm's device libraries (NCSA), HIP's
headers (MIT), Intel's IGC and compute-runtime (MIT), and Ubuntu's packages
under their own licenses.
