!/usr/bin/env bash
# Builds StS2Mono.Harmony.dll and rewrites Lib.Harmony's 0Harmony.dll to use it
# (see harmonypatch/Program.cs). The game ships this exact 0Harmony.dll.
# Usage: harmony/build.sh <output dir>
set -euo pipefail

HARMONY_VERSION="2.4.2"
HARMONY_SHA256="a849b726e1f9248d71aabbed8114deaf79beb7acc25e8344ff92a27ad8ac87ab" # lib/net9.0/0Harmony.dll

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$(mkdir -p "$1" && cd "$1" && pwd)"
WORK="$ROOT/work/harmony"
rm -rf "$WORK"
mkdir -p "$WORK"

curl -fsSL --retry 5 -o "$WORK/lib.harmony.nupkg" \
    "https://api.nuget.org/v3-flatcontainer/lib.harmony/$HARMONY_VERSION/lib.harmony.$HARMONY_VERSION.nupkg"
unzip -q "$WORK/lib.harmony.nupkg" -d "$WORK/lib.harmony"
HARMONY="$WORK/lib.harmony/lib/net9.0/0Harmony.dll"
echo "$HARMONY_SHA256  $HARMONY" | shasum -a 256 -c -

dotnet build "$ROOT/harmony/StS2Mono.Harmony/StS2Mono.Harmony.csproj" -c Release -o "$WORK/adapter" --nologo
dotnet build "$ROOT/harmony/harmonypatch/harmonypatch.csproj" -c Release -o "$WORK/harmonypatch" --nologo
dotnet "$WORK/harmonypatch/harmonypatch.dll" patch "$HARMONY" "$WORK/adapter/StS2Mono.Harmony.dll" "$OUT/0Harmony.dll"
cp "$WORK/adapter/StS2Mono.Harmony.dll" "$WORK/adapter/StS2Mono.Harmony.pdb" "$OUT/"
ls -la "$OUT"
