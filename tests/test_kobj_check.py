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
    [(0x6005604, 8, "sm_86"), (0x6007802, 8, "sm_120"), (0x560056, 7, "sm_86")],
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
