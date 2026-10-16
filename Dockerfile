# SPDX-FileCopyrightText: Simon A. F. Lund <os@safl.dk>
#
# SPDX-License-Identifier: BSD-3-Clause
#
# GPU kernels to device code for AMD, Intel and NVIDIA GPUs, no GPU needed:
# ROCm's clang and device libraries, Intel's ocloc and IGC, and LLVM's clang
# for nvptx64. Nothing of NVIDIA's is in it; gkcc runs ptxas and libdevice,
# and reads CUDA's headers, from NVIDIA's own image, mounted at run time
# (see README.md).

FROM docker.io/library/ubuntu:26.04@sha256:88a381d5b5eeb2b35d3ad70925a362c37ce569daf43ede89ff818ec20e4d3794

# clang compiles CUDA with the headers of the CUDA it is given, those of the
# NVIDIA image nvidia-image pins; clang 21 cannot parse CUDA 13's, 22 can.
ARG CLANG_MAJOR=22
ARG CLANG_VERSION=1:22.1.2-1ubuntu1

# AMD's TheRock-based ROCm packages; rocmradeon 26.16 is the first with a
# release (not ~pre) build for resolute.
ARG ROCM_REPO=https://repo.radeon.com/rocmradeon/apt/26.16
ARG ROCM_SERIES=10.1
ARG ROCM_VERSION=10.1.0-3
ARG ROCM_KEY_SHA256=2de99e2354646a90d9903e2a669fc4e36b02c1bbff7075c481e12d7edab2c88b
# The ROCm packages carry no license texts, so they come from the source tag
ARG ROCM_SOURCE_TAG=therock-10.1
ARG ROCM_LLVM_LICENSE_SHA256=8d85c1057d742e597985c7d4e6320b015a9139385cff4cbae06ffc0ebe89afee
ARG ROCM_DEVICE_LIBS_LICENSE_SHA256=a4e8e3ba6e9255928a29d3085f929de402e61413cb0c49276e16b558effa8a2a
# HIP and hipother, its NVIDIA side, share one MIT text
ARG HIP_LICENSE_SHA256=b185aaa652b0bf066c37a0d6314ce4bf4521e4a3c9bf46edd2f6a777ac522223

ARG IGC_VERSION=2.41.5
ARG IGC_BUILD=22716
ARG IGC_CORE_SHA256=0a6e64a663ae65a0fa02d6912ae3b6b37cf85b90c21cc423fd9fef70aaf4f628
ARG IGC_OPENCL_SHA256=779e1b9e88098eb25711e9a8f67c2752665bad22f134aa40ed5649f6e1b87058
ARG IGC_LICENSE_SHA256=8b2cd951f44d1fbe6adcf112e1f3a0cc989c89c8889a1c48dea5f7ece10ba9c9
ARG NEO_VERSION=26.35.39758.10
ARG OCLOC_SHA256=c64bff586edf2bd9b49f3e4c9c2be25e05c43466e4dafa2a2c3948d498c736b7
ARG NEO_LICENSE_SHA256=987a002c6c9eb75290d9937735641ef4f4b670591ee79e1ac8edebe16a81872e

SHELL ["/bin/bash", "-euo", "pipefail", "-c"]

# clang is pinned; what it runs on, and make for builds run inside the
# image, follow the archive.
# hadolint ignore=DL3008
RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        ca-certificates curl gnupg make python3 "clang-${CLANG_MAJOR}=${CLANG_VERSION}" \
 && ln -s "clang-${CLANG_MAJOR}" /usr/bin/clang \
 && rm -rf /var/lib/apt/lists/*

# Only ROCm's LLVM package and what it depends on, not the math libraries a
# ROCm install pulls in. The meta packages left out are what would point
# /opt/rocm/{lib,bin,...} at core-<series>, so link them here.
# hadolint ignore=DL3008
RUN curl -fsSL https://repo.radeon.com/rocm/rocm.gpg.key -o /tmp/rocm.gpg.key \
 && echo "${ROCM_KEY_SHA256}  /tmp/rocm.gpg.key" | sha256sum -c - \
 && gpg --dearmor -o /etc/apt/keyrings/rocm.gpg /tmp/rocm.gpg.key \
 && rm /tmp/rocm.gpg.key \
 && echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/rocm.gpg] ${ROCM_REPO} resolute main" \
        > /etc/apt/sources.list.d/rocm.list \
 && apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        "amdrocm-llvm${ROCM_SERIES}=${ROCM_VERSION}" \
        "amdrocm-runtime${ROCM_SERIES}=${ROCM_VERSION}" \
        "amdrocm-sysdeps${ROCM_SERIES}=${ROCM_VERSION}" \
        "amdrocm-base${ROCM_SERIES}=${ROCM_VERSION}" \
 && rm -rf /var/lib/apt/lists/* \
 && for e in /opt/rocm/core-"${ROCM_SERIES}"/*; do ln -s "${e#/opt/rocm/}" "/opt/rocm/${e##*/}"; done

# HIP's headers are all HIP device code needs, so they come out of their
# package rather than with it: it depends on ROCm's LLVM development files,
# 2 GB. HIP for NVIDIA is CUDA under HIP's names, in hipother's nvidia_detail
# headers, which no package of this ROCm carries; they come from its source
# tag, checked against hipother.sha256.
COPY hipother.sha256 /tmp/
# hadolint ignore=DL3003
RUN mkdir /tmp/hip && cd /tmp/hip \
 && apt-get update \
 && apt-get download "amdrocm-runtime-dev${ROCM_SERIES}=${ROCM_VERSION}" \
 && rm -rf /var/lib/apt/lists/* \
 && dpkg-deb --fsys-tarfile ./*.deb | tar -C / -x "./opt/rocm/core-${ROCM_SERIES}/include/hip" \
 && d=/opt/rocm/core-${ROCM_SERIES}/include/hip/nvidia_detail && mkdir "$d" && cd "$d" \
 && while read -r _ f; do \
        curl -fsSLO "https://raw.githubusercontent.com/ROCm/rocm-systems/${ROCM_SOURCE_TAG}/projects/hipother/hipnv/include/hip/nvidia_detail/$f"; \
    done </tmp/hipother.sha256 \
 && sha256sum -c /tmp/hipother.sha256 \
 && cd / && rm -rf /tmp/hip /tmp/hipother.sha256

# The packages put their libraries in /usr/local/lib and leave refreshing the
# loader's cache to whatever else the transaction triggers; nothing else does.
# hadolint ignore=DL3003
RUN mkdir /tmp/neo && cd /tmp/neo \
 && igc=https://github.com/intel/intel-graphics-compiler/releases/download/v${IGC_VERSION} \
 && neo=https://github.com/intel/compute-runtime/releases/download/${NEO_VERSION} \
 && curl -fsSLO "$igc/intel-igc-core-2_${IGC_VERSION}+${IGC_BUILD}_amd64.deb" \
 && curl -fsSLO "$igc/intel-igc-opencl-2_${IGC_VERSION}+${IGC_BUILD}_amd64.deb" \
 && curl -fsSLO "$neo/intel-ocloc_${NEO_VERSION}-0_amd64.deb" \
 && printf '%s  %s\n' \
        "${IGC_CORE_SHA256}" "intel-igc-core-2_${IGC_VERSION}+${IGC_BUILD}_amd64.deb" \
        "${IGC_OPENCL_SHA256}" "intel-igc-opencl-2_${IGC_VERSION}+${IGC_BUILD}_amd64.deb" \
        "${OCLOC_SHA256}" "intel-ocloc_${NEO_VERSION}-0_amd64.deb" \
    | sha256sum -c - \
 && apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends ./*.deb \
 && rm -rf /var/lib/apt/lists/* \
 && ldconfig \
 && cd / && rm -rf /tmp/neo

# hadolint ignore=DL3003
RUN d=/usr/share/gpu-kernel-compiler/licenses && mkdir -p "$d" && cd "$d" \
 && curl -fsSL "https://raw.githubusercontent.com/ROCm/llvm-project/${ROCM_SOURCE_TAG}/LICENSE.TXT" \
        -o rocm-llvm-LICENSE.TXT \
 && curl -fsSL "https://raw.githubusercontent.com/ROCm/llvm-project/${ROCM_SOURCE_TAG}/amd/device-libs/LICENSE.TXT" \
        -o rocm-device-libs-LICENSE.TXT \
 && curl -fsSL "https://raw.githubusercontent.com/ROCm/rocm-systems/${ROCM_SOURCE_TAG}/projects/hip/LICENSE.md" \
        -o hip-LICENSE.md \
 && curl -fsSL "https://raw.githubusercontent.com/ROCm/rocm-systems/${ROCM_SOURCE_TAG}/projects/hipother/LICENSE.md" \
        -o hipother-LICENSE.md \
 && curl -fsSL "https://raw.githubusercontent.com/intel/intel-graphics-compiler/v${IGC_VERSION}/LICENSE.md" \
        -o intel-graphics-compiler-LICENSE.md \
 && curl -fsSL "https://raw.githubusercontent.com/intel/compute-runtime/${NEO_VERSION}/LICENSE.md" \
        -o intel-compute-runtime-LICENSE.md \
 && printf '%s  %s\n' \
        "${ROCM_LLVM_LICENSE_SHA256}" rocm-llvm-LICENSE.TXT \
        "${ROCM_DEVICE_LIBS_LICENSE_SHA256}" rocm-device-libs-LICENSE.TXT \
        "${HIP_LICENSE_SHA256}" hip-LICENSE.md \
        "${HIP_LICENSE_SHA256}" hipother-LICENSE.md \
        "${IGC_LICENSE_SHA256}" intel-graphics-compiler-LICENSE.md \
        "${NEO_LICENSE_SHA256}" intel-compute-runtime-LICENSE.md \
    | sha256sum -c -

COPY LICENSE /usr/share/gpu-kernel-compiler/licenses/gpu-kernel-compiler-LICENSE
COPY targets nvidia-image /usr/share/gpu-kernel-compiler/
COPY gkcc /usr/local/bin/gkcc
COPY kobj_check.py /usr/local/bin/kobj_check

# What the tools report of themselves, not only the pins they were asked for
RUN isas=$(find /opt/rocm/lib/llvm/amdgcn/bitcode -name 'oclc_isa_version_*.bc' -printf '%f\n' \
           | sed 's/^oclc_isa_version_\(.*\)\.bc$/gfx\1/' | sort -V | tr '\n' ' ') \
 && rocm=$(dpkg-query -W -f '${Version}' "amdrocm-llvm${ROCM_SERIES}") \
 && printf '%-16s %s\n' \
        base "ubuntu:26.04@sha256:88a381d5b5eeb2b35d3ad70925a362c37ce569daf43ede89ff818ec20e4d3794" \
        targets "$(tr '\n' ' ' </usr/share/gpu-kernel-compiler/targets)" \
        clang "$(dpkg-query -W -f '${Version}' "clang-${CLANG_MAJOR}") ($(clang --version | head -1))" \
        rocm-llvm "$rocm ($(/opt/rocm/lib/llvm/bin/clang --version | head -1))" \
        rocm-device-libs "$rocm (${isas% })" \
        hip "$rocm (amdrocm-runtime-dev${ROCM_SERIES} headers; nvidia_detail from rocm-systems ${ROCM_SOURCE_TAG})" \
        igc "$(dpkg-query -W -f '${Version}' intel-igc-core-2)" \
        ocloc "$(dpkg-query -W -f '${Version}' intel-ocloc)" \
        nvidia "not in the image; ptxas, libdevice and CUDA headers mounted at run time from $(cat /usr/share/gpu-kernel-compiler/nvidia-image)" \
    > /usr/share/gpu-kernel-compiler/manifest \
 && cat /usr/share/gpu-kernel-compiler/manifest

LABEL org.opencontainers.image.title="gpu-kernel-compiler" \
      org.opencontainers.image.description="GPU kernels to device code for AMD, Intel and NVIDIA GPUs; NVIDIA's tools mounted at run time" \
      org.opencontainers.image.source="https://github.com/safl/gpu-kernel-compiler" \
      org.opencontainers.image.licenses="BSD-3-Clause AND Apache-2.0 WITH LLVM-exception AND NCSA AND MIT"

ENV ROCM_PATH=/opt/rocm
WORKDIR /work
