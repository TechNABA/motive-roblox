"""Build the plugin file for the release: build/MotiveAnimazioni.rbxmx, a Script holding plugin/MotiveAnimazioni.lua
(and build/MotiveAnimazioni_modulo.rbxmx, the same code as a ModuleScript, for tests/plugin_test.luau).

Dragged into Studio, the Script can be saved with "Save as Local Plugin" or published with "Publish as Plugin".
Usage: python tools/build_plugin.py
"""
import os
import re

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def main():
    with open(os.path.join(ROOT, "plugin", "MotiveAnimazioni.lua"), encoding="utf-8") as f:
        src = f.read()
    if "]]>" in src:
        raise SystemExit("il sorgente contiene ']]>' e non puo' stare in un CDATA")
    version = re.search(r'local VERSION = "([^"]+)"', src).group(1)
    xml = ('<roblox version="4"><Item class="Script" referent="RBX0"><Properties>'
           '<string name="Name">AnimazioniMotive</string>'
           '<token name="RunContext">0</token>'
           '<ProtectedString name="Source"><![CDATA[%s]]></ProtectedString>'
           '</Properties></Item></roblox>') % src
    out_dir = os.path.join(ROOT, "build")
    os.makedirs(out_dir, exist_ok=True)
    path = os.path.join(out_dir, "MotiveAnimazioni.rbxmx")
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write(xml)
    # same code as a ModuleScript, for tests/plugin_test.luau
    module = ('<roblox version="4"><Item class="ModuleScript" referent="RBX0"><Properties>'
              '<string name="Name">MotiveAnimazioni</string>'
              '<ProtectedString name="Source"><![CDATA[%s]]></ProtectedString>'
              '</Properties></Item></roblox>') % src
    with open(os.path.join(out_dir, "MotiveAnimazioni_modulo.rbxmx"), "w", encoding="utf-8", newline="\n") as f:
        f.write(module)
    print("%s (versione %s)" % (path, version))


if __name__ == "__main__":
    main()
