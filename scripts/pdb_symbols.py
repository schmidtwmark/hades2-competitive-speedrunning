#!/usr/bin/env python3
"""List public and function symbols from a PDB (MSF 7.0) with their RVAs.

    scripts/pdb_symbols.py Hades2.exe Hades2.pdb [substring ...]

Reads the DBI stream's public symbol records (S_PUB32) and every module's
S_GPROC32/S_LPROC32 records, and converts section:offset to an RVA using the
exe's section table. Prints "rva_hex  name" lines, filtered by substrings
(case-insensitive) when given. Used to find engine functions to hook with
rom.memory.dynamic_hook; RVAs are only valid for the exact exe/PDB pair.
"""
import struct
import sys

MSF_MAGIC = b"Microsoft C/C++ MSF 7.00\r\n\x1aDS\x00\x00\x00"
S_PUB32 = 0x110E
S_GPROC32 = 0x1110
S_LPROC32 = 0x110F


def read_msf(path):
    data = open(path, "rb").read()
    if not data.startswith(MSF_MAGIC):
        raise SystemExit("not an MSF 7.0 PDB")
    block_size, _fpm, _nblocks, dir_bytes, _unk, block_map_addr = struct.unpack_from("<6I", data, 32)

    def blocks(indices, size):
        out = b"".join(data[i * block_size:(i + 1) * block_size] for i in indices)
        return out[:size]

    n_dir_blocks = (dir_bytes + block_size - 1) // block_size
    dir_block_indices = struct.unpack_from(f"<{n_dir_blocks}I", data, block_map_addr * block_size)
    directory = blocks(dir_block_indices, dir_bytes)
    n_streams = struct.unpack_from("<I", directory, 0)[0]
    sizes = struct.unpack_from(f"<{n_streams}I", directory, 4)
    pos = 4 + 4 * n_streams
    streams = []
    for size in sizes:
        if size == 0xFFFFFFFF:
            streams.append(b"")
            continue
        n = (size + block_size - 1) // block_size
        idx = struct.unpack_from(f"<{n}I", directory, pos)
        pos += 4 * n
        streams.append(blocks(idx, size))
    return streams


def pe_sections(exe_path):
    data = open(exe_path, "rb").read()
    pe = struct.unpack_from("<I", data, 0x3C)[0]
    n_sections = struct.unpack_from("<H", data, pe + 6)[0]
    opt_size = struct.unpack_from("<H", data, pe + 20)[0]
    sec = pe + 24 + opt_size
    out = []
    for i in range(n_sections):
        name = data[sec:sec + 8].rstrip(b"\0").decode(errors="replace")
        vaddr = struct.unpack_from("<I", data, sec + 12)[0]
        out.append((name, vaddr))
        sec += 40
    return out


def records(buf, start=0):
    pos = start
    while pos + 4 <= len(buf):
        reclen, kind = struct.unpack_from("<HH", buf, pos)
        if reclen < 2:
            break
        yield kind, buf[pos + 4:pos + 2 + reclen]
        pos += 2 + reclen


def cstr(b, off):
    end = b.index(b"\0", off)
    return b[off:end].decode(errors="replace")


def main():
    exe, pdb = sys.argv[1], sys.argv[2]
    filters = [f.lower() for f in sys.argv[3:]]
    streams = read_msf(pdb)
    sections = pe_sections(exe)
    dbi = streams[3]
    (sym_record_stream,) = struct.unpack_from("<H", dbi, 20)
    mod_info_size = struct.unpack_from("<i", dbi, 24)[0]

    def rva(seg, off):
        if 1 <= seg <= len(sections):
            return sections[seg - 1][1] + off
        return None

    found = {}
    for kind, body in records(streams[sym_record_stream]):
        if kind == S_PUB32:
            _flags, off, seg = struct.unpack_from("<IIH", body, 0)
            found.setdefault(cstr(body, 10), rva(seg, off))

    # Module streams carry S_GPROC32 with undecorated "sgg::Class::Method" names.
    pos = 64
    end = 64 + mod_info_size
    while pos < end:
        stream_index = struct.unpack_from("<H", dbi, pos + 34)[0]
        sym_bytes = struct.unpack_from("<I", dbi, pos + 36)[0]
        name_off = pos + 64
        mod_name_end = dbi.index(b"\0", name_off)
        obj_name_end = dbi.index(b"\0", mod_name_end + 1)
        pos = (obj_name_end + 1 + 3) & ~3
        if stream_index == 0xFFFF or stream_index >= len(streams):
            continue
        mod = streams[stream_index][:sym_bytes]
        for kind, body in records(mod, 4):
            if kind in (S_GPROC32, S_LPROC32):
                off, seg = struct.unpack_from("<IH", body, 28)
                found.setdefault(cstr(body, 31), rva(seg, off))

    for name, addr in sorted(found.items(), key=lambda kv: (kv[1] or 0)):
        if addr is None:
            continue
        if filters and not any(f in name.lower() for f in filters):
            continue
        print(f"{addr:08x}  {name}")


if __name__ == "__main__":
    main()
