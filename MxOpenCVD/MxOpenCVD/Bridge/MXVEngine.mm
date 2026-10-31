// OpenCV's headers come first: they define names that clash with Objective-C macros otherwise.
#include "../Engine/ColorTools.hpp"
#include "../Engine/Contours.hpp"
#include "../Engine/Engine.hpp"

#include <onnxruntime_cxx_api.h>
#include <opencv2/imgcodecs.hpp>
#include <opencv2/imgproc.hpp>

#import "MXVEngine.h"

#import <AppKit/AppKit.h>
#import <Vision/Vision.h>

#include <chrono>

using namespace mxv;

static NSString *toNS(const std::string &value) {
    // Decoded codes can hold bytes that aren't UTF-8; they shouldn't turn into a nil string.
    NSString *text = [NSString stringWithUTF8String:value.c_str()];
    return text ?: [[NSString alloc] initWithBytes:value.data() length:value.size() encoding:NSISOLatin1StringEncoding];
}

/// An image with its own copy of the pixels, so it outlives the Mat. BGR or BGRA.
static CGImageRef createImage(const cv::Mat &image) {
    cv::Mat bgra;
    if (image.channels() == 3) {
        cv::cvtColor(image, bgra, cv::COLOR_BGR2BGRA);
    } else {
        bgra = image.isContinuous() ? image : image.clone();
    }
    NSData *pixels = [NSData dataWithBytes:bgra.data length:bgra.total() * 4];
    CGDataProviderRef provider = CGDataProviderCreateWithCFData((__bridge CFDataRef)pixels);
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGImageRef result = CGImageCreate(size_t(bgra.cols), size_t(bgra.rows), 8, 32, bgra.step[0], space,
                                      kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Little, provider, nullptr, false,
                                      kCGRenderingIntentDefault);
    CGColorSpaceRelease(space);
    CGDataProviderRelease(provider);
    return result;
}

/// The symbologies for the tool's Look For setting: nil means all of them.
static NSArray<VNBarcodeSymbology> *symbologiesToRead(int codes, VNDetectBarcodesRequest *request) {
    if (codes == 0) {
        return nil;
    }
    NSArray<VNBarcodeSymbology> *qr = @[ VNBarcodeSymbologyQR, VNBarcodeSymbologyMicroQR ];
    NSArray<VNBarcodeSymbology> *otherMatrix = @[ VNBarcodeSymbologyDataMatrix, VNBarcodeSymbologyPDF417, VNBarcodeSymbologyMicroPDF417, VNBarcodeSymbologyAztec ];
    if (codes == 1) {
        return qr;
    }
    if (codes == 3) {
        return otherMatrix;
    }
    NSMutableArray<VNBarcodeSymbology> *bars = [[request supportedSymbologiesAndReturnError:nil] mutableCopy] ?: [NSMutableArray array];
    [bars removeObjectsInArray:qr];
    [bars removeObjectsInArray:otherMatrix];
    return bars;
}

/// The code-reading tool. This one uses Apple Vision rather than OpenCV, which reads only QR and EAN/UPC, so it lives
/// here rather than in the engine, which is free of Apple frameworks.
static ToolOutput readCodes(const cv::Mat &bgr, const ToolInput &input) {
    ToolOutput out;
    auto started = std::chrono::steady_clock::now();
    cv::Rect full(0, 0, bgr.cols, bgr.rows);
    cv::Rect roi = input.roi.empty() ? full : (input.roi & full);
    if (roi.width < 2 || roi.height < 2) {
        out.error = "The region of interest is outside the image.";
        return out;
    }

    VNDetectBarcodesRequest *request = [[VNDetectBarcodesRequest alloc] init];
    NSArray<VNBarcodeSymbology> *symbologies = symbologiesToRead(int(input.number("codes", 0)), request);
    if (symbologies) {
        request.symbologies = symbologies;
    }
    CGImageRef image = createImage(bgr(roi));
    VNImageRequestHandler *handler = [[VNImageRequestHandler alloc] initWithCGImage:image options:@{}];
    NSError *error = nil;
    BOOL ran = [handler performRequests:@[ request ] error:&error];
    CGImageRelease(image);
    if (!ran) {
        out.error = std::string("Apple Vision: ") + error.localizedDescription.UTF8String;
        return out;
    }

    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    for (VNBarcodeObservation *code in request.results) {
        NSString *text = code.payloadStringValue;
        if (!text) {
            // A code holding binary data has no string form, and its text can still be checked as hex.
            NSMutableString *hex = [NSMutableString string];
            const unsigned char *bytes = (const unsigned char *)code.payloadData.bytes;
            for (NSUInteger i = 0; i < code.payloadData.length; i++) {
                [hex appendFormat:@"%02X", bytes[i]];
            }
            text = hex;
        }
        if (text.length == 0 || [seen containsObject:text]) {
            continue;
        }
        [seen addObject:text];

        Overlay overlay;
        overlay.style = OverlayStyle::Good;
        NSString *type = [code.symbology stringByReplacingOccurrencesOfString:@"VNBarcodeSymbology" withString:@""];
        overlay.label = [NSString stringWithFormat:@"%@ (%@)", text, type].UTF8String;
        // Vision's points run from 0 to 1 with the origin at the bottom left.
        for (CGPoint corner : {code.topLeft, code.topRight, code.bottomRight, code.bottomLeft}) {
            overlay.points.emplace_back(float(roi.x + corner.x * roi.width), float(roi.y + (1 - corner.y) * roi.height));
        }
        out.overlays.push_back(std::move(overlay));
        out.texts.push_back(text.UTF8String);
    }
    out.measures.push_back({"count", double(out.texts.size()), ""});
    out.elapsedMs = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - started).count();
    return out;
}

@implementation MXVFrame {
@public
    cv::Mat _bgr;
}

- (instancetype)initWithPixelBuffer:(CVPixelBufferRef)pixelBuffer {
    if ((self = [super init])) {
        CVPixelBufferLockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);
        cv::Mat bgra(int(CVPixelBufferGetHeight(pixelBuffer)), int(CVPixelBufferGetWidth(pixelBuffer)), CV_8UC4,
                     CVPixelBufferGetBaseAddress(pixelBuffer), CVPixelBufferGetBytesPerRow(pixelBuffer));
        cv::cvtColor(bgra, _bgr, cv::COLOR_BGRA2BGR);
        CVPixelBufferUnlockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);
    }
    return self;
}

- (instancetype)initWithCGImage:(CGImageRef)image {
    size_t width = CGImageGetWidth(image);
    size_t height = CGImageGetHeight(image);
    if (width == 0 || height == 0 || !(self = [super init])) {
        return nil;
    }
    cv::Mat bgra(int(height), int(width), CV_8UC4);
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef context = CGBitmapContextCreate(bgra.data, width, height, 8, bgra.step[0], space,
                                                 kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
    CGColorSpaceRelease(space);
    if (!context) {
        return nil;
    }
    CGContextSetFillColorWithColor(context, CGColorGetConstantColor(kCGColorWhite));
    CGContextFillRect(context, CGRectMake(0, 0, width, height));
    CGContextDrawImage(context, CGRectMake(0, 0, width, height), image);
    CGContextRelease(context);
    cv::cvtColor(bgra, _bgr, cv::COLOR_BGRA2BGR);
    return self;
}

- (instancetype)initWithPNGData:(NSData *)data {
    cv::Mat encoded(1, int(data.length), CV_8U, const_cast<void *>(data.bytes));
    cv::Mat decoded = cv::imdecode(encoded, cv::IMREAD_COLOR);
    if (decoded.empty() || !(self = [super init])) {
        return nil;
    }
    _bgr = decoded;
    return self;
}

- (CGSize)size {
    return CGSizeMake(_bgr.cols, _bgr.rows);
}

- (NSData *)PNGDataInRect:(CGRect)rect {
    cv::Rect full(0, 0, _bgr.cols, _bgr.rows);
    cv::Rect area = CGRectIsNull(rect) ? full : (cv::Rect(int(rect.origin.x), int(rect.origin.y), int(rect.size.width), int(rect.size.height)) & full);
    if (area.empty()) {
        return nil;
    }
    std::vector<uchar> bytes;
    if (!cv::imencode(".png", _bgr(area), bytes)) {
        return nil;
    }
    return [NSData dataWithBytes:bytes.data() length:bytes.size()];
}

- (CGImageRef)createCGImage {
    return createImage(_bgr);
}

@end

@implementation MXVOverlay
- (instancetype)initWithOverlay:(const Overlay &)overlay {
    if ((self = [super init])) {
        NSMutableArray<NSValue *> *points = [NSMutableArray arrayWithCapacity:overlay.points.size()];
        for (const auto &p : overlay.points) {
            [points addObject:[NSValue valueWithPoint:NSMakePoint(p.x, p.y)]];
        }
        _points = points;
        _closed = overlay.closed;
        _label = toNS(overlay.label);
        _style = overlay.style == OverlayStyle::Good ? MXVOverlayStyleGood
               : overlay.style == OverlayStyle::Bad  ? MXVOverlayStyleBad
                                                     : MXVOverlayStyleInfo;
    }
    return self;
}
@end

@implementation MXVMeasure
- (instancetype)initWithMeasure:(const Measure &)measure {
    if ((self = [super init])) {
        _name = toNS(measure.name);
        _value = measure.value;
        _unit = toNS(measure.unit);
    }
    return self;
}
@end

@implementation MXVToolOutput
- (instancetype)initWithOutput:(const ToolOutput &)output {
    if ((self = [super init])) {
        NSMutableArray *measures = [NSMutableArray array];
        for (const auto &m : output.measures) {
            [measures addObject:[[MXVMeasure alloc] initWithMeasure:m]];
        }
        NSMutableArray *texts = [NSMutableArray array];
        for (const auto &t : output.texts) {
            [texts addObject:toNS(t)];
        }
        NSMutableArray *overlays = [NSMutableArray array];
        for (const auto &o : output.overlays) {
            [overlays addObject:[[MXVOverlay alloc] initWithOverlay:o]];
        }
        _measures = measures;
        _texts = texts;
        _overlays = overlays;
        _error = output.error.empty() ? nil : toNS(output.error);
        _elapsedMs = output.elapsedMs;
    }
    return self;
}
@end

static NSArray<NSNumber *> *toArray(const std::array<double, 3> &values) {
    return @[ @(values[0]), @(values[1]), @(values[2]) ];
}

static void fromArray(NSArray<NSNumber *> *numbers, std::array<double, 3> &values) {
    for (NSUInteger i = 0; i < 3 && i < numbers.count; i++) {
        values[i] = numbers[i].doubleValue;
    }
}

@implementation MXVColorReference
@end

static MXVColorReference *toObject(const ColorReference &color) {
    MXVColorReference *object = [[MXVColorReference alloc] init];
    object.name = toNS(color.name);
    object.meanRGB = toArray(color.meanRGB);
    object.meanHSI = toArray(color.meanHSI);
    object.spreadRGB = toArray(color.spreadRGB);
    object.spreadHSI = toArray(color.spreadHSI);
    object.lowRGB = toArray(color.lowRGB);
    object.highRGB = toArray(color.highRGB);
    object.lowHSI = toArray(color.lowHSI);
    object.highHSI = toArray(color.highHSI);
    object.softness = color.softness;
    object.dilation = color.dilation;
    object.matteLow = color.matteLow;
    object.matteHigh = color.matteHigh;
    object.highlight = color.highlight;
    object.voxels = [NSData dataWithBytes:color.voxels.data() length:color.voxels.size() * sizeof(uint32_t)];
    object.histogram = [NSData dataWithBytes:color.histogram.data() length:color.histogram.size() * sizeof(float)];
    return object;
}

static ColorReference fromObject(MXVColorReference *object) {
    ColorReference color;
    color.name = object.name.UTF8String ?: "";
    fromArray(object.meanRGB, color.meanRGB);
    fromArray(object.meanHSI, color.meanHSI);
    fromArray(object.spreadRGB, color.spreadRGB);
    fromArray(object.spreadHSI, color.spreadHSI);
    fromArray(object.lowRGB, color.lowRGB);
    fromArray(object.highRGB, color.highRGB);
    fromArray(object.lowHSI, color.lowHSI);
    fromArray(object.highHSI, color.highHSI);
    color.softness = object.softness;
    color.dilation = object.dilation;
    color.matteLow = object.matteLow;
    color.matteHigh = object.matteHigh;
    color.highlight = object.highlight;
    const uint32_t *voxels = (const uint32_t *)object.voxels.bytes;
    color.voxels.assign(voxels, voxels + object.voxels.length / sizeof(uint32_t));
    const float *histogram = (const float *)object.histogram.bytes;
    color.histogram.assign(histogram, histogram + object.histogram.length / sizeof(float));
    return color;
}

@implementation MXVContour
- (instancetype)initWithPoints:(NSArray<NSValue *> *)points closed:(BOOL)closed hole:(BOOL)hole {
    if ((self = [super init])) {
        _points = points;
        _closed = closed;
        _hole = hole;
    }
    return self;
}
@end

@implementation MXVChessboardResult
- (instancetype)initWithScale:(const ChessboardScale &)scale {
    if ((self = [super init])) {
        _found = scale.found;
        _mmPerPixel = scale.mmPerPixel;
    }
    return self;
}
@end

@implementation MXVEngine {
    std::unique_ptr<Engine> _engine;
}

- (instancetype)initWithModelsDirectory:(NSString *)directory {
    if ((self = [super init])) {
        _engine = std::make_unique<Engine>(directory.UTF8String);
    }
    return self;
}

- (MXVToolOutput *)runTool:(NSString *)kind
                     frame:(MXVFrame *)frame
                       roi:(CGRect)roi
                   numbers:(NSDictionary<NSString *, NSNumber *> *)numbers
                   strings:(NSDictionary<NSString *, NSString *> *)strings
                   pattern:(MXVFrame *)pattern
                mmPerPixel:(double)mmPerPixel
                    colors:(NSArray<MXVColorReference *> *)colors {
    ToolInput input;
    if (!CGRectIsNull(roi)) {
        input.roi = cv::Rect(int(roi.origin.x), int(roi.origin.y), int(roi.size.width), int(roi.size.height));
    }
    for (NSString *key in numbers) {
        input.numbers[key.UTF8String] = numbers[key].doubleValue;
    }
    for (NSString *key in strings) {
        input.strings[key.UTF8String] = strings[key].UTF8String;
    }
    if (pattern) {
        input.templ = pattern->_bgr;
    }
    input.mmPerPixel = mmPerPixel;
    for (MXVColorReference *color in colors) {
        input.colors.push_back(fromObject(color));
    }
    if ([kind isEqualToString:@"code"]) {
        return [[MXVToolOutput alloc] initWithOutput:readCodes(frame->_bgr, input)];
    }
    return [[MXVToolOutput alloc] initWithOutput:_engine->run(kind.UTF8String, frame->_bgr, input)];
}

+ (MXVChessboardResult *)measureChessboardInFrame:(MXVFrame *)frame cols:(NSInteger)cols rows:(NSInteger)rows squareMM:(double)squareMM {
    ChessboardScale scale;
    try {
        scale = measureChessboard(frame->_bgr, int(cols), int(rows), squareMM);
    } catch (const cv::Exception &) {
        // Treated as not found: a board size OpenCV rejects can't match anything in the image anyway.
    }
    return [[MXVChessboardResult alloc] initWithScale:scale];
}

+ (MXVColorReference *)trainColorInFrame:(MXVFrame *)frame roi:(CGRect)roi numbers:(NSDictionary<NSString *, NSNumber *> *)numbers {
    ToolInput input;
    for (NSString *key in numbers) {
        input.numbers[key.UTF8String] = numbers[key].doubleValue;
    }
    cv::Rect full(0, 0, frame->_bgr.cols, frame->_bgr.rows);
    cv::Rect area = CGRectIsNull(roi) ? full : (cv::Rect(int(roi.origin.x), int(roi.origin.y), int(roi.size.width), int(roi.size.height)) & full);
    if (area.width < 1 || area.height < 1) {
        area = full;
    }
    return toObject(trainColor(frame->_bgr, area, input));
}

+ (NSArray<MXVContour *> *)extractContoursInFrame:(MXVFrame *)frame roi:(CGRect)roi numbers:(NSDictionary<NSString *, NSNumber *> *)numbers {
    ToolInput input;
    for (NSString *key in numbers) {
        input.numbers[key.UTF8String] = numbers[key].doubleValue;
    }
    cv::Rect full(0, 0, frame->_bgr.cols, frame->_bgr.rows);
    cv::Rect area = CGRectIsNull(roi) ? full : (cv::Rect(int(roi.origin.x), int(roi.origin.y), int(roi.size.width), int(roi.size.height)) & full);
    NSMutableArray<MXVContour *> *result = [NSMutableArray array];
    if (area.width < 2 || area.height < 2) {
        return result;
    }
    cv::Mat gray;
    cv::cvtColor(frame->_bgr(area), gray, cv::COLOR_BGR2GRAY);
    try {
        for (const Contour &contour : extractContours(gray, input)) {
            NSMutableArray<NSValue *> *points = [NSMutableArray arrayWithCapacity:contour.points.size()];
            for (const auto &p : contour.points) {
                [points addObject:[NSValue valueWithPoint:NSMakePoint(p.x + area.x, p.y + area.y)]];
            }
            [result addObject:[[MXVContour alloc] initWithPoints:points closed:contour.closed hole:contour.hole]];
        }
    } catch (const cv::Exception &) {
        // Nothing to export: settings OpenCV rejects can't produce outlines.
    }
    return result;
}

+ (NSString *)libraryVersions {
    return [NSString stringWithFormat:@"OpenCV %s, ONNX Runtime %s", CV_VERSION, Ort::GetVersionString().c_str()];
}

@end
