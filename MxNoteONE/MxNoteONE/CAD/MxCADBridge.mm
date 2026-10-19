//
//  MxCADBridge.mm
//  MxNoteONE
//
//  Objective-C++: MXSolid holds a C++ mxcad::Solid.
//

#import "MxCADBridge.h"
#include "MxCADKernel.hpp"

@implementation MXSolid {
    mxcad::Solid _solid;
    mxcad::Mesh _mesh;
    BOOL _meshed;
    NSData *_positions, *_normals, *_faces;
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
