"""
PhoneDetector - Level 1 Analyzer
Dual-backend: YOLO (PC/Windows) or TFLite (Raspberry Pi 5 ARM64).
Auto-selects based on platform at import time.
"""

import platform
from pathlib import Path

import cv2
import numpy as np

# ── Constants (shared by both backends) ──────────────────────────────────────
PHONE_CLASS_ID  = 67      # COCO: "cell phone"
MIN_CONFIDENCE  = 0.35
MIN_ASPECT_RATIO = 0.7
MAX_ASPECT_RATIO = 8.0
MIN_REL_AREA    = 0.005
MAX_REL_AREA    = 0.35

# Primary: models/yolo26n.tflite (copied there for Pi deployment)
# Fallback: analyzers/models/yolo26n_fp16.tflite (original location)
_TFLITE_PRIMARY  = Path(__file__).parent.parent / "models" / "yolo26n.tflite"
_TFLITE_FALLBACK = Path(__file__).parent / "models" / "yolo26n_fp16.tflite"
TFLITE_MODEL_PATH = _TFLITE_PRIMARY if _TFLITE_PRIMARY.exists() else _TFLITE_FALLBACK


def _is_valid_phone_bbox(x1, y1, x2, y2, img_w, img_h) -> bool:
    w, h = x2 - x1, y2 - y1
    if w <= 0 or h <= 0:
        return False
    ratio = max(w, h) / (min(w, h) + 1e-6)
    if not (MIN_ASPECT_RATIO <= ratio <= MAX_ASPECT_RATIO):
        return False
    rel_area = (w * h) / (img_w * img_h + 1e-6)
    return MIN_REL_AREA <= rel_area <= MAX_REL_AREA


# ── YOLO backend (PC / x86_64) ────────────────────────────────────────────────
class _YOLOBackend:
    def __init__(self):
        self._ready = False
        self.model  = None
        self._load()

    def _load(self):
        try:
            import torch
            _orig = torch.load
            def _patched(*a, **kw):
                kw["weights_only"] = False
                return _orig(*a, **kw)
            torch.load = _patched

            import warnings
            from ultralytics import YOLO  # noqa
            with warnings.catch_warnings():
                warnings.simplefilter("ignore")
                self.model = YOLO("yolo26n.pt")

            torch.load = _orig
            self._ready = True
            print("[Phone L1] [OK] YOLOv26n loaded (YOLO backend).")
        except ImportError:
            print("[Phone L1] [ERROR] ultralytics not installed: pip install ultralytics")
        except Exception as exc:
            print(f"[Phone L1] [ERROR] YOLO load: {exc}")

    def analyze(self, image, face_box=None) -> dict:
        if not self._ready:
            return {"phone_found": False, "confidence": 0.0, "bbox": None, "rel_area": 0.0}

        img_h, img_w = image.shape[:2]
        try:
            results = self.model(
                image, classes=[PHONE_CLASS_ID], conf=MIN_CONFIDENCE,
                imgsz=416, verbose=False, device="cpu",
            )
        except Exception:
            try:
                results = self.model(
                    image, classes=[PHONE_CLASS_ID], conf=MIN_CONFIDENCE,
                    imgsz=320, verbose=False, device="cpu",
                )
            except Exception as exc:
                print(f"[Phone L1] inference error: {exc}")
                return {"phone_found": False, "confidence": 0.0, "bbox": None, "rel_area": 0.0}

        best_conf, best_bbox, best_area = 0.0, None, 0.0
        for result in results:
            if result.boxes is None:
                continue
            for box in result.boxes:
                conf = float(box.conf[0])
                if conf < MIN_CONFIDENCE:
                    continue
                x1, y1, x2, y2 = [int(v) for v in box.xyxy[0]]
                if not _is_valid_phone_bbox(x1, y1, x2, y2, img_w, img_h):
                    continue
                rel_area = ((x2 - x1) * (y2 - y1)) / (img_w * img_h + 1e-6)
                if conf > best_conf:
                    best_conf, best_bbox, best_area = conf, (x1, y1, x2, y2), rel_area

        return {
            "phone_found": best_bbox is not None,
            "confidence":  round(best_conf, 3),
            "bbox":        best_bbox,
            "rel_area":    round(best_area, 4),
        }


# ── TFLite backend (Raspberry Pi 5 / ARM64) ───────────────────────────────────
class _TFLiteBackend:
    def __init__(self):
        self._ready = False
        self._interp = None
        self._in_idx  = None
        self._out_idx = None
        self._in_h = 416
        self._in_w = 416
        self._in_dtype = np.float32
        self._load()

    def _load(self):
        if not TFLITE_MODEL_PATH.exists():
            print(
                f"[Phone L1] [ERROR] TFLite model not found: {TFLITE_MODEL_PATH}\n"
                "  Run on PC: python convert_yolo_tflite.py  then push + pull on Pi."
            )
            return
        try:
            try:
                from tflite_runtime.interpreter import Interpreter  # noqa
            except ImportError:
                from tensorflow.lite.python.interpreter import Interpreter  # noqa

            interp = Interpreter(model_path=str(TFLITE_MODEL_PATH))
            interp.allocate_tensors()

            in_det  = interp.get_input_details()[0]
            out_det = interp.get_output_details()[0]

            self._interp   = interp
            self._in_idx   = in_det["index"]
            self._out_idx  = out_det["index"]
            self._in_dtype = in_det["dtype"]
            shape = in_det["shape"]   # [1, H, W, 3]
            self._in_h, self._in_w = int(shape[1]), int(shape[2])
            self._ready = True
            print(f"[Phone L1] [OK] TFLite model loaded ({self._in_h}x{self._in_w}, dtype={self._in_dtype.__name__}).")
        except ImportError:
            print("[Phone L1] [ERROR] tflite_runtime not installed: pip install tflite-runtime")
        except Exception as exc:
            print(f"[Phone L1] [ERROR] TFLite load: {exc}")

    def analyze(self, image, face_box=None) -> dict:
        if not self._ready:
            return {"phone_found": False, "confidence": 0.0, "bbox": None, "rel_area": 0.0}

        img_h, img_w = image.shape[:2]

        # Pre-process: resize to model input, normalize [0,1], add batch dim
        inp = cv2.resize(image, (self._in_w, self._in_h))
        inp = cv2.cvtColor(inp, cv2.COLOR_BGR2RGB)
        inp = inp.astype(np.float32) / 255.0
        inp = np.expand_dims(inp, 0)  # [1, H, W, 3]

        try:
            self._interp.set_tensor(self._in_idx, inp)
            self._interp.invoke()
            # Output: [1, 300, 6] = [x1, y1, x2, y2, confidence, class_id]
            # Coords are absolute in model input space (0..in_w, 0..in_h)
            output = self._interp.get_tensor(self._out_idx)
        except Exception as exc:
            print(f"[Phone L1] TFLite inference error: {exc}")
            return {"phone_found": False, "confidence": 0.0, "bbox": None, "rel_area": 0.0}

        return self._postprocess(output, img_w, img_h)

    def _postprocess(self, output: np.ndarray, img_w: int, img_h: int) -> dict:
        # output: [1, 300, 6] — NMS already applied by the model
        # Each row: [x1, y1, x2, y2, confidence, class_id] in model input coords
        detections = output[0]  # [300, 6]

        # Scale factors from model input size to actual image size
        sx = img_w / self._in_w
        sy = img_h / self._in_h

        best_conf, best_bbox, best_area = 0.0, None, 0.0

        for det in detections:
            x1, y1, x2, y2, conf, cls_id = det
            if conf < MIN_CONFIDENCE:
                continue
            if int(round(cls_id)) != PHONE_CLASS_ID:
                continue

            # Scale to image coords
            bx1 = int(np.clip(x1 * sx, 0, img_w))
            by1 = int(np.clip(y1 * sy, 0, img_h))
            bx2 = int(np.clip(x2 * sx, 0, img_w))
            by2 = int(np.clip(y2 * sy, 0, img_h))

            if not _is_valid_phone_bbox(bx1, by1, bx2, by2, img_w, img_h):
                continue

            if conf > best_conf:
                best_conf = float(conf)
                best_bbox = (bx1, by1, bx2, by2)
                best_area = ((bx2 - bx1) * (by2 - by1)) / (img_w * img_h + 1e-6)

        return {
            "phone_found": best_bbox is not None,
            "confidence":  round(best_conf, 3),
            "bbox":        best_bbox,
            "rel_area":    round(best_area, 4),
        }



# ── Public class ──────────────────────────────────────────────────────────────
class PhoneDetector:
    """
    Instantaneous phone detector. Auto-selects backend:
      - ARM64 Linux (Raspberry Pi 5) → TFLite via tflite_runtime
      - All other platforms           → Ultralytics YOLO
    """

    def __init__(self):
        arch = platform.machine().lower()
        use_tflite = (platform.system() == "Linux" and ("aarch64" in arch or "arm64" in arch))
        if use_tflite:
            print("[Phone L1] Platform: Raspberry Pi 5 — using TFLite backend.")
            self._backend = _TFLiteBackend()
        else:
            self._backend = _YOLOBackend()

    def analyze(self, image, face_box=None) -> dict:
        return self._backend.analyze(image, face_box)
