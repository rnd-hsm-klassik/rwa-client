"""AFC push helper for deploy_games.sh - the path for phones devicectl cannot
reach (iOS < 17). Uses the pymobiledevice3 library over house_arrest, the same
service Finder's file-sharing pane speaks, so it works on every iOS version.

Run with the python of the pymobiledevice3 installation (deploy_games.sh
resolves it from the pymobiledevice3 entry point):

    <pmd3-python> deploy_games_afc.py --udid U --bundle B push-dir  SRC DEST
    <pmd3-python> deploy_games_afc.py --udid U --bundle B push-file SRC DEST

push-dir mirrors devicectl's skip-unmodified behaviour: AFC cannot preserve
mtimes, so a manifest (.deploy-manifest.json, relpath -> [size, mtime]) is
kept in DEST on the device and files whose local size+mtime match it are
skipped. push-dir only adds and overwrites, it never deletes remote files,
matching the devicectl path.
"""

import argparse
import asyncio
import inspect
import json
import os
import posixpath
import sys

MANIFEST_NAME = ".deploy-manifest.json"


async def maybe(value):
    """Await if awaitable - pymobiledevice3 mixes sync and async surfaces."""
    if inspect.isawaitable(value):
        return await value
    return value


async def push_dir(afc, src, dest):
    manifest_path = posixpath.join(dest, MANIFEST_NAME)
    try:
        old = json.loads(await maybe(afc.get_file_contents(manifest_path)))
        if not isinstance(old, dict):
            old = {}
    except Exception:
        old = {}

    await maybe(afc.makedirs(dest))
    made = {dest}
    new = {}
    pushed = skipped = 0
    pushed_bytes = 0

    for root, dirs, files in os.walk(src):
        dirs.sort()
        for name in sorted(files):
            lpath = os.path.join(root, name)
            rel = os.path.relpath(lpath, src).replace(os.sep, "/")
            st = os.stat(lpath)
            sig = [st.st_size, int(st.st_mtime)]
            new[rel] = sig
            if old.get(rel) == sig:
                skipped += 1
                continue
            rpath = posixpath.join(dest, rel)
            rdir = posixpath.dirname(rpath)
            if rdir not in made:
                await maybe(afc.makedirs(rdir))
                made.add(rdir)
            await maybe(afc.push(lpath, rpath, progress_bar=False))
            pushed += 1
            pushed_bytes += st.st_size

    await maybe(afc.set_file_contents(manifest_path, json.dumps(new).encode()))
    print(f"    {pushed} file(s) pushed ({pushed_bytes / 1e6:.1f} MB), {skipped} unchanged")


async def push_file(afc, src, dest):
    rdir = posixpath.dirname(dest)
    if rdir:
        await maybe(afc.makedirs(rdir))
    await maybe(afc.push(src, dest, progress_bar=False))


async def run(args):
    from pymobiledevice3.lockdown import create_using_usbmux
    from pymobiledevice3.services.house_arrest import HouseArrestService

    lockdown = await maybe(create_using_usbmux(serial=args.udid))
    afc = await maybe(HouseArrestService.create(lockdown, args.bundle))
    try:
        if args.cmd == "push-dir":
            await push_dir(afc, args.src, args.dest)
        else:
            await push_file(afc, args.src, args.dest)
    finally:
        await maybe(afc.close())


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--udid", required=True)
    parser.add_argument("--bundle", required=True)
    sub = parser.add_subparsers(dest="cmd", required=True)
    for cmd in ("push-dir", "push-file"):
        p = sub.add_parser(cmd)
        p.add_argument("src")
        p.add_argument("dest")
    args = parser.parse_args()

    if args.cmd == "push-dir" and not os.path.isdir(args.src):
        sys.exit(f"error: {args.src} is not a directory")
    if args.cmd == "push-file" and not os.path.isfile(args.src):
        sys.exit(f"error: {args.src} is not a file")

    try:
        asyncio.run(run(args))
    except Exception as e:  # surfaced by deploy_games.sh
        sys.exit(f"error: {type(e).__name__}: {e}")


if __name__ == "__main__":
    main()
