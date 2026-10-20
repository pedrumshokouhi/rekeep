#!/usr/bin/env python3
"""Composes App Store screenshots from real app captures: a quiet background, one headline,
one supporting line, and the unaltered screenshot. No device bezels, no invented UI."""
import os
from PIL import Image, ImageDraw, ImageFilter, ImageFont

RAW = os.path.expanduser("~/RekeepBuild/appstore/raw")
MAC = os.path.expanduser("~/RekeepBuild/appstore/mac")
OUT = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "docs", "AppStore", "screenshots")
FONT = "/System/Library/Fonts/SFNS.ttf"

LIGHT = dict(bg=(245, 245, 242), ink=(32, 35, 41), sub=(92, 97, 107))
DARK = dict(bg=(17, 19, 24), ink=(236, 237, 239), sub=(164, 169, 178))

def font(size, weight):
    f = ImageFont.truetype(FONT, size)
    f.set_variation_by_name(weight)
    return f

def rounded(img, radius):
    mask = Image.new("L", img.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, img.width - 1, img.height - 1], radius=radius, fill=255)
    out = img.convert("RGBA")
    out.putalpha(mask)
    return out

def shadowed(canvas, img, xy, radius, blur, alpha):
    shadow = Image.new("RGBA", (img.width + blur * 4, img.height + blur * 4), (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rounded_rectangle([blur * 2, blur * 2, blur * 2 + img.width, blur * 2 + img.height], radius=radius, fill=(0, 0, 0, alpha))
    shadow = shadow.filter(ImageFilter.GaussianBlur(blur))
    canvas.alpha_composite(shadow, (xy[0] - blur * 2, xy[1] - blur * 2 + blur // 2))
    canvas.alpha_composite(img, xy)

def text_center(draw, y, text, f, fill, width):
    w = draw.textlength(text, font=f)
    draw.text(((width - w) / 2, y), text, font=f, fill=fill)

def portrait(src, dst, size, title, subtitle, theme, scale, radius, top):
    W, H = size
    canvas = Image.new("RGBA", size, theme["bg"] + (255,))
    d = ImageDraw.Draw(canvas)
    text_center(d, top, title, font(int(W * 0.07), "Semibold"), theme["ink"], W)
    text_center(d, top + int(W * 0.095), subtitle, font(int(W * 0.033), "Regular"), theme["sub"], W)
    shot = Image.open(src).convert("RGB")
    sw = int(W * scale)
    sh = int(shot.height * sw / shot.width)
    shot = rounded(shot.resize((sw, sh), Image.LANCZOS), int(radius * sw / shot.width))
    y = top + int(W * 0.17)
    shadowed(canvas, shot, ((W - sw) // 2, y), int(radius * sw / Image.open(src).width), 30, 60 if theme is LIGHT else 140)
    canvas.convert("RGB").save(dst, optimize=True)

def mac(shelf, dst, title, subtitle, theme, preview=None):
    W, H = 2880, 1800
    canvas = Image.new("RGBA", (W, H), theme["bg"] + (255,))
    # A soft, original backdrop so the shelf reads as floating over a desktop.
    glow = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    gd = ImageDraw.Draw(glow)
    tint = (54, 183, 151, 46) if theme is LIGHT else (54, 183, 151, 34)
    gd.ellipse([W * 0.55, -H * 0.3, W * 1.25, H * 0.75], fill=tint)
    gd.ellipse([-W * 0.25, H * 0.15, W * 0.45, H * 1.1], fill=(32, 35, 41, 22) if theme is LIGHT else (230, 232, 235, 14))
    canvas.alpha_composite(glow.filter(ImageFilter.GaussianBlur(220)))
    d = ImageDraw.Draw(canvas)
    text_center(d, 150, title, font(118, "Semibold"), theme["ink"], W)
    text_center(d, 300, subtitle, font(56, "Regular"), theme["sub"], W)
    s = Image.open(shelf).convert("RGBA")
    margin = 56  # transparent shadow margin baked into the render, at 2×
    scale = (W - 2 * 32 * 2) / (s.width - 2 * margin)
    s = s.resize((int(s.width * scale), int(s.height * scale)), Image.LANCZOS)
    sx = (W - s.width) // 2
    sy = H - s.height + int(margin * scale) - 28 * 2
    if preview:
        p = Image.open(preview).convert("RGBA")
        p = p.resize((int(p.width * scale), int(p.height * scale)), Image.LANCZOS)
        canvas.alpha_composite(p, (int(W * 0.18), sy - p.height + int(60 * scale)))
    canvas.alpha_composite(s, (sx, sy))
    canvas.convert("RGB").save(dst, optimize=True)

if __name__ == "__main__":
    os.makedirs(OUT, exist_ok=True)
    iphone = [
        ("iphone-1-feed.png", "Everything you copy, kept.", "Text, links, images, colors, and code.", LIGHT),
        ("iphone-2-search.png", "Find anything in seconds.", "Search text, links, notes, and tags.", LIGHT),
        ("iphone-3-keyboard.png", "Type any clip, anywhere.", "The Rekeep keyboard puts clips one tap away.", LIGHT),
        ("iphone-4-compose.png", "Turn clips into something finished.", "Compose briefs, emails, and reference lists.", LIGHT),
        ("iphone-5-dark.png", "Private by design.", "Saved on your device. No account. No tracking.", DARK),
    ]
    for i, (src, t, s, th) in enumerate(iphone, 1):
        p = os.path.join(RAW, src)
        if os.path.exists(p):
            portrait(p, os.path.join(OUT, f"iPhone-6.3-{i}.png"), (1206, 2622), t, s, th, scale=0.80, radius=150, top=150)
    ipad = [
        ("ipad-1-grid.png", "Your clipboard, organized.", "Collections, favorites, and snippets.", LIGHT),
        ("ipad-3-search.png", "Find anything in seconds.", "Search across everything you’ve kept.", LIGHT),
        ("ipad-2-dark.png", "Calm in light and dark.", "Designed for iPad, with keyboard and drag and drop.", DARK),
    ]
    for i, (src, t, s, th) in enumerate(ipad, 1):
        p = os.path.join(RAW, src)
        if os.path.exists(p):
            portrait(p, os.path.join(OUT, f"iPad-13-{i}.png"), (2064, 2752), t, s, th, scale=0.80, radius=50, top=110)
    if os.path.isdir(MAC):
        mac(f"{MAC}/light-shelf/light-panel-1.png", os.path.join(OUT, "Mac-1.png"), "One shortcut. Every clip.", "Press ⇧⌘V, pick a card, then ⌘V wherever you are.", LIGHT)
        mac(f"{MAC}/light-preview/light-panel-1.png", os.path.join(OUT, "Mac-2.png"), "Look closer before you paste.", "Press Space for a full preview of any clip.", LIGHT, preview=f"{MAC}/light-preview/light-panel-7.png")
        mac(f"{MAC}/dark-shelf/dark-panel-1.png", os.path.join(OUT, "Mac-3.png"), "Quiet until you need it.", "Lives in your menu bar. Keeps everything on your Mac.", DARK)
    print("\n".join(sorted(os.listdir(OUT))))
