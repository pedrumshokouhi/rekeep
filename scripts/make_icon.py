#!/usr/bin/env python3
"""Builds the Rekeep app icon as an Icon Composer document (AppIcon.icon) for Mac and iOS,
plus flat SVG/PNG brand assets. The mark geometry matches Mac/Design/BrandMark.swift."""
import json, os, shutil, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BRAND = os.path.join(ROOT, "Brand")

# Mark geometry in a 100-unit box (identical to BrandMark.swift).
FOLD = ("M23 84 L23 26 Q23 12 37 12 L56 12 C71.5 12 81 22.5 81 36.5 C81 50.5 71.5 61 56 61 L41 61 L41 84 "
        "Q41 90 35 90 L29 90 Q23 90 23 84 Z "
        "M41 28.5 L55.5 28.5 C60.5 28.5 63.5 32 63.5 36.5 C63.5 41 60.5 44.5 55.5 44.5 L41 44.5 Z")
TAB = "M48 49 L60 49 Q64 49 66.3 52.6 L82.4 83.8 Q85.2 90 78.4 90 L68.6 90 Q64.4 90 62.4 86.4 L45.2 54.6 Q43 49 48 49 Z"

def layer_svg(path, fill, size=1024, glyph=0.60):
    # Center the 100-unit mark (optical centre nudged slightly left; the leg carries weight right).
    scale = size * glyph / 100
    offset = (size - 100 * scale) / 2
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {size} {size}" width="{size}" height="{size}">'
            f'<g transform="translate({offset - size * 0.012:.2f} {offset:.2f}) scale({scale:.4f})">'
            f'<path d="{path}" fill="{fill}" fill-rule="evenodd"/></g></svg>')

def write(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write(text)

def srgb(hexstr, a=1.0):
    r, g, b = (int(hexstr[i:i + 2], 16) / 255 for i in (0, 2, 4))
    return f"srgb:{r:.5f},{g:.5f},{b:.5f},{a:.5f}"

def build_icon(dest):
    if os.path.exists(dest):
        shutil.rmtree(dest)
    assets = os.path.join(dest, "Assets")
    write(os.path.join(assets, "fold.svg"), layer_svg(FOLD, "#202329"))
    write(os.path.join(assets, "tab.svg"), layer_svg(TAB, "#36B797"))
    FOLD_GROUP = {
        "name": "Fold",
        "layers": [{
            "name": "fold", "image-name": "fold.svg", "glass": True,
            "fill-specializations": [{"appearance": "dark", "value": {"solid": srgb("F5F5F2")}}],
        }],
        "shadow": {"kind": "neutral", "opacity": 0.55},
        "translucency": {"enabled": True, "value": 0.15},
        "lighting": "individual",
        "specular": True,
    }
    doc = {
        "fill": {"linear-gradient": [srgb("FBFBF9"), srgb("E4E5E1")], "orientation": {"start": {"x": 0.5, "y": 0}, "stop": {"x": 0.5, "y": 1}}},
        "fill-specializations": [
            {"appearance": "dark", "value": {"linear-gradient": [srgb("2B2F37"), srgb("111318")], "orientation": {"start": {"x": 0.5, "y": 0}, "stop": {"x": 0.5, "y": 1}}}},
        ],
        "groups": [
            FOLD_GROUP,
            {
                "name": "Tab",
                "layers": [{"name": "tab", "image-name": "tab.svg", "glass": True}],
                "shadow": {"kind": "layer-color", "opacity": 0.5},
                "translucency": {"enabled": True, "value": 0.35},
                "lighting": "individual",
                "specular": True,
            },
        ],
        "supported-platforms": {"squares": "shared"},
    }
    write(os.path.join(dest, "icon.json"), json.dumps(doc, indent=2))

def flat_assets():
    """Brand mark SVGs for marketing, docs, and the website."""
    write(os.path.join(BRAND, "rekeep-mark.svg"),
          f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100"><path d="{FOLD}" fill="#202329" fill-rule="evenodd"/><path d="{TAB}" fill="#36B797"/></svg>')
    write(os.path.join(BRAND, "rekeep-mark-mono.svg"),
          f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100"><defs><mask id="m"><rect width="100" height="100" fill="#fff"/>'
          f'<path d="{FOLD}" fill="#000" stroke="#000" stroke-width="7" fill-rule="evenodd"/></mask></defs>'
          f'<path d="{TAB}" fill="#000" mask="url(#m)"/><path d="{FOLD}" fill="#000" fill-rule="evenodd"/></svg>')
    write(os.path.join(BRAND, "rekeep-mark-reversed.svg"),
          f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100"><path d="{FOLD}" fill="#F5F5F2" fill-rule="evenodd"/><path d="{TAB}" fill="#45C7A5"/></svg>')

ICTOOL = "/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool"

def render(icon, out_dir):
    os.makedirs(out_dir, exist_ok=True)
    jobs = [("macOS", "Default", 1024), ("macOS", "Dark", 1024), ("macOS", "Default", 32), ("macOS", "Default", 16),
            ("iOS", "Default", 1024), ("iOS", "Dark", 1024), ("iOS", "TintedDark", 1024), ("iOS", "ClearLight", 1024)]
    for platform, rendition, size in jobs:
        out = os.path.join(out_dir, f"{platform}-{rendition}-{size}.png")
        cmd = [ICTOOL, icon, "--export-image", "--output-file", out, "--platform", platform, "--rendition", rendition,
               "--width", str(size), "--height", str(size), "--scale", "1"]
        if rendition.startswith("Tinted"):
            cmd += ["--tint-color", "0.45", "--tint-strength", "0.8"]
        r = subprocess.run(cmd, capture_output=True, text=True)
        print(platform, rendition, size, "ok" if r.returncode == 0 and os.path.exists(out) else "FAILED " + (r.stderr or r.stdout)[:400])

if __name__ == "__main__":
    icon = os.path.join(ROOT, "Mac", "AppIcon.icon")
    build_icon(icon)
    build_icon(os.path.join(ROOT, "iOS", "App", "AppIcon.icon"))
    flat_assets()
    if "--render" in sys.argv:
        render(icon, sys.argv[sys.argv.index("--render") + 1])
