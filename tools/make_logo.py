"""Draws the PugLogs logo (docs/images/logo.png, 1024x1024) for CurseForge/Wago and the addon list."""
import os
from PIL import Image, ImageDraw, ImageFilter

S = 1024
BG, PANEL, CYAN, GOLD, WHITE = (17, 19, 23), (30, 34, 42), (0, 204, 255), (229, 204, 128), (230, 230, 230)
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

img = Image.new("RGB", (S, S), BG)
d = ImageDraw.Draw(img)
d.rounded_rectangle((48, 48, S - 48, S - 48), radius=150, fill=PANEL)

# Rising bars (a run's damage over time / performance).
base = 760
bars = [(230, 300, 600), (340, 410, 520), (450, 520, 420), (560, 630, 300)]
for i, (x0, x1, top) in enumerate(bars):
    d.rounded_rectangle((x0, top, x1, base), radius=16, fill=CYAN if i < 3 else GOLD)
d.rounded_rectangle((200, base, 690, base + 18), radius=9, fill=(60, 66, 78))

# Magnifying glass over the chart (checking applicants).
glow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
g = ImageDraw.Draw(glow)
cx, cy, r = 610, 430, 165
g.ellipse((cx - r - 10, cy - r - 10, cx + r + 10, cy + r + 10), outline=(0, 204, 255, 90), width=40)
glow = glow.filter(ImageFilter.GaussianBlur(18))
img.paste(glow, (0, 0), glow)
d = ImageDraw.Draw(img)
d.ellipse((cx - r, cy - r, cx + r, cy + r), outline=WHITE, width=42)
d.line((cx + r * 0.68, cy + r * 0.68, cx + r * 1.55, cy + r * 1.55), fill=WHITE, width=62)
d.ellipse((cx + r * 1.55 - 31, cy + r * 1.55 - 31, cx + r * 1.55 + 31, cy + r * 1.55 + 31), fill=WHITE)

out = os.path.join(ROOT, "docs", "images")
os.makedirs(out, exist_ok=True)
img.save(os.path.join(out, "logo.png"))
img.resize((400, 400), Image.LANCZOS).save(os.path.join(out, "logo-400.png"))
print("saved", out)
