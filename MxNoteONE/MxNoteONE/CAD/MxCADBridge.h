//
//  MxCADBridge.h
//  MxNoteONE
//
//  The geometry kernel for Swift: an Objective-C class over the C++ solid (MxCADKernel). Every operation gives
//  a new solid; meshes and measures are worked out once, when first asked for.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

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

- (MXSolid *)unionWith:(MXSolid *)other NS_SWIFT_NAME(union(_:));
- (MXSolid *)subtracting:(MXSolid *)other NS_SWIFT_NAME(subtracting(_:));
- (MXSolid *)intersecting:(MXSolid *)other NS_SWIFT_NAME(intersecting(_:));
/// Moved by a 4×4 matrix (16 doubles, column-major).
- (MXSolid *)transformed:(NSData *)matrix NS_SWIFT_NAME(transformed(_:));

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
