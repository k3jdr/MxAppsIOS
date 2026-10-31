#!/bin/bash
# Fetch and build the native libraries into Vendor/ (git-ignored): a static OpenCV and the official
# ONNX Runtime dylib, both pinned by version and SHA-256. Run once after cloning, and again after a
# version bump. Safe to re-run: finished steps are skipped.
set -euo pipefail

OPENCV_VERSION=4.14.0
OPENCV_SHA256=ee8fb9b30eb60850431b4656447080e3737b56e45719c92b67f245950609f86e
ORT_VERSION=1.31.1
ORT_SHA256=2e1344a1926ee50eb25b38153cb6992c3567515aef0e677a1a520a1798896d6f
DEPLOYMENT_TARGET=26.6

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR="$ROOT/Vendor"
DOWNLOADS="$VENDOR/downloads"
mkdir -p "$DOWNLOADS"

fetch() { # url file sha256
    local url="$1" file="$DOWNLOADS/$2" sha="$3"
    if [ ! -f "$file" ] || ! echo "$sha  $file" | shasum -a 256 -c --status; then
        echo "Downloading $2"
        curl -fL --retry 3 -o "$file" "$url"
    fi
    echo "$sha  $file" | shasum -a 256 -c --quiet
}

# ONNX Runtime
if [ ! -f "$VENDOR/onnxruntime/lib/libonnxruntime.$ORT_VERSION.dylib" ]; then
    fetch "https://github.com/microsoft/onnxruntime/releases/download/v$ORT_VERSION/onnxruntime-osx-arm64-$ORT_VERSION.tgz" \
        "onnxruntime-$ORT_VERSION.tgz" "$ORT_SHA256"
    rm -rf "$VENDOR/onnxruntime"
    mkdir -p "$VENDOR/onnxruntime"
    tar xzf "$DOWNLOADS/onnxruntime-$ORT_VERSION.tgz" -C "$VENDOR/onnxruntime" --strip-components=1 \
        --exclude='*.dSYM' --exclude='*/testdata'
    echo "ONNX Runtime $ORT_VERSION ready"
fi

# OpenCV: only the modules the engine uses, static, with nothing taken from Homebrew
if [ ! -f "$VENDOR/opencv/lib/libopencv_core.a" ]; then
    fetch "https://github.com/opencv/opencv/archive/refs/tags/$OPENCV_VERSION.tar.gz" \
        "opencv-$OPENCV_VERSION.tar.gz" "$OPENCV_SHA256"
    SRC="$VENDOR/build/opencv-$OPENCV_VERSION"
    rm -rf "$VENDOR/build"
    mkdir -p "$VENDOR/build"
    tar xzf "$DOWNLOADS/opencv-$OPENCV_VERSION.tar.gz" -C "$VENDOR/build"
    cmake -S "$SRC" -B "$VENDOR/build/out" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="$VENDOR/opencv" \
        -DCMAKE_OSX_ARCHITECTURES=arm64 \
        -DCMAKE_OSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET" \
        -DCMAKE_FIND_FRAMEWORK=NEVER \
        -DBUILD_LIST=core,imgproc,imgcodecs,calib3d,features2d,flann,objdetect \
        -DBUILD_SHARED_LIBS=OFF \
        -DBUILD_TESTS=OFF -DBUILD_PERF_TESTS=OFF -DBUILD_EXAMPLES=OFF -DBUILD_DOCS=OFF \
        -DBUILD_opencv_apps=OFF -DBUILD_JAVA=OFF -DBUILD_opencv_python3=OFF \
        -DBUILD_ZLIB=ON -DBUILD_PNG=ON -DBUILD_JPEG=ON \
        -DWITH_TIFF=OFF -DWITH_WEBP=OFF -DWITH_OPENEXR=OFF -DWITH_OPENJPEG=OFF -DWITH_JASPER=OFF \
        -DWITH_AVIF=OFF -DWITH_JPEGXL=OFF -DWITH_IMGCODEC_HDR=OFF -DWITH_IMGCODEC_SUNRASTER=OFF \
        -DWITH_IMGCODEC_PXM=OFF -DWITH_IMGCODEC_PFM=OFF -DWITH_IMGCODEC_GIF=OFF \
        -DWITH_FFMPEG=OFF -DWITH_GSTREAMER=OFF -DWITH_AVFOUNDATION=OFF -DWITH_V4L=OFF \
        -DWITH_OPENCL=OFF -DWITH_IPP=OFF -DWITH_ITT=OFF -DWITH_QT=OFF -DWITH_LAPACK=OFF \
        -DWITH_PROTOBUF=OFF -DWITH_ADE=OFF -DWITH_KLEIDICV=OFF -DWITH_FLATBUFFERS=OFF \
        -DCV_TRACE=OFF -DOPENCV_GENERATE_PKGCONFIG=OFF
    cmake --build "$VENDOR/build/out" --target install -j "$(sysctl -n hw.ncpu)"
    rm -rf "$VENDOR/build"
    echo "OpenCV $OPENCV_VERSION ready"
fi

echo "Vendor libraries are ready in $VENDOR"
