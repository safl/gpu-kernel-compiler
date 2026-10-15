// SPDX-FileCopyrightText: Simon A. F. Lund <os@safl.dk>
//
// SPDX-License-Identifier: BSD-3-Clause
//
// The smoke test's kernel: a work-item index and one math library call, so
// each target's device library is linked, not only its code generator.
// SCALE comes from -D and OFFSET from prelude.cl, so both reach the compiler.
#include "smoke.h"

KERNEL void smoke(global const float *x, global float *y)
{
	size_t i = gid();
	y[i] = EXPF(x[i]) * SCALE + OFFSET;
}
