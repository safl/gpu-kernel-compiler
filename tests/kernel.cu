// SPDX-FileCopyrightText: Simon A. F. Lund <os@safl.dk>
//
// SPDX-License-Identifier: BSD-3-Clause
//
// kernel.cl's kernel in CUDA: a thread index, a warp shuffle and one math
// library call, so libdevice is linked, not only the code generator.
// SCALE comes from -D and OFFSET from prelude.cl, so both reach the compiler.
extern "C" __global__ void smoke(const float *x, float *y)
{
	int i = blockIdx.x * blockDim.x + threadIdx.x;
	y[i] = expf(__shfl_sync(0xffffffffu, x[i], 0)) * SCALE + OFFSET;
}
