#!/usr/bin/env python3
"""Every Zapline icon from the mark's geometry: iPhone and iPad (light, dark and tinted), the in-app logo,
the Apple TV layers and Top Shelf banners, and the web icons.

Needs Pillow and NumPy. Run from anywhere: python3 apple/scripts/make-icons.py
"""
import json
from dataclasses import dataclass
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parents[2]
IOS = ROOT / "apple/OpenIPTV/Resources/Assets.xcassets"
TV = ROOT / "apple/OpenIPTV-tvOS/Resources/Assets.xcassets"
BRAND = TV / "App Icon & Top Shelf Image.brandassets"
WEB = ROOT / "web/public"
ROUND_CORNERS = IOS / "Logo.imageset/Logo.png"
SUPERSAMPLE = 4

# The mark on a 1024 grid: the Z is what's on now, the pale blocks are the shows before and after.
STROKE = 112
NOW = [(532, 342), (736, 342), (288, 682), (492, 682)]
BEFORE_AND_AFTER = [[(288, 342), (380, 342)], [(644, 682), (736, 682)]]
MARK_BOX = (232, 286, 792, 738)


@dataclass(frozen=True)
class Theme:
    ground: tuple
    blocks: str
    ink: tuple
    halo: str
    halo_opacity: float
    halo_blur: float
    halo_drop: float


LIGHT = Theme(("#FFFFFF", "#E8EDFB"), "#B0BDFF", ("#3E5EFF", "#1B32D4"), "#1B32D4", 0.22, 34, 26)
DARK = Theme(("#121A46", "#060A20"), "#2B397F", ("#7A90FF", "#4560FF"), "#4560FF", 0.45, 40, 0)
TINTED = Theme(("#000000", "#000000"), "#5A5A5A", ("#FFFFFF", "#FFFFFF"), "#000000", 0.0, 1, 0)


def rgb(hex_color):
    return np.array([int(hex_color[i:i + 2], 16) for i in (1, 3, 5)], dtype=np.float64)


@dataclass(frozen=True)
class Place:
    """Where the 1024 grid lands on a canvas: its scale and the canvas point under the grid's centre."""
    width: int
    height: int
    scale: float
    x: float
    y: float

    def point(self, p, drop=0.0):
        return (self.x + (p[0] - 512) * self.scale, self.y + (p[1] + drop - 512) * self.scale)


def stroke_mask(place, paths, drop=0.0):
    big = Image.new("L", (place.width * SUPERSAMPLE, place.height * SUPERSAMPLE))
    pen = ImageDraw.Draw(big)
    width = STROKE * place.scale * SUPERSAMPLE
    for path in paths:
        points = [tuple(c * SUPERSAMPLE for c in place.point(p, drop)) for p in path]
        pen.line(points, fill=255, width=round(width))
        for x, y in points:
            pen.ellipse((x - width / 2, y - width / 2, x + width / 2, y + width / 2), fill=255)
    return np.asarray(big.resize((place.width, place.height), Image.LANCZOS), dtype=np.float64) / 255


def ground(place, theme):
    top, bottom = rgb(theme.ground[0]), rgb(theme.ground[1])
    t = np.linspace(0, 1, place.height)[:, None, None]
    return np.broadcast_to(top + (bottom - top) * t, (place.height, place.width, 3)).copy()


def ink(place, theme):
    x0, y0 = place.point(MARK_BOX[:2])
    x1, y1 = place.point(MARK_BOX[2:])
    y, x = np.mgrid[0:place.height, 0:place.width]
    t = np.clip(((x - x0) * (x1 - x0) + (y - y0) * (y1 - y0)) / ((x1 - x0) ** 2 + (y1 - y0) ** 2), 0, 1)[..., None]
    start, end = rgb(theme.ink[0]), rgb(theme.ink[1])
    return start + (end - start) * t


def blend(under, colour, alpha):
    return under * (1 - alpha[..., None]) + colour * alpha[..., None]


def halo(place, theme):
    mask = stroke_mask(place, [NOW], theme.halo_drop)
    blurred = Image.fromarray(np.uint8(mask * 255)).filter(ImageFilter.GaussianBlur(theme.halo_blur * place.scale))
    return np.asarray(blurred, dtype=np.float64) / 255 * theme.halo_opacity


def mark_layers(place, theme):
    """The pale blocks and the Z, as colour and coverage."""
    blocks = stroke_mask(place, BEFORE_AND_AFTER)
    now = stroke_mask(place, [NOW])
    colour = blend(np.broadcast_to(rgb(theme.blocks), (place.height, place.width, 3)).copy(), ink(place, theme), now)
    return colour, np.maximum(blocks, now)


def scene(place, theme, with_mark=True):
    canvas = blend(ground(place, theme), rgb(theme.halo), halo(place, theme))
    if with_mark:
        colour, coverage = mark_layers(place, theme)
        canvas = blend(canvas, colour, coverage)
    return Image.fromarray(np.uint8(np.clip(np.rint(canvas), 0, 255)))


def mark_only(place, theme):
    colour, coverage = mark_layers(place, theme)
    return Image.fromarray(np.uint8(np.clip(np.rint(np.dstack([colour, coverage * 255])), 0, 255)))


def square(size):
    return Place(size, size, size / 1024, size / 2, size / 2)


def centred(width, height, mark_height_share):
    return Place(width, height, height * mark_height_share / (MARK_BOX[3] - MARK_BOX[1]), width / 2, height / 2)


def rounded(image, size):
    out = image.resize((size, size), Image.LANCZOS).convert("RGBA")
    out.putalpha(Image.open(ROUND_CORNERS).getchannel("A").resize((size, size), Image.LANCZOS))
    return out


def save(image, path):
    path.parent.mkdir(parents=True, exist_ok=True)
    image.save(path, optimize=True)


def app_icon_set():
    folder = IOS / "AppIcon.appiconset"
    variants = {"AppIcon.png": (LIGHT, None), "AppIcon-dark.png": (DARK, "dark"), "AppIcon-tinted.png": (TINTED, "tinted")}
    images = []
    for name, (theme, appearance) in variants.items():
        save(scene(square(1024), theme), folder / name)
        entry = {"filename": name, "idiom": "universal", "platform": "ios", "size": "1024x1024"}
        if appearance:
            entry["appearances"] = [{"appearance": "luminosity", "value": appearance}]
        images.append(entry)
    (folder / "Contents.json").write_text(json.dumps({"images": images, "info": {"author": "xcode", "version": 1}}, indent=2) + "\n")


def favicon_svg():
    def d(path):
        return "M" + " L".join(f"{x} {y}" for x, y in path)
    blocks = "".join(f'<path d="{d(p)}"/>' for p in BEFORE_AND_AFTER)
    return ('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" role="img" aria-label="Zapline">'
            '<title>Zapline</title><defs>'
            f'<linearGradient id="g" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="{LIGHT.ground[0]}"/>'
            f'<stop offset="1" stop-color="{LIGHT.ground[1]}"/></linearGradient>'
            f'<linearGradient id="i" gradientUnits="userSpaceOnUse" x1="{MARK_BOX[0]}" y1="{MARK_BOX[1]}" x2="{MARK_BOX[2]}" '
            f'y2="{MARK_BOX[3]}"><stop offset="0" stop-color="{LIGHT.ink[0]}"/><stop offset="1" stop-color="{LIGHT.ink[1]}"/>'
            '</linearGradient></defs><rect width="1024" height="1024" rx="230" fill="url(#g)"/>'
            f'<g fill="none" stroke-width="{STROKE}" stroke-linecap="round" stroke-linejoin="round">'
            f'<g stroke="{LIGHT.blocks}">{blocks}</g><path stroke="url(#i)" d="{d(NOW)}"/></g></svg>\n')


def main():
    app_icon_set()
    logo = rounded(scene(square(1152), LIGHT), 288)
    for catalog in (IOS, TV):
        save(logo, catalog / "Logo.imageset/Logo.png")

    for stack, sizes in {"App Icon.imagestack": {"1x": (400, 240), "2x": (800, 480)},
                         "App Icon - App Store.imagestack": {"1x": (1280, 768)}}.items():
        for scale, (w, h) in sizes.items():
            place = centred(w, h, 0.6)
            save(scene(place, LIGHT, with_mark=False), BRAND / stack / f"Back.imagestacklayer/Content.imageset/back@{scale}.png")
            save(mark_only(place, LIGHT), BRAND / stack / f"Front.imagestacklayer/Content.imageset/front@{scale}.png")
    for shelf, (w, h) in {"Top Shelf Image.imageset": (1920, 720), "Top Shelf Image Wide.imageset": (2320, 720)}.items():
        for scale in (1, 2):
            save(scene(centred(w * scale, h * scale, 0.42), LIGHT), BRAND / shelf / f"shelf@{scale}x.png")

    for name, size in {"apple-touch-icon.png": 180, "icon-192.png": 192, "icon-512.png": 512}.items():
        save(scene(square(size), LIGHT), WEB / name)
    for path in (ROOT / "favicon.svg", WEB / "favicon.svg"):
        path.write_text(favicon_svg())


if __name__ == "__main__":
    main()
