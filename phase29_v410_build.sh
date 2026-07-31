#!/usr/bin/env bash
set -euo pipefail

mkdir -p artifact /tmp/albay-old /tmp/albay-overlay /tmp/albay-v410
exec > >(tee artifact/phase29-run.log) 2>&1

printf '== Reconstruct legacy carrier and verify current TB3 payload ==\n'
test "$(find ci_source -maxdepth 1 -name 'part-*.b64' | wc -l)" -eq 9
cat ci_source/part-*.b64 | base64 --decode > /tmp/albay-old.tar.xz
echo "1f137dcfda27a3484f07e40c9e1dc38687f68f137777e626135425dd9cb4756e  /tmp/albay-old.tar.xz" | sha256sum -c --strict
tar -xJf /tmp/albay-old.tar.xz -C /tmp/albay-old
OLD_SRC=/tmp/albay-old/albay_minimal
test -f "$OLD_SRC/src/tb3_data.inc"
echo "dad96580c6f74f746159b8c0490566a65c041623ca4a968b234a13aa070ee2bb  $OLD_SRC/src/tb3_data.inc" | sha256sum -c --strict
cp "$OLD_SRC/src/tb3_data.inc" /tmp/tb3_data.inc

printf '== Reconstruct exact Albay v4.1.0 overlay ==\n'
test "$(find phase29_v410_overlay10 -maxdepth 1 -name 'part-*.b64' | wc -l)" -eq 5
cat phase29_v410_overlay10/part-*.b64 | base64 --decode > /tmp/albay-v410-overlay.tar.xz
echo "577600c4441c101f9003e954d484e8bf299d2472827ad0d655a52043bef2f76e  /tmp/albay-v410-overlay.tar.xz" | sha256sum -c --strict
tar -xJf /tmp/albay-v410-overlay.tar.xz -C /tmp/albay-overlay
test -f /tmp/albay-overlay/albay/CMakeLists.txt
cp -a /tmp/albay-overlay/albay/. /tmp/albay-v410/
cp /tmp/tb3_data.inc /tmp/albay-v410/src/tb3_data.inc
chmod +x /tmp/albay-v410/scripts/build_android_arm64.sh

grep -Fq 'project(Albay VERSION 4.1.0 LANGUAGES CXX)' /tmp/albay-v410/CMakeLists.txt
grep -Fq 'EXPECTED_NDK_REVISION="${EXPECTED_NDK_REVISION:-29.0.14206865}"' /tmp/albay-v410/scripts/build_android_arm64.sh
grep -Fq -- '-Wl,-z,max-page-size=16384' /tmp/albay-v410/CMakeLists.txt
echo "dad96580c6f74f746159b8c0490566a65c041623ca4a968b234a13aa070ee2bb  /tmp/albay-v410/src/tb3_data.inc" | sha256sum -c --strict
(cd /tmp/albay-v410 && find . -type f -print0 | sort -z | xargs -0 sha256sum) > artifact/SOURCE_SHA256SUMS.txt
sha256sum /tmp/albay-old.tar.xz /tmp/albay-v410-overlay.tar.xz /tmp/albay-v410/src/tb3_data.inc > artifact/INPUT_SHA256SUMS.txt

printf '== Install and verify exact NDK r29 ==\n'
SDKMANAGER="${ANDROID_SDK_ROOT}/cmdline-tools/latest/bin/sdkmanager"
yes | "$SDKMANAGER" --licenses >/dev/null || true
"$SDKMANAGER" "ndk;29.0.14206865"
NDK="${ANDROID_SDK_ROOT}/ndk/29.0.14206865"
test -f "$NDK/source.properties"
grep -Eq '^Pkg.Revision[[:space:]]*=[[:space:]]*29\.0\.14206865[[:space:]]*$' "$NDK/source.properties"
cp "$NDK/source.properties" artifact/NDK_SOURCE_PROPERTIES.txt

printf '== Build real Android ARM64 library and run project audits ==\n'
export ANDROID_NDK_ROOT="$NDK"
export ANDROID_PLATFORM=android-29
export JOBS=2
(cd /tmp/albay-v410 && ./scripts/build_android_arm64.sh) 2>&1 | tee artifact/phase29-build.log

printf '== Create debug symbols and independent ELF evidence ==\n'
TOOLS="$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin"
DIST=/tmp/albay-v410/dist/android/arm64-v8a
test -f "$DIST/libalbay.so"
test -f "$DIST/libalbay.so.unstripped"
"$TOOLS/llvm-objcopy" --only-keep-debug "$DIST/libalbay.so.unstripped" "$DIST/libalbay.so.debug"
"$TOOLS/llvm-objcopy" --add-gnu-debuglink="$DIST/libalbay.so.debug" "$DIST/libalbay.so"

"$TOOLS/llvm-readelf" -W -h "$DIST/libalbay.so" > artifact/independent-elf-header.txt
"$TOOLS/llvm-readelf" -W -l "$DIST/libalbay.so" > artifact/independent-program-headers.txt
"$TOOLS/llvm-readelf" -W -d "$DIST/libalbay.so" > artifact/independent-dynamic.txt
"$TOOLS/llvm-readelf" -W -n "$DIST/libalbay.so" > artifact/independent-notes.txt
"$TOOLS/llvm-nm" -D --defined-only "$DIST/libalbay.so" > artifact/independent-exports.txt

grep -Eq 'Machine:[[:space:]]+AArch64' artifact/independent-elf-header.txt
grep -Eq 'Type:[[:space:]]+DYN' artifact/independent-elf-header.txt
grep -Eq '\(SONAME\).+\[libalbay\.so\]' artifact/independent-dynamic.txt
! grep -Eq 'libstdc\+\+\.so\.6|libgcc_s\.so\.1|libc\+\+_shared\.so' artifact/independent-dynamic.txt
grep -Eq '[[:space:]]JNI_OnLoad$' artifact/independent-exports.txt
grep -Eq '[[:space:]]JNI_OnUnload$' artifact/independent-exports.txt
awk '$1 == "LOAD" {print}' artifact/independent-program-headers.txt > artifact/independent-load-segments.txt
test "$(awk '$1 == "LOAD" && $NF != "0x4000" {bad++} END {print bad+0}' artifact/independent-load-segments.txt)" -eq 0

cp -a "$DIST" artifact/arm64-v8a
sha256sum artifact/arm64-v8a/libalbay.so artifact/arm64-v8a/libalbay.so.unstripped artifact/arm64-v8a/libalbay.so.debug > artifact/FINAL_SHA256SUMS.txt
cat > artifact/PHASE29_BUILD_INFO.txt <<'INFO'
Status=PASS
Engine=Albay 4.1.0
Phase=29
NDK=29.0.14206865
ABI=arm64-v8a
Platform=android-29
STL=c++_static
ELFMachine=AArch64
ELFType=ET_DYN
PageAlignment=16384
Interfaces=JNI+C_API
DebugSymbols=separate
INFO

printf 'Phase 29 GitHub runner build: PASS\n'
