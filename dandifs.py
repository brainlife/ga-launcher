#!/usr/bin/env python3
"""Read-only FUSE filesystem exposing DANDI datasets as folders.

The DANDI S3 bucket is content-addressed (blobs/<hash>), so mounting the
bucket directly gives a flat blob store, not dataset folders. The folder
structure lives in the DANDI REST API, so this maps API paths onto a tree:

    <mount>/<dandiset>/<version>/<asset/path...>

File content is streamed from the public S3 blobs via HTTP Range requests,
so no AWS credentials, boto3, or s3fs are needed.

Usage:
    ./dandifs.py <mountpoint>                       # whole archive
    ./dandifs.py <mountpoint> 000003                # one dandiset (draft)
    ./dandifs.py <mountpoint> 000003 0.230629.1955  # pinned version
    ./dandifs.py --selftest                         # no mount; checks API logic

Needs fusepy (pip install fusepy) and a FUSE kernel module (libfuse on
Linux, macFUSE on macOS).
"""
import errno
import json
import os
import stat
import sys
import time
import urllib.parse
import urllib.request
from functools import lru_cache

API = "https://api.dandiarchive.org/api"


def _get(url):
    with urllib.request.urlopen(url, timeout=30) as r:
        return json.load(r)


def _get_all(url):
    """Follow DANDI's `next` pagination, returning all `results`."""
    out = []
    while url:
        page = _get(url)
        out.extend(page["results"])
        url = page.get("next")
    return out


@lru_cache(maxsize=1)
def list_dandisets():
    rows = _get_all(f"{API}/dandisets/?page_size=1000")
    return {r["identifier"]: r for r in rows}


@lru_cache(maxsize=256)
def list_versions(dandiset):
    rows = _get_all(f"{API}/dandisets/{dandiset}/versions/?page_size=1000")
    return {r["version"]: r for r in rows}


@lru_cache(maxsize=4096)
def list_children(dandiset, version, prefix):
    """Immediate children of `prefix` within a dandiset version.

    Returns {name: {"dir": bool, "size": int, "url": str|None}}.
    """
    url = (f"{API}/dandisets/{dandiset}/versions/{version}"
           f"/assets/paths/?path_prefix={urllib.parse.quote(prefix)}")
    out = {}
    for r in _get_all(url):
        name = r["path"][len(prefix):].lstrip("/").split("/")[0]
        asset = r.get("asset")
        out[name] = {
            "dir": asset is None,
            "size": r["aggregate_size"] if asset else 0,
            "url": asset["url"] if asset else None,
        }
    return out


def resolve(parts, root):
    """Map FUSE path parts to a node.

    root is () for the whole archive, or (dandiset, version) when a single
    dandiset is mounted. Returns ("dir"|"file", meta) or None if missing.
    """
    parts = root + tuple(parts)
    if len(parts) == 0:
        return ("dir", {"children": "dandisets"})
    ds = parts[0]
    if ds not in list_dandisets():
        return None
    if len(parts) == 1:
        return ("dir", {"children": "versions", "dandiset": ds})
    ver = parts[1]
    if ver not in list_versions(ds):
        return None
    asset_path = "/".join(parts[2:])
    if not asset_path:
        return ("dir", {"dandiset": ds, "version": ver, "prefix": ""})
    parent = "/".join(parts[2:-1])
    name = parts[-1]
    entry = list_children(ds, ver, parent).get(name)
    if entry is None:
        return None
    if entry["dir"]:
        return ("dir", {"dandiset": ds, "version": ver, "prefix": asset_path})
    return ("file", {"size": entry["size"], "url": entry["url"]})


def read_range(url, offset, size):
    req = urllib.request.Request(url, headers={"Range": f"bytes={offset}-{offset + size - 1}"})
    with urllib.request.urlopen(req, timeout=60) as r:
        return r.read()


def _build_fs():
    from fuse import FUSE, FuseOSError, Operations  # imported lazily: selftest needs no FUSE

    class DandiFS(Operations):
        def __init__(self, root):
            self.root = root
            self.uid, self.gid = os.getuid(), os.getgid()
            self.now = int(time.time())

        def _node(self, path):
            parts = [p for p in path.split("/") if p]
            node = resolve(parts, self.root)
            if node is None:
                raise FuseOSError(errno.ENOENT)
            return node

        def getattr(self, path, fh=None):
            kind, meta = self._node(path)
            base = dict(st_uid=self.uid, st_gid=self.gid,
                        st_atime=self.now, st_mtime=self.now, st_ctime=self.now)
            if kind == "dir":
                return {**base, "st_mode": stat.S_IFDIR | 0o555, "st_nlink": 2}
            return {**base, "st_mode": stat.S_IFREG | 0o444, "st_nlink": 1,
                    "st_size": meta["size"]}

        def readdir(self, path, fh):
            kind, meta = self._node(path)
            if kind != "dir":
                raise FuseOSError(errno.ENOTDIR)
            names = meta.get("children")
            if names == "dandisets":
                entries = list_dandisets().keys()
            elif names == "versions":
                entries = list_versions(meta["dandiset"]).keys()
            else:
                entries = list_children(meta["dandiset"], meta["version"], meta["prefix"]).keys()
            return [".", ".."] + list(entries)

        def open(self, path, flags):
            if flags & (os.O_WRONLY | os.O_RDWR):
                raise FuseOSError(errno.EROFS)
            return 0

        def read(self, path, size, offset, fh):
            kind, meta = self._node(path)
            if kind != "file":
                raise FuseOSError(errno.EISDIR)
            size = min(size, max(0, meta["size"] - offset))
            if size == 0:
                return b""
            return read_range(meta["url"], offset, size)

    return FUSE, DandiFS


def selftest():
    ds, ver = "000003", "draft"
    top = list_children(ds, ver, "")
    assert top, "no top-level entries"
    name, entry = next(iter(top.items()))
    assert entry["dir"], f"expected dir at top level, got {name}"
    kids = list_children(ds, ver, name)
    leaf = next((e for e in kids.values() if not e["dir"]), None)
    assert leaf and leaf["size"] > 0, "no file leaf found"
    data = read_range(leaf["url"], 0, 10)
    assert len(data) == 10, f"range read returned {len(data)} bytes"
    print(f"OK: {ds}/{ver} -> {name}/ -> file {leaf['size']} bytes, read 10")


def main():
    args = sys.argv[1:]
    if args[:1] == ["--selftest"]:
        selftest()
        return
    if not args:
        sys.exit(__doc__)
    mount = args[0]
    root = ()
    if len(args) >= 2:
        root = (args[1], args[2] if len(args) >= 3 else "draft")
    FUSE, DandiFS = _build_fs()
    # allow_other lets a different uid (e.g. the unprivileged container user) read the
    # mount; requires user_allow_other in /etc/fuse.conf. Off unless asked, for local use.
    allow_other = os.environ.get("DANDIFS_ALLOW_OTHER") == "1"
    FUSE(DandiFS(root), mount, foreground=True, ro=True, nothreads=False,
         allow_other=allow_other)


if __name__ == "__main__":
    main()
