"""Build the plugin file for the release: build/MotiveAnimazioni.rbxmx, a Script holding plugin/MotiveAnimazioni.lua
(and build/MotiveAnimazioni_modulo.rbxmx, the same code as a ModuleScript, for tests/plugin_test.luau).

Dragged into Studio, the Script can be saved with "Save as Local Plugin" or published with "Publish as Plugin".
Usage: python tools/build_plugin.py
"""
import os
import re

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def item_xml(cls, name, src):
    return ('<roblox version="4"><Item class="%s" referent="RBX0"><Properties>'
            '<string name="Name">%s</string>'
            '<ProtectedString name="Source"><![CDATA[%s]]></ProtectedString>'
            '</Properties></Item></roblox>') % (cls, name, src)


def main():
    with open(os.path.join(ROOT, "plugin", "MotiveAnimazioni.lua"), encoding="utf-8") as f:
        src = f.read()
    if "]]>" in src:
        raise SystemExit("il sorgente contiene ']]>' e non puo' stare in un CDATA")
    version = re.search(r'local VERSION = "([^"]+)"', src).group(1)
    out_dir = os.path.join(ROOT, "build")
    os.makedirs(out_dir, exist_ok=True)
    path = os.path.join(out_dir, "MotiveAnimazioni.rbxmx")
    # the plugin as a Script, and the same code as a ModuleScript for tests/plugin_test.luau
    for file_name, cls, name in ((path, "Script", "AnimazioniMotive"),
                                 (os.path.join(out_dir, "MotiveAnimazioni_modulo.rbxmx"), "ModuleScript", "MotiveAnimazioni")):
        with open(file_name, "w", encoding="utf-8", newline="\n") as f:
            f.write(item_xml(cls, name, src))
    print("%s (versione %s)" % (path, version))


if __name__ == "__main__":
    main()
