#!/usr/bin/env bash
set -euo pipefail

WORK="$PWD"
ART="$WORK/artifact-phase32-rc1"
OVERLAY=/tmp/albay-v410-overlay.tar.xz
EXTRACT=/tmp/albay-overlay
SRC="$EXTRACT/albay"
mkdir -p "$ART" "$EXTRACT"
exec > >(tee "$ART/phase32-rc1-ci.log") 2>&1

printf '== Reconstruct exact Albay v4.1.0 source ==\n'
test "$(find phase29_v410_overlay10 -maxdepth 1 -name 'part-*.b64' | wc -l)" -eq 5
cat phase29_v410_overlay10/part-*.b64 | base64 --decode > "$OVERLAY"
echo "577600c4441c101f9003e954d484e8bf299d2472827ad0d655a52043bef2f76e  $OVERLAY" | sha256sum -c --strict
tar -xJf "$OVERLAY" -C "$EXTRACT"
test -f "$SRC/CMakeLists.txt"
test -f "$SRC/src/engine.cpp"
test -f "$SRC/scripts/build_android_arm64.sh"
grep -Fq 'project(Albay VERSION 4.1.0 LANGUAGES CXX)' "$SRC/CMakeLists.txt"

printf '== Restore exact fail-closed audit tools ==\n'
mkdir -p "$SRC/tools"
cp "$WORK/phase30_audit_android_elf.py" "$SRC/tools/audit_android_elf.py"
cp "$WORK/phase30_audit_native_exports.py" "$SRC/tools/audit_native_exports.py"
echo "bd001bbd159d1b6c32305af9acc31f7ad273b87b7f32f661027863960f6f2c1a  $SRC/tools/audit_android_elf.py" | sha256sum -c --strict
echo "b9209bb757cc1220b0bd54a1c5049d0a6331892432e05bbbe10aa358b776cf46  $SRC/tools/audit_native_exports.py" | sha256sum -c --strict

printf '== Apply metadata-only RC1 version patch ==\n'
python3 - "$SRC/src/engine.cpp" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
s = p.read_text(encoding='utf-8')
old = 'const char* Engine::version() { return "4.1.0-dev"; }'
new = 'const char* Engine::version() { return "4.1.0-rc1"; }'
if s.count(old) != 1:
    raise SystemExit(f'expected exactly one version declaration, found {s.count(old)}')
p.write_text(s.replace(old, new), encoding='utf-8')
PY
grep -Fq 'const char* Engine::version() { return "4.1.0-rc1"; }' "$SRC/src/engine.cpp"
! grep -Fq '4.1.0-dev' "$SRC/src/engine.cpp"
sha256sum "$SRC/src/engine.cpp" > "$ART/RC1_ENGINE_SOURCE_SHA256.txt"

printf '== Regenerate byte-identical embedded TB3 ==\n'
cat > /tmp/albay_tb3_stubs.cpp <<'CPP'
#include "albay/draw_rules.h"
#include "albay/position.h"
namespace albay {
uint8_t three_kings_vs_one_eligible_mask(const Position&) { return 0; }
RegulationDescriptor regulation_descriptor(const Position&) { return {}; }
}
CPP
g++ -std=c++20 -O2 -pthread -I"$SRC/include" \
  "$WORK/phase30_tb3_generate.cpp" \
  "$SRC/src/bitboard.cpp" "$SRC/src/move.cpp" "$SRC/src/movegen.cpp" \
  "$SRC/src/position.cpp" "$SRC/src/zobrist.cpp" /tmp/albay_tb3_stubs.cpp \
  -o /tmp/albay_tb3_generate
/tmp/albay_tb3_generate /tmp/albay_tb3.bin "$ART/tb3-regeneration-stats.json" >/dev/null
echo "1f4397e72b63bd13f64e88c87d07432de802b5d12c54a4e38e66a6319fb3f9ec  /tmp/albay_tb3.bin" | sha256sum -c --strict
python3 - <<'PY'
from pathlib import Path
payload = Path('/tmp/albay_tb3.bin').read_bytes()
lines = []
for offset in range(0, len(payload), 16):
    chunk = payload[offset:offset + 16]
    suffix = ',' if offset + 16 < len(payload) else ''
    lines.append('    ' + ', '.join(f'0x{value:02x}' for value in chunk) + suffix)
Path('/tmp/tb3_data.inc').write_text('\n'.join(lines) + '\n', encoding='ascii')
PY
echo "dad96580c6f74f746159b8c0490566a65c041623ca4a968b234a13aa070ee2bb  /tmp/tb3_data.inc" | sha256sum -c --strict
mv /tmp/tb3_data.inc "$SRC/src/tb3_data.inc"

printf '== Install and verify exact official NDK r29 ==\n'
SDKMANAGER="${ANDROID_SDK_ROOT}/cmdline-tools/latest/bin/sdkmanager"
yes | "$SDKMANAGER" --licenses >/dev/null || true
"$SDKMANAGER" "ndk;29.0.14206865"
NDK="${ANDROID_SDK_ROOT}/ndk/29.0.14206865"
test -f "$NDK/source.properties"
grep -Eq '^Pkg.Revision[[:space:]]*=[[:space:]]*29\.0\.14206865[[:space:]]*$' "$NDK/source.properties"
cp "$NDK/source.properties" "$ART/NDK_SOURCE_PROPERTIES.txt"
TOOLS="$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin"

build_once() {
  local label="$1"
  printf '== Canonical clean Android RC1 build %s ==\n' "$label"
  rm -rf "$SRC/build/android-arm64-release" "$SRC/dist/android/arm64-v8a"
  export ANDROID_NDK_ROOT="$NDK"
  export ANDROID_PLATFORM=android-29
  export JOBS=2
  chmod +x "$SRC/scripts/build_android_arm64.sh"
  "$SRC/scripts/build_android_arm64.sh" > "$ART/${label}-build.log" 2>&1
  local dist="$SRC/dist/android/arm64-v8a"
  test -f "$dist/libalbay.so"
  test -f "$dist/libalbay.so.unstripped"
  mkdir -p "$ART/$label"
  cp "$dist/libalbay.so" "$ART/$label/"
  cp "$dist/libalbay.so.unstripped" "$ART/$label/"
  "$TOOLS/llvm-objcopy" --only-keep-debug "$dist/libalbay.so.unstripped" "$ART/$label/libalbay.so.debug"
  "$TOOLS/llvm-readelf" -W -h "$dist/libalbay.so" > "$ART/$label/elf-header.txt"
  "$TOOLS/llvm-readelf" -W -l "$dist/libalbay.so" > "$ART/$label/program-headers.txt"
  "$TOOLS/llvm-readelf" -W -d "$dist/libalbay.so" > "$ART/$label/dynamic.txt"
  "$TOOLS/llvm-readelf" -W -n "$dist/libalbay.so" > "$ART/$label/notes.txt"
  "$TOOLS/llvm-nm" -D --defined-only "$dist/libalbay.so" > "$ART/$label/exports.txt"
  "$TOOLS/llvm-strings" "$dist/libalbay.so" | grep -Fx '4.1.0-rc1' > "$ART/$label/version-string.txt"
  python3 "$SRC/tools/audit_android_elf.py" --library "$dist/libalbay.so" --readelf "$TOOLS/llvm-readelf" > "$ART/$label/elf-audit.json"
  python3 "$SRC/tools/audit_native_exports.py" --library "$dist/libalbay.so" --nm "$TOOLS/llvm-nm" --jni-source "$SRC/jni/albay_jni.cpp" --capi-header "$SRC/include/albay/engine_capi.h" > "$ART/$label/export-audit.json"
  grep -Eq 'Machine:[[:space:]]+AArch64' "$ART/$label/elf-header.txt"
  grep -Eq 'Type:[[:space:]]+DYN' "$ART/$label/elf-header.txt"
  grep -Eq '\(SONAME\).+\[libalbay\.so\]' "$ART/$label/dynamic.txt"
  ! grep -Eq 'libstdc\+\+\.so\.6|libgcc_s\.so\.1|libc\+\+_shared\.so' "$ART/$label/dynamic.txt"
  awk '$1 == "LOAD" {print}' "$ART/$label/program-headers.txt" > "$ART/$label/load-segments.txt"
  test "$(awk '$1 == "LOAD" && $NF != "0x4000" {bad++} END {print bad+0}' "$ART/$label/load-segments.txt")" -eq 0
  sha256sum "$ART/$label/libalbay.so" "$ART/$label/libalbay.so.unstripped" "$ART/$label/libalbay.so.debug" > "$ART/$label/SHA256SUMS.txt"
}

build_once run-A
build_once run-B

printf '== Byte-for-byte RC1 reproducibility comparison ==\n'
cmp -s "$ART/run-A/libalbay.so" "$ART/run-B/libalbay.so"
cmp -s "$ART/run-A/libalbay.so.unstripped" "$ART/run-B/libalbay.so.unstripped"
cmp -s "$ART/run-A/libalbay.so.debug" "$ART/run-B/libalbay.so.debug"

PROD_SHA=$(sha256sum "$ART/run-A/libalbay.so" | awk '{print $1}')
UNSTRIPPED_SHA=$(sha256sum "$ART/run-A/libalbay.so.unstripped" | awk '{print $1}')
DEBUG_SHA=$(sha256sum "$ART/run-A/libalbay.so.debug" | awk '{print $1}')
cat > "$ART/PHASE32_RC1_REPRODUCIBILITY_STATUS.json" <<EOF
{
  "engine": "Albay",
  "version": "4.1.0-rc1",
  "status": "PASS",
  "ndk": "29.0.14206865",
  "abi": "arm64-v8a",
  "platform": "android-29",
  "page_alignment": 16384,
  "production_byte_identical": true,
  "unstripped_byte_identical": true,
  "debug_byte_identical": true,
  "production_sha256": "$PROD_SHA",
  "unstripped_sha256": "$UNSTRIPPED_SHA",
  "debug_sha256": "$DEBUG_SHA"
}
EOF
cp -a "$ART/run-A" "$ART/production"
printf 'ALBAY_PHASE32_RC1_ANDROID_REPRODUCIBILITY_PASS\n'
