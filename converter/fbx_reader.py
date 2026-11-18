"""Minimal reader for binary FBX files exported by OptiTrack Motive: skeleton, rest pose and animation curves."""
import struct
import zlib

TICKS_PER_SECOND = 46186158000


class FbxError(Exception):
    """The file is not a binary FBX this converter can read."""


def _read_nodes(buf, pos, end, wide):
    nodes = []
    head = 24 if wide else 12
    while pos < end:
        if pos + head + 1 > len(buf):
            raise FbxError("file troncato")
        if wide:
            end_off, nprops, plen = struct.unpack_from("<QQQ", buf, pos)
        else:
            end_off, nprops, plen = struct.unpack_from("<III", buf, pos)
        pos += head
        nlen = buf[pos]
        pos += 1
        if end_off == 0:
            break
        if end_off > len(buf) or end_off < pos:
            raise FbxError("struttura FBX non valida")
        name = buf[pos:pos + nlen].decode("latin1")
        pos += nlen
        props, p = [], pos
        for _ in range(nprops):
            t = chr(buf[p])
            p += 1
            if t in "YCIFDL":
                fmt = {"Y": "<h", "C": "<?", "I": "<i", "F": "<f", "D": "<d", "L": "<q"}[t]
                props.append(struct.unpack_from(fmt, buf, p)[0])
                p += struct.calcsize(fmt)
            elif t in "SR":
                ln = struct.unpack_from("<I", buf, p)[0]
                p += 4
                v = buf[p:p + ln]
                p += ln
                props.append(v.decode("utf-8", "replace") if t == "S" else v)
            elif t in "fdlib":
                alen, enc, clen = struct.unpack_from("<III", buf, p)
                p += 12
                raw = buf[p:p + clen]
                p += clen
                if enc == 1:
                    raw = zlib.decompress(raw)
                fmt = {"f": "f", "d": "d", "l": "q", "i": "i", "b": "?"}[t]
                props.append(struct.unpack("<%d%s" % (alen, fmt), raw))
            else:
                raise FbxError("tipo di proprieta' FBX sconosciuto %r" % t)
        pos += plen
        children = _read_nodes(buf, pos, end_off, wide) if pos < end_off else []
        nodes.append((name, props, children))
        pos = end_off
    return nodes


def _find(nodes, name):
    return [n for n in nodes if n[0] == name]


def _props70(node):
    out = {}
    for c in node[2]:
        if c[0] == "Properties70":
            for p in c[2]:
                out[p[1][0]] = p[1][4:]
    return out


class Skeleton:
    """Bones of one take: rest transforms, animation curves and hierarchy."""

    def __init__(self, models, parent, by_name, up_axis):
        self.models = models
        self.parent = parent
        self.by_name = by_name
        self.up_axis = up_axis


def load(path):
    with open(path, "rb") as f:
        buf = f.read()
    if not buf.startswith(b"Kaydara FBX Binary") or len(buf) < 27:
        raise FbxError("non e' un FBX binario (esporta da Motive in formato binario)")
    version = struct.unpack_from("<I", buf, 23)[0]
    try:
        top = _read_nodes(buf, 27, len(buf), version >= 7500)
    except (struct.error, zlib.error, IndexError, ValueError) as e:
        raise FbxError("file FBX danneggiato o incompleto (%s): riesportalo da Motive" % e) from e
    objects = _find(top, "Objects")
    connections = _find(top, "Connections")
    if not objects or not connections:
        raise FbxError("FBX senza oggetti o connessioni")
    up_axis = 1
    gs = _find(top, "GlobalSettings")
    if gs:
        p = _props70(gs[0])
        if "UpAxis" in p:
            up_axis = p["UpAxis"][0] * (p.get("UpAxisSign", [1])[0])
    models, cnodes, curves = {}, {}, {}
    for n in objects[0][2]:
        if n[0] == "Model":
            p = _props70(n)
            name = n[1][1].split("\x00")[0]
            unsupported = None  # checked later, only on the bones the converter uses
            if p.get("RotationOrder", [0])[0] != 0:
                unsupported = "l'osso %s usa un ordine di rotazione non supportato" % name
            pre = list(p.get("PreRotation", [0, 0, 0])) + list(p.get("PostRotation", [0, 0, 0]))
            if any(abs(x) > 1e-6 for x in pre):
                unsupported = "l'osso %s ha Pre/PostRotation, non supportate" % name
            models[n[1][0]] = {"name": name, "kind": n[1][2] if len(n[1]) > 2 else "", "unsupported": unsupported,
                               "T": list(p.get("Lcl Translation", [0, 0, 0])),
                               "R": list(p.get("Lcl Rotation", [0, 0, 0])), "curves": {}}
        elif n[0] == "AnimationCurveNode":
            cnodes[n[1][0]] = {}
        elif n[0] == "AnimationCurve":
            kt = [c for c in n[2] if c[0] == "KeyTime"]
            kv = [c for c in n[2] if c[0] == "KeyValueFloat"]
            if kt and kv and len(kt[0][1][0]) == len(kv[0][1][0]) and kt[0][1][0]:
                curves[n[1][0]] = (kt[0][1][0], kv[0][1][0])
    parent, cn_target = {}, {}
    for c in connections[0][2]:
        if len(c[1]) < 3:
            continue
        kind, child, par = c[1][0], c[1][1], c[1][2]
        if kind == "OO" and child in models and (par in models or par == 0):
            parent[child] = par  # bone hierarchy only: a bone is also linked to skin clusters
        elif kind == "OP" and len(c[1]) > 3 and child in curves and par in cnodes:
            cnodes[par][c[1][3]] = curves[child]
        elif kind == "OP" and len(c[1]) > 3 and child in cnodes and par in models:
            cn_target[child] = (par, c[1][3])
    for cn, (mid, prop) in cn_target.items():
        key = {"Lcl Translation": "T", "Lcl Rotation": "R"}.get(prop)
        if key:
            models[mid]["curves"][key] = [cnodes[cn].get(a) for a in ("d|X", "d|Y", "d|Z")]
    if not curves:
        raise FbxError("l'FBX non contiene animazione")
    by_name = {}  # skeleton bones (LimbNode) win over markers or props with the same name
    for uid, m in sorted(models.items(), key=lambda item: item[1]["kind"] != "LimbNode"):
        by_name.setdefault(m["name"], uid)
    return Skeleton(models, parent, by_name, up_axis)
