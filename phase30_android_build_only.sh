#!/usr/bin/env bash
set -euo pipefail

WORK="$PWD"
ART="$WORK/artifact"
OVERLAY_ARCHIVE=/tmp/albay-v410-overlay.tar.xz
EXTRACT=/tmp/albay-overlay
SRC="$EXTRACT/albay"
mkdir -p "$ART" "$EXTRACT"
exec > >(tee "$ART/phase30-android-ci.log") 2>&1

printf '== Reconstruct exact Albay v4.1.0 Android source overlay ==\n'
test "$(find phase29_v410_overlay10 -maxdepth 1 -name 'part-*.b64' | wc -l)" -eq 5
cat phase29_v410_overlay10/part-*.b64 | base64 --decode > "$OVERLAY_ARCHIVE"
echo "577600c4441c101f9003e954d484e8bf299d2472827ad0d655a52043bef2f76e  $OVERLAY_ARCHIVE" | sha256sum -c --strict
tar -xJf "$OVERLAY_ARCHIVE" -C "$EXTRACT"
test -f "$SRC/CMakeLists.txt"
test -f "$SRC/scripts/build_android_arm64.sh"
grep -Fq 'project(Albay VERSION 4.1.0 LANGUAGES CXX)' "$SRC/CMakeLists.txt"

printf '== Restore exact fail-closed audit tools ==\n'
mkdir -p "$SRC/tools"
cp "$WORK/phase30_audit_android_elf.py" "$SRC/tools/audit_android_elf.py"
cp "$WORK/phase30_audit_native_exports.py" "$SRC/tools/audit_native_exports.py"
echo "bd001bbd159d1b6c32305af9acc31f7ad273b87b7f32f661027863960f6f2c1a  $SRC/tools/audit_android_elf.py" | sha256sum -c --strict
echo "b9209bb757cc1220b0bd54a1c5049d0a6331892432e05bbbe10aa358b776cf46  $SRC/tools/audit_native_exports.py" | sha256sum -c --strict

printf '== Deterministically regenerate exact embedded TB3 payload ==\n'
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
/usr/bin/time -f 'tb3_elapsed=%e tb3_maxrss_kb=%M' \
  /tmp/albay_tb3_generate /tmp/albay_tb3.bin "$ART/tb3-regeneration-stats.json" \
  2> >(tee "$ART/tb3-regeneration.log" >&2)
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

printf '== Install exact official Android NDK r29 ==\n'
SDKMANAGER="${ANDROID_SDK_ROOT}/cmdline-tools/latest/bin/sdkmanager"
yes | "$SDKMANAGER" --licenses >/dev/null || true
"$SDKMANAGER" "ndk;29.0.14206865"
NDK="${ANDROID_SDK_ROOT}/ndk/29.0.14206865"
test -f "$NDK/source.properties"
grep -Eq '^Pkg.Revision[[:space:]]*=[[:space:]]*29\.0\.14206865[[:space:]]*$' "$NDK/source.properties"
cp "$NDK/source.properties" "$ART/NDK_SOURCE_PROPERTIES.txt"

printf '== Build and execute source fail-closed Android audits ==\n'
export ANDROID_NDK_ROOT="$NDK"
export ANDROID_PLATFORM=android-29
export JOBS=2
chmod +x "$SRC/scripts/build_android_arm64.sh"
"$SRC/scripts/build_android_arm64.sh" 2>&1 | tee "$ART/android-build-and-source-audit.log"

DIST="$SRC/dist/android/arm64-v8a"
TOOLS="$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin"
test -f "$DIST/libalbay.so"
test -f "$DIST/libalbay.so.unstripped"
"$TOOLS/llvm-objcopy" --only-keep-debug "$DIST/libalbay.so.unstripped" "$DIST/libalbay.so.debug"

printf '== Independent second ELF, dependency, alignment and export audit ==\n'
"$TOOLS/llvm-readelf" -W -h "$DIST/libalbay.so" > "$ART/final-elf-header.txt"
"$TOOLS/llvm-readelf" -W -l "$DIST/libalbay.so" > "$ART/final-program-headers.txt"
"$TOOLS/llvm-readelf" -W -d "$DIST/libalbay.so" > "$ART/final-dynamic.txt"
"$TOOLS/llvm-readelf" -W -n "$DIST/libalbay.so" > "$ART/final-notes.txt"
"$TOOLS/llvm-nm" -D --defined-only "$DIST/libalbay.so" > "$ART/final-exports.txt"
grep -Eq 'Machine:[[:space:]]+AArch64' "$ART/final-elf-header.txt"
grep -Eq 'Type:[[:space:]]+DYN' "$ART/final-elf-header.txt"
grep -Eq '\(SONAME\).+\[libalbay\.so\]' "$ART/final-dynamic.txt"
! grep -Eq 'libstdc\+\+\.so\.6|libgcc_s\.so\.1|libc\+\+_shared\.so' "$ART/final-dynamic.txt"
grep -Eq '[[:space:]]JNI_OnLoad$' "$ART/final-exports.txt"
grep -Eq '[[:space:]]JNI_OnUnload$' "$ART/final-exports.txt"
awk '$1 == "LOAD" {print}' "$ART/final-program-headers.txt" > "$ART/final-load-segments.txt"
test "$(awk '$1 == "LOAD" && $NF != "0x4000" {bad++} END {print bad+0}' "$ART/final-load-segments.txt")" -eq 0

cp -a "$DIST" "$ART/arm64-v8a"
sha256sum "$ART/arm64-v8a/libalbay.so" \
  "$ART/arm64-v8a/libalbay.so.unstripped" \
  "$ART/arm64-v8a/libalbay.so.debug" > "$ART/FINAL_SHA256SUMS.txt"
cat > "$ART/PHASE30_CI_STATUS.txt" <<'EOF'
Status=BUILD_AND_AUDIT_PASS
Engine=Albay 4.1.0
NDK=29.0.14206865
ABI=arm64-v8a
Platform=android-29
PageAlignment=16384
HostCTest=PASS_LOCAL_COMPLETE_SOURCE
HostCtypes=PASS_LOCAL_COMPLETE_SOURCE
HostJNI=PASS_LOCAL_COMPLETE_SOURCE
AndroidBuild=PASS
AndroidELF=PASS
PhysicalAndroid=PENDING
Pydroid3=PENDING
EOF
printf 'PHASE30_ANDROID_BUILD_AND_AUDIT_PASS\n'
