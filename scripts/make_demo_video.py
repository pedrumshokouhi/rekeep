#!/usr/bin/env python3
"""Rekeep demo video compositor: real iPhone screen recording + real Mac renders,
with quiet typography. Renders PNG frames; vtool encodes them to H.264."""
import os, sys, math
from functools import lru_cache
from multiprocessing import Pool
from PIL import Image, ImageDraw, ImageFont, ImageFilter

H = os.path.expanduser
W_, H_ = 1920, 1080
FPS = 30
OUT = H("~/RekeepBuild/demo/out-frames")
PHONE = H("~/RekeepBuild/demo/iphone-frames")
MAC = H("~/RekeepBuild/appstore/mac")
ICON = H("~/RekeepBuild/icon-renders/macOS-Default-1024.png")
FONT = "/System/Library/Fonts/SFNS.ttf"

LIGHT = dict(bg=(245, 245, 242), ink=(32, 35, 41), sub=(92, 97, 107), glow=(54, 183, 151, 46), eyebrow=(29, 132, 102))
DARK = dict(bg=(17, 19, 24), ink=(236, 237, 239), sub=(164, 169, 178), glow=(54, 183, 151, 30), eyebrow=(90, 211, 178))

# ---------- helpers

def clamp(x, a=0.0, b=1.0): return max(a, min(b, x))
def ease_out(x): x = clamp(x); return 1 - (1 - x) ** 3
def ease_in_out(x): x = clamp(x); return 3 * x * x - 2 * x * x * x
def ramp(t, start, dur): return clamp((t - start) / dur)

@lru_cache(maxsize=None)
def font(size, weight):
    f = ImageFont.truetype(FONT, size)
    f.set_variation_by_name(weight)
    return f

@lru_cache(maxsize=256)
def text_img(text, size, weight, color, tracking=0):
    f = font(size, weight)
    l, t, r, b = f.getbbox(text)
    extra = int(abs(tracking) * len(text)) + 4
    img = Image.new("RGBA", (r - l + extra + 8, int(size * 1.35)), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    if tracking:
        x = 4
        for ch in text:
            d.text((x, 0), ch, font=f, fill=color + (255,))
            x += f.getlength(ch) + tracking
    else:
        d.text((4 - l, 0), text, font=f, fill=color + (255,))
    return img

def with_alpha(img, a):
    if a >= 0.999: return img
    out = img.copy()
    out.putalpha(out.getchannel("A").point(lambda v: int(v * a)))
    return out

def put(canvas, img, x, y, alpha=1.0):
    if alpha <= 0.001: return
    canvas.alpha_composite(with_alpha(img, alpha), (int(round(x)), int(round(y))))

def put_center(canvas, img, cx, y, alpha=1.0):
    put(canvas, img, cx - img.width / 2, y, alpha)

@lru_cache(maxsize=4)
def backdrop(theme_name):
    th = LIGHT if theme_name == "light" else DARK
    c = Image.new("RGBA", (W_, H_), th["bg"] + (255,))
    glow = Image.new("RGBA", (W_, H_), (0, 0, 0, 0))
    g = ImageDraw.Draw(glow)
    g.ellipse([W_ * 0.58, -H_ * 0.35, W_ * 1.25, H_ * 0.7], fill=th["glow"])
    g.ellipse([-W_ * 0.3, H_ * 0.35, W_ * 0.35, H_ * 1.3], fill=(32, 35, 41, 16) if theme_name == "light" else (230, 232, 235, 10))
    glow = glow.filter(ImageFilter.GaussianBlur(160))
    c.alpha_composite(glow)
    # Fine static dither so the soft gradient doesn't band after H.264 compression.
    from PIL import ImageChops
    import random
    random.seed(7)
    noise = Image.effect_noise((W_, H_), 3.0).convert("RGB")
    rgb = ImageChops.add(c.convert("RGB"), noise, scale=1.0, offset=-128)
    out = rgb.convert("RGBA")
    return out

@lru_cache(maxsize=8)
def load(path, scale):
    im = Image.open(path).convert("RGBA")
    return im.resize((round(im.width * scale), round(im.height * scale)), Image.LANCZOS)

def headline_block(canvas, th, eyebrow, title, sub, cx, y, alpha, rise=0, align="center", x=None):
    e = text_img(eyebrow.upper(), 22, "Semibold", th["eyebrow"], tracking=3) if eyebrow else None
    t = text_img(title, 64, "Semibold", th["ink"])
    s = text_img(sub, 30, "Regular", th["sub"]) if sub else None
    dy = rise
    if align == "center":
        if e: put_center(canvas, e, cx, y + dy, alpha)
        put_center(canvas, t, cx, y + 40 + dy, alpha)
        if s: put_center(canvas, s, cx, y + 128 + dy, alpha)
    else:
        if e: put(canvas, e, x, y + dy, alpha)
        put(canvas, t, x - 3, y + 40 + dy, alpha)
        if s: put(canvas, s, x - 1, y + 128 + dy, alpha)

def wrap_sub(text, width, size=30):
    f = font(size, "Regular")
    words, lines, cur = text.split(), [], ""
    for w in words:
        trial = (cur + " " + w).strip()
        if f.getlength(trial) <= width: cur = trial
        else: lines.append(cur); cur = w
    lines.append(cur)
    return lines

# ---------- scenes (each takes local time, returns RGBA frame)

def intro(t):
    th = LIGHT
    c = backdrop("light").copy()
    out = 1 - ease_in_out(ramp(t, 2.75, 0.45))
    a = ease_out(ramp(t, 0.1, 0.9)) * out
    size = int(220 * (0.94 + 0.06 * a))
    icon = load(ICON, size / 1024)
    put_center(c, icon, W_ / 2, 300 - (size - 220) / 2 + (1 - a) * 18, a)
    a2 = ease_out(ramp(t, 0.55, 0.8)) * out
    put_center(c, text_img("Rekeep", 96, "Semibold", th["ink"]), W_ / 2, 560 + (1 - a2) * 14, a2)
    a3 = ease_out(ramp(t, 0.95, 0.8)) * out
    put_center(c, text_img("Copy once. Keep moving.", 38, "Regular", th["sub"]), W_ / 2, 690 + (1 - a3) * 12, a3)
    return c

SHELF_S = 1800 / 1888  # px per pt: shelf content (1888pt) spans 1800px
def shelf_geom():
    pw, ph = round(3888 / 2 * SHELF_S), round(772 / 2 * SHELF_S)
    x = (W_ - pw) / 2
    y = H_ - 30 + 28 * SHELF_S - ph
    return x, y, pw, ph

MAC_DUR = 11.4

def mac_scene(t):
    """Shelf rises, selection moves, preview opens and closes, then the whole scene
    switches to Dark appearance in place, then the shelf settles away."""
    x, y, pw, ph = shelf_geom()
    dark = ease_in_out(ramp(t, 6.9, 0.8)) * (1 - ease_in_out(ramp(t, 9.75, 0.8)))
    c = backdrop("light").copy() if dark < 1 else backdrop("dark").copy()
    if 0 < dark < 1:
        c = Image.blend(backdrop("light"), backdrop("dark"), dark)
    shelf_a = load(f"{MAC}/light-shelf/light-panel-1.png", SHELF_S / 2)
    shelf_b = load(f"{MAC}/light-preview/light-panel-1.png", SHELF_S / 2)
    shelf_d = load(f"{MAC}/dark-shelf/dark-panel-1.png", SHELF_S / 2)
    rise = ease_out(ramp(t, 0.25, 0.9))
    leave = ease_in_out(ramp(t, MAC_DUR - 0.85, 0.65))
    sy = y + (1 - rise) * (ph + 40) + leave * (ph + 40)
    shelf_alpha = min(rise, 1 - leave)
    # selection: Link -> Swift (preview) -> back to Link before the appearance switch
    sel = ease_in_out(ramp(t, 2.7, 0.28)) * (1 - ease_in_out(ramp(t, 6.45, 0.28)))
    if dark < 1:
        put(c, shelf_a, x, sy, shelf_alpha)
        if sel > 0: put(c, shelf_b, x, sy, shelf_alpha * sel)
    if dark > 0:
        put(c, shelf_d, x, sy, shelf_alpha * dark)
    h1 = ease_out(ramp(t, 0.5, 0.6)) * (1 - ease_in_out(ramp(t, 3.4, 0.35)))
    h2 = ease_out(ramp(t, 3.75, 0.6)) * (1 - ease_in_out(ramp(t, 6.25, 0.35)))
    h3 = ease_out(ramp(t, 7.5, 0.6)) * (1 - ease_in_out(ramp(t, 9.4, 0.4)))
    headline_block(c, LIGHT, "On your Mac", "One shortcut. Every clip.", "Press \u21e7\u2318V, pick a card, and it\u2019s pasted where you were.", W_ / 2, 96, h1, rise=(1 - ease_out(ramp(t, 0.5, 0.6))) * 12)
    headline_block(c, LIGHT, "On your Mac", "Look closer before you paste.", "Press Space for a full preview of any clip.", W_ / 2, 96, h2, rise=(1 - ease_out(ramp(t, 3.75, 0.6))) * 12)
    headline_block(c, DARK, "On your Mac", "Quiet until you need it.", "Lives in your menu bar. Keeps everything on your Mac.", W_ / 2, 96, h3, rise=(1 - ease_out(ramp(t, 7.5, 0.6))) * 12)
    p = ease_out(ramp(t, 3.9, 0.55)) * (1 - ease_in_out(ramp(t, 6.15, 0.35)))
    if p > 0:
        prev = load(f"{MAC}/light-preview/light-panel-7.png", SHELF_S / 2)
        px = x + 301 * SHELF_S - 24 * SHELF_S
        py = sy + 27 - 14 - prev.height + 24 * SHELF_S + (1 - p) * 16
        put(c, prev, px, py, p)
    return c

PHONE_START = 6.5
PHONE_LEN = 26.5
CAPTIONS = [  # footage-relative start, eyebrow, title, sub
    (0.0, "Everything you copy, kept.", "Links, colors, images, code and text, each as a clear card."),
    (4.4, "Reuse what matters.", "Favorites and snippets, one tap away."),
    (8.8, "Find anything in a few letters.", "Search every word you’ve saved, instantly."),
    (13.7, "Open it. Copy it. Done.", "Every clip has its details, notes and tags."),
    (19.3, "Your clips, in any app.", "Switch to the Rekeep keyboard and tap a clip to type it."),
]
PH_H = 940
PH_S = PH_H / 2622
PH_W = round(1206 * PH_S)
PH_R = round(62 * PH_W / 402 * 1.0)

@lru_cache(maxsize=1)
def phone_mask():
    m = Image.new("L", (PH_W * 4, PH_H * 4), 0)
    ImageDraw.Draw(m).rounded_rectangle([0, 0, PH_W * 4 - 1, PH_H * 4 - 1], radius=PH_R * 4, fill=255)
    return m.resize((PH_W, PH_H), Image.LANCZOS)

@lru_cache(maxsize=1)
def phone_shadow():
    pad = 80
    s = Image.new("RGBA", (PH_W + pad * 2, PH_H + pad * 2), (0, 0, 0, 0))
    ImageDraw.Draw(s).rounded_rectangle([pad, pad + 18, pad + PH_W, pad + PH_H + 18], radius=PH_R, fill=(20, 24, 30, 70))
    return s.filter(ImageFilter.GaussianBlur(34)), pad

def phone_frame(ft):
    files = sorted(os.listdir(PHONE))
    i = min(len(files) - 1, max(0, round(ft * FPS)))
    im = Image.open(os.path.join(PHONE, files[i])).convert("RGB").resize((PH_W, PH_H), Image.LANCZOS).convert("RGBA")
    im.putalpha(phone_mask())
    return im

def phone_scene(t):
    th = LIGHT
    c = backdrop("light").copy()
    px, py = 1225, (H_ - PH_H) / 2
    a = ease_out(ramp(t, 0.45, 0.8)) * (1 - ease_in_out(ramp(t, PHONE_LEN - 0.75, 0.5)))
    shadow, pad = phone_shadow()
    dy = (1 - a) * 30
    put(c, shadow, px - pad, py - pad + dy, a)
    rim = Image.new("RGBA", (PH_W + 4, PH_H + 4), (0, 0, 0, 0))
    ImageDraw.Draw(rim).rounded_rectangle([0, 0, PH_W + 3, PH_H + 3], radius=PH_R + 2, outline=(0, 0, 0, 34), width=2)
    put(c, phone_frame(PHONE_START + t), px, py + dy, a)
    put(c, rim, px - 2, py - 2 + dy, a)
    # captions on the left
    lx, ty = 285, 400
    for k, (start, title, sub) in enumerate(CAPTIONS):
        end = CAPTIONS[k + 1][0] if k + 1 < len(CAPTIONS) else 999
        fin = ease_out(ramp(t, start + (0.75 if k == 0 else 0.3), 0.55))
        fout = 1 - ease_in_out(ramp(t, min(end, PHONE_LEN - 0.4) - 0.35, 0.3))
        al = fin * fout
        if al <= 0.001: continue
        rise = (1 - fin) * 14
        put(c, text_img("On iPhone and iPad".upper(), 22, "Semibold", th["eyebrow"], tracking=3), lx, ty + rise, al)
        tf = font(58, "Semibold")
        # wrap title to the column
        lines = wrap_sub(title, 820, 58) if tf.getlength(title) > 820 else [title]
        yy = ty + 42
        for ln in lines:
            put(c, text_img(ln, 58, "Semibold", th["ink"]), lx - 3, yy + rise, al); yy += 70
        yy += 14
        for ln in wrap_sub(sub, 760, 30):
            put(c, text_img(ln, 30, "Regular", th["sub"]), lx - 1, yy + rise, al); yy += 42
    return c

def outro(t):
    th = LIGHT
    c = backdrop("light").copy()
    a = ease_out(ramp(t, 0.3, 0.8))
    put_center(c, load(ICON, 180 / 1024), W_ / 2, 280 + (1 - a) * 14, a)
    a2 = ease_out(ramp(t, 0.6, 0.8))
    put_center(c, text_img("Rekeep", 88, "Semibold", th["ink"]), W_ / 2, 500 + (1 - a2) * 12, a2)
    put_center(c, text_img("Copy once. Keep moving.", 36, "Regular", th["sub"]), W_ / 2, 620 + (1 - a2) * 12, a2)
    a3 = ease_out(ramp(t, 1.1, 0.8))
    put_center(c, text_img("Free for Mac, iPhone and iPad", 28, "Medium", th["eyebrow"]), W_ / 2, 720 + (1 - a3) * 10, a3)
    return c

XF = 0.6  # crossfade between scenes
SCENES = [  # (start, end, fn); each scene clears its own content before it ends
    (0.0, 3.4, intro),
    (3.4 - XF, 3.4 - XF + MAC_DUR, mac_scene),
    (3.4 - 2 * XF + MAC_DUR, 3.4 - 2 * XF + MAC_DUR + PHONE_LEN, phone_scene),
    (3.4 - 3 * XF + MAC_DUR + PHONE_LEN, 3.4 - 3 * XF + MAC_DUR + PHONE_LEN + 4.6, outro),
]
TOTAL = SCENES[-1][1]

def fn_theme(img):
    # dark scenes have a dark top-left corner
    return sum(img.getpixel((4, 4))[:3]) < 200

def render(i):
    t = i / FPS
    active = [(s, e, fn) for s, e, fn in SCENES if s <= t < e or (fn is outro and t >= s)]
    frames = []
    for s, e, fn in active:
        frames.append((s, e, fn(t - s)))
    if len(frames) == 1:
        img = frames[0][2]
    else:
        (s0, e0, a), (s1, e1, b) = frames[0], frames[-1]
        k = ease_in_out((t - s1) / max(0.001, e0 - s1))
        img = Image.blend(a, b, k)
    # fade from/to background at the very ends
    if t > TOTAL - 0.5:
        img = Image.blend(img, backdrop("light"), ease_in_out((t - (TOTAL - 0.5)) / 0.5))
    img.convert("RGB").save(f"{OUT}/f{i:05d}.png", compress_level=1)
    return i

if __name__ == "__main__":
    os.makedirs(OUT, exist_ok=True)
    n = int(TOTAL * FPS)
    only = [int(a) for a in sys.argv[1:]]
    idx = only if only else range(n)
    with Pool(8) as p:
        for k, _ in enumerate(p.imap_unordered(render, idx, chunksize=4)):
            pass
    print("frames", n, "seconds", TOTAL)
