"""Tests for the Motive -> Roblox converter. Run: python -m unittest discover -s tests

The end-to-end tests need a real Motive take: set MOTIVE_TEST_FBX to its path (they are skipped otherwise).
"""
import copy
import json
import math
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))

from converter import __main__ as cli  # noqa: E402
from converter.fbx_reader import TICKS_PER_SECOND, FbxError, load  # noqa: E402
from converter.retarget import (FPS, M, MAP, PARTS, conj, convert, global_pose, mm, mt, mv,  # noqa: E402
                                quat, quat_to_matrix, resolve_names, ry)

SAMPLE = os.environ.get("MOTIVE_TEST_FBX", "")

# segments checked against the source: part -> (bone, child bone, canonical rest direction or None = same as source)
SEGMENTS = {
    "LeftUpperArm": ("LeftArm", "LeftForeArm", (0, -1, 0)), "LeftLowerArm": ("LeftForeArm", "LeftHand", (0, -1, 0)),
    "RightUpperArm": ("RightArm", "RightForeArm", (0, -1, 0)),
    "RightLowerArm": ("RightForeArm", "RightHand", (0, -1, 0)),
    "LeftUpperLeg": ("LeftUpLeg", "LeftLeg", None), "LeftLowerLeg": ("LeftLeg", "LeftFoot", None),
    "RightUpperLeg": ("RightUpLeg", "RightLeg", None), "RightLowerLeg": ("RightLeg", "RightFoot", None),
    "LeftFoot": ("LeftFoot", "LeftToeBase", None), "UpperTorso": ("Spine4", "Neck", None),
}


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

    def test_safe_name(self):
        self.assertEqual(cli.safe_name("261106 Big T_001"), "261106_Big_T_001")
        self.assertEqual(cli.safe_name("***"), "take")


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
        d0 = conj(mm(w0["Hips"][0], mt(rest["Hips"][0])))
        fwd = mv(d0, [0, 0, -1])
        yaw = ry(-math.degrees(math.atan2(-fwd[0], -fwd[2])))
        worst = 0.0
        for f in range(0, take["frames"], 7):
            world = compose(take, f)
            src = global_pose(skel, ids, round(f * TICKS_PER_SECOND / FPS))
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

    def test_cli_writes_take_and_index(self):
        with tempfile.TemporaryDirectory() as d:
            src, out = os.path.join(d, "in"), os.path.join(d, "out")
            os.makedirs(src)
            with open(SAMPLE, "rb") as a, open(os.path.join(src, "My Take.fbx"), "wb") as b:
                b.write(a.read())
            with open(os.path.join(src, "broken.fbx"), "wb") as b:
                b.write(b"not an fbx")
            code = cli.main([src, out])
            self.assertEqual(code, 1)  # the broken file is reported, the good one converted
            with open(os.path.join(out, "index.json"), encoding="utf-8") as f:
                index = json.load(f)
            self.assertEqual([t["file"] for t in index["takes"]], ["My_Take.json"])
            self.assertEqual(index["takes"][0]["name"], "My Take")


if __name__ == "__main__":
    unittest.main()
