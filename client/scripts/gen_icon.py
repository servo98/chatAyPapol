#!/usr/bin/env python3
"""Genera el ícono de la app (marca ❯ terminal) en todos los formatos de plataforma.
Reproduce el badge del login: cuadro oscuro redondeado (inset) + borde + chevron
verde neón con glow. Tokens calcados de theme.dart (Pal).

Uso:  python3 scripts/gen_icon.py   (desde client/)
"""
import os
from PIL import Image, ImageDraw, ImageFilter

HERE = os.path.dirname(os.path.abspath(__file__))
CLIENT = os.path.dirname(HERE)

# Tokens (Pal) — theme.dart
BG      = (0x07, 0x0A, 0x09, 255)   # Pal.inset  #070A09
BORDER  = (0x2A, 0x35, 0x2F, 255)   # Pal.borderStrong #2A352F
GREEN   = (0x39, 0xFF, 0x14, 255)   # Pal.accent #39FF14

S = 4                  # supersampling para bordes suaves
N = 1024               # tamaño master
W = N * S

def render():
    img = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)

    margin = int(W * 0.055)
    radius = int(W * 0.22)
    box = [margin, margin, W - margin, W - margin]

    # fondo redondeado + borde
    d.rounded_rectangle(box, radius=radius, fill=BG)
    bw = max(2, int(W * 0.018))
    d.rounded_rectangle(box, radius=radius, outline=BORDER, width=bw)

    # chevron ❯ — normalizado dentro del cuadro
    def pt(nx, ny):
        return (margin + nx * (W - 2 * margin), margin + ny * (W - 2 * margin))
    top, tip, bot = pt(0.40, 0.30), pt(0.665, 0.50), pt(0.40, 0.70)
    stroke = int(W * 0.115)

    # capa de glow: chevron verde difuminado
    glow = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    gd = ImageDraw.Draw(glow)
    gd.line([top, tip, bot], fill=GREEN, width=stroke, joint="curve")
    for p in (top, tip, bot):
        gd.ellipse([p[0]-stroke/2, p[1]-stroke/2, p[0]+stroke/2, p[1]+stroke/2], fill=GREEN)
    glow = glow.filter(ImageFilter.GaussianBlur(W * 0.035))
    # recorta el glow al cuadro redondeado (que no se desborde)
    mask = Image.new("L", (W, W), 0)
    ImageDraw.Draw(mask).rounded_rectangle(box, radius=radius, fill=255)
    img = Image.alpha_composite(img, Image.composite(glow, Image.new("RGBA", (W, W), (0,0,0,0)), mask))

    # chevron nítido encima
    d = ImageDraw.Draw(img)
    d.line([top, tip, bot], fill=GREEN, width=stroke, joint="curve")
    for p in (top, tip, bot):
        d.ellipse([p[0]-stroke/2, p[1]-stroke/2, p[0]+stroke/2, p[1]+stroke/2], fill=GREEN)

    return img.resize((N, N), Image.LANCZOS)

def main():
    master = render()

    # preview
    master.save(os.path.join(CLIENT, "icon_preview.png"))

    # Windows .ico (multi-tamaño)
    ico = os.path.join(CLIENT, "windows", "runner", "resources", "app_icon.ico")
    master.save(ico, format="ICO",
                sizes=[(256,256),(128,128),(64,64),(48,48),(32,32),(16,16)])
    print("✓", ico)

    # macOS appiconset
    macdir = os.path.join(CLIENT, "macos", "Runner", "Assets.xcassets", "AppIcon.appiconset")
    for sz in (16, 32, 64, 128, 256, 512, 1024):
        p = os.path.join(macdir, f"app_icon_{sz}.png")
        master.resize((sz, sz), Image.LANCZOS).save(p)
        print("✓", p)

    # Linux / AppImage
    appdir = os.path.join(CLIENT, "packaging", "AppDir")
    png = os.path.join(appdir, "chatpapol.png")
    master.resize((512, 512), Image.LANCZOS).save(png)
    master.resize((512, 512), Image.LANCZOS).save(os.path.join(appdir, ".DirIcon"), format="PNG")
    print("✓", png, "+ .DirIcon")

    print("✓ preview:", os.path.join(CLIENT, "icon_preview.png"))

if __name__ == "__main__":
    main()
