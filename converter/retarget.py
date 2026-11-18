"""Retarget a Motive take onto the canonical Roblox R15 rig.

Canonical rig = classic R15 (content/avatar/characterR15.rbxm): every joint frame aligned with the world,
character facing -Z, left side on -X, arms and legs straight down at rest, hip->ankle 1.748 studs.
The output holds, per frame, the Motor6D.Transform rotation of each of the 15 R15 parts (as a quaternion)
and the translation of LowerTorso. The Studio plugin adapts this to the student's avatar.
"""
import math

from .fbx_reader import TICKS_PER_SECOND, FbxError

FPS = 30
CANON_LEG = 1.748  # classic R15 hip->ankle, studs
SMOOTH_S = 1.0  # moving-average window removed from horizontal hips motion when travel is off

# R15 part -> (Motive bone, parent part)
MAP = {
    "LowerTorso": ("Hips", None),
    "UpperTorso": ("Spine4", "LowerTorso"),
    "Head": ("Head", "UpperTorso"),
    "LeftUpperArm": ("LeftArm", "UpperTorso"),
    "LeftLowerArm": ("LeftForeArm", "LeftUpperArm"),
    "LeftHand": ("LeftHand", "LeftLowerArm"),
    "RightUpperArm": ("RightArm", "UpperTorso"),
    "RightLowerArm": ("RightForeArm", "RightUpperArm"),
    "RightHand": ("RightHand", "RightLowerArm"),
    "LeftUpperLeg": ("LeftUpLeg", "LowerTorso"),
    "LeftLowerLeg": ("LeftLeg", "LeftUpperLeg"),
    "LeftFoot": ("LeftFoot", "LeftLowerLeg"),
    "RightUpperLeg": ("RightUpLeg", "LowerTorso"),
    "RightLowerLeg": ("RightLeg", "RightUpperLeg"),
    "RightFoot": ("RightFoot", "RightLowerLeg"),
}
PARTS = list(MAP)  # parents before children
# extra bones needed to measure the rest pose
REQUIRED = sorted({b for b, _ in MAP.values()} | {"LeftToeBase", "RightToeBase", "Neck"})
# limb parts keep their direction: canonical rest is straight down, Motive arms are a T-pose
LIMB_SEGMENTS = {"UpperArm": ("Arm", "ForeArm"), "LowerArm": ("ForeArm", "Hand"), "Hand": ("ForeArm", "Hand"),
                 "UpperLeg": ("UpLeg", "Leg"), "LowerLeg": ("Leg", "Foot")}


# ---- 3x3 rotation helpers (row-major lists of 9) ----
def mm(a, b):
    return [sum(a[r * 3 + k] * b[k * 3 + c] for k in range(3)) for r in range(3) for c in range(3)]


def mt(a):
    return [a[0], a[3], a[6], a[1], a[4], a[7], a[2], a[5], a[8]]


def mv(a, v):
    return [a[0] * v[0] + a[1] * v[1] + a[2] * v[2], a[3] * v[0] + a[4] * v[1] + a[5] * v[2],
            a[6] * v[0] + a[7] * v[1] + a[8] * v[2]]


def rx(d):
    c, s = math.cos(math.radians(d)), math.sin(math.radians(d))
    return [1, 0, 0, 0, c, -s, 0, s, c]


def ry(d):
    c, s = math.cos(math.radians(d)), math.sin(math.radians(d))
    return [c, 0, s, 0, 1, 0, -s, 0, c]


def rz(d):
    c, s = math.cos(math.radians(d)), math.sin(math.radians(d))
    return [c, -s, 0, s, c, 0, 0, 0, 1]


def euler_xyz(v):  # FBX eEulerXYZ: X first, then Y, then Z
    return mm(rz(v[2]), mm(ry(v[1]), rx(v[0])))


I3 = [1, 0, 0, 0, 1, 0, 0, 0, 1]
M = [-1, 0, 0, 0, 1, 0, 0, 0, -1]  # Motive (faces +Z, left +X) -> Roblox (faces -Z, left -X): 180 deg about Y


def conj(r):
    return mm(M, mm(r, M))


def unit(v):
    n = math.sqrt(sum(x * x for x in v))
    return [x / n for x in v]


def align(a, b):
    """Minimal rotation taking direction a onto direction b."""
    a, b = unit(a), unit(b)
    v = [a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]]
    c = sum(x * y for x, y in zip(a, b))
    if c < -1 + 1e-9:  # opposite directions: half turn about an axis perpendicular to a
        axis = unit([a[1], -a[0], 0] if abs(a[2]) < 0.9 else [0, a[2], -a[1]])
        return [2 * axis[r] * axis[c2] - (1 if r == c2 else 0) for r in range(3) for c2 in range(3)]
    k = [0, -v[2], v[1], v[2], 0, -v[0], -v[1], v[0], 0]
    k2 = mm(k, k)
    return [I3[i] + k[i] + k2[i] / (1 + c) for i in range(9)]


def quat(r):
    """Rotation matrix -> quaternion (x, y, z, w), w >= 0."""
    t = r[0] + r[4] + r[8]
    if t > 0:
        s = math.sqrt(t + 1.0) * 2
        q = [(r[7] - r[5]) / s, (r[2] - r[6]) / s, (r[3] - r[1]) / s, 0.25 * s]
    elif r[0] > r[4] and r[0] > r[8]:
        s = math.sqrt(1.0 + r[0] - r[4] - r[8]) * 2
        q = [0.25 * s, (r[1] + r[3]) / s, (r[2] + r[6]) / s, (r[7] - r[5]) / s]
    elif r[4] > r[8]:
        s = math.sqrt(1.0 + r[4] - r[0] - r[8]) * 2
        q = [(r[1] + r[3]) / s, 0.25 * s, (r[5] + r[7]) / s, (r[2] - r[6]) / s]
    else:
        s = math.sqrt(1.0 + r[8] - r[0] - r[4]) * 2
        q = [(r[2] + r[6]) / s, (r[5] + r[7]) / s, 0.25 * s, (r[3] - r[1]) / s]
    if q[3] < 0:
        q = [-x for x in q]
    n = math.sqrt(sum(x * x for x in q))
    return [x / n for x in q]


# ---- skeleton evaluation ----
def resolve_names(skel):
    """Motive may prefix bone names with the skeleton name ("Actor_Hips"): find the prefix, check every bone."""
    candidates = [name[:-4] for name in skel.by_name if name.endswith("Hips")]
    if not candidates:
        raise FbxError("osso Hips non trovato: lo scheletro non e' quello di Motive atteso")
    complete = [p for p in candidates if all(p + b in skel.by_name for b in REQUIRED)]
    if len(complete) > 1:
        raise FbxError("il file contiene piu' scheletri (%s): esporta un attore per file"
                       % ", ".join((p or "senza prefisso") for p in complete))
    if not complete:
        prefix = "" if "" in candidates else candidates[0]
        missing = [b for b in REQUIRED if prefix + b not in skel.by_name]
        raise FbxError("ossa mancanti: %s (lo scheletro non e' quello di Motive atteso)" % ", ".join(missing))
    ids = {b: skel.by_name[complete[0] + b] for b in REQUIRED}
    for uid in ids.values():  # the used bones and every ancestor global_pose walks through
        while uid in skel.models:
            if skel.models[uid].get("unsupported"):
                raise FbxError(skel.models[uid]["unsupported"])
            uid = skel.parent.get(uid)
    return ids


def bone_time_range(skel, ids):
    """First and last key time of the skeleton bones only (markers or rigid bodies may have other ranges)."""
    times = [(c[0][0], c[0][-1]) for uid in ids.values()
             for curves in skel.models[uid]["curves"].values() for c in curves if c is not None]
    if not times:
        raise FbxError("lo scheletro non ha animazione")
    return min(t[0] for t in times), max(t[1] for t in times)


def _sample(curve, t, default, angular=False):
    if curve is None:
        return default
    kt, kv = curve
    if t <= kt[0]:
        return kv[0]
    if t >= kt[-1]:
        return kv[-1]
    lo, hi = 0, len(kt) - 1
    while hi - lo > 1:
        mid = (lo + hi) // 2
        if kt[mid] <= t:
            lo = mid
        else:
            hi = mid
    f = (t - kt[lo]) / (kt[hi] - kt[lo])
    delta = kv[hi] - kv[lo]
    if angular:  # Euler angles in degrees: go the short way across the +-180 wrap
        delta = (delta + 180.0) % 360.0 - 180.0
    return kv[lo] + delta * f


def quat_to_matrix(q):
    x, y, z, w = q
    return [1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w),
            2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w),
            2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y)]


def _slerp(q0, q1, f):
    d = sum(a * b for a, b in zip(q0, q1))
    if d < 0:
        q1, d = [-x for x in q1], -d
    if d > 0.9995:
        q = [a + (b - a) * f for a, b in zip(q0, q1)]
    else:
        th = math.acos(d)
        s0, s1 = math.sin((1 - f) * th) / math.sin(th), math.sin(f * th) / math.sin(th)
        q = [a * s0 + b * s1 for a, b in zip(q0, q1)]
    n = math.sqrt(sum(x * x for x in q))
    return [x / n for x in q]


def _rotation_at(m, t):
    """Local rotation matrix of a bone at time t. Between two keys the rotation is interpolated as a whole
    (slerp): interpolating Euler channels one by one breaks where the Euler angles jump (near gimbal lock)."""
    keys, curves = m.get("r_keys"), m["curves"].get("R")
    if keys is None:
        return euler_xyz([_sample(c, t, d, True) for c, d in zip(curves or [None] * 3, m["R"])])
    if t <= keys[0] or t >= keys[-1]:
        i = 0 if t <= keys[0] else len(keys) - 1
        return euler_xyz([c[1][i] for c in curves])
    lo, hi = 0, len(keys) - 1
    while hi - lo > 1:
        mid = (lo + hi) // 2
        if keys[mid] <= t:
            lo = mid
        else:
            hi = mid
    if t == keys[lo]:
        return euler_xyz([c[1][lo] for c in curves])
    q0 = quat(euler_xyz([c[1][lo] for c in curves]))
    q1 = quat(euler_xyz([c[1][hi] for c in curves]))
    return quat_to_matrix(_slerp(q0, q1, (t - keys[lo]) / (keys[hi] - keys[lo])))


def global_pose(skel, ids, t_ticks):
    """World rotation and position (source axes) of the required bones; t_ticks=None -> rest pose."""
    cache = {}

    def get(uid):
        if uid in cache:
            return cache[uid]
        m = skel.models[uid]
        if t_ticks is None:
            tr, local = m["T"], euler_xyz(m["R"])
        else:
            tr = [_sample(c, t_ticks, d) for c, d in zip(m["curves"].get("T", [None] * 3), m["T"])]
            local = _rotation_at(m, t_ticks)
        pu = skel.parent.get(uid)
        if pu in skel.models:
            pr, pp = get(pu)
            res = (mm(pr, local), [a + b for a, b in zip(pp, mv(pr, tr))])
        else:
            res = (local, list(tr))
        cache[uid] = res
        return res

    return {b: get(uid) for b, uid in ids.items()}


def _dist(a, b):
    return math.sqrt(sum((x - y) ** 2 for x, y in zip(a, b)))


def check_rest(rest):
    """The converter assumes Y up, actor facing +Z and left side on +X in the rest pose."""
    left = rest["LeftUpLeg"][1][0] - rest["RightUpLeg"][1][0]
    toe = rest["LeftToeBase"][1][2] - rest["LeftFoot"][1][2]
    up = rest["Neck"][1][1] - rest["Hips"][1][1]
    if up <= 0:
        raise FbxError("lo scheletro non ha l'asse Y verso l'alto: esporta da Motive con Y up")
    if left <= 0 or toe <= 0:
        raise FbxError("nella posa di riposo l'attore non guarda verso +Z: controlla le impostazioni di export")


def heading(d):
    """Yaw (degrees) of the hips rotation d. Taken from the left-right axis, which stays horizontal when the actor
    starts bent forward or lying down (Crawl, Bridge); the forward axis is the fallback (e.g. lying on a side)."""
    left = mv(d, [-1, 0, 0])
    if math.hypot(left[0], left[2]) > 0.3:
        fwd = [-left[2], 0, left[0]]
    else:
        fwd = mv(d, [0, 0, -1])
    return math.degrees(math.atan2(-fwd[0], -fwd[2]))


def leg_length(rest):
    return _dist(rest["LeftUpLeg"][1], rest["LeftLeg"][1]) + _dist(rest["LeftLeg"][1], rest["LeftFoot"][1])


def _moving_average(xs, win):
    h = win // 2
    out = []
    for i in range(len(xs)):
        seg = xs[max(0, i - h):i + h + 1]
        out.append(sum(seg) / len(seg))
    return out


def convert(skel, name, travel=True):
    """Return the take as a dict ready for JSON (see FORMAT in README)."""
    if skel.up_axis != 1:
        raise FbxError("l'FBX non e' Y up (UpAxis=%s): esporta da Motive con Y up" % skel.up_axis)
    ids = resolve_names(skel)
    rest = global_pose(skel, ids, None)
    check_rest(rest)
    src_leg = leg_length(rest)
    if src_leg <= 0:
        raise FbxError("lunghezza della gamba nulla: scheletro non valido")
    scale = CANON_LEG / src_leg
    # the take may not start at time 0 (timecode, export range): sample from its first key
    start, end = bone_time_range(skel, ids)
    nframes = int(round((end - start) * FPS / TICKS_PER_SECOND)) + 1
    if nframes < 2:
        raise FbxError("la take e' troppo corta")
    # limbs: canonical rest hangs straight down; torso, head and feet map rest to rest
    offs = {}
    for part in PARTS:
        seg = LIMB_SEGMENTS.get(part.replace("Left", "").replace("Right", ""))
        if seg:
            side = "Left" if part.startswith("Left") else "Right"
            d = mv(M, [b - a for a, b in zip(rest[side + seg[0]][1], rest[side + seg[1]][1])])
            offs[part] = align([0, -1, 0], d)
        else:
            offs[part] = I3
    worlds = [global_pose(skel, ids, start + round(f * TICKS_PER_SECOND / FPS)) for f in range(nframes)]
    rest_inv = {b: mt(rest[b][0]) for b in ids}
    yaw_fix = ry(-heading(conj(mm(worlds[0]["Hips"][0], rest_inv["Hips"]))))  # start facing Roblox forward (-Z)
    hips = [mv(yaw_fix, mv(M, w["Hips"][1])) for w in worlds]
    rest_h = mv(M, rest["Hips"][1])
    xs, zs = [h[0] for h in hips], [h[2] for h in hips]
    if travel:
        bx, bz = [xs[0]] * nframes, [zs[0]] * nframes
    else:
        win = max(1, int(SMOOTH_S * FPS))
        bx, bz = _moving_average(xs, win), _moving_average(zs, win)
    frames = []
    for f, w in enumerate(worlds):
        world = {}
        for part in PARTS:
            bone = MAP[part][0]
            world[part] = mm(yaw_fix, mm(conj(mm(w[bone][0], rest_inv[bone])), offs[part]))
        rots = []
        for part in PARTS:
            par = MAP[part][1]
            local = world[part] if par is None else mm(mt(world[par]), world[part])
            rots.append([round(x, 5) for x in quat(local)])
        root = [round((xs[f] - bx[f]) * scale, 4), round((hips[f][1] - rest_h[1]) * scale, 4),
                round((zs[f] - bz[f]) * scale, 4)]
        frames.append({"root": root, "rot": rots})
    return {
        "format": "motive-roblox",
        "version": 1,
        "name": name,
        "fps": FPS,
        "frames": nframes,
        "seconds": round((nframes - 1) / FPS, 3),
        "source_leg": round(src_leg, 3),
        "parts": PARTS,
        "parents": [MAP[p][1] or "HumanoidRootPart" for p in PARTS],
        "root": [x for fr in frames for x in fr["root"]],
        "rot": [x for fr in frames for q in fr["rot"] for x in q],
    }
