# アプリのアイコン（石のアーチの扉と、向こうの光）を作る。使い方：python3 tools/make_icon.py → AppIcon.png
import math, random
from PIL import Image, ImageDraw, ImageFilter, ImageChops

S = 4096  # 4 倍で描いて、最後に 1024 に縮める（ふちをなめらかに）
def lerp(a, b, t): return tuple(int(a[i] + (b[i]-a[i])*t) for i in range(3))

def vgrad(w, h, top, bottom):
    g = Image.new('RGB', (1, h))
    for y in range(h):
        g.putpixel((0, y), lerp(top, bottom, y/(h-1)))
    return g.resize((w, h))

def radial(w, h, cx, cy, r, color, alpha):
    m = Image.new('L', (w, h), 0)
    d = ImageDraw.Draw(m)
    steps = 120
    for i in range(steps, 0, -1):
        t = i/steps
        a = int(alpha * (1 - t)**1.8)
        d.ellipse([cx-r*t, cy-r*t, cx+r*t, cy+r*t], fill=a)
    layer = Image.new('RGB', (w, h), color)
    return layer, m.filter(ImageFilter.GaussianBlur(S//200))

def arch_mask(w, h, x0, x1, ytop, ybottom):
    m = Image.new('L', (w, h), 0)
    d = ImageDraw.Draw(m)
    r = (x1 - x0)/2
    d.rectangle([x0, ytop + r, x1, ybottom], fill=255)
    d.ellipse([x0, ytop, x1, ytop + 2*r], fill=255)
    return m

img = vgrad(S, S, (20, 78, 66), (8, 36, 32))

# 扉の向こうからの光（背景にもうっすら）
cx = S/2
layer, m = radial(S, S, cx, S*0.50, S*0.55, (255, 214, 150), 70)
img.paste(layer, (0, 0), m)

# アーチの寸法
ow = S*0.54            # 外の幅
ox0, ox1 = cx - ow/2, cx + ow/2
otop, obottom = S*0.17, S*0.79
fw = S*0.062           # 枠の太さ
ix0, ix1 = ox0 + fw, ox1 - fw
itop, ibottom = otop + fw, obottom

# 接地の影
sh = Image.new('L', (S, S), 0)
ImageDraw.Draw(sh).ellipse([ox0 - S*0.06, obottom - S*0.035, ox1 + S*0.06, obottom + S*0.055], fill=150)
sh = sh.filter(ImageFilter.GaussianBlur(S//60))
img.paste((4, 18, 16), (0, 0), sh)

# 手前の地面に広がる光
spill = Image.new('L', (S, S), 0)
ImageDraw.Draw(spill).ellipse([cx - S*0.24, obottom - S*0.01, cx + S*0.24, obottom + S*0.11], fill=125)
spill = spill.filter(ImageFilter.GaussianBlur(S//28))
img.paste((255, 200, 120), (0, 0), spill)

# 枠（あたたかい白の石）。少し下が暗い
outer = arch_mask(S, S, ox0, ox1, otop, obottom)
stone = vgrad(S, S, (250, 247, 240), (214, 208, 196))
img.paste(stone, (0, 0), outer)
# 枠の左側に、ほんのり陰（厚み）
shade = Image.new('L', (S, S), 0)
ImageDraw.Draw(shade).rectangle([ox0, 0, ox0 + fw*0.45, S], fill=60)
shade = ImageChops.multiply(shade, outer).filter(ImageFilter.GaussianBlur(S//300))
img.paste((150, 140, 125), (0, 0), shade)

# 開口部の向こう：上は深い緑、下はあたたかい光
inner = arch_mask(S, S, ix0, ix1, itop, ibottom)
sky = vgrad(S, S, (34, 120, 104), (255, 222, 160))
sky2 = Image.new('RGB', (S, S))
sky2.paste(sky.crop((0, 0, S, S)))
glow_layer, glow_m = radial(S, S, cx, S*0.60, S*0.34, (255, 250, 236), 250)
sky2.paste(glow_layer, (0, 0), glow_m)
# 光の粒
rnd = random.Random(7)
motes = Image.new('L', (S, S), 0)
d = ImageDraw.Draw(motes)
for _ in range(11):
    x = rnd.uniform(ix0 + S*0.04, ix1 - S*0.04)
    y = rnd.uniform(itop + S*0.12, ibottom - S*0.10)
    r = rnd.uniform(S*0.0035, S*0.0075)
    d.ellipse([x-r, y-r, x+r, y+r], fill=255)
halo = motes.filter(ImageFilter.GaussianBlur(S//160)).point(lambda v: min(255, v*3))
sky2.paste((255, 236, 190), (0, 0), halo)
sky2.paste((255, 252, 240), (0, 0), motes)
img.paste(sky2, (0, 0), inner)

# 開口部のふちの光の線
trim = ImageChops.subtract(arch_mask(S, S, ix0 - S*0.006, ix1 + S*0.006, itop - S*0.006, ibottom), inner)
trim_glow = trim.filter(ImageFilter.GaussianBlur(S//250))
img.paste((255, 222, 160), (0, 0), trim_glow)
img.paste((255, 232, 186), (0, 0), trim)

# 踏み石
slab = Image.new('L', (S, S), 0)
ImageDraw.Draw(slab).rounded_rectangle([ox0 - S*0.025, obottom - S*0.004, ox1 + S*0.025, obottom + S*0.028],
                                       radius=S*0.01, fill=255)
img.paste((226, 220, 208), (0, 0), slab)

out = img.resize((1024, 1024), Image.LANCZOS).convert('RGB')
out.save('AppIcon.png')
out.resize((256, 256), Image.LANCZOS).save('preview.png')
print('ok')
