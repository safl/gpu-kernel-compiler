// SPDX-FileCopyrightText: Simon A. F. Lund <os@safl.dk>
//
// SPDX-License-Identifier: BSD-3-Clause
//
// kernel.cl includes this, so a source in another directory than its
// includes, as a prelude or stdin makes it, still finds them.
#ifdef __NVPTX__
// clang has no OpenCL builtin library for nvptx64, and its OpenCL kernel
// stub calls the body as a second kernel, which PTX cannot do
#define KERNEL __attribute__((nvptx_kernel))
static size_t gid(void)
{
	return __nvvm_read_ptx_sreg_ctaid_x() * __nvvm_read_ptx_sreg_ntid_x() + __nvvm_read_ptx_sreg_tid_x();
}
float __nv_expf(float);
// A warp shuffle needs PTX 6.0, which clang only emits when it knows the CUDA
#define EXPF(x) __nv_expf(__nvvm_shfl_sync_idx_f32(0xffffffff, (x), 0, 31))
#else
#define KERNEL kernel
#define gid() get_global_id(0)
#define EXPF exp
#endif
