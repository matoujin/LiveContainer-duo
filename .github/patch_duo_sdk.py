#!/usr/bin/env python3
"""Stamp iOS 27.1 Duo SDK metadata into LiveContainer.app payloads.

Patches:
  - Info.plist DTSDK* / MinimumOSVersion / modern UILaunchScreen
  - Removes LaunchScreen.storyboardc and legacy launch keys
  - Mach-O LC_BUILD_VERSION / LC_VERSION_MIN_IPHONEOS → minos=16.1 sdk=27.1
"""

from __future__ import annotations

import os
import plistlib
import struct
import sys
from pathlib import Path

MINOS = 0x00100100  # 16.1.0
SDK = 0x001B0100    # 27.1.0
LC_BUILD_VERSION = 0x32
LC_VERSION_MIN_IPHONEOS = 0x25
MH_MAGIC_64 = 0xFEEDFACF
MH_CIGAM_64 = 0xCFFAEDFE
FAT_MAGIC = 0xCAFEBABE
FAT_CIGAM = 0xBEBAFECA

PLIST_STAMP = {
    "DTSDKName": "iphoneos27.1",
    "DTPlatformVersion": "27.1",
    "DTSDKBuild": "24A94232",
    "DTPlatformBuild": "24A94232",
    "DTXcode": "2710",
    "DTXcodeBuild": "27A9275",
    "MinimumOSVersion": "16.1",
    "DTPlatformName": "iphoneos",
}

LEGACY_LAUNCH_KEYS = (
    "UILaunchImages",
    "UILaunchImageFile",
    "UILaunchStoryboardName",
    "UILaunchStoryboards",
    "UIRequiresFullScreen",
)


def u32(data: bytes, off: int, swap: bool) -> int:
    fmt = "<I" if swap else ">I"
    return struct.unpack_from(fmt, data, off)[0]


def patch_build_version_in_slice(buf: bytearray, offset: int) -> int:
    magic = struct.unpack_from(">I", buf, offset)[0]
    if magic == MH_MAGIC_64:
        swap = False
    elif magic == MH_CIGAM_64:
        swap = True
    else:
        return 0
    ncmds = u32(buf, offset + 16, swap)
    sizeofcmds = u32(buf, offset + 20, swap)
    cmd_off = offset + 32
    end = cmd_off + sizeofcmds
    patched = 0
    for _ in range(ncmds):
        if cmd_off + 8 > end:
            break
        cmd = u32(buf, cmd_off, swap)
        cmdsize = u32(buf, cmd_off + 4, swap)
        if cmdsize < 8 or cmd_off + cmdsize > end:
            break
        if cmd == LC_BUILD_VERSION and cmdsize >= 24:
            # platform(8) minos(12) sdk(16)
            struct.pack_into(">I" if not swap else "<I", buf, cmd_off + 12, MINOS)
            struct.pack_into(">I" if not swap else "<I", buf, cmd_off + 16, SDK)
            patched += 1
        elif cmd == LC_VERSION_MIN_IPHONEOS and cmdsize >= 16:
            # version(8) sdk(12)
            struct.pack_into(">I" if not swap else "<I", buf, cmd_off + 8, MINOS)
            struct.pack_into(">I" if not swap else "<I", buf, cmd_off + 12, SDK)
            patched += 1
        cmd_off += cmdsize
    return patched


def patch_macho(path: Path) -> int:
    data = bytearray(path.read_bytes())
    if len(data) < 8:
        return 0
    magic = struct.unpack_from(">I", data, 0)[0]
    patched = 0
    if magic in (FAT_MAGIC, FAT_CIGAM):
        swap = magic == FAT_CIGAM
        nfat = u32(data, 4, swap)
        for i in range(nfat):
            # fat_arch: cputype, cpusubtype, offset, size, align
            base = 8 + i * 20
            slice_off = u32(data, base + 8, swap)
            patched += patch_build_version_in_slice(data, slice_off)
    else:
        patched = patch_build_version_in_slice(data, 0)
    if patched:
        path.write_bytes(data)
    return patched


def modernize_plist(path: Path) -> bool:
    try:
        with path.open("rb") as f:
            plist = plistlib.load(f)
    except Exception as exc:
        print(f"[duo] skip plist {path}: {exc}")
        return False
    changed = False
    for key, value in PLIST_STAMP.items():
        if plist.get(key) != value:
            plist[key] = value
            changed = True
    for key in LEGACY_LAUNCH_KEYS:
        if key in plist:
            del plist[key]
            changed = True
    if not isinstance(plist.get("UILaunchScreen"), dict):
        # Only inject UILaunchScreen for .app / .appex / SideStoreApp.framework style bundles
        if path.parent.suffix in (".app", ".appex", ".framework") or path.parent.name.endswith(".app"):
            plist["UILaunchScreen"] = {}
            changed = True
    if changed:
        with path.open("wb") as f:
            plistlib.dump(plist, f, fmt=plistlib.FMT_BINARY)
    return changed


def remove_launch_storyboards(root: Path) -> int:
    removed = 0
    for p in root.rglob("LaunchScreen.storyboardc"):
        if p.is_dir():
            for child in sorted(p.rglob("*"), reverse=True):
                if child.is_file():
                    child.unlink()
                elif child.is_dir():
                    child.rmdir()
            p.rmdir()
            removed += 1
            print(f"[duo] removed {p}")
        elif p.is_file():
            p.unlink()
            removed += 1
    return removed


def is_macho(path: Path) -> bool:
    try:
        with path.open("rb") as f:
            magic = f.read(4)
        if len(magic) < 4:
            return False
        val = struct.unpack(">I", magic)[0]
        return val in (MH_MAGIC_64, MH_CIGAM_64, FAT_MAGIC, FAT_CIGAM, 0xFEEDFACE, 0xCEFAEDFE)
    except OSError:
        return False


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print(f"usage: {argv[0]} <Payload/LiveContainer.app>")
        return 2
    app = Path(argv[1])
    if not app.is_dir():
        print(f"[duo] missing app bundle: {app}")
        return 1

    plist_count = 0
    macho_count = 0
    for dirpath, dirnames, filenames in os.walk(app):
        # skip code signature blobs
        dirnames[:] = [d for d in dirnames if d != "_CodeSignature"]
        root = Path(dirpath)
        if "Info.plist" in filenames:
            if modernize_plist(root / "Info.plist"):
                plist_count += 1
                print(f"[duo] stamped Info.plist {root / 'Info.plist'}")
        for name in filenames:
            path = root / name
            if path.is_symlink():
                continue
            # Heuristic: Mach-O executables / dylibs / frameworks binary
            if name.endswith((".dylib",)) or path.suffix == "" or path.parent.suffix in (".framework", ".appex", ".app"):
                if is_macho(path):
                    n = patch_macho(path)
                    if n:
                        macho_count += n
                        print(f"[duo] patched Mach-O LC_BUILD_VERSION in {path} ({n})")

    removed = remove_launch_storyboards(app)
    print(f"[duo] done: plists={plist_count} macho_cmds={macho_count} storyboards_removed={removed}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
