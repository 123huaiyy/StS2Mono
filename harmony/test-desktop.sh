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
    -p:RuntimeFrameworkVersion="$NET_VERSION" -p:HarmonyPath="$HARMONY_OUT/0Harmony.dll" -o "$APP" --nologo
cp "$HARMONY_OUT/0Harmony.dll" "$APP/"
cp "$MONO_BUILD/libcoreclr.dylib" "$APP/libcoreclr.dylib"
cp "$MONO_BUILD/System.Private.CoreLib.dll" "$APP/System.Private.CoreLib.dll"

MONO_ENV_OPTIONS="--interpreter" MONO_INTERPRETER_OPTIONS="-inline" "$APP/StS2Mono.HarmonyTest"
