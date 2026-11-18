"""Convert Motive FBX exports into a take package (.zip) for the Roblox Studio plugin.

Usage: python -m converter [--sul-posto] [--out=CARTELLA] <folder or .fbx> [...]
Inputs are folders (their .fbx files, not subfolders) or single .fbx files. The package is written to
<out>/Motive_<name>.zip (default out: "pacchetti" next to the converter), where <name> is the dragged folder's
name, or the date and time when several inputs are given. The zip holds one JSON file per take and pacchetto.json,
the list of takes. Files are stored uncompressed: the plugin reads them directly.

Exit codes: 0 all converted, 10 some files rejected (the package holds the others), 2 nothing to package.
"""
import datetime
import json
import os
import re
import sys
import zipfile

from .fbx_reader import FbxError, load
from .retarget import convert

MANIFEST = "pacchetto.json"
PARTIAL = 10
KNOWN_OPTIONS = ("--out=", "--sul-posto")
DEFAULT_OUT = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "pacchetti")


def safe_name(stem):
    name = re.sub(r"[^A-Za-z0-9_-]+", "_", stem).strip("_") or "take"
    return name + "_take" if name.lower() == "pacchetto" else name


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


def package_name(inputs):
    if len(inputs) == 1 and os.path.isdir(inputs[0]):
        base = os.path.basename(os.path.normpath(os.path.abspath(inputs[0])))
    else:
        base = datetime.datetime.now().strftime("%Y%m%d_%H%M")
    return "Motive_" + safe_name(base) + ".zip"


def write_package(path, takes):
    """takes: list of (file name, take dict). Written to a temporary file first, then moved in place."""
    tmp = path + ".tmp"
    manifest = {"format": "motive-roblox-pacchetto", "version": 1,
                "takes": [{"name": t["name"], "file": fn, "seconds": t["seconds"], "frames": t["frames"]}
                          for fn, t in takes]}
    with zipfile.ZipFile(tmp, "w", compression=zipfile.ZIP_STORED) as z:
        z.writestr(MANIFEST, json.dumps(manifest, separators=(",", ":"), ensure_ascii=False))
        for fn, take in takes:
            z.writestr(fn, json.dumps(take, separators=(",", ":"), ensure_ascii=False))
    os.replace(tmp, path)


def main(argv):
    unknown = [a for a in argv if a.startswith("--") and not a.startswith(KNOWN_OPTIONS)]
    if unknown:
        print("ERRORE: opzione sconosciuta %s (valide: --out=CARTELLA, --sul-posto)" % ", ".join(unknown))
        return 2
    opts = dict(a[2:].split("=", 1) for a in argv if a.startswith("--") and "=" in a)
    travel = "--sul-posto" not in argv
    inputs = [a for a in argv if not a.startswith("--")]
    if not inputs:
        print("Trascina su Converti.bat la cartella degli export di Motive (o dei file .fbx).")
        return 2
    fbx, missing = collect_inputs(inputs)
    for item in missing:
        print("ERRORE  %s: non e' una cartella ne' un file .fbx" % item)
    if not fbx:
        print("Nessun file .fbx da convertire.")
        return 2
    takes, seen, failed = [], {}, len(missing)
    for src in fbx:
        fn = os.path.basename(src)
        stem = os.path.splitext(fn)[0]
        out_name = safe_name(stem) + ".json"
        try:
            if out_name.lower() in seen:
                raise FbxError("stesso nome di %s: rinomina uno dei due" % seen[out_name.lower()])
            take = convert(load(src), stem, travel)
        except Exception as e:  # one bad file must not stop the others
            failed += 1
            print("ERRORE  %s: %s" % (src, e))
            continue
        seen[out_name.lower()] = fn
        takes.append((out_name, take))
        print("ok      %s  (%.1f s)" % (fn, take["seconds"]))
    if not takes:
        print("\nNessuna take convertita: nessun pacchetto creato.")
        return 2
    out_dir = opts.get("out", DEFAULT_OUT)
    os.makedirs(out_dir, exist_ok=True)
    path = os.path.join(out_dir, package_name(inputs))
    write_package(path, takes)
    print("\n%d take nel pacchetto, %d file con errori.\nPACCHETTO: %s" % (len(takes), failed, os.path.abspath(path)))
    return PARTIAL if failed else 0


def run(argv):
    try:
        return main(argv)
    except Exception as e:
        print("ERRORE imprevisto: %s: %s" % (type(e).__name__, e))
        return 3


if __name__ == "__main__":
    sys.exit(run(sys.argv[1:]))
