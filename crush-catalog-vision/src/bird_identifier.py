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

IDENTIFY_ENTIRE_IMAGE = False

class BirdIdentifier:
    """Encapsulates the Birder model loading and inference pipeline.

    Configurable for different models and hardware acceleration backends.
    """

    def __init__(self, model_name: str | None = None, device: str = "cpu"):
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
        results = self.detector.predict(img, classes=[14], verbose=False)
        detections = []

        if results and len(results[0].boxes) > 0:
            boxes = results[0].boxes.xyxy.cpu().numpy()
            for index, box in enumerate(boxes, start=1):
                crop = self._crop_with_margin(img, box)
                predictions = self._classify_image(crop, top_k=top_k)
                detections.append(
                    {
                        "detection_id": index,
                        "box": [float(box[0]), float(box[1]), float(box[2]), float(box[3])],
                        "image": crop,
                        "predictions": predictions,
                        "top_prediction": predictions[0] if predictions else None,
                    }
                )
        elif IDENTIFY_ENTIRE_IMAGE and img is not None:
            predictions = self._classify_image(img, top_k=top_k)
            detections.append(
                {
                    "detection_id": 1,
                    "box": None,
                    "image": img,
                    "predictions": predictions,
                    "top_prediction": predictions[0] if predictions else None,
                }
            )

        return detections

    def predict_from_file(self, file_path: str, top_k: int | None = 5) -> list:
        img = self.get_image_from_file(file_path)

        if img is not None:
            return self.predict(img, top_k=top_k)

        raise ValueError(f"Could not read or process image at {file_path}")

    def get_image_from_file(self, file_path: str) -> Image.Image:
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
        if not detection:
            return img
        
        if not detection.get("box"):
            return img
        
        box = detection["box"]
        crop = self._crop_with_margin(img, box)
        return crop
