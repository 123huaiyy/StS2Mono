"""Package a local Windows game export with the existing Godot iOS host."""

import argparse
import hashlib
import json
import plistlib
import shutil
import struct
import tempfile
import zipfile
from copy import copy
from pathlib import Path


APP = "Payload/sts2.app/"
PACK_HEADER = struct.Struct("<4s5I2Q")
PACK_ENTRY = struct.Struct("<QQ16sI")
VERSION = "0.113.1"
MONO_PUBLISH_MANIFEST = ".godot/mono/publish/arm64/.dotnet-publish-manifest"


def uint(data, offset):
    return struct.unpack_from("<I", data, offset)[0]


def update_project(data):
    if not data.startswith(b"ECFG"):
        raise ValueError("unexpected project.binary signature")
    settings = {}
    pos = 8
    for _ in range(uint(data, 4)):
        key_size = uint(data, pos)
        pos += 4
        key = data[pos:pos + key_size].decode("utf-8")
        pos += key_size
        value_size = uint(data, pos)
        pos += 4
        settings[key] = data[pos:pos + value_size]
        pos += value_size
    if pos != len(data):
        raise ValueError("unexpected project.binary length")
    # Retain the previous port's mobile window and logging settings.
    settings.update({
        "debug/file_logging/enable_file_logging": struct.pack("<II", 1, 1),
        "display/window/handheld/orientation": struct.pack("<II", 2, 6),
        "display/window/ios/hide_home_indicator": struct.pack("<II", 1, 0),
        "ios/launch_screen_image_mode": struct.pack("<II", 4, 6) + b"center\0\0",
    })
    packed = bytearray(b"ECFG" + struct.pack("<I", len(settings)))
    for key, value in settings.items():
        name = key.encode("utf-8")
        packed += struct.pack("<I", len(name)) + name + struct.pack("<I", len(value)) + value
    return packed


def read_pack_index(source):
    header = source.read(PACK_HEADER.size)
    magic, format_version, major, minor, patch, flags, file_base, index_offset = PACK_HEADER.unpack(header)
    if (magic, format_version, major, minor, patch, flags) != (b"GDPC", 3, 4, 5, 1, 2):
        raise ValueError("expected an unencrypted Godot 4.5.1 v3 pack")
    source.seek(index_offset)
    directory = source.read()
    entries = {}
    pos = 4
    for _ in range(uint(directory, 0)):
        length = uint(directory, pos)
        pos += 4
        name = directory[pos:pos + length].rstrip(b"\0").decode("utf-8")
        pos += length
        offset, size, digest, entry_flags = PACK_ENTRY.unpack_from(directory, pos)
        if file_base + offset + size > index_offset or name in entries:
            raise ValueError(f"invalid resource entry: {name}")
        entries[name] = offset, size, digest, entry_flags
        pos += PACK_ENTRY.size
    if pos != len(directory):
        raise ValueError("unexpected resource directory length")
    return header, file_base, index_offset, entries


def write_pack(source, destination, release_info):
    header, file_base, index_offset, entries = read_pack_index(source)
    project = entries["project.binary"]
    if project[3] != 0:
        raise ValueError("project.binary uses unsupported flags")
    source.seek(file_base + project[0])
    data = source.read(project[1])
    if hashlib.md5(data).digest() != project[2]:
        raise ValueError("project.binary digest does not match its directory entry")
    replacements = {
        "project.binary": update_project(data),
        "release_info.json": release_info,
        # Match the empty cache manifest created by StS2Mono. The Godot iOS
        # host only probes for Mono after it accepts this packed manifest.
        MONO_PUBLISH_MANIFEST: b"",
    }
    added = bytearray()
    for name, data in replacements.items():
        added += bytes(-(index_offset + len(added) - file_base) % 16)
        entries[name] = index_offset + len(added) - file_base, len(data), hashlib.md5(data).digest(), 0
        added += data

    destination.write(header[:32] + struct.pack("<Q", index_offset + len(added)))
    source.seek(PACK_HEADER.size)
    left = index_offset - PACK_HEADER.size
    while left:
        chunk = source.read(min(left, 8 * 1024 * 1024))
        if not chunk:
            raise ValueError("incomplete resource pack")
        destination.write(chunk)
        left -= len(chunk)
    destination.write(added)
    destination.write(struct.pack("<I", len(entries)))
    for name, entry in entries.items():
        label = name.encode("utf-8")
        label += bytes(-len(label) % 4)
        destination.write(struct.pack("<I", len(label)) + label + PACK_ENTRY.pack(*entry))


def pack_app(source_ipa, game, out, release_info):
    with zipfile.ZipFile(source_ipa) as previous, zipfile.ZipFile(out, "x") as result:
        info = plistlib.loads(previous.read(APP + "Info.plist"))
        if info["CFBundleIdentifier"] != "cv.o.sts2.v0111":
            raise ValueError("expected the existing v0.111.0 app host")
        info.update({
            "CFBundleIdentifier": "cv.o.sts2.v0113",
            "CFBundleDisplayName": "杀戮尖塔2 " + VERSION,
            "CFBundleVersion": VERSION,
            "CFBundleShortVersionString": VERSION,
        })
        for entry in previous.infolist():
            name = entry.filename
            if name == APP + "sts2.pck":
                with (game / "SlayTheSpire2.pck").open("rb") as src, result.open(copy(entry), "w", force_zip64=True) as dst:
                    write_pack(src, dst, release_info)
            elif name == APP + "release_info.json":
                result.writestr(copy(entry), release_info)
            elif name == APP + "Info.plist":
                result.writestr(copy(entry), plistlib.dumps(info, sort_keys=False))
            else:
                with previous.open(entry) as src, result.open(copy(entry), "w") as dst:
                    shutil.copyfileobj(src, dst, 1024 * 1024)


def pack_dotnet(previous_dotnet, mono, game_assembly, game_fixes, out):
    replacements = {
        "dotnet/sts2.dll": game_assembly,
        "dotnet/StS2Mono.GameFixes.dll": game_fixes,
        "dotnet/0Harmony.dll": mono / "dotnet/0Harmony.dll",
        "dotnet/StS2Mono.Harmony.dll": mono / "dotnet/StS2Mono.Harmony.dll",
    }
    with zipfile.ZipFile(previous_dotnet) as previous, zipfile.ZipFile(out, "x", zipfile.ZIP_DEFLATED) as result:
        previous.getinfo("dotnet/GodotSharp.dll")
        previous.getinfo("dotnet/System.Private.CoreLib.dll")
        for entry in previous.infolist():
            if entry.filename not in replacements and not entry.filename.endswith(".pdb"):
                result.writestr(copy(entry), previous.read(entry))
        for name, path in replacements.items():
            result.write(path, name)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for arg in ("legacy-ipa", "legacy-dotnet", "mono", "game", "game-assembly", "game-fixes", "out"):
        parser.add_argument("--" + arg, type=Path, required=True)
    args = parser.parse_args()
    release_info = (args.game / "release_info.json").read_bytes()
    if json.loads(release_info)["version"] != "v" + VERSION:
        parser.error("game directory does not contain v" + VERSION)
    args.out.mkdir(parents=True, exist_ok=True)
    dotnet = f"StS2-{VERSION}-dotnet.zip"
    ipa = f"StS2-{VERSION}-iOS.ipa"
    bridge = "StS2Mono.dylib"
    for name in (dotnet, ipa, bridge):
        if (args.out / name).exists():
            parser.error(f"output already exists: {args.out / name}")
    with tempfile.TemporaryDirectory(prefix="sts2-build-", dir=args.out) as stage:
        folder = Path(stage)
        pack_dotnet(args.legacy_dotnet, args.mono, args.game_assembly, args.game_fixes, folder / dotnet)
        pack_app(args.legacy_ipa, args.game, folder / ipa, release_info)
        shutil.copy2(args.mono / bridge, folder / bridge)
        for name in (dotnet, bridge, ipa):
            (folder / name).rename(args.out / name)


if __name__ == "__main__":
    main()
