import numpy as np
from PIL import Image
import torch
import birder
import io
import os
import rawpy


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

        # 1. Load the network and its metadata
        self.net, self.model_info = birder.load_pretrained_model(
            self.model_name, inference=True
        )

        # 2. Set the device for the network
        self.net.to(self.device)

        # 3. Setup the image transform pipeline based on model signature
        size = birder.get_size_from_signature(self.model_info.signature)
        self.transform = birder.classification_transform(
            size, self.model_info.rgb_stats
        )

        # 4. Create the inverted labels map {ID: 'Common Name'}
        self.labels_map = {
            v: k for k, v in self.model_info.class_to_idx.items()
        }

    def predict(self, img: Image.Image, top_k: int | None = 5) -> list:
        """Takes a Pillow Image, runs local inference, and returns an array of
        top predictions.
        """
        # Transform the image, add batch dimension, and push to the set device
        input_tensor = self.transform(img.convert("RGB"))
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
