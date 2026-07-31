#!/usr/bin/env bash
set -euo pipefail

WORK="$PWD"
ART="$WORK/artifact"
OVERLAY_ARCHIVE=/tmp/albay-v410-overlay.tar.xz
EXTRACT=/tmp/albay-overlay
SRC="$EXTRACT/albay"
HOST=/tmp/albay-host
JAR_CLASSES=/tmp/albay-jni-classes
mkdir -p "$ART" "$EXTRACT" "$JAR_CLASSES"
exec > >(tee "$ART/phase30-ci.log") 2>&1

printf '== Reconstruct exact Albay v4.1.0 source overlay ==\n'
test "$(find phase29_v410_overlay10 -maxdepth 1 -name 'part-*.b64' | wc -l)" -eq 5
cat phase29_v410_overlay10/part-*.b64 | base64 --decode > "$OVERLAY_ARCHIVE"
echo "577600c4441c101f9003e954d484e8bf299d2472827ad0d655a52043bef2f76e  $OVERLAY_ARCHIVE" | sha256sum -c --strict
tar -xJf "$OVERLAY_ARCHIVE" -C "$EXTRACT"
test -f "$SRC/CMakeLists.txt"
grep -Fq 'project(Albay VERSION 4.1.0 LANGUAGES CXX)' "$SRC/CMakeLists.txt"

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
  "$SRC/tools/tb3_generate.cpp" \
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

printf '== Host Release regression, ctypes and JNI smoke ==\n'
cmake -S "$SRC" -B "$HOST" -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DALBAY_BUILD_TESTS=ON \
  -DALBAY_BUILD_TOOLS=OFF \
  -DALBAY_BUILD_HOST_JNI=ON \
  -DALBAY_USE_SANITIZERS=OFF
cmake --build "$HOST" --parallel 2
ctest --test-dir "$HOST" --output-on-failure 2>&1 | tee "$ART/host-ctest.log"
python3 "$SRC/tests/python_ctypes_smoke.py" "$HOST/libalbay.so" "$SRC" \
  2>&1 | tee "$ART/host-ctypes-smoke.log"
javac -encoding UTF-8 -d "$JAR_CLASSES" \
  "$SRC/jni/java/com/albay/engine/AlbayMove.java" \
  "$SRC/jni/java/com/albay/engine/AlbaySearchInfo.java" \
  "$SRC/jni/java/com/albay/engine/AlbayEngine.java" \
  "$SRC/tests/jni/AlbayJniSmokeTest.java"
java -Dalbay.native.path="$HOST/libalbay_jni.so" -cp "$JAR_CLASSES" \
  com.albay.engine.AlbayJniSmokeTest "$SRC" \
  2>&1 | tee "$ART/host-jni-smoke.log"

printf '== Install exact Android NDK r29 ==\n'
SDKMANAGER="${ANDROID_SDK_ROOT}/cmdline-tools/latest/bin/sdkmanager"
yes | "$SDKMANAGER" --licenses >/dev/null || true
"$SDKMANAGER" "ndk;29.0.14206865"
NDK="${ANDROID_SDK_ROOT}/ndk/29.0.14206865"
test -f "$NDK/source.properties"
grep -Eq '^Pkg.Revision[[:space:]]*=[[:space:]]*29\.0\.14206865[[:space:]]*$' "$NDK/source.properties"
cp "$NDK/source.properties" "$ART/NDK_SOURCE_PROPERTIES.txt"

printf '== Build real Android arm64-v8a production library ==\n'
export ANDROID_NDK_ROOT="$NDK"
export ANDROID_PLATFORM=android-29
export JOBS=2
chmod +x "$SRC/scripts/build_android_arm64.sh"
"$SRC/scripts/build_android_arm64.sh" 2>&1 | tee "$ART/android-build-and-audit.log"
DIST="$SRC/dist/android/arm64-v8a"
TOOLS="$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin"
test -f "$DIST/libalbay.so"
test -f "$DIST/libalbay.so.unstripped"
"$TOOLS/llvm-objcopy" --only-keep-debug "$DIST/libalbay.so.unstripped" "$DIST/libalbay.so.debug"
"$TOOLS/llvm-objcopy" --add-gnu-debuglink=libalbay.so.debug "$DIST/libalbay.so"

printf '== Independent final ELF/export audit ==\n'
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

printf '== Create physical-device/Pydroid 3 smoke kit ==\n'
KIT="$ART/Albay-v4.1.0-Phase30-DEVICE-TEST-KIT"
mkdir -p "$KIT/lib/arm64-v8a" "$KIT/python" "$KIT/java/com/albay/engine" "$KIT/assets"
cp "$DIST/libalbay.so" "$KIT/lib/arm64-v8a/"
cp "$DIST/libalbay.so.unstripped" "$KIT/lib/arm64-v8a/"
cp "$DIST/libalbay.so.debug" "$KIT/lib/arm64-v8a/"
cp "$SRC/bindings/python/albay_ctypes.py" "$KIT/python/"
cp "$SRC/tests/python_ctypes_smoke.py" "$KIT/python/"
cp "$SRC/jni/java/com/albay/engine/AlbayMove.java" "$KIT/java/com/albay/engine/"
cp "$SRC/jni/java/com/albay/engine/AlbaySearchInfo.java" "$KIT/java/com/albay/engine/"
cp "$SRC/jni/java/com/albay/engine/AlbayEngine.java" "$KIT/java/com/albay/engine/"
cp "$SRC/tests/jni/AlbayJniSmokeTest.java" "$KIT/java/com/albay/engine/"
cp "$SRC/opening_book/albay_opening_book_v3.4.0.albob15" "$KIT/assets/"
cp "$SRC/loss_memory/albay_loss_memory_v3.4.0.alblm13" "$KIT/assets/"
cp -a "$DIST" "$ART/arm64-v8a"

javac -encoding UTF-8 -d "$JAR_CLASSES" \
  "$KIT/java/com/albay/engine/AlbayMove.java" \
  "$KIT/java/com/albay/engine/AlbaySearchInfo.java" \
  "$KIT/java/com/albay/engine/AlbayEngine.java" \
  "$KIT/java/com/albay/engine/AlbayJniSmokeTest.java"
jar --create --file "$KIT/phase30-jni-smoke.jar" -C "$JAR_CLASSES" .

cat > "$KIT/PHASE30_BUILD_INFO.txt" <<EOF
Status=DEVICE_EXECUTION_PENDING
Engine=Albay 4.1.0
NDK=29.0.14206865
ABI=arm64-v8a
Platform=android-29
PageAlignment=16384
HostCTest=PASS
HostCtypes=PASS
HostJNI=PASS
AndroidELF=PASS
PhysicalAndroid=PENDING
Pydroid3=PENDING
EOF
sha256sum "$KIT/lib/arm64-v8a/libalbay.so" \
  "$KIT/lib/arm64-v8a/libalbay.so.unstripped" \
  "$KIT/lib/arm64-v8a/libalbay.so.debug" > "$KIT/SHA256SUMS.txt"
sha256sum "$KIT/lib/arm64-v8a/libalbay.so" > "$ART/PRODUCTION_LIB_SHA256.txt"

printf 'PHASE30_CI_BUILD_PASS\n' | tee "$ART/PHASE30_CI_STATUS.txt"
