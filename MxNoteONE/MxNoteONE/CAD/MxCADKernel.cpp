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
#include <string>
#include <tuple>
#include <unordered_map>
#include <unordered_set>
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

Solid Solid::triangles(const std::vector<float>& xyz, uint32_t face, const std::vector<uint32_t>* faces, const std::vector<float>* normals) {
    Solid s;
    size_t count = xyz.size() / 9;
    bool given = faces && faces->size() >= count;
    bool smooth = normals && normals->size() >= count * 9;
    // Faces from flat regions (unless given): triangles on the same plane share a face.
    std::map<std::tuple<long, long, long, long>, uint32_t> planes;
    for (size_t t = 0; t < count; t++) {
        size_t i = t * 9;
        Vec3 a(xyz[i], xyz[i + 1], xyz[i + 2]), b(xyz[i + 3], xyz[i + 4], xyz[i + 5]), c(xyz[i + 6], xyz[i + 7], xyz[i + 8]);
        Vec3 n = (b - a).cross(c - a).unit();
        if (n.length() < 0.5) continue;
        uint32_t f;
        if (given) {
            f = (*faces)[t];
        } else {
            auto key = std::make_tuple(std::lround(n.x * 100), std::lround(n.y * 100), std::lround(n.z * 100), std::lround(n.dot(a) * 10));
            auto found = planes.find(key);
            f = found != planes.end() ? found->second : uint32_t(planes.size());
            if (found == planes.end()) planes[key] = f;
        }
        std::vector<Vertex> vs = {flat(a, n), flat(b, n), flat(c, n)};
        if (smooth) {
            for (int k = 0; k < 3; k++) {
                Vec3 m((*normals)[i + 3 * k], (*normals)[i + 3 * k + 1], (*normals)[i + 3 * k + 2]);
                m = m.unit();
                if (m.length() > 0.5) vs[k].normal = m.dot(n) < 0 ? -m : m;
            }
        }
        add(s.polygons, vs, face + std::min<uint32_t>(f, 0xFFFF));
    }
    return s;
}

// MARK: - Sweeps (lofts, pipes, helices)

Solid Solid::sweep(const std::vector<std::vector<Vec3>>& rings, const std::vector<int32_t>& groupsIn, const std::vector<uint8_t>& smoothIn,
                   bool closed, uint32_t face) {
    Solid s;
    size_t m = rings.size();
    if (m < 2) return s;
    size_t n = rings[0].size();
    if (n < 3) return s;
    for (const auto& r : rings) if (r.size() != n) return s;
    std::vector<int32_t> groups = groupsIn;
    std::vector<uint8_t> smooth = smoothIn;
    if (groups.size() != n) groups.assign(n, 0);
    if (smooth.size() != n) smooth.assign(n, 0);
    size_t segs = closed ? m : m - 1;
    // Each quad's normal (Newell, from its diagonals).
    std::vector<std::vector<Vec3>> q(segs, std::vector<Vec3>(n));
    for (size_t i = 0; i < segs; i++) {
        size_t next = (i + 1) % m;
        for (size_t k = 0; k < n; k++) {
            const Vec3& a = rings[i][k];
            const Vec3& b = rings[i][(k + 1) % n];
            const Vec3& c = rings[next][(k + 1) % n];
            const Vec3& d = rings[next][k];
            q[i][k] = (c - a).cross(d - b).unit();
        }
    }
    // A corner's normal: smooth along the sweep, and across profile edges of one smooth group.
    auto corner = [&](size_t ring, size_t point, size_t edge) {
        Vec3 sum;
        std::vector<size_t> sweepSegs;
        if (closed) { sweepSegs = {(ring + segs - 1) % segs, ring % segs}; }
        else {
            if (ring > 0) sweepSegs.push_back(ring - 1);
            if (ring < segs) sweepSegs.push_back(ring);
        }
        std::vector<size_t> edgeList = {edge};
        size_t other = point == edge ? (edge + n - 1) % n : (edge + 1) % n;   // the edge on the corner's other side
        if (smooth[edge] && smooth[other] && groups[other] == groups[edge]) edgeList.push_back(other);
        for (size_t si : sweepSegs) for (size_t e : edgeList) sum = sum + q[si][e];
        Vec3 u = sum.unit();
        return u.length() > 0.5 ? u : q[sweepSegs.empty() ? 0 : sweepSegs[0]][edge];
    };
    for (size_t i = 0; i < segs; i++) {
        size_t next = (i + 1) % m;
        for (size_t k = 0; k < n; k++) {
            size_t k1 = (k + 1) % n;
            Vertex a{rings[i][k], corner(i, k, k)}, b{rings[i][k1], corner(i, k1, k)};
            Vertex c{rings[next][k1], corner(next, k1, k)}, d{rings[next][k], corner(next, k, k)};
            uint32_t f = face + 2 + uint32_t(std::max(0, groups[k]));
            add(s.polygons, {a, b, c}, f);
            add(s.polygons, {a, c, d}, f);
        }
    }
    if (!closed) {
        // Caps: the first ring turned round, the last as it is.
        auto cap = [&](std::vector<Vec3> ring, uint32_t f) {
            Vec3 nrm;
            for (size_t i = 0; i < ring.size(); i++) {
                const Vec3& a = ring[i];
                const Vec3& b = ring[(i + 1) % ring.size()];
                nrm.x += (a.y - b.y) * (a.z + b.z);
                nrm.y += (a.z - b.z) * (a.x + b.x);
                nrm.z += (a.x - b.x) * (a.y + b.y);
            }
            nrm = nrm.unit();
            if (nrm.length() < 0.5) return;
            Vec3 u = std::fabs(nrm.x) < 0.9 ? Vec3(1, 0, 0).cross(nrm).unit() : Vec3(0, 1, 0).cross(nrm).unit();
            Vec3 v = nrm.cross(u);
            std::vector<Vec2> flatPts;
            for (const auto& p : ring) flatPts.push_back({p.dot(u), p.dot(v)});
            if (signedArea(flatPts) < 0) return;
            for (const auto& t : triangulate(flatPts)) add(s.polygons, {flat(ring[t[0]], nrm), flat(ring[t[1]], nrm), flat(ring[t[2]], nrm)}, f);
        };
        std::vector<Vec3> first(rings[0].rbegin(), rings[0].rend());
        cap(first, face);
        cap(rings[m - 1], face + 1);
    }
    s.orientOutward();
    return s;
}

// MARK: - Edges

namespace {

struct HalfEdge {
    int i, j;
    uint32_t face;
    int poly;
    Vec3 ni, nj;
};

struct CellHash {
    size_t operator()(const std::tuple<long, long, long>& k) const {
        return size_t(std::get<0>(k)) * 73856093u ^ size_t(std::get<1>(k)) * 19349663u ^ size_t(std::get<2>(k)) * 83492791u;
    }
};

uint64_t pairKey(int i, int j) { return (uint64_t(uint32_t(i)) << 32) | uint32_t(j); }

}  // namespace

std::vector<Edge> Solid::edges() const {
    std::vector<Edge> out;
    if (polygons.empty()) return out;
    double bb[6];
    bounds(bb);
    double diag = Vec3(bb[3] - bb[0], bb[4] - bb[1], bb[5] - bb[2]).length();
    const double tol = kEpsilon;
    // The corners, merged where they meet.
    const double cell = 1e-4;
    std::unordered_map<std::tuple<long, long, long>, std::vector<int>, CellHash> grid;
    std::vector<Vec3> pts;
    auto cellOf = [](const Vec3& p, double size) {
        return std::make_tuple(long(std::floor(p.x / size)), long(std::floor(p.y / size)), long(std::floor(p.z / size)));
    };
    auto indexOf = [&](const Vec3& p) {
        auto k = cellOf(p, cell);
        for (long dx = -1; dx <= 1; dx++)
            for (long dy = -1; dy <= 1; dy++)
                for (long dz = -1; dz <= 1; dz++) {
                    auto it = grid.find({std::get<0>(k) + dx, std::get<1>(k) + dy, std::get<2>(k) + dz});
                    if (it == grid.end()) continue;
                    for (int idx : it->second) if ((pts[idx] - p).length() < tol) return idx;
                }
        int idx = int(pts.size());
        pts.push_back(p);
        grid[k].push_back(idx);
        return idx;
    };
    std::vector<HalfEdge> hes;
    for (size_t pi = 0; pi < polygons.size(); pi++) {
        const Polygon& p = polygons[pi];
        std::vector<int> idx;
        for (const auto& v : p.vertices) idx.push_back(indexOf(v.pos));
        size_t n = idx.size();
        auto normalAt = [&](size_t k) { const Vec3& vn = p.vertices[k].normal; return vn.length() > 0.5 ? vn.unit() : p.plane.normal; };
        for (size_t k = 0; k < n; k++) {
            int i = idx[k], j = idx[(k + 1) % n];
            if (i == j) continue;
            hes.push_back({i, j, p.face, int(pi), normalAt(k), normalAt((k + 1) % n)});
        }
    }
    // T-junctions: a side with nothing running back along it is split at the corners lying on it.
    std::unordered_set<uint64_t> directed;
    for (const auto& h : hes) directed.insert(pairKey(h.i, h.j));
    const double coarse = std::max(1e-3, diag / 96);
    std::unordered_map<std::tuple<long, long, long>, std::vector<int>, CellHash> cells;
    for (int k = 0; k < int(pts.size()); k++) cells[cellOf(pts[k], coarse)].push_back(k);
    std::vector<HalfEdge> split;
    split.reserve(hes.size());
    for (const auto& h : hes) {
        if (directed.count(pairKey(h.j, h.i))) { split.push_back(h); continue; }
        Vec3 A = pts[h.i], B = pts[h.j], d = B - A;
        double L = d.length();
        if (L < tol) continue;
        std::vector<std::pair<double, int>> on;
        std::unordered_set<int> seen;
        int steps = std::max(1, int(std::ceil(L / coarse)));
        for (int st = 0; st <= steps; st++) {
            auto k = cellOf(A + d * (double(st) / steps), coarse);
            for (long dx = -1; dx <= 1; dx++)
                for (long dy = -1; dy <= 1; dy++)
                    for (long dz = -1; dz <= 1; dz++) {
                        auto it = cells.find({std::get<0>(k) + dx, std::get<1>(k) + dy, std::get<2>(k) + dz});
                        if (it == cells.end()) continue;
                        for (int idx : it->second) {
                            if (idx == h.i || idx == h.j || !seen.insert(idx).second) continue;
                            double t = (pts[idx] - A).dot(d) / (L * L);
                            if (t <= 1e-9 || t >= 1 - 1e-9) continue;
                            if ((pts[idx] - (A + d * t)).length() < tol) on.push_back({t, idx});
                        }
                    }
        }
        std::sort(on.begin(), on.end());
        int prev = h.i;
        Vec3 prevN = h.ni;
        for (const auto& [t, k] : on) {
            Vec3 nk = (h.ni + (h.nj - h.ni) * t).unit();
            split.push_back({prev, k, h.face, h.poly, prevN, nk});
            prev = k;
            prevN = nk;
        }
        split.push_back({prev, h.j, h.face, h.poly, prevN, h.nj});
    }
    // Sides between two different faces, from the lower-numbered face's side.
    struct Seg { int i, j; Vec3 nai, naj, nbi, nbj; int pa, pb; };
    std::unordered_map<uint64_t, int> byDirected;
    for (int k = 0; k < int(split.size()); k++) byDirected[pairKey(split[k].i, split[k].j)] = k;
    std::map<std::pair<uint32_t, uint32_t>, std::vector<Seg>> pairs;
    for (const auto& h : split) {
        auto it = byDirected.find(pairKey(h.j, h.i));
        if (it == byDirected.end()) continue;
        const HalfEdge& tw = split[it->second];
        if (h.face >= tw.face) continue;
        pairs[{h.face, tw.face}].push_back({h.i, h.j, h.ni, h.nj, tw.nj, tw.ni, h.poly, tw.poly});
    }
    auto centroid = [&](int pi) {
        Vec3 c;
        for (const auto& v : polygons[pi].vertices) c = c + v.pos;
        return c * (1.0 / double(std::max<size_t>(1, polygons[pi].vertices.size())));
    };
    for (auto& [fp, segs] : pairs) {
        std::unordered_map<int, std::vector<int>> at;
        for (int k = 0; k < int(segs.size()); k++) {
            at[segs[k].i].push_back(k);
            at[segs[k].j].push_back(k);
        }
        std::vector<bool> used(segs.size(), false);
        auto chainFrom = [&](int v0, int first) {
            Edge e;
            e.a = fp.first;
            e.b = fp.second;
            std::vector<int> vs = {v0};
            std::unordered_map<int, std::pair<Vec3, Vec3>> normals;
            auto addNormals = [&](int v, const Vec3& na, const Vec3& nb) {
                auto& slot = normals[v];
                slot.first = slot.first + na;
                slot.second = slot.second + nb;
            };
            e.insideA = centroid(segs[first].pa);
            e.insideB = centroid(segs[first].pb);
            int v = v0, si = first;
            while (true) {
                used[si] = true;
                const Seg& sg = segs[si];
                bool forward = sg.i == v;
                int next = forward ? sg.j : sg.i;
                addNormals(v, forward ? sg.nai : sg.naj, forward ? sg.nbi : sg.nbj);
                addNormals(next, forward ? sg.naj : sg.nai, forward ? sg.nbj : sg.nbi);
                v = next;
                if (v == v0) { e.closed = true; break; }
                vs.push_back(v);
                if (at[v].size() != 2) break;
                int nextSeg = -1;
                for (int k : at[v]) if (!used[k]) { nextSeg = k; break; }
                if (nextSeg < 0) break;
                si = nextSeg;
            }
            for (int idx : vs) {
                e.points.push_back(pts[idx]);
                e.normalsA.push_back(normals[idx].first.unit());
                e.normalsB.push_back(normals[idx].second.unit());
            }
            out.push_back(std::move(e));
        };
        // Open chains from their ends, then closed loops.
        for (auto& [v, list] : at) {
            if (list.size() == 2) continue;
            for (int k : list) if (!used[k]) chainFrom(v, k);
        }
        for (int k = 0; k < int(segs.size()); k++) if (!used[k]) chainFrom(segs[k].i, k);
    }
    return out;
}

// MARK: - Fillets and chamfers

namespace {

/// A circle through points (a least-squares fit in their plane): its centre, axis and radius, if they lie on one.
bool fitCircle(const std::vector<Vec3>& p, Vec3& c, Vec3& axis, double& r) {
    size_t n = p.size();
    if (n < 3) return false;
    Vec3 nrm, cen;
    for (size_t i = 0; i < n; i++) {
        const Vec3& a = p[i];
        const Vec3& b = p[(i + 1) % n];
        nrm.x += (a.y - b.y) * (a.z + b.z);
        nrm.y += (a.z - b.z) * (a.x + b.x);
        nrm.z += (a.x - b.x) * (a.y + b.y);
        cen = cen + a;
    }
    if (nrm.length() < 1e-12) return false;
    axis = nrm.unit();
    cen = cen * (1.0 / double(n));
    Vec3 u = std::fabs(axis.x) < 0.9 ? Vec3(1, 0, 0).cross(axis).unit() : Vec3(0, 1, 0).cross(axis).unit();
    Vec3 v = axis.cross(u);
    // Kåsa's fit: x² + y² + D x + E y + F = 0.
    double m[3][4] = {{0, 0, 0, 0}, {0, 0, 0, 0}, {0, 0, 0, 0}};
    for (const auto& q : p) {
        double x = (q - cen).dot(u), y = (q - cen).dot(v), row[3] = {x, y, 1}, rhs = -(x * x + y * y);
        for (int a = 0; a < 3; a++) {
            for (int b = 0; b < 3; b++) m[a][b] += row[a] * row[b];
            m[a][3] += row[a] * rhs;
        }
    }
    for (int col = 0; col < 3; col++) {
        int piv = col;
        for (int rr = col + 1; rr < 3; rr++) if (std::fabs(m[rr][col]) > std::fabs(m[piv][col])) piv = rr;
        if (std::fabs(m[piv][col]) < 1e-18) return false;
        for (int k = 0; k < 4; k++) std::swap(m[col][k], m[piv][k]);
        for (int rr = 0; rr < 3; rr++) {
            if (rr == col) continue;
            double f = m[rr][col] / m[col][col];
            for (int k = 0; k < 4; k++) m[rr][k] -= f * m[col][k];
        }
    }
    double D = m[0][3] / m[0][0], E = m[1][3] / m[1][1], F = m[2][3] / m[2][2];
    double cx = -D / 2, cy = -E / 2, rr2 = cx * cx + cy * cy - F;
    if (rr2 <= 0) return false;
    r = std::sqrt(rr2);
    c = cen + u * cx + v * cy;
    double tolerance = r * 2e-3 + 1e-4;
    for (const auto& q : p) {
        Vec3 d = q - c;
        double h = d.dot(axis);
        double radial = (d - axis * h).length();
        if (std::fabs(h) > tolerance || std::fabs(radial - r) > tolerance) return false;
    }
    return true;
}

/// A straight or round stretch of an edge.
struct Piece {
    std::vector<Vec3> pts, na, nb;
    bool closed = false;
};

std::vector<Piece> piecesOf(const Edge& e) {
    std::vector<Piece> out;
    Piece whole{e.points, e.normalsA, e.normalsB, e.closed};
    Vec3 c, axis;
    double r;
    if ((e.closed && e.points.size() >= 6) || (!e.closed && e.points.size() >= 4)) {
        if (fitCircle(e.points, c, axis, r)) { out.push_back(whole); return out; }
    }
    // Split where it turns a corner.
    size_t n = e.points.size();
    std::vector<size_t> corners;
    for (size_t k = 0; k < n; k++) {
        if (!e.closed && (k == 0 || k == n - 1)) continue;
        Vec3 a = (e.points[k] - e.points[(k + n - 1) % n]).unit(), b = (e.points[(k + 1) % n] - e.points[k]).unit();
        if (a.dot(b) < std::cos(20.0 * kPi / 180)) corners.push_back(k);
    }
    std::vector<size_t> cuts;
    if (!e.closed) cuts.push_back(0);
    cuts.insert(cuts.end(), corners.begin(), corners.end());
    if (!e.closed) cuts.push_back(n - 1);
    if (e.closed && cuts.empty()) { out.push_back(whole); return out; }
    size_t pieces = e.closed ? cuts.size() : cuts.size() - 1;
    for (size_t k = 0; k < pieces; k++) {
        size_t from = cuts[k], to = e.closed ? cuts[(k + 1) % cuts.size()] : cuts[k + 1];
        Piece pc;
        size_t i = from;
        while (true) {
            pc.pts.push_back(e.points[i]);
            pc.na.push_back(e.normalsA[i]);
            pc.nb.push_back(e.normalsB[i]);
            if (i == to) break;
            i = (i + 1) % n;
        }
        if (pc.pts.size() >= 2) out.push_back(pc);
    }
    return out;
}

/// What a fillet or chamfer takes away at an edge point P (or adds, at a concave edge), across the edge: the faces'
/// outward normals nA, nB and directions tA, tB from the edge into each face give the section's corners.
bool section(const Vec3& P, Vec3 nA, Vec3 nB, const Vec3& tA, const Vec3& tB, double size, bool chamfer, int segments,
             std::vector<Vec3>& pts, std::vector<int32_t>& groups, std::vector<uint8_t>& smooth, bool& concave) {
    concave = tB.dot(nA) > 1e-9;
    if (concave) { nA = -nA; nB = -nB; }
    double phi = std::acos(std::max(-1.0, std::min(1.0, tA.dot(tB))));
    if (phi < kPi / 180 || phi > kPi * 179 / 180) return false;
    double delta = size * 0.75 + 1e-3;
    Vec3 out = (nA + nB).unit();
    pts.clear();
    groups.clear();
    smooth.clear();
    if (chamfer) {
        Vec3 TA = P + tA * size, TB = P + tB * size;
        pts = {TA, TA + nA * delta, P + out * delta, TB + nB * delta, TB};
        groups = {1, 2, 3, 4, 0};
        smooth = {0, 0, 0, 0, 0};
        return true;
    }
    double d = size / std::tan(phi / 2);
    Vec3 TA = P + tA * d, TB = P + tB * d;
    Vec3 C = P + (tA + tB).unit() * (size / std::sin(phi / 2));
    pts = {TA, TA + nA * delta, P + out * delta, TB + nB * delta, TB};
    groups = {1, 2, 3, 4};
    smooth = {0, 0, 0, 0};
    Vec3 a0 = TB - C, a1 = TA - C;
    double sweep = kPi - phi;
    int k = std::max(2, int(std::ceil(double(std::max(8, segments)) * sweep / (2 * kPi))));
    Vec3 axis = a0.cross(a1).unit();
    for (int s = 1; s < k; s++) {
        double t = sweep * double(s) / k;
        // a0 turned by t towards a1 (Rodrigues).
        Vec3 v = a0 * std::cos(t) + axis.cross(a0) * std::sin(t) + axis * (axis.dot(a0) * (1 - std::cos(t)));
        pts.push_back(C + v);
    }
    // The arc's edges (from TB round to TA) are the fillet face.
    for (int s = 0; s < k; s++) { groups.push_back(0); smooth.push_back(1); }
    return true;
}

Transform columns(const Vec3& x, const Vec3& y, const Vec3& z, const Vec3& o) {
    Transform t;
    double m[16] = {x.x, x.y, x.z, 0, y.x, y.y, y.z, 0, z.x, z.y, z.z, 0, o.x, o.y, o.z, 1};
    for (int i = 0; i < 16; i++) t.m[i] = m[i];
    return t;
}

}  // namespace

Solid Solid::blend(const std::vector<EdgeRef>& refs, double size, bool chamfer, int segments, uint32_t face, std::string& error) const {
    if (!(size > 1e-9)) { error = chamfer ? "The chamfer's size must be more than 0." : "The fillet's radius must be more than 0."; return *this; }
    auto all = edges();
    Solid cut, add;
    uint32_t piece = 0;
    auto across = [](Vec3 n, const Vec3& dir) { n = n - dir * n.dot(dir); return n.unit(); };
    for (const auto& ref : refs) {
        uint32_t a = std::min(ref.a, ref.b), b = std::max(ref.a, ref.b);
        std::vector<const Edge*> found;
        for (const auto& e : all) if (e.a == a && e.b == b) found.push_back(&e);
        if (found.empty()) { error = "An edge it uses isn't there any more."; continue; }
        if (ref.hasNear && found.size() > 1) {
            const Edge* best = nullptr;
            double bestD = 1e300;
            for (const Edge* e : found) {
                for (size_t k = 0; k + 1 < e->points.size() + (e->closed ? 1 : 0); k++) {
                    Vec3 p = e->points[k], q = e->points[(k + 1) % e->points.size()], d = q - p;
                    double t = std::max(0.0, std::min(1.0, (ref.near - p).dot(d) / std::max(1e-18, d.dot(d))));
                    double dist = (ref.near - (p + d * t)).length();
                    if (dist < bestD) { bestD = dist; best = e; }
                }
            }
            found = {best};
        }
        for (const Edge* e : found) {
            for (const Piece& pc : piecesOf(*e)) {
                uint32_t f = face + piece * 8;
                piece++;
                std::vector<Vec3> pts;
                std::vector<int32_t> groups;
                std::vector<uint8_t> smooth;
                bool concave = false;
                Vec3 c, axis;
                double r = 0;
                Vec3 P0 = pc.pts.front(), P1 = pc.pts.back();
                bool straight = !pc.closed;
                if (straight) {
                    Vec3 d = P1 - P0;
                    double L = d.length();
                    for (const auto& q : pc.pts) {
                        double t = (q - P0).dot(d) / std::max(1e-18, L * L);
                        if ((q - (P0 + d * t)).length() > L * 1e-4 + 1e-5) { straight = false; break; }
                    }
                }
                if (straight) {
                    Vec3 dir = (P1 - P0).unit();
                    double L = (P1 - P0).length();
                    Vec3 nA = across(pc.na.front() + pc.na.back(), dir), nB = across(pc.nb.front() + pc.nb.back(), dir);
                    Vec3 tA = dir.cross(nA).unit(), tB = dir.cross(nB).unit();
                    Vec3 vA = e->insideA - P0, vB = e->insideB - P0;
                    if (tA.dot(vA - dir * vA.dot(dir)) < 0) tA = -tA;
                    if (tB.dot(vB - dir * vB.dot(dir)) < 0) tB = -tB;
                    if (!section(P0, nA, nB, tA, tB, size, chamfer, segments, pts, groups, smooth, concave)) continue;
                    Vec3 u = tA, w = dir.cross(u);
                    Profile prof;
                    for (const auto& q : pts) prof.points.push_back({(q - P0).dot(u), (q - P0).dot(w)});
                    prof.groups = groups;
                    prof.smooth = smooth;
                    double ext = std::max(1e-4, L * 1e-4);
                    Solid tool = Solid::extrude(prof, L + 2 * ext, f).transformed(columns(u, w, dir, P0 - dir * ext));
                    (concave ? add : cut) = (concave ? add : cut).unite(tool);
                } else if (fitCircle(pc.pts, c, axis, r)) {
                    Vec3 X = pc.pts[0] - c;
                    X = (X - axis * X.dot(axis)).unit();
                    Vec3 Y = axis, Z = X.cross(Y);
                    auto angle = [&](const Vec3& q) {
                        Vec3 d = q - c;
                        double t = std::atan2(d.dot(Z), d.dot(X));
                        return t < -1e-9 ? t + 2 * kPi : std::max(0.0, t);
                    };
                    double sweepDeg = 360;
                    if (!pc.closed) {
                        double end = angle(pc.pts.back()), mid = angle(pc.pts[pc.pts.size() / 2]);
                        if (!(mid < end)) { Y = -axis; Z = X.cross(Y); end = angle(pc.pts.back()); }
                        sweepDeg = end * 180 / kPi;
                    }
                    Vec3 P = pc.pts[0], tangent = Z;
                    Vec3 nA = across(pc.na[0], tangent), nB = across(pc.nb[0], tangent);
                    Vec3 tA = tangent.cross(nA).unit(), tB = tangent.cross(nB).unit();
                    auto inPlane = [&](const Vec3& q) {
                        Vec3 d = q - c;
                        double h = d.dot(Y);
                        double rho = (d - Y * h).length();
                        return c + X * rho + Y * h - P;
                    };
                    if (tA.dot(inPlane(e->insideA)) < 0) tA = -tA;
                    if (tB.dot(inPlane(e->insideB)) < 0) tB = -tB;
                    if (!section(P, nA, nB, tA, tB, size, chamfer, segments, pts, groups, smooth, concave)) continue;
                    Profile prof;
                    for (const auto& q : pts) prof.points.push_back({std::max(0.0, (q - c).dot(X)), (q - c).dot(Y)});
                    prof.groups = groups;
                    prof.smooth = smooth;
                    double eps = pc.closed ? 0 : 0.05;
                    Solid tool = Solid::revolve(prof, pc.closed ? 360 : sweepDeg + 2 * eps, segments, f);
                    double e0 = eps * kPi / 180;
                    Transform turn = columns(Vec3(std::cos(e0), 0, -std::sin(e0)), Vec3(0, 1, 0), Vec3(std::sin(e0), 0, std::cos(e0)), Vec3());
                    tool = tool.transformed(turn).transformed(columns(X, Y, Z, c));
                    (concave ? add : cut) = (concave ? add : cut).unite(tool);
                } else {
                    error = chamfer ? "Only straight and round edges can be chamfered." : "Only straight and round edges can be filleted.";
                }
            }
        }
    }
    Solid s = *this;
    if (!cut.polygons.empty()) s = s.subtract(cut);
    if (!add.polygons.empty()) s = s.unite(add);
    return s;
}

}  // namespace mxcad
