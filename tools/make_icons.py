"""Generate the driver icons in the DirectorLink style (no maker logos).

    pip install pillow
    python tools/make_icons.py

Writes (paths in driver.xml are relative to www/):
  src/camera/www/icons/device_sm.png, device_lg.png     camera driver, Composer (16 / 32 px)
  src/camera/www/icons/camera_300.png                   camera documentation header
  src/hub/www/icons/device_sm.png, device_lg.png        hub driver, Composer (16 / 32 px)
  src/hub/www/icons/tile/<state>_<size>.png              Camera Alerts tile (the UniFi Protect Hub)
      states: on, alert, off, error, pending     sizes: 70, 90, 300, 512, 1024

Style (matches the other DirectorLink drivers): round grey disc with a vertical
gradient, thick ring, white glyph; cyan ring when active, red ring with a badge
for problems, light ring with dots while busy, grey when off.
"""
import os

from PIL import Image, ImageDraw, ImageFilter

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CAMERA_ICONS = os.path.join(ROOT, "src", "camera", "www", "icons")
HUB_ICONS = os.path.join(ROOT, "src", "hub", "www", "icons")
TILE_STATES = ("on", "alert", "off", "error", "pending")
SIZES = (70, 90, 300, 512, 1024)

CYAN = (40, 210, 255, 255)
BLUE = (66, 119, 255, 255)
RED = (230, 40, 40, 255)
RING_IDLE = (95, 95, 95, 255)
RING_PENDING = (235, 235, 235, 255)
DISC_TOP = (157, 157, 157)
DISC_BOTTOM = (99, 99, 99)
WHITE = (250, 250, 250, 255)
LIGHT = (238, 238, 238, 255)

SS = 2048          # supersampled canvas
S = SS / 1024.0    # scale from the 1024 design grid
TILT = 24          # degrees the camera body points down


def p(*v):
    return [int(round(x * S)) for x in v]


def disc(ring):
    """Grey gradient disc with a ring and a soft drop shadow."""
    img = Image.new("RGBA", (SS, SS), (0, 0, 0, 0))
    shadow = Image.new("RGBA", (SS, SS), (0, 0, 0, 0))
    ImageDraw.Draw(shadow).ellipse(p(52, 60, 972, 980), fill=(0, 0, 0, 90))
    img.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(14 * S)))
    ImageDraw.Draw(img).ellipse(p(44, 44, 980, 980), fill=ring)
    grad = Image.new("RGBA", (SS, SS))
    gd = ImageDraw.Draw(grad)
    top, bottom = p(124)[0], p(900)[0]
    for y in range(SS):
        t = min(1.0, max(0.0, (y - top) / float(bottom - top)))
        c = tuple(int(DISC_TOP[i] + (DISC_BOTTOM[i] - DISC_TOP[i]) * t) for i in range(3))
        gd.line([(0, y), (SS, y)], fill=c + (255,))
    mask = Image.new("L", (SS, SS), 0)
    ImageDraw.Draw(mask).ellipse(p(124, 124, 900, 900), fill=255)
    img.paste(grad, (0, 0), mask)
    return img


def camera_glyph(img, body, accent, lens_glass):
    """Classic CCTV bullet camera: body tilted down-left, arm to a wall plate on the right."""
    layer = Image.new("RGBA", img.size, (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    d.rounded_rectangle(p(318, 366, 760, 424), radius=p(29)[0], fill=body)     # sun hood
    d.rounded_rectangle(p(340, 404, 740, 588), radius=p(64)[0], fill=body)     # body
    d.rounded_rectangle(p(262, 430, 360, 562), radius=p(30)[0], fill=body)     # lens housing
    d.ellipse(p(276, 450, 368, 542), fill=accent)                               # lens ring
    d.ellipse(p(298, 472, 346, 520), fill=lens_glass)                           # lens glass
    d.ellipse(p(668, 456, 704, 492), fill=accent)                               # status LED
    layer = layer.rotate(TILT, resample=Image.BICUBIC, center=tuple(p(560, 496)))
    img.alpha_composite(layer)
    d = ImageDraw.Draw(img)
    d.line(p(700, 560, 770, 634), fill=body, width=p(46)[0])                    # mount arm
    d.ellipse(p(677, 537, 723, 583), fill=body)                                 # arm joint
    d.rounded_rectangle(p(752, 560, 806, 742), radius=p(24)[0], fill=body)     # wall plate


def motion_waves(d, color):
    cx, cy = 382, 625   # lens centre after the tilt
    for r in (116, 180):
        d.arc(p(cx - r, cy - r, cx + r, cy + r), start=126, end=186, fill=color, width=p(30)[0])


def badge(img, color):
    d = ImageDraw.Draw(img)
    d.ellipse(p(640, 640, 900, 900), fill=WHITE)
    d.ellipse(p(664, 664, 876, 876), fill=color)
    d.rounded_rectangle(p(752, 698, 788, 800), radius=p(16)[0], fill=WHITE)
    d.ellipse(p(750, 816, 790, 856), fill=WHITE)


def tile(state):
    if state in ("on", "alert"):
        img = disc(CYAN)
        camera_glyph(img, WHITE, CYAN, (60, 60, 60, 255))
        if state == "alert":
            motion_waves(ImageDraw.Draw(img), CYAN)
    elif state == "error":
        img = disc(RED)
        camera_glyph(img, WHITE, LIGHT, (110, 110, 110, 255))
        badge(img, RED)
    elif state == "pending":
        img = disc(RING_PENDING)
        camera_glyph(img, WHITE, LIGHT, (110, 110, 110, 255))
        d = ImageDraw.Draw(img)
        for cx in (430, 512, 594):
            d.ellipse(p(cx - 26, 790, cx + 26, 842), fill=WHITE)
    else:  # off
        img = disc(RING_IDLE)
        camera_glyph(img, WHITE, LIGHT, (110, 110, 110, 255))
    return img


def small_disc():
    img = Image.new("RGBA", (SS, SS), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    d.ellipse(p(16, 16, 1008, 1008), fill=BLUE)
    d.ellipse(p(176, 176, 848, 848), fill=(118, 118, 118, 255))
    return img


def composer_camera(size):
    if size >= 32:
        img = disc(BLUE)
        camera_glyph(img, BLUE, WHITE, BLUE)
        return img.resize((size, size), Image.LANCZOS)
    img = small_disc()
    layer = Image.new("RGBA", (SS, SS), (0, 0, 0, 0))
    ImageDraw.Draw(layer).rounded_rectangle(p(250, 400, 700, 600), radius=p(60)[0], fill=WHITE)
    img.alpha_composite(layer.rotate(TILT, resample=Image.BICUBIC, center=tuple(p(512, 512))))
    ImageDraw.Draw(img).rectangle(p(600, 560, 690, 760), fill=WHITE)
    return img.resize((size, size), Image.LANCZOS)


def composer_hub(size):
    """Camera wall: a 2x2 grid of screens, one highlighted in cyan."""
    if size >= 32:
        img = disc(BLUE)
        d = ImageDraw.Draw(img)
        cells = [(300, 300, 500, 470), (524, 300, 724, 470), (300, 494, 500, 664), (524, 494, 724, 664)]
        for i, c in enumerate(cells):
            d.rounded_rectangle(p(*c), radius=p(26)[0], fill=WHITE if i else CYAN)
        d.rounded_rectangle(p(420, 700, 604, 736), radius=p(18)[0], fill=WHITE)
        return img.resize((size, size), Image.LANCZOS)
    img = small_disc()
    d = ImageDraw.Draw(img)
    for i, c in enumerate([(300, 300, 500, 500), (524, 300, 724, 500), (300, 524, 500, 724), (524, 524, 724, 724)]):
        d.rectangle(p(*c), fill=WHITE if i else CYAN)
    return img.resize((size, size), Image.LANCZOS)


def save(img, path):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    img.save(path, optimize=True)


def main():
    for size, name in ((16, "device_sm.png"), (32, "device_lg.png")):
        save(composer_camera(size), os.path.join(CAMERA_ICONS, name))
        save(composer_hub(size), os.path.join(HUB_ICONS, name))
    save(tile("on").resize((300, 300), Image.LANCZOS), os.path.join(CAMERA_ICONS, "camera_300.png"))  # documentation header
    for state in TILE_STATES:
        big = tile(state)
        for size in SIZES:
            save(big.resize((size, size), Image.LANCZOS), os.path.join(HUB_ICONS, "tile", f"{state}_{size}.png"))
    print("icons written to", CAMERA_ICONS, "and", HUB_ICONS)


if __name__ == "__main__":
    main()
