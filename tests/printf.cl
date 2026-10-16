// SPDX-FileCopyrightText: Simon A. F. Lund <os@safl.dk>
//
// SPDX-License-Identifier: BSD-3-Clause
//
// The smoke test's printf in OpenCL C: a format, a string literal and a
// float, which every target must build into a call the target serves, on
// sm_* vprintf through gkcc's shim.
#include "smoke.h"

KERNEL void say(global uint *out, float f)
{
	if (gid() == 0)
		printf("say %s %f %u\n", "str", f, (uint)gid());
	out[gid()] = 1;
}
