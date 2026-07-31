#!/usr/bin/env bash
set -euo pipefail

python3 - <<'PY'
from pathlib import Path
src = Path('phase29_v410_build.sh').read_text()
old = 'OLD_SRC=/tmp/albay-old/albay_minimal\ntest -f "$OLD_SRC/src/tb3_data.inc"'
new = '''OLD_SRC="$(find /tmp/albay-old -type f -name CMakeLists.txt -printf '%h\\n' | head -n 1)"
echo "Detected legacy carrier root: $OLD_SRC"
find /tmp/albay-old -maxdepth 3 -type f | sort | sed -n '1,120p'
test -n "$OLD_SRC"
test -f "$OLD_SRC/src/tb3_data.inc"'''
if old not in src:
    raise SystemExit('expected source-root block not found')
Path('/tmp/phase29_v410_build_patched.sh').write_text(src.replace(old, new))
PY

exec bash /tmp/phase29_v410_build_patched.sh
