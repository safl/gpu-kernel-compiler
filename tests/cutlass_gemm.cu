// SPDX-FileCopyrightText: Simon A. F. Lund <os@safl.dk>
//
// SPDX-License-Identifier: BSD-3-Clause
//
// A CUTLASS GEMM device kernel under a plain name, for tests/cutlass.sh:
// half-precision A and B, single-precision C and D, on Ampere's tensor
// cores. The host builds GemmKernel::Params and launches it with
// sizeof(GemmKernel::SharedStorage) bytes of dynamic shared memory.
#include <cutlass/gemm/device/gemm.h>

using Gemm = cutlass::gemm::device::Gemm<cutlass::half_t, cutlass::layout::RowMajor,
					 cutlass::half_t, cutlass::layout::ColumnMajor, float,
					 cutlass::layout::RowMajor, float,
					 cutlass::arch::OpClassTensorOp, cutlass::arch::Sm80>;
using GemmKernel = Gemm::GemmKernel;

extern "C" __global__ void __launch_bounds__(GemmKernel::kThreadCount)
	cutlass_gemm(GemmKernel::Params params)
{
	extern __shared__ int smem[];
	GemmKernel op;
	op(params, *reinterpret_cast<GemmKernel::SharedStorage *>(smem));
}
