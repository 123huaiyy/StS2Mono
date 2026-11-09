#!/usr/bin/env bash
# Builds StS2Mono.dylib (Mono runtime + AOT-compiled CoreLib + bridge) for iOS
# arm64 and collects the matching base class library. Needs macOS with Xcode.
# No game files are involved.
#
# Inputs (environment):
#   MONO_BUILD   output of `mono/build-mono.sh ios`: Mono built from Microsoft's
#                sources with StS2Mono's interpreter patches, and the AOT compiler
#                from the same build
#   HARMONY_OUT  output of `harmony/build.sh`: 0Harmony.dll rewritten for StS2Mono
#                and StS2Mono.Harmony.dll
# The class libraries, CoreLib and their native helpers come from Microsoft's
# runtime package of the same version.
set -euo pipefail

NET_VERSION="${NET_VERSION:-9.0.22}"
BRIDGE_VERSION="${BRIDGE_VERSION:-dev}"
MIN_IOS="14.0"

ROOT="$(cd "$(dirname "$0")" && pwd)"
WORK="$ROOT/work/bridge"
OUT="$ROOT/out"
MONO_BUILD="$(cd "${MONO_BUILD:?set MONO_BUILD to the output of mono/build-mono.sh ios}" && pwd)"
HARMONY_OUT="$(cd "${HARMONY_OUT:?set HARMONY_OUT to the output of harmony/build.sh}" && pwd)"
rm -rf "$WORK" "$OUT"
mkdir -p "$WORK" "$OUT/dotnet"

SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
CC="$(xcrun --sdk iphoneos -f clang)"
CFLAGS=(-isysroot "$SDK" -arch arm64 -miphoneos-version-min="$MIN_IOS")

fetch() {
    local id="$1" dest="$2"
    echo "::group::download $id $NET_VERSION"
    curl -fsSL --retry 5 -o "$WORK/$id.nupkg" \
        "https://api.nuget.org/v3-flatcontainer/$id/$NET_VERSION/$id.$NET_VERSION.nupkg"
    mkdir -p "$dest"
    unzip -q -o "$WORK/$id.nupkg" -d "$dest"
    echo "::endgroup::"
}

fetch microsoft.netcore.app.runtime.mono.ios-arm64 "$WORK/runtime"
NATIVE="$WORK/runtime/runtimes/ios-arm64/native"
LIB="$WORK/runtime/runtimes/ios-arm64/lib/net9.0"
MONO_LIB="$MONO_BUILD/lib"
AOT="$MONO_BUILD/cross/mono-aot-cross"
chmod +x "$MONO_BUILD/cross/"* # build artifacts lose the executable bit

# The interpreter cannot create native<->managed trampolines without a JIT, so
# CoreLib is AOT-compiled with interpreter support, the way .NET for iOS does it.
echo "::group::AOT-compile System.Private.CoreLib"
mkdir -p "$WORK/aot-out"
AOT_ARGS="static,asmonly,direct-icalls,full,interp,mtriple=arm64-ios"
AOT_ARGS+=",ntrampolines=16384,nrgctx-trampolines=16384,nimt-trampolines=2048"
AOT_ARGS+=",ngsharedvt-trampolines=16384,nftnptr-arg-trampolines=8192,nunbox-arbitrary-trampolines=4096"
AOT_ARGS+=",outfile=$WORK/aot-out/System.Private.CoreLib.dll.s"
"$AOT" --version || true
MONO_PATH="$NATIVE:$LIB" "$AOT" --aot="$AOT_ARGS" "$NATIVE/System.Private.CoreLib.dll"
"$CC" "${CFLAGS[@]}" -c "$WORK/aot-out/System.Private.CoreLib.dll.s" -o "$WORK/aot-out/System.Private.CoreLib.o"
echo "::endgroup::"

# P/Invokes into these libraries are answered from a lookup table instead of
# dlopen, since the libraries are linked into the dylib itself.
echo "::group::native symbol table"
NATIVE_LIBS=(
    "$NATIVE/libSystem.Native.a"
    "$NATIVE/libSystem.IO.Compression.Native.a"
    "$NATIVE/libSystem.Security.Cryptography.Native.Apple.a"
)
for lib in "${NATIVE_LIBS[@]}"; do
    nm -gU "$lib" 2>/dev/null | awk '$2 == "T" { print $3 }'
done | sed 's/^_//' | grep -E '^(SystemNative_|CompressionNative_|Brotli|AppleCryptoNative_)' \
    | LC_ALL=C sort -u > "$WORK/native_syms.txt"
{
    echo '#include <stddef.h>'
    echo 'typedef struct { const char *name; void *fn; } bridge_sym;'
    while read -r s; do echo "extern void $s(void);"; done < "$WORK/native_syms.txt"
    echo 'const bridge_sym bridge_native_syms[] = {'
    while read -r s; do echo "    { \"$s\", (void *)$s },"; done < "$WORK/native_syms.txt"
    echo '};'
    echo 'const size_t bridge_native_syms_count = sizeof bridge_native_syms / sizeof bridge_native_syms[0];'
} > "$WORK/native_syms.c"
echo "$(wc -l < "$WORK/native_syms.txt") native functions"
echo "::endgroup::"

echo "::group::compile and link"
"$CC" "${CFLAGS[@]}" -fobjc-arc -O2 -Wall -I "$NATIVE/include/mono-2.0" \
    -DBRIDGE_VERSION="\"$BRIDGE_VERSION\"" -DRUNTIME_VERSION="\"$NET_VERSION+sts2mono\"" \
    -c "$ROOT/src/bridge.m" -o "$WORK/bridge.o"
"$CC" "${CFLAGS[@]}" -O2 -c "$WORK/native_syms.c" -o "$WORK/native_syms.o"

SWIFT_TOOLCHAIN_LIB="$(dirname "$(xcrun --sdk iphoneos -f swiftc)")/../lib/swift/iphoneos"
"$CC" "${CFLAGS[@]}" -dynamiclib -o "$OUT/StS2Mono.dylib" -install_name @rpath/StS2Mono.dylib \
    "$WORK/bridge.o" "$WORK/native_syms.o" "$WORK/aot-out/System.Private.CoreLib.o" \
    "$MONO_LIB/libmonosgen-2.0.a" \
    "$MONO_LIB/libmono-component-marshal-ilgen-static.a" \
    "$MONO_LIB/libmono-component-hot_reload-stub-static.a" \
    "$MONO_LIB/libmono-component-debugger-stub-static.a" \
    "$MONO_LIB/libmono-component-diagnostics_tracing-stub-static.a" \
    "${NATIVE_LIBS[@]}" \
    -L "$SDK/usr/lib/swift" -L "$SWIFT_TOOLCHAIN_LIB" -Wl,-rpath,/usr/lib/swift \
    -framework Foundation -framework Security -framework CryptoKit -framework UIKit \
    -lc++ -lz -liconv
codesign --force --sign - "$OUT/StS2Mono.dylib"
echo "::endgroup::"

echo "::group::check the result"
otool -L "$OUT/StS2Mono.dylib"
EXPORTS="$(nm -gU "$OUT/StS2Mono.dylib" | grep -E ' _(coreclr_initialize|coreclr_create_delegate|mono_aot_module_System_Private_CoreLib_info|mono_interp_redirect_method)$')"
echo "$EXPORTS"
[ "$(echo "$EXPORTS" | wc -l)" -eq 4 ] || { echo "missing exports" >&2; exit 1; }
echo "::endgroup::"

# The managed side must be this exact CoreLib: the AOT image is tied to it.
cp "$NATIVE/System.Private.CoreLib.dll" "$OUT/dotnet/"
cp "$LIB/"*.dll "$OUT/dotnet/"
cp "$HARMONY_OUT/0Harmony.dll" "$HARMONY_OUT/StS2Mono.Harmony.dll" "$HARMONY_OUT/StS2Mono.Harmony.pdb" "$OUT/dotnet/"
echo "$NET_VERSION" > "$OUT/dotnet/RUNTIME_VERSION.txt"
cp "$MONO_BUILD/SOURCE.txt" "$OUT/MONO_SOURCE.txt"
ls -la "$OUT"
du -sh "$OUT/StS2Mono.dylib" "$OUT/dotnet"
