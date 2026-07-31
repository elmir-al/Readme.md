#!/usr/bin/env python3
from __future__ import annotations
import argparse
import json
import re
import subprocess
from pathlib import Path


def exports(path: Path, nm: str) -> set[str]:
    text = subprocess.check_output([nm, "-D", "--defined-only", str(path)], text=True)
    return {line.split()[-1] for line in text.splitlines() if line.split()}


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("library", type=Path)
    ap.add_argument("jni_header", type=Path)
    ap.add_argument("capi_header", type=Path)
    ap.add_argument("--json", type=Path)
    ap.add_argument("--nm", default="nm", help="nm-compatible executable (for example NDK llvm-nm)")
    args = ap.parse_args()

    actual = exports(args.library, args.nm)
    jni_text = args.jni_header.read_text(encoding="utf-8")
    capi_text = args.capi_header.read_text(encoding="utf-8")
    expected_jni = set(re.findall(r"JNICALL\s+(Java_[A-Za-z0-9_]+)\s*\(", jni_text))
    expected_capi = set(re.findall(r"\b(albay_(?:engine|tablebase)[A-Za-z0-9_]*)\s*\(", capi_text))

    actual_jni = {s for s in actual if s.startswith("Java_com_albay_engine_")}
    actual_capi = {s for s in actual if s.startswith("albay_engine_") or s.startswith("albay_tablebase")}
    missing_jni = sorted(expected_jni - actual)
    extra_jni = sorted(actual_jni - expected_jni)
    missing_capi = sorted(expected_capi - actual)
    extra_capi = sorted(actual_capi - expected_capi)

    result = {
        "library": str(args.library),
        "expected_jni": len(expected_jni),
        "exported_jni": len(actual_jni),
        "expected_capi": len(expected_capi),
        "exported_capi": len(actual_capi),
        "missing_jni": missing_jni,
        "extra_jni": extra_jni,
        "missing_capi": missing_capi,
        "extra_capi": extra_capi,
        "pass": not missing_jni and not extra_jni and not missing_capi and not extra_capi,
    }
    print(json.dumps(result, indent=2))
    if args.json:
        args.json.parent.mkdir(parents=True, exist_ok=True)
        args.json.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    return 0 if result["pass"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
