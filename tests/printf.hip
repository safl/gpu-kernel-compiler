// SPDX-FileCopyrightText: Simon A. F. Lund <os@safl.dk>
//
// SPDX-License-Identifier: BSD-3-Clause
//
// The smoke test's printf in HIP, which on gfx* must use the kernel's printf
// buffer, not the host call buffer.
#include <hip/hip_runtime.h>

extern "C" __global__ void say(unsigned *out, float f)
{
	if (threadIdx.x == 0)
		printf("say %s %f\n", "str", f);
	out[threadIdx.x] = 1;
}
