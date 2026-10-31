# Third-party components

| Component | Version | License | Where it comes from |
| --- | --- | --- | --- |
| OpenCV | 4.14.0 | Apache-2.0 | Source from github.com/opencv/opencv, built statically by `scripts/bootstrap.sh` |
| ONNX Runtime | 1.31.1 | MIT | Official `onnxruntime-osx-arm64` release from github.com/microsoft/onnxruntime, embedded in the app |
| PaddleOCR models | PP-OCRv5 | Apache-2.0 | PaddlePaddle's official inference models, converted to ONNX by `scripts/convert_models.sh` |
| paddle2onnx | 2.1.0 | Apache-2.0 | Used only to convert the models; not part of the app |

## Models

The files in `Models/` were converted with `paddle2onnx` at opset 13 from these archives, under
`paddle-model-ecology.bj.bcebos.com/paddlex/official_inference_model/paddle3.0.0/`:

| Model file | Source archive | Archive SHA-256 |
| --- | --- | --- |
| `ppocrv5_mobile_det.onnx` | `PP-OCRv5_mobile_det_infer.tar` | `50446e5d01ac2a73d5319c89513281f6578414c888c602f9af13f93feefffc58` |
| `en_ppocrv5_mobile_rec.onnx` | `en_PP-OCRv5_mobile_rec_infer.tar` | `e595b4cf2ffad19fbb5a61ba345d63939577a3ab8717b6e5995642590c9101b4` |
| `pplcnet_x025_textline_ori.onnx` | `PP-LCNet_x0_25_textline_ori_infer.tar` | `268d9aea61461c3d4a5a32752e5b920e8af2ee0a002362f6ba5cd39638fa2c3a` |

`en_ppocrv5_mobile_rec_dict.txt` is the `character_dict` from the recognizer's `inference.yml`.
