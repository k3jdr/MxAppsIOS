//
//  CADFreeCADLibrary.swift
//  MxNoteONE
//
//  The Python FreeCAD runs for MxNoteONE (see CADFreeCAD): it builds FreeCAD documents from models, exports them,
//  and reads FreeCAD, STEP, IGES and BREP files back as triangles.
//

enum CADFreeCADLibrary {
    static let source = #"""
# MxNoteONE <-> FreeCAD.
#
# Run by FreeCAD (freecadcmd, or FreeCAD itself with no window) for MxNoteONE: builds a FreeCAD document from an
# MxNoteONE 3D model -- Part workbench objects with their dimensions bound to a "Parameters" spreadsheet, sketches
# (Sketcher) with their constraints -- saves it and exports it (STEP, IGES, BREP); and reads FreeCAD, STEP, IGES and
# BREP files back as triangles, face by face. Each job is a folder with job.json; the answer is result.json.

import json
import math
import os
import re
import struct
import sys
import traceback

import FreeCAD as App
import Part
from FreeCAD import Matrix, Placement, Rotation, Vector

try:
    import FreeCADGui as Gui  # noqa: F401
    GUI = bool(App.GuiUp)
except Exception:
    GUI = False

LOG = []


def log(*parts):
    LOG.append(" ".join(str(p) for p in parts))


def vec(p):
    return Vector(float(p[0]), float(p[1]), float(p[2]))


def is_number(text):
    try:
        float(str(text).strip())
        return True
    except ValueError:
        return False


FUNCTIONS = {"sin", "cos", "tan", "sqrt", "abs", "min", "max", "round", "pi"}
UNITS = {"mm", "cm", "m", "in"}


class Builder:
    def __init__(self, job, doc):
        self.job = job
        self.model = job["model"]
        self.resolved = job.get("resolved", {})
        self.doc = doc
        self.features = {f["id"]: f for f in self.model.get("features", [])}
        self.objects = {}      # feature id -> the FreeCAD object that is its result
        self.tools = {}        # feature id -> what a Part Design feature adds or cuts
        self.sketches = {}     # feature id -> its Sketcher object
        self.helpers = []      # objects that are parts of others (hidden)
        self.alias = {}
        self.sheet = None
        self.colors = {}

    # Expressions -------------------------------------------------------------------------------------------------

    def translate(self, text, in_sheet=False):
        """An MxNoteONE expression as a FreeCAD one: parameters from the spreadsheet, commas between arguments as ;."""
        s = str(text).replace("×", "*").replace("÷", "/").replace("−", "-")

        def name(m):
            word = m.group(1)
            if word in self.alias:
                return self.alias[word] if in_sheet else "Parameters." + self.alias[word]
            return word
        s = re.sub(r"(?<![\w.])([A-Za-z_]\w*)", name, s)
        return s.replace(",", ";")

    def bind(self, obj, prop, text, value):
        """A property set to its value -- and, when it's an expression of the parameters, bound to it."""
        try:
            setattr(obj, prop, value)
        except Exception as e:
            log("couldn't set", obj.Name, prop, e)
        if text is not None and not is_number(text):
            try:
                obj.setExpression(prop, self.translate(text))
            except Exception as e:
                log("couldn't bind", obj.Name, prop, text, e)

    def resolved_feature(self, f):
        return self.resolved.get("features", {}).get(f["id"], {})

    def number(self, f, key, default=0.0):
        r = self.resolved_feature(f).get("values", {})
        return float(r.get(key, default))

    def text(self, f, key):
        return f.get("values", {}).get(key)

    # Parameters --------------------------------------------------------------------------------------------------

    def parameters(self):
        params = self.model.get("parameters", [])
        if not params:
            return
        sheet = self.doc.addObject("Spreadsheet::Sheet", "Parameters")
        self.sheet = sheet
        for i, p in enumerate(params):
            row = i + 1
            sheet.set("A%d" % row, str(p["name"]))
            alias = p["name"]
            for candidate in (alias, "p_" + alias, "param%d" % row):
                try:
                    sheet.setAlias("B%d" % row, candidate)
                    alias = candidate
                    break
                except Exception:
                    continue
            self.alias[p["name"]] = alias
        for i, p in enumerate(params):
            expr = p["expression"]
            sheet.set("B%d" % (i + 1), str(expr) if is_number(expr) else "=" + self.translate(expr, in_sheet=True))
        self.doc.recompute()

    # Placement ---------------------------------------------------------------------------------------------------

    def placement(self, obj, f, centre=(0, 0, 0), turn=(0, 0, 0)):
        """The feature's placement (a move, then turns about X, Y, Z) after a fixed one that puts FreeCAD's
        primitive where MxNoteONE has it (centred on the Z axis, standing on Z = 0)."""
        p = f.get("placement", {})
        keys = ["x", "y", "z", "rx", "ry", "rz"]
        texts = [p.get(k, "0") for k in keys]
        nums = self.resolved_feature(f).get("placement", [0, 0, 0, 0, 0, 0])
        inner = Placement(vec(centre), Rotation(turn[2], turn[1], turn[0]))
        outer = Placement(Vector(nums[0], nums[1], nums[2]), Rotation(nums[5], nums[4], nums[3]))
        obj.Placement = outer.multiply(inner)
        cexpr = [str(c) for c in centre]
        if any(not is_number(t) for t in texts) or any(not is_number(c) for c in cexpr):
            t = [self.translate(x) for x in texts]
            c = [self.translate(x) for x in cexpr]
            expr = ("create(<<placement>>; create(<<vector>>; %s; %s; %s); create(<<rotation>>; %s; %s; %s)) * "
                    "create(<<placement>>; create(<<vector>>; %s; %s; %s); create(<<rotation>>; %s; %s; %s))") % (
                t[0], t[1], t[2], t[5], t[4], t[3], c[0], c[1], c[2], turn[2], turn[1], turn[0])
            try:
                obj.setExpression("Placement", expr)
            except Exception as e:
                log("couldn't bind placement", obj.Name, e)

    def centre_text(self, f, key, scale):
        """-width / 2 and the like, as an expression when it's one."""
        t = self.text(f, key)
        v = self.number(f, key)
        if t is not None and not is_number(t):
            return "(%s) * %s" % (t, scale)
        return v * scale

    # Sketches ----------------------------------------------------------------------------------------------------

    def sketch_object(self, f):
        import Sketcher
        sk = f["sketch"]
        r = self.resolved_feature(f).get("sketch", {})
        obj = self.doc.addObject("Sketcher::SketchObject", "Sketch")
        obj.Label = f["name"]
        u, v, n, o = vec(r["u"]), vec(r["v"]), vec(r["n"]), vec(r["origin"])
        m = Matrix(u.x, v.x, n.x, 0, u.y, v.y, n.y, 0, u.z, v.z, n.z, 0, 0, 0, 0, 1)
        obj.Placement = Placement(o + n * float(r.get("offset", 0)), Rotation(m))
        points = {}   # (entity, part) -> (geo, pos)
        edges = {}    # (entity, edge) -> geo
        centres = {}  # entity -> (geo, pos) for rectangle/polygon centres made on request
        refs_used = set()
        for c in sk.get("constraints", []) or []:
            for rr in c.get("refs", []):
                refs_used.add((rr["entity"], rr["part"]))
        tangent_pairs = set()
        for c in sk.get("constraints", []) or []:
            if c["kind"] == "tangent" and c.get("mode") == 1:
                a, b = c["refs"][0], c["refs"][1]
                tangent_pairs.add(frozenset([(a["entity"], a["part"]), (b["entity"], b["part"])]))

        def P(q):
            return Vector(float(q[0]), float(q[1]), 0)

        for e in sk.get("entities", []):
            kind = e["kind"]
            pts = e["points"]
            constr = bool(e.get("construction")) or kind == "point"
            eid = e["id"]
            if kind == "point":
                g = obj.addGeometry(Part.Point(P(pts[0])), True)
                points[(eid, 0)] = (g, 1)
            elif kind == "line":
                g = obj.addGeometry(Part.LineSegment(P(pts[0]), P(pts[1])), constr)
                points[(eid, 0)] = (g, 1)
                points[(eid, 1)] = (g, 2)
                edges[(eid, 0)] = g
            elif kind == "arc":
                arc = Part.ArcOfCircle(P(pts[0]), P(pts[2]), P(pts[1]))
                g = obj.addGeometry(arc, constr)
                geo = obj.Geometry[g]
                same = (geo.StartPoint - P(pts[0])).Length < 1e-6
                points[(eid, 0)] = (g, 1 if same else 2)
                points[(eid, 1)] = (g, 2 if same else 1)
                points[(eid, -1)] = (g, 3)
                edges[(eid, 0)] = g
            elif kind == "circle":
                rad = math.hypot(pts[1][0] - pts[0][0], pts[1][1] - pts[0][1])
                g = obj.addGeometry(Part.Circle(P(pts[0]), Vector(0, 0, 1), rad), constr)
                points[(eid, -1)] = (g, 3)
                edges[(eid, 0)] = g
            elif kind in ("rectangle", "polygon"):
                if kind == "rectangle":
                    a, b = pts[0], pts[1]
                    corners = [a, [b[0], a[1]], b, [a[0], b[1]]]
                else:
                    count = max(3, int(e.get("sides") or 6))
                    cx, cy = pts[0]
                    vx, vy = pts[1][0] - cx, pts[1][1] - cy
                    corners = []
                    for k in range(count):
                        t = 2 * math.pi * k / count
                        corners.append([cx + vx * math.cos(t) - vy * math.sin(t), cy + vx * math.sin(t) + vy * math.cos(t)])
                count = len(corners)
                first = None
                for k in range(count):
                    g = obj.addGeometry(Part.LineSegment(P(corners[k]), P(corners[(k + 1) % count])), constr)
                    first = g if first is None else first
                    points[(eid, k)] = (g, 1)
                    edges[(eid, k)] = g
                for k in range(count):
                    obj.addConstraint(Sketcher.Constraint("Coincident", first + k, 2, first + (k + 1) % count, 1))
                if kind == "rectangle":
                    for k in range(4):
                        obj.addConstraint(Sketcher.Constraint("Horizontal" if k % 2 == 0 else "Vertical", first + k))
                    if (eid, -1) in refs_used:
                        c = obj.addGeometry(Part.Point(P([(a[0] + b[0]) / 2, (a[1] + b[1]) / 2])), True)
                        obj.addConstraint(Sketcher.Constraint("Symmetric", first, 1, first + 2, 1, c, 1))
                        centres[eid] = (c, 1)
                else:
                    rad = math.hypot(vx, vy)
                    circle = obj.addGeometry(Part.Circle(P(pts[0]), Vector(0, 0, 1), rad), True)
                    for k in range(count):
                        obj.addConstraint(Sketcher.Constraint("PointOnObject", first + k, 1, circle))
                        if k > 0:
                            obj.addConstraint(Sketcher.Constraint("Equal", first, first + k))
                    centres[eid] = (circle, 3)
                if eid in centres:
                    points[(eid, -1)] = centres[eid]

        def pt(rr):
            if rr["entity"] == "00000000-0000-0000-0000-000000000000":
                return (-1, 1)
            return points.get((rr["entity"], rr["part"]))

        def ed(rr):
            if rr["entity"] == "00000000-0000-0000-0000-000000000000":
                return -1 if rr["part"] == 1000 else -2
            return edges.get((rr["entity"], rr["part"] - 1000))

        values = self.resolved_feature(f).get("constraints", {})
        for c in sk.get("constraints", []) or []:
            kind = c["kind"]
            refs = c.get("refs", [])
            value = values.get(c["id"])
            made = []
            try:
                if kind == "coincident":
                    if frozenset([(refs[0]["entity"], refs[0]["part"]), (refs[1]["entity"], refs[1]["part"])]) in tangent_pairs:
                        continue  # FreeCAD's end-to-end tangency joins the points itself
                    a, b = pt(refs[0]), pt(refs[1])
                    made.append(Sketcher.Constraint("Coincident", a[0], a[1], b[0], b[1]))
                elif kind == "pointOnObject":
                    a = pt(refs[0])
                    made.append(Sketcher.Constraint("PointOnObject", a[0], a[1], ed(refs[1])))
                elif kind in ("horizontal", "vertical"):
                    name = "Horizontal" if kind == "horizontal" else "Vertical"
                    if len(refs) == 1:
                        made.append(Sketcher.Constraint(name, ed(refs[0])))
                    else:
                        a, b = pt(refs[0]), pt(refs[1])
                        made.append(Sketcher.Constraint(name, a[0], a[1], b[0], b[1]))
                elif kind in ("parallel", "perpendicular", "equal"):
                    made.append(Sketcher.Constraint(kind.capitalize(), ed(refs[0]), ed(refs[1])))
                elif kind == "tangent":
                    if c.get("mode") == 1:
                        a, b = pt(refs[0]), pt(refs[1])
                        made.append(Sketcher.Constraint("Tangent", a[0], a[1], b[0], b[1]))
                    else:
                        made.append(Sketcher.Constraint("Tangent", ed(refs[0]), ed(refs[1])))
                elif kind == "symmetric":
                    a, b = pt(refs[0]), pt(refs[1])
                    if refs[2]["part"] >= 1000:
                        made.append(Sketcher.Constraint("Symmetric", a[0], a[1], b[0], b[1], ed(refs[2])))
                    else:
                        o = pt(refs[2])
                        made.append(Sketcher.Constraint("Symmetric", a[0], a[1], b[0], b[1], o[0], o[1]))
                elif kind == "lock":
                    a = pt(refs[0])
                    made.append(Sketcher.Constraint("DistanceX", a[0], a[1], float(value[0])))
                    made.append(Sketcher.Constraint("DistanceY", a[0], a[1], float(value[1])))
                elif kind == "block":
                    for (eid, part), g in edges.items():
                        if eid == refs[0]["entity"]:
                            made.append(Sketcher.Constraint("Block", g))
                elif kind in ("distanceX", "distanceY"):
                    name = "DistanceX" if kind == "distanceX" else "DistanceY"
                    if len(refs) == 2:
                        a, b = pt(refs[0]), pt(refs[1])
                        made.append(Sketcher.Constraint(name, a[0], a[1], b[0], b[1], float(value)))
                    elif refs[0]["part"] >= 1000:
                        g = ed(refs[0])
                        made.append(Sketcher.Constraint(name, g, 1, g, 2, float(value)))
                    else:
                        a = pt(refs[0])
                        made.append(Sketcher.Constraint(name, a[0], a[1], float(value)))
                elif kind == "distance":
                    if len(refs) == 2 and refs[1]["part"] >= 1000:
                        a = pt(refs[0])
                        made.append(Sketcher.Constraint("Distance", a[0], a[1], ed(refs[1]), float(value)))
                    elif len(refs) == 2:
                        a, b = pt(refs[0]), pt(refs[1])
                        made.append(Sketcher.Constraint("Distance", a[0], a[1], b[0], b[1], float(value)))
                    else:
                        made.append(Sketcher.Constraint("Distance", ed(refs[0]), float(value)))
                elif kind in ("radius", "diameter"):
                    made.append(Sketcher.Constraint(kind.capitalize(), ed(refs[0]), float(value)))
                elif kind == "angle":
                    if len(refs) == 2:
                        made.append(Sketcher.Constraint("Angle", ed(refs[0]), ed(refs[1]), math.radians(float(value))))
                    else:
                        made.append(Sketcher.Constraint("Angle", ed(refs[0]), math.radians(float(value))))
            except Exception as e:
                log("couldn't map constraint", kind, e)
                continue
            for m in made:
                try:
                    index = obj.addConstraint(m)
                except Exception as e:
                    log("FreeCAD refused constraint", kind, e)
                    continue
                expr = c.get("value")
                if kind in ("distanceX", "distanceY", "distance", "radius", "diameter", "angle") and expr is not None and not is_number(expr):
                    try:
                        obj.setExpression("Constraints[%d]" % index, self.translate(expr) + (" * 1 deg" if kind == "angle" else ""))
                    except Exception as e:
                        log("couldn't bind dimension", e)
        self.sketches[f["id"]] = obj
        return obj

    def sketch_of(self, f):
        """A feature's sketch object: its profile's, or (older models) its own."""
        if f.get("profile") and f["profile"] in self.sketches:
            return self.sketches[f["profile"]]
        if f.get("sketch") is not None:
            helper = dict(f)
            helper["name"] = f["name"] + " Sketch"
            obj = self.sketch_object(helper)
            self.helpers.append(obj)
            return obj
        raise ValueError("no sketch")

    # Features ----------------------------------------------------------------------------------------------------

    def primitive(self, f):
        kind = f["kind"]
        n = lambda k: self.number(f, k)  # noqa: E731
        t = lambda k: self.text(f, k)    # noqa: E731
        if kind == "box":
            o = self.doc.addObject("Part::Box", "Box")
            self.bind(o, "Length", t("width"), n("width"))
            self.bind(o, "Width", t("depth"), n("depth"))
            self.bind(o, "Height", t("height"), n("height"))
            self.placement(o, f, centre=(self.centre_text(f, "width", -0.5), self.centre_text(f, "depth", -0.5), 0))
            if n("radius") > 1e-9:
                self.doc.recompute()
                fil = self.doc.addObject("Part::Fillet", "Fillet")
                fil.Base = o
                fil.Edges = [(i + 1, n("radius"), n("radius")) for i in range(len(o.Shape.Edges))]
                self.helpers.append(o)
                return fil
            return o
        if kind == "cylinder":
            o = self.doc.addObject("Part::Cylinder", "Cylinder")
            self.bind(o, "Radius", t("radius"), n("radius"))
            self.bind(o, "Height", t("height"), n("height"))
        elif kind == "cone":
            o = self.doc.addObject("Part::Cone", "Cone")
            self.bind(o, "Radius1", t("bottom"), n("bottom"))
            self.bind(o, "Radius2", t("top"), n("top"))
            self.bind(o, "Height", t("height"), n("height"))
        elif kind == "sphere":
            o = self.doc.addObject("Part::Sphere", "Sphere")
            self.bind(o, "Radius", t("radius"), n("radius"))
            self.placement(o, f, centre=(0, 0, self.centre_text(f, "radius", 1)))
            return o
        elif kind == "torus":
            o = self.doc.addObject("Part::Torus", "Torus")
            self.bind(o, "Radius1", t("major"), n("major"))
            self.bind(o, "Radius2", t("minor"), n("minor"))
            self.placement(o, f, centre=(0, 0, self.centre_text(f, "minor", 1)))
            return o
        elif kind == "wedge":
            o = self.doc.addObject("Part::Wedge", "Wedge")
            w, d, h = n("width"), n("depth"), n("height")
            o.Xmin, o.Xmax, o.Ymin, o.Ymax, o.Zmin, o.Zmax = -w / 2, w / 2, 0, h, -d / 2, d / 2
            o.X2min, o.X2max, o.Z2min, o.Z2max = -w / 2, -w / 2, -d / 2, d / 2
            self.placement(o, f, turn=(90, 0, 0))
            return o
        elif kind == "prism":
            o = self.doc.addObject("Part::Prism", "Prism")
            self.bind(o, "Polygon", t("sides"), int(round(n("sides"))))
            self.bind(o, "Circumradius", t("radius"), n("radius"))
            self.bind(o, "Height", t("height"), n("height"))
            self.placement(o, f, turn=(0, 0, 90))
            return o
        elif kind == "tube":
            o = self.doc.addObject("Part::Tube", "Tube")
            self.bind(o, "OuterRadius", t("outer"), n("outer"))
            self.bind(o, "InnerRadius", t("inner"), n("inner"))
            self.bind(o, "Height", t("height"), n("height"))
        elif kind == "ellipsoid":
            o = self.doc.addObject("Part::Ellipsoid", "Ellipsoid")
            self.bind(o, "Radius1", t("rz"), n("rz"))
            self.bind(o, "Radius2", t("rx"), n("rx"))
            self.bind(o, "Radius3", t("ry"), n("ry"))
            self.placement(o, f, centre=(0, 0, self.centre_text(f, "rz", 1)))
            return o
        else:
            raise ValueError("unknown primitive " + kind)
        self.placement(o, f)
        return o

    def extrusion(self, f, sketch):
        r = self.resolved_feature(f)
        o = self.doc.addObject("Part::Extrusion", "Extrude")
        o.Base = sketch
        o.DirMode = "Normal"
        o.Solid = True
        kind = f.get("values", {}).get("type", "Length")
        reversed_ = (f.get("values", {}).get("reversed", "No") == "Yes") != (f.get("operation") == "subtract")
        o.Reversed = reversed_
        if kind == "Through All":
            o.LengthFwd = float(r.get("throughAll", 1000))
        else:
            self.bind(o, "LengthFwd", self.text(f, "distance"), self.number(f, "distance"))
        if kind == "Two Lengths":
            self.bind(o, "LengthRev", self.text(f, "distance2"), self.number(f, "distance2"))
        if kind == "Symmetric":
            o.Symmetric = True
        return o

    def revolution(self, f, sketch):
        r = self.resolved_feature(f)
        o = self.doc.addObject("Part::Revolution", "Revolve")
        o.Source = sketch
        o.Base = vec(r["axis"]["base"])
        o.Axis = vec(r["axis"]["dir"])
        self.bind(o, "Angle", self.text(f, "angle"), self.number(f, "angle"))
        o.Symmetric = f.get("values", {}).get("symmetric", "No") == "Yes"
        o.Solid = True
        return o

    def loft(self, f):
        sections = [self.sketches[s] for s in [f.get("profile")] + (f.get("sections") or []) if s in self.sketches]
        o = self.doc.addObject("Part::Loft", "Loft")
        o.Sections = sections
        o.Solid = True
        o.Ruled = f.get("values", {}).get("ruled", "No") == "Yes"
        return o

    def sweep(self, f):
        profile = self.sketches[f["profile"]]
        path = self.sketches[(f.get("sections") or [None])[0]]
        o = self.doc.addObject("Part::Sweep", "Sweep")
        o.Sections = [profile]
        self.doc.recompute()
        o.Spine = (path, ["Edge%d" % (i + 1) for i in range(len(path.Shape.Edges))])
        o.Solid = True
        o.Frenet = False
        return o

    def helix(self, f, sketch):
        r = self.resolved_feature(f)
        self.doc.recompute()
        pitch, height = self.number(f, "pitch"), self.number(f, "height")
        left = f.get("values", {}).get("hand", "Right-handed") == "Left-handed"
        axis = r["axis"]
        h = self.doc.addObject("Part::Helix", "HelixPath")
        h.Pitch = pitch
        h.Height = height
        h.Radius = float(axis["radius"])
        h.LocalCoord = 1 if left else 0
        x, y, z = vec(axis["u"]), vec(axis["dir"]) * -1, vec(axis["dir"])
        y = z.cross(x)
        m = Matrix(x.x, y.x, z.x, 0, x.y, y.y, z.y, 0, x.z, y.z, z.z, 0, 0, 0, 0, 1)
        h.Placement = Placement(vec(axis["base"]), Rotation(m))
        self.helpers.append(h)
        o = self.doc.addObject("Part::Sweep", "Helix")
        o.Sections = [sketch]
        o.Spine = (h, [])
        o.Solid = True
        o.Frenet = True
        return o

    def hole_tool(self, f):
        r = self.resolved_feature(f)
        d = vec(r["holeAxis"])
        shapes = []
        lift = 0.01
        for h in r.get("holes", []):
            c, rad, depth = vec(h["centre"]), float(h["radius"]), float(h["depth"])
            start = c - d * lift
            s = Part.makeCylinder(rad, depth + lift, start, d)
            if h.get("tip", 0) > 0:
                s = s.fuse(Part.makeCone(rad, 0, float(h["tip"]), c + d * depth, d))
            if h.get("bore", 0) > 0:
                s = s.fuse(Part.makeCylinder(float(h["boreRadius"]), float(h["bore"]) + lift, start, d))
            if h.get("sink", 0) > 0:
                t = float(h["sinkTan"])
                s = s.fuse(Part.makeCone(float(h["boreRadius"]) + lift * t, rad, float(h["sink"]) + lift, start, d))
            shapes.append(s)
        tool = shapes[0]
        for s in shapes[1:]:
            tool = tool.fuse(s)
        o = self.doc.addObject("Part::Feature", "HoleTool")
        o.Shape = tool
        return o

    def dress_up(self, f, base):
        r = self.resolved_feature(f)
        self.doc.recompute()
        shape = base.Shape
        size = self.number(f, "radius" if f["kind"] == "fillet" else "size")
        tol = max(0.02, shape.BoundBox.DiagonalLength * 2e-4)
        picked = []
        for polyline in r.get("edges", []):
            samples = polyline if len(polyline) <= 9 else [polyline[int(i * (len(polyline) - 1) / 8)] for i in range(9)]
            for i, edge in enumerate(shape.Edges):
                if i + 1 in picked:
                    continue
                if all(edge.distToShape(Part.Vertex(vec(q)))[0] < tol for q in samples):
                    picked.append(i + 1)
        if not picked:
            log("no FreeCAD edges matched", f["name"])
        o = self.doc.addObject("Part::Fillet" if f["kind"] == "fillet" else "Part::Chamfer", f["kind"].capitalize())
        o.Base = base
        o.Edges = [(i, size, size) for i in picked]
        return o

    def combined(self, op, base, tool, name):
        kind = {"add": "Part::Fuse", "subtract": "Part::Cut", "intersect": "Part::Common"}[op]
        o = self.doc.addObject(kind, name)
        o.Base = base
        o.Tool = tool
        try:
            o.Refine = True
        except Exception:
            pass
        self.helpers.append(tool)
        return o

    def boolean(self, f):
        ins = [self.objects[i] for i in f.get("inputs", []) if i in self.objects]
        if len(ins) < 2:
            raise ValueError("needs two bodies")
        kind = f["kind"]
        if kind == "union":
            o = self.doc.addObject("Part::MultiFuse", "Fusion")
            o.Shapes = ins
        elif kind == "intersect":
            o = self.doc.addObject("Part::MultiCommon", "Common")
            o.Shapes = ins
        else:
            tool = ins[1]
            if len(ins) > 2:
                tool = self.doc.addObject("Part::MultiFuse", "Tools")
                tool.Shapes = ins[1:]
                self.helpers.append(tool)
            o = self.doc.addObject("Part::Cut", "Cut")
            o.Base = ins[0]
            o.Tool = tool
        try:
            o.Refine = True
        except Exception:
            pass
        return o

    def pattern(self, f):
        import Draft
        source_id = (f.get("inputs") or [None])[0]
        source = self.features.get(source_id)
        op = source.get("operation") if source else None
        if source and source["kind"] == "hole":
            op = "subtract"
        what = self.tools.get(source_id) if op else None
        target = what if what is not None else self.objects[source_id]
        kind = f["kind"]
        self.doc.recompute()
        if kind == "mirror":
            plane = f.get("values", {}).get("plane", "YZ")
            normal = {"YZ": Vector(1, 0, 0), "XZ": Vector(0, 1, 0), "XY": Vector(0, 0, 1)}[plane]
            m = self.doc.addObject("Part::Mirroring", "Mirror")
            m.Source = target
            m.Normal = normal
            m.Base = Vector(0, 0, 0)
            copies = m
        else:
            count = max(1, int(round(self.number(f, "count", 1))))
            if kind == "linearPattern":
                step = Vector(self.number(f, "dx"), self.number(f, "dy"), self.number(f, "dz"))
                copies = Draft.make_ortho_array(target, v_x=step, v_y=Vector(0, 1000, 0), v_z=Vector(0, 0, 1000), n_x=count, n_y=1, n_z=1, use_link=False)
                for prop, key in (("NumberX", "count"), ("IntervalX.x", "dx"), ("IntervalX.y", "dy"), ("IntervalX.z", "dz")):
                    t = self.text(f, key)
                    if t is not None and not is_number(t):
                        try:
                            copies.setExpression(prop, self.translate(t))
                        except Exception as e:
                            log("couldn't bind", prop, e)
            else:
                copies = Draft.make_polar_array(target, number=count, angle=self.number(f, "angle", 360), center=Vector(0, 0, 0), use_link=False)
                for prop, key in (("NumberPolar", "count"), ("Angle", "angle")):
                    t = self.text(f, key)
                    if t is not None and not is_number(t):
                        try:
                            copies.setExpression(prop, self.translate(t))
                        except Exception as e:
                            log("couldn't bind", prop, e)
            try:
                copies.Fuse = True
            except Exception:
                pass
        if what is not None:
            # A Part Design feature repeated on its body.
            return self.combined(op, self.objects[source_id], copies, f["kind"])
        if kind == "mirror":
            fuse = self.doc.addObject("Part::MultiFuse", "Mirrored")
            fuse.Shapes = [self.objects[source_id], copies]
            self.helpers.append(copies)
            return fuse
        return copies

    def mesh(self, f):
        r = self.resolved_feature(f)
        src = r.get("source")
        if src and os.path.exists(src.get("file", "")):
            try:
                shape = read_object_shape(src["file"], src.get("object"))
                if shape is not None:
                    o = self.doc.addObject("Part::Feature", "Shape")
                    o.Shape = shape
                    return o
            except Exception as e:
                log("couldn't read the source", e)
        import Mesh
        data = r.get("triangles")
        if not data:
            raise ValueError("empty mesh")
        tris = []
        for i in range(0, len(data) - 8, 9):
            tris.append([Vector(data[i], data[i + 1], data[i + 2]), Vector(data[i + 3], data[i + 4], data[i + 5]), Vector(data[i + 6], data[i + 7], data[i + 8])])
        mesh = Mesh.Mesh(tris)
        shape = Part.Shape()
        shape.makeShapeFromMesh(mesh.Topology, 0.05)
        try:
            shape = Part.Solid(Part.Shell(shape.Faces))
        except Exception:
            pass
        o = self.doc.addObject("Part::Feature", "Mesh")
        o.Shape = shape
        return o

    def feature(self, f):
        kind = f["kind"]
        op = f.get("operation")
        if kind == "sketch":
            self.sketch_object(f)
            return None
        if kind in ("box", "cylinder", "cone", "sphere", "torus", "wedge", "prism", "tube", "ellipsoid"):
            obj = self.primitive(f)
        elif kind == "extrude":
            obj = self.extrusion(f, self.sketch_of(f))
        elif kind == "revolve":
            obj = self.revolution(f, self.sketch_of(f))
        elif kind == "loft":
            obj = self.loft(f)
        elif kind == "pipe":
            obj = self.sweep(f)
        elif kind == "helix":
            obj = self.helix(f, self.sketch_of(f))
        elif kind == "hole":
            tool = self.hole_tool(f)
            self.tools[f["id"]] = tool
            return self.combined("subtract", self.objects[f["inputs"][0]], tool, "Hole")
        elif kind in ("fillet", "chamfer"):
            return self.dress_up(f, self.objects[f["inputs"][0]])
        elif kind in ("union", "subtract", "intersect"):
            return self.boolean(f)
        elif kind in ("linearPattern", "circularPattern", "mirror"):
            return self.pattern(f)
        elif kind == "mesh":
            obj = self.mesh(f)
            self.placement(obj, f)
        else:
            raise ValueError("unknown kind " + kind)
        if kind in ("extrude", "revolve") and any(abs(x) > 1e-12 for x in self.resolved_feature(f).get("placement", [0] * 6)):
            self.placement(obj, f)
        if op:
            self.tools[f["id"]] = obj
            base = (f.get("inputs") or [None])[0]
            if base in self.objects:
                return self.combined(op, self.objects[base], obj, {"add": "Pad", "subtract": "Pocket", "intersect": "Common"}[op] if kind == "extrude" else kind.capitalize())
        return obj

    def build(self):
        self.parameters()
        consumed = set()
        for f in self.model.get("features", []):
            for i in (f.get("inputs") or []) + ([f["profile"]] if f.get("profile") else []) + (f.get("sections") or []):
                consumed.add(i)
        for f in self.model.get("features", []):
            try:
                obj = self.feature(f)
            except Exception as e:
                log("couldn't make", f.get("name"), repr(e))
                traceback.print_exc()
                continue
            if obj is None:
                continue
            obj.Label = f["name"]
            self.objects[f["id"]] = obj
            c = f.get("color")
            if c:
                self.colors[obj.Name] = (c["r"], c["g"], c["b"])
        self.doc.recompute()
        # What shows: the results not used by a later feature (as FreeCAD hides a Cut's base and tool).
        shown = []
        for f in self.model.get("features", []):
            obj = self.objects.get(f["id"])
            if obj is None:
                continue
            visible = f["id"] not in consumed and not f.get("hidden")
            set_visible(obj, visible)
            if visible:
                shown.append((f, obj))
        for obj in self.helpers:
            set_visible(obj, False)
        for sk_id, sk in self.sketches.items():
            set_visible(sk, sk_id not in consumed and not self.features[sk_id].get("hidden"))
        if GUI:
            for name, rgb in self.colors.items():
                try:
                    o = self.doc.getObject(name)
                    o.ViewObject.ShapeColor = rgb
                    o.ViewObject.DisplayMode = "Flat Lines"
                except Exception as e:
                    log("couldn't colour", name, e)
        return shown


def set_visible(obj, visible):
    try:
        obj.Visibility = visible
    except Exception:
        pass
    if GUI:
        try:
            obj.ViewObject.Visibility = visible
        except Exception:
            pass


def read_object_shape(path, name):
    ext = os.path.splitext(path)[1].lower()
    if ext == ".fcstd":
        try:
            doc = App.openDocument(path, hidden=True)
        except TypeError:
            doc = App.openDocument(path)
        try:
            obj = doc.getObject(name) if name else None
            if obj is None:
                return None
            return Part.getShape(obj, "", needSubElement=False, transform=True).copy()
        finally:
            App.closeDocument(doc.Name)
    shape = Part.read(path)
    if name and name.startswith("Solid") and name[5:].isdigit():
        i = int(name[5:]) - 1
        solids = shape.Solids
        if 0 <= i < len(solids):
            return solids[i]
    return shape


# Jobs ----------------------------------------------------------------------------------------------------------------

def document(job, folder):
    name = re.sub(r"[^A-Za-z0-9_]", "_", job["model"].get("name") or "Model") or "Model"
    doc = App.newDocument(name)
    builder = Builder(job, doc)
    shown = builder.build()
    doc.recompute()
    out = job.get("output", {})
    result = {"objects": []}
    for f, obj in shown:
        try:
            shape = obj.Shape
            result["objects"].append({"id": f["id"], "name": obj.Name, "label": obj.Label, "valid": shape.isValid(), "volume": shape.Volume, "area": shape.Area})
        except Exception as e:
            result["objects"].append({"id": f["id"], "name": obj.Name, "error": repr(e)})
    result["sketches"] = []
    for sk in builder.sketches.values():
        try:
            code = sk.solve()
        except Exception:
            code = -99
        result["sketches"].append({"label": sk.Label, "constraints": len(sk.Constraints), "solve": code})
    result["expressions"] = sum(len(o.ExpressionEngine) for o in doc.Objects if hasattr(o, "ExpressionEngine"))
    if out.get("fcstd"):
        doc.saveAs(out["fcstd"])
    objs = [obj for _, obj in shown]
    for key in ("step", "iges"):
        if out.get(key):
            if GUI:
                import ImportGui
                ImportGui.export(objs, out[key])
            else:
                import Import
                Import.export(objs, out[key])
    if out.get("brep"):
        shapes = [o.Shape for o in objs]
        Part.makeCompound(shapes).exportBrep(out["brep"])
    return result


def visible(obj):
    """The document's own visibility (what FreeCAD saves for every object, with or without its window's layer)."""
    if hasattr(obj, "Visibility") and not obj.Visibility:
        return False
    for parent in obj.InList:
        if parent.isDerivedFrom("App::Part") and not visible(parent):
            return False
    return True


def color_of(obj):
    if not GUI:
        return None
    try:
        c = obj.ViewObject.ShapeColor
        return [c[0], c[1], c[2]]
    except Exception:
        return None


def shapes_in(doc):
    """The solids showing: each visible object with faces (a Part Design body's tip, not its features; an App::Part's
    children, not the part). With nothing marked visible, the results nothing else uses."""
    def candidates(check_visible):
        out = []
        for obj in doc.Objects:
            if obj.TypeId in ("App::Part", "App::DocumentObjectGroup", "App::Origin", "App::Line", "App::Plane") or obj.TypeId.startswith("Sketcher::"):
                continue
            if not (hasattr(obj, "Shape") or obj.TypeId == "App::Link"):
                continue
            if check_visible and not visible(obj):
                continue
            if any(p.isDerivedFrom("PartDesign::Body") for p in obj.InList) and not obj.isDerivedFrom("PartDesign::Body"):
                continue
            if not check_visible and any(hasattr(p, "Shape") and not p.isDerivedFrom("App::Part") for p in obj.InList):
                continue
            try:
                shape = Part.getShape(obj, "", needSubElement=False, transform=True)
            except Exception:
                continue
            if shape.isNull() or not shape.Faces:
                continue
            out.append((obj.Name, obj.Label, shape, color_of(obj)))
        return out
    return candidates(True) or candidates(False)


def tessellate(shape, path):
    """Each face's triangles (as the face is turned), its normals at their corners, and the face's number."""
    bb = shape.BoundBox
    tol = max(0.005, bb.DiagonalLength * 6e-4)
    positions, normals, faces = [], [], []
    for index, face in enumerate(shape.Faces):
        try:
            pts, tris = face.tessellate(tol)
        except Exception:
            continue
        if not tris:
            continue
        flip = False
        try:
            a, b, c = pts[tris[0][0]], pts[tris[0][1]], pts[tris[0][2]]
            n = (b - a).cross(c - a)
            centre = (a + b + c) * (1.0 / 3)
            uv = face.Surface.parameter(centre)
            fn = face.normalAt(uv[0], uv[1])
            flip = n.dot(fn) < 0
        except Exception:
            pass
        # Corner normals: smooth across the face.
        acc = [Vector(0, 0, 0) for _ in pts]
        for t in tris:
            i, j, k = (t[0], t[2], t[1]) if flip else t
            n = (pts[j] - pts[i]).cross(pts[k] - pts[i])
            for q in (i, j, k):
                acc[q] = acc[q] + n
        for t in tris:
            i, j, k = (t[0], t[2], t[1]) if flip else t
            for q in (i, j, k):
                p = pts[q]
                positions += [p.x, p.y, p.z]
                m = acc[q]
                length = m.Length
                if length > 1e-12:
                    m = m * (1.0 / length)
                normals += [m.x, m.y, m.z]
            faces.append(index)
    with open(path, "wb") as fh:
        fh.write(struct.pack("<I", len(faces)))
        fh.write(struct.pack("<%df" % len(positions), *positions))
        fh.write(struct.pack("<%df" % len(normals), *normals))
        fh.write(struct.pack("<%dI" % len(faces), *faces))
    return len(faces)


def read(job, folder):
    path = job["path"]
    ext = os.path.splitext(path)[1].lower()
    items = []
    if ext == ".fcstd":
        doc = App.openDocument(path)
        doc.recompute()
        items = shapes_in(doc)
    else:
        doc = App.newDocument("Import")
        if GUI and ext in (".step", ".stp", ".iges", ".igs"):
            import ImportGui
            ImportGui.insert(path, doc.Name)
            items = shapes_in(doc)
        else:
            shape = Part.read(path)
            solids = shape.Solids or [shape]
            items = [("Solid%d" % (i + 1), "%s %d" % (os.path.splitext(os.path.basename(path))[0], i + 1) if len(solids) > 1 else os.path.splitext(os.path.basename(path))[0], s, None)
                     for i, s in enumerate(solids)]
    result = {"objects": []}
    for k, (name, label, shape, color) in enumerate(items):
        file = os.path.join(folder, "object%d.bin" % k)
        count = tessellate(shape, file)
        if count == 0:
            continue
        result["objects"].append({"name": name, "label": label, "color": color, "file": file, "triangles": count,
                                  "volume": shape.Volume if shape.Solids else 0})
    return result


def main(folder):
    result = {}
    try:
        with open(os.path.join(folder, "job.json")) as fh:
            job = json.load(fh)
        command = job.get("command")
        if command in ("document", "export"):
            result = document(job, folder)
        elif command == "import":
            result = read(job, folder)
        else:
            raise ValueError("unknown command %r" % command)
        result["ok"] = True
    except Exception as e:
        result = {"ok": False, "error": repr(e), "trace": traceback.format_exc()}
    result["log"] = LOG
    result["gui"] = GUI
    result["version"] = ".".join(App.Version()[:3])
    with open(os.path.join(folder, "result.json.part"), "w") as fh:
        json.dump(result, fh)
    os.replace(os.path.join(folder, "result.json.part"), os.path.join(folder, "result.json"))
"""#
}
