# SPDX-FileCopyrightText: Simon A. F. Lund <os@safl.dk>
#
# SPDX-License-Identifier: BSD-3-Clause
"""Unit tests for kobj_check.py, which every image's smoke test runs."""

from __future__ import annotations

import struct

import pytest

import kobj_check


def _elf(machine: int, flags: int, abiversion: int = 0, sections: bytes = b"") -> bytes:
    ident = b"\x7fELF" + bytes([2, 1, 1, 0, abiversion]) + bytes(7)
    shoff = 0x40 if sections else 0
    head = ident + struct.pack(
        "<HHIQQQIHHHHHH", 1, machine, 1, 0, 0, shoff, flags, 0x40, 0, 0, 0x40, 0, 0
    )
    return head + sections


def _zebin(product: int) -> bytes:
    """An EM_INTELGT ELF whose .note.intelgt.compat holds a product family note."""
    names = b"\0.shstrtab\0.note.intelgt.compat\0"
    note = struct.pack("<III", 8, 4, 2) + b"IntelGT\0" + struct.pack("<I", 0xC07)
    note += struct.pack("<III", 8, 4, 1) + b"IntelGT\0" + struct.pack("<I", product)
    data_off = 0x40 + 3 * 0x40
    names_off, note_off = data_off, data_off + len(names)

    def sh(name: int, stype: int, off: int, size: int) -> bytes:
        return struct.pack("<IIQQQQIIQQ", name, stype, 0, 0, off, size, 0, 0, 1, 0)

    shdrs = sh(0, 0, 0, 0) + sh(1, 3, names_off, len(names)) + sh(11, 7, note_off, len(note))
    elf = bytearray(_elf(kobj_check.EM_INTELGT, 0, sections=shdrs + names + note))
    struct.pack_into("<HH", elf, 0x3C, 3, 1)  # e_shnum, e_shstrndx
    return bytes(elf)


@pytest.mark.parametrize(
    ("flags", "abiversion", "want"),
    [
        (0x6004B04, 8, "sm_75"),
        (0x6005604, 8, "sm_86"),
        (0x6007802, 8, "sm_120"),
        (0x560056, 7, "sm_86"),
    ],
)
def test_cubin(flags, abiversion, want):
    assert kobj_check.identify(_elf(kobj_check.EM_CUDA, flags, abiversion)) == want


@pytest.mark.parametrize(
    ("flags", "want"),
    [(0x12C, "gfx900"), (0x135, "gfx1012"), (0x46, "gfx1101"), (0x2F, "amdgpu-mach-0x2f")],
)
def test_amd_code_object(flags, want):
    assert kobj_check.identify(_elf(kobj_check.EM_AMDGPU, flags, 4)) == want


def test_zebin():
    assert kobj_check.identify(_zebin(1270)) == "dg2"
    assert kobj_check.identify(_zebin(1210)) == "intelgt-product-1210"


@pytest.mark.parametrize(
    "data", [b"", b"PTX text, not ELF", _elf(62, 0), _elf(kobj_check.EM_INTELGT, 0)]
)
def test_rejects(data):
    with pytest.raises(kobj_check.NotAKernelObject):
        kobj_check.identify(data)


def test_main_reports_mismatch(tmp_path, capsys):
    obj = tmp_path / "k.o"
    obj.write_bytes(_elf(kobj_check.EM_AMDGPU, 0x2C, 4))
    assert kobj_check.main([f"{obj}=gfx900"]) == 0
    assert kobj_check.main([f"{obj}=gfx1101"]) == 1
    assert "FAIL" in capsys.readouterr().out


def _with_symbols(machine: int, flags: int, abiversion: int, names: list[str]) -> bytes:
    """An ELF whose .symtab names each of names, its strings in .strtab."""
    strtab = b"\0" + b"".join(n.encode() + b"\0" for n in names)
    syms = bytes(24)  # the null symbol
    pos = 1
    for n in names:
        syms += struct.pack("<IBBHQQ", pos, 0x12, 0, 1, 0, 0)
        pos += len(n) + 1
    data_off = 0x40 + 3 * 0x40
    str_off, sym_off = data_off, data_off + len(strtab)

    def sh(stype: int, off: int, size: int, link: int, entsize: int) -> bytes:
        return struct.pack("<IIQQQQIIQQ", 0, stype, 0, 0, off, size, link, 0, 8, entsize)

    shdrs = sh(0, 0, 0, 0, 0) + sh(3, str_off, len(strtab), 0, 0)
    shdrs += sh(kobj_check.SHT_SYMTAB, sym_off, len(syms), 1, 24)
    elf = bytearray(_elf(machine, flags, abiversion, sections=shdrs + strtab + syms))
    struct.pack_into("<HH", elf, 0x3C, 3, 0)
    return bytes(elf)


def test_symbols():
    obj = _with_symbols(kobj_check.EM_AMDGPU, 0x46, 4, ["saxpy", "saxpy.kd"])
    assert kobj_check.symbols(obj) == {"", "saxpy", "saxpy.kd"}
    assert kobj_check.check(obj, "gfx1101:saxpy") == "gfx1101:saxpy"
    assert kobj_check.check(obj, "gfx1101:gemm") == "gfx1101 without gemm"
    assert kobj_check.check(obj, "gfx900:saxpy") == "gfx1101:saxpy"
    assert kobj_check.symbols(_elf(kobj_check.EM_CUDA, 0)) == set()


def test_main_reports_missing_symbol(tmp_path, capsys):
    obj = tmp_path / "k.cubin"
    obj.write_bytes(_with_symbols(kobj_check.EM_CUDA, 0x6005604, 8, ["saxpy"]))
    assert kobj_check.main([f"{obj}=sm_86:saxpy", f"{obj}=sm_86"]) == 0
    assert kobj_check.main([f"{obj}=sm_86:gemm"]) == 1
    assert "sm_86 without gemm" in capsys.readouterr().out


def _spirv(
    version: int = 0x10200, model: tuple[int, int] = (2, 2), entries=("smoke",), order="<"
) -> bytes:
    """A SPIR-V module of a memory model and a kernel entry point per name."""

    def inst(opcode: int, *operands: int) -> list[int]:
        return [(len(operands) + 1) << 16 | opcode, *operands]

    def string(s: str) -> list[int]:
        raw = s.encode() + b"\0"
        raw += bytes(-len(raw) % 4)
        return list(struct.unpack(f"<{len(raw) // 4}I", raw))

    words = [kobj_check.SPIRV_MAGIC, version, 0, 16, 0]
    words += inst(17, 6)  # OpCapability Kernel
    words += inst(kobj_check.SPIRV_OP_MEMORY_MODEL, *model)
    for i, name in enumerate(entries):
        words += inst(kobj_check.SPIRV_OP_ENTRY_POINT, 6, i + 1, *string(name), 9)
    return struct.pack(f"{order}{len(words)}I", *words)


@pytest.mark.parametrize("order", "<>")
def test_spirv(order):
    assert kobj_check.identify(_spirv(order=order)) == "emu"
    assert kobj_check.identify(_spirv(0x10000, order=order)) == "emu"
    assert kobj_check.identify(_spirv(0x10400, order=order)) == "spirv-1.4"
    assert kobj_check.identify(_spirv(model=(1, 2), order=order)) == "spirv-model-1-2"
    obj = _spirv(entries=("saxpy", "gemm_f16"), order=order)
    assert kobj_check.symbols(obj) == {"saxpy", "gemm_f16"}
    assert kobj_check.check(obj, "emu:gemm_f16") == "emu:gemm_f16"
    assert kobj_check.check(obj, "emu:smoke") == "emu without smoke"


def test_spirv_rejects():
    with pytest.raises(kobj_check.NotAKernelObject):
        kobj_check.symbols(_spirv() + struct.pack("<I", 9 << 16 | 15))
    with pytest.raises(kobj_check.NotAKernelObject):
        kobj_check.identify(struct.pack("<5I", kobj_check.SPIRV_MAGIC, 0x10200, 0, 1, 0))
