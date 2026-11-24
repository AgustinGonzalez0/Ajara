from pathlib import Path
import cv2
import numpy as np
import torch
from torch.utils.data import Dataset

SIZE = 512
NUM_CLASSES = 6

class PlanDataset(Dataset):
    def __init__(self, root, split="train", augment=False):
        self.root = Path(root)
        self.augment = augment
        split_file = self.root / "splits" / f"{split}.txt"
        if not split_file.exists():
            raise FileNotFoundError(f"No existe {split_file}")
        self.ids = [x.strip() for x in split_file.read_text().splitlines() if x.strip()]
        if not self.ids:
            raise ValueError(f"El split {split} está vacío")

    def __len__(self):
        return len(self.ids)

    def __getitem__(self, idx):
        name = self.ids[idx]
        image_path = self.root / "images" / f"{name}.png"
        mask_path = self.root / "masks" / f"{name}.png"
        image = cv2.imread(str(image_path), cv2.IMREAD_COLOR)
        mask = cv2.imread(str(mask_path), cv2.IMREAD_GRAYSCALE)
        if image is None or mask is None:
            raise FileNotFoundError(f"No se pudo leer imagen/máscara de {name}")
        image = cv2.cvtColor(image, cv2.COLOR_BGR2RGB)
        image = cv2.resize(image, (SIZE, SIZE), interpolation=cv2.INTER_AREA)
        mask = cv2.resize(mask, (SIZE, SIZE), interpolation=cv2.INTER_NEAREST)

        if self.augment:
            if np.random.rand() < 0.5:
                image, mask = np.fliplr(image), np.fliplr(mask)
            if np.random.rand() < 0.5:
                image, mask = np.flipud(image), np.flipud(mask)
            k = np.random.randint(0, 4)
            image, mask = np.rot90(image, k), np.rot90(mask, k)

        image = np.ascontiguousarray(image.transpose(2, 0, 1), dtype=np.float32) / 255.0
        mask = np.ascontiguousarray(mask, dtype=np.int64)
        if mask.min() < 0 or mask.max() >= NUM_CLASSES:
            raise ValueError(f"Máscara {name}: IDs fuera del rango 0..{NUM_CLASSES-1}")
        return torch.from_numpy(image), torch.from_numpy(mask)
