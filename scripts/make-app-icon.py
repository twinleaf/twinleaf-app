#!/usr/bin/env python3
"""Writes the app icon as an Icon Composer bundle.

    python3 scripts/make-app-icon.py

The output is Sources/Twinleaf/Resources/AppIcon.icon: icon.json plus one SVG
per layer. Xcode's asset compiler turns it into every size both platforms need
and applies the system shape and the glass, dark and tinted treatments, so the
artwork here is full bleed and carries no mask, rim or shadow of its own.

The picture is the original Twinleaf icon, split into layers from back to
front: a dark instrument screen with field lines (Grid) and the two field vectors
(Back, Front). The original's border ring and edge tick marks are left out.

The bundle is committed, so this only needs running when the design changes.
To look at the result without building:

    "/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool" \\
        Sources/Twinleaf/Resources/AppIcon.icon --export-image --output-file icon.png \\
        --platform macOS --rendition Default --width 512 --height 512 --scale 2
"""
import json
import os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "Sources", "Twinleaf", "Resources", "AppIcon.icon")

# Colours.
MINT = "#C4FFD6"      # front vector
GREY = "#A3ABA5"      # back vector
OUTLINE = "#000000"
LINE = "#2B312D"      # field lines
CROSS = "#181C1A"     # cross lines
CHEVRON = "#4A524C"   # arrowheads on the field lines
# Icon Composer ignores SVG opacity and gradients inside a layer, so these are
# solid colours and the screen's shading comes from the fill in icon.json.

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


# Layers from front to back, the order icon.json lists them. The screen
# stays flat (no glass); the two vectors are the glass pieces.
LAYERS = [
    ("Front", arrow(MINT, mirrored=False), True, 0.5),
    ("Back", arrow(GREY, mirrored=True), True, 0.5),
    ("Grid", grid(), False, 0.0),
]


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
        "fill": {"linear-gradient": ["extended-srgb:0.12500,0.15000,0.13500,1.00000",
                                     "extended-srgb:0.02400,0.03100,0.02700,1.00000"]},
        "groups": groups,
        "supported-platforms": {"squares": "shared"},
    }
    with open(os.path.join(OUT, "icon.json"), "w") as f:
        json.dump(doc, f, indent=2, sort_keys=True)
        f.write("\n")
    print("wrote", os.path.relpath(OUT, ROOT))


if __name__ == "__main__":
    main()
