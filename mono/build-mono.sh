!/usr/bin/env bash
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

case "$TARGET_OS" in
    ios) SUBSETS="mono.runtime+mono.aotcross" ;;
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
BIN="$(find "$ARTIFACTS/bin/mono" -maxdepth 1 -type d -iname "$TARGET_OS.arm64.Release" | head -1)"
echo "runtime output: $BIN"

# The first file called $1 under $BIN, else anywhere under artifacts/ (not obj/ref).
pick() {
    local found
    found="$(find "$BIN" -name "$1" -type f 2>/dev/null | head -1)"
    if [ -z "$found" ]; then
        found="$(find "$ARTIFACTS" -name "$1" -type f -not -path '*/ref/*' 2>/dev/null | head -1)"
    fi
    if [ -z "$found" ]; then
        echo "$1 not found in the build output" >&2
        find "$ARTIFACTS/bin" -maxdepth 4 | head -200 >&2
        exit 1
    fi
    echo "$found"
}

rm -rf "$OUT"
mkdir -p "$OUT"
if [ "$TARGET_OS" = ios ]; then
    RUNTIME_LIB="$(pick libmonosgen-2.0.a)"
    mkdir -p "$OUT/lib" "$OUT/cross"
    cp "$(dirname "$RUNTIME_LIB")"/*.a "$OUT/lib/"
    CROSS="$(pick mono-aot-cross)"
    cp -R "$(dirname "$CROSS")/." "$OUT/cross/"
else
    RUNTIME_LIB="$(find "$BIN" -name libcoreclr.dylib -type f | head -1)"
    [ -n "$RUNTIME_LIB" ] || RUNTIME_LIB="$(pick libmonosgen-2.0.dylib)"
    cp "$RUNTIME_LIB" "$OUT/libcoreclr.dylib"
    cp "$(pick System.Private.CoreLib.dll)" "$OUT/System.Private.CoreLib.dll"
fi
echo "$TAG with $(basename "$ROOT")/mono/patch-mono.ps1" > "$OUT/SOURCE.txt"
find "$OUT" -type f -exec ls -la {} \;
