"""Rebuild Nishang from the original static mesh, with separate costume weights.

blender --background --factory-startup --python tools/blender/rebuild_nishang.py
Optional arguments after --: --source <original.glb>.
The editable .blend contains mesh, normalized weights, rig and all four actions.
"""
import argparse
import math
from pathlib import Path
import sys

import bpy
import bmesh
import numpy as np
from mathutils import Vector, Quaternion

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / 'assets/models/nishang'
AUTHORING = ROOT / 'tools/blender/authoring'
parser = argparse.ArgumentParser()
parser.add_argument('--source', default=r'E:/dream/godot/各种UI图/units/players/霓裳.glb')
args = parser.parse_args(sys.argv[sys.argv.index('--') + 1:] if '--' in sys.argv else [])
OUT.mkdir(parents=True, exist_ok=True)
AUTHORING.mkdir(parents=True, exist_ok=True)
bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.context.preferences.filepaths.save_version = 0
bpy.ops.import_scene.gltf(filepath=args.source)
meshes = [o for o in bpy.context.scene.objects if o.type == 'MESH']
if len(meshes) != 1:
    raise RuntimeError('Expected one original static mesh')
mesh = meshes[0]
mesh.matrix_world = mesh.matrix_world.copy()
for obj in list(bpy.context.scene.objects):
    if obj != mesh:
        bpy.data.objects.remove(obj, do_unlink=True)
mesh.parent = None
bpy.context.view_layer.objects.active = mesh
mesh.select_set(True)
bpy.ops.object.transform_apply(location=True, rotation=True, scale=True)
mesh.vertex_groups.clear()
for modifier in list(mesh.modifiers):
    mesh.modifiers.remove(modifier)
mesh.name = 'Nishang_BodyAndCostume'

# Positions are measured in the actual original mesh, rather than bounding-box
# proportions (the two large hair buns otherwise shift every anatomical joint).
spec = {}
def bone(name, head, tail, parent=None, deform=True):
    spec[name] = (Vector(head), Vector(tail), parent, deform)

bone('root', (0,0,-.95), (0,0,-.75), deform=False)
bone('mixamorig:Hips', (0,0,-.30), (0,0,-.10), 'root')
bone('mixamorig:Spine', (0,0,-.10), (0,0,.035), 'mixamorig:Hips')
bone('mixamorig:Spine1', (0,0,.035), (0,0,.17), 'mixamorig:Spine')
bone('mixamorig:Neck', (0,0,.17), (0,-.01,.29), 'mixamorig:Spine1')
bone('mixamorig:Head', (0,-.01,.29), (0,-.01,.79), 'mixamorig:Neck')
for side, sign in [('Left',1), ('Right',-1)]:
    pre = 'mixamorig:' + side
    bone(pre+'Shoulder', (sign*.06,0,.13), (sign*.175,0,.115), 'mixamorig:Spine1')
    bone(pre+'Arm', (sign*.175,0,.115), (sign*.34,0,.065), pre+'Shoulder')
    bone(pre+'ForeArm', (sign*.34,0,.065), (sign*.49,-.015,.035), pre+'Arm')
    bone(pre+'Hand', (sign*.49,-.015,.035), (sign*.565,-.025,.025), pre+'ForeArm')
    bone(pre+'UpLeg', (sign*.165,.005,-.34), (sign*.175,.005,-.65), 'mixamorig:Hips')
    bone(pre+'Leg', (sign*.175,.005,-.65), (sign*.18,.005,-.86), pre+'UpLeg')
    bone(pre+'Foot', (sign*.18,.005,-.86), (sign*.18,-.10,-.91), pre+'Leg')
    bone(pre+'ToeBase', (sign*.18,-.10,-.91), (sign*.18,-.17,-.915), pre+'Foot')
    # Sleeves have their own downward chains. They never bind to a thigh.
    bone('sleeve_'+side+'_01', (sign*.35,0,.04), (sign*.38,0,-.16), pre+'ForeArm')
    bone('sleeve_'+side+'_02', (sign*.38,0,-.16), (sign*.41,0,-.42), 'sleeve_'+side+'_01')
    # Back hair/ribbons follow their actual attachment (head or waist).
    for kind, z, parent in [('hair',.62,'mixamorig:Head'),('ribbon',-.12,'mixamorig:Hips')]:
        for segment in range(3):
            name=f'{kind}_{side}_{segment+1:02}'
            h=(sign*(.34+.045*segment), .22+.065*segment, z-.22*segment)
            t=(sign*(.34+.045*(segment+1)), .22+.065*(segment+1), z-.22*(segment+1))
            bone(name,h,t,parent if segment==0 else f'{kind}_{side}_{segment:02}')
for panel in range(8):
    angle=panel*math.tau/8
    dx,dy=math.sin(angle),-math.cos(angle)
    bone(f'skirt_{panel}_01',(dx*.17,dy*.12,-.16),(dx*.27,dy*.19,-.43),'mixamorig:Hips')
    bone(f'skirt_{panel}_02',(dx*.27,dy*.19,-.43),(dx*.39,dy*.29,-.73),f'skirt_{panel}_01')

data=bpy.data.armatures.new('Nishang_CostumeRig')
arm=bpy.data.objects.new('Nishang_Rig',data)
bpy.context.collection.objects.link(arm)
mesh.select_set(False);arm.select_set(True)
bpy.context.view_layer.objects.active=arm
bpy.ops.object.mode_set(mode='EDIT')
for name,(head,tail,parent,deform) in spec.items():
    eb=data.edit_bones.new(name);eb.head=head;eb.tail=tail;eb.use_deform=deform
    eb.align_roll(Vector((0,-1,0)))
    if parent:eb.parent=data.edit_bones[parent]
bpy.ops.object.mode_set(mode='OBJECT')
arm.show_in_front=True
for collection, prefix in [('Costume','skirt_'),('Sleeves','sleeve_'),('Hair','hair_'),('Ribbons','ribbon_'),('Body','mixamorig:')]:
    bc=data.collections.new(collection)
    for b in data.bones:
        if b.name.startswith(prefix):bc.assign(b)

coords=np.empty(len(mesh.data.vertices)*3,dtype=np.float32)
mesh.data.vertices.foreach_get('co',coords)
p=coords.reshape(-1,3);x,y,z=p.T
def ramp(v,a,b):
    t=np.clip((v-a)/(b-a),0,1);return t*t*(3-2*t)
names=[n for n in spec if spec[n][3]]
indices={n:i for i,n in enumerate(names)}
weights=np.zeros((len(p),len(names)),dtype=np.float32)
def add(name, value):weights[:,indices[name]]+=value

# Every region gets a complete normalized distribution. Costume classification
# precedes distance weighting, so spatially adjacent limbs cannot steal cloth.
head=ramp(z,.19,.32)
torso=1-head
add('mixamorig:Head',head)
for name, center, width in [('mixamorig:Hips',-.20,.23),('mixamorig:Spine',-.025,.17),('mixamorig:Spine1',.095,.15),('mixamorig:Neck',.23,.10)]:
    add(name,torso*np.exp(-((z-center)/width)**2))
weights/=np.maximum(weights.sum(axis=1,keepdims=True),1e-8)

def replace_region(mask, field):
    total=field.sum(axis=1,keepdims=True)
    valid=total[:,0]>1e-10
    mask=mask*valid
    weights[:]*=(1-mask[:,None])
    weights[:]+=field/np.maximum(total,1e-10)*mask[:,None]

# Radial skirt panels stay with pelvis, with a soft waist transition and two
# sections per panel. No part of this field has a leg influence.
field=np.zeros_like(weights)
theta=np.arctan2(x,-y)
lower=ramp(-z,.12,.26)*(1-ramp(-z,.73,.81))
for panel in range(8):
    angle=panel*math.tau/8
    delta=np.arctan2(np.sin(theta-angle),np.cos(theta-angle))
    angular=np.exp(-.5*(delta/.49)**2)
    blend=ramp(-z,.38,.64)
    field[:,indices[f'skirt_{panel}_01']]=angular*(1-blend)
    field[:,indices[f'skirt_{panel}_02']]=angular*blend
replace_region(lower,field)

for side,sign in [('Left',1),('Right',-1)]:
    pre='mixamorig:'+side
    # Arms and hanging sleeves have separate spatial gates.
    arm_mask=ramp(x*sign,.20,.29)*(1-ramp(z,.17,.25))*ramp(z,-.10,.025)*(1-ramp(y,.13,.25))
    field=np.zeros_like(weights)
    for suffix,radius in [('Shoulder',.09),('Arm',.07),('ForeArm',.07),('Hand',.05)]:
        n=pre+suffix;a,b,*_=spec[n];a=np.array(a);b=np.array(b)
        v=b-a;t=np.clip((p-a)@v/float(v@v),0,1)
        d=np.sum((p-(a+t[:,None]*v))**2,axis=1)
        field[:,indices[n]]=np.exp(-d/(2*radius*radius))
    replace_region(arm_mask,field)
    sleeve_mask=ramp(x*sign,.245,.315)*(1-ramp(z,-.03,.035))*ramp(z,-.47,-.38)*(1-ramp(y,.14,.24))
    field=np.zeros_like(weights)
    b=ramp(-z,.10,.31)
    field[:,indices['sleeve_'+side+'_01']]=1-b
    field[:,indices['sleeve_'+side+'_02']]=b
    replace_region(sleeve_mask,field)
    # Only the actual lower leg/boot corridor can be assigned to the leg rig.
    leg_mask=(1-ramp(np.abs(x-sign*.18),.065,.12))*(1-ramp(np.abs(y-.005),.075,.15))*ramp(-z,.64,.73)
    leg_mask=np.maximum(leg_mask, (1-ramp(np.abs(x-sign*.18),.085,.14))*ramp(-z,.82,.86))
    field=np.zeros_like(weights)
    for suffix,center,width in [('UpLeg',-.54,.16),('Leg',-.75,.12),('Foot',-.87,.08),('ToeBase',-.93,.06)]:
        n=pre+suffix
        value=np.exp(-((z-center)/width)**2)
        if suffix=='ToeBase':value*=ramp(-y,.06,.14)
        field[:,indices[n]]=value
    replace_region(leg_mask,field)
    # Behind the body, ribbons stay attached to head/waist instead of knees.
    for kind,mask,top in [('hair',ramp(y,.20,.30)*ramp(z,-.12,.18),.62),('ribbon',ramp(y,.18,.30)*(1-ramp(z,-.10,.12))*ramp(z,-.80,-.70),-.12)]:
        mask*=ramp(x*sign,.12,.25)
        field=np.zeros_like(weights)
        along=np.clip((top-z)/.22,0,2)
        for segment in range(3):field[:,indices[f'{kind}_{side}_{segment+1:02}']]=np.exp(-((along-segment)/.65)**2)
        replace_region(mask,field)

# Four normalized influences match the glTF/Godot skinning budget.
top=np.argpartition(weights,-4,axis=1)[:,-4:]
vals=np.take_along_axis(weights,top,axis=1)
vals/=np.maximum(vals.sum(axis=1,keepdims=True),1e-8)
assert np.isfinite(vals).all() and np.allclose(vals.sum(axis=1),1,atol=1e-5)
for n in names:mesh.vertex_groups.new(name=n)
bm=bmesh.new();bm.from_mesh(mesh.data);layer=bm.verts.layers.deform.verify()
for i,v in enumerate(bm.verts):
    for j in range(4):
        if vals[i,j]>1e-6:v[layer][int(top[i,j])]=float(vals[i,j])
bm.to_mesh(mesh.data);bm.free()
mod=mesh.modifiers.new('Nishang_Skin','ARMATURE');mod.object=arm
mesh.parent=arm
del weights

# Convert desired armature-space rotation axes into each bone's actual local
# basis, instead of assuming that every bone uses the same X/Y/Z convention.
def qworld(pb, rotations):
    q=Quaternion()
    for axis,deg in rotations:
        q=Quaternion(Vector(axis),math.radians(deg))@q
    basis=pb.bone.matrix_local.to_quaternion()
    pb.rotation_quaternion=basis.inverted()@q@basis

def ik_leg(side, phase, bob):
    pre='mixamorig:'+side
    # 60% planted stance, then a smooth low swing. No horizontal root motion.
    u=phase%1
    if u<.60:
        foot_y=-.15+.30*(u/.60);lift=0
    else:
        s=(u-.60)/.40
        foot_y=.15-.30*(s*s*(3-2*s));lift=.080*math.sin(math.pi*s)**2
    hip=Vector(spec[pre+'UpLeg'][0]);hip.z+=bob
    target=Vector((hip.x,foot_y,-.86+lift))
    a=(spec[pre+'UpLeg'][1]-spec[pre+'UpLeg'][0]).length
    b=(spec[pre+'Leg'][1]-spec[pre+'Leg'][0]).length
    d=target-hip;dist=min(d.length,a+b-.002);direction=d.normalized()
    along=(a*a-b*b+dist*dist)/(2*dist)
    height=math.sqrt(max(a*a-along*along,0))
    bend=Vector((0,-direction.z,direction.y))
    if bend.y>0:bend=-bend
    knee=hip+direction*along+bend*height
    for suffix,start,end in [('UpLeg',hip,knee),('Leg',knee,target)]:
        pb=arm.pose.bones[pre+suffix]
        basis=pb.bone.matrix_local.to_quaternion()
        rest=(spec[pre+suffix][1]-spec[pre+suffix][0]).normalized()
        delta=rest.rotation_difference((end-start).normalized())
        absolute=delta@basis
        parent=pb.parent
        relative_rest=parent.bone.matrix_local.to_quaternion().inverted()@basis
        pb.rotation_quaternion=relative_rest.inverted()@parent.matrix.to_quaternion().inverted()@absolute
        bpy.context.view_layer.update()
    # Counter shin orientation to keep the boot approximately level in stance.
    pb=arm.pose.bones[pre+'Foot'];basis=pb.bone.matrix_local.to_quaternion()
    rel=pb.parent.bone.matrix_local.to_quaternion().inverted()@basis
    roll=-6*math.sin(math.pi*u/.60) if u<.60 else 8*math.sin(math.pi*(u-.60)/.40)
    desired=Quaternion((1,0,0),math.radians(roll))@basis
    pb.rotation_quaternion=rel.inverted()@pb.parent.matrix.to_quaternion().inverted()@desired

FPS=30
bpy.context.scene.render.fps=FPS
arm.animation_data_create()
for pb in arm.pose.bones:pb.rotation_mode='QUATERNION'
for action_name,duration in [('idle',3.2),('run',.8),('attack',.72),('cast',1.1)]:
    action=bpy.data.actions.new(action_name);action.use_fake_user=True
    arm.animation_data.action=action
    count=round(duration*FPS)
    for frame in range(count+1):
        bpy.context.scene.frame_set(frame+1)
        t=frame/count;phase=math.tau*t;wave=math.sin(phase)
        for pb in arm.pose.bones:pb.rotation_quaternion=Quaternion();pb.location=(0,0,0);pb.scale=(1,1,1)
        running=action_name=='run'
        pulse=math.sin(math.pi*t)**2 if action_name in ('attack','cast') else 0
        tilt=3.5 if running else .5*wave
        qworld(arm.pose.bones['mixamorig:Spine'],[((1,0,0),tilt)])
        qworld(arm.pose.bones['mixamorig:Spine1'],[((0,0,1),(-2*wave if running else 0)+(8*pulse if action_name=='attack' else 0)),((1,0,0),.7*wave)])
        qworld(arm.pose.bones['mixamorig:Head'],[((1,0,0),-tilt*.7)])
        bob=-.040+.008*(1-math.cos(2*phase)) if running else .002*wave
        hips=arm.pose.bones['mixamorig:Hips']
        hips.location=hips.bone.matrix_local.to_3x3().inverted()@Vector((0,0,bob))
        for side,sign in [('Left',1),('Right',-1)]:
            drop=27.0
            swing=18*math.cos(phase) if running else .6*wave*sign
            elbow=20.0 if running else 8.0
            if action_name=='cast':drop-=18*pulse;swing-=20*pulse;elbow+=14*pulse
            if action_name=='attack' and side=='Right':swing-=28*pulse;elbow+=12*pulse
            qworld(arm.pose.bones['mixamorig:'+side+'Arm'],[((0,1,0),sign*drop),((0,0,1),swing)])
            qworld(arm.pose.bones['mixamorig:'+side+'ForeArm'],[((0,0,1),-sign*elbow)])
            # Gravity compensation plus low-amplitude delayed motion.
            qworld(arm.pose.bones['sleeve_'+side+'_01'],[((0,0,1),-swing+sign*elbow),((0,1,0),-sign*drop),((1,0,0),2*math.sin(phase-.5))])
            qworld(arm.pose.bones['sleeve_'+side+'_02'],[((1,0,0),2.5*math.sin(phase-.9))])
            for kind in ('hair','ribbon'):
                for segment in range(3):
                    amplitude=(1.2 if action_name=='idle' else 3.0)*(1+segment*.25)
                    qworld(arm.pose.bones[f'{kind}_{side}_{segment+1:02}'],[((1,0,0),amplitude*math.sin(phase-.6-segment*.45)),((0,1,0),sign*.5*math.sin(phase-.3))])
        bpy.context.view_layer.update()
        if running:
            ik_leg('Left',t,bob);ik_leg('Right',t+.5,bob)
        for panel in range(8):
            angle=panel*math.tau/8
            for segment in (1,2):
                amount=.6*math.sin(phase-.4*segment+angle) if action_name=='idle' else (2+3*max(0,math.cos(phase+angle-.3*segment)))/segment
                qworld(arm.pose.bones[f'skirt_{panel}_{segment:02}'],[((-math.cos(angle),-math.sin(angle),0),amount)])
        for pb in arm.pose.bones:
            pb.keyframe_insert('rotation_quaternion',frame=frame+1,group=pb.name)
            pb.keyframe_insert('location',frame=frame+1,group=pb.name)
    # Export samples as linear segments: no Bezier overshoot at knee/contact.
    for layer in action.layers:
        for strip in layer.strips:
            for bag in strip.channelbags:
                for fc in bag.fcurves:
                    for key in fc.keyframe_points:key.interpolation='LINEAR'
    print('ACTION',action_name,'frames',count+1,flush=True)

arm.animation_data.action=bpy.data.actions['idle'];bpy.context.scene.frame_set(1)
bpy.context.scene.frame_end=97
bpy.ops.wm.save_as_mainfile(filepath=str(AUTHORING/'nishang_rigged.blend'))
bpy.ops.export_scene.gltf(filepath=str(OUT/'nishang_rigged.glb'),export_format='GLB',export_animations=True,export_animation_mode='ACTIONS',export_skins=True,export_yup=True)
print('EXPORTED',len(data.bones),'bones',len(p),'vertices',flush=True)
