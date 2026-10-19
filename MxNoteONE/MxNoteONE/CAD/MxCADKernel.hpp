//
//  MxCADKernel.hpp
//  MxNoteONE
//
//  The geometry kernel (C++): solids as closed sets of planar, convex polygons, each tagged with the face it
//  belongs to. Primitives (box — with rounded edges —, cylinder, cone, sphere, torus), sketch profiles extruded
//  or revolved, meshes brought in from STL / OBJ; union, subtraction and intersection by BSP trees; transforms;
//  triangle meshes for the Metal viewport and mass properties. Swift reaches it through MxCADBridge (Objective-C++).
//

#pragma once

#include <cstdint>
#include <vector>

namespace mxcad {

struct Vec3 {
    double x = 0, y = 0, z = 0;
    Vec3() = default;
    Vec3(double x, double y, double z) : x(x), y(y), z(z) {}
    Vec3 operator+(const Vec3& o) const { return {x + o.x, y + o.y, z + o.z}; }
    Vec3 operator-(const Vec3& o) const { return {x - o.x, y - o.y, z - o.z}; }
    Vec3 operator*(double s) const { return {x * s, y * s, z * s}; }
    Vec3 operator-() const { return {-x, -y, -z}; }
    double dot(const Vec3& o) const { return x * o.x + y * o.y + z * o.z; }
    Vec3 cross(const Vec3& o) const { return {y * o.z - z * o.y, z * o.x - x * o.z, x * o.y - y * o.x}; }
    double length() const;
    Vec3 unit() const;
    Vec3 lerp(const Vec3& o, double t) const { return *this + (o - *this) * t; }
};

struct Vec2 {
    double x = 0, y = 0;
};

/// A corner of a polygon: where it is and the surface's normal there (smooth surfaces share normals).
struct Vertex {
    Vec3 pos, normal;
    Vertex interpolate(const Vertex& o, double t) const { return {pos.lerp(o.pos, t), normal.lerp(o.normal, t)}; }
};

struct Plane {
    Vec3 normal;
    double w = 0;
    void flip() { normal = -normal; w = -w; }
};

struct Polygon {
    std::vector<Vertex> vertices;
    Plane plane;
    /// The face it's part of (feature edges are drawn where faces meet).
    uint32_t face = 0;
    void flip();
};

/// A 4×4 transform, column-major (as simd and Metal keep them).
struct Transform {
    double m[16];
};

struct Mesh {
    std::vector<float> positions;   // x y z per vertex, three vertices per triangle
    std::vector<float> normals;
    std::vector<uint32_t> faces;    // the face of each vertex
};

/// A closed sketch profile: its points, and for each edge (point i to i + 1) a group — an arc's edges share one,
/// becoming one side face — and whether that face is smooth.
struct Profile {
    std::vector<Vec2> points;
    std::vector<int32_t> groups;
    std::vector<uint8_t> smooth;
};

class Solid {
public:
    std::vector<Polygon> polygons;

    /// A box centred on the Z axis, standing on Z = 0, its edges rounded by `radius`.
    static Solid box(double width, double depth, double height, double radius, int segments, uint32_t face);
    static Solid cylinder(double radius, double height, int segments, uint32_t face);
    /// A cone or frustum: bottom and top radii (either may be 0).
    static Solid cone(double bottom, double top, double height, int segments, uint32_t face);
    /// A sphere resting on Z = 0.
    static Solid sphere(double radius, int segments, uint32_t face);
    /// A torus lying on Z = 0 round the Z axis.
    static Solid torus(double major, double minor, int segments, uint32_t face);
    /// A profile (in the XY plane) extruded along Z.
    static Solid extrude(const Profile& profile, double height, uint32_t face);
    /// A profile (x: distance from the axis, y: along it) revolved round the Y axis.
    static Solid revolve(const Profile& profile, double degrees, int segments, uint32_t face);
    /// Triangles (nine floats each), their faces found from flat regions.
    static Solid triangles(const std::vector<float>& xyz, uint32_t face);

    Solid unite(const Solid& other) const;
    Solid subtract(const Solid& other) const;
    Solid intersect(const Solid& other) const;
    Solid transformed(const Transform& t) const;
    /// Turns the polygons round if the solid is inside out.
    void orientOutward();

    Mesh mesh() const;
    double volume() const;
    double area() const;
    /// minX minY minZ maxX maxY maxZ.
    void bounds(double out[6]) const;
};

}  // namespace mxcad
