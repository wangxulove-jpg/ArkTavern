"""
ArkTavern 默认 AI 动作包生成脚本

使用 Blender 5.2 Python API 创建 ArkTavernHumanoidV1 骨骼,
生成 15 个基础人形动画动作,导出为 GLB。

运行方式:
  blender --background --python generate_default_ai_actions.py

输出:
  .agent-cache/default-ai-actions/
  ├── preview_humanoid.blend
  ├── default_ai_action_pack.glb
  ├── preview_humanoid.glb
  ├── default_ai_action_pack.json
  └── generation_report.md

Blender 版本: 5.2.0 LTS
"""

import bpy
import math
import os
import json
import sys
from mathutils import Vector, Euler

# ============================================================
# 常量
# ============================================================

FPS = 24
OUTPUT_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", ".agent-cache", "default-ai-actions")
OUTPUT_DIR = os.path.normpath(OUTPUT_DIR)

ARMATURE_NAME = "ArkTavernHumanoidV1"
MESH_NAME = "PreviewHumanoid"

# 骨骼定义: (name, parent, head, tail)
BONES = [
    # 躯干
    ("Hips", None, (0, 0, 0.90), (0, 0, 1.05)),
    ("Spine", "Hips", (0, 0, 1.05), (0, 0, 1.20)),
    ("Chest", "Spine", (0, 0, 1.20), (0, 0, 1.35)),
    ("UpperChest", "Chest", (0, 0, 1.35), (0, 0, 1.45)),
    ("Neck", "UpperChest", (0, 0, 1.45), (0, 0, 1.53)),
    ("Head", "Neck", (0, 0, 1.53), (0, 0, 1.70)),
    # 左臂
    ("LeftShoulder", "UpperChest", (0.06, 0, 1.40), (0.14, 0, 1.40)),
    ("LeftUpperArm", "LeftShoulder", (0.14, 0, 1.40), (0.34, 0, 1.38)),
    ("LeftLowerArm", "LeftUpperArm", (0.34, 0, 1.38), (0.52, 0, 1.36)),
    ("LeftHand", "LeftLowerArm", (0.52, 0, 1.36), (0.62, 0, 1.35)),
    # 右臂
    ("RightShoulder", "UpperChest", (-0.06, 0, 1.40), (-0.14, 0, 1.40)),
    ("RightUpperArm", "RightShoulder", (-0.14, 0, 1.40), (-0.34, 0, 1.38)),
    ("RightLowerArm", "RightUpperArm", (-0.34, 0, 1.38), (-0.52, 0, 1.36)),
    ("RightHand", "RightLowerArm", (-0.52, 0, 1.36), (-0.62, 0, 1.35)),
    # 左腿
    ("LeftUpperLeg", "Hips", (0.10, 0, 0.90), (0.10, 0, 0.50)),
    ("LeftLowerLeg", "LeftUpperLeg", (0.10, 0, 0.50), (0.10, 0, 0.08)),
    ("LeftFoot", "LeftLowerLeg", (0.10, 0, 0.08), (0.10, 0.12, 0.00)),
    ("LeftToes", "LeftFoot", (0.10, 0.12, 0.00), (0.10, 0.22, 0.00)),
    # 右腿
    ("RightUpperLeg", "Hips", (-0.10, 0, 0.90), (-0.10, 0, 0.50)),
    ("RightLowerLeg", "RightUpperLeg", (-0.10, 0, 0.50), (-0.10, 0, 0.08)),
    ("RightFoot", "RightLowerLeg", (-0.10, 0, 0.08), (-0.10, 0.12, 0.00)),
    ("RightToes", "RightFoot", (-0.10, 0.12, 0.00), (-0.10, 0.22, 0.00)),
]

# 动作定义: (clip_name, display_name, duration_sec, loop)
ACTIONS = [
    ("AT_Idle", "待机", 4.0, True),
    ("AT_Listening", "倾听", 3.0, True),
    ("AT_Thinking", "思考", 3.0, True),
    ("AT_Speaking", "说话", 2.0, True),
    ("AT_Greeting", "问候", 1.8, False),
    ("AT_Wave", "挥手", 2.0, False),
    ("AT_Nod", "点头", 1.2, False),
    ("AT_ShakeHead", "摇头", 1.2, False),
    ("AT_Happy", "开心", 1.8, False),
    ("AT_Confused", "疑惑", 2.0, False),
    ("AT_Sad", "难过", 2.0, False),
    ("AT_Angry", "生气", 1.8, False),
    ("AT_TouchReaction", "触摸回应", 0.8, False),
    ("AT_Celebrate", "庆祝", 2.2, False),
    ("AT_Apology", "抱歉", 1.5, False),
]

# ============================================================
# 工具函数
# ============================================================

def deg2rad(d):
    return math.radians(d)

def clear_scene():
    """清空场景"""
    bpy.ops.object.select_all(action='SELECT')
    bpy.ops.object.delete(use_global=False)
    # 清理残留数据
    for block in bpy.data.meshes:
        bpy.data.meshes.remove(block)
    for block in bpy.data.armatures:
        bpy.data.armatures.remove(block)
    for block in bpy.data.actions:
        bpy.data.actions.remove(block)
    for block in bpy.data.materials:
        bpy.data.materials.remove(block)
    for block in bpy.data.cameras:
        bpy.data.cameras.remove(block)
    for block in bpy.data.lights:
        bpy.data.lights.remove(block)

def create_armature():
    """创建骨骼"""
    arm_data = bpy.data.armatures.new(ARMATURE_NAME)
    arm_obj = bpy.data.objects.new(ARMATURE_NAME, arm_data)
    bpy.context.collection.objects.link(arm_obj)
    bpy.context.view_layer.objects.active = arm_obj
    bpy.ops.object.mode_set(mode='EDIT')

    bone_map = {}
    for name, parent, head, tail in BONES:
        bone = arm_data.edit_bones.new(name)
        bone.head = Vector(head)
        bone.tail = Vector(tail)
        bone_map[name] = bone

    for name, parent, head, tail in BONES:
        if parent and parent in bone_map:
            bone_map[name].parent = bone_map[parent]
            # 使用 connect 仅当 tail/head 对齐
            bone_map[name].use_connect = False

    bpy.ops.object.mode_set(mode='OBJECT')

    # 设置所有骨骼的旋转模式为 XYZ
    for bone in arm_obj.pose.bones:
        bone.rotation_mode = 'XYZ'

    return arm_obj

def create_mesh(arm_obj):
    """创建简单人形网格"""
    segments = [
        # (name, bone_name, center, scale)
        ("Pelvis", "Hips", (0, 0, 0.97), (0.22, 0.14, 0.12)),
        ("TorsoLower", "Spine", (0, 0, 1.12), (0.20, 0.13, 0.12)),
        ("Chest", "Chest", (0, 0, 1.27), (0.22, 0.14, 0.13)),
        ("UpperChest", "UpperChest", (0, 0, 1.40), (0.20, 0.13, 0.10)),
        ("Neck", "Neck", (0, 0, 1.49), (0.06, 0.06, 0.05)),
        ("Head", "Head", (0, 0, 1.61), (0.13, 0.14, 0.15)),
        ("L_Shoulder", "LeftShoulder", (0.10, 0, 1.40), (0.05, 0.05, 0.05)),
        ("L_UpperArm", "LeftUpperArm", (0.24, 0, 1.39), (0.04, 0.04, 0.10)),
        ("L_LowerArm", "LeftLowerArm", (0.43, 0, 1.37), (0.035, 0.035, 0.09)),
        ("L_Hand", "LeftHand", (0.57, 0, 1.355), (0.04, 0.04, 0.05)),
        ("R_Shoulder", "RightShoulder", (-0.10, 0, 1.40), (0.05, 0.05, 0.05)),
        ("R_UpperArm", "RightUpperArm", (-0.24, 0, 1.39), (0.04, 0.04, 0.10)),
        ("R_LowerArm", "RightLowerArm", (-0.43, 0, 1.37), (0.035, 0.035, 0.09)),
        ("R_Hand", "RightHand", (-0.57, 0, 1.355), (0.04, 0.04, 0.05)),
        ("L_UpperLeg", "LeftUpperLeg", (0.10, 0, 0.70), (0.05, 0.05, 0.20)),
        ("L_LowerLeg", "LeftLowerLeg", (0.10, 0, 0.29), (0.045, 0.045, 0.20)),
        ("L_Foot", "LeftFoot", (0.10, 0.06, 0.04), (0.05, 0.08, 0.04)),
        ("L_Toes", "LeftToes", (0.10, 0.17, 0.02), (0.04, 0.05, 0.02)),
        ("R_UpperLeg", "RightUpperLeg", (-0.10, 0, 0.70), (0.05, 0.05, 0.20)),
        ("R_LowerLeg", "RightLowerLeg", (-0.10, 0, 0.29), (0.045, 0.045, 0.20)),
        ("R_Foot", "RightFoot", (-0.10, 0.06, 0.04), (0.05, 0.08, 0.04)),
        ("R_Toes", "RightToes", (-0.10, 0.17, 0.02), (0.04, 0.05, 0.02)),
    ]

    meshes = []
    for name, bone_name, center, scale in segments:
        bpy.ops.mesh.primitive_cube_add(size=1, location=center)
        obj = bpy.context.object
        obj.scale = (scale[0], scale[1], scale[2])
        bpy.ops.object.transform_apply(scale=True)
        obj.name = name
        vg = obj.vertex_groups.new(name=bone_name)
        vg.add([v.index for v in obj.data.vertices], 1.0, 'REPLACE')
        meshes.append(obj)

    # 选中所有 mesh 并 join
    bpy.ops.object.select_all(action='DESELECT')
    for m in meshes:
        m.select_set(True)
    bpy.context.view_layer.objects.active = meshes[0]
    bpy.ops.object.join()
    joined = bpy.context.object
    joined.name = MESH_NAME

    # 添加简单灰色材质
    mat = bpy.data.materials.new("HumanoidMat")
    mat.use_nodes = True
    bsdf = mat.node_tree.nodes.get("Principled BSDF")
    if bsdf:
        bsdf.inputs["Base Color"].default_value = (0.7, 0.7, 0.72, 1.0)
        bsdf.inputs["Roughness"].default_value = 0.8
    joined.data.materials.append(mat)

    # 父级到骨骼(使用已有顶点组)
    bpy.ops.object.select_all(action='DESELECT')
    joined.select_set(True)
    arm_obj.select_set(True)
    bpy.context.view_layer.objects.active = arm_obj
    bpy.ops.object.parent_set(type='ARMATURE')

    return joined

def set_bone_rot(pose_bones, name, rx, ry, rz):
    """设置骨骼欧拉旋转(度)"""
    if name in pose_bones:
        pose_bones[name].rotation_euler = Euler((deg2rad(rx), deg2rad(ry), deg2rad(rz)), 'XYZ')

def insert_rot_keyframes(arm_obj, frame):
    """为所有骨骼插入旋转关键帧"""
    for bone in arm_obj.pose.bones:
        bone.keyframe_insert(data_path="rotation_euler", frame=frame)

def reset_pose(arm_obj):
    """重置到静息姿态"""
    for bone in arm_obj.pose.bones:
        bone.rotation_euler = Euler((0, 0, 0), 'XYZ')
        bone.location = Vector((0, 0, 0))
        bone.scale = Vector((1, 1, 1))

def create_action(arm_obj, action_name, keyframe_func, duration_frames):
    """创建一个动画 Action"""
    # 创建新 Action
    action = bpy.data.actions.new(action_name)
    action.use_frame_range = True
    action.frame_start = 1
    action.frame_end = duration_frames

    # 分配给 armature
    if arm_obj.animation_data is None:
        arm_obj.animation_data_create()
    arm_obj.animation_data.action = action

    # 重置姿态
    reset_pose(arm_obj)
    pose_bones = arm_obj.pose.bones

    # 设置帧
    bpy.context.scene.frame_set(1)

    # 调用关键帧函数
    keyframe_func(pose_bones, arm_obj, duration_frames)

    return action

def push_to_nla(arm_obj, action, track_name):
    """将 Action 推入 NLA 轨道"""
    anim_data = arm_obj.animation_data
    track = anim_data.nla_tracks.new()
    track.name = track_name
    strip = track.strips.new(action.name, 0, action)
    # 清除当前 action
    anim_data.action = None

# ============================================================
# 动画关键帧函数
# ============================================================

def anim_idle(pose_bones, arm_obj, dur):
    """AT_Idle: 待机 - 呼吸、轻微重心变化"""
    f1 = 1
    f_mid1 = dur // 4
    f_mid2 = dur // 2
    f_mid3 = dur * 3 // 4
    f_end = dur

    # Frame 1: 静息
    reset_pose(arm_obj)
    set_bone_rot(pose_bones, "Spine", 0, 0, 0)
    set_bone_rot(pose_bones, "Head", 0, 0, 0)
    insert_rot_keyframes(arm_obj, f1)

    # Frame 25%: 吸气(胸腔微微扩展,头部微仰)
    set_bone_rot(pose_bones, "Chest", -1.5, 0, 0)
    set_bone_rot(pose_bones, "Head", -1.0, 0, 0.5)
    set_bone_rot(pose_bones, "LeftUpperArm", 0, 0, -1.0)
    set_bone_rot(pose_bones, "RightUpperArm", 0, 0, 1.0)
    insert_rot_keyframes(arm_obj, f_mid1)

    # Frame 50%: 静息
    reset_pose(arm_obj)
    insert_rot_keyframes(arm_obj, f_mid2)

    # Frame 75%: 吸气
    set_bone_rot(pose_bones, "Chest", -1.5, 0, 0)
    set_bone_rot(pose_bones, "Head", 1.0, 2.0, -0.5)
    set_bone_rot(pose_bones, "LeftUpperArm", 0, 0, -1.0)
    set_bone_rot(pose_bones, "RightUpperArm", 0, 0, 1.0)
    insert_rot_keyframes(arm_obj, f_mid3)

    # Frame end: 静息(循环)
    reset_pose(arm_obj)
    insert_rot_keyframes(arm_obj, f_end)

def anim_listening(pose_bones, arm_obj, dur):
    """AT_Listening: 倾听 - 身体轻微前倾,偶尔点头"""
    f1 = 1
    f2 = dur // 3
    f3 = dur * 2 // 3
    f_end = dur

    reset_pose(arm_obj)
    insert_rot_keyframes(arm_obj, f1)

    # 前倾
    set_bone_rot(pose_bones, "Spine", 3.0, 0, 0)
    set_bone_rot(pose_bones, "Head", -2.0, 0, 0)
    insert_rot_keyframes(arm_obj, f2)

    # 点头
    set_bone_rot(pose_bones, "Spine", 2.0, 0, 0)
    set_bone_rot(pose_bones, "Neck", 8.0, 0, 0)
    set_bone_rot(pose_bones, "Head", 5.0, 0, 0)
    insert_rot_keyframes(arm_obj, f3)

    # 回到前倾
    set_bone_rot(pose_bones, "Spine", 3.0, 0, 0)
    set_bone_rot(pose_bones, "Head", -2.0, 0, 0)
    set_bone_rot(pose_bones, "Neck", 0, 0, 0)
    insert_rot_keyframes(arm_obj, f_end)

def anim_thinking(pose_bones, arm_obj, dur):
    """AT_Thinking: 思考 - 歪头,右手靠近下巴"""
    f1 = 1
    f2 = dur // 3
    f3 = dur * 2 // 3
    f_end = dur

    reset_pose(arm_obj)
    insert_rot_keyframes(arm_obj, f1)

    # 歪头 + 抬右手
    set_bone_rot(pose_bones, "Head", -3.0, 0, -8.0)
    set_bone_rot(pose_bones, "RightUpperArm", -60.0, 0, 40.0)
    set_bone_rot(pose_bones, "RightLowerArm", 80.0, 0, 0)
    set_bone_rot(pose_bones, "RightShoulder", -10.0, 0, 0)
    insert_rot_keyframes(arm_obj, f2)

    # 保持,头部微动
    set_bone_rot(pose_bones, "Head", -5.0, 5.0, -8.0)
    set_bone_rot(pose_bones, "RightUpperArm", -55.0, 5.0, 40.0)
    set_bone_rot(pose_bones, "RightLowerArm", 75.0, 0, 0)
    insert_rot_keyframes(arm_obj, f3)

    # 回到歪头
    set_bone_rot(pose_bones, "Head", -3.0, 0, -8.0)
    set_bone_rot(pose_bones, "RightUpperArm", -60.0, 0, 40.0)
    set_bone_rot(pose_bones, "RightLowerArm", 80.0, 0, 0)
    insert_rot_keyframes(arm_obj, f_end)

def anim_speaking(pose_bones, arm_obj, dur):
    """AT_Speaking: 说话 - 手势,头部和上身轻微运动"""
    f1 = 1
    f2 = dur // 4
    f3 = dur // 2
    f4 = dur * 3 // 4
    f_end = dur

    reset_pose(arm_obj)
    insert_rot_keyframes(arm_obj, f1)

    # 右手手势
    set_bone_rot(pose_bones, "Spine", 0, 5.0, 0)
    set_bone_rot(pose_bones, "RightUpperArm", -20.0, 0, 25.0)
    set_bone_rot(pose_bones, "RightLowerArm", 30.0, 0, 0)
    set_bone_rot(pose_bones, "Head", 0, -3.0, 0)
    insert_rot_keyframes(arm_obj, f2)

    # 左手手势
    set_bone_rot(pose_bones, "Spine", 0, -5.0, 0)
    set_bone_rot(pose_bones, "LeftUpperArm", -20.0, 0, -25.0)
    set_bone_rot(pose_bones, "LeftLowerArm", 30.0, 0, 0)
    set_bone_rot(pose_bones, "RightUpperArm", 0, 0, 0)
    set_bone_rot(pose_bones, "RightLowerArm", 0, 0, 0)
    set_bone_rot(pose_bones, "Head", 0, 3.0, 0)
    insert_rot_keyframes(arm_obj, f3)

    # 右手手势
    set_bone_rot(pose_bones, "Spine", 0, 5.0, 0)
    set_bone_rot(pose_bones, "RightUpperArm", -25.0, 0, 30.0)
    set_bone_rot(pose_bones, "RightLowerArm", 40.0, 0, 0)
    set_bone_rot(pose_bones, "LeftUpperArm", 0, 0, 0)
    set_bone_rot(pose_bones, "LeftLowerArm", 0, 0, 0)
    set_bone_rot(pose_bones, "Head", 0, -3.0, 0)
    insert_rot_keyframes(arm_obj, f4)

    # 回到静息
    reset_pose(arm_obj)
    insert_rot_keyframes(arm_obj, f_end)

def anim_greeting(pose_bones, arm_obj, dur):
    """AT_Greeting: 问候 - 抬手或轻微鞠躬"""
    f1 = 1
    f2 = dur // 3
    f3 = dur * 2 // 3
    f_end = dur

    reset_pose(arm_obj)
    insert_rot_keyframes(arm_obj, f1)

    # 抬右手
    set_bone_rot(pose_bones, "RightUpperArm", -45.0, 0, 30.0)
    set_bone_rot(pose_bones, "RightLowerArm", 30.0, 0, 0)
    set_bone_rot(pose_bones, "RightShoulder", -5.0, 0, 0)
    set_bone_rot(pose_bones, "Head", -3.0, 5.0, 0)
    insert_rot_keyframes(arm_obj, f2)

    # 轻微鞠躬
    set_bone_rot(pose_bones, "Spine", 8.0, 0, 0)
    set_bone_rot(pose_bones, "RightUpperArm", -30.0, 0, 20.0)
    set_bone_rot(pose_bones, "RightLowerArm", 20.0, 0, 0)
    set_bone_rot(pose_bones, "Head", 5.0, 0, 0)
    insert_rot_keyframes(arm_obj, f3)

    # 回到静息
    reset_pose(arm_obj)
    insert_rot_keyframes(arm_obj, f_end)

def anim_wave(pose_bones, arm_obj, dur):
    """AT_Wave: 挥手"""
    f1 = 1
    f2 = dur // 4
    f3 = dur // 2
    f4 = dur * 3 // 4
    f_end = dur

    reset_pose(arm_obj)
    insert_rot_keyframes(arm_obj, f1)

    # 抬右手到挥手位置
    set_bone_rot(pose_bones, "RightUpperArm", -80.0, 0, 20.0)
    set_bone_rot(pose_bones, "RightLowerArm", 90.0, 0, 0)
    set_bone_rot(pose_bones, "RightShoulder", -10.0, 0, 0)
    insert_rot_keyframes(arm_obj, f2)

    # 手掌向外摆
    set_bone_rot(pose_bones, "RightLowerArm", 90.0, 0, -20.0)
    insert_rot_keyframes(arm_obj, f3)

    # 手掌向回摆
    set_bone_rot(pose_bones, "RightLowerArm", 90.0, 0, 20.0)
    insert_rot_keyframes(arm_obj, f4)

    # 放下
    reset_pose(arm_obj)
    insert_rot_keyframes(arm_obj, f_end)

def anim_nod(pose_bones, arm_obj, dur):
    """AT_Nod: 点头"""
    f1 = 1
    f2 = dur // 3
    f3 = dur * 2 // 3
    f_end = dur

    reset_pose(arm_obj)
    insert_rot_keyframes(arm_obj, f1)

    # 低头
    set_bone_rot(pose_bones, "Neck", 15.0, 0, 0)
    set_bone_rot(pose_bones, "Head", 10.0, 0, 0)
    insert_rot_keyframes(arm_obj, f2)

    # 抬头
    set_bone_rot(pose_bones, "Neck", -5.0, 0, 0)
    set_bone_rot(pose_bones, "Head", -3.0, 0, 0)
    insert_rot_keyframes(arm_obj, f3)

    # 回到静息
    reset_pose(arm_obj)
    insert_rot_keyframes(arm_obj, f_end)

def anim_shake_head(pose_bones, arm_obj, dur):
    """AT_ShakeHead: 摇头"""
    f1 = 1
    f2 = dur // 4
    f3 = dur // 2
    f4 = dur * 3 // 4
    f_end = dur

    reset_pose(arm_obj)
    insert_rot_keyframes(arm_obj, f1)

    # 向左
    set_bone_rot(pose_bones, "Head", 0, -15.0, 0)
    set_bone_rot(pose_bones, "Neck", 0, -8.0, 0)
    insert_rot_keyframes(arm_obj, f2)

    # 向右
    set_bone_rot(pose_bones, "Head", 0, 15.0, 0)
    set_bone_rot(pose_bones, "Neck", 0, 8.0, 0)
    insert_rot_keyframes(arm_obj, f3)

    # 向左
    set_bone_rot(pose_bones, "Head", 0, -10.0, 0)
    set_bone_rot(pose_bones, "Neck", 0, -5.0, 0)
    insert_rot_keyframes(arm_obj, f4)

    # 回到静息
    reset_pose(arm_obj)
    insert_rot_keyframes(arm_obj, f_end)

def anim_happy(pose_bones, arm_obj, dur):
    """AT_Happy: 开心 - 身体舒展,小幅张开手臂"""
    f1 = 1
    f2 = dur // 3
    f3 = dur * 2 // 3
    f_end = dur

    reset_pose(arm_obj)
    insert_rot_keyframes(arm_obj, f1)

    # 张开手臂,抬头
    set_bone_rot(pose_bones, "LeftUpperArm", 0, 0, -35.0)
    set_bone_rot(pose_bones, "RightUpperArm", 0, 0, 35.0)
    set_bone_rot(pose_bones, "LeftShoulder", -5.0, 0, -10.0)
    set_bone_rot(pose_bones, "RightShoulder", -5.0, 0, 10.0)
    set_bone_rot(pose_bones, "Head", -5.0, 0, 0)
    set_bone_rot(pose_bones, "Chest", -2.0, 0, 0)
    insert_rot_keyframes(arm_obj, f2)

    # 小跳(双腿微弯再伸直)
    set_bone_rot(pose_bones, "LeftUpperArm", 0, 0, -45.0)
    set_bone_rot(pose_bones, "RightUpperArm", 0, 0, 45.0)
    set_bone_rot(pose_bones, "Head", -8.0, 0, 0)
    insert_rot_keyframes(arm_obj, f3)

    # 回到静息
    reset_pose(arm_obj)
    insert_rot_keyframes(arm_obj, f_end)

def anim_confused(pose_bones, arm_obj, dur):
    """AT_Confused: 疑惑 - 头部倾斜,耸肩"""
    f1 = 1
    f2 = dur // 3
    f3 = dur * 2 // 3
    f_end = dur

    reset_pose(arm_obj)
    insert_rot_keyframes(arm_obj, f1)

    # 歪头 + 耸肩
    set_bone_rot(pose_bones, "Head", 0, 5.0, 12.0)
    set_bone_rot(pose_bones, "Neck", 0, 0, 5.0)
    set_bone_rot(pose_bones, "LeftShoulder", -15.0, 0, 0)
    set_bone_rot(pose_bones, "RightShoulder", -15.0, 0, 0)
    set_bone_rot(pose_bones, "LeftUpperArm", 5.0, 0, 5.0)
    set_bone_rot(pose_bones, "RightUpperArm", 5.0, 0, -5.0)
    insert_rot_keyframes(arm_obj, f2)

    # 保持,头部微动
    set_bone_rot(pose_bones, "Head", -3.0, -5.0, 12.0)
    insert_rot_keyframes(arm_obj, f3)

    # 回到静息
    reset_pose(arm_obj)
    insert_rot_keyframes(arm_obj, f_end)

def anim_sad(pose_bones, arm_obj, dur):
    """AT_Sad: 难过 - 低头,肩部下沉"""
    f1 = 1
    f2 = dur // 3
    f3 = dur * 2 // 3
    f_end = dur

    reset_pose(arm_obj)
    insert_rot_keyframes(arm_obj, f1)

    # 低头,肩部下沉(手臂内收)
    set_bone_rot(pose_bones, "Spine", 8.0, 0, 0)
    set_bone_rot(pose_bones, "Neck", 10.0, 0, 0)
    set_bone_rot(pose_bones, "Head", 15.0, 0, 0)
    set_bone_rot(pose_bones, "LeftUpperArm", 5.0, 0, 10.0)
    set_bone_rot(pose_bones, "RightUpperArm", 5.0, 0, -10.0)
    set_bone_rot(pose_bones, "LeftShoulder", 5.0, 0, 0)
    set_bone_rot(pose_bones, "RightShoulder", 5.0, 0, 0)
    insert_rot_keyframes(arm_obj, f2)

    # 保持
    set_bone_rot(pose_bones, "Head", 18.0, 3.0, 0)
    insert_rot_keyframes(arm_obj, f3)

    # 回到静息
    reset_pose(arm_obj)
    insert_rot_keyframes(arm_obj, f_end)

def anim_angry(pose_bones, arm_obj, dur):
    """AT_Angry: 生气 - 身体紧绷,叉腰"""
    f1 = 1
    f2 = dur // 3
    f3 = dur * 2 // 3
    f_end = dur

    reset_pose(arm_obj)
    insert_rot_keyframes(arm_obj, f1)

    # 叉腰
    set_bone_rot(pose_bones, "LeftUpperArm", 0, 0, 35.0)
    set_bone_rot(pose_bones, "RightUpperArm", 0, 0, -35.0)
    set_bone_rot(pose_bones, "LeftLowerArm", -60.0, 0, 0)
    set_bone_rot(pose_bones, "RightLowerArm", -60.0, 0, 0)
    set_bone_rot(pose_bones, "Head", -5.0, 0, 0)
    set_bone_rot(pose_bones, "Chest", -3.0, 0, 0)
    insert_rot_keyframes(arm_obj, f2)

    # 前倾
    set_bone_rot(pose_bones, "Spine", 5.0, 0, 0)
    set_bone_rot(pose_bones, "Head", -8.0, 0, 0)
    set_bone_rot(pose_bones, "LeftUpperArm", 5.0, 0, 35.0)
    set_bone_rot(pose_bones, "RightUpperArm", 5.0, 0, -35.0)
    insert_rot_keyframes(arm_obj, f3)

    # 回到静息
    reset_pose(arm_obj)
    insert_rot_keyframes(arm_obj, f_end)

def anim_touch_reaction(pose_bones, arm_obj, dur):
    """AT_TouchReaction: 触摸回应 - 轻微后缩再恢复"""
    f1 = 1
    f2 = dur // 2
    f_end = dur

    reset_pose(arm_obj)
    insert_rot_keyframes(arm_obj, f1)

    # 后缩
    set_bone_rot(pose_bones, "Spine", -4.0, 0, 0)
    set_bone_rot(pose_bones, "UpperChest", -3.0, 0, 0)
    set_bone_rot(pose_bones, "Head", -3.0, 0, 0)
    set_bone_rot(pose_bones, "LeftUpperArm", 0, 0, -8.0)
    set_bone_rot(pose_bones, "RightUpperArm", 0, 0, 8.0)
    insert_rot_keyframes(arm_obj, f2)

    # 恢复
    reset_pose(arm_obj)
    insert_rot_keyframes(arm_obj, f_end)

def anim_celebrate(pose_bones, arm_obj, dur):
    """AT_Celebrate: 庆祝 - 双手举起"""
    f1 = 1
    f2 = dur // 3
    f3 = dur * 2 // 3
    f_end = dur

    reset_pose(arm_obj)
    insert_rot_keyframes(arm_obj, f1)

    # 双手举起
    set_bone_rot(pose_bones, "LeftUpperArm", -85.0, 0, -15.0)
    set_bone_rot(pose_bones, "RightUpperArm", -85.0, 0, 15.0)
    set_bone_rot(pose_bones, "LeftLowerArm", 0, 0, 0)
    set_bone_rot(pose_bones, "RightLowerArm", 0, 0, 0)
    set_bone_rot(pose_bones, "LeftShoulder", -10.0, 0, -5.0)
    set_bone_rot(pose_bones, "RightShoulder", -10.0, 0, 5.0)
    set_bone_rot(pose_bones, "Head", -5.0, 0, 0)
    set_bone_rot(pose_bones, "Chest", -3.0, 0, 0)
    insert_rot_keyframes(arm_obj, f2)

    # 保持,微微挥动
    set_bone_rot(pose_bones, "LeftUpperArm", -80.0, 0, -25.0)
    set_bone_rot(pose_bones, "RightUpperArm", -80.0, 0, 25.0)
    insert_rot_keyframes(arm_obj, f3)

    # 回到静息
    reset_pose(arm_obj)
    insert_rot_keyframes(arm_obj, f_end)

def anim_apology(pose_bones, arm_obj, dur):
    """AT_Apology: 抱歉 - 轻微鞠躬或低头"""
    f1 = 1
    f2 = dur // 2
    f_end = dur

    reset_pose(arm_obj)
    insert_rot_keyframes(arm_obj, f1)

    # 鞠躬
    set_bone_rot(pose_bones, "Spine", 15.0, 0, 0)
    set_bone_rot(pose_bones, "Chest", 10.0, 0, 0)
    set_bone_rot(pose_bones, "Neck", 8.0, 0, 0)
    set_bone_rot(pose_bones, "Head", 10.0, 0, 0)
    set_bone_rot(pose_bones, "LeftUpperArm", 10.0, 0, 15.0)
    set_bone_rot(pose_bones, "RightUpperArm", 10.0, 0, -15.0)
    insert_rot_keyframes(arm_obj, f2)

    # 恢复
    reset_pose(arm_obj)
    insert_rot_keyframes(arm_obj, f_end)

# 动画函数映射
ANIM_FUNCS = {
    "AT_Idle": anim_idle,
    "AT_Listening": anim_listening,
    "AT_Thinking": anim_thinking,
    "AT_Speaking": anim_speaking,
    "AT_Greeting": anim_greeting,
    "AT_Wave": anim_wave,
    "AT_Nod": anim_nod,
    "AT_ShakeHead": anim_shake_head,
    "AT_Happy": anim_happy,
    "AT_Confused": anim_confused,
    "AT_Sad": anim_sad,
    "AT_Angry": anim_angry,
    "AT_TouchReaction": anim_touch_reaction,
    "AT_Celebrate": anim_celebrate,
    "AT_Apology": anim_apology,
}

# ============================================================
# 主流程
# ============================================================

def main():
    os.makedirs(OUTPUT_DIR, exist_ok=True)

    print(f"[ArkTavern] Output dir: {OUTPUT_DIR}")
    print(f"[ArkTavern] Blender version: {bpy.app.version_string}")

    # 1. 清空场景
    clear_scene()

    # 2. 创建骨骼
    arm_obj = create_armature()
    print(f"[ArkTavern] Armature created: {arm_obj.name}, bones: {len(arm_obj.data.bones)}")

    # 3. 创建网格
    mesh_obj = create_mesh(arm_obj)
    print(f"[ArkTavern] Mesh created: {mesh_obj.name}, vertices: {len(mesh_obj.data.vertices)}")

    # 4. 设置场景帧率
    bpy.context.scene.render.fps = FPS
    bpy.context.scene.frame_start = 1
    bpy.context.scene.frame_end = 100

    # 5. 创建所有动画
    action_metas = []
    for clip_name, display_name, duration_sec, loop in ACTIONS:
        dur_frames = max(2, int(duration_sec * FPS))
        func = ANIM_FUNCS[clip_name]
        action = create_action(arm_obj, clip_name, func, dur_frames)
        push_to_nla(arm_obj, action, clip_name)
        action_metas.append({
            "clipName": clip_name,
            "displayName": display_name,
            "durationMs": int(duration_sec * 1000),
            "loop": loop,
            "frameCount": dur_frames,
        })
        print(f"[ArkTavern] Action created: {clip_name} ({duration_sec}s, {dur_frames} frames, loop={loop})")

    # 6. 重置到静息姿态
    reset_pose(arm_obj)
    if arm_obj.animation_data:
        arm_obj.animation_data.action = None

    # 7. 保存 .blend 文件
    blend_path = os.path.join(OUTPUT_DIR, "preview_humanoid.blend")
    bpy.ops.wm.save_as_mainfile(filepath=blend_path)
    print(f"[ArkTavern] Blend saved: {blend_path}")

    # 8. 导出动作包 GLB(包含所有动画)
    glb_path = os.path.join(OUTPUT_DIR, "default_ai_action_pack.glb")
    bpy.ops.export_scene.gltf(
        filepath=glb_path,
        export_format='GLB',
        export_animations=True,
        export_animation_mode='ACTIONS',
        export_skins=True,
        export_morph=False,
        export_apply=False,
        export_yup=True,
    )
    print(f"[ArkTavern] Action pack GLB exported: {glb_path}")

    # 9. 导出预览模型 GLB(不含动画,仅静态模型)
    # 先移除所有 NLA tracks
    if arm_obj.animation_data:
        for track in list(arm_obj.animation_data.nla_tracks):
            arm_obj.animation_data.nla_tracks.remove(track)
        arm_obj.animation_data.action = None

    preview_glb_path = os.path.join(OUTPUT_DIR, "preview_humanoid.glb")
    bpy.ops.export_scene.gltf(
        filepath=preview_glb_path,
        export_format='GLB',
        export_animations=False,
        export_skins=True,
        export_morph=False,
        export_apply=False,
        export_yup=True,
    )
    print(f"[ArkTavern] Preview GLB exported: {preview_glb_path}")

    # 10. 生成 Manifest JSON
    manifest = {
        "version": "1.0.0",
        "skeletonProfile": "ArkTavern",
        "packFile": "default_ai_action_pack.glb",
        "previewModelFile": "preview_humanoid.glb",
        "actions": [],
    }

    slot_map = {
        "AT_Idle": "Idle",
        "AT_Listening": "Idle",
        "AT_Thinking": "Thinking",
        "AT_Speaking": "Speaking",
        "AT_Greeting": "Greeting",
        "AT_Wave": "Wave",
        "AT_Nod": "Nod",
        "AT_ShakeHead": "ShakeHead",
        "AT_Happy": "Happy",
        "AT_Confused": "Confused",
        "AT_Sad": "Sad",
        "AT_Angry": "Angry",
        "AT_TouchReaction": "TouchReaction",
        "AT_Celebrate": "Celebrate",
        "AT_Apology": "Custom01",
    }

    fallback_map = {
        "AT_Idle": None,
        "AT_Listening": "AT_Idle",
        "AT_Thinking": "AT_Idle",
        "AT_Speaking": "AT_Listening",
        "AT_Greeting": "AT_Idle",
        "AT_Wave": "AT_Idle",
        "AT_Nod": "AT_Idle",
        "AT_ShakeHead": "AT_Idle",
        "AT_Happy": "AT_Idle",
        "AT_Confused": "AT_Idle",
        "AT_Sad": "AT_Idle",
        "AT_Angry": "AT_Idle",
        "AT_TouchReaction": "AT_Idle",
        "AT_Celebrate": "AT_Idle",
        "AT_Apology": "AT_Idle",
    }

    category_map = {
        "AT_Idle": "base",
        "AT_Listening": "base",
        "AT_Thinking": "base",
        "AT_Speaking": "base",
        "AT_Greeting": "social",
        "AT_Wave": "social",
        "AT_Nod": "social",
        "AT_ShakeHead": "social",
        "AT_Happy": "emotion",
        "AT_Confused": "emotion",
        "AT_Sad": "emotion",
        "AT_Angry": "emotion",
        "AT_TouchReaction": "reaction",
        "AT_Celebrate": "reaction",
        "AT_Apology": "social",
    }

    required_bones = ["Hips", "Spine", "Chest", "UpperChest", "Neck", "Head",
                      "LeftShoulder", "LeftUpperArm", "LeftLowerArm", "LeftHand",
                      "RightShoulder", "RightUpperArm", "RightLowerArm", "RightHand",
                      "LeftUpperLeg", "LeftLowerLeg", "LeftFoot",
                      "RightUpperLeg", "RightLowerLeg", "RightFoot"]

    for i, (clip_name, display_name, duration_sec, loop) in enumerate(ACTIONS):
        manifest["actions"].append({
            "id": clip_name.lower().replace("at_", "builtin_"),
            "slot": slot_map[clip_name],
            "clipName": clip_name,
            "defaultDisplayName": display_name,
            "durationMs": int(duration_sec * 1000),
            "loop": loop,
            "sortOrder": i,
            "thumbnailPath": f"thumbnails/{clip_name.lower()}.webp",
            "category": category_map[clip_name],
            "builtIn": True,
            "requiredBones": required_bones,
            "fallbackSlot": fallback_map[clip_name],
        })

    manifest_path = os.path.join(OUTPUT_DIR, "default_ai_action_pack.json")
    with open(manifest_path, "w", encoding="utf-8") as f:
        json.dump(manifest, f, ensure_ascii=False, indent=2)
    print(f"[ArkTavern] Manifest written: {manifest_path}")

    # 11. 生成报告
    report = f"""# ArkTavern 默认 AI 动作包生成报告

## 生成信息

- **生成时间**: 2026-07-23
- **Blender 版本**: {bpy.app.version_string}
- **骨骼名称**: ArkTavernHumanoidV1
- **骨骼数量**: {len(arm_obj.data.bones)}
- **网格顶点数**: {len(mesh_obj.data.vertices)}
- **动作数量**: {len(ACTIONS)}
- **帧率**: {FPS} FPS

## 动作列表

| Clip 名称 | 显示名 | 时长(ms) | 循环 | 帧数 |
|-----------|--------|----------|------|------|
"""
    for clip_name, display_name, duration_sec, loop in ACTIONS:
        dur_frames = max(2, int(duration_sec * FPS))
        report += f"| {clip_name} | {display_name} | {int(duration_sec*1000)} | {'是' if loop else '否'} | {dur_frames} |\n"

    report += f"""
## 输出文件

- `preview_humanoid.blend` - Blender 源文件
- `default_ai_action_pack.glb` - 动作包 GLB(含 15 个动画)
- `preview_humanoid.glb` - 预览模型 GLB(静态,无动画)
- `default_ai_action_pack.json` - 动作清单

## 授权

该动作包由 ArkTavern 项目脚本生成,不包含第三方角色或动作资产。
骨骼结构和动画关键帧均为原创,可随应用自由分发。

## 骨骼结构

```
Hips (根骨骼)
├── Spine
│   └── Chest
│       └── UpperChest
│           ├── Neck → Head
│           ├── LeftShoulder → LeftUpperArm → LeftLowerArm → LeftHand
│           └── RightShoulder → RightUpperArm → RightLowerArm → RightHand
├── LeftUpperLeg → LeftLowerLeg → LeftFoot → LeftToes
└── RightUpperLeg → RightLowerLeg → RightFoot → RightToes
```
"""
    report_path = os.path.join(OUTPUT_DIR, "generation_report.md")
    with open(report_path, "w", encoding="utf-8") as f:
        f.write(report)
    print(f"[ArkTavern] Report written: {report_path}")

    # 12. 输出文件大小
    for fname in ["preview_humanoid.blend", "default_ai_action_pack.glb", "preview_humanoid.glb", "default_ai_action_pack.json"]:
        fpath = os.path.join(OUTPUT_DIR, fname)
        if os.path.exists(fpath):
            size = os.path.getsize(fpath)
            print(f"[ArkTavern] {fname}: {size} bytes ({size/1024:.1f} KB)")

    print("[ArkTavern] Done!")

if __name__ == "__main__":
    main()
