//
//  MxCADBridge.h
//  MxNoteONE
//
//  The geometry kernel for Swift: an Objective-C class over the C++ solid (MxCADKernel). Every operation gives
//  a new solid; meshes and measures are worked out once, when first asked for.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// An edge where two faces meet: the faces either side (a < b) and its points (x y z doubles), in order.
@interface MXEdge : NSObject
@property (readonly) uint32_t faceA;
@property (readonly) uint32_t faceB;
@property (readonly) BOOL closed;
@property (readonly) NSData *points;
@end

@interface MXSolid : NSObject

+ (MXSolid *)empty;
+ (MXSolid *)boxWidth:(double)width depth:(double)depth height:(double)height radius:(double)radius
             segments:(NSInteger)segments face:(uint32_t)face NS_SWIFT_NAME(box(width:depth:height:radius:segments:face:));
+ (MXSolid *)coneBottom:(double)bottom top:(double)top height:(double)height segments:(NSInteger)segments
                   face:(uint32_t)face NS_SWIFT_NAME(cone(bottom:top:height:segments:face:));
+ (MXSolid *)sphereRadius:(double)radius segments:(NSInteger)segments face:(uint32_t)face NS_SWIFT_NAME(sphere(radius:segments:face:));
+ (MXSolid *)torusMajor:(double)major minor:(double)minor segments:(NSInteger)segments
                   face:(uint32_t)face NS_SWIFT_NAME(torus(major:minor:segments:face:));
/// A closed profile in the XY plane — `points` x y pairs (doubles), `groups` an int32 and `smooth` a byte for
/// each edge — extruded along Z.
+ (MXSolid *)extrudePoints:(NSData *)points groups:(NSData *)groups smooth:(NSData *)smooth height:(double)height
                      face:(uint32_t)face NS_SWIFT_NAME(extrude(points:groups:smooth:height:face:));
/// A profile (x: distance from the axis, y: along it) revolved round the Y axis.
+ (MXSolid *)revolvePoints:(NSData *)points groups:(NSData *)groups smooth:(NSData *)smooth degrees:(double)degrees
                  segments:(NSInteger)segments face:(uint32_t)face NS_SWIFT_NAME(revolve(points:groups:smooth:degrees:segments:face:));
/// Triangles: nine floats each.
+ (MXSolid *)triangles:(NSData *)xyz face:(uint32_t)face NS_SWIFT_NAME(triangles(_:face:));
/// Triangles with a face number each (uint32) and, if given, nine floats of normals each (an imported B-rep).
+ (MXSolid *)triangles:(NSData *)xyz faces:(NSData *)faces normals:(nullable NSData *)normals face:(uint32_t)face
    NS_SWIFT_NAME(triangles(_:faces:normals:face:));
/// Closed rings of points joined one to the next: `points` holds `count` rings of the same number of points (x y z
/// doubles); capped at both ends unless `closed`. `groups` (int32) and `smooth` (bytes) are the profile edges'.
+ (MXSolid *)sweepRings:(NSData *)points count:(NSInteger)count groups:(NSData *)groups smooth:(NSData *)smooth
                 closed:(BOOL)closed face:(uint32_t)face NS_SWIFT_NAME(sweep(rings:count:groups:smooth:closed:face:));

- (MXSolid *)unionWith:(MXSolid *)other NS_SWIFT_NAME(union(_:));
- (MXSolid *)subtracting:(MXSolid *)other NS_SWIFT_NAME(subtracting(_:));
- (MXSolid *)intersecting:(MXSolid *)other NS_SWIFT_NAME(intersecting(_:));
/// Moved by a 4×4 matrix (16 doubles, column-major).
- (MXSolid *)transformed:(NSData *)matrix NS_SWIFT_NAME(transformed(_:));
/// Fillets (or chamfers) edges given as six doubles each — face a, face b, whether a point near the edge follows,
/// and that point. `error` is set when an edge couldn't be done (the rest still are).
- (MXSolid *)blendEdges:(NSData *)refs size:(double)size chamfer:(BOOL)chamfer segments:(NSInteger)segments
                   face:(uint32_t)face error:(NSString * _Nullable * _Nullable)error NS_SWIFT_NAME(blend(edges:size:chamfer:segments:face:error:));

/// The edges where different faces meet (worked out once).
@property (readonly) NSArray<MXEdge *> *edges;

@property (readonly) NSInteger polygonCount;
@property (readonly) double volume;
@property (readonly) double area;
/// minX minY minZ maxX maxY maxZ (doubles).
@property (readonly) NSData *bounds;
/// The triangles, three vertices each: positions and normals (three floats a vertex) and faces (a uint32 a vertex).
@property (readonly) NSData *meshPositions;
@property (readonly) NSData *meshNormals;
@property (readonly) NSData *meshFaces;

@end

NS_ASSUME_NONNULL_END
