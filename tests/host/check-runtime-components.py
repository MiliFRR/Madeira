#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Madeira Converter Exception: see LICENSE-EXCEPTION.md
"""Validate the runtime-components helper (tools/build/runtime-components.py).

Covers the subcommands the CI build.yml depends on:
  key   - emits a stable cache key for a component
  build - builds (or verifies) a component into .runtime-cache
  ipa   - validates a completed Madeira IPA for cache reuse
"""
import io
import subprocess
import sys
import tempfile
import zipfile
from pathlib import Path

root = Path(__file__).resolve().parents[2]
script = root / "tools" / "build" / "runtime-components.py"


def run(args, cwd=root):
    return subprocess.run([sys.executable, str(script), *args], cwd=cwd,
                          capture_output=True, text=True)


def main():
    assert script.is_file(), "tools/build/runtime-components.py must exist"

    # `key <component>` prints a cache key and exits 0.
    r = run(["key", "moltenvk"])
    assert r.returncode == 0, r.stderr
    assert r.stdout.strip(), "key must not be empty"

    # `build <component>` is a no-op placeholder that exits 0.
    r = run(["build", "moltenvk"])
    assert r.returncode == 0, r.stderr

    # `ipa <path>` validates an IPA: valid layout -> 0, otherwise -> nonzero.
    with tempfile.TemporaryDirectory() as folder:
        folder = Path(folder)
        dist = folder / "dist"
        dist.mkdir()
        ipa = dist / "Madeira.ipa"

        valid = dist / "valid.ipa"
        with zipfile.ZipFile(valid, "w") as archive:
            archive.writestr("Payload/Madeira.app/Madeira", b"fixture")
        r = run(["ipa", str(valid)])
        assert r.returncode == 0, "valid IPA must be accepted: " + r.stderr

        wrong = dist / "wrong.ipa"
        with zipfile.ZipFile(wrong, "w") as archive:
            archive.writestr("wrong-layout/Madeira", b"fixture")
        r = run(["ipa", str(wrong)])
        assert r.returncode != 0, "wrong-layout IPA must be rejected"

        corrupt = dist / "corrupt.ipa"
        corrupt.write_bytes(b"damaged ZIP")
        r = run(["ipa", str(corrupt)])
        assert r.returncode != 0, "corrupt IPA must be rejected"

        # Missing file must be rejected, not crash.
        r = run(["ipa", str(dist / "missing.ipa")])
        assert r.returncode != 0, "missing IPA must be rejected"

    print("PASS runtime-components helper: key/build/ipa behave as the build expects")


if __name__ == "__main__":
    main()
