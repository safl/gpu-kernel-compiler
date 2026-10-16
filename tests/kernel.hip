// SPDX-FileCopyrightText: Simon A. F. Lund <os@safl.dk>
//
// SPDX-License-Identifier: BSD-3-Clause
//
// kernel.cl's kernel in HIP: a thread index, shared memory and a barrier,
// and one math library call, so the device library is linked, not only the
// code generator. SCALE comes from -D and OFFSET from prelude.cl.
#include <hip/hip_runtime.h>

extern "C" __global__ void smoke(const float *x, float *y)
{
	__shared__ float first;
	int i = blockIdx.x * blockDim.x + threadIdx.x;
	if (threadIdx.x == 0)
		first = x[i];
	__syncthreads();
	y[i] = expf(first) * SCALE + OFFSET;
}
