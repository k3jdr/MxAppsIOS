#!/bin/bash
# Rebuilds Models/ from PaddleOCR's official models. Only needed to change models: the results are committed.
# Takes a Python 3.9 or later. Everything it downloads stays in a temporary folder.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
BASE=https://paddle-model-ecology.bj.bcebos.com/paddlex/official_inference_model/paddle3.0.0

python3 -m venv "$WORK/venv"
"$WORK/venv/bin/pip" -q install paddlepaddle==3.3.1 paddle2onnx==2.1.0 onnx==1.17.0 packaging pyyaml

convert() { # model output sha256
    # This server is slow and often drops the connection, so keep resuming.
    curl -fsSL --retry 20 --retry-delay 3 --retry-all-errors -C - -o "$WORK/$1.tar" "$BASE/$1_infer.tar"
    echo "$3  $WORK/$1.tar" | shasum -a 256 -c --quiet
    tar xf "$WORK/$1.tar" -C "$WORK"
    "$WORK/venv/bin/paddle2onnx" --model_dir "$WORK/$1_infer" --model_filename inference.json \
        --params_filename inference.pdiparams --save_file "$ROOT/Models/$2" --opset_version 13
}

mkdir -p "$ROOT/Models"
convert PP-OCRv5_mobile_det ppocrv5_mobile_det.onnx 50446e5d01ac2a73d5319c89513281f6578414c888c602f9af13f93feefffc58
convert en_PP-OCRv5_mobile_rec en_ppocrv5_mobile_rec.onnx e595b4cf2ffad19fbb5a61ba345d63939577a3ab8717b6e5995642590c9101b4
convert PP-LCNet_x0_25_textline_ori pplcnet_x025_textline_ori.onnx 268d9aea61461c3d4a5a32752e5b920e8af2ee0a002362f6ba5cd39638fa2c3a

# The recognizer's alphabet is stored in its config; the engine reads it from a plain file.
"$WORK/venv/bin/python" -I - "$WORK/en_PP-OCRv5_mobile_rec_infer/inference.yml" "$ROOT/Models/en_ppocrv5_mobile_rec_dict.txt" <<'PY'
import sys
import yaml
characters = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))["PostProcess"]["character_dict"]
open(sys.argv[2], "w", encoding="utf-8").write("\n".join(str(c) for c in characters) + "\n")
PY
