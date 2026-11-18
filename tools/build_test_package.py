"""Build the data for tests/plugin_test.luau: build/MotiveTestData.rbxmx, a ModuleScript returning the same take
package as base64 in four zip variants (stored as Converti.bat writes it, deflate level 9, deflate level 0, and a
macOS-style zip with a folder and __MACOSX entries).

Usage: python tools/build_test_package.py <261106_GorillaWave_T_001.fbx>
(the plugin test compares arm directions measured on that take).
"""
import base64
import io
import json
import os
import sys
import zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT)

from converter.fbx_reader import load  # noqa: E402
from converter.retarget import convert  # noqa: E402


def make_zip(entries, compression, level=None, prefix=""):
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w", compression=compression, compresslevel=level) as z:
        for name, text in entries:
            z.writestr(prefix + name, text)
        if prefix:
            z.writestr("__MACOSX/" + prefix + "._pacchetto.json", b"\x00\x05\x16\x07 mac metadata")
    return base64.b64encode(buf.getvalue()).decode("ascii")


def main(fbx):
    stem = os.path.splitext(os.path.basename(fbx))[0]
    take = convert(load(fbx), stem)
    manifest = {"format": "motive-roblox-pacchetto", "version": 1,
                "takes": [{"name": take["name"], "file": stem + ".json", "seconds": take["seconds"], "frames": take["frames"]}]}
    entries = [("pacchetto.json", json.dumps(manifest, separators=(",", ":"))),
               (stem + ".json", json.dumps(take, separators=(",", ":")))]
    variants = {
        "stored": make_zip(entries, zipfile.ZIP_STORED),
        "deflate9": make_zip(entries, zipfile.ZIP_DEFLATED, 9),
        "deflate0": make_zip(entries, zipfile.ZIP_DEFLATED, 0),
        "mac": make_zip(entries, zipfile.ZIP_DEFLATED, 6, prefix="Motive_prova/"),
    }
    body = "return {\n" + "".join('\t%s = "%s",\n' % (k, v) for k, v in variants.items()) + "}\n"
    xml = ('<roblox version="4"><Item class="ModuleScript" referent="RBX0"><Properties>'
           '<string name="Name">MotiveTestData</string>'
           '<ProtectedString name="Source"><![CDATA[%s]]></ProtectedString>'
           '</Properties></Item></roblox>') % body
    out = os.path.join(ROOT, "build")
    os.makedirs(out, exist_ok=True)
    path = os.path.join(out, "MotiveTestData.rbxmx")
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write(xml)
    print(path)


if __name__ == "__main__":
    main(sys.argv[1])
