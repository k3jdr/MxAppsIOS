// The Swift-facing side of the C++ engine. This header stays free of C++ so Swift can import it.
#import <CoreGraphics/CoreGraphics.h>
#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// One image held as its own 8-bit BGR copy, so it doesn't tie up a buffer from the camera's pool.
@interface MXVFrame : NSObject
- (instancetype)initWithPixelBuffer:(CVPixelBufferRef)pixelBuffer;  // 32BGRA
- (nullable instancetype)initWithCGImage:(CGImageRef)image;
- (nullable instancetype)initWithPNGData:(NSData *)data;
@property(nonatomic, readonly) CGSize size;
/// The whole image when rect is CGRectNull.
- (nullable NSData *)PNGDataInRect:(CGRect)rect;
- (nullable CGImageRef)createCGImage CF_RETURNS_RETAINED;
@end

typedef NS_ENUM(NSInteger, MXVOverlayStyle) {
    MXVOverlayStyleInfo,
    MXVOverlayStyleGood,
    MXVOverlayStyleBad,
};

/// A polygon or line in full-image pixels, with an optional label.
@interface MXVOverlay : NSObject
@property(nonatomic, readonly) NSArray<NSValue *> *points;
@property(nonatomic, readonly) BOOL closed;
@property(nonatomic, readonly) NSString *label;
@property(nonatomic, readonly) MXVOverlayStyle style;
@end

@interface MXVMeasure : NSObject
@property(nonatomic, readonly) NSString *name;
@property(nonatomic, readonly) double value;
@property(nonatomic, readonly) NSString *unit;
@end

@interface MXVToolOutput : NSObject
@property(nonatomic, readonly) NSArray<MXVMeasure *> *measures;
@property(nonatomic, readonly) NSArray<NSString *> *texts;
@property(nonatomic, readonly) NSArray<MXVOverlay *> *overlays;
@property(nonatomic, readonly, nullable) NSString *error;
@property(nonatomic, readonly) double elapsedMs;
@end

/// A color trained from a region, for the color tools. The arrays hold three numbers each: R, G, B or H, S, I.
@interface MXVColorReference : NSObject
@property(nonatomic, copy) NSString *name;
@property(nonatomic, copy) NSArray<NSNumber *> *meanRGB, *meanHSI, *spreadRGB, *spreadHSI, *lowRGB, *highRGB, *lowHSI, *highHSI;
@property(nonatomic) double softness, dilation, matteLow, matteHigh, highlight;
@property(nonatomic, copy) NSData *voxels, *histogram;
@end

/// One extracted outline, at full precision, in full-image pixels.
@interface MXVContour : NSObject
@property(nonatomic, readonly) NSArray<NSValue *> *points;
@property(nonatomic, readonly) BOOL closed;
@property(nonatomic, readonly) BOOL hole;
@end

@interface MXVChessboardResult : NSObject
@property(nonatomic, readonly) BOOL found;
@property(nonatomic, readonly) double mmPerPixel;
@end

/// Not thread-safe: use one engine from one queue at a time.
@interface MXVEngine : NSObject
- (instancetype)initWithModelsDirectory:(NSString *)directory;

/// roi is in pixels; CGRectNull means the whole image.
- (MXVToolOutput *)runTool:(NSString *)kind
                     frame:(MXVFrame *)frame
                       roi:(CGRect)roi
                   numbers:(NSDictionary<NSString *, NSNumber *> *)numbers
                   strings:(NSDictionary<NSString *, NSString *> *)strings
                   pattern:(nullable MXVFrame *)pattern
                mmPerPixel:(double)mmPerPixel
                    colors:(NSArray<MXVColorReference *> *)colors;

+ (MXVChessboardResult *)measureChessboardInFrame:(MXVFrame *)frame
                                             cols:(NSInteger)cols
                                             rows:(NSInteger)rows
                                         squareMM:(double)squareMM;

/// Trains a color from a region. roi is in pixels; CGRectNull means the whole image. The settings give the region's shape.
+ (MXVColorReference *)trainColorInFrame:(MXVFrame *)frame
                                     roi:(CGRect)roi
                                 numbers:(NSDictionary<NSString *, NSNumber *> *)numbers;

/// The outlines the Contours tool finds with these settings, for exporting. roi is in pixels; CGRectNull means the whole image.
+ (NSArray<MXVContour *> *)extractContoursInFrame:(MXVFrame *)frame
                                              roi:(CGRect)roi
                                          numbers:(NSDictionary<NSString *, NSNumber *> *)numbers;

/// The versions linked into this build, for the About box and diagnostics.
+ (NSString *)libraryVersions;
@end

NS_ASSUME_NONNULL_END
