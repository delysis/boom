#!/usr/bin/env python3
"""Apply or verify only Boom's tracked patches on exact pinned MLX sources."""

import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import subprocess


def git(directory, *arguments):
    return subprocess.check_output(["git", "-C", str(directory), *arguments])


def digest(path):
    value = hashlib.sha256()
    with path.open("rb") as stream:
        for data in iter(lambda: stream.read(1 << 20), b""):
            value.update(data)
    return value.hexdigest()


def changed_paths(directory, overlay):
    tracked = git(directory, "diff", "--name-only", "-z", "HEAD")
    added = git(directory, "ls-files", "--others", "--exclude-standard", "-z")
    paths = {p.decode("utf-8") for p in (tracked + added).split(b"\0") if p}
    # Each excluded gitlink has its own pinned component below. Its contents
    # must be verified there; it is not an allowance for an arbitrary directory.
    return paths - set(overlay.get("submodules", []))


def verify(directory, overlay):
    expected = {row["path"]: row["sha256"] for row in overlay["files"]}
    if len(expected) != len(overlay["files"]):
        raise ValueError("Duplicate MLX overlay path.")
    if not changed_paths(directory, overlay).issubset(expected):
        raise ValueError("MLX sources contain changes outside the tracked overlay.")
    for relative, sha256 in expected.items():
        parts = PurePosixPath(relative)
        if parts.is_absolute() or ".." in parts.parts:
            raise ValueError("Invalid MLX overlay path.")
        path = directory / relative
        if path.is_symlink() or not path.is_file() or digest(path) != sha256:
            raise ValueError(f"MLX overlay postimage mismatch: {relative}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--apply", action="store_true")
    mode.add_argument("--verify", action="store_true")
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    overlays = json.loads((root / "patches/mlx-runtime-overlays.json").read_text())
    directories = {entry["directory"] for entry in overlays}
    pending = []
    for overlay in overlays:
        for child in overlay.get("submodules", []):
            if str(PurePosixPath(overlay["directory"]) / child) not in directories:
                raise ValueError("A patched MLX submodule needs its own pinned component.")
        directory = root / overlay["directory"]
        if git(directory, "rev-parse", "HEAD").decode().strip() != overlay["revision"]:
            raise ValueError("Unexpected MLX dependency revision.")
        patch = root / overlay["patch"]
        if digest(patch) != overlay["patchSHA256"]:
            raise ValueError("Tracked MLX patch hash mismatch.")
        if args.apply:
            try:
                verify(directory, overlay)
            except (ValueError, OSError):
                if changed_paths(directory, overlay):
                    raise ValueError("Refusing to replace a modified MLX dependency.")
                git(directory, "apply", "--check", str(patch))
                pending.append((directory, patch))
    # Preflight every component before changing any dependency source.
    for directory, patch in pending:
        git(directory, "apply", str(patch))
    for overlay in overlays:
        directory = root / overlay["directory"]
        verify(directory, overlay)
    print("Pinned MLX source overlays verified.")


if __name__ == "__main__":
    main()
