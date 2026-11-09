#!/usr/bin/env bash
# Builds Mono from dotnet/runtime with StS2Mono's patches (patch-mono.ps1).
# Needs macOS with Xcode, git and PowerShell (pwsh).
#
# Usage: mono/build-mono.sh <ios|osx> <output dir>
#   ios  lib/*.a (the runtime, linked into the bridge) and cross/mono-aot-cross,
#        the AOT compiler for CoreLib; both from the same build, as the AOT image
#        must match the runtime's version
#   osx  libcoreclr.dylib (desktop Mono) and its System.Private.CoreLib.dll, for
#        harmony/test-desktop.sh
set -euo pipefail

TARGET_OS="$1"
OUT="$2"
TAG="${DOTNET_RUNTIME_TAG:-v9.0.22}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/work/runtime"

# For iOS, mono.runtime also builds the AOT cross compiler (in obj/.../cross).
case "$TARGET_OS" in
    ios) SUBSETS="mono.runtime" ;;
    osx) SUBSETS="mono.runtime+mono.corelib" ;;
    *) echo "unknown target '$TARGET_OS' (ios or osx)" >&2; exit 2 ;;
esac

echo "::group::clone dotnet/runtime $TAG"
rm -rf "$SRC"
git clone --quiet --depth 1 --branch "$TAG" https://github.com/dotnet/runtime.git "$SRC"
df -h "$SRC"
echo "::endgroup::"

pwsh -NoProfile -File "$ROOT/mono/patch-mono.ps1" -RuntimeRoot "$SRC"

echo "::group::build $SUBSETS for $TARGET_OS-arm64"
# CMake 4 rejects projects declaring compatibility with CMake older than 3.5.
export CMAKE_POLICY_VERSION_MINIMUM=3.5
(cd "$SRC" && ./build.sh "$SUBSETS" -os "$TARGET_OS" -arch arm64 -c Release \
    /p:MonoEnableLLVM=false /p:MonoAOTEnableLLVM=false)
echo "::endgroup::"

ARTIFACTS="$SRC/artifacts"
BIN="$ARTIFACTS/bin/mono/$TARGET_OS.arm64.Release"
OBJ="$ARTIFACTS/obj/mono/$TARGET_OS.arm64.Release"

# The first of the given paths that is a file. Lists the outputs if none is.
first() {
    for f in "$@"; do
        if [ -f "$f" ]; then
            echo "$f"
            return
        fi
    done
    echo "none of these exist: $*" >&2
    find "$BIN" "$OBJ/out" "$OBJ/cross/out" -maxdepth 3 2>/dev/null | head -300 >&2
    return 1
}

rm -rf "$OUT"
mkdir -p "$OUT"
if [ "$TARGET_OS" = ios ]; then
    # Not obj/.../cross/out/lib: those are the cross compiler's own macOS libraries.
    RUNTIME_LIB="$(first "$BIN/libmonosgen-2.0.a" "$OBJ/out/lib/libmonosgen-2.0.a")"
    CROSS="$(first "$BIN/cross/ios-arm64/mono-aot-cross" "$OBJ/cross/out/bin/mono-aot-cross")"
    mkdir -p "$OUT/lib" "$OUT/cross"
    cp "$(dirname "$RUNTIME_LIB")"/*.a "$OUT/lib/"
    cp "$CROSS" "$OUT/cross/mono-aot-cross"
else
    RUNTIME_LIB="$(first "$BIN/libcoreclr.dylib" "$OBJ/out/lib/libcoreclr.dylib" "$BIN/libmonosgen-2.0.dylib" "$OBJ/out/lib/libmonosgen-2.0.dylib")"
    CORELIB="$(first "$BIN/System.Private.CoreLib.dll" "$BIN/IL/System.Private.CoreLib.dll" \
        "$ARTIFACTS/bin/System.Private.CoreLib/Release/System.Private.CoreLib.dll")"
    cp "$RUNTIME_LIB" "$OUT/libcoreclr.dylib"
    cp "$CORELIB" "$OUT/System.Private.CoreLib.dll"
fi
echo "$TAG with $(basename "$ROOT")/mono/patch-mono.ps1" > "$OUT/SOURCE.txt"
find "$OUT" -type f -exec ls -la {} \;
