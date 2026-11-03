#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Madeira Converter Exception: see LICENSE-EXCEPTION.md
"""Runtime-component helpers for the Madeira CI build.

Subcommands:
  key <component>   Print a stable cache key for a runtime component.
  build <component> Build (or verify) a runtime component into .runtime-cache.
  ipa   <path>      Validate a completed Madeira IPA for cache reuse.

The `ipa` validator is what `check-build-inputs.py`'s `valid_ipa()` exercises:
a reusable IPA is a ZIP whose Payload holds a `.app` bundle with a `Madeira`
executable; anything else (wrong layout, corrupt ZIP) is rejected.
"""
import sys
import zipfile


def cmd_ipa(path):
    try:
        with zipfile.ZipFile(path) as archive:
            names = archive.namelist()
    except (zipfile.BadZipFile, FileNotFoundError, OSError):
        return 1
    # A Madeira IPA bundles Payload/Madeira.app/Madeira.
    for name in names:
        if name.startswith("Payload/") and name.endswith(".app/Madeira"):
            return 0
    return 1


def cmd_key(component):
    print(f"runtime-{component}-stub")
    return 0


def cmd_build(component):
    # No-op placeholder: real component builds are produced by the native
    # build jobs (LLVM, FEX, Wine, DXMT) and restored from cache here.
    print(f"runtime component {component}: nothing to build (cached)")
    return 0


def main(argv):
    if len(argv) < 2:
        print("usage: runtime-components.py <key|build|ipa> ...", file=sys.stderr)
        return 2
    subcommand, arg = argv[0], argv[1]
    if subcommand == "ipa":
        return cmd_ipa(arg)
    if subcommand == "key":
        return cmd_key(arg)
    if subcommand == "build":
        return cmd_build(arg)
    print(f"unknown subcommand: {subcommand}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
