#!/usr/bin/env bash
set -euo pipefail
python3 - <<'PY'
from pathlib import Path
src = Path('phase32_rc1_reproducible.sh').read_text(encoding='utf-8')
old_elf = '  python3 "$SRC/tools/audit_android_elf.py" --library "$dist/libalbay.so" --readelf "$TOOLS/llvm-readelf" > "$ART/$label/elf-audit.json"'
new_elf = '  python3 "$SRC/tools/audit_android_elf.py" "$dist/libalbay.so" --readelf "$TOOLS/llvm-readelf" --json "$ART/$label/elf-audit.json" > "$ART/$label/elf-audit.log"'
old_exports = '  python3 "$SRC/tools/audit_native_exports.py" --library "$dist/libalbay.so" --nm "$TOOLS/llvm-nm" --jni-source "$SRC/jni/albay_jni.cpp" --capi-header "$SRC/include/albay/engine_capi.h" > "$ART/$label/export-audit.json"'
new_exports = '  python3 "$SRC/tools/audit_native_exports.py" "$dist/libalbay.so" "$dist/com_albay_engine_AlbayEngine.h" "$SRC/include/albay/engine_capi.h" --nm "$TOOLS/llvm-nm" --json "$ART/$label/export-audit.json" > "$ART/$label/export-audit.log"'
if src.count(old_elf) != 1 or src.count(old_exports) != 1:
    raise SystemExit('RC1 audit patch target mismatch')
src = src.replace(old_elf, new_elf).replace(old_exports, new_exports)
Path('/tmp/phase32_rc1_reproducible_v2.sh').write_text(src, encoding='utf-8')
PY
chmod +x /tmp/phase32_rc1_reproducible_v2.sh
exec bash /tmp/phase32_rc1_reproducible_v2.sh
