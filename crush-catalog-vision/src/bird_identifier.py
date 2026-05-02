import numpy as np
from PIL import Image
import torch
import birder
import io
import os
import rawpy
from ultralytics import YOLO

class BirdIdentifier:
    """Encapsulates the Birder model loading and inference pipeline.

    Configurable for different models and hardware acceleration backends.
    """

    def __init__(self, model_name: str, device: str = "cpu"):
        """Initializes the model once for all images.

        Common device choices: 'cpu', 'mps' (Apple Silicon), 'cuda' (NVIDIA)
        """
        self.device = torch.device(device)
        self.model_name = model_name

        self.detector = YOLO("yolo11n.pt")
        self.detector.to(self.device)
        
        self.net, self.model_info = birder.load_pretrained_model(
            self.model_name, inference=True
        )

        self.net.to(self.device)

        size = birder.get_size_from_signature(self.model_info.signature)
        self.transform = birder.classification_transform(
            size, self.model_info.rgb_stats
        )

        self.labels_map = {
            v: k for k, v in self.model_info.class_to_idx.items()
        }

    def predict(self, img: Image.Image, top_k: int | None = 5) -> list:
        """Takes a Pillow Image, runs local inference, and returns an array of
        top predictions.
        """
        subject_img = self._get_dynamic_crop(img)

        # Transform the image, add batch dimension, and push to the set device
        input_tensor = self.transform(subject_img.convert("RGB"))
        input_tensor = input_tensor.unsqueeze(0).to(self.device)

        # Run inference directly on the network
        self.net.eval()
        with torch.no_grad():
            logits = self.net(input_tensor)
            probabilities = (
                torch.nn.functional.softmax(logits, dim=1)
                .squeeze()
                .cpu()
                .numpy()
            )

        # Process probabilities and sort top results
        # Process probabilities and sort
        if top_k is not None:
            # Get only the top K indices
            target_indices = np.argsort(probabilities)[-top_k:][::-1]
        else:
            # Get all indices sorted by highest probability
            target_indices = np.argsort(probabilities)[::-1]

        results = []
        for rank, idx in enumerate(target_indices, 1):
            unknown = f"Unknown Class {idx}"
            class_label = self.labels_map.get(
                int(idx), unknown
            )

            parts = class_label.split('_')
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

    def predict_from_file(
        self, file_path: str, top_k: int | None = 5
    ) -> list:
        """Accepts any supported file type path, automatically routes decoding,

        and yields the requested prediction array.
        """
        _, ext = os.path.splitext(file_path)
        ext = ext.lower()

        # 1. Route CR3 files to rawpy to extract baked-in JPEG
        if ext == ".cr3":
            with rawpy.imread(file_path) as raw:
                try:
                    thumb = raw.extract_thumb()
                    if thumb.format == rawpy.ThumbFormat.JPEG:
                        img = Image.open(io.BytesIO(thumb.data))
                except rawpy.LibRawNoThumbnailError:
                    # Fallback to a fast demosaic if no preview exists
                    rgb = raw.postprocess(use_camera_wb=True, half_size=True)
                    img = Image.fromarray(rgb)

        # 2. Route standard formats straight to Pillow
        else:
            img = Image.open(file_path)

        # 3. Call internal predict on the loaded Pillow Image
        if img is not None:
            return self.predict(img, top_k=top_k)

        raise ValueError(f"Could not read or process image at {file_path}")

    def _get_dynamic_crop(self, img: Image.Image) -> Image.Image:
        """Finds the bird anywhere in the frame and crops to its bounding box."""
        # Detect 'bird' (COCO class 14)
        results = self.detector.predict(img, classes=[14], verbose=False)
        
        if not results or len(results[0].boxes) == 0:
            return img  # Fallback to original if bird not found

        # Get coordinates of the most confident detection [xmin, ymin, xmax, ymax]
        box = results[0].boxes.xyxy.cpu().numpy()[0]
        
        # Add a 20% margin to provide context for the classifier
        w, h = img.size
        bw, bh = box[2] - box[0], box[3] - box[1]
        
        crop_box = (
            max(0, box[0] - bw * 0.2),
            max(0, box[1] - bh * 0.2),
            min(w, box[2] + bw * 0.2),
            min(h, box[3] + bh * 0.2)
        )
        
        return img.crop(crop_box)
