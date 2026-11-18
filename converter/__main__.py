"""Convert every Motive FBX in a folder into the take files the Roblox plugin reads.

Usage: python -m converter [input_folder] [output_folder] [--sul-posto]
Defaults: export_motive -> animazioni. Converted FBX move to <input_folder>/convertiti. The index (index.json) is
rebuilt from all takes in the output folder, also when there is nothing new to convert.
"""
import json
import os
import re
import sys

from .fbx_reader import FbxError, load
from .retarget import convert

DONE_DIR = "convertiti"  # inside the input folder: FBX already converted


def safe_name(stem):
    return re.sub(r"[^A-Za-z0-9_-]+", "_", stem).strip("_") or "take"


def write_json(path, data):
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(data, f, separators=(",", ":"), ensure_ascii=False)
    os.replace(tmp, path)


def build_index(out_dir):
    takes = []
    for fn in sorted(os.listdir(out_dir)):
        if not fn.endswith(".json") or fn == "index.json":
            continue
        try:
            with open(os.path.join(out_dir, fn), encoding="utf-8") as f:
                d = json.load(f)
        except (OSError, ValueError):
            continue
        if d.get("format") != "motive-roblox":
            continue
        takes.append({"name": d["name"], "file": fn, "seconds": d["seconds"], "frames": d["frames"]})
    takes.sort(key=lambda t: t["name"].lower())
    write_json(os.path.join(out_dir, "index.json"),
               {"format": "motive-roblox-index", "version": 1, "takes": takes})
    return takes


def main(argv):
    args = [a for a in argv if not a.startswith("--")]
    travel = "--sul-posto" not in argv
    in_dir = args[0] if len(args) > 0 else "export_motive"
    out_dir = args[1] if len(args) > 1 else "animazioni"
    if not os.path.isdir(in_dir):
        print("ERRORE: la cartella %s non esiste" % in_dir)
        return 2
    os.makedirs(out_dir, exist_ok=True)
    done_dir = os.path.join(in_dir, DONE_DIR)
    fbx = sorted(f for f in os.listdir(in_dir)
                 if f.lower().endswith(".fbx") and os.path.isfile(os.path.join(in_dir, f)))
    if not fbx:
        print("Nessun FBX nuovo in %s: aggiorno solo l'elenco." % in_dir)
    failed = 0
    for fn in fbx:
        stem = os.path.splitext(fn)[0]
        src = os.path.join(in_dir, fn)
        try:
            take = convert(load(src), stem, travel)
        except (FbxError, OSError, ValueError, KeyError, IndexError, ZeroDivisionError) as e:
            failed += 1
            print("ERRORE  %s: %s" % (fn, e))
            continue
        write_json(os.path.join(out_dir, safe_name(stem) + ".json"), take)
        # converted files leave the inbox, so a take deleted from the output is not recreated
        os.makedirs(done_dir, exist_ok=True)
        os.replace(src, os.path.join(done_dir, fn))
        print("ok      %s  (%.1f s)" % (fn, take["seconds"]))
    takes = build_index(out_dir)
    print("\n%d convertite, %d con errori. Nell'elenco degli studenti: %d take." % (len(fbx) - failed, failed, len(takes)))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
