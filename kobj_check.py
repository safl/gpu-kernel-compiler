#!/usr/bin/env python3
# SPDX-FileCopyrightText: Simon A. F. Lund <os@safl.dk>
#
# SPDX-License-Identifier: BSD-3-Clause
"""Check that GPU kernel objects are what their target says they are.

Reads each file's ELF header (and, for an Intel zebin, its
``.note.intelgt.compat`` notes) and names the device it is for, so a compiler
that silently emitted something else is caught. A ``:SYMBOL`` after the
target also requires that symbol in the file's symbol table, so an object
that lost its kernel is caught too. No GPU and no vendor tool is needed to
read them.

    kobj_check out/sm_86.o=sm_86 out/gfx900.o=gfx900:smoke out/dg2.o=dg2

Exits non-zero, naming each mismatch, unless every file is for its target
and holds its symbol.
"""

from __future__ import annotations

import struct
import sys
from pathlib import Path

EM_AMDGPU = 224
EM_CUDA = 190
EM_INTELGT = 205

# EF_AMDGPU_MACH_* in the low byte of e_flags (llvm/BinaryFormat/ELF.h)
AMDGPU_MACH = {0x2C: "gfx900", 0x35: "gfx1012", 0x46: "gfx1101"}

# PRODUCT_FAMILY values in the zebin's INTELGT_NOTE_PRODUCT_FAMILY (igfxfmid.h)
INTELGT_PRODUCT = {1270: "dg2"}
NT_INTELGT_PRODUCT_FAMILY = 1
SHT_SYMTAB = 2


class NotAKernelObject(ValueError):
    pass


def _intelgt_product(data: bytes, shoff: int, shentsize: int, shnum: int) -> int:
    """PRODUCT_FAMILY from the zebin's .note.intelgt.compat section."""
    shstrndx = struct.unpack_from("<H", data, 0x3E)[0]
    strtab_off = struct.unpack_from("<Q", data, shoff + shstrndx * shentsize + 0x18)[0]
    for i in range(shnum):
        sh = shoff + i * shentsize
        name_off = struct.unpack_from("<I", data, sh)[0]
        start = strtab_off + name_off
        name = data[start : data.index(b"\0", start)]
        if name != b".note.intelgt.compat":
            continue
        off, size = struct.unpack_from("<QQ", data, sh + 0x18)
        pos, end = off, off + size
        while pos + 12 <= end:
            namesz, descsz, ntype = struct.unpack_from("<III", data, pos)
            desc = pos + 12 + ((namesz + 3) & ~3)
            if ntype == NT_INTELGT_PRODUCT_FAMILY and descsz == 4:
                return struct.unpack_from("<I", data, desc)[0]
            pos = desc + ((descsz + 3) & ~3)
    raise NotAKernelObject("zebin without a product family note")


def identify(data: bytes) -> str:
    """Name the device a kernel object is for: sm_NN, gfxNNN or dg2."""
    if len(data) < 0x40 or data[:4] != b"\x7fELF" or data[4] != 2 or data[5] != 1:
        raise NotAKernelObject("not a little-endian ELF64 file")
    abiversion = data[8]
    machine, _version, _entry, _phoff, shoff, flags = struct.unpack_from("<HIQQQI", data, 0x12)
    shentsize, shnum = struct.unpack_from("<HH", data, 0x3A)

    if machine == EM_CUDA:
        # The cubin ABI moved the SM number up a byte at ABI version 8 (CUDA 12.8)
        sm = (flags >> 8) & 0xFF if abiversion >= 8 else flags & 0xFF
        return f"sm_{sm}"
    if machine == EM_AMDGPU:
        mach = flags & 0xFF
        return AMDGPU_MACH.get(mach, f"amdgpu-mach-{mach:#x}")
    if machine == EM_INTELGT:
        product = _intelgt_product(data, shoff, shentsize, shnum)
        return INTELGT_PRODUCT.get(product, f"intelgt-product-{product}")
    raise NotAKernelObject(f"ELF machine {machine} is not a GPU")


def symbols(data: bytes) -> set[str]:
    """The names in an ELF64 file's .symtab, empty when it has none."""
    shoff = struct.unpack_from("<Q", data, 0x28)[0]
    shentsize, shnum = struct.unpack_from("<HH", data, 0x3A)
    names: set[str] = set()
    for i in range(shnum):
        sh = shoff + i * shentsize
        stype, _flags, _addr, off, size, link, _info, _align, entsize = struct.unpack_from(
            "<IQQQQIIQQ", data, sh + 4
        )
        if stype != SHT_SYMTAB or not entsize:
            continue
        strtab = struct.unpack_from("<Q", data, shoff + link * shentsize + 0x18)[0]
        for sym in range(off, off + size, entsize):
            start = strtab + struct.unpack_from("<I", data, sym)[0]
            names.add(data[start : data.index(b"\0", start)].decode(errors="replace"))
    return names


def check(data: bytes, want: str) -> str:
    """What the object is, as want spells it: TARGET, or TARGET:SYMBOL."""
    target, _, symbol = want.partition(":")
    got = identify(data)
    if symbol and got == target and symbol not in symbols(data):
        return f"{got} without {symbol}"
    return f"{got}:{symbol}" if symbol else got


def main(argv: list[str]) -> int:
    if not argv:
        print(__doc__, file=sys.stderr)
        return 2
    failed = 0
    for arg in argv:
        path, _, want = arg.rpartition("=")
        try:
            got = check(Path(path).read_bytes(), want)
        except (OSError, NotAKernelObject, struct.error, ValueError) as exc:
            got = f"error: {exc}"
        ok = got == want
        failed += not ok
        print(f"{'ok' if ok else 'FAIL'}  {path}: {got} (want {want})")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
