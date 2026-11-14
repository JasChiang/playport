#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Add an LC_LOAD_DYLIB for <install_name> to a thin arm64 Mach-O, in the header padding.

Usage: insert_dylib.py <binary> <install_name>   (idempotent; re-sign afterwards)
"""
import struct
import sys

MH_MAGIC_64 = 0xFEEDFACF
LC_LOAD_DYLIB = 0xC
LC_SEGMENT_64 = 0x19


def main(path, name):
    data = bytearray(open(path, "rb").read())
    magic, cputype, _sub, _ft, ncmds, sizeofcmds, _flags, _res = struct.unpack_from("<IiiIIIII", data, 0)
    if magic != MH_MAGIC_64:
        sys.exit(f"{path}: not a thin 64-bit Mach-O (magic {magic:#x}); lipo -thin arm64 first")
    hdr = 32
    off = hdr
    first_section = len(data)
    for _ in range(ncmds):
        cmd, size = struct.unpack_from("<II", data, off)
        if cmd == LC_LOAD_DYLIB:
            stroff = struct.unpack_from("<I", data, off + 8)[0]
            existing = bytes(data[off + stroff: off + size]).split(b"\0", 1)[0].decode()
            if existing == name:
                print(f"already loads {name}")
                return
        if cmd == LC_SEGMENT_64:
            nsects = struct.unpack_from("<I", data, off + 64)[0]
            for i in range(nsects):
                s = off + 72 + i * 80
                sect_off = struct.unpack_from("<I", data, s + 48)[0]
                if sect_off:
                    first_section = min(first_section, sect_off)
        off += size
    end = hdr + sizeofcmds
    raw = name.encode() + b"\0"
    cmdsize = (24 + len(raw) + 7) & ~7
    if end + cmdsize > first_section:
        sys.exit(f"not enough header padding: need {cmdsize}, have {first_section - end}")
    if any(data[end:end + cmdsize]):
        sys.exit("header padding is not zero; refusing to overwrite")
    lc = struct.pack("<IIIIII", LC_LOAD_DYLIB, cmdsize, 24, 2, 0x10000, 0x10000) + raw
    lc += b"\0" * (cmdsize - len(lc))
    data[end:end + cmdsize] = lc
    struct.pack_into("<II", data, 16, ncmds + 1, sizeofcmds + cmdsize)
    open(path, "wb").write(data)
    print(f"added LC_LOAD_DYLIB {name} ({cmdsize} bytes, {first_section - end - cmdsize} bytes padding left)")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    main(sys.argv[1], sys.argv[2])
