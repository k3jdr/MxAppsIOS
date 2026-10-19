//
//  MxCADKernel.cpp
//  MxNoteONE
//
//  Booleans follow the BSP-tree method (as in Evan Wallace's csg.js): each solid's polygons are built into a
//  tree of splitting planes; clipping one solid's polygons by the other's tree keeps the parts outside (or
//  inside) it. The trees are walked with explicit stacks, so large models don't run out of stack.
//

#include "MxCADKernel.hpp"

#include <algorithm>
#include <array>
#include <cmath>
#include <map>
#include <tuple>
#include <utility>

namespace mxcad {

static constexpr double kEpsilon = 1e-5;
static constexpr double kPi = 3.14159265358979323846;

double Vec3::length() const { return std::sqrt(x * x + y * y + z * z); }

Vec3 Vec3::unit() const {
    double l = length();
    return l > 1e-15 ? *this * (1.0 / l) : Vec3(0, 0, 0);
}

void Polygon::flip() {
    std::reverse(vertices.begin(), vertices.end());
    for (auto& v : vertices) v.normal = -v.normal;
    plane.flip();
}

// MARK: - Making polygons

/// A polygon's plane by Newell's method (robust for any planar polygon); false when it has no area.
static bool planeOf(const std::vector<Vertex>& vs, Plane& plane) {
    Vec3 n;
    Vec3 centre;
    for (size_t i = 0; i < vs.size(); i++) {
        const Vec3& a = vs[i].pos;
        const Vec3& b = vs[(i + 1) % vs.size()].pos;
        n.x += (a.y - b.y) * (a.z + b.z);
        n.y += (a.z - b.z) * (a.x + b.x);
        n.z += (a.x - b.x) * (a.y + b.y);
        centre = centre + a;
    }
    double l = n.length();
    if (l < 1e-12) return false;
    plane.normal = n * (1.0 / l);
    plane.w = plane.normal.dot(centre * (1.0 / double(vs.size())));
    return true;
}

/// Adds a polygon (repeated corners dropped); with `outward` given, it's turned to face that way.
static void add(std::vector<Polygon>& out, std::vector<Vertex> vs, uint32_t face, const Vec3* outward = nullptr) {
    std::vector<Vertex> clean;
    for (const auto& v : vs) {
        if (clean.empty() || (clean.back().pos - v.pos).length() > 1e-9) clean.push_back(v);
    }
    while (clean.size() > 1 && (clean.front().pos - clean.back().pos).length() <= 1e-9) clean.pop_back();
    if (clean.size() < 3) return;
    Polygon p;
    p.vertices = std::move(clean);
    p.face = face;
    if (!planeOf(p.vertices, p.plane)) return;
    if (outward && p.plane.normal.dot(*outward) < 0) {
        std::reverse(p.vertices.begin(), p.vertices.end());
        p.plane.flip();
    }
    out.push_back(std::move(p));
}

static Vertex flat(const Vec3& p, const Vec3& n) { return {p, n}; }

// MARK: - BSP trees

enum { kCoplanar = 0, kFront = 1, kBack = 2, kSpanning = 3 };

static void split(const Plane& plane, const Polygon& poly, std::vector<Polygon>& coplanarFront, std::vector<Polygon>& coplanarBack,
                  std::vector<Polygon>& front, std::vector<Polygon>& back) {
    int type = 0;
    std::vector<int> types(poly.vertices.size());
    for (size_t i = 0; i < poly.vertices.size(); i++) {
        double t = plane.normal.dot(poly.vertices[i].pos) - plane.w;
        int k = t < -kEpsilon ? kBack : t > kEpsilon ? kFront : kCoplanar;
        type |= k;
        types[i] = k;
    }
    switch (type) {
    case kCoplanar:
        (plane.normal.dot(poly.plane.normal) > 0 ? coplanarFront : coplanarBack).push_back(poly);
        break;
    case kFront:
        front.push_back(poly);
        break;
    case kBack:
        back.push_back(poly);
        break;
    default: {
        std::vector<Vertex> f, b;
        size_t n = poly.vertices.size();
        for (size_t i = 0; i < n; i++) {
            size_t j = (i + 1) % n;
            int ti = types[i], tj = types[j];
            const Vertex& vi = poly.vertices[i];
            const Vertex& vj = poly.vertices[j];
            if (ti != kBack) f.push_back(vi);
            if (ti != kFront) b.push_back(vi);
            if ((ti | tj) == kSpanning) {
                double t = (plane.w - plane.normal.dot(vi.pos)) / plane.normal.dot(vj.pos - vi.pos);
                Vertex v = vi.interpolate(vj, t);
                f.push_back(v);
                b.push_back(v);
            }
        }
        if (f.size() >= 3) {
            Polygon p;
            p.vertices = std::move(f);
            p.plane = poly.plane;
            p.face = poly.face;
            front.push_back(std::move(p));
        }
        if (b.size() >= 3) {
            Polygon p;
            p.vertices = std::move(b);
            p.plane = poly.plane;
            p.face = poly.face;
            back.push_back(std::move(p));
        }
    }
    }
}

class BSP {
    struct Node {
        Plane plane;
        bool hasPlane = false;
        int front = -1, back = -1;
        std::vector<Polygon> polygons;
    };
    std::vector<Node> nodes;

public:
    explicit BSP(const std::vector<Polygon>& polygons) {
        nodes.emplace_back();
        build(polygons);
    }

    void build(const std::vector<Polygon>& polygons) {
        std::vector<std::pair<int, std::vector<Polygon>>> work;
        work.emplace_back(0, polygons);
        while (!work.empty()) {
            auto [index, list] = std::move(work.back());
            work.pop_back();
            if (list.empty()) continue;
            if (!nodes[index].hasPlane) {
                nodes[index].plane = list[0].plane;
                nodes[index].hasPlane = true;
            }
            std::vector<Polygon> f, b;
            Plane plane = nodes[index].plane;
            for (const auto& p : list) split(plane, p, nodes[index].polygons, nodes[index].polygons, f, b);
            if (!f.empty()) {
                if (nodes[index].front < 0) {
                    nodes.emplace_back();
                    nodes[index].front = int(nodes.size()) - 1;
                }
                work.emplace_back(nodes[index].front, std::move(f));
            }
            if (!b.empty()) {
                if (nodes[index].back < 0) {
                    nodes.emplace_back();
                    nodes[index].back = int(nodes.size()) - 1;
                }
                work.emplace_back(nodes[index].back, std::move(b));
            }
        }
    }

    void invert() {
        for (auto& n : nodes) {
            for (auto& p : n.polygons) p.flip();
            n.plane.flip();
            std::swap(n.front, n.back);
        }
    }

    /// The parts of the polygons outside this solid.
    std::vector<Polygon> clip(const std::vector<Polygon>& polygons) const {
        std::vector<Polygon> out;
        std::vector<std::pair<int, std::vector<Polygon>>> work;
        work.emplace_back(0, polygons);
        while (!work.empty()) {
            auto [index, list] = std::move(work.back());
            work.pop_back();
            const Node& n = nodes[index];
            if (!n.hasPlane) {
                out.insert(out.end(), list.begin(), list.end());
                continue;
            }
            std::vector<Polygon> f, b;
            for (const auto& p : list) split(n.plane, p, f, b, f, b);
            if (n.front >= 0) work.emplace_back(n.front, std::move(f));
            else out.insert(out.end(), f.begin(), f.end());
            if (n.back >= 0) work.emplace_back(n.back, std::move(b));
        }
        return out;
    }

    void clipTo(const BSP& other) {
        for (auto& n : nodes) n.polygons = other.clip(n.polygons);
    }

    std::vector<Polygon> all() const {
        std::vector<Polygon> out;
        for (const auto& n : nodes) out.insert(out.end(), n.polygons.begin(), n.polygons.end());
        return out;
    }
};

Solid Solid::unite(const Solid& other) const {
    if (polygons.empty()) return other;
    if (other.polygons.empty()) return *this;
    BSP a(polygons), b(other.polygons);
    a.clipTo(b);
    b.clipTo(a);
    b.invert();
    b.clipTo(a);
    b.invert();
    a.build(b.all());
    Solid s;
    s.polygons = a.all();
    return s;
}

Solid Solid::subtract(const Solid& other) const {
    if (polygons.empty() || other.polygons.empty()) return *this;
    BSP a(polygons), b(other.polygons);
    a.invert();
    a.clipTo(b);
    b.clipTo(a);
    b.invert();
    b.clipTo(a);
    b.invert();
    a.build(b.all());
    a.invert();
    Solid s;
    s.polygons = a.all();
    return s;
}

Solid Solid::intersect(const Solid& other) const {
    if (polygons.empty() || other.polygons.empty()) return Solid();
    BSP a(polygons), b(other.polygons);
    a.invert();
    b.clipTo(a);
    b.invert();
    a.clipTo(b);
    b.clipTo(a);
    a.build(b.all());
    a.invert();
    Solid s;
    s.polygons = a.all();
    return s;
}

// MARK: - Transforms and measures

Solid Solid::transformed(const Transform& t) const {
    const double* m = t.m;
    auto point = [&](const Vec3& p) {
        return Vec3(m[0] * p.x + m[4] * p.y + m[8] * p.z + m[12], m[1] * p.x + m[5] * p.y + m[9] * p.z + m[13],
                    m[2] * p.x + m[6] * p.y + m[10] * p.z + m[14]);
    };
    // Normals go through the inverse transpose of the 3×3 part.
    double a = m[0], b = m[4], c = m[8], d = m[1], e = m[5], f = m[9], g = m[2], h = m[6], i = m[10];
    double det = a * (e * i - f * h) - b * (d * i - f * g) + c * (d * h - e * g);
    double cof[9] = {e * i - f * h, -(d * i - f * g), d * h - e * g, -(b * i - c * h), a * i - c * g, -(a * h - b * g),
                     b * f - c * e, -(a * f - c * d), a * e - b * d};
    auto normal = [&](const Vec3& n) {
        // Cofactor matrix = det · inverse transpose; its direction is what matters.
        Vec3 r(cof[0] * n.x + cof[1] * n.y + cof[2] * n.z, cof[3] * n.x + cof[4] * n.y + cof[5] * n.z,
               cof[6] * n.x + cof[7] * n.y + cof[8] * n.z);
        return (det < 0 ? -r : r).unit();
    };
    Solid s;
    s.polygons.reserve(polygons.size());
    for (const auto& p : polygons) {
        std::vector<Vertex> vs;
        vs.reserve(p.vertices.size());
        for (const auto& v : p.vertices) vs.push_back({point(v.pos), normal(v.normal)});
        // A mirroring transform turns faces inside out: put the corners back in order.
        if (det < 0) std::reverse(vs.begin(), vs.end());
        add(s.polygons, vs, p.face);
    }
    return s;
}

double Solid::volume() const {
    double v = 0;
    for (const auto& p : polygons) {
        for (size_t i = 1; i + 1 < p.vertices.size(); i++) {
            const Vec3& a = p.vertices[0].pos;
            const Vec3& b = p.vertices[i].pos;
            const Vec3& c = p.vertices[i + 1].pos;
            v += a.dot(b.cross(c)) / 6.0;
        }
    }
    return v;
}

double Solid::area() const {
    double s = 0;
    for (const auto& p : polygons) {
        for (size_t i = 1; i + 1 < p.vertices.size(); i++) {
            s += (p.vertices[i].pos - p.vertices[0].pos).cross(p.vertices[i + 1].pos - p.vertices[0].pos).length() / 2.0;
        }
    }
    return s;
}

void Solid::bounds(double out[6]) const {
    bool first = true;
    for (const auto& p : polygons) {
        for (const auto& v : p.vertices) {
            const double c[3] = {v.pos.x, v.pos.y, v.pos.z};
            for (int k = 0; k < 3; k++) {
                if (first || c[k] < out[k]) out[k] = c[k];
                if (first || c[k] > out[k + 3]) out[k + 3] = c[k];
            }
            first = false;
        }
    }
    if (first) for (int k = 0; k < 6; k++) out[k] = 0;
}

void Solid::orientOutward() {
    if (volume() < 0) for (auto& p : polygons) p.flip();
}

Mesh Solid::mesh() const {
    Mesh m;
    for (const auto& p : polygons) {
        for (size_t i = 1; i + 1 < p.vertices.size(); i++) {
            const Vertex* tri[3] = {&p.vertices[0], &p.vertices[i], &p.vertices[i + 1]};
            for (const Vertex* v : tri) {
                m.positions.insert(m.positions.end(), {float(v->pos.x), float(v->pos.y), float(v->pos.z)});
                Vec3 n = v->normal.length() > 0.5 ? v->normal : p.plane.normal;
                m.normals.insert(m.normals.end(), {float(n.x), float(n.y), float(n.z)});
                m.faces.push_back(p.face);
            }
        }
    }
    return m;
}

// MARK: - Primitives

Solid Solid::box(double w, double d, double h, double radius, int segments, uint32_t face) {
    Solid s;
    double hx = w / 2, hy = d / 2, hz = h / 2;
    double r = std::max(0.0, std::min(radius, std::min({hx, hy, hz}) - 1e-6));
    Vec3 centre(0, 0, hz);
    if (r <= 1e-9) {
        // Bottom, top, front (−Y), back (+Y), left (−X), right (+X).
        const Vec3 normals[6] = {{0, 0, -1}, {0, 0, 1}, {0, -1, 0}, {0, 1, 0}, {-1, 0, 0}, {1, 0, 0}};
        for (int k = 0; k < 6; k++) {
            Vec3 n = normals[k];
            // Two axes across the face.
            Vec3 u = std::fabs(n.z) > 0.5 ? Vec3(1, 0, 0) : Vec3(0, 0, 1);
            Vec3 v = n.cross(u);
            Vec3 half(hx, hy, hz);
            auto scale = [&](const Vec3& a) { return Vec3(a.x * half.x, a.y * half.y, a.z * half.z); };
            Vec3 c = centre + scale(n), du = scale(u), dv = scale(v);
            add(s.polygons, {flat(c - du - dv, n), flat(c + du - dv, n), flat(c + du + dv, n), flat(c - du + dv, n)}, face + k, &n);
        }
        return s;
    }
    // Rounded: a subdivided box whose points are pushed out from an inner box by the radius — flat in the middle
    // of each face, a quarter cylinder along each edge and an eighth of a sphere at each corner.
    int k = std::max(2, segments / 8);
    double inner[3] = {hx - r, hy - r, hz - r};
    double half[3] = {hx, hy, hz};
    auto samples = [&](int axis) {
        std::vector<double> t;
        for (int j = 0; j <= k; j++) t.push_back(-(inner[axis] + r * std::tan(kPi / 4 * double(k - j) / k)));
        for (int j = 0; j <= k; j++) t.push_back(inner[axis] + r * std::tan(kPi / 4 * double(j) / k));
        return t;
    };
    auto project = [&](double p[3]) {
        double c[3];
        for (int a = 0; a < 3; a++) c[a] = std::max(-inner[a], std::min(inner[a], p[a]));
        Vec3 dir = Vec3(p[0] - c[0], p[1] - c[1], p[2] - c[2]).unit();
        return Vertex{Vec3(c[0], c[1], c[2]) + dir * r + centre, dir};
    };
    for (int axis = 0; axis < 3; axis++) {
        for (int sign = -1; sign <= 1; sign += 2) {
            int ua = (axis + 1) % 3, va = (axis + 2) % 3;
            auto us = samples(ua), vs = samples(va);
            Vec3 outward(axis == 0 ? sign : 0, axis == 1 ? sign : 0, axis == 2 ? sign : 0);
            uint32_t flatFace = face + uint32_t(axis * 2 + (sign > 0 ? 1 : 0));
            for (size_t i = 0; i + 1 < us.size(); i++) {
                for (size_t j = 0; j + 1 < vs.size(); j++) {
                    auto corner = [&](size_t a, size_t b) {
                        double p[3];
                        p[axis] = sign * half[axis];
                        p[ua] = us[a];
                        p[va] = vs[b];
                        return project(p);
                    };
                    Vertex q[4] = {corner(i, j), corner(i + 1, j), corner(i + 1, j + 1), corner(i, j + 1)};
                    bool middle = i == size_t(k) && j == size_t(k);
                    if (middle) {
                        add(s.polygons, {q[0], q[1], q[2], q[3]}, flatFace, &outward);
                    } else {
                        // Curved: two triangles (each exactly flat).
                        Vec3 n = (q[0].normal + q[2].normal).unit();
                        add(s.polygons, {q[0], q[1], q[2]}, face + 6, &n);
                        add(s.polygons, {q[0], q[2], q[3]}, face + 6, &n);
                    }
                }
            }
        }
    }
    return s;
}

Solid Solid::cylinder(double radius, double height, int segments, uint32_t face) {
    return cone(radius, radius, height, segments, face);
}

Solid Solid::cone(double r1, double r2, double h, int segments, uint32_t face) {
    Solid s;
    int n = std::max(8, segments);
    double slope = h > 1e-12 ? (r1 - r2) / h : 0;
    std::vector<Vertex> bottom, top;
    for (int i = 0; i < n; i++) {
        double a0 = 2 * kPi * i / n, a1 = 2 * kPi * (i + 1) / n;
        Vec3 n0 = Vec3(std::cos(a0), std::sin(a0), slope).unit(), n1 = Vec3(std::cos(a1), std::sin(a1), slope).unit();
        Vec3 b0(r1 * std::cos(a0), r1 * std::sin(a0), 0), b1(r1 * std::cos(a1), r1 * std::sin(a1), 0);
        Vec3 t0(r2 * std::cos(a0), r2 * std::sin(a0), h), t1(r2 * std::cos(a1), r2 * std::sin(a1), h);
        Vec3 mid = Vec3(std::cos((a0 + a1) / 2), std::sin((a0 + a1) / 2), slope).unit();
        add(s.polygons, {{b0, n0}, {b1, n1}, {t1, r2 > 1e-12 ? n1 : mid}, {t0, r2 > 1e-12 ? n0 : mid}}, face, &mid);
        bottom.push_back(flat(b0, {0, 0, -1}));
        top.push_back(flat(t0, {0, 0, 1}));
    }
    Vec3 down(0, 0, -1), up(0, 0, 1);
    if (r1 > 1e-12) add(s.polygons, bottom, face + 1, &down);
    if (r2 > 1e-12) add(s.polygons, top, face + 2, &up);
    return s;
}

Solid Solid::sphere(double r, int segments, uint32_t face) {
    Solid s;
    int slices = std::max(12, segments), stacks = std::max(6, segments / 2);
    Vec3 centre(0, 0, r);
    auto point = [&](int i, int j) {
        double theta = 2 * kPi * i / slices, phi = kPi * j / stacks;
        Vec3 n(std::sin(phi) * std::cos(theta), std::sin(phi) * std::sin(theta), std::cos(phi));
        return Vertex{centre + n * r, n};
    };
    for (int i = 0; i < slices; i++) {
        for (int j = 0; j < stacks; j++) {
            std::vector<Vertex> vs = {point(i, j), point(i, j + 1), point(i + 1, j + 1), point(i + 1, j)};
            Vec3 out = (vs[0].normal + vs[2].normal).unit();
            add(s.polygons, vs, face, &out);
        }
    }
    return s;
}

Solid Solid::torus(double R, double r, int segments, uint32_t face) {
    Solid s;
    int n = std::max(12, segments), m = std::max(8, segments / 2);
    auto point = [&](int i, int j) {
        double u = 2 * kPi * i / n, v = 2 * kPi * j / m;
        Vec3 ring(std::cos(u), std::sin(u), 0);
        Vec3 normal = ring * std::cos(v) + Vec3(0, 0, std::sin(v));
        return Vertex{ring * R + normal * r + Vec3(0, 0, r), normal};
    };
    for (int i = 0; i < n; i++) {
        for (int j = 0; j < m; j++) {
            std::vector<Vertex> vs = {point(i, j), point(i + 1, j), point(i + 1, j + 1), point(i, j + 1)};
            Vec3 out = (vs[0].normal + vs[2].normal).unit();
            add(s.polygons, vs, face, &out);
        }
    }
    return s;
}

// MARK: - Profiles

static double signedArea(const std::vector<Vec2>& p) {
    double a = 0;
    for (size_t i = 0; i < p.size(); i++) {
        const Vec2& u = p[i];
        const Vec2& v = p[(i + 1) % p.size()];
        a += u.x * v.y - v.x * u.y;
    }
    return a / 2;
}

/// The profile counter-clockwise, its edges' groups following their edges.
static Profile counterClockwise(const Profile& in) {
    Profile p = in;
    size_t n = p.points.size();
    if (p.groups.size() != n) p.groups.assign(n, 0);
    if (p.smooth.size() != n) p.smooth.assign(n, 0);
    if (signedArea(p.points) >= 0) return p;
    Profile r;
    for (size_t i = 0; i < n; i++) r.points.push_back(p.points[n - 1 - i]);
    // Reversed, edge i runs from r[i] to r[i + 1] = old edge n − 2 − i.
    for (size_t i = 0; i < n; i++) {
        size_t old = (2 * n - 2 - i) % n;
        r.groups.push_back(p.groups[old]);
        r.smooth.push_back(p.smooth[old]);
    }
    return r;
}

/// Triangles covering a simple counter-clockwise polygon (ear clipping).
static std::vector<std::array<int, 3>> triangulate(const std::vector<Vec2>& p) {
    std::vector<std::array<int, 3>> tris;
    std::vector<int> idx;
    for (int i = 0; i < int(p.size()); i++) idx.push_back(i);
    auto cross = [&](int a, int b, int c) { return (p[b].x - p[a].x) * (p[c].y - p[a].y) - (p[b].y - p[a].y) * (p[c].x - p[a].x); };
    auto inside = [&](int a, int b, int c, int q) {
        double d1 = cross(a, b, q), d2 = cross(b, c, q), d3 = cross(c, a, q);
        return d1 >= -1e-12 && d2 >= -1e-12 && d3 >= -1e-12;
    };
    int guard = 0;
    while (idx.size() > 3 && guard++ < 100000) {
        bool clipped = false;
        for (size_t i = 0; i < idx.size(); i++) {
            int a = idx[(i + idx.size() - 1) % idx.size()], b = idx[i], c = idx[(i + 1) % idx.size()];
            if (cross(a, b, c) <= 1e-12) continue;   // a reflex (or flat) corner
            bool ear = true;
            for (int q : idx) {
                if (q == a || q == b || q == c) continue;
                if (inside(a, b, c, q)) { ear = false; break; }
            }
            if (!ear) continue;
            tris.push_back({a, b, c});
            idx.erase(idx.begin() + long(i));
            clipped = true;
            break;
        }
        if (!clipped) break;
    }
    if (idx.size() == 3) tris.push_back({idx[0], idx[1], idx[2]});
    return tris;
}

/// Each corner's normal on the side faces: its edge's, or between the two edges where a smooth face goes on.
static std::vector<std::pair<Vec2, Vec2>> edgeNormals(const Profile& p) {
    size_t n = p.points.size();
    std::vector<Vec2> edge(n);
    for (size_t i = 0; i < n; i++) {
        const Vec2& a = p.points[i];
        const Vec2& b = p.points[(i + 1) % n];
        double dx = b.x - a.x, dy = b.y - a.y, l = std::sqrt(dx * dx + dy * dy);
        edge[i] = l > 1e-15 ? Vec2{dy / l, -dx / l} : Vec2{0, 0};
    }
    std::vector<std::pair<Vec2, Vec2>> out(n);   // (start, end) normal of each edge
    for (size_t i = 0; i < n; i++) {
        size_t prev = (i + n - 1) % n, next = (i + 1) % n;
        Vec2 start = edge[i], end = edge[i];
        if (p.smooth[i] && p.smooth[prev] && p.groups[prev] == p.groups[i]) {
            double x = edge[i].x + edge[prev].x, y = edge[i].y + edge[prev].y, l = std::sqrt(x * x + y * y);
            if (l > 1e-12) start = {x / l, y / l};
        }
        if (p.smooth[i] && p.smooth[next] && p.groups[next] == p.groups[i]) {
            double x = edge[i].x + edge[next].x, y = edge[i].y + edge[next].y, l = std::sqrt(x * x + y * y);
            if (l > 1e-12) end = {x / l, y / l};
        }
        out[i] = {start, end};
    }
    return out;
}

Solid Solid::extrude(const Profile& in, double height, uint32_t face) {
    Solid s;
    if (in.points.size() < 3 || std::fabs(height) < 1e-12) return s;
    Profile p = counterClockwise(in);
    double z0 = std::min(0.0, height), z1 = std::max(0.0, height);
    size_t n = p.points.size();
    auto normals = edgeNormals(p);
    for (size_t i = 0; i < n; i++) {
        const Vec2& a = p.points[i];
        const Vec2& b = p.points[(i + 1) % n];
        Vec3 na(normals[i].first.x, normals[i].first.y, 0), nb(normals[i].second.x, normals[i].second.y, 0);
        Vec3 out = (na + nb).unit();
        add(s.polygons, {{{a.x, a.y, z0}, na}, {{b.x, b.y, z0}, nb}, {{b.x, b.y, z1}, nb}, {{a.x, a.y, z1}, na}},
            face + 2 + uint32_t(std::max(0, p.groups[i])), &out);
    }
    Vec3 down(0, 0, -1), up(0, 0, 1);
    for (const auto& t : triangulate(p.points)) {
        std::vector<Vertex> bottom, top;
        for (int k : t) {
            bottom.push_back(flat({p.points[k].x, p.points[k].y, z0}, down));
            top.push_back(flat({p.points[k].x, p.points[k].y, z1}, up));
        }
        add(s.polygons, bottom, face, &down);
        add(s.polygons, top, face + 1, &up);
    }
    return s;
}

Solid Solid::revolve(const Profile& in, double degrees, int segments, uint32_t face) {
    Solid s;
    if (in.points.size() < 3) return s;
    Profile p = in;
    // Revolve from whichever side of the axis the profile is on.
    double maxX = 0, minX = 0;
    for (const auto& q : p.points) { maxX = std::max(maxX, q.x); minX = std::min(minX, q.x); }
    if (maxX <= 1e-12 && minX < 0) for (auto& q : p.points) q.x = -q.x;
    for (auto& q : p.points) q.x = std::max(0.0, q.x);
    p = counterClockwise(p);
    double sweep = std::max(-360.0, std::min(360.0, degrees)) * kPi / 180;
    bool full = std::fabs(std::fabs(degrees) - 360) < 1e-9;
    int steps = std::max(3, int(std::ceil(std::max(12, segments) * std::fabs(sweep) / (2 * kPi))));
    size_t n = p.points.size();
    auto normals = edgeNormals(p);
    auto at = [&](const Vec2& q, double angle) { return Vec3(q.x * std::cos(angle), q.y, q.x * std::sin(angle)); };
    auto turn = [&](const Vec2& nn, double angle) { return Vec3(nn.x * std::cos(angle), nn.y, nn.x * std::sin(angle)); };
    for (size_t i = 0; i < n; i++) {
        const Vec2& a = p.points[i];
        const Vec2& b = p.points[(i + 1) % n];
        for (int j = 0; j < steps; j++) {
            double t0 = sweep * j / steps, t1 = sweep * (j + 1) / steps;
            Vec3 out = (turn(normals[i].first, (t0 + t1) / 2) + turn(normals[i].second, (t0 + t1) / 2)).unit();
            add(s.polygons, {{at(a, t0), turn(normals[i].first, t0)}, {at(b, t0), turn(normals[i].second, t0)},
                             {at(b, t1), turn(normals[i].second, t1)}, {at(a, t1), turn(normals[i].first, t1)}},
                face + 2 + uint32_t(std::max(0, p.groups[i])), &out);
        }
    }
    if (!full) {
        // Caps where the sweep starts and ends.
        Vec3 startOut(std::sin(0.0), 0, -std::cos(0.0));
        Vec3 endOut(-std::sin(sweep), 0, std::cos(sweep));
        if (sweep < 0) { startOut = -startOut; endOut = -endOut; }
        for (const auto& t : triangulate(p.points)) {
            std::vector<Vertex> a, b;
            for (int k : t) {
                a.push_back(flat(at(p.points[k], 0), startOut));
                b.push_back(flat(at(p.points[k], sweep), endOut));
            }
            add(s.polygons, a, face, &startOut);
            add(s.polygons, b, face + 1, &endOut);
        }
    }
    s.orientOutward();
    return s;
}

Solid Solid::triangles(const std::vector<float>& xyz, uint32_t face) {
    Solid s;
    // Faces from flat regions: triangles on the same plane share a face.
    std::map<std::tuple<long, long, long, long>, uint32_t> planes;
    for (size_t i = 0; i + 8 < xyz.size(); i += 9) {
        Vec3 a(xyz[i], xyz[i + 1], xyz[i + 2]), b(xyz[i + 3], xyz[i + 4], xyz[i + 5]), c(xyz[i + 6], xyz[i + 7], xyz[i + 8]);
        Vec3 n = (b - a).cross(c - a).unit();
        if (n.length() < 0.5) continue;
        auto key = std::make_tuple(std::lround(n.x * 100), std::lround(n.y * 100), std::lround(n.z * 100), std::lround(n.dot(a) * 10));
        auto found = planes.find(key);
        uint32_t f = found != planes.end() ? found->second : uint32_t(planes.size());
        if (found == planes.end()) planes[key] = f;
        add(s.polygons, {flat(a, n), flat(b, n), flat(c, n)}, face + std::min<uint32_t>(f, 0xFFFF));
    }
    return s;
}

}  // namespace mxcad
