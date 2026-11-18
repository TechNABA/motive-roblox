"""Convert Motive FBX exports into the take files the Roblox plugin reads.

Usage: python -m converter [--out=animazioni] [--registro=FILE] [--sul-posto] [folder or .fbx ...]
Inputs are folders (their .fbx files, not subfolders) or single .fbx files; default: export_motive.
The FBX files are never moved: a local record (default .convertiti.json next to the output folder) remembers which
ones are already converted (name, size, date), so they are skipped next time, a re-exported file is converted
again, and a take deleted from the output is not recreated. The index (index.json) is always rebuilt.
"""
import json
import os
import re
import sys

from .fbx_reader import FbxError, load
from .retarget import convert

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
    if os.path.exists(out_path):
        existing = read_take_header(out_path)
        if existing is None:
            raise FbxError("in animazioni c'e' gia' un file %s che non e' una take: rinomina l'FBX"
                           % os.path.basename(out_path))
        if existing["name"] != stem:
            raise FbxError("il nome finisce nello stesso file della take '%s': rinomina l'FBX" % existing["name"])
    take = convert(load(src), stem, travel)
    write_json(out_path, take)
    return take


def file_key(path):
    st = os.stat(path)
    return "%s|%d|%d" % (os.path.basename(path).lower(), st.st_size, st.st_mtime_ns)


def load_record(path):
    """{"files": {fbx key: take file}, "origin": {take file: folder of its FBX}}"""
    empty = {"files": {}, "origin": {}}
    try:
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
    except FileNotFoundError:
        return empty
    except (OSError, ValueError):
        data = None
    if not (isinstance(data, dict) and isinstance(data.get("files"), dict) and isinstance(data.get("origin"), dict)):
        print("ATTENZIONE: il registro %s e' illeggibile, lo ricreo (gli FBX verranno riconvertiti)" % path)
        return empty
    return data


def collect_inputs(inputs):
    """FBX files from folders (not subfolders) and single files; missing inputs are reported."""
    found, missing = [], []
    for item in inputs:
        if os.path.isdir(item):
            found += sorted(os.path.join(item, f) for f in os.listdir(item)
                            if f.lower().endswith(".fbx") and os.path.isfile(os.path.join(item, f)))
        elif os.path.isfile(item) and item.lower().endswith(".fbx"):
            found.append(item)
        else:
            missing.append(item)
    return found, missing


def main(argv):
    opts = dict(a[2:].split("=", 1) for a in argv if a.startswith("--") and "=" in a)
    travel = "--sul-posto" not in argv
    inputs = [a for a in argv if not a.startswith("--")] or ["export_motive"]
    out_dir = opts.get("out", "animazioni")
    record_path = opts.get("registro", os.path.join(os.path.dirname(os.path.abspath(out_dir)), ".convertiti.json"))
    fbx, missing = collect_inputs(inputs)
    for item in missing:
        print("ERRORE  %s: non e' una cartella ne' un file .fbx" % item)
    if missing and not fbx:
        return 2
    os.makedirs(out_dir, exist_ok=True)
    for fn in os.listdir(out_dir):  # leftovers of an interrupted run
        if fn.endswith(".tmp"):
            os.remove(os.path.join(out_dir, fn))
    record = load_record(record_path)
    failed = done = skipped = 0
    seen = {}
    for src in fbx:
        fn = os.path.basename(src)
        stem = os.path.splitext(fn)[0]
        try:
            key = file_key(src)
            if key in record["files"]:
                skipped += 1
                continue
            out_name = safe_name(stem) + ".json"
            if out_name.lower() in seen:
                raise FbxError("stesso nome di %s, convertito in questo giro: rinomina uno dei due" % seen[out_name.lower()])
            folder = os.path.dirname(os.path.abspath(src))
            replacing = os.path.exists(os.path.join(out_dir, out_name))
            origin = record["origin"].get(out_name)
            if replacing and origin and os.path.normcase(origin) != os.path.normcase(folder):
                raise FbxError("esiste gia' una take con questo nome, da un'altra cartella (%s): rinomina l'FBX" % origin)
            take = convert_one(src, stem, os.path.join(out_dir, out_name), travel)
        except Exception as e:  # one bad file must not stop the others
            failed += 1
            print("ERRORE  %s: %s" % (src, e))
            continue
        seen[out_name.lower()] = src
        record["files"][key] = out_name
        record["origin"][out_name] = folder
        done += 1
        print("%s %s  (%.1f s)" % ("sostituita" if replacing else "ok     ", fn, take["seconds"]))
    write_json(record_path, record)
    takes = build_index(out_dir)
    if skipped:
        print("\n%d FBX gia' convertiti in passato, saltati." % skipped)
    print("\n%d convertite, %d con errori. Nell'elenco degli studenti: %d take." % (done, failed + len(missing), len(takes)))
    return 1 if failed or missing else 0


def run(argv):
    """Exit codes: 0 all converted, 1 some files rejected (the others are fine to publish), >= 2 stop, publish nothing."""
    try:
        return main(argv)
    except Exception as e:
        print("ERRORE imprevisto, niente viene pubblicato: %s: %s" % (type(e).__name__, e))
        return 3


if __name__ == "__main__":
    sys.exit(run(sys.argv[1:]))
