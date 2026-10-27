#!/usr/bin/env python3
"""Every app icon, Apple TV layer, Top Shelf banner and web icon, from art/app-icon.png.

Needs Pillow and NumPy. Run from anywhere: python3 apple/scripts/make-icons.py
"""
import base64
import io
from pathlib import Path

import numpy as np
from PIL import Image, ImageFilter

ROOT = Path(__file__).resolve().parents[2]
IOS = ROOT / "apple/OpenIPTV/Resources/Assets.xcassets"
TV = ROOT / "apple/OpenIPTV-tvOS/Resources/Assets.xcassets"
BRAND = TV / "App Icon & Top Shelf Image.brandassets"
WEB = ROOT / "web/public"
ROUND_CORNERS = IOS / "Logo.imageset/Logo.png"


def pixels(image):
    return np.asarray(image, dtype=np.float64)


def picture(array):
    return Image.fromarray(np.clip(np.rint(array), 0, 255).astype(np.uint8))


def blur(array, radius):
    channels = array if array.ndim == 3 else array[..., None]
    out = np.stack([pixels(picture(channels[..., i]).filter(ImageFilter.GaussianBlur(radius))) for i in range(channels.shape[2])], axis=-1)
    return out if array.ndim == 3 else out[..., 0]


def mark_coverage(art):
    """The background has almost no red and the mark's darkest brown has plenty, so red alone separates them."""
    t = np.clip((art[..., 0] - 20) / 90, 0, 1)
    return t * t * (3 - 2 * t)


def without_mark(art, coverage):
    keep = 1 - coverage
    radius = art.shape[0] / 12
    filled = blur(art * keep[..., None], radius) / np.maximum(blur(keep * 255, radius) / 255, 1e-3)[..., None]
    return art * keep[..., None] + filled * coverage[..., None]


def vignette(art, coverage):
    """The background's colour by distance from the centre (0 there, 1 at a corner), read only well clear of the mark and its shadow."""
    h, w = art.shape[:2]
    clear = blur(coverage * 255, h / 16) < 1
    y, x = np.mgrid[0:h, 0:w]
    rings = np.minimum((np.hypot((x - w / 2) / (w / 2), (y - h / 2) / (h / 2)) / np.sqrt(2) * 64).astype(int), 63)
    seen = [art[(rings == r) & clear].mean(axis=0) if ((rings == r) & clear).any() else None for r in range(64)]
    first = next(c for c in seen if c is not None)
    profile, last = [], first
    for c in seen:
        last = last if c is None else c
        profile.append(last)
    profile = np.array(profile)
    padded = np.concatenate([np.repeat(profile[:1], 8, axis=0), profile, np.repeat(profile[-1:], 8, axis=0)])
    return np.stack([np.convolve(padded[:, i], np.ones(17) / 17, mode="valid") for i in range(3)], axis=-1)


def backdrop(profile, size):
    w, h = size
    y, x = np.mgrid[0:h, 0:w]
    distance = np.minimum(np.hypot((x - w / 2) / (w / 2), (y - h / 2) / (h / 2)) / np.sqrt(2), 1) * (len(profile) - 1)
    return np.stack([np.interp(distance, np.arange(len(profile)), profile[:, i]) for i in range(3)], axis=-1)


def mark_alone(art, coverage, back):
    """The mark on transparency, its edge colours freed of the background, cropped to its bounds."""
    k = np.maximum(coverage, 1e-6)[..., None]
    colour = np.clip((art - (1 - k) * back) / k, 0, 255)
    rgba = picture(np.dstack([colour, coverage * 255]))
    return rgba.crop(rgba.getchannel("A").getbbox())


def stage(profile, figure, size, height_share):
    """A backdrop with the mark's soft shadow, and the mark on its own layer above it."""
    w, h = size
    fig = figure.copy()
    fig.thumbnail((w, round(h * height_share)), Image.LANCZOS)
    at = ((w - fig.size[0]) // 2, (h - fig.size[1]) // 2)
    softness = fig.size[1] * 0.05
    shadow = Image.new("L", size)
    shadow.paste(fig.getchannel("A"), (at[0], at[1] + round(softness * 0.8)))
    darkness = pixels(shadow.filter(ImageFilter.GaussianBlur(softness))) / 255 * 0.4
    back = picture(backdrop(profile, size) * (1 - darkness)[..., None])
    front = Image.new("RGBA", size)
    front.paste(fig, at)
    return back, front


def rounded(art, size):
    out = art.resize((size, size), Image.LANCZOS).convert("RGBA")
    out.putalpha(Image.open(ROUND_CORNERS).getchannel("A").resize((size, size), Image.LANCZOS))
    return out


def save(image, path):
    path.parent.mkdir(parents=True, exist_ok=True)
    image.save(path, optimize=True)


def main():
    art_image = Image.open(ROOT / "art/app-icon.png").convert("RGB")
    art = pixels(art_image)
    coverage = mark_coverage(art)
    back = without_mark(art, coverage)
    profile = vignette(art, coverage)
    figure = mark_alone(art, coverage, back)

    save(art_image.resize((1024, 1024), Image.LANCZOS), IOS / "AppIcon.appiconset/AppIcon.png")
    logo = rounded(art_image, 288)
    for catalog in (IOS, TV):
        save(logo, catalog / "Logo.imageset/Logo.png")

    for stack, sizes in {"App Icon.imagestack": {"1x": (400, 240), "2x": (800, 480)},
                         "App Icon - App Store.imagestack": {"1x": (1280, 768)}}.items():
        for scale, size in sizes.items():
            base, layer = stage(profile, figure, size, 0.62)
            save(base, BRAND / stack / f"Back.imagestacklayer/Content.imageset/back@{scale}.png")
            save(layer, BRAND / stack / f"Front.imagestacklayer/Content.imageset/front@{scale}.png")
    for shelf, (w, h) in {"Top Shelf Image.imageset": (1920, 720), "Top Shelf Image Wide.imageset": (2320, 720)}.items():
        for scale in (1, 2):
            base, layer = stage(profile, figure, (w * scale, h * scale), 0.45)
            base.paste(layer, (0, 0), layer)
            save(base, BRAND / shelf / f"shelf@{scale}x.png")

    save(art_image.resize((180, 180), Image.LANCZOS), WEB / "apple-touch-icon.png")
    for size in (192, 512):
        save(art_image.resize((size, size), Image.LANCZOS), WEB / f"icon-{size}.png")
    png = io.BytesIO()
    rounded(art_image, 128).save(png, format="PNG", optimize=True)
    svg = ('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 128 128" role="img" aria-label="Openreel">'
           '<title>Openreel</title>'
           f'<image width="128" height="128" href="data:image/png;base64,{base64.b64encode(png.getvalue()).decode()}"/></svg>\n')
    for path in (ROOT / "favicon.svg", WEB / "favicon.svg"):
        path.write_text(svg)


if __name__ == "__main__":
    main()
