#!/bin/bash
# Builds and runs the engine tests (no camera needed). Needs scripts/bootstrap.sh to have run.
# The app's own logic is tested by the built app: MxOpenCVD.app/Contents/MacOS/MxOpenCVD --self-test
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/build/tests"
mkdir -p "$OUT"
V="$ROOT/Vendor"
clang++ -std=gnu++20 -O1 -g -Wall -Wextra \
    -isystem "$V/opencv/include/opencv4" -isystem "$V/onnxruntime/include" \
    "$ROOT/Tests/engine_tests.cpp" "$ROOT"/MxOpenCVD/Engine/*.cpp \
    -L"$V/opencv/lib" -L"$V/opencv/lib/opencv4/3rdparty" -L"$V/onnxruntime/lib" \
    -lopencv_objdetect -lopencv_calib3d -lopencv_features2d -lopencv_flann -lopencv_imgcodecs -lopencv_imgproc -lopencv_core \
    -llibjpeg-turbo -llibpng -lzlib -ltegra_hal -lonnxruntime \
    -framework Accelerate -Wl,-rpath,"$V/onnxruntime/lib" \
    -o "$OUT/engine_tests"
"$OUT/engine_tests" "$ROOT/Models" "$ROOT/Tests/fixtures" "$@"
