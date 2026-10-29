<!--
SPDX-FileCopyrightText: Simon A. F. Lund <os@safl.dk>

SPDX-License-Identifier: BSD-3-Clause
-->

# Changelog

What changed in each release of the image and of `gkcc`, newest first, in a
section named for the version, `## X.Y.Z`. The versions follow
[Semantic Versioning](https://semver.org), as the README's Versioning section
says what that means here. `main` between releases is a preview of the next.

## 1.0.0

The first release, of what the image has done since it was first published
and builds kernels for in use:

* targets `sm_75`, `sm_86`, `sm_120`, `gfx900`, `gfx1012`, `gfx1101`, `dg2`
  and `emu`;
* OpenCL C for every target, PTX and CUDA for `sm_*`, HIP for `sm_*` and
  `gfx*`, OpenCL SPIR-V for `dg2` and `emu`;
* CUDA compiled by clang, or by nvcc with `--cuda-compiler nvcc`;
* OpenCL C for `gfx*` linked into a shared object, as HIP's code objects are;
* printf on every target without host calls the runtime cannot serve;
* NVIDIA's tools mounted from NVIDIA's image at run time, none in the image;
* `gkcc --targets`, `--manifest` and, new in this release, `--version`.
