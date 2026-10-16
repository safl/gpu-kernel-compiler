// SPDX-FileCopyrightText: Simon A. F. Lund <os@safl.dk>
//
// SPDX-License-Identifier: BSD-3-Clause
//
// OpenCL C's printf on nvptx64, which gkcc links into an OpenCL C kernel for
// sm_* as it links libdevice. clang lowers OpenCL's printf to a variadic
// call of printf(format, ...), packing the arguments as CUDA's vprintf takes
// them, but nothing defines printf on NVIDIA, and the format and every %s
// argument, string literals in OpenCL C, are addresses in the constant
// space, not generic ones. This printf converts them to generic addresses
// and calls vprintf, which the driver or the program's device runtime
// resolves. Its walk of the format follows the packing: a 32-bit slot, at
// 4 bytes' alignment, for every integer the default promotions leave an
// int and for %c; a 64-bit one, at 8, for l, ll, j, z and t, every float,
// which is promoted to double, and %s and %p; a vector whole at its own
// alignment, 8 at most.
typedef __attribute__((address_space(4))) const char cchar;
typedef unsigned long long u64;

int vprintf(const char *format, void *args);

static void digits(const char **p)
{
	while (**p >= '0' && **p <= '9')
		(*p)++;
}

int printf(cchar *format, ...)
{
	const char *f = (const char *)format;
	__builtin_va_list ap;
	char *args;
	u64 at = 0;
	int r;

	__builtin_va_start(ap, format);
	args = (char *)ap;
	for (const char *p = f; *p; p++) {
		unsigned size = 4, vec = 0, each = 4, star;

		if (*p != '%')
			continue;
		if (*++p == '%')
			continue;
		while (*p == '-' || *p == '+' || *p == ' ' || *p == '#' || *p == '0')
			p++;
		/* a '*' width or precision is an int argument of its own */
		for (star = 0; star < 2; star++) {
			if (*p == '*') {
				at = (at + 3) & ~3ull;
				at += 4;
				p++;
			} else {
				digits(&p);
			}
			if (star == 0 && *p == '.')
				p++;
			else
				break;
		}
		if (*p == 'v') {
			p++;
			vec = 0;
			while (*p >= '0' && *p <= '9')
				vec = vec * 10 + (unsigned)(*p++ - '0');
		}
		if (p[0] == 'h' && p[1] == 'h') {
			each = 1;
			p += 2;
		} else if (p[0] == 'h' && p[1] == 'l') {
			each = 4;
			p += 2;
		} else if (p[0] == 'l' && p[1] == 'l') {
			size = each = 8;
			p += 2;
		} else if (*p == 'h') {
			each = 2;
			p++;
		} else if (*p == 'l' || *p == 'j' || *p == 'z' || *p == 't') {
			size = each = 8;
			p++;
		} else if (*p == 'L') {
			p++;
		}
		if (!*p)
			break;
		if (vec) {
			unsigned bytes = each * (vec == 3 ? 4 : vec), align = bytes > 8 ? 8 : bytes;

			at = (at + align - 1) & ~(u64)(align - 1);
			at += bytes;
			continue;
		}
		if (*p == 's' || *p == 'p' || *p == 'e' || *p == 'E' || *p == 'f' || *p == 'F' || *p == 'g' ||
		    *p == 'G' || *p == 'a' || *p == 'A')
			size = 8;
		at = (at + size - 1) & ~(u64)(size - 1);
		if (*p == 's') {
			u64 raw = *(u64 *)(args + at);

			*(u64 *)(args + at) = (u64)(const char *)(cchar *)raw;
		}
		at += size;
	}
	r = vprintf(f, args);
	__builtin_va_end(ap);
	return r;
}
