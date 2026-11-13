#!/usr/bin/env python3
"""Grafity Gate のアイコン（G の形の扉をネオンにし、扉の中と足もとに光がもれる。ネオンは下の夕焼けから上の夜空へ）。

使い方：
  python3 tools/icon/make_icon.py          → tools/icon/app_icon.svg を作る
  node tools/icon/render.js                → AppIcon.png（1024）と BrandMark.png（512）を作る（Playwright の Chromium が要る）
2026-11-14 にオーナーが見本から選んだ形（「G の扉 × ネオン × もれる光」「夕焼けから夜空」「縦に移る」）。
"""
import os
def neon_grad(neon, x0, x1, top, bottom, direction="diag"):
    if isinstance(neon, dict):
        stops = "".join(f'<stop offset="{o}" stop-color="{c}"/>' for o, c in neon["stops"])
        if neon["dir"] == "vertical":
            return f'<linearGradient id="neon" gradientUnits="userSpaceOnUse" x1="0" y1="{bottom+30}" x2="0" y2="{top-30}">{stops}</linearGradient>'
        return f'<linearGradient id="neon" gradientUnits="userSpaceOnUse" x1="{x0-20}" y1="{bottom+20}" x2="{x1+20}" y2="{top-20}">{stops}</linearGradient>'
    return (f'<linearGradient id="neon" gradientUnits="userSpaceOnUse" x1="{x0}" y1="{bottom}" x2="{x1}" y2="{top}">'
            f'<stop offset="0" stop-color="{neon[0]}"/><stop offset=".5" stop-color="{neon[1]}"/><stop offset="1" stop-color="{neon[2]}"/></linearGradient>')

def make(name, neon, light, bg, particles=True):
    refl_c = neon["stops"][1][1] if isinstance(neon, dict) else neon[1]
    # G：上は扉のアーチ。右上が開き、右の柱から中へ横棒。y を少し上げて、下に光の床を作る
    x0, x1, top, bottom, r = 326, 698, 236, 742, 186
    yc = top + r
    G = (f"M{x1-14} {yc-62} A{r} {r} 0 0 0 {x0} {yc} L{x0} {bottom-40} Q{x0} {bottom} {x0+40} {bottom} "
         f"L{x1-40} {bottom} Q{x1} {bottom} {x1} {bottom-40} L{x1} {yc+128} L{x0+212} {yc+128}")
    inside = f"M{x0} {bottom} L{x0} {yc} A{r} {r} 0 0 1 {x1} {yc} L{x1} {bottom} Z"
    beam = f"M{x0+18} {bottom+6} L{x1-18} {bottom+6} L{1024+120} 1024 L{-120} 1024 Z"
    import random
    random.seed(4)
    dots = ""
    if particles:
        for _ in range(22):
            t = random.random()
            y = bottom + 30 + t * 250
            half = (x1 - x0) / 2 + t * 330
            x = 512 + random.uniform(-half, half) * 0.8
            dots += f'<circle cx="{x:.0f}" cy="{y:.0f}" r="{random.uniform(2.2,5.5):.1f}" fill="{light[0]}" opacity="{random.uniform(.25,.7):.2f}"/>'
    svg = f'''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="1024" height="1024">
<defs>
 {('<linearGradient id="bg" x1="0" y1="0" x2="0" y2="1">' + ''.join(f'<stop offset="{o}" stop-color="{c}"/>' for o, c in bg) + '</linearGradient>') if isinstance(bg[0], tuple) else f'<radialGradient id="bg" cx="50%" cy="40%" r="80%"><stop offset="0" stop-color="{bg[0]}"/><stop offset=".6" stop-color="{bg[1]}"/><stop offset="1" stop-color="{bg[2]}"/></radialGradient>'}
 {neon_grad(neon, x0, x1, top, bottom)}
 <radialGradient id="room" cx="50%" cy="70%" r="55%"><stop offset="0" stop-color="{light[0]}" stop-opacity="1"/><stop offset=".45" stop-color="{light[1]}" stop-opacity=".55"/><stop offset="1" stop-color="{light[1]}" stop-opacity="0"/></radialGradient>
 <linearGradient id="beam" x1="0" y1="{bottom}" x2="0" y2="1024" gradientUnits="userSpaceOnUse"><stop offset="0" stop-color="{light[0]}" stop-opacity="1"/><stop offset=".18" stop-color="{light[1]}" stop-opacity=".75"/><stop offset=".6" stop-color="{light[1]}" stop-opacity=".22"/><stop offset="1" stop-color="{light[1]}" stop-opacity="0"/></linearGradient>
 <radialGradient id="vig" cx="50%" cy="45%" r="75%"><stop offset=".55" stop-color="#000" stop-opacity="0"/><stop offset="1" stop-color="#000" stop-opacity=".45"/></radialGradient>
 <filter id="glow" x="-40%" y="-40%" width="180%" height="180%"><feGaussianBlur stdDeviation="30"/></filter>
 <filter id="glowS" x="-40%" y="-40%" width="180%" height="180%"><feGaussianBlur stdDeviation="9"/></filter>
 <filter id="beamBlur" x="-30%" y="-30%" width="160%" height="160%"><feGaussianBlur stdDeviation="14"/></filter>
 <filter id="roomBlur" x="-50%" y="-50%" width="200%" height="200%"><feGaussianBlur stdDeviation="38"/></filter>
 <filter id="rayBlur" x="-30%" y="-30%" width="160%" height="160%"><feGaussianBlur stdDeviation="22"/></filter>
 <linearGradient id="door" x1="0" y1="{top}" x2="0" y2="{bottom}" gradientUnits="userSpaceOnUse"><stop offset="0" stop-color="{light[1]}" stop-opacity="0"/><stop offset=".64" stop-color="{light[1]}" stop-opacity=".04"/><stop offset="1" stop-color="{light[0]}" stop-opacity=".7"/></linearGradient>
 <radialGradient id="gap" cx="50%" cy="50%" r="50%"><stop offset="0" stop-color="{light[1]}" stop-opacity=".28"/><stop offset="1" stop-color="{light[1]}" stop-opacity="0"/></radialGradient>
 <linearGradient id="ray" gradientUnits="userSpaceOnUse" x1="{x1}" y1="0" x2="1100" y2="0"><stop offset="0" stop-color="{light[0]}" stop-opacity=".55"/><stop offset="1" stop-color="{light[1]}" stop-opacity="0"/></linearGradient>
 <radialGradient id="refl" gradientUnits="userSpaceOnUse" cx="512" cy="{bottom+40}" r="260"><stop offset="0" stop-color="{refl_c}" stop-opacity=".45"/><stop offset="1" stop-color="{refl_c}" stop-opacity="0"/></radialGradient>
</defs>
<rect width="1024" height="1024" fill="url(#bg)"/>
<rect width="1024" height="1024" fill="url(#vig)"/>
<path d="{beam}" fill="url(#beam)" filter="url(#beamBlur)"/>
<ellipse cx="512" cy="{bottom+44}" rx="260" ry="40" fill="url(#refl)"/>
<path d="{inside}" fill="url(#door)"/>
<ellipse cx="512" cy="{bottom-120}" rx="165" ry="190" fill="url(#room)" filter="url(#roomBlur)"/>
<ellipse cx="512" cy="{bottom-30}" rx="150" ry="46" fill="{light[0]}" opacity=".75" filter="url(#rayBlur)"/>
{dots}
<path d="{G}" fill="none" stroke="url(#neon)" stroke-width="104" stroke-linecap="round" stroke-linejoin="round" opacity=".7" filter="url(#glow)"/>
<path d="{G}" fill="none" stroke="url(#neon)" stroke-width="62" stroke-linecap="round" stroke-linejoin="round"/>
<path d="{G}" fill="none" stroke="#FFF6EC" stroke-width="16" stroke-linecap="round" stroke-linejoin="round" opacity=".7" filter="url(#glowS)"/>
<path d="{G}" fill="none" stroke="#FFFBF5" stroke-width="7" stroke-linecap="round" stroke-linejoin="round" opacity=".95"/>
</svg>'''
    open(name, "w").write(svg)



night_sunset = {"dir": "vertical", "stops": [(0, "#FF9A3C"), (.28, "#FF3D7F"), (.6, "#9B5CFF"), (1, "#3FD0FF")]}
sky = [(0, "#060A24"), (.55, "#140F3A"), (.82, "#2A1240"), (1, "#3A1530")]

if __name__ == "__main__":
    here = os.path.dirname(os.path.abspath(__file__))
    make(os.path.join(here, "app_icon.svg"), night_sunset, ("#FFF4DA", "#FFB04A"), sky)
    print("作りました：tools/icon/app_icon.svg")
