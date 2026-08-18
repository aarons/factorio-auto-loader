#!/usr/bin/env python3
"""Builds the Auto-Loader chest artwork from an SVG design.

Outputs (relative to this file), sized to match the vanilla 1x1 chests:
  entity/auto-loader-chest.png         64x80 entity sprite (scale 0.5 in-game)
  entity/auto-loader-chest-shadow.png  110x46 shadow, drawn with draw_as_shadow
  entity/auto-loader-chest-connector-<style>.png    64x80 circuit-connector overlay,
                                                    one per CONNECTOR_STYLES entry
  icons/auto-loader-chest.png          120x64 icon with 64/32/16/8 mipmaps
  ../thumbnail.png                     256x256 mod-portal thumbnail (icon x4)

Run with the venv created next to this file:
  graphics/.venv/bin/python graphics/build_art.py
  graphics/.venv/bin/python graphics/build_art.py --preview /some/dir   # + comparison sheet

The SVG is authored in sprite pixel coordinates (64x80): lit top face above, a
darker front face below. cairosvg rasterises it, then a light noise pass in
Pillow keeps it from reading as flat vector art.
"""

from __future__ import annotations

import io
import os
from dataclasses import dataclass
from pathlib import Path
from typing import Callable

import cairosvg
import numpy
from PIL import Image, ImageDraw, ImageFilter, ImageFont

HERE = Path(__file__).resolve().parent

# Palette: blue-steel body, hazard yellow intake, cyan status lights.
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
COPPER_LIGHT = "#f2b98e"
COPPER_MID = "#c9743d"
COPPER_DARK = "#743a19"


def svg_open(width: int, height: int, view_box: str) -> str:
    """Opening tag plus the shared gradient/pattern defs, so every sprite drawn
    in the 64x80 chest coordinate space shades identically."""
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
    <linearGradient id="copper" x1="0" y1="0" x2="1" y2="0">
      <stop offset="0" stop-color="{COPPER_MID}"/>
      <stop offset="0.35" stop-color="{COPPER_LIGHT}"/>
      <stop offset="1" stop-color="{COPPER_DARK}"/>
    </linearGradient>
    <linearGradient id="slat" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="{STEEL_FRONT_LIGHT}"/>
      <stop offset="1" stop-color="{STEEL_FRONT_MID}"/>
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
"""


def chest_svg(width: int, height: int, view_box: str) -> str:
    """The chest design in 64x80 sprite coordinates.

    Layout (y): lid top face 1..33, lid thickness 33..38, front face 38..74.
    `view_box` selects the region rendered (the icon uses a tighter crop).
    """
    return svg_open(width, height, view_box) + f"""
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


# --- Circuit connector overlays --------------------------------------------------
#
# Factorio draws CircuitConnectorSprites.connector_main on top of the entity
# picture only while a wire is attached, so these overlays are how the chest
# changes its look when wired. Several styles are built side by side so they
# can be compared in-game; CONNECTOR_STYLE in data.lua picks the one used.
#
# Every overlay is authored on the same 64x80 canvas as the entity sprite (only
# its patch of the front panel is opaque) so data.lua can reuse the entity
# layer's shift. The engine crops transparent borders at load, so the empty
# canvas is free.
#
# No LED sprites: the connector's red/green LEDs show circuit *write* mode and
# the blue one *read* mode (FFF-210), and a linked-container has neither, so
# data.lua gives the (mandatory) LED slots empty sprites.
#
# The panel the overlays repaint is x 8..56, y 49..68 (see chest_svg): three
# horizontal slats separated by dark rib lines at y 55.5 and 62.5, each slat
# with a lit line 1px below its top edge (y 49.5, 56.5, 63.5).
PANEL_TOP, PANEL_BOTTOM = 49.0, 68.0
RIB_UPPER, RIB_LOWER = 55.5, 62.5


@dataclass(frozen=True)
class ConnectorStyle:
    """One wired-look variant. Pin coordinates are sprite px; data.lua carries
    a matching CONNECTOR_STYLES table, so keep the two in sync."""

    description: str
    svg: Callable[[], str]
    wire_pin_red: tuple[float, float]
    wire_pin_green: tuple[float, float]


# --- "mouth": the original bite -------------------------------------------------
#
# The front-panel slats part around a dark bite gap and the wire ends on pins
# inside it -- the chest is biting the wire.
BITE_CENTER = (32.0, 59.0)  # sprite px; middle of the ribbed front panel
BITE_RADIUS_X = 8.0
BITE_RADIUS_Y = 4.5
MOUTH_PIN_RED = (28.0, 59.0)
MOUTH_PIN_GREEN = (36.0, 59.0)


def mouth_svg() -> str:
    """Parted slats + bite gap + wire pins, drawn over the ribbed front panel.
    Only x 20..44 is repainted."""
    cx, cy = BITE_CENTER
    rx, ry = BITE_RADIUS_X, BITE_RADIUS_Y
    left, right = 20, 44
    # Rib lines bow away from the gap; a quadratic's apex sits at
    # 0.25*P0 + 0.5*P1 + 0.25*P2, so control y = apex - (base - apex).
    upper_apex = cy - ry - 0.5
    lower_apex = cy + ry + 0.5
    upper_control = 2 * upper_apex - RIB_UPPER
    lower_control = 2 * lower_apex - RIB_LOWER
    upper_rib = f"M{left} {RIB_UPPER} L{cx - rx - 2} {RIB_UPPER} Q{cx} {upper_control} {cx + rx + 2} {RIB_UPPER} L{right} {RIB_UPPER}"
    lower_rib = f"M{left} {RIB_LOWER} L{cx - rx - 2} {RIB_LOWER} Q{cx} {lower_control} {cx + rx + 2} {RIB_LOWER} L{right} {RIB_LOWER}"
    upper_lit = f"M{left} {RIB_UPPER + 1} L{cx - rx - 2} {RIB_UPPER + 1} Q{cx} {upper_control + 1} {cx + rx + 2} {RIB_UPPER + 1} L{right} {RIB_UPPER + 1}"
    lower_lit = f"M{left} {RIB_LOWER + 1} L{cx - rx - 2} {RIB_LOWER + 1} Q{cx} {lower_control + 1} {cx + rx + 2} {RIB_LOWER + 1} L{right} {RIB_LOWER + 1}"

    # Teeth: small wedges pointing into the gap from its top and bottom edges.
    teeth = []
    for i in range(-2, 3):
        tx = cx + i * 3.0
        h = 1.6 if i != 0 else 1.2
        teeth.append(f'<path d="M{tx - 1.1} {cy - ry + 0.3} L{tx + 1.1} {cy - ry + 0.3} L{tx} {cy - ry + 0.3 + h} Z"/>')
        teeth.append(f'<path d="M{tx - 1.1} {cy + ry - 0.3} L{tx + 1.1} {cy + ry - 0.3} L{tx} {cy + ry - 0.3 - h} Z"/>')
    teeth_svg = "\n    ".join(teeth)

    def pin(x: float, y: float) -> str:
        return f"""
    <circle cx="{x}" cy="{y}" r="2.1" fill="{STEEL_EDGE}"/>
    <circle cx="{x}" cy="{y}" r="1.5" fill="url(#brass)"/>
    <circle cx="{x - 0.4}" cy="{y - 0.4}" r="0.6" fill="{BRASS_LIGHT}"/>"""

    return svg_open(64, 80, "0 0 64 80") + f"""
  <!-- repaint the panel strip so the straight rib lines vanish under the bite -->
  <rect x="{left}" y="{PANEL_TOP}" width="{right - left}" height="{PANEL_BOTTOM - PANEL_TOP}" fill="url(#front)"/>

  <!-- ribs bowing around the gap -->
  <g fill="none" stroke="{STEEL_EDGE}" stroke-width="1.2">
    <path d="{upper_rib}"/>
    <path d="{lower_rib}"/>
  </g>
  <g fill="none" stroke="#ffffff" stroke-width="1" opacity="0.16">
    <path d="{upper_lit}"/>
    <path d="{lower_lit}"/>
  </g>

  <!-- the bite gap: dark opening with a lit upper lip -->
  <ellipse cx="{cx}" cy="{cy}" rx="{rx + 0.8}" ry="{ry + 0.8}" fill="{STEEL_EDGE}"/>
  <ellipse cx="{cx}" cy="{cy}" rx="{rx}" ry="{ry}" fill="url(#intake)"/>
  <path d="M{cx - rx} {cy} A{rx} {ry} 0 0 1 {cx + rx} {cy}" fill="none" stroke="#ffffff" stroke-opacity="0.22" stroke-width="0.8"/>

  <!-- teeth -->
  <g fill="{STEEL_TOP_LIGHT}" stroke="{STEEL_EDGE}" stroke-width="0.35">
    {teeth_svg}
  </g>

  <!-- wire pins the red / green wires terminate on -->
  {pin(*MOUTH_PIN_RED)}
  {pin(*MOUTH_PIN_GREEN)}
</svg>
"""


# --- "hatch" / "hatch-open" / "socket": copper leads in a terminal bay ----------
#
# No lips: a shallow terminal bay is cut into the middle slat and two copper
# leads stand in it. In the hatch styles the section of slat covering the bay
# has slid up over the slat above (proud, with a drop shadow), which is what
# uncovers the leads -- read literally it is a sliding access cover, read
# loosely it is a lip lifting off two teeth.
BAY_LEFT, BAY_RIGHT = 22.0, 42.0  # x extent of the bay / the sliding slat section
LEAD_X = (28.0, 36.0)  # red, green
LEAD_HALF_WIDTH = 1.5
LEAD_TOP = RIB_UPPER + 1.2  # y of the leads' rounded tops (in the bay's shadow)
LEAD_FOOT = RIB_LOWER - 0.4  # y where the leads meet the bay floor


def copper_lead(x: float, top: float) -> str:
    """A short copper post with a rounded head, standing on the bay floor."""
    return f"""
    <rect x="{x - LEAD_HALF_WIDTH - 0.4}" y="{top - 0.4}" width="{2 * LEAD_HALF_WIDTH + 0.8}" height="{LEAD_FOOT - top + 0.4}" rx="{LEAD_HALF_WIDTH + 0.4}" fill="{STEEL_EDGE}"/>
    <rect x="{x - LEAD_HALF_WIDTH}" y="{top}" width="{2 * LEAD_HALF_WIDTH}" height="{LEAD_FOOT - top}" rx="{LEAD_HALF_WIDTH}" fill="url(#copper)"/>
    <line x1="{x - 0.45}" y1="{top + 1.1}" x2="{x - 0.45}" y2="{LEAD_FOOT - 0.9}" stroke="{COPPER_LIGHT}" stroke-opacity="0.85" stroke-width="0.5"/>
    <circle cx="{x}" cy="{top + 1.1}" r="0.55" fill="{COPPER_DARK}" fill-opacity="0.75"/>"""


def bay_svg(left: float, right: float, top: float, bottom: float, lead_top: float) -> str:
    """Dark recess with a framed edge, lit left wall and floor, and the two leads."""
    leads = "".join(copper_lead(x, lead_top) for x in LEAD_X)
    return f"""
  <!-- terminal bay cut into the slat -->
  <rect x="{left - 0.6}" y="{top - 0.6}" width="{right - left + 1.2}" height="{bottom - top + 1.2}" rx="0.6" fill="{STEEL_EDGE}"/>
  <rect x="{left}" y="{top}" width="{right - left}" height="{bottom - top}" rx="0.3" fill="url(#intake)"/>
  <line x1="{left + 0.4}" y1="{top}" x2="{left + 0.4}" y2="{bottom}" stroke="#ffffff" stroke-opacity="0.12" stroke-width="0.6"/>
  <line x1="{left}" y1="{bottom - 0.4}" x2="{right}" y2="{bottom - 0.4}" stroke="#ffffff" stroke-opacity="0.10" stroke-width="0.6"/>

  <!-- copper leads the red / green wires terminate on -->
  <g>{leads}
  </g>"""


def hatch_svg(slide: float) -> str:
    """The middle slat section over the bay slid up by `slide` px.

    slide < RIB_LOWER - RIB_UPPER leaves the slat's lower edge hanging over the
    bay, so the leads peek out from under it; slide of a full slat height
    parks it flush on the slat above and opens the whole bay.
    """
    slat_top = RIB_UPPER - slide
    slat_bottom = RIB_LOWER - slide
    return svg_open(64, 80, "0 0 64 80") + f"""
  <!-- repaint the strip so the ribs, lit lines and slat all restart cleanly -->
  <rect x="{BAY_LEFT - 2}" y="{PANEL_TOP}" width="{BAY_RIGHT - BAY_LEFT + 4}" height="{PANEL_BOTTOM - PANEL_TOP}" fill="url(#front)"/>
  <g stroke="{STEEL_EDGE}" stroke-width="1.2">
    <line x1="{BAY_LEFT - 2}" y1="{RIB_UPPER}" x2="{BAY_RIGHT + 2}" y2="{RIB_UPPER}"/>
    <line x1="{BAY_LEFT - 2}" y1="{RIB_LOWER}" x2="{BAY_RIGHT + 2}" y2="{RIB_LOWER}"/>
  </g>
  <g stroke="#ffffff" stroke-width="1" opacity="0.16">
    <line x1="{BAY_LEFT - 2}" y1="{PANEL_TOP + 0.5}" x2="{BAY_RIGHT + 2}" y2="{PANEL_TOP + 0.5}"/>
    <line x1="{BAY_LEFT - 2}" y1="{RIB_UPPER + 1}" x2="{BAY_RIGHT + 2}" y2="{RIB_UPPER + 1}"/>
    <line x1="{BAY_LEFT - 2}" y1="{RIB_LOWER + 1}" x2="{BAY_RIGHT + 2}" y2="{RIB_LOWER + 1}"/>
  </g>
{bay_svg(BAY_LEFT, BAY_RIGHT, RIB_UPPER, RIB_LOWER, LEAD_TOP)}

  <!-- the slid slat section: drop shadow (light is top-left), then the plate -->
  <rect x="{BAY_LEFT + 0.6}" y="{slat_top + 0.8}" width="{BAY_RIGHT - BAY_LEFT + 0.6}" height="{slat_bottom - slat_top + 0.8}" rx="0.8" fill="#000000" fill-opacity="0.45"/>
  <rect x="{BAY_LEFT}" y="{slat_top}" width="{BAY_RIGHT - BAY_LEFT}" height="{slat_bottom - slat_top}" rx="0.7" fill="{STEEL_EDGE}"/>
  <rect x="{BAY_LEFT + 0.6}" y="{slat_top + 0.6}" width="{BAY_RIGHT - BAY_LEFT - 1.2}" height="{slat_bottom - slat_top - 1.2}" rx="0.4" fill="url(#slat)"/>
  <line x1="{BAY_LEFT + 1}" y1="{slat_top + 1.1}" x2="{BAY_RIGHT - 1}" y2="{slat_top + 1.1}" stroke="#ffffff" stroke-opacity="0.28" stroke-width="0.8"/>
  <line x1="{BAY_LEFT + 1}" y1="{slat_bottom - 1.0}" x2="{BAY_RIGHT - 1}" y2="{slat_bottom - 1.0}" stroke="#000000" stroke-opacity="0.30" stroke-width="0.7"/>
  <!-- finger pull -->
  <rect x="29.5" y="{slat_top + 2.4}" width="5" height="1.4" rx="0.7" fill="{STEEL_EDGE}" fill-opacity="0.8"/>
  <line x1="30" y1="{slat_top + 4.1}" x2="34" y2="{slat_top + 4.1}" stroke="#ffffff" stroke-opacity="0.18" stroke-width="0.6"/>
</svg>
"""


SOCKET_LEFT, SOCKET_RIGHT = 24.5, 39.5
SOCKET_TOP, SOCKET_BOTTOM = RIB_UPPER + 1.0, RIB_LOWER - 0.6


def socket_svg() -> str:
    """No moving parts: a small recessed terminal block let into the middle
    slat, the two copper leads inside it. The quietest of the styles."""
    return svg_open(64, 80, "0 0 64 80") + f"""
  <!-- retaining plate around the socket, flush with the slat -->
  <rect x="{SOCKET_LEFT - 1.8}" y="{SOCKET_TOP - 0.9}" width="{SOCKET_RIGHT - SOCKET_LEFT + 3.6}" height="{SOCKET_BOTTOM - SOCKET_TOP + 1.5}" rx="0.8" fill="{STEEL_EDGE}"/>
  <rect x="{SOCKET_LEFT - 1.3}" y="{SOCKET_TOP - 0.5}" width="{SOCKET_RIGHT - SOCKET_LEFT + 2.6}" height="{SOCKET_BOTTOM - SOCKET_TOP + 0.8}" rx="0.5" fill="url(#slat)"/>
{bay_svg(SOCKET_LEFT, SOCKET_RIGHT, SOCKET_TOP, SOCKET_BOTTOM, SOCKET_TOP + 0.9)}
</svg>
"""


HATCH_SLIDE = 5.0
HATCH_OPEN_SLIDE = RIB_LOWER - RIB_UPPER - 0.5  # parks the slat over the one above

CONNECTOR_STYLES: dict[str, ConnectorStyle] = {
    "mouth": ConnectorStyle(
        "front slats part around a bite gap; brass pins inside",
        mouth_svg,
        MOUTH_PIN_RED,
        MOUTH_PIN_GREEN,
    ),
    "hatch": ConnectorStyle(
        "middle-slat section slides part-way up; copper leads peek out under it",
        lambda: hatch_svg(HATCH_SLIDE),
        (LEAD_X[0], RIB_LOWER - HATCH_SLIDE + 1.6),
        (LEAD_X[1], RIB_LOWER - HATCH_SLIDE + 1.6),
    ),
    "hatch-open": ConnectorStyle(
        "middle-slat section slides fully up; the whole terminal bay is open",
        lambda: hatch_svg(HATCH_OPEN_SLIDE),
        (LEAD_X[0], LEAD_TOP + 1.2),
        (LEAD_X[1], LEAD_TOP + 1.2),
    ),
    "socket": ConnectorStyle(
        "no moving parts; copper leads in a small recessed terminal block",
        socket_svg,
        (LEAD_X[0], SOCKET_TOP + 2.0),
        (LEAD_X[1], SOCKET_TOP + 2.0),
    ),
}


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


def build_connector(style: ConnectorStyle) -> Image.Image:
    """Same canvas + same grunge seed as the entity, so overlay metal matches."""
    return grunge(render_svg(style.svg(), 64, 80))


def build_connector_preview(entity: Image.Image, connectors: dict[str, Image.Image], zoom: int = 6) -> Image.Image:
    """Plain entity beside every style wired up (overlay + fake wires), zoomed
    and labelled, for eyeballing the variants side by side."""
    tile_width, tile_height, origin = 96, 108, (16, 22)
    label_height = 28
    sheet = Image.new(
        "RGBA",
        (tile_width * zoom * (len(connectors) + 1), tile_height * zoom + label_height),
        (0, 0, 0, 255),
    )
    font = ImageFont.load_default(size=18)
    labels = ImageDraw.Draw(sheet)

    def tile(label: str, index: int, paint: Callable[[Image.Image], None]) -> None:
        frame = Image.new("RGBA", (tile_width, tile_height), (96, 72, 48, 255))
        frame.alpha_composite(entity, origin)
        paint(frame)
        zoomed = frame.resize((tile_width * zoom, tile_height * zoom), Image.NEAREST)
        sheet.alpha_composite(zoomed, (index * tile_width * zoom, label_height))
        labels.text((index * tile_width * zoom + 8, 6), label, fill=(230, 230, 230, 255), font=font)

    tile("plain", 0, lambda frame: None)
    for index, (name, connector) in enumerate(connectors.items(), start=1):
        style = CONNECTOR_STYLES[name]

        def paint(frame: Image.Image, connector=connector, style=style) -> None:
            frame.alpha_composite(connector, origin)
            draw = ImageDraw.Draw(frame)
            for (px, py), colour in ((style.wire_pin_red, (232, 48, 40)), (style.wire_pin_green, (54, 200, 70))):
                draw.line((0, 8, origin[0] + px, origin[1] + py), fill=colour, width=1)

        tile(name, index, paint)
    return sheet


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


def build_thumbnail(icon_sheet: Image.Image) -> Image.Image:
    """The 64x64 icon scaled up 4x, nearest-neighbour so pixels stay exact."""
    return icon_sheet.crop((0, 0, 64, 64)).resize((256, 256), Image.NEAREST)


def main(preview_dir: Path | None) -> None:
    (HERE / "entity").mkdir(exist_ok=True)
    (HERE / "icons").mkdir(exist_ok=True)
    entity = build_entity()
    entity.save(HERE / "entity" / "auto-loader-chest.png")
    build_shadow().save(HERE / "entity" / "auto-loader-chest-shadow.png")
    connectors = {}
    for name, style in CONNECTOR_STYLES.items():
        connectors[name] = build_connector(style)
        connectors[name].save(HERE / "entity" / f"auto-loader-chest-connector-{name}.png")
    icon_sheet = build_icon()
    icon_sheet.save(HERE / "icons" / "auto-loader-chest.png")
    build_thumbnail(icon_sheet).save(HERE.parent / "thumbnail.png")
    print(
        "wrote entity/auto-loader-chest.png, entity/auto-loader-chest-shadow.png,"
        f" entity/auto-loader-chest-connector-{{{','.join(CONNECTOR_STYLES)}}}.png,"
        " icons/auto-loader-chest.png, ../thumbnail.png"
    )
    if preview_dir:
        preview_dir.mkdir(parents=True, exist_ok=True)
        build_connector_preview(entity, connectors).save(preview_dir / "connector-preview.png")
        print(f"wrote {preview_dir / 'connector-preview.png'}")


if __name__ == "__main__":
    import argparse

    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--preview", metavar="DIR", type=Path, help="also write a zoomed plain-vs-each-style comparison PNG to DIR")
    arguments = parser.parse_args()
    os.chdir(HERE)
    main(arguments.preview)
