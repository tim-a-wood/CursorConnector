#!/usr/bin/env python3
"""Generate app icon: black background, minimal white cursor."""

from PIL import Image, ImageDraw

BLACK = (0, 0, 0)
WHITE = (255, 255, 255)


def cursor_polygon(size):
    """Minimal cursor arrow (top-left pointing), scaled to ~35% of canvas, upper-left."""
    s = size
    scale = 0.35 * s
    pad = 0.12 * s
    # Arrow: tip (0,0), head corner, stem end, stem inner, back to head
    return [
        (pad, pad + scale * 0.45),
        (pad + scale * 0.45, pad),
        (pad + scale * 0.5, pad),
        (pad + scale * 0.5, pad + scale * 0.85),
        (pad + scale * 0.38, pad + scale * 0.7),
    ]


def draw_icon(canvas_size):
    img = Image.new("RGB", (canvas_size, canvas_size), BLACK)
    draw = ImageDraw.Draw(img)
    poly = cursor_polygon(canvas_size)
    draw.polygon(poly, fill=WHITE, outline=None)
    return img


def main():
    out_dir = "."
    sizes = [
        (120, "Icon-120.png"),
        (180, "Icon-180.png"),
        (152, "Icon-152.png"),
        (1024, "AppIcon.png"),
    ]
    for size, name in sizes:
        img = draw_icon(size)
        img.save(f"{out_dir}/{name}", "PNG")
        print(f"Wrote {name}")


if __name__ == "__main__":
    main()
