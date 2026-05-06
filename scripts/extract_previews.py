#!/usr/bin/env python3
"""
Extract frame 0 (256×256) from every body sprite sheet AND COMPOSITE IT
onto the Black Stars starter background. The result is a self-contained
marketplace preview — wallets show body+background as one image, no
transparency artifacts.

The dapp's browser compositor still uses the full animated strip + the
user's actually-equipped background separately; this preview just gives
every NFT a clean default look in wallets/explorers/Tradeport.

Output: NEW BODIES AND BACKGROUNDS DONE/BodiesPreview/{name}-preview.png
"""

from pathlib import Path
import json
import sys

try:
    from PIL import Image
except ImportError:
    print("Pillow required: pip3 install Pillow", file=sys.stderr)
    sys.exit(1)


ROOT = Path("/Users/apple/Desktop/suitrump/trumpagotchi/NEW BODIES AND BACKGROUNDS DONE")
BODIES_DIR = ROOT / "Bodies"
OUT_DIR = ROOT / "BodiesPreview"
# Default starter background composited under every body preview. Wallets
# will show body+background as one self-contained image.
STARTER_BG = ROOT / "Backgroundsv2" / "Starter" / "BlackStars.png"
DEFAULT_FRAME_W = 256
DEFAULT_FRAME_H = 256


def frame_dims_for(png_path: Path) -> tuple[int, int]:
    """Read frame size from sidecar JSON; fallback to 256×256."""
    sidecar = png_path.with_suffix(".json")
    if not sidecar.exists():
        return DEFAULT_FRAME_W, DEFAULT_FRAME_H
    try:
        meta = json.loads(sidecar.read_text())
        sx = meta.get("size_x", DEFAULT_FRAME_W)
        sy = meta.get("size_y", DEFAULT_FRAME_H)
        return int(sx), int(sy)
    except Exception:
        return DEFAULT_FRAME_W, DEFAULT_FRAME_H


def main() -> int:
    if not BODIES_DIR.exists():
        print(f"Bodies dir not found: {BODIES_DIR}", file=sys.stderr)
        return 1
    if not STARTER_BG.exists():
        print(f"Starter background not found: {STARTER_BG}", file=sys.stderr)
        return 1
    OUT_DIR.mkdir(parents=True, exist_ok=True)

    # Wipe any prior preview output so the dir matches exactly what we pin.
    for old in OUT_DIR.glob("*"):
        if old.is_file():
            old.unlink()

    # Load the starter background once (force RGBA for clean composite).
    with Image.open(STARTER_BG) as bg_im:
        bg_master = bg_im.convert("RGBA").copy()

    png_files = sorted(BODIES_DIR.glob("*.png"))
    if not png_files:
        print(f"No PNGs in {BODIES_DIR}", file=sys.stderr)
        return 1

    print(f"Compositing frame 0 of {len(png_files)} bodies onto {STARTER_BG.name} → {OUT_DIR}")
    for png in png_files:
        fw, fh = frame_dims_for(png)
        # Background sized to the frame canvas (resize if mismatched).
        bg = bg_master.resize((fw, fh), Image.NEAREST) if bg_master.size != (fw, fh) else bg_master.copy()
        with Image.open(png) as im:
            # Frame 0 = leftmost fw pixels of the horizontal strip.
            body_frame = im.crop((0, 0, fw, fh)).convert("RGBA")
            # Alpha-composite body over background.
            bg.alpha_composite(body_frame)
        out = OUT_DIR / f"{png.stem}-preview.png"
        bg.save(out, optimize=True)
        print(f"  {png.name}  ({fw}×{fh})  →  {out.name}")

    # Also copy each background PNG flat into the preview output so the
    # cosmetic Display image_url for backgrounds resolves from the same quilt.
    bgs_dir = ROOT / "Backgroundsv2"
    for bg_png in bgs_dir.rglob("*.png"):
        dest = OUT_DIR / bg_png.name
        with Image.open(bg_png) as im:
            im.convert("RGBA").save(dest, optimize=True)

    body_count = sum(1 for _ in OUT_DIR.glob("*-preview.png"))
    bg_count = sum(1 for p in OUT_DIR.glob("*.png") if not p.name.endswith("-preview.png"))
    print(f"\nDone. {body_count} composited body preview(s) + {bg_count} background(s) in {OUT_DIR}")
    print(f"Total bytes: {sum(p.stat().st_size for p in OUT_DIR.glob('*.png')):,}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
