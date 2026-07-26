#!/usr/bin/env python3
"""Generate the Synergy Crew AppIcon set.

Full-bleed VOLTAGE charcoal (#0A0A0D) squares with a volt-yellow (#FFD400)
lightning bolt, drawn at 4x supersampling and downscaled with Lanczos for
crisp edges. iOS rounds the corners itself, so icons are square and opaque
(no alpha channel — required for the 1024 marketing icon).
"""

import os

from PIL import Image, ImageDraw

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "..", "Sources", "Assets.xcassets", "AppIcon.appiconset")

CHARCOAL = (10, 10, 13)
VOLT = (255, 212, 0)

# Classic bolt, normalized 0..1 (matches the site's 512 PWA icon silhouette).
BOLT = [
    (0.555, 0.100),  # top tip
    (0.235, 0.565),  # lower-left sweep
    (0.445, 0.565),  # notch (right of sweep)
    (0.395, 0.900),  # bottom tip
    (0.720, 0.435),  # upper-right arm
    (0.510, 0.435),  # notch (left of arm)
]

SIZES = [20, 29, 40, 58, 60, 76, 80, 87, 120, 152, 167, 180, 1024]

SS = 4  # supersampling factor


def render(size: int) -> Image.Image:
    big = size * SS
    img = Image.new("RGB", (big, big), CHARCOAL)
    draw = ImageDraw.Draw(img)
    draw.polygon([(x * big, y * big) for x, y in BOLT], fill=VOLT)
    return img.resize((size, size), Image.LANCZOS)


def main() -> None:
    os.makedirs(OUT, exist_ok=True)
    for size in SIZES:
        path = os.path.join(OUT, f"icon-{size}.png")
        render(size).save(path, "PNG")
        print(f"wrote {path}")


if __name__ == "__main__":
    main()
