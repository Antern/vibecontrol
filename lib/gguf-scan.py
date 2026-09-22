#!/usr/bin/env python3
"""List GGUF models under the given directories, with what is worth knowing.

Prints one TSV row per model: path, size in bytes, architecture, name.

The architecture is the point. It is the string llama.cpp looks up when
loading, and a build that does not implement it refuses the model outright --
so having it in the menu turns "this will not load" from a failed start into
something visible before you pick it. It lives in the GGUF header, so reading
it costs one small read per file rather than touching the weights.

Usage: gguf-scan.py <dir> [dir...]
"""
import os
import struct
import sys

# GGUF scalar type -> byte width. Strings (8) and arrays (9) are handled apart.
WIDTH = {0: 1, 1: 1, 2: 2, 3: 2, 4: 4, 5: 4, 6: 4, 7: 1, 10: 8, 11: 8, 12: 8}

WANTED = ("general.architecture", "general.name")


def read_meta(path):
    """Header fields we care about, or {} if this is not a readable GGUF."""
    try:
        f = open(path, "rb")
    except OSError:
        return {}
    with f:
        if f.read(4) != b"GGUF":
            return {}
        try:
            struct.unpack("<I", f.read(4))            # format version
            struct.unpack("<Q", f.read(8))            # tensor count
            n_kv = struct.unpack("<Q", f.read(8))[0]
        except struct.error:
            return {}

        def rstr():
            n = struct.unpack("<Q", f.read(8))[0]
            return f.read(n).decode("utf-8", "replace")

        def skip(t):
            if t == 8:
                rstr()
            elif t == 9:
                it = struct.unpack("<I", f.read(4))[0]
                cnt = struct.unpack("<Q", f.read(8))[0]
                if it == 8:
                    for _ in range(cnt):
                        rstr()
                else:
                    f.seek(WIDTH.get(it, 0) * cnt, os.SEEK_CUR)
            else:
                f.seek(WIDTH.get(t, 0), os.SEEK_CUR)

        out = {}
        for _ in range(min(n_kv, 4096)):
            try:
                k = rstr()
                t = struct.unpack("<I", f.read(4))[0]
            except (struct.error, OSError):
                break
            if k in WANTED and t == 8:
                out[k] = rstr()
            else:
                skip(t)
            # The tokeniser arrays come after everything interesting and are by
            # far the largest part of the header; stop once we have both.
            if len(out) == len(WANTED):
                break
        return out


def interesting(name):
    if not name.endswith(".gguf"):
        return False
    base = os.path.basename(name)
    # Vision projectors are companions to a model, not a model.
    if base.startswith("mmproj"):
        return False
    # A sharded model is loaded by naming its first part; the rest would show
    # as separate entries that cannot be selected.
    if "-of-" in base and not base.split("-of-")[0].endswith("00001"):
        return False
    return True


def main():
    if len(sys.argv) < 2:
        print(__doc__.strip().splitlines()[-1], file=sys.stderr)
        return 2
    seen = set()
    for root in sys.argv[1:]:
        if not root or not os.path.isdir(root):
            continue
        for dirpath, _dirs, files in os.walk(root):
            for fn in sorted(files):
                if not interesting(fn):
                    continue
                path = os.path.join(dirpath, fn)
                real = os.path.realpath(path)
                if real in seen:
                    continue
                seen.add(real)
                try:
                    size = os.path.getsize(path)
                except OSError:
                    continue
                meta = read_meta(path)
                # Tabs would break the TSV the daemon parses; names are free text.
                name = (meta.get("general.name") or "").replace("\t", " ")
                arch = (meta.get("general.architecture") or "?").replace("\t", " ")
                print("%s\t%d\t%s\t%s" % (path, size, arch, name))
    return 0


if __name__ == "__main__":
    sys.exit(main())
