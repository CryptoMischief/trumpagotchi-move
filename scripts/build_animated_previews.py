#!/usr/bin/env python3
"""
Build per-body animated GIFs for marketplace previews. Each GIF is the body
sprite (read from working/Bodies/_manifest.json — the canonical source per
v8 §12) composited frame-by-frame onto the Black Stars starter background.

Output: trumpagotchi/AnimatedPreviews/{base}-animated.gif
where {base} matches the body_identifier on-chain (e.g. "Tier1-FakeNews",
"Tier4-Tremendous-Tuxedo"). Display.image_url interpolates body_identifier
into "{body_identifier}-animated.gif".

Yolked is excluded per user decision 2026-05-05.

Per v8 §5.3 (amended 2026-05-05): Display.image_url is body+Black-Stars
only. Equipped backgrounds change the dapp compositor only, not the
marketplace preview.
"""

import argparse
import json
import sys
from pathlib import Path

try:
    from PIL import Image
except ImportError:
    print("Pillow required: pip3 install Pillow", file=sys.stderr)
    sys.exit(1)


# v8 deliverable folder — the renamed copy of working/Bodies/ matches the
# on-chain identifier convention exactly (e.g. Tier4-Tremendous-Tuxedo.png).
ROOT = Path("/Users/apple/Desktop/suitrump/trumpagotchi/NEW BODIES AND BACKGROUNDS DONE")
BODIES_DIR = ROOT / "Bodies"
STARTER_BG = ROOT / "Backgroundsv2" / "Starter" / "BlackStars.png"
OUT_DIR = Path("/Users/apple/Desktop/suitrump/trumpagotchi/AnimatedPreviews")

# Per v8: drop Yolked from the pipeline.
EXCLUDE_STEMS = {"Tier13-POTUS-Yolked"}

DEFAULT_FPS = 3
DEFAULT_FRAME = 256


def frame_meta(png_path: Path) -> dict:
    """Pixelorama JSON sidecar: {frames:[…], fps, size_x, size_y}."""
    sidecar = png_path.with_suffix(".json")
    if not sidecar.exists():
        return {"frame_count": 1, "fps": DEFAULT_FPS, "fw": DEFAULT_FRAME, "fh": DEFAULT_FRAME}
    raw = json.loads(sidecar.read_text())
    frames = raw.get("frames", []) or []
    return {
        "frame_count": max(1, len(frames)),
        "fps": float(raw.get("fps") or DEFAULT_FPS),
        "fw": int(raw.get("size_x") or DEFAULT_FRAME),
        "fh": int(raw.get("size_y") or DEFAULT_FRAME),
    }


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--only", default=None,
                    help="Only render bodies whose stem contains this substring (for sample/test runs)")
    args = ap.parse_args()

    if not BODIES_DIR.exists():
        print(f"Bodies dir missing: {BODIES_DIR}", file=sys.stderr)
        return 1
    if not STARTER_BG.exists():
        print(f"Black Stars background missing: {STARTER_BG}", file=sys.stderr)
        return 1
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    # Only wipe prior output on a full run. For --only sample renders, leave
    # existing files alone so iterative testing doesn't blow them away.
    if not args.only:
        for old in OUT_DIR.glob("*"):
            if old.is_file():
                old.unlink()
    print(f"only={args.only or '(all)'}")

    with Image.open(STARTER_BG) as bg_im:
        bg_master_rgba = bg_im.convert("RGBA").copy()

    pngs = sorted(BODIES_DIR.glob("*.png"))
    if not pngs:
        print(f"No PNGs in {BODIES_DIR}", file=sys.stderr)
        return 1

    rendered = 0
    skipped = 0
    for png in pngs:
        if png.stem in EXCLUDE_STEMS:
            print(f"  SKIP (excluded): {png.name}")
            skipped += 1
            continue
        if args.only and args.only not in png.stem:
            continue

        meta = frame_meta(png)
        fw, fh, n, fps = meta["fw"], meta["fh"], meta["frame_count"], meta["fps"]
        ms_per_frame = max(20, int(round(1000.0 / max(0.1, fps))))

        # Background sized to per-frame canvas (resize via NEAREST to keep
        # pixel-perfect look — Black Stars at 256×256 is already correct,
        # but other tiers/frame sizes may differ).
        bg = bg_master_rgba.resize((fw, fh), Image.NEAREST) if bg_master_rgba.size != (fw, fh) else bg_master_rgba.copy()

        with Image.open(png) as sheet:
            sheet_rgba = sheet.convert("RGBA")
            frames = []
            for i in range(n):
                comp = bg.copy()
                body_frame = sheet_rgba.crop((i * fw, 0, (i + 1) * fw, fh))
                comp.alpha_composite(body_frame)
                # Default Pillow GIF encoder — per-frame adaptive palette,
                # Floyd-Steinberg dither. The fringe-cleanup + shared-palette
                # variant was rejected by user 2026-05-06 ("doesn't look good
                # at all"); reverting to original behavior. User will polish
                # source sprites manually in a separate pass.
                frames.append(comp.convert("RGB").convert("P", palette=Image.ADAPTIVE, colors=256))

        out = OUT_DIR / f"{png.stem}-animated.gif"
        frames[0].save(
            out,
            save_all=True,
            append_images=frames[1:],
            duration=ms_per_frame,
            loop=0,
            disposal=2,
            optimize=True,
        )
        size_kb = out.stat().st_size / 1024
        print(f"  OK   {png.name:48s}  frames={n:2d} fps={fps:3.0f}  →  {out.name}  ({size_kb:.0f} KB)")
        rendered += 1

    total_bytes = sum(p.stat().st_size for p in OUT_DIR.glob("*.gif"))
    print()
    print(f"Done. {rendered} animated GIF(s), {skipped} skipped.")
    print(f"Output: {OUT_DIR}")
    print(f"Total size: {total_bytes / 1024 / 1024:.2f} MB")
    return 0


if __name__ == "__main__":
    sys.exit(main())
