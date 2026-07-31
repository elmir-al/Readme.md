#!/usr/bin/env bash
set -euo pipefail

WORK="$PWD"
ART="$WORK/artifact-phase32-canonical"
OVERLAY=/tmp/albay-v410-overlay.tar.xz
ROOT=/tmp/albay-overlay/albay
NDK_REV=29.0.14206865
EXPECTED_PROD=0fe549b095e64fef5d837155b334b7641b3e063d4fa5e6dea389fed5b52ae98b
EXPECTED_UNSTRIPPED=f330b6c8f559f82a81eabb7dd35bb4e8b2edf97ac7f2df670406384cce804d3c
unset SOURCE_DATE_EPOCH || true
export TZ=UTC LC_ALL=C LANG=C
rm -rf "$ART"
mkdir -p "$ART"
exec > >(tee "$ART/phase32-canonical-repro.log") 2>&1

printf '== Verify exact official NDK r29 ==\n'
SDKMANAGER="${ANDROID_SDK_ROOT}/cmdline-tools/latest/bin/sdkmanager"
yes | "$SDKMANAGER" --licenses >/dev/null || true
"$SDKMANAGER" "ndk;$NDK_REV"
NDK="${ANDROID_SDK_ROOT}/ndk/$NDK_REV"
grep -Eq '^Pkg.Revision[[:space:]]*=[[:space:]]*29\.0\.14206865[[:space:]]*$' "$NDK/source.properties"
cp "$NDK/source.properties" "$ART/NDK_SOURCE_PROPERTIES.txt"

printf '== Compile deterministic TB3 generator ==\n'
rm -rf /tmp/albay-generator-source
mkdir -p /tmp/albay-generator-source
test "$(find phase29_v410_overlay10 -maxdepth 1 -name 'part-*.b64' | wc -l)" -eq 5
cat phase29_v410_overlay10/part-*.b64 | base64 --decode > "$OVERLAY"
echo "577600c4441c101f9003e954d484e8bf299d2472827ad0d655a52043bef2f76e  $OVERLAY" | sha256sum -c --strict
tar -xJf "$OVERLAY" -C /tmp/albay-generator-source
GENSRC=/tmp/albay-generator-source/albay
cat > /tmp/albay_tb3_stubs.cpp <<'CPP'
#include "albay/draw_rules.h"
#include "albay/position.h"
namespace albay {
uint8_t three_kings_vs_one_eligible_mask(const Position&) { return 0; }
RegulationDescriptor regulation_descriptor(const Position&) { return {}; }
}
CPP
g++ -std=c++20 -O2 -pthread -I"$GENSRC/include" \
  "$WORK/phase30_tb3_generate.cpp" \
  "$GENSRC/src/bitboard.cpp" "$GENSRC/src/move.cpp" "$GENSRC/src/movegen.cpp" \
  "$GENSRC/src/position.cpp" "$GENSRC/src/zobrist.cpp" /tmp/albay_tb3_stubs.cpp \
  -o /tmp/albay_tb3_generate

prepare_source() {
  rm -rf /tmp/albay-overlay
  mkdir -p /tmp/albay-overlay
  tar -xJf "$OVERLAY" -C /tmp/albay-overlay
  test -f "$ROOT/CMakeLists.txt"
  mkdir -p "$ROOT/tools"
  cp "$WORK/phase30_audit_android_elf.py" "$ROOT/tools/audit_android_elf.py"
  cp "$WORK/phase30_audit_native_exports.py" "$ROOT/tools/audit_native_exports.py"
  echo "bd001bbd159d1b6c32305af9acc31f7ad273b87b7f32f661027863960f6f2c1a  $ROOT/tools/audit_android_elf.py" | sha256sum -c --strict
  echo "b9209bb757cc1220b0bd54a1c5049d0a6331892432e05bbbe10aa358b776cf46  $ROOT/tools/audit_native_exports.py" | sha256sum -c --strict
  /tmp/albay_tb3_generate /tmp/albay_tb3.bin /tmp/tb3-stats.json >/dev/null 2>/tmp/tb3.log
  echo "1f4397e72b63bd13f64e88c87d07432de802b5d12c54a4e38e66a6319fb3f9ec  /tmp/albay_tb3.bin" | sha256sum -c --strict
  python3 - <<'PY'
from pathlib import Path
payload = Path('/tmp/albay_tb3.bin').read_bytes()
lines=[]
for offset in range(0, len(payload), 16):
    chunk=payload[offset:offset+16]
    suffix=',' if offset+16 < len(payload) else ''
    lines.append('    '+', '.join(f'0x{x:02x}' for x in chunk)+suffix)
Path('/tmp/tb3_data.inc').write_text('\n'.join(lines)+'\n', encoding='ascii')
PY
  echo "dad96580c6f74f746159b8c0490566a65c041623ca4a968b234a13aa070ee2bb  /tmp/tb3_data.inc" | sha256sum -c --strict
  mv /tmp/tb3_data.inc "$ROOT/src/tb3_data.inc"
}

build_once() {
  local label="$1"
  printf '== Canonical clean build %s ==\n' "$label"
  prepare_source
  chmod +x "$ROOT/scripts/build_android_arm64.sh"
  ANDROID_NDK_ROOT="$NDK" ANDROID_PLATFORM=android-29 JOBS=2 CLEAN_BUILD=1 \
    "$ROOT/scripts/build_android_arm64.sh" > "$ART/build-${label}.log" 2>&1
  DIST="$ROOT/dist/android/arm64-v8a"
  mkdir -p "$ART/$label"
  cp "$DIST/libalbay.so" "$ART/$label/libalbay.so"
  cp "$DIST/libalbay.so.unstripped" "$ART/$label/libalbay.so.unstripped"
  cp "$DIST/android_elf_audit.json" "$ART/$label/android_elf_audit.json"
  cp "$DIST/native_export_audit.json" "$ART/$label/native_export_audit.json"
  cp "$DIST/BUILD_INFO.txt" "$ART/$label/BUILD_INFO.txt"
}

build_once run-A
build_once run-B
cmp -s "$ART/run-A/libalbay.so" "$ART/run-B/libalbay.so"
cmp -s "$ART/run-A/libalbay.so.unstripped" "$ART/run-B/libalbay.so.unstripped"
PROD=$(sha256sum "$ART/run-A/libalbay.so" | awk '{print $1}')
UNSTRIPPED=$(sha256sum "$ART/run-A/libalbay.so.unstripped" | awk '{print $1}')
[[ "$PROD" == "$EXPECTED_PROD" ]]
[[ "$UNSTRIPPED" == "$EXPECTED_UNSTRIPPED" ]]
sha256sum "$ART/run-A/libalbay.so" "$ART/run-B/libalbay.so" > "$ART/PRODUCTION_SHA256_COMPARISON.txt"
sha256sum "$ART/run-A/libalbay.so.unstripped" "$ART/run-B/libalbay.so.unstripped" > "$ART/UNSTRIPPED_SHA256_COMPARISON.txt"
cat > "$ART/PHASE32_CANONICAL_STATUS.txt" <<EOF2
Status=PASS
Engine=Albay 4.1.0
NDK=$NDK_REV
ABI=arm64-v8a
Platform=android-29
CanonicalSourcePath=/tmp/albay-overlay/albay
CanonicalBuildPath=/tmp/albay-overlay/albay/build/android-arm64-release
ProductionByteIdentical=YES
UnstrippedByteIdentical=YES
MatchesPhysicalTestedProductionHash=YES
ProductionSHA256=$PROD
UnstrippedSHA256=$UNSTRIPPED
PhysicalAndroid60MinuteSoak=PENDING
StableRC=PENDING_PHASE31_ACCEPTANCE
EOF2
printf 'ALBAY_PHASE32_ACCEPTED_BINARY_REPRODUCED_PASS\n'
