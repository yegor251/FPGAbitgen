#!/usr/bin/env python3
"""Bundle the non-system dylib closure of Mach-O executables.

For every executable: walk `otool -L`, copy each non-system dylib into
<root>/lib/, rewrite the reference (and each copied dylib's own deps/ID) to
@executable_path/../lib/<name>, place the executable at its destination and
ad-hoc re-sign it (mandatory on arm64 after install_name_tool).

System libraries (/usr/lib, /System) are left untouched — macOS ships them.
"""
from __future__ import annotations

import shutil
import subprocess
import sys
from pathlib import Path

SKIP = ("/usr/lib/", "/System/", "/usr/local/lib/libSystem")


def run(cmd: list[str]) -> str:
    return subprocess.run(cmd, capture_output=True, text=True).stdout


def deps_of(macho: Path) -> list[str]:
    deps = []
    for line in run(["otool", "-L", str(macho)]).splitlines()[1:]:
        name = line.strip().split(" ")[0]
        if name and not name.startswith(SKIP):
            deps.append(name)
    return deps


def is_macho(p: Path) -> bool:
    return "Mach-O" in run(["file", "-b", str(p)])


def codesign(p: Path) -> None:
    subprocess.run(["codesign", "-f", "-s", "-", str(p)],
                   capture_output=True, check=False)


def rewrite_dep(target: Path, dep: str) -> None:
    new = f"@executable_path/../lib/{Path(dep).name}"
    if dep != new:
        subprocess.run(["install_name_tool", "-change", dep, new, str(target)],
                       check=True)


def main() -> int:
    import argparse
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", required=True, help="tools/ dir: deps go to <root>/lib")
    ap.add_argument("--exe", action="append", required=True,
                    help="source executable (original location), repeatable")
    ap.add_argument("--dest", action="append", required=True,
                    help="destination dir for the corresponding --exe (same order)")
    ap.add_argument("--also", action="append", default=[],
                    help="extra Mach-O to bundle in place (e.g. a plugin .so)")
    ap.add_argument("--origin", action="append", default=[],
                    help="@executable_path origin dir for the matching --also")
    args = ap.parse_args()
    assert len(args.also) == len(args.origin), "--also/--origin counts differ"
    root = Path(args.root).resolve()
    libdir = root / "lib"
    libdir.mkdir(parents=True, exist_ok=True)

    copied: dict[str, Path] = {}
    queue: list[tuple[Path, str]] = []

    def copy_dylib(src: Path, dep: str) -> None:
        base = Path(dep).name
        if base in copied:
            return
        dst = libdir / base
        shutil.copyfile(src, dst)
        copied[base] = dst
        subprocess.run(["install_name_tool", "-id",
                        f"@executable_path/../lib/{base}", str(dst)], check=True)
        for dep2 in deps_of(dst):
            if dep2.startswith(SKIP) or Path(dep2).name == base:
                continue
            queue.append((src, dep2))               # resolve vs SOURCE (suite) tree
            rewrite_dep(dst, dep2)
        codesign(dst)

    def process_queue() -> None:
        while queue:
            origin, name = queue.pop(0)
            base = Path(name).name
            if base in copied:
                continue
            if name.startswith("@executable_path"):
                tail = name.split("/", 2)[-1]          # "lib/libgnat-16.dylib"
                src = origin.parent / tail
                if not src.exists():
                    src = origin.parent.parent / tail  # suite + lib/... = suite/lib/libgnat
            else:
                src = Path(name)
            if not src.exists() or not is_macho(src):
                print(f"bundler: warning: cannot resolve {name} (from {origin})", file=sys.stderr)
                continue
            copy_dylib(src, name)

    for exe_src in map(Path, args.exe):
        if not is_macho(exe_src):
            print(f"bundler: skip non-Mach-O {exe_src}", file=sys.stderr)
            continue
        for d in deps_of(exe_src):
            queue.append((exe_src, d))
    process_queue()

    for exe_src, dest_dir in zip(map(Path, args.exe), args.dest):
        dest_dir = Path(dest_dir)
        dest_dir.mkdir(parents=True, exist_ok=True)
        dst = dest_dir / exe_src.name
        shutil.copyfile(exe_src, dst)
        for dep in deps_of(dst):
            if dep.startswith(SKIP):
                continue
            rewrite_dep(dst, dep)
        dst.chmod(0o755)
        codesign(dst)
        print(f"bundler: {exe_src.name} -> {dst}")

    # extra Mach-O (plugins etc.): bundle their non-system deps in place;
    # new queue items are drained by another process_queue() pass
    for extra, origin in zip(map(Path, args.also), args.origin):
        origin = Path(origin)
        if not extra.exists() or not is_macho(extra):
            continue
        for dep in deps_of(extra):
            if dep.startswith(SKIP):
                continue
            base = Path(dep).name
            if base not in copied:
                if dep.startswith("@executable_path"):
                    tail = dep.split("/", 2)[-1]
                    src = origin / tail
                    if not src.exists():
                        src = origin.parent / tail
                else:
                    src = Path(dep)
                if src.exists() and is_macho(src):
                    copy_dylib(src, dep)
                    print(f"bundler: extra dep {base} copied")
            if base in copied:
                rewrite_dep(extra, dep)
        codesign(extra)
    process_queue()

    print(f"bundler: {len(copied)} dylibs -> {libdir}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
