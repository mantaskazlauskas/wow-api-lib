"""WoW API Lib logo generator.

Renders assets/logo.png (400x400, the CurseForge project icon) and
assets/logo-64.png from vector primitives, the same way tank-tools draws its
logo, so the mark can be recoloured or resized by editing the constants at the
top. Requires Pillow.

    python assets/logo.py

The mark: code braces around a magnifying glass, i.e. "search the API", in the
browser's accent blue on the dark backdrop the addon's windows use.
"""

import math
import os
from PIL import Image, ImageDraw, ImageFilter, ImageFont

S   = 4                 # supersample
N   = 400
C   = N * S
OUT = os.path.dirname(os.path.abspath(__file__))

BG       = (17, 18, 21)       # ui.C.window
BORDER   = (46, 48, 55)       # ui.C.border
ACCENT   = (61, 142, 255)     # ui.C.accent
ACCENT_HI = (120, 180, 255)
GLASS    = (235, 237, 242)    # ui.C.text
LENS     = (61, 142, 255, 46)

# Bold monospace faces with a clear brace, first one found wins.
FONTS = [
    r"C:\Windows\Fonts\consolab.ttf",
    r"C:\Windows\Fonts\CascadiaMono.ttf",
    "/usr/share/fonts/truetype/dejavu/DejaVuSansMono-Bold.ttf",
    "/System/Library/Fonts/Menlo.ttc",
]


def font(size):
    for path in FONTS:
        if os.path.exists(path):
            return ImageFont.truetype(path, size)
    raise SystemExit("no monospace font found; add one to FONTS")


def backdrop():
    img = Image.new("RGBA", (C, C), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    r = int(C * 0.18)
    d.rounded_rectangle([0, 0, C - 1, C - 1], radius=r, fill=BG)

    # A soft blue glow behind the mark, so it doesn't sit on flat black.
    glow = Image.new("L", (C, C), 0)
    ImageDraw.Draw(glow).ellipse([C * 0.18, C * 0.16, C * 0.82, C * 0.80], fill=70)
    glow = glow.filter(ImageFilter.GaussianBlur(C * 0.09))
    tint = Image.new("RGBA", (C, C), ACCENT + (0,))
    tint.putalpha(glow)
    img = Image.alpha_composite(img, tint)

    # Re-clip to the rounded square, then the hairline border.
    mask = Image.new("L", (C, C), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, C - 1, C - 1], radius=r, fill=255)
    img.putalpha(mask)
    w = int(C * 0.012)
    ImageDraw.Draw(img).rounded_rectangle([w // 2, w // 2, C - 1 - w // 2, C - 1 - w // 2],
                                          radius=r - w // 2, outline=BORDER, width=w)
    return img


def gradient_text(img, text, cx, cy, size):
    """Text centred on (cx, cy), filled with a top-to-bottom accent gradient."""
    f = font(size)
    layer = Image.new("L", (C, C), 0)
    d = ImageDraw.Draw(layer)
    l, t, r, b = d.textbbox((0, 0), text, font=f)
    d.text((cx - (l + r) / 2, cy - (t + b) / 2), text, font=f, fill=255)

    grad = Image.new("RGBA", (C, C))
    gd = ImageDraw.Draw(grad)
    for y in range(C):
        k = y / C
        gd.line([(0, y), (C, y)], fill=tuple(int(ACCENT_HI[i] + (ACCENT[i] - ACCENT_HI[i]) * k)
                                             for i in range(3)) + (255,))
    grad.putalpha(layer)
    return Image.alpha_composite(img, grad)


def magnifier(img):
    d = ImageDraw.Draw(img)
    cx, cy, r = C * 0.475, C * 0.445, C * 0.135
    ring = C * 0.042

    # Lens tint, then the ring.
    lens = Image.new("RGBA", (C, C), (0, 0, 0, 0))
    ImageDraw.Draw(lens).ellipse([cx - r, cy - r, cx + r, cy + r], fill=LENS)
    img = Image.alpha_composite(img, lens)
    d = ImageDraw.Draw(img)
    d.ellipse([cx - r, cy - r, cx + r, cy + r], outline=GLASS, width=int(ring))

    # Handle at 45 degrees, from just outside the ring, with round ends.
    a = math.radians(45)
    x0 = cx + math.cos(a) * (r + ring * 0.2)
    y0 = cy + math.sin(a) * (r + ring * 0.2)
    x1 = cx + math.cos(a) * (r + C * 0.17)
    y1 = cy + math.sin(a) * (r + C * 0.17)
    hw = C * 0.058
    d.line([(x0, y0), (x1, y1)], fill=GLASS, width=int(hw))
    for x, y in ((x0, y0), (x1, y1)):
        d.ellipse([x - hw / 2, y - hw / 2, x + hw / 2, y + hw / 2], fill=GLASS)

    # A glint on the lens.
    g = r * 0.55
    d.arc([cx - g, cy - g, cx + g, cy + g], start=200, end=250, fill=GLASS, width=int(C * 0.018))
    return img


def logo():
    img = backdrop()
    size = int(C * 0.58)
    img = gradient_text(img, "{", C * 0.225, C * 0.50, size)
    img = gradient_text(img, "}", C * 0.775, C * 0.50, size)
    img = magnifier(img)
    return img.resize((N, N), Image.LANCZOS)


if __name__ == "__main__":
    im = logo()
    im.save(os.path.join(OUT, "logo.png"))
    im.resize((64, 64), Image.LANCZOS).save(os.path.join(OUT, "logo-64.png"))
    print("wrote logo.png and logo-64.png in", OUT)
