#!/usr/bin/env bash
# Runs harmony/HarmonyTest on StS2Mono's Mono build for macOS arm64, with every
# method interpreted and no inlining, as the game runs on iOS.
# Usage: harmony/test-desktop.sh <mono/build-mono.sh osx output> <harmony/build.sh output>
set -euo pipefail

NET_VERSION="${NET_VERSION:-9.0.22}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MONO_BUILD="$(cd "$1" && pwd)"
HARMONY_OUT="$(cd "$2" && pwd)"
APP="$ROOT/work/harmonytest"
rm -rf "$APP"

# A self-contained CoreCLR app, then Mono swapped in: the class libraries and
# their native helpers are the same for both runtimes, CoreLib is not.
dotnet publish "$ROOT/harmony/HarmonyTest/HarmonyTest.csproj" -c Release -r osx-arm64 --self-contained \
    -p:RuntimeFrameworkVersion="$NET_VERSION" -p:HarmonyDir="$HARMONY_OUT/" -o "$APP" --nologo
cp "$MONO_BUILD/libcoreclr.dylib" "$APP/libcoreclr.dylib"
cp "$MONO_BUILD/System.Private.CoreLib.dll" "$APP/System.Private.CoreLib.dll"
# The stand-in library without the type the test's Orphan class is built on.
dotnet build "$ROOT/harmony/HarmonyTest.Missing/HarmonyTest.Missing.csproj" -c Release \
    -p:DefineConstants=WITHOUT_TYPES -o "$ROOT/work/harmonytest-missing" --nologo
cp "$ROOT/work/harmonytest-missing/HarmonyTest.Missing.dll" "$APP/"

# Once for each way MonoMod can make Harmony's replacement methods: a DynamicMethod
# (the default), or a method in a generated assembly (MethodBuilder, Cecil).
for generator in "" mb cecil; do
    echo "::group::replacements by the ${generator:-default} generator"
    if [ -n "$generator" ]; then export MONOMOD_DMDType="$generator"; else unset MONOMOD_DMDType; fi
    MONO_ENV_OPTIONS="--interpreter" MONO_INTERPRETER_OPTIONS="-inline" "$APP/StS2Mono.HarmonyTest"
    echo "::endgroup::"
done
