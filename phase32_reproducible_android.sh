#!/usr/bin/env bash
set -euo pipefail

WORK="$PWD"
ART="$WORK/artifact-phase32"
TEMPLATE=/tmp/albay-phase32-template
SRC=/tmp/albay-phase32-src
BUILD=/tmp/albay-phase32-build
DIST=/tmp/albay-phase32-dist
OVERLAY=/tmp/albay-v410-overlay.tar.xz
NDK_REV=29.0.14206865
SOURCE_DATE_EPOCH=1785456000
export SOURCE_DATE_EPOCH TZ=UTC LC_ALL=C LANG=C
rm -rf "$ART" "$TEMPLATE" "$SRC" "$BUILD" "$DIST"
mkdir -p "$ART" "$TEMPLATE"
exec > >(tee "$ART/phase32-reproducibility.log") 2>&1

printf '== Reconstruct exact Albay v4.1.0 source ==\n'
test "$(find phase29_v410_overlay10 -maxdepth 1 -name 'part-*.b64' | wc -l)" -eq 5
cat phase29_v410_overlay10/part-*.b64 | base64 --decode > "$OVERLAY"
echo "577600c4441c101f9003e954d484e8bf299d2472827ad0d655a52043bef2f76e  $OVERLAY" | sha256sum -c --strict
tar -xJf "$OVERLAY" -C "$TEMPLATE"
TEMPLATE="$TEMPLATE/albay"
test -f "$TEMPLATE/CMakeLists.txt"
grep -Fq 'project(Albay VERSION 4.1.0 LANGUAGES CXX)' "$TEMPLATE/CMakeLists.txt"

mkdir -p "$TEMPLATE/tools"
cp "$WORK/phase30_audit_android_elf.py" "$TEMPLATE/tools/audit_android_elf.py"
cp "$WORK/phase30_audit_native_exports.py" "$TEMPLATE/tools/audit_native_exports.py"
echo "bd001bbd159d1b6c32305af9acc31f7ad273b87b7f32f661027863960f6f2c1a  $TEMPLATE/tools/audit_android_elf.py" | sha256sum -c --strict
echo "b9209bb757cc1220b0bd54a1c5049d0a6331892432e05bbbe10aa358b776cf46  $TEMPLATE/tools/audit_native_exports.py" | sha256sum -c --strict

printf '== Regenerate byte-identical embedded TB3 ==\n'
cat > /tmp/albay_tb3_stubs.cpp <<'CPP'
#include "albay/draw_rules.h"
#include "albay/position.h"
namespace albay {
uint8_t three_kings_vs_one_eligible_mask(const Position&) { return 0; }
RegulationDescriptor regulation_descriptor(const Position&) { return {}; }
}
CPP
g++ -std=c++20 -O2 -pthread -I"$TEMPLATE/include" \
  "$WORK/phase30_tb3_generate.cpp" \
  "$TEMPLATE/src/bitboard.cpp" "$TEMPLATE/src/move.cpp" "$TEMPLATE/src/movegen.cpp" \
  "$TEMPLATE/src/position.cpp" "$TEMPLATE/src/zobrist.cpp" /tmp/albay_tb3_stubs.cpp \
  -o /tmp/albay_tb3_generate
/tmp/albay_tb3_generate /tmp/albay_tb3.bin "$ART/tb3-regeneration-stats.json" \
  > "$ART/tb3-regeneration.stdout" 2> "$ART/tb3-regeneration.stderr"
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
mv /tmp/tb3_data.inc "$TEMPLATE/src/tb3_data.inc"

(cd "$TEMPLATE" && find . -type f -not -path './build/*' -not -path './dist/*' -print0 | sort -z | xargs -0 sha256sum) > "$ART/SOURCE_FILE_SHA256SUMS.txt"
sha256sum "$ART/SOURCE_FILE_SHA256SUMS.txt" > "$ART/SOURCE_TREE_DIGEST.txt"

printf '== Install exact official NDK r29 ==\n'
SDKMANAGER="${ANDROID_SDK_ROOT}/cmdline-tools/latest/bin/sdkmanager"
yes | "$SDKMANAGER" --licenses >/dev/null || true
"$SDKMANAGER" "ndk;$NDK_REV"
NDK="${ANDROID_SDK_ROOT}/ndk/$NDK_REV"
grep -Eq '^Pkg.Revision[[:space:]]*=[[:space:]]*29\.0\.14206865[[:space:]]*$' "$NDK/source.properties"
cp "$NDK/source.properties" "$ART/NDK_SOURCE_PROPERTIES.txt"

build_once() {
  local label="$1"
  printf '== Clean reproducibility build %s ==\n' "$label"
  rm -rf "$SRC" "$BUILD" "$DIST"
  cp -a "$TEMPLATE" "$SRC"
  chmod +x "$SRC/scripts/build_android_arm64.sh"
  ANDROID_NDK_ROOT="$NDK" ANDROID_PLATFORM=android-29 JOBS=2 \
    BUILD_DIR="$BUILD" DIST_DIR="$DIST" CLEAN_BUILD=1 \
    "$SRC/scripts/build_android_arm64.sh" \
    > "$ART/build-${label}.log" 2>&1
  mkdir -p "$ART/$label"
  cp "$DIST/libalbay.so" "$ART/$label/libalbay.so"
  cp "$DIST/libalbay.so.unstripped" "$ART/$label/libalbay.so.unstripped"
  cp "$DIST/SHA256SUMS.txt" "$ART/$label/SHA256SUMS.txt"
  cp "$DIST/android_elf_audit.json" "$ART/$label/android_elf_audit.json"
  cp "$DIST/native_export_audit.json" "$ART/$label/native_export_audit.json"
  cp "$DIST/BUILD_INFO.txt" "$ART/$label/BUILD_INFO.txt"
  "$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-readelf" -W -n "$DIST/libalbay.so" > "$ART/$label/elf_notes.txt"
}

build_once run-A
build_once run-B

printf '== Byte-for-byte comparison ==\n'
cmp -s "$ART/run-A/libalbay.so" "$ART/run-B/libalbay.so"
cmp -s "$ART/run-A/libalbay.so.unstripped" "$ART/run-B/libalbay.so.unstripped"
sha256sum "$ART/run-A/libalbay.so" "$ART/run-B/libalbay.so" > "$ART/PRODUCTION_SHA256_COMPARISON.txt"
sha256sum "$ART/run-A/libalbay.so.unstripped" "$ART/run-B/libalbay.so.unstripped" > "$ART/UNSTRIPPED_SHA256_COMPARISON.txt"
PROD_A=$(sha256sum "$ART/run-A/libalbay.so" | awk '{print $1}')
PROD_B=$(sha256sum "$ART/run-B/libalbay.so" | awk '{print $1}')
DBG_A=$(sha256sum "$ART/run-A/libalbay.so.unstripped" | awk '{print $1}')
DBG_B=$(sha256sum "$ART/run-B/libalbay.so.unstripped" | awk '{print $1}')
[[ "$PROD_A" == "$PROD_B" ]]
[[ "$DBG_A" == "$DBG_B" ]]
cat > "$ART/PHASE32_REPRODUCIBILITY_STATUS.txt" <<EOF2
Status=PASS
Engine=Albay 4.1.0
Phase=32_PRE_RC
NDK=$NDK_REV
ABI=arm64-v8a
Platform=android-29
SOURCE_DATE_EPOCH=$SOURCE_DATE_EPOCH
ProductionByteIdentical=YES
UnstrippedByteIdentical=YES
ProductionSHA256=$PROD_A
UnstrippedSHA256=$DBG_A
PhysicalAndroid60MinuteSoak=PENDING
StableRC=PENDING_PHASE31_ACCEPTANCE
EOF2
printf 'ALBAY_PHASE32_ANDROID_REPRODUCIBILITY_PASS\n'
