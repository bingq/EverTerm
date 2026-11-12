# macOS app icon set from one square artwork: 1024 canvas, 824 rounded square, transparent margin.
import json, os, sys
from PIL import Image, ImageDraw, ImageFilter
src, out = sys.argv[1], sys.argv[2]
os.makedirs(out, exist_ok=True)
S = 4                                   # supersampling for a smooth edge
CANVAS, BODY, RADIUS = 1024, 824, 185   # Apple's macOS icon grid (Big Sur and later)
art = Image.open(src).convert("RGB").resize((BODY * S, BODY * S), Image.LANCZOS)
mask = Image.new("L", (BODY * S, BODY * S), 0)
ImageDraw.Draw(mask).rounded_rectangle([0, 0, BODY * S - 1, BODY * S - 1], radius=RADIUS * S, fill=255)
body = art.convert("RGBA"); body.putalpha(mask)
canvas = Image.new("RGBA", (CANVAS * S, CANVAS * S), (0, 0, 0, 0))
# soft drop shadow, as macOS icons have
shadow = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
sm = Image.new("L", canvas.size, 0)
off = (CANVAS - BODY) // 2 * S
ImageDraw.Draw(sm).rounded_rectangle([off, off + 12 * S, off + BODY * S, off + BODY * S + 12 * S], radius=RADIUS * S, fill=90)
shadow.putalpha(sm.filter(ImageFilter.GaussianBlur(14 * S)))
canvas.alpha_composite(shadow)
canvas.alpha_composite(body, (off, off))
master = canvas.resize((CANVAS, CANVAS), Image.LANCZOS)
master.save(os.path.join(out, "AppIcon-1024.png"))
specs = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)]
iconset = os.path.join(out, "AppIcon.iconset"); appiconset = os.path.join(out, "AppIcon.appiconset")
os.makedirs(iconset, exist_ok=True); os.makedirs(appiconset, exist_ok=True)
images = []
for size, scale in specs:
    px = size * scale
    name = f"icon_{size}x{size}{'@2x' if scale == 2 else ''}.png"
    img = master.resize((px, px), Image.LANCZOS)
    if px <= 64:
        img = img.filter(ImageFilter.UnsharpMask(radius=0.6, percent=60, threshold=0))
    img.save(os.path.join(iconset, name)); img.save(os.path.join(appiconset, name))
    images.append({"idiom": "mac", "size": f"{size}x{size}", "scale": f"{scale}x", "filename": name})
json.dump({"images": images, "info": {"author": "xcode", "version": 1}},
          open(os.path.join(appiconset, "Contents.json"), "w"), indent=2)
master.save(os.path.join(out, "AppIcon.icns"),
            sizes=[(16, 16), (32, 32), (64, 64), (128, 128), (256, 256), (512, 512), (1024, 1024)])
# preview sheet: every size at 1:1 on light and dark backgrounds
sheet = Image.new("RGBA", (1500, 560), (236, 236, 236, 255))
ImageDraw.Draw(sheet).rectangle([0, 280, 1500, 560], fill=(30, 30, 30, 255))
x = 20
for px in (16, 32, 64, 128, 256):
    im = Image.open(os.path.join(iconset, f"icon_{px}x{px}.png" if px != 64 else "icon_32x32@2x.png"))
    sheet.alpha_composite(im, (x, 140 - px // 2)); sheet.alpha_composite(im, (x, 420 - px // 2)); x += px + 40
sheet.alpha_composite(master.resize((256, 256), Image.LANCZOS), (x, 12))
sheet.save(os.path.join(out, "preview.png"))
print("done")
