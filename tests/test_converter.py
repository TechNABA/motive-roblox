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
import zipfile

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))

from converter import __main__ as cli  # noqa: E402
from converter.fbx_reader import TICKS_PER_SECOND, FbxError, load  # noqa: E402
from converter.retarget import (FPS, M, PARTS, align, bone_time_range, conj, convert, global_pose, heading, mm, mt, mv,  # noqa: E402
                                quat, quat_to_matrix, resolve_names, ry)

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

    def test_rotation_interpolated_as_a_whole_near_gimbal_lock(self):
        """Between two keys where Y is near 90 deg the Euler X and Z jump by 180 while the rotation barely moves."""
        from converter.retarget import _rotation_at, euler_xyz
        a, b = [10.0, 89.0, 20.0], [-170.0, 91.0, -160.0]
        m = {"R": [0, 0, 0], "r_keys": (0, 10), "curves": {"R": [((0, 10), (a[i], b[i])) for i in range(3)]}}
        mid = _rotation_at(m, 5)
        ra, rb = euler_xyz(a), euler_xyz(b)
        for end in (ra, rb):  # the midpoint stays close to both keys (they are 2 deg apart)
            self.assertLess(max(abs(x - y) for x, y in zip(mid, end)), 0.05)

    def test_safe_name(self):
        self.assertEqual(cli.safe_name("261106 Big T_001"), "261106_Big_T_001")
        self.assertEqual(cli.safe_name("***"), "take")
        self.assertEqual(cli.safe_name("Pacchetto"), "Pacchetto_take")  # never overwrites pacchetto.json

    def test_align_opposite_directions(self):
        r = align([0, -1, 0], [0, 1, 0])
        self.assertLess(max(abs(a - b) for a, b in zip(mv(r, [0, -1, 0]), [0, 1, 0])), 1e-9)
        self.assertLess(max(abs(a - b) for a, b in zip(mm(r, mt(r)), [1, 0, 0, 0, 1, 0, 0, 0, 1])), 1e-9)

    def test_unknown_option_is_refused(self):
        with tempfile.TemporaryDirectory() as d:
            self.assertEqual(cli.main(["--sul_posto", "--out=" + os.path.join(d, "out"), d]), 2)

    def test_nothing_to_package(self):
        with tempfile.TemporaryDirectory() as d:
            out = os.path.join(d, "out")
            self.assertEqual(cli.main(["--out=" + out]), 2)  # double click: nothing dragged
            self.assertEqual(cli.main(["--out=" + out, d]), 2)  # a folder without FBX
            with open(os.path.join(d, "rotto.fbx"), "wb") as f:
                f.write(b"not an fbx")
            self.assertEqual(cli.main(["--out=" + out, d]), 2)  # only broken files: no package
            self.assertFalse(os.path.exists(out) and os.listdir(out))

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

    def test_version_fingerprint(self):
        """Same motion -> same id (whatever the name); different motion -> different id."""
        self.assertRegex(self.take["id"], r"^[0-9a-f]{16}$")
        self.assertEqual(convert(self.skel, "altro nome")["id"], self.take["id"])
        self.assertNotEqual(convert(self.skel, "sample", travel=False)["id"], self.take["id"])

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
            if m.get("r_keys"):
                m["r_keys"] = tuple(t + shift for t in m["r_keys"])
            for key in ("T", "R"):
                if m["curves"].get(key):
                    m["curves"][key] = [None if c is None else (tuple(t + shift for t in c[0]), c[1])
                                        for c in m["curves"][key]]
        other = convert(late, "late")
        self.assertEqual(other["frames"], self.take["frames"])
        self.assertEqual(other["rot"][:60], self.take["rot"][:60])

    def test_unsupported_settings_on_intermediate_bones(self):
        for setting in ("pre", "scale"):
            broken = copy.deepcopy(self.skel)
            spine2 = broken.by_name["Spine2"]  # not used directly, but an ancestor of Spine4
            broken.models[spine2]["unsupported"] = "l'osso Spine2 %s" % setting
            with self.assertRaises(FbxError) as e:
                convert(broken, "x")
            self.assertIn("Spine2", str(e.exception))

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

    def test_rotation_pivot_is_refused(self):
        broken = copy.deepcopy(self.skel)
        hips = broken.by_name["Hips"]
        broken.models[hips]["unsupported"] = "l'osso Hips ha RotationPivot, non supportato"
        with self.assertRaises(FbxError) as e:
            convert(broken, "x")
        self.assertIn("RotationPivot", str(e.exception))

    def test_package_from_dragged_folder(self):
        with tempfile.TemporaryDirectory() as d:
            motive, out = os.path.join(d, "Sessione 261106"), os.path.join(d, "pacchetti")
            os.makedirs(os.path.join(motive, "sottocartella"))
            shutil.copy(SAMPLE, os.path.join(motive, "My Take.fbx"))
            shutil.copy(SAMPLE, os.path.join(motive, "Take.1.fbx"))
            shutil.copy(SAMPLE, os.path.join(motive, "Take 1.fbx"))  # same file name as Take.1 once cleaned
            shutil.copy(SAMPLE, os.path.join(motive, "sottocartella", "ignorata.fbx"))  # subfolders are not read
            with open(os.path.join(motive, "broken.fbx"), "wb") as b:
                b.write(b"not an fbx")
            self.assertEqual(cli.main(["--out=" + out, motive]), cli.PARTIAL)
            path = os.path.join(out, "Motive_Sessione_261106.zip")
            self.assertEqual(os.listdir(out), ["Motive_Sessione_261106.zip"])
            with zipfile.ZipFile(path) as z:
                self.assertTrue(all(i.compress_type == zipfile.ZIP_STORED for i in z.infolist()))
                manifest = json.loads(z.read("pacchetto.json"))
                self.assertEqual(manifest["format"], "motive-roblox-pacchetto")
                self.assertEqual([t["name"] for t in manifest["takes"]], ["My Take", "Take 1"])
                for t in manifest["takes"]:
                    take = json.loads(z.read(t["file"]))
                    self.assertEqual((take["name"], take["frames"]), (t["name"], t["frames"]))
            self.assertEqual(sorted(os.listdir(motive)),  # the FBX are not touched
                             ["My Take.fbx", "Take 1.fbx", "Take.1.fbx", "broken.fbx", "sottocartella"])

    def test_package_from_several_files(self):
        with tempfile.TemporaryDirectory() as d:
            a, b, out = os.path.join(d, "A.fbx"), os.path.join(d, "B.fbx"), os.path.join(d, "pacchetti")
            shutil.copy(SAMPLE, a)
            shutil.copy(SAMPLE, b)
            self.assertEqual(cli.main(["--out=" + out, a, b, "--sul-posto"]), 0)
            (name,) = os.listdir(out)
            self.assertRegex(name, r"^Motive_\d{8}_\d{4}\.zip$")
            with zipfile.ZipFile(os.path.join(out, name)) as z:
                self.assertEqual(sorted(z.namelist()), ["A.json", "B.json", "pacchetto.json"])


if __name__ == "__main__":
    unittest.main()
