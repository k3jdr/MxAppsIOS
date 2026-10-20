//
//  MxCADBridge.mm
//  MxNoteONE
//
//  Objective-C++: MXSolid holds a C++ mxcad::Solid.
//

#import "MxCADBridge.h"
#include "MxCADKernel.hpp"

@implementation MXEdge {
@public
    uint32_t _faceA, _faceB;
    BOOL _closed;
    NSData *_points;
}
- (uint32_t)faceA { return _faceA; }
- (uint32_t)faceB { return _faceB; }
- (BOOL)closed { return _closed; }
- (NSData *)points { return _points; }
@end

@implementation MXSolid {
    mxcad::Solid _solid;
    mxcad::Mesh _mesh;
    BOOL _meshed;
    NSData *_positions, *_normals, *_faces;
    NSArray<MXEdge *> *_edges;
}

+ (MXSolid *)with:(mxcad::Solid)solid {
    MXSolid *s = [[MXSolid alloc] init];
    s->_solid = std::move(solid);
    return s;
}

+ (MXSolid *)empty { return [MXSolid with:mxcad::Solid()]; }

+ (MXSolid *)boxWidth:(double)width depth:(double)depth height:(double)height radius:(double)radius segments:(NSInteger)segments face:(uint32_t)face {
    return [MXSolid with:mxcad::Solid::box(width, depth, height, radius, int(segments), face)];
}

+ (MXSolid *)coneBottom:(double)bottom top:(double)top height:(double)height segments:(NSInteger)segments face:(uint32_t)face {
    return [MXSolid with:mxcad::Solid::cone(bottom, top, height, int(segments), face)];
}

+ (MXSolid *)sphereRadius:(double)radius segments:(NSInteger)segments face:(uint32_t)face {
    return [MXSolid with:mxcad::Solid::sphere(radius, int(segments), face)];
}

+ (MXSolid *)torusMajor:(double)major minor:(double)minor segments:(NSInteger)segments face:(uint32_t)face {
    return [MXSolid with:mxcad::Solid::torus(major, minor, int(segments), face)];
}

static mxcad::Profile profile(NSData *points, NSData *groups, NSData *smooth) {
    mxcad::Profile p;
    const double *xy = (const double *)points.bytes;
    NSUInteger n = points.length / (2 * sizeof(double));
    for (NSUInteger i = 0; i < n; i++) p.points.push_back({xy[2 * i], xy[2 * i + 1]});
    const int32_t *g = (const int32_t *)groups.bytes;
    for (NSUInteger i = 0; i < groups.length / sizeof(int32_t); i++) p.groups.push_back(g[i]);
    const uint8_t *s = (const uint8_t *)smooth.bytes;
    for (NSUInteger i = 0; i < smooth.length; i++) p.smooth.push_back(s[i]);
    return p;
}

+ (MXSolid *)extrudePoints:(NSData *)points groups:(NSData *)groups smooth:(NSData *)smooth height:(double)height face:(uint32_t)face {
    return [MXSolid with:mxcad::Solid::extrude(profile(points, groups, smooth), height, face)];
}

+ (MXSolid *)revolvePoints:(NSData *)points groups:(NSData *)groups smooth:(NSData *)smooth degrees:(double)degrees segments:(NSInteger)segments face:(uint32_t)face {
    return [MXSolid with:mxcad::Solid::revolve(profile(points, groups, smooth), degrees, int(segments), face)];
}

+ (MXSolid *)triangles:(NSData *)xyz face:(uint32_t)face {
    const float *f = (const float *)xyz.bytes;
    std::vector<float> v(f, f + xyz.length / sizeof(float));
    return [MXSolid with:mxcad::Solid::triangles(v, face)];
}

+ (MXSolid *)triangles:(NSData *)xyz faces:(NSData *)faces normals:(NSData *)normals face:(uint32_t)face {
    const float *f = (const float *)xyz.bytes;
    std::vector<float> v(f, f + xyz.length / sizeof(float));
    const uint32_t *fs = (const uint32_t *)faces.bytes;
    std::vector<uint32_t> faceList(fs, fs + faces.length / sizeof(uint32_t));
    std::vector<float> n;
    if (normals.length > 0) {
        const float *nf = (const float *)normals.bytes;
        n.assign(nf, nf + normals.length / sizeof(float));
    }
    return [MXSolid with:mxcad::Solid::triangles(v, face, &faceList, n.empty() ? nullptr : &n)];
}

+ (MXSolid *)sweepRings:(NSData *)points count:(NSInteger)count groups:(NSData *)groups smooth:(NSData *)smooth closed:(BOOL)closed face:(uint32_t)face {
    const double *p = (const double *)points.bytes;
    NSUInteger total = points.length / (3 * sizeof(double));
    if (count < 2 || total % NSUInteger(count) != 0) return [MXSolid empty];
    NSUInteger n = total / NSUInteger(count);
    std::vector<std::vector<mxcad::Vec3>> rings; rings.resize(size_t(count));
    for (NSUInteger r = 0; r < NSUInteger(count); r++)
        for (NSUInteger k = 0; k < n; k++) {
            const double *q = p + 3 * (r * n + k);
            rings[r].push_back({q[0], q[1], q[2]});
        }
    const int32_t *g = (const int32_t *)groups.bytes;
    std::vector<int32_t> gs(g, g + groups.length / sizeof(int32_t));
    const uint8_t *s = (const uint8_t *)smooth.bytes;
    std::vector<uint8_t> ss(s, s + smooth.length);
    return [MXSolid with:mxcad::Solid::sweep(rings, gs, ss, closed, face)];
}

- (MXSolid *)blendEdges:(NSData *)refs size:(double)size chamfer:(BOOL)chamfer segments:(NSInteger)segments face:(uint32_t)face error:(NSString **)error {
    const double *d = (const double *)refs.bytes;
    std::vector<mxcad::EdgeRef> list;
    for (NSUInteger i = 0; i + 6 <= refs.length / sizeof(double); i += 6) {
        mxcad::EdgeRef r;
        r.a = uint32_t(d[i]);
        r.b = uint32_t(d[i + 1]);
        r.hasNear = d[i + 2] != 0;
        r.near = {d[i + 3], d[i + 4], d[i + 5]};
        list.push_back(r);
    }
    std::string problem;
    mxcad::Solid s = _solid.blend(list, size, chamfer, int(segments), face, problem);
    if (error) *error = problem.empty() ? nil : [NSString stringWithUTF8String:problem.c_str()];
    return [MXSolid with:std::move(s)];
}

- (NSArray<MXEdge *> *)edges {
    if (_edges) return _edges;
    NSMutableArray<MXEdge *> *out = [NSMutableArray array];
    for (const auto& e : _solid.edges()) {
        MXEdge *m = [[MXEdge alloc] init];
        m->_faceA = e.a;
        m->_faceB = e.b;
        m->_closed = e.closed;
        std::vector<double> xyz;
        for (const auto& p : e.points) { xyz.push_back(p.x); xyz.push_back(p.y); xyz.push_back(p.z); }
        m->_points = [NSData dataWithBytes:xyz.data() length:xyz.size() * sizeof(double)];
        [out addObject:m];
    }
    _edges = out;
    return _edges;
}

- (MXSolid *)unionWith:(MXSolid *)other { return [MXSolid with:_solid.unite(other->_solid)]; }
- (MXSolid *)subtracting:(MXSolid *)other { return [MXSolid with:_solid.subtract(other->_solid)]; }
- (MXSolid *)intersecting:(MXSolid *)other { return [MXSolid with:_solid.intersect(other->_solid)]; }

- (MXSolid *)transformed:(NSData *)matrix {
    mxcad::Transform t;
    const double *m = (const double *)matrix.bytes;
    for (int i = 0; i < 16; i++) t.m[i] = matrix.length >= 16 * sizeof(double) ? m[i] : (i % 5 == 0 ? 1 : 0);
    return [MXSolid with:_solid.transformed(t)];
}

- (NSInteger)polygonCount { return NSInteger(_solid.polygons.size()); }
- (double)volume { return _solid.volume(); }
- (double)area { return _solid.area(); }

- (NSData *)bounds {
    double b[6];
    _solid.bounds(b);
    return [NSData dataWithBytes:b length:sizeof(b)];
}

- (void)makeMesh {
    if (_meshed) return;
    _mesh = _solid.mesh();
    _positions = [NSData dataWithBytes:_mesh.positions.data() length:_mesh.positions.size() * sizeof(float)];
    _normals = [NSData dataWithBytes:_mesh.normals.data() length:_mesh.normals.size() * sizeof(float)];
    _faces = [NSData dataWithBytes:_mesh.faces.data() length:_mesh.faces.size() * sizeof(uint32_t)];
    _mesh = mxcad::Mesh();
    _meshed = YES;
}

- (NSData *)meshPositions { [self makeMesh]; return _positions; }
- (NSData *)meshNormals { [self makeMesh]; return _normals; }
- (NSData *)meshFaces { [self makeMesh]; return _faces; }

@end
