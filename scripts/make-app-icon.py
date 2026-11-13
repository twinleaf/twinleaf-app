#!/usr/bin/env python3
"""Writes the app icon: an Icon Composer bundle, and an image stack for visionOS.

    python3 scripts/make-app-icon.py

The main output is Sources/Twinleaf/Resources/AppIcon.icon: icon.json plus one
SVG per layer. Xcode's asset compiler turns it into every size macOS and iOS
need and applies the system shape and the glass, dark and tinted treatments, so
the artwork here is full bleed and carries no mask, rim or shadow of its own.

visionOS takes nothing from an Icon Composer bundle. Its icon is
Assets.xcassets/AppIcon.solidimagestack: the same picture as three 1024 px
bitmaps, which the system crops to a circle and spreads apart in depth. The
asset compiler gives each platform its own of the two, under the one name.

The picture is the original Twinleaf icon, split into layers from back to
front: a dark instrument screen with field lines (Grid) and the two field vectors
(Back, Front). The original's border ring and edge tick marks are left out.

Both are committed, so this only needs running when the design changes.
To look at the result without building:

    "/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool" \\
        Sources/Twinleaf/Resources/AppIcon.icon --export-image --output-file icon.png \\
        --platform macOS --rendition Default --width 512 --height 512 --scale 2
"""
import json
import os
import subprocess
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RESOURCES = os.path.join(ROOT, "Sources", "Twinleaf", "Resources")
OUT = os.path.join(RESOURCES, "AppIcon.icon")
STACK = os.path.join(RESOURCES, "Assets.xcassets", "AppIcon.solidimagestack")

# Colours.
MINT = "#C4FFD6"      # front vector
GREY = "#A3ABA5"      # back vector
OUTLINE = "#000000"
LINE = "#2B312D"      # field lines
CROSS = "#181C1A"     # cross lines
CHEVRON = "#4A524C"   # arrowheads on the field lines
# Icon Composer ignores SVG opacity and gradients inside a layer, so these are
# solid colours and the screen's shading comes from the fill in icon.json.
SCREEN = ((0.125, 0.150, 0.135), (0.024, 0.031, 0.027))   # top, bottom

# Geometry, on the 1024 x 1024 canvas with y downward.

# The front vector, tip first, clockwise. The back vector is its mirror image.
ARROW = [(407, 139), (711, 357), (588, 397), (698, 756), (533, 813), (417, 454), (286, 495)]

GRID_X = range(81, 1024, 56)            # field lines
GRID_Y = (212, 512, 812)                # faint cross lines
# Small arrowheads riding the field lines: (line index, y).
CHEVRONS = [(0, 280), (1, 680), (2, 410), (3, 800), (4, 240), (5, 600),
            (11, 280), (12, 600), (10, 820), (13, 405), (14, 730)]



def svg(body):
    return ('<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">\n'
            + "".join("  %s\n" % line for line in body) + "</svg>\n")


def arrow(color, mirrored):
    pts = " ".join("%d,%d" % ((1024 - x if mirrored else x), y) for x, y in ARROW)
    return ['<polygon points="%s" fill="%s" stroke="%s" stroke-width="7" stroke-linejoin="miter"/>'
            % (pts, color, OUTLINE)]


def grid():
    body = ['<g stroke-linecap="round" fill="none">']
    for y in GRID_Y:
        body.append('  <line x1="0" y1="%d" x2="1024" y2="%d" stroke="%s" stroke-width="4"/>' % (y, y, CROSS))
    for x in GRID_X:
        body.append('  <line x1="%d" y1="0" x2="%d" y2="1024" stroke="%s" stroke-width="7"/>' % (x, x, LINE))
    for i, y in CHEVRONS:
        x = GRID_X[i]
        body.append('  <polyline points="%d,%d %d,%d %d,%d" stroke="%s" stroke-width="7" '
                    'stroke-linejoin="round"/>' % (x - 28, y + 22, x, y - 22, x + 28, y + 22, CHEVRON))
    body.append("</g>")
    return body


def screen():
    """The screen's shading as a full-bleed rectangle, for the visionOS back layer."""
    top, bottom = ("#%02X%02X%02X" % tuple(round(c * 255) for c in rgb) for rgb in SCREEN)
    return ['<linearGradient id="screen" x2="0" y2="1">',
            '  <stop offset="0" stop-color="%s"/>' % top,
            '  <stop offset="1" stop-color="%s"/>' % bottom,
            "</linearGradient>",
            '<rect width="1024" height="1024" fill="url(#screen)"/>']


# Layers from front to back, the order icon.json lists them. The screen
# stays flat (no glass); the two vectors are the glass pieces.
LAYERS = [
    ("Front", arrow(MINT, mirrored=False), True, 0.5),
    ("Back", arrow(GREY, mirrored=True), True, 0.5),
    ("Grid", grid(), False, 0.0),
]

# The visionOS layers, front to back, under the names Xcode gives them. The
# back one has to be opaque, so it carries the shading as well as the grid.
VISION_LAYERS = [
    ("Front", arrow(MINT, mirrored=False)),
    ("Middle", arrow(GREY, mirrored=True)),
    ("Back", screen() + grid()),
]


def catalog_json(path, doc):
    """Writes an asset catalog Contents.json the way Xcode formats it."""
    doc["info"] = {"author": "xcode", "version": 1}
    with open(path, "w") as f:
        json.dump(doc, f, indent=2, sort_keys=True, separators=(",", " : "))
        f.write("\n")


def vision():
    """Writes the visionOS image stack: one PNG and its catalog entries per layer."""
    with tempfile.TemporaryDirectory() as tmp:
        for name, body in VISION_LAYERS:
            layer = os.path.join(STACK, name + ".solidimagestacklayer")
            imageset = os.path.join(layer, "Content.imageset")
            os.makedirs(imageset, exist_ok=True)
            source = os.path.join(tmp, name + ".svg")
            with open(source, "w") as f:
                f.write(svg(body))
            # A stack layer is a bitmap, so sips draws the SVG as a PNG.
            subprocess.run(["sips", "-s", "format", "png", source,
                            "--out", os.path.join(imageset, name + ".png")],
                           check=True, stdout=subprocess.DEVNULL)
            catalog_json(os.path.join(imageset, "Contents.json"),
                         {"images": [{"filename": name + ".png", "idiom": "vision", "scale": "2x"}]})
            catalog_json(os.path.join(layer, "Contents.json"), {})
    catalog_json(os.path.join(STACK, "Contents.json"),
                 {"layers": [{"filename": name + ".solidimagestacklayer"} for name, _ in VISION_LAYERS]})
    print("wrote", os.path.relpath(STACK, ROOT))


def main():
    os.makedirs(os.path.join(OUT, "Assets"), exist_ok=True)
    groups = []
    for name, body, glass, shadow in LAYERS:
        with open(os.path.join(OUT, "Assets", name + ".svg"), "w") as f:
            f.write(svg(body))
        layer = {"image-name": name + ".svg", "name": name}
        if not glass:
            layer["glass"] = False
        groups.append({
            "layers": [layer],
            "shadow": {"kind": "neutral", "opacity": shadow},
            "translucency": {"enabled": False, "value": 0.5},
        })
    doc = {
        "fill": {"linear-gradient": ["extended-srgb:%.5f,%.5f,%.5f,1.00000" % rgb for rgb in SCREEN]},
        "groups": groups,
        "supported-platforms": {"squares": "shared"},
    }
    with open(os.path.join(OUT, "icon.json"), "w") as f:
        json.dump(doc, f, indent=2, sort_keys=True)
        f.write("\n")
    print("wrote", os.path.relpath(OUT, ROOT))
    vision()


if __name__ == "__main__":
    main()
