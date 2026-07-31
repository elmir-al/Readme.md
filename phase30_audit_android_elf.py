#!/usr/bin/env python3
"""Fail-closed Android ARM64 production ELF audit for Albay."""
from __future__ import annotations

import argparse
import json
import re
import subprocess
from pathlib import Path

MIN_PAGE = 0x4000
DEFAULT_ALLOWED_NEEDED = {"libc.so", "libdl.so", "libm.so"}


def run(*args: str) -> str:
    return subprocess.check_output(args, text=True, stderr=subprocess.STDOUT)


def field(text: str, name: str) -> str:
    match = re.search(rf"^\s*{re.escape(name)}:\s*(.+?)\s*$", text, re.MULTILINE)
    return match.group(1) if match else ""


def dynamic_values(text: str, tag: str) -> list[str]:
    values: list[str] = []
    for line in text.splitlines():
        if f"({tag})" not in line:
            continue
        bracket = re.search(r"\[([^]]+)\]", line)
        values.append(bracket.group(1) if bracket else line.strip())
    return values


def parse_load_segments(program_headers: str) -> list[dict[str, int | str]]:
    loads: list[dict[str, int | str]] = []
    for line in program_headers.splitlines():
        tokens = line.split()
        if not tokens or tokens[0] != "LOAD" or len(tokens) < 8:
            continue
        try:
            offset = int(tokens[1], 16)
            vaddr = int(tokens[2], 16)
            align = int(tokens[-1], 16)
        except ValueError:
            continue
        loads.append({"offset": offset, "vaddr": vaddr, "align": align, "line": line.strip()})
    return loads


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("library", type=Path)
    parser.add_argument("--readelf", default="llvm-readelf")
    parser.add_argument("--expected-soname", default="libalbay.so")
    parser.add_argument("--allowed-needed", action="append", default=[])
    parser.add_argument("--json", type=Path)
    args = parser.parse_args()

    header = run(args.readelf, "-W", "-h", str(args.library))
    program_headers = run(args.readelf, "-W", "-l", str(args.library))
    dynamic = run(args.readelf, "-W", "-d", str(args.library))
    sections = run(args.readelf, "-W", "-S", str(args.library))
    notes = run(args.readelf, "-W", "-n", str(args.library))

    elf_class = field(header, "Class")
    data = field(header, "Data")
    elf_type = field(header, "Type")
    machine = field(header, "Machine")
    osabi = field(header, "OS/ABI")
    loads = parse_load_segments(program_headers)
    needed = sorted(dynamic_values(dynamic, "NEEDED"))
    sonames = dynamic_values(dynamic, "SONAME")
    allowed_needed = set(args.allowed_needed) if args.allowed_needed else DEFAULT_ALLOWED_NEEDED

    checks: dict[str, bool] = {
        "elf64": elf_class == "ELF64",
        "little_endian": "little endian" in data.lower(),
        "shared_object": elf_type.startswith("DYN"),
        "aarch64": "AArch64" in machine,
        "system_v_osabi": "UNIX - System V" in osabi or "UNIX - GNU" in osabi,
        "has_load_segments": bool(loads),
        "all_load_align_at_least_16k": bool(loads) and all(int(seg["align"]) >= MIN_PAGE for seg in loads),
        "all_load_offset_vaddr_congruent": bool(loads) and all(
            int(seg["align"]) > 0
            and int(seg["offset"]) % int(seg["align"]) == int(seg["vaddr"]) % int(seg["align"])
            for seg in loads
        ),
        "gnu_relro": "GNU_RELRO" in program_headers,
        "bind_now": "BIND_NOW" in dynamic or re.search(r"\bNOW\b", dynamic) is not None,
        "no_textrel": "(TEXTREL)" not in dynamic,
        "no_rpath": "(RPATH)" not in dynamic,
        "no_runpath": "(RUNPATH)" not in dynamic,
        "soname": sonames == [args.expected_soname],
        "needed_allowlist": set(needed).issubset(allowed_needed),
        "no_libcxx_shared": "libc++_shared.so" not in needed,
        "build_id": "Build ID:" in notes,
        "not_debuglink_only": ".text" in sections and ".dynsym" in sections,
    }

    result = {
        "library": str(args.library),
        "elf": {
            "class": elf_class,
            "data": data,
            "type": elf_type,
            "machine": machine,
            "osabi": osabi,
            "soname": sonames,
            "needed": needed,
            "allowed_needed": sorted(allowed_needed),
            "load_segments": loads,
        },
        "minimum_page_alignment": MIN_PAGE,
        "checks": checks,
        "failures": sorted(name for name, passed in checks.items() if not passed),
        "pass": all(checks.values()),
    }
    payload = json.dumps(result, indent=2) + "\n"
    print(payload, end="")
    if args.json:
        args.json.parent.mkdir(parents=True, exist_ok=True)
        args.json.write_text(payload, encoding="utf-8")
    return 0 if result["pass"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
