#!/usr/bin/env python3
"""Build a deterministic, flat runtime archive for Azure's customData limit."""

import argparse
import base64
import io
import lzma
from pathlib import Path
import tarfile


def archive_bytes(sources: list[Path]) -> bytes:
    names = [source.name for source in sources]
    if len(set(names)) != len(names):
        raise ValueError("runtime asset names must be unique")
    output = io.BytesIO()
    with tarfile.open(fileobj=output, mode="w", format=tarfile.USTAR_FORMAT) as archive:
        for source in sorted(sources, key=lambda item: item.name):
            if source.is_symlink() or not source.is_file():
                raise ValueError("runtime assets must be regular files")
            content = source.read_bytes().replace(b"\r\n", b"\n")
            item = tarfile.TarInfo(source.name)
            item.size = len(content)
            item.mode = 0o644
            item.uid = item.gid = item.mtime = 0
            archive.addfile(item, io.BytesIO(content))
    return output.getvalue()


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--check", action="store_true")
    parser.add_argument("sources", type=Path, nargs="+")
    args = parser.parse_args()
    expected = archive_bytes(args.sources)
    if args.check:
        actual = lzma.decompress(base64.b64decode(args.output.read_bytes(), validate=True))
        if actual != expected:
            raise ValueError("runtime bundle is stale; run sync-cloud-init-assets.ps1")
    else:
        compressed = lzma.compress(expected, format=lzma.FORMAT_XZ, preset=6)
        args.output.write_bytes(base64.b64encode(compressed))


if __name__ == "__main__":
    main()
