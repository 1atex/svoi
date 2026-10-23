"""Export the approved SVOI avatar to app/favicon resources. Requires Pillow."""
from pathlib import Path
from PIL import Image

root = Path(__file__).resolve().parents[2]
source = Image.open(root / "assets/brand/svoi-avatar-amber.png").convert("RGBA")
sizes = [(n, n) for n in (16, 20, 24, 32, 40, 48, 64, 128, 256)]
for target in ("assets/svoi.ico", "web/favicon.ico", "flutter_client/windows/runner/resources/app_icon.ico"):
    source.save(root / target, format="ICO", sizes=sizes)
for target, size in (("flutter_client/assets/svoi-mark.png", 256), ("web/svoi-mark.png", 128)):
    path = root / target
    path.parent.mkdir(parents=True, exist_ok=True)
    source.resize((size, size), Image.Resampling.LANCZOS).save(path, optimize=True)
print("Exported Windows, browser and Flutter icon assets.")
