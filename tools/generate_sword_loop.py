"""Render a short additive-friendly sword VFX loop to PNG frames."""
import math
import os
import random
import shutil
from PIL import Image, ImageDraw, ImageFilter

W, H = 960, 540
FPS, FRAMES = 30, 90
OUT = os.path.join(os.path.dirname(__file__), "..", "renders", "sword_vfx_frames")
random.seed(19)

IMPACTS = [(118, 320), (480, 402), (842, 320)]
ORIGINS = [(480, 105), (480, 105), (480, 105)]
CYAN = (34, 246, 230)
ICE = (195, 255, 255)
GOLD = (255, 216, 131)

def smooth(a, b, x):
    x = max(0.0, min(1.0, (x-a)/(b-a)))
    return x*x*(3-2*x)

def rgba(c, a): return (*c, max(0, min(255, int(a))))

def add_path(draw, points, fill, outline=None, width=1):
    draw.polygon(points, fill=fill)
    if outline:
        draw.line(points+[points[0]], fill=outline, width=width, joint="curve")

def blade_shape(origin, target, progress, spread):
    # A crisp narrow blade with a long wake; the luminous edge leads the body.
    ox, oy = origin; tx, ty = target
    ex, ey = ox+(tx-ox)*progress, oy+(ty-oy)*progress
    dx, dy = tx-ox, ty-oy
    length = max(1, math.hypot(dx,dy)); nx, ny = -dy/length, dx/length
    width = 9 + 5*spread
    bx, by = ex-dx/length*min(92, length*.34), ey-dy/length*min(92, length*.34)
    pts=[(ex+nx*1.2,ey+ny*1.2),(bx+nx*width,by+ny*width),
         (ox+dx/length*18+nx*width*.44,oy+dy/length*18+ny*width*.44),
         (ox+dx/length*8,oy+dy/length*8),
         (ox+dx/length*18-nx*width*.44,oy+dy/length*18-ny*width*.44),
         (bx-nx*width,by-ny*width)]
    return [(int(x),int(y)) for x,y in pts]

def draw_lotus(layer, center, strength, phase):
    if strength <= .005: return
    x,y=center; d=ImageDraw.Draw(layer)
    # Fine expanding elliptical rings.
    radius=18+82*phase
    for k in range(3):
        rr=radius*(.70+k*.22)
        box=(x-rr,y-rr*.28,x+rr,y+rr*.28)
        d.ellipse(box, outline=rgba(GOLD if k==1 else CYAN, 155*strength*(1-k*.22)), width=2 if k==1 else 1)
    # Twelve pointed lotus petals, alternating long and short.
    for i in range(12):
        a=2*math.pi*i/12
        length=(24+22*(.5+.5*math.sin(i*8.1)))*(1-.2*phase)
        width=7+2*math.sin(i*3.2)
        ux,uy=math.cos(a),math.sin(a); px,py=-uy,ux
        base=(x+ux*5,y+uy*3)
        tip=(x+ux*length,y+uy*length*.48)
        side1=(x+ux*length*.52+px*width,y+uy*length*.26+py*width)
        side2=(x+ux*length*.52-px*width,y+uy*length*.26-py*width)
        add_path(d,[base,side1,tip,side2],rgba(CYAN,72*strength),rgba(GOLD,150*strength),1)
        d.line([base,tip], fill=rgba(ICE,135*strength), width=1)
    # Compact brilliant center.
    r=8+10*(1-phase)
    d.ellipse((x-r,y-r,x+r,y+r), fill=rgba(ICE,170*strength))

def render_frame(fi):
    t=fi/FPS
    base=Image.new("RGB",(W,H),(0,0,0))
    if t < .16 or t > 2.80:
        return base
    alpha=smooth(.14,.38,t)*(1-smooth(2.42,2.82,t))
    glow=Image.new("RGBA",(W,H),(0,0,0,0))
    core=Image.new("RGBA",(W,H),(0,0,0,0))
    d=ImageDraw.Draw(core)
    # Inward motes gather, then sparks peel upward during the dissolve.
    for i in range(84):
        ang=random.Random(i*31).random()*math.tau
        r0=35+(i%11)*17
        if t < .46:
            q=1-smooth(.15,.46,t)
            x=480+math.cos(ang)*r0*(.35+q)
            y=250+math.sin(ang)*r0*(.25+q)
            a=100*alpha*q
        else:
            q=smooth(2.05,2.65,t)
            x=480+math.cos(ang)*r0*(.4+q*1.6)
            y=265+math.sin(ang)*r0*.55-q*(40+(i%70)*2)
            a=155*alpha*q
        if a>2:
            rr=1+(i%3==0)
            d.ellipse((x-rr,y-rr,x+rr,y+rr),fill=rgba(ICE,a))
    # Three fan-shaped sword strokes, sweeping rapidly out from a common origin.
    launch=smooth(.30,.92,t)
    for j,(origin,target) in enumerate(zip(ORIGINS,IMPACTS)):
        progress=min(1.0,launch*1.22)
        pts=blade_shape(origin,target,progress,j/2)
        # broad translucent wake, narrow gold edge, and moon-white blade core
        d.polygon(pts,fill=rgba(CYAN,110*alpha))
        d.line([origin,target],fill=rgba(GOLD,115*alpha),width=2)
        d.line([origin,target],fill=rgba(ICE,235*alpha),width=2)
        # trailing filaments taper out behind the slash
        for k in range(3):
            off=(k-1)*5
            d.line([(origin[0]+off,origin[1]),(target[0]+off,target[1])],
                   fill=rgba(CYAN,75*alpha),width=1)
    # Blooming lotus impact sigils and several orbiting qi ribbons.
    bloom=smooth(.69,.98,t)*(1-smooth(1.8,2.65,t))
    for j,c in enumerate(IMPACTS):
        draw_lotus(core,c,bloom, min(1,(t-.69)/.7))
        if bloom>.02:
            x,y=c
            # thin elliptical shockwave expands then dissipates
            r=18+118*smooth(.78,1.56,t)
            fade=(1-smooth(1.35,2.05,t))*bloom
            dd=ImageDraw.Draw(core)
            for k in range(2):
                bx=(x-r*(1+k*.22),y-r*.20*(1+k*.1),x+r*(1+k*.22),y+r*.20*(1+k*.1))
                dd.arc(bx, start=8+k*28, end=168+k*32, fill=rgba(GOLD,135*fade),width=2)
                dd.arc(bx, start=190+k*25, end=350+k*24, fill=rgba(CYAN,115*fade),width=2)
    # A soft aura generated from the crisp source, then additive-composited.
    glow=core.filter(ImageFilter.GaussianBlur(12))
    glow=glow.point(lambda p: int(p*.52))
    base=ImageChops_add(base,glow.convert("RGB"))
    base=ImageChops_add(base,core.convert("RGB"))
    return base

def ImageChops_add(a,b):
    from PIL import ImageChops
    return ImageChops.add(a,b,scale=1.0)

def main():
    if os.path.isdir(OUT): shutil.rmtree(OUT)
    os.makedirs(OUT,exist_ok=True)
    for i in range(FRAMES):
        render_frame(i).resize((1920,1080),Image.Resampling.LANCZOS).save(os.path.join(OUT,f"{i:04d}.png"),compress_level=1)
        if i%15==0: print(f"Rendered {i}/{FRAMES}",flush=True)
    print(OUT)

if __name__ == "__main__": main()
