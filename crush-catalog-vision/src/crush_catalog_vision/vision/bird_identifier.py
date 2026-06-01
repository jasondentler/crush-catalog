import io
import json
import os
from pathlib import Path

import numpy as np
import torch
import birder
import rawpy
from PIL import Image
from ultralytics import YOLO

IDENTIFY_ENTIRE_IMAGE = True
DUPLICATE_DETECTION_IOU_THRESHOLD = 0.85
DUPLICATE_DETECTION_CONTAINMENT_THRESHOLD = 0.85


def _box_iou(box_a: list[float], box_b: list[float]) -> float:
    """Calculate intersection-over-union for two bounding boxes."""
    ax1, ay1, ax2, ay2 = box_a
    bx1, by1, bx2, by2 = box_b

    inter_x1 = max(ax1, bx1)
    inter_y1 = max(ay1, by1)
    inter_x2 = min(ax2, bx2)
    inter_y2 = min(ay2, by2)
    inter_w = max(0.0, inter_x2 - inter_x1)
    inter_h = max(0.0, inter_y2 - inter_y1)
    intersection = inter_w * inter_h

    area_a = max(0.0, ax2 - ax1) * max(0.0, ay2 - ay1)
    area_b = max(0.0, bx2 - bx1) * max(0.0, by2 - by1)
    union = area_a + area_b - intersection

    if union <= 0:
        return 0.0

    return intersection / union


def _box_containment(box_a: list[float], box_b: list[float]) -> float:
    """Calculate how much the smaller box is contained by the other box."""
    ax1, ay1, ax2, ay2 = box_a
    bx1, by1, bx2, by2 = box_b

    inter_x1 = max(ax1, bx1)
    inter_y1 = max(ay1, by1)
    inter_x2 = min(ax2, bx2)
    inter_y2 = min(ay2, by2)
    inter_w = max(0.0, inter_x2 - inter_x1)
    inter_h = max(0.0, inter_y2 - inter_y1)
    intersection = inter_w * inter_h

    area_a = max(0.0, ax2 - ax1) * max(0.0, ay2 - ay1)
    area_b = max(0.0, bx2 - bx1) * max(0.0, by2 - by1)
    smaller_area = min(area_a, area_b)

    if smaller_area <= 0:
        return 0.0

    return intersection / smaller_area


def _remove_duplicate_boxes(boxes: list[list[float]], threshold: float = DUPLICATE_DETECTION_IOU_THRESHOLD) -> list[list[float]]:
    """Remove overlapping or nested detection boxes from a YOLO result."""
    unique_boxes = []
    for box in boxes:
        if any(
            _box_iou(box, existing_box) >= threshold
            or _box_containment(box, existing_box) >= DUPLICATE_DETECTION_CONTAINMENT_THRESHOLD
            for existing_box in unique_boxes
        ):
            continue

        unique_boxes.append(box)

    return unique_boxes

class BirdIdentifier:
    """Encapsulates the Birder model loading and inference pipeline.

    Configurable for different models and hardware acceleration backends.
    """

    def __init__(self, model_name: str | None = None, device: str = "cpu"):
        """Load the YOLO detector and Birder classifier on the requested device."""
        self.device = torch.device(device)
        self.model_name = model_name

        model_path = Path(__file__).resolve().parent.parent / "yolo11n.pt"
        self.detector = YOLO(str(model_path))
        self.detector.to(self.device)

        self.net, self.model_info = birder.load_pretrained_model(
            self.model_name, inference=True
        )

        self.net.to(self.device)

        size = birder.get_size_from_signature(self.model_info.signature)
        self.transform = birder.classification_transform(
            size, self.model_info.rgb_stats
        )

        self.labels_map = {v: k for k, v in self.model_info.class_to_idx.items()}

    def _classify_image(self, img: Image.Image, top_k: int | None = 5) -> list:
        """Classify a cropped image and return ranked species predictions."""
        input_tensor = self.transform(img.convert("RGB"))
        input_tensor = input_tensor.unsqueeze(0).to(self.device)

        self.net.eval()
        with torch.no_grad():
            logits = self.net(input_tensor)
            probabilities = (
                torch.nn.functional.softmax(logits, dim=1)
                .squeeze()
                .cpu()
                .numpy()
            )

        if top_k is not None:
            target_indices = np.argsort(probabilities)[-top_k:][::-1]
        else:
            target_indices = np.argsort(probabilities)[::-1]

        results = []
        for rank, idx in enumerate(target_indices, 1):
            unknown = f"Unknown Class {idx}"
            class_label = self.labels_map.get(int(idx), unknown)
            parts = class_label.split("_")
            sci_name = f"{parts[-2]} {parts[-1]}" if len(parts) >= 2 else class_label
            results.append(
                {
                    "rank": rank,
                    "class_id": int(idx),
                    "class_label": class_label,
                    "species": sci_name,
                    "confidence": round(float(probabilities[idx]), 4),
                }
            )
        return results

    def _crop_with_margin(self, img: Image.Image, box: list[float]) -> Image.Image:
        """Crop a detection box with margin while staying inside image bounds."""
        w, h = img.size
        xmin, ymin, xmax, ymax = box
        bw, bh = xmax - xmin, ymax - ymin
        crop_box = (
            max(0, xmin - bw * 0.2),
            max(0, ymin - bh * 0.2),
            min(w, xmax + bw * 0.2),
            min(h, ymax + bh * 0.2),
        )
        return img.crop(crop_box)

    def predict(self, img: Image.Image, top_k: int | None = 5) -> list:
        """Detect bird regions in an image and classify each region."""
        results = self.detector.predict(img, classes=[14], verbose=False)
        detections = []
        image_width, image_height = img.size

        if results and len(results[0].boxes) > 0:
            boxes = _remove_duplicate_boxes(results[0].boxes.xyxy.cpu().numpy().tolist())
            for index, box in enumerate(boxes, start=1):
                crop = self._crop_with_margin(img, box)
                predictions = self._classify_image(crop, top_k=top_k)
                detections.append(
                    {
                        "detection_id": index,
                        "box": [float(box[0]), float(box[1]), float(box[2]), float(box[3])],
                        "image_width": image_width,
                        "image_height": image_height,
                        "image": crop,
                        "predictions": predictions,
                        "top_prediction": predictions[0] if predictions else None,
                    }
                )
        elif IDENTIFY_ENTIRE_IMAGE and img is not None:
            w, h = img.size
            predictions = self._classify_image(img, top_k=top_k)
            detections.append(
                {
                    "detection_id": 1,
                    "box": [0.0, 0.0, float(w), float(h)],
                    "image_width": image_width,
                    "image_height": image_height,
                    "image": img,
                    "predictions": predictions,
                    "top_prediction": predictions[0] if predictions else None,
                }
            )

        return detections

    def predict_from_file(self, file_path: str, top_k: int | None = 5) -> list:
        """Load an image file and return bird detections with predictions."""
        img = self.get_image_from_file(file_path)

        if img is not None:
            return self.predict(img, top_k=top_k)

        raise ValueError(f"Could not read or process image at {file_path}")

    def get_image_from_file(self, file_path: str) -> Image.Image:
        """Load a JPEG or CR3 file as a Pillow image."""
        _, ext = os.path.splitext(file_path)
        ext = ext.lower()

        if ext == ".cr3":
            with rawpy.imread(file_path) as raw:
                try:
                    thumb = raw.extract_thumb()
                    if thumb.format == rawpy.ThumbFormat.JPEG:
                        return Image.open(io.BytesIO(thumb.data))
                except rawpy.LibRawNoThumbnailError:
                    rgb = raw.postprocess(use_camera_wb=True, half_size=True)
                    return Image.fromarray(rgb)
        else:
            return Image.open(file_path)

        raise ValueError(f"Could not read or process image at {file_path}")
    
    def get_bird_in_image(self, img: Image.image, detection: dict) -> Image.image:
        """Return the cropped bird region for a detection when available."""
        if not detection:
            return img
        
        if not detection.get("box"):
            return img
        
        box = detection["box"]
        crop = self._crop_with_margin(img, box)
        return crop
