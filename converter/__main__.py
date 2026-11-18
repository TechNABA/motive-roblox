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
INDEX = "index.json"


def safe_name(stem):
    name = re.sub(r"[^A-Za-z0-9_-]+", "_", stem).strip("_") or "take"
    return name + "_take" if name.lower() == "index" else name


def write_json(path, data):
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(data, f, separators=(",", ":"), ensure_ascii=False)
    os.replace(tmp, path)


def read_take_header(path):
    """Name, seconds and frames of a take file, or None if the file is not a take."""
    try:
        with open(path, encoding="utf-8") as f:
            d = json.load(f)
    except (OSError, ValueError):
        return None
    if not isinstance(d, dict) or d.get("format") != "motive-roblox":
        return None
    name, seconds, frames = d.get("name"), d.get("seconds"), d.get("frames")
    if not isinstance(name, str) or not isinstance(seconds, (int, float)) or not isinstance(frames, int):
        return None
    return {"name": name, "seconds": seconds, "frames": frames}


def build_index(out_dir):
    takes = []
    for fn in sorted(os.listdir(out_dir)):
        if not fn.endswith(".json") or fn.lower() == INDEX:
            continue
        head = read_take_header(os.path.join(out_dir, fn))
        if head:
            takes.append({"name": head["name"], "file": fn, "seconds": head["seconds"], "frames": head["frames"]})
    takes.sort(key=lambda t: t["name"].lower())
    write_json(os.path.join(out_dir, INDEX), {"format": "motive-roblox-index", "version": 1, "takes": takes})
    return takes


def convert_one(src, stem, out_path, travel):
    existing = read_take_header(out_path) if os.path.exists(out_path) else None
    if existing and existing["name"] != stem:
        raise FbxError("il nome finisce nello stesso file della take '%s': rinomina l'FBX" % existing["name"])
    take = convert(load(src), stem, travel)
    write_json(out_path, take)
    return take


def main(argv):
    args = [a for a in argv if not a.startswith("--")]
    travel = "--sul-posto" not in argv
    in_dir = args[0] if len(args) > 0 else "export_motive"
    out_dir = args[1] if len(args) > 1 else "animazioni"
    if not os.path.isdir(in_dir):
        print("ERRORE: la cartella %s non esiste" % in_dir)
        return 2
    os.makedirs(out_dir, exist_ok=True)
    for fn in os.listdir(out_dir):  # leftovers of an interrupted run
        if fn.endswith(".tmp"):
            os.remove(os.path.join(out_dir, fn))
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
            take = convert_one(src, stem, os.path.join(out_dir, safe_name(stem) + ".json"), travel)
        except Exception as e:  # one bad file must not stop the others
            failed += 1
            print("ERRORE  %s: %s" % (fn, e))
            continue
        # converted files leave the inbox, so a take deleted from the output is not recreated
        os.makedirs(done_dir, exist_ok=True)
        os.replace(src, os.path.join(done_dir, fn))
        print("ok      %s  (%.1f s)" % (fn, take["seconds"]))
    takes = build_index(out_dir)
    print("\n%d convertite, %d con errori. Nell'elenco degli studenti: %d take." % (len(fbx) - failed, failed, len(takes)))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
