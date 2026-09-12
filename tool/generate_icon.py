"""Generates the launcher icon from the app's own palette.

Checked in rather than run at build time: an icon is a design decision, not a
build artefact, and the reviewer should be able to see how it was made. Run it
only when the icon should change.

    python tool/generate_icon.py

Writes:
    assets/icon/icon.png             1024px, full icon (legacy Android + iOS)
    assets/icon/icon_foreground.png  1024px, motif only on transparency, kept
                                     inside Android's 66% adaptive-icon safe
                                     zone so the launcher mask cannot clip it
"""

import math
import os

from PIL import Image, ImageDraw

# Straight from lib/ui/theme.dart, so the icon and the app agree.
BACKGROUND = (14, 17, 22, 255)  # RunTheme.background
ROUTE = (34, 197, 94, 255)  # RunTheme.running
END_DOT = (56, 189, 248, 255)  # RunTheme.route

SIZE = 1024
SUPERSAMPLE = 4  # draw big, shrink down: cheap, reliable anti-aliasing
CANVAS = SIZE * SUPERSAMPLE


def cubic_bezier(t, p0, p1, p2, p3):
    """A point at `t` along the curve, in normalised 0..1 coordinates."""
    u = 1 - t
    x = (
        u**3 * p0[0]
        + 3 * u**2 * t * p1[0]
        + 3 * u * t**2 * p2[0]
        + t**3 * p3[0]
    )
    y = (
        u**3 * p0[1]
        + 3 * u**2 * t * p1[1]
        + 3 * u * t**2 * p2[1]
        + t**3 * p3[1]
    )
    return x, y


def stamp(draw, x, y, radius, colour):
    draw.ellipse(
        [x - radius, y - radius, x + radius, y + radius],
        fill=colour,
    )


def draw_route(draw, scale, offset, stroke, hole):
    """A stylised run route: one winding line, a start ring, an end dot.

    Drawn as densely stamped circles rather than polygon segments, which gives
    round caps and joins for free and keeps the curve smooth at any size.

    `hole` is what gets punched through the start ring. It has to be the solid
    background on the legacy icon -- punching transparency there would let the
    user's wallpaper show through a hole in the middle of the mark -- while the
    adaptive foreground punches real transparency and lets the adaptive
    background layer, which is the same colour, show through instead.
    """
    # An S-curve that reads as a route rather than a generic swoosh.
    p0, p1, p2, p3 = (0.24, 0.80), (0.12, 0.30), (0.90, 0.70), (0.72, 0.20)

    def to_px(point):
        return (
            offset + point[0] * scale,
            offset + point[1] * scale,
        )

    steps = 900
    for i in range(steps + 1):
        x, y = to_px(cubic_bezier(i / steps, p0, p1, p2, p3))
        stamp(draw, x, y, stroke / 2, ROUTE)

    # Start: a hollow ring, the way a map marks where a track begins.
    start_x, start_y = to_px(p0)
    stamp(draw, start_x, start_y, stroke * 1.15, ROUTE)
    stamp(draw, start_x, start_y, stroke * 0.52, hole)

    # End: a solid dot in the route colour used on the summary map.
    end_x, end_y = to_px(p3)
    stamp(draw, end_x, end_y, stroke * 1.3, hole)
    stamp(draw, end_x, end_y, stroke * 1.0, END_DOT)


def render(with_background, safe_zone_fraction):
    """Renders one icon variant.

    `safe_zone_fraction` is how much of the canvas the motif may occupy. Android
    masks adaptive icons down to roughly the middle 66%, so the foreground
    layer has to be drawn smaller than the legacy icon.
    """
    image = Image.new(
        "RGBA",
        (CANVAS, CANVAS),
        BACKGROUND if with_background else (0, 0, 0, 0),
    )
    draw = ImageDraw.Draw(image)

    scale = CANVAS * safe_zone_fraction
    offset = (CANVAS - scale) / 2
    stroke = CANVAS * 0.075

    draw_route(
        draw,
        scale,
        offset,
        stroke,
        hole=BACKGROUND if with_background else (0, 0, 0, 0),
    )
    return image.resize((SIZE, SIZE), Image.LANCZOS)


def main():
    out_dir = os.path.join(
        os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
        "assets",
        "icon",
    )
    os.makedirs(out_dir, exist_ok=True)

    # Legacy / iOS: the motif fills most of a square that is never masked.
    render(with_background=True, safe_zone_fraction=0.68).save(
        os.path.join(out_dir, "icon.png")
    )

    # Adaptive foreground: smaller, so a circular launcher mask cannot clip it.
    render(with_background=False, safe_zone_fraction=0.46).save(
        os.path.join(out_dir, "icon_foreground.png")
    )

    print(f"wrote icon.png and icon_foreground.png to {out_dir}")


if __name__ == "__main__":
    main()
