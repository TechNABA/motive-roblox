"""Tests for the Motive -> Roblox converter. Run: python -m unittest discover -s tests

The end-to-end tests need a real Motive take: set MOTIVE_TEST_FBX to its path (they are skipped otherwise).
"""
import copy
import shutil
import struct
import json
import math
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))

from converter import __main__ as cli  # noqa: E402
from converter.fbx_reader import TICKS_PER_SECOND, FbxError, load  # noqa: E402
from converter.retarget import (FPS, M, PARTS, align, bone_time_range, conj, convert, global_pose, heading, mm, mt, mv,  # noqa: E402
                                quat, resolve_names, ry)

SAMPLE = os.environ.get("MOTIVE_TEST_FBX", "")

# segments checked against the source: part -> (bone, child bone, canonical rest direction or None = same as source)
SEGMENTS = {
    "LeftUpperArm": ("LeftArm", "LeftForeArm", (0, -1, 0)), "LeftLowerArm": ("LeftForeArm", "LeftHand", (0, -1, 0)),
    "RightUpperArm": ("RightArm", "RightForeArm", (0, -1, 0)),
    "RightLowerArm": ("RightForeArm", "RightHand", (0, -1, 0)),
    "LeftUpperLeg": ("LeftUpLeg", "LeftLeg", (0, -1, 0)), "LeftLowerLeg": ("LeftLeg", "LeftFoot", (0, -1, 0)),
    "RightUpperLeg": ("RightUpLeg", "RightLeg", (0, -1, 0)), "RightLowerLeg": ("RightLeg", "RightFoot", (0, -1, 0)),
    "LeftFoot": ("LeftFoot", "LeftToeBase", None), "UpperTorso": ("Spine4", "Neck", None),
}


def quat_to_matrix(q):
    x, y, z, w = q
    return [1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w),
            2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w),
            2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y)]


def angle(a, b):
    na, nb = math.sqrt(sum(x * x for x in a)), math.sqrt(sum(x * x for x in b))
    return math.degrees(math.acos(max(-1.0, min(1.0, sum(x * y for x, y in zip(a, b)) / (na * nb)))))


def compose(take, f):
    """World rotation of every part at frame f, from the take's local quaternions."""
    world = {"HumanoidRootPart": [1, 0, 0, 0, 1, 0, 0, 0, 1]}
    for i, part in enumerate(take["parts"]):
        q = take["rot"][(f * len(take["parts"]) + i) * 4:(f * len(take["parts"]) + i) * 4 + 4]
        world[part] = mm(world[take["parents"][i]], quat_to_matrix(q))
    return world


class MathTests(unittest.TestCase):
    def test_quaternion_roundtrip(self):
        for r in (ry(30), mm(ry(170), [1, 0, 0, 0, 0, -1, 0, 1, 0]), [-1, 0, 0, 0, 1, 0, 0, 0, -1]):
            back = quat_to_matrix(quat(r))
            self.assertLess(max(abs(a - b) for a, b in zip(r, back)), 1e-9)

    def test_heading_ignores_bending(self):
        for yaw in (0, 37, -120):
            for pitch in (0, 85, 95):  # standing, bent over, lying face down
                c, s = math.cos(math.radians(pitch)), math.sin(math.radians(pitch))
                d = mm(ry(yaw), [1, 0, 0, 0, c, -s, 0, s, c])
                self.assertAlmostEqual(heading(d), yaw, places=6)

    def test_euler_interpolation_takes_short_way(self):
        from converter.retarget import _sample
        self.assertAlmostEqual(_sample(((0, 10), (179.0, -179.0)), 5, 0, True), 180.0)
        self.assertAlmostEqual(_sample(((0, 10), (10.0, 20.0)), 5, 0), 15.0)

    def test_safe_name(self):
        self.assertEqual(cli.safe_name("261106 Big T_001"), "261106_Big_T_001")
        self.assertEqual(cli.safe_name("***"), "take")
        self.assertEqual(cli.safe_name("Index"), "Index_take")  # never overwrites index.json

    def test_align_opposite_directions(self):
        r = align([0, -1, 0], [0, 1, 0])
        self.assertLess(max(abs(a - b) for a, b in zip(mv(r, [0, -1, 0]), [0, 1, 0])), 1e-9)
        self.assertLess(max(abs(a - b) for a, b in zip(mm(r, mt(r)), [1, 0, 0, 0, 1, 0, 0, 0, 1])), 1e-9)

    def test_index_ignores_foreign_json_and_leftovers(self):
        with tempfile.TemporaryDirectory() as d:
            src, out = os.path.join(d, "in"), os.path.join(d, "out")
            os.makedirs(src)
            os.makedirs(out)
            for name, body in (("lista.json", "[1, 2]"), ("rotto.json", "{"), ("vecchio.json.tmp", "x"),
                               ("senza.json", '{"format": "motive-roblox", "name": "x"}')):
                with open(os.path.join(out, name), "w", encoding="utf-8") as f:
                    f.write(body)
            self.assertEqual(cli.main(["--out=" + out, src]), 0)
            with open(os.path.join(out, "index.json"), encoding="utf-8") as f:
                self.assertEqual(json.load(f)["takes"], [])
            self.assertNotIn("vecchio.json.tmp", os.listdir(out))

    def test_corrupt_fbx_is_reported(self):
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "x.fbx")
            with open(path, "wb") as f:
                f.write(b"Kaydara FBX Binary  " + bytes([0, 0x1A, 0]) + struct.pack("<I", 7500) + bytes([0xFF]) * 40)
            with self.assertRaises(FbxError):
                load(path)


@unittest.skipUnless(os.path.isfile(SAMPLE), "MOTIVE_TEST_FBX non impostata")
class EndToEndTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.skel = load(SAMPLE)
        cls.take = convert(cls.skel, "sample")

    def test_shape(self):
        t = self.take
        self.assertEqual(len(t["root"]), 3 * t["frames"])
        self.assertEqual(len(t["rot"]), 4 * len(PARTS) * t["frames"])
        self.assertEqual(t["root"][:3], [0.0, t["root"][1], 0.0])  # travel starts at the origin

    def test_segment_directions_match_source(self):
        skel, take = self.skel, self.take
        ids = resolve_names(skel)
        rest = global_pose(skel, ids, None)
        w0 = global_pose(skel, ids, 0)
        yaw = ry(-heading(conj(mm(w0["Hips"][0], mt(rest["Hips"][0])))))
        worst = 0.0
        for f in range(0, take["frames"], 7):
            world = compose(take, f)
            src = global_pose(skel, ids, bone_time_range(skel, ids)[0] + round(f * TICKS_PER_SECOND / FPS))
            for part, (b, c, canon) in SEGMENTS.items():
                cur = mv(yaw, mv(M, [q - p for p, q in zip(src[b][1], src[c][1])]))
                restdir = canon or mv(M, [q - p for p, q in zip(rest[b][1], rest[c][1])])
                worst = max(worst, angle(mv(world[part], restdir), cur))
        self.assertLess(worst, 1.5)

    def test_taller_actor_gives_same_motion(self):
        """Hips height and travel are scaled by the actor's own leg: a 20% bigger actor converts the same."""
        big = copy.deepcopy(self.skel)
        for m in big.models.values():
            m["T"] = [x * 1.2 for x in m["T"]]
            curves = m["curves"].get("T")
            if curves:
                m["curves"]["T"] = [None if c is None else (c[0], tuple(v * 1.2 for v in c[1])) for c in curves]
        other = convert(big, "big")
        self.assertLess(max(abs(a - b) for a, b in zip(other["root"], self.take["root"])), 2e-3)
        self.assertAlmostEqual(other["source_leg"], self.take["source_leg"] * 1.2, places=2)

    def test_take_not_starting_at_zero(self):
        """Keys shifted by 10 s (timecode): same take, no frozen lead-in."""
        late = copy.deepcopy(self.skel)
        shift = 10 * TICKS_PER_SECOND
        for m in late.models.values():
            for key in ("T", "R"):
                if m["curves"].get(key):
                    m["curves"][key] = [None if c is None else (tuple(t + shift for t in c[0]), c[1])
                                        for c in m["curves"][key]]
        other = convert(late, "late")
        self.assertEqual(other["frames"], self.take["frames"])
        self.assertEqual(other["rot"][:60], self.take["rot"][:60])

    def test_name_collision_is_reported(self):
        with tempfile.TemporaryDirectory() as d:
            src, out = os.path.join(d, "in"), os.path.join(d, "out")
            os.makedirs(src)
            for name in ("Take 1.fbx", "Take.1.fbx"):
                shutil.copy(SAMPLE, os.path.join(src, name))
            self.assertEqual(cli.main(["--out=" + out, src]), 1)
            with open(os.path.join(out, "index.json"), encoding="utf-8") as f:
                self.assertEqual([t["name"] for t in json.load(f)["takes"]], ["Take 1"])

    def test_missing_bone_is_reported(self):
        broken = copy.deepcopy(self.skel)
        broken.by_name.pop("LeftForeArm")
        with self.assertRaises(FbxError) as e:
            convert(broken, "x")
        self.assertIn("LeftForeArm", str(e.exception))

    def test_prefixed_bone_names(self):
        pref = copy.deepcopy(self.skel)
        pref.by_name = {"Actor_" + k: v for k, v in pref.by_name.items()}
        other = convert(pref, "pref")
        self.assertEqual(other["rot"][:40], self.take["rot"][:40])

    def test_cli_drag_and_drop_flow(self):
        with tempfile.TemporaryDirectory() as d:
            motive, out = os.path.join(d, "Motive export"), os.path.join(d, "repo", "animazioni")
            os.makedirs(os.path.join(motive, "sottocartella"))
            shutil.copy(SAMPLE, os.path.join(motive, "My Take.fbx"))
            shutil.copy(SAMPLE, os.path.join(motive, "sottocartella", "ignorata.fbx"))  # subfolders are not read
            with open(os.path.join(motive, "broken.fbx"), "wb") as b:
                b.write(b"not an fbx")
            single = os.path.join(d, "Singola.fbx")
            shutil.copy(SAMPLE, single)

            def index():
                with open(os.path.join(out, "index.json"), encoding="utf-8") as f:
                    return [t["name"] for t in json.load(f)["takes"]]

            # a dragged folder plus a dragged file: the broken file is reported, the good ones converted
            self.assertEqual(cli.main(["--out=" + out, motive, single]), 1)
            self.assertEqual(index(), ["My Take", "Singola"])
            self.assertEqual(sorted(os.listdir(motive)), ["My Take.fbx", "broken.fbx", "sottocartella"])  # nothing moved
            self.assertTrue(os.path.isfile(os.path.join(d, "repo", ".convertiti.json")))
            # second run: already converted files are skipped, a deleted take is not recreated
            os.remove(os.path.join(motive, "broken.fbx"))
            os.remove(os.path.join(out, "My_Take.json"))
            self.assertEqual(cli.main(["--out=" + out, motive]), 0)
            self.assertEqual(index(), ["Singola"])
            # a re-exported file (new date) is converted again
            st = os.stat(os.path.join(motive, "My Take.fbx"))
            os.utime(os.path.join(motive, "My Take.fbx"), ns=(st.st_atime_ns, st.st_mtime_ns + 10 ** 9))
            self.assertEqual(cli.main(["--out=" + out, motive]), 0)
            self.assertEqual(index(), ["My Take", "Singola"])
            # same name from another session folder: refused, the published take is kept
            other = os.path.join(d, "Altra sessione")
            os.makedirs(other)
            shutil.copy(os.path.join(motive, "My Take.fbx"), os.path.join(other, "My Take.fbx"))
            st = os.stat(os.path.join(other, "My Take.fbx"))
            os.utime(os.path.join(other, "My Take.fbx"), ns=(st.st_atime_ns, st.st_mtime_ns + 5 * 10 ** 9))
            self.assertEqual(cli.main(["--out=" + out, other]), 1)
            self.assertEqual(index(), ["My Take", "Singola"])
            # something that is neither a folder nor an .fbx: stop
            self.assertEqual(cli.main(["--out=" + out, os.path.join(d, "non esiste")]), 2)


if __name__ == "__main__":
    unittest.main()
