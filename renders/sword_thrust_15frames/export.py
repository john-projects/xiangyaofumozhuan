from pathlib import Path
import json, subprocess, shutil, zipfile
from PIL import Image, ImageChops

root = Path(__file__).resolve().parent
manifest = json.loads((root/'manifest.json').read_text(encoding='utf-8'))
frames = root/'frames'
sources = root/'source_frames'
frames.mkdir(exist_ok=True)
sources.mkdir(exist_ok=True)
durations = [100,100,100,100,100,100,100,250,250,250,300,300,300,350,300]
for entry in manifest:
    name = f"frame_{entry['frame']:02d}.png"
    shutil.copy2(entry['path'], sources/name)
subprocess.run(['ffmpeg','-hide_banner','-loglevel','error','-y','-start_number','1','-i',str(sources/'frame_%02d.png'),'-vf',"scale=1920:1080:flags=lanczos,lutrgb=r='if(lte(val,2),0,val)':g='if(lte(val,2),0,val)':b='if(lte(val,2),0,val)'",'-frames:v','15',str(frames/'frame_%02d.png')],check=True)
lines=[]
for i,d in enumerate(durations,1):
    lines += [f"file 'frames/frame_{i:02d}.png'", f'duration {d/1000:.3f}']
lines += ["file 'frames/frame_15.png'"]
(root/'timing.txt').write_text('\n'.join(lines)+'\n',encoding='utf-8')
subprocess.run(['ffmpeg','-hide_banner','-loglevel','error','-y','-f','concat','-safe','0','-i',str(root/'timing.txt'),'-t','3','-vf','fps=30','-c:v','libx264','-crf','17','-pix_fmt','yuv420p','-movflags','+faststart',str(root/'sword_thrust_preview.mp4')],check=True)
subprocess.run(['ffmpeg','-hide_banner','-loglevel','error','-y','-i',str(root/'sword_thrust_preview.mp4'),'-filter_complex','fps=20,scale=800:-1:flags=lanczos,split[a][b];[a]palettegen[p];[b][p]paletteuse','-loop','0',str(root/'sword_thrust_preview.gif')],check=True)
(root/'prompts.txt').write_text('Built-in image_gen. Original image size 1672x941; exported PNG size 1920x1080.\n15 keyframes / 3 seconds. MP4 repeats held frames at 30 fps; no generated motion interpolation.\n\n'+'\n\n'.join(f"FRAME {e['frame']:02d}\n{e['prompt']}" for e in manifest),encoding='utf-8')
with zipfile.ZipFile(root/'sword_thrust_15frames.zip','w',zipfile.ZIP_DEFLATED) as z:
    for p in sorted(frames.glob('*.png')): z.write(p,'frames/'+p.name)
    z.write(root/'prompts.txt','prompts.txt')
    z.write(root/'timing.txt','timing.txt')
for p in sorted(frames.glob('*.png')):
    im=Image.open(p)
    assert im.size==(1920,1080)
first=Image.open(frames/'frame_01.png').convert('RGB')
last=Image.open(frames/'frame_15.png').convert('RGB')
print('15 PNG exports complete. First frame extrema:',first.getextrema())
print('Last frame extrema:',last.getextrema())
print('Seam difference extrema:',ImageChops.difference(first,last).getextrema())
print('Deliverables:',root)

