"""Validate exported authoring data: loops, weights and foot contact."""
from pathlib import Path
import bpy

root=Path(__file__).resolve().parents[2]
bpy.ops.wm.open_mainfile(filepath=str(root/'tools/blender/authoring/nishang_rigged.blend'))
arm=bpy.data.objects['Nishang_Rig']
mesh=bpy.data.objects['Nishang_BodyAndCostume']
scene=bpy.context.scene
assert len(arm.data.bones)==54
maximum_weight_error=0.0
costume_leg_leaks=0
for v in mesh.data.vertices:
    maximum_weight_error=max(maximum_weight_error,abs(sum(g.weight for g in v.groups)-1))
    assert 1<=len(v.groups)<=4
    if -.62<v.co.z<-.26 and abs(v.co.x)>.25:
        for g in v.groups:
            if any(s in mesh.vertex_groups[g.group].name for s in ('UpLeg','Leg','Foot','ToeBase')) and g.weight>.005:
                costume_leg_leaks+=1
assert maximum_weight_error<1e-4
assert costume_leg_leaks==0, costume_leg_leaks
for name in ('idle','run','attack','cast'):
    act=bpy.data.actions[name]
    arm.animation_data.action=act
    lo,hi=map(int,act.frame_range)
    scene.frame_set(lo)
    first=[pb.matrix.copy() for pb in arm.pose.bones]
    scene.frame_set(hi)
    error=max(abs(x-y) for a,b in zip(first,[pb.matrix for pb in arm.pose.bones]) for rowa,rowb in zip(a,b) for x,y in zip(rowa,rowb))
    assert error<1e-4,(name,error)
    print('LOOP',name,'endpoint_error',error,flush=True)
    if name=='run':
        for side,offset in [('Left',0),('Right',.5)]:
            planted=[]
            for f in range(lo,hi):
                phase=((f-lo)/(hi-lo)+offset)%1
                scene.frame_set(f)
                if phase<.60:
                    planted.append(arm.pose.bones['mixamorig:'+side+'Foot'].head.z)
            drift=max(planted)-min(planted)
            assert drift<.006,(side,drift,planted)
            print('FOOT',side,'stance_vertical_drift',drift,flush=True)
print('PASS weights',maximum_weight_error,'costume_leg_leaks',costume_leg_leaks,flush=True)
