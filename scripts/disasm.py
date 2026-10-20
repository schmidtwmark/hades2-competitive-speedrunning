#!/usr/bin/env python3
"""Disassemble one function of the game exe, annotated with PDB symbols and strings.

    scripts/disasm.py Hades2.exe symbols.txt <symbol substring or 0xRVA> [max_bytes]

symbols.txt comes from scripts/pdb_symbols.py. Uses Xcode's llvm-objdump. Every
"# 0x14..." target is replaced by the nearest symbol (+offset) and, when it
points into read-only data, the C string found there.
"""
import bisect
import re
import struct
import subprocess
import sys

IMAGE_BASE = 0x140000000


def load_symbols(path):
    syms = []
    for line in open(path):
        rva, name = line.rstrip("\n").split("  ", 1)
        syms.append((int(rva, 16), name))
    syms.sort()
    return syms


def pe_sections(data):
    pe = struct.unpack_from("<I", data, 0x3C)[0]
    n = struct.unpack_from("<H", data, pe + 6)[0]
    opt = struct.unpack_from("<H", data, pe + 20)[0]
    sec = pe + 24 + opt
    out = []
    for _ in range(n):
        name = data[sec:sec + 8].rstrip(b"\0").decode()
        vsize, vaddr, rsize, raddr = struct.unpack_from("<IIII", data, sec + 8)
        out.append((name, vaddr, vsize, raddr, rsize))
        sec += 40
    return out


def read_cstring(data, sections, rva):
    for name, vaddr, vsize, raddr, rsize in sections:
        if vaddr <= rva < vaddr + rsize and name in (".rdata", ".data"):
            off = raddr + (rva - vaddr)
            end = data.find(b"\0", off, off + 120)
            if end <= off:
                return None
            raw = data[off:end]
            if all(32 <= c < 127 for c in raw) and len(raw) >= 3:
                return raw.decode()
    return None


def main():
    exe, symfile, target = sys.argv[1], sys.argv[2], sys.argv[3]
    max_bytes = int(sys.argv[4], 0) if len(sys.argv) > 4 else 0x2000
    data = open(exe, "rb").read()
    sections = pe_sections(data)
    syms = load_symbols(symfile)
    addrs = [a for a, _ in syms]
    if target.startswith("0x"):
        start = int(target, 16)
        name = target
    else:
        matches = [(a, n) for a, n in syms if target in n]
        if not matches:
            raise SystemExit(f"no symbol matching {target}")
        if len(matches) > 1:
            for a, n in matches[:20]:
                print(f"  {a:08x} {n}", file=sys.stderr)
        start, name = matches[0]
    i = bisect.bisect_right(addrs, start)
    end = addrs[i] if i < len(addrs) else start + max_bytes
    end = min(end, start + max_bytes)
    print(f"; {name} rva {start:#x} .. {end:#x}")
    objdump = subprocess.run(["xcrun", "--find", "llvm-objdump"], capture_output=True, text=True).stdout.strip()
    out = subprocess.run([objdump, "-d", "--no-show-raw-insn", f"--start-address={IMAGE_BASE + start:#x}",
                          f"--stop-address={IMAGE_BASE + end:#x}", exe], capture_output=True, text=True).stdout

    def label(m):
        va = int(m.group(1), 16)
        rva = va - IMAGE_BASE
        j = bisect.bisect_right(addrs, rva) - 1
        parts = []
        if j >= 0:
            a, n = syms[j]
            parts.append(n if a == rva else f"{n}+{rva - a:#x}")
        s = read_cstring(data, sections, rva)
        if s:
            parts.append(repr(s))
        return "# " + " | ".join(parts) if parts else m.group(0)

    for line in out.splitlines():
        if not re.match(r"\s*14[0-9a-f]{7}:", line):
            continue
        line = re.sub(r"<[^>]*>", "", line)
        line = re.sub(r"# 0x(14[0-9a-f]{7})", label, line)
        m = re.search(r"(call|jmp)q?\s+0x(14[0-9a-f]{7})", line)
        if m and "#" not in line:
            line += "  " + label(re.match(r"(.*)", "0x" + m.group(2)) and type("M", (), {"group": lambda self, k, v=m.group(2): v})())
        print(line)


if __name__ == "__main__":
    main()
