#!/usr/bin/env python3
"""Builds the Auto-Loader chest artwork from an SVG design.

Outputs (all relative to this file's directory):
  entity/auto-loader-chest.png         64x80 entity sprite (scale 0.5 in-game)
  entity/auto-loader-chest-shadow.png  110x46 shadow, drawn with draw_as_shadow
  icons/auto-loader-chest.png          120x64 icon with 64/32/16/8 mipmaps

Run with the venv created next to this file:
  graphics/.venv/bin/python graphics/build_art.py

The design is authored as SVG in sprite pixel coordinates (64x80) so shapes
line up with the vanilla chest projection: a lit top face in the upper half and
a darker front face below. cairosvg rasterises it, then a light noise/grunge
pass in Pillow keeps it from reading as flat vector art next to Wube's sprites.
"""

from __future__ import annotations

import io
import os
from pathlib import Path

import cairosvg
import numpy
from PIL import Image, ImageDraw, ImageFilter

HERE = Path(__file__).resolve().parent

# ---------------------------------------------------------------------------
# Palette. Blue-steel body (continuity with the tinted look players know),
# hazard yellow on the intake, cyan status lights (a nod to the mimic mascot).
# ---------------------------------------------------------------------------
STEEL_TOP_LIGHT = "#d3dfea"
STEEL_TOP_MID = "#98acc2"
STEEL_TOP_DARK = "#66788e"
STEEL_RIM_LIGHT = "#a3b3c5"
STEEL_RIM_MID = "#6c7e93"
STEEL_RIM_DARK = "#3a4756"
STEEL_FRONT_LIGHT = "#657789"
STEEL_FRONT_MID = "#3f4d5c"
STEEL_FRONT_DARK = "#222a33"
STEEL_EDGE = "#12161c"
BOLT_LIGHT = "#dde5ed"
BOLT_DARK = "#4a5663"
HAZARD_YELLOW = "#f0bd2a"
HAZARD_BLACK = "#1c1b16"
INTAKE_DARK = "#05070a"
LIGHT_CYAN = "#6fe4ff"
LIGHT_CYAN_CORE = "#f2feff"
BRASS_LIGHT = "#e2c060"
BRASS_DARK = "#8a6c22"


def chest_svg(width: int, height: int, view_box: str) -> str:
    """The chest design in 64x80 sprite coordinates.

    Layout (y): lid top face 1..33, lid thickness 33..38, front face 38..74.
    `view_box` selects the region rendered (the icon uses a tighter crop).
    """
    return f"""<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" viewBox="{view_box}">
  <defs>
    <linearGradient id="top" x1="0" y1="0" x2="0.6" y2="1">
      <stop offset="0" stop-color="{STEEL_TOP_LIGHT}"/>
      <stop offset="0.5" stop-color="{STEEL_TOP_MID}"/>
      <stop offset="1" stop-color="{STEEL_TOP_DARK}"/>
    </linearGradient>
    <linearGradient id="rim" x1="0" y1="0" x2="0.4" y2="1">
      <stop offset="0" stop-color="{STEEL_RIM_LIGHT}"/>
      <stop offset="0.6" stop-color="{STEEL_RIM_MID}"/>
      <stop offset="1" stop-color="{STEEL_RIM_DARK}"/>
    </linearGradient>
    <linearGradient id="lid_edge" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="{STEEL_RIM_MID}"/>
      <stop offset="1" stop-color="{STEEL_RIM_DARK}"/>
    </linearGradient>
    <linearGradient id="front" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="{STEEL_FRONT_LIGHT}"/>
      <stop offset="0.35" stop-color="{STEEL_FRONT_MID}"/>
      <stop offset="1" stop-color="{STEEL_FRONT_DARK}"/>
    </linearGradient>
    <linearGradient id="side_shade" x1="0" y1="0" x2="1" y2="0">
      <stop offset="0" stop-color="#ffffff" stop-opacity="0.12"/>
      <stop offset="0.45" stop-color="#ffffff" stop-opacity="0"/>
      <stop offset="1" stop-color="#000000" stop-opacity="0.32"/>
    </linearGradient>
    <linearGradient id="brass" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="{BRASS_LIGHT}"/>
      <stop offset="1" stop-color="{BRASS_DARK}"/>
    </linearGradient>
    <radialGradient id="bolt" cx="0.35" cy="0.35" r="0.7">
      <stop offset="0" stop-color="{BOLT_LIGHT}"/>
      <stop offset="1" stop-color="{BOLT_DARK}"/>
    </radialGradient>
    <radialGradient id="lamp" cx="0.5" cy="0.5" r="0.5">
      <stop offset="0" stop-color="{LIGHT_CYAN_CORE}"/>
      <stop offset="0.4" stop-color="{LIGHT_CYAN}"/>
      <stop offset="1" stop-color="{LIGHT_CYAN}" stop-opacity="0"/>
    </radialGradient>
    <linearGradient id="intake" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="{INTAKE_DARK}"/>
      <stop offset="0.7" stop-color="#0d1218"/>
      <stop offset="1" stop-color="#26313e"/>
    </linearGradient>
    <pattern id="hazard" width="16" height="16" patternUnits="userSpaceOnUse" patternTransform="skewX(-45)">
      <rect width="16" height="16" fill="{HAZARD_YELLOW}"/>
      <rect width="8" height="16" fill="{HAZARD_BLACK}"/>
    </pattern>
  </defs>

  <!-- ===================== FRONT FACE (drawn first, lid overlaps it) ===================== -->
  <rect x="1" y="34" width="62" height="40" rx="2" fill="{STEEL_EDGE}"/>
  <rect x="2" y="35" width="60" height="38" rx="1.5" fill="url(#front)"/>
  <rect x="2" y="35" width="60" height="38" rx="1.5" fill="url(#side_shade)"/>
  <!-- vertical corner posts -->
  <rect x="2" y="38" width="4" height="35" fill="{STEEL_FRONT_LIGHT}" opacity="0.35"/>
  <rect x="58" y="38" width="4" height="35" fill="{STEEL_EDGE}" opacity="0.45"/>

  <!-- recessed front panel with horizontal armour ribs -->
  <rect x="7" y="48" width="50" height="21" rx="1" fill="{STEEL_EDGE}"/>
  <rect x="8" y="49" width="48" height="19" rx="1" fill="url(#front)"/>
  <g stroke="{STEEL_EDGE}" stroke-width="1.2">
    <line x1="8" y1="55.5" x2="56" y2="55.5"/>
    <line x1="8" y1="62.5" x2="56" y2="62.5"/>
  </g>
  <g stroke="#ffffff" stroke-width="1" opacity="0.16">
    <line x1="8" y1="49.5" x2="56" y2="49.5"/>
    <line x1="8" y1="56.5" x2="56" y2="56.5"/>
    <line x1="8" y1="63.5" x2="56" y2="63.5"/>
  </g>

  <!-- brass latch, centred like the vanilla chests -->
  <rect x="26.5" y="44.5" width="11" height="8" rx="1.5" fill="{STEEL_EDGE}"/>
  <rect x="27.5" y="45.5" width="9" height="6" rx="1" fill="url(#brass)"/>
  <rect x="29.5" y="46.5" width="5" height="1.6" rx="0.6" fill="{STEEL_EDGE}" opacity="0.65"/>

  <!-- status lamps: two cyan indicators flanking the latch -->
  <g>
    <circle cx="15" cy="43" r="6" fill="url(#lamp)" opacity="0.6"/>
    <circle cx="49" cy="43" r="6" fill="url(#lamp)" opacity="0.6"/>
    <circle cx="15" cy="43" r="3.2" fill="{STEEL_EDGE}"/>
    <circle cx="49" cy="43" r="3.2" fill="{STEEL_EDGE}"/>
    <circle cx="15" cy="43" r="2.4" fill="{LIGHT_CYAN}"/>
    <circle cx="49" cy="43" r="2.4" fill="{LIGHT_CYAN}"/>
    <circle cx="14.4" cy="42.4" r="1.1" fill="{LIGHT_CYAN_CORE}"/>
    <circle cx="48.4" cy="42.4" r="1.1" fill="{LIGHT_CYAN_CORE}"/>
  </g>

  <!-- feet -->
  <rect x="2" y="70" width="10" height="4" fill="{STEEL_EDGE}"/>
  <rect x="52" y="70" width="10" height="4" fill="{STEEL_EDGE}"/>
  <rect x="3" y="70" width="8" height="3" fill="{STEEL_FRONT_MID}"/>
  <rect x="53" y="70" width="8" height="3" fill="{STEEL_FRONT_MID}"/>

  <!-- ===================== LID ===================== -->
  <!-- lid thickness (the visible front edge of the lid) -->
  <rect x="0" y="30" width="64" height="9" rx="2" fill="{STEEL_EDGE}"/>
  <rect x="1" y="31" width="62" height="7" rx="1.5" fill="url(#lid_edge)"/>
  <rect x="1" y="31" width="62" height="7" rx="1.5" fill="url(#side_shade)"/>

  <!-- lid top face: outer rim with bevel -->
  <rect x="0" y="1" width="64" height="33" rx="3" fill="{STEEL_EDGE}"/>
  <rect x="1" y="2" width="62" height="31" rx="2.5" fill="url(#rim)"/>
  <rect x="1" y="2" width="62" height="31" rx="2.5" fill="url(#side_shade)"/>
  <!-- bevel: bright top/left, dark bottom/right -->
  <path d="M3 33 L3 4 L61 4" fill="none" stroke="#ffffff" stroke-opacity="0.35" stroke-width="1.4"/>
  <path d="M61 4 L61 32 L3 32" fill="none" stroke="#000000" stroke-opacity="0.35" stroke-width="1.4"/>

  <!-- inset lid panel -->
  <rect x="6" y="7" width="52" height="22" rx="1.5" fill="{STEEL_EDGE}"/>
  <rect x="7" y="8" width="50" height="20" rx="1" fill="url(#top)"/>
  <path d="M8 27 L8 9 L56 9" fill="none" stroke="#000000" stroke-opacity="0.35" stroke-width="1"/>
  <path d="M56 9 L56 27 L8 27" fill="none" stroke="#ffffff" stroke-opacity="0.25" stroke-width="1"/>

  <!-- intake slot: hazard-striped frame around a dark loading mouth -->
  <rect x="11" y="10" width="42" height="16" rx="1.5" fill="{STEEL_EDGE}"/>
  <rect x="12" y="11" width="40" height="14" rx="1" fill="url(#hazard)"/>
  <rect x="17" y="14" width="30" height="8" rx="1" fill="{STEEL_EDGE}"/>
  <rect x="18" y="15" width="28" height="6" rx="0.5" fill="url(#intake)"/>

  <!-- corner bolts on the lid -->
  <g stroke="{STEEL_EDGE}" stroke-width="0.7">
    <circle cx="4.5" cy="5.5" r="2.1" fill="url(#bolt)"/>
    <circle cx="59.5" cy="5.5" r="2.1" fill="url(#bolt)"/>
    <circle cx="4.5" cy="29.5" r="2.1" fill="url(#bolt)"/>
    <circle cx="59.5" cy="29.5" r="2.1" fill="url(#bolt)"/>
  </g>

  <!-- side handles (small loops on the left/right of the lid rim) -->
  <rect x="0" y="12" width="2.5" height="11" rx="1" fill="{STEEL_EDGE}"/>
  <rect x="61.5" y="12" width="2.5" height="11" rx="1" fill="{STEEL_EDGE}"/>
  <rect x="0.5" y="13" width="1.5" height="9" rx="0.7" fill="{STEEL_RIM_LIGHT}"/>
  <rect x="62" y="13" width="1.5" height="9" rx="0.7" fill="{STEEL_RIM_MID}"/>
</svg>
"""


def render_svg(svg: str, width: int, height: int, supersample: int = 4) -> Image.Image:
    """Rasterise at `supersample`x and box-downscale for smooth edges."""
    png = cairosvg.svg2png(
        bytestring=svg.encode("utf-8"),
        output_width=width * supersample,
        output_height=height * supersample,
    )
    image = Image.open(io.BytesIO(png)).convert("RGBA")
    return image.resize((width, height), Image.LANCZOS)


def grunge(image: Image.Image, strength: float = 0.16, seed: int = 7) -> Image.Image:
    """Multiply RGB by layered noise + a few dark stains so metal reads as worn."""
    rng = numpy.random.default_rng(seed)
    width, height = image.size

    def blurred_noise(cell: int, sigma: float) -> numpy.ndarray:
        coarse = rng.normal(0.0, 1.0, (height // cell + 2, width // cell + 2))
        coarse_image = Image.fromarray(((coarse * 40) + 128).clip(0, 255).astype("uint8"))
        coarse_image = coarse_image.resize((width, height), Image.BICUBIC).filter(ImageFilter.GaussianBlur(sigma))
        return (numpy.asarray(coarse_image, dtype="float32") - 128) / 40

    noise = blurred_noise(6, 0.8) * 0.55 + blurred_noise(2, 0.3) * 0.3 + rng.normal(0.0, 1.0, (height, width)) * 0.25
    factor = 1.0 + noise * strength

    # sparse dark stains: threshold a very low-frequency field
    stains = blurred_noise(5, 0.7) * 0.7 + blurred_noise(2, 0.3) * 0.3
    stain_mask = numpy.clip((stains - 1.0) * 1.2, 0, 1) * 0.6
    rust = numpy.array([1.0, 0.74, 0.55], dtype="float32")  # multiply toward rust orange
    factor_rgb = factor[..., None] * (1.0 - stain_mask[..., None] * (1.0 - rust)) * (1.0 - stain_mask[..., None] * 0.10)

    pixels = numpy.asarray(image, dtype="float32")
    pixels[..., :3] = (pixels[..., :3] * factor_rgb).clip(0, 255)
    return Image.fromarray(pixels.astype("uint8"), "RGBA")


def build_entity() -> Image.Image:
    sprite = render_svg(chest_svg(64, 80, "0 0 64 80"), 64, 80)
    return grunge(sprite)


def build_shadow() -> Image.Image:
    """Opaque black footprint; the engine tints/blends draw_as_shadow layers."""
    shadow = Image.new("RGBA", (110, 46), (0, 0, 0, 0))
    mask = Image.new("L", (110 * 4, 46 * 4), 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, 109 * 4, 42 * 4), radius=10, fill=255)
    mask = mask.resize((110, 46), Image.LANCZOS)
    shadow.putalpha(mask)
    return shadow


def build_icon() -> Image.Image:
    """64x64 icon plus 32/16/8 mipmaps laid out horizontally (120x64)."""
    # Crop the design to the chest body and letterbox into a square.
    base = render_svg(chest_svg(64, 74, "0 0 64 74"), 64, 74)
    base = grunge(base, strength=0.12)
    icon = Image.new("RGBA", (64, 64), (0, 0, 0, 0))
    scaled = base.resize((56, 64), Image.LANCZOS)
    icon.alpha_composite(scaled, (4, 0))

    sheet = Image.new("RGBA", (120, 64), (0, 0, 0, 0))
    x = 0
    for size in (64, 32, 16, 8):
        level = icon if size == 64 else icon.resize((size, size), Image.LANCZOS)
        sheet.alpha_composite(level, (x, 0))
        x += size
    return sheet


def main() -> None:
    (HERE / "entity").mkdir(exist_ok=True)
    (HERE / "icons").mkdir(exist_ok=True)
    build_entity().save(HERE / "entity" / "auto-loader-chest.png")
    build_shadow().save(HERE / "entity" / "auto-loader-chest-shadow.png")
    build_icon().save(HERE / "icons" / "auto-loader-chest.png")
    print("wrote entity/auto-loader-chest.png, entity/auto-loader-chest-shadow.png, icons/auto-loader-chest.png")


if __name__ == "__main__":
    os.chdir(HERE)
    main()
