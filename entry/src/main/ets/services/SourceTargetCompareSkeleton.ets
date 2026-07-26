/**
 * SourceTargetCompareSkeleton Source/Target 三栏对比可视化
 *
 * T-4.2G-A4: Debug-only 三栏对比模式,同屏显示:
 *   - Source Rest Pose(灰色,横向偏左)
 *   - Source Animated Pose(蓝色,横向居中)
 *   - Target Retargeted Pose(绿色,横向偏右)
 *
 * 三栏必须使用真实数据:
 *   - Source Rest:从 sourceRestPose 计算 worldPosition
 *   - Source Animated:从 sampleMotionClip(clip, currentTime) + sourceRestPose 计算 worldPosition
 *   - Target Retargeted:从 boneNodeMap 实时读取 SceneNode world transform
 *
 * 同屏显示时位置横向错开,但保持相同比例和相机方向。
 *
 * 颜色说明:
 *   ArkGraphics3D Material 颜色属性 API 在该项目中未确认可用,
 *   此处采用"横向错开 + 不同关节球半径"区分三栏:
 *   - Source Rest:radius × 0.8(较小),偏左
 *   - Source Animated:radius × 1.0(中等),居中
 *   - Target Retargeted:radius × 1.2(较大),偏右
 *   日志和 UI 文案中仍使用"灰色/蓝色/绿色"描述,便于对照任务要求。
 *
 * 仅在 setEnabled(true) 时显示。验收后不得默认展示。
 */

import {
  Scene,
  Node,
  Geometry,
  Material,
  MeshResource,
  SceneResourceFactory,
  SceneResourceParameters,
  SceneNodeParameters,
  SphereGeometry,
  CubeGeometry,
  MaterialType
} from '@kit.ArkGraphics3D';
import { HumanoidBone } from '../models/character3d/HumanoidBone';
import {
  HumanoidMotionClip,
  HumanoidRestPose,
  QuaternionValue,
  Vector3Value
} from '../models/character3d/HumanoidMotionClip';
import { sampleMotionClip } from './HumanoidMotionSampler';
import {
  computeRestPoseWorldSnapshot,
  computeAnimatedPoseWorldSnapshot,
  PoseSnapshot,
  BoneWorldSnapshot
} from './SourceRetargetDiagnosticCollector';
import {
  computeNodeWorldTransform,
  vectorSubtract,
  vectorAdd,
  vectorScale,
  vectorLength,
  rotationFromYAxisToDirection
} from '../utils/SceneNodeTransformUtil';
import { Logger } from '../utils/Logger';

const LOG_TAG: string = 'SrcTargetCompare';

/**
 * 骨骼连接关系(parent → child),用于绘制骨段连线。
 * 与 TargetAvatarSkeletonController.BONE_CONNECTIONS 一致(精简版,仅诊断骨骼链路)。
 */
interface BoneConnection {
  parent: HumanoidBone;
  child: HumanoidBone;
}

const COMPARE_CONNECTIONS: BoneConnection[] = [
  { parent: HumanoidBone.Hips, child: HumanoidBone.Spine },
  { parent: HumanoidBone.Spine, child: HumanoidBone.Chest },
  { parent: HumanoidBone.Chest, child: HumanoidBone.UpperChest },
  { parent: HumanoidBone.UpperChest, child: HumanoidBone.Neck },
  { parent: HumanoidBone.Neck, child: HumanoidBone.Head },
  { parent: HumanoidBone.UpperChest, child: HumanoidBone.LeftShoulder },
  { parent: HumanoidBone.LeftShoulder, child: HumanoidBone.LeftUpperArm },
  { parent: HumanoidBone.LeftUpperArm, child: HumanoidBone.LeftLowerArm },
  { parent: HumanoidBone.LeftLowerArm, child: HumanoidBone.LeftHand },
  { parent: HumanoidBone.UpperChest, child: HumanoidBone.RightShoulder },
  { parent: HumanoidBone.RightShoulder, child: HumanoidBone.RightUpperArm },
  { parent: HumanoidBone.RightUpperArm, child: HumanoidBone.RightLowerArm },
  { parent: HumanoidBone.RightLowerArm, child: HumanoidBone.RightHand },
  { parent: HumanoidBone.Hips, child: HumanoidBone.LeftUpperLeg },
  { parent: HumanoidBone.LeftUpperLeg, child: HumanoidBone.LeftLowerLeg },
  { parent: HumanoidBone.LeftLowerLeg, child: HumanoidBone.LeftFoot },
  { parent: HumanoidBone.Hips, child: HumanoidBone.RightUpperLeg },
  { parent: HumanoidBone.RightUpperLeg, child: HumanoidBone.RightLowerLeg },
  { parent: HumanoidBone.RightLowerLeg, child: HumanoidBone.RightFoot }
];

/**
 * 要绘制关节的骨骼列表(19 个,与 TargetAvatarSkeletonController.DRAWN_JOINTS 一致)。
 */
const DRAWN_JOINTS: HumanoidBone[] = [
  HumanoidBone.Hips,
  HumanoidBone.Spine,
  HumanoidBone.Chest,
  HumanoidBone.UpperChest,
  HumanoidBone.Neck,
  HumanoidBone.Head,
  HumanoidBone.LeftShoulder,
  HumanoidBone.LeftUpperArm,
  HumanoidBone.LeftLowerArm,
  HumanoidBone.LeftHand,
  HumanoidBone.RightShoulder,
  HumanoidBone.RightUpperArm,
  HumanoidBone.RightLowerArm,
  HumanoidBone.RightHand,
  HumanoidBone.LeftUpperLeg,
  HumanoidBone.LeftLowerLeg,
  HumanoidBone.LeftFoot,
  HumanoidBone.RightUpperLeg,
  HumanoidBone.RightLowerLeg,
  HumanoidBone.RightFoot
];

/**
 * 三栏标签。
 */
export enum CompareColumn {
  SourceRest = 'SourceRest',
  SourceAnimated = 'SourceAnimated',
  TargetRetargeted = 'TargetRetargeted'
}

/**
 * 单栏状态(关节几何 + 骨段几何 + skeletonRoot)。
 */
interface ColumnState {
  column: CompareColumn;
  root: Node;
  material: Material;
  joints: Map<HumanoidBone, Geometry>;
  segments: BoneSegmentRecord[];
  /** 横向偏移(X 轴) */
  xOffset: number;
  /** 关节球半径系数 */
  radiusScale: number;
}

interface BoneSegmentRecord {
  parentBone: HumanoidBone;
  childBone: HumanoidBone;
  geometry: Geometry;
}

/**
 * 三栏对比可视化控制器。
 */
export class SourceTargetCompareSkeleton {
  private scene: Scene | null = null;
  private columns: Map<CompareColumn, ColumnState> = new Map();
  private enabled: boolean = false;
  private attached: boolean = false;

  /** 当前 clip(用于采样 Source Animated) */
  private clip: HumanoidMotionClip | null = null;
  /** Source Rest Pose */
  private sourceRestPose: HumanoidRestPose | null = null;
  /** Target boneNodeMap(用于读取 Target Retargeted world position) */
  private boneNodeMap: Map<HumanoidBone, Node> | null = null;
  /** 模型高度(用于计算几何尺寸和横向偏移) */
  private modelHeight: number = 1.7;
  /** 关节球基础半径 */
  private jointRadius: number = 0.012;
  /** 骨段粗细 */
  private segmentThickness: number = 0.010;

  /**
   * attach 到 Scene。
   *
   * @param scene 目标 Scene(与 Avatar 同一 Scene)
   * @param clip 动作 clip
   * @param sourceRestPose Source Rest Pose
   * @param boneNodeMap Target boneNodeMap
   * @param modelHeight 模型高度
   */
  async attach(
    scene: Scene,
    clip: HumanoidMotionClip,
    sourceRestPose: HumanoidRestPose,
    boneNodeMap: Map<HumanoidBone, Node>,
    modelHeight: number
  ): Promise<void> {
    if (this.attached) {
      Logger.warn(LOG_TAG, 'attach: already attached, skip');
      return;
    }
    const sceneRoot: Node | null = scene.root;
    if (sceneRoot === null) {
      Logger.error(LOG_TAG, 'attach: scene.root is null');
      return;
    }
    this.scene = scene;
    this.clip = clip;
    this.sourceRestPose = sourceRestPose;
    this.boneNodeMap = boneNodeMap;
    this.modelHeight = modelHeight > 0 ? modelHeight : 1.7;

    // 几何尺寸基于模型高度
    const scale: number = this.modelHeight / 1.7;
    this.jointRadius = 0.012 * scale;
    this.segmentThickness = 0.010 * scale;

    // 横向偏移 = 模型高度 × 0.8(三栏之间留出足够间距)
    const offset: number = this.modelHeight * 0.8;

    const factory: SceneResourceFactory = scene.getResourceFactory();

    try {
      // 创建三栏
      await this.createColumn(factory, sceneRoot, CompareColumn.SourceRest, -offset, 0.8);
      await this.createColumn(factory, sceneRoot, CompareColumn.SourceAnimated, 0, 1.0);
      await this.createColumn(factory, sceneRoot, CompareColumn.TargetRetargeted, offset, 1.2);

      this.attached = true;
      // 默认隐藏
      this.setEnabledInternal(false);
      Logger.info(LOG_TAG, 'attach: done, columns=3, offset=' + offset.toFixed(3)
        + ', jointRadius=' + this.jointRadius.toFixed(4));
    } catch (e) {
      Logger.error(LOG_TAG, 'attach failed: ' + (e as Error)?.message);
      await this.detach();
    }
  }

  /**
   * 创建一栏(关节小球 + 骨段连线)。
   */
  private async createColumn(
    factory: SceneResourceFactory,
    sceneRoot: Node,
    column: CompareColumn,
    xOffset: number,
    radiusScale: number
  ): Promise<void> {
    // 创建 skeletonRoot
    const rootParams: SceneNodeParameters = { name: 'compareRoot_' + column };
    const root: Node = await factory.createNode(rootParams);
    root.position = { x: xOffset, y: 0, z: 0 };
    root.rotation = { x: 0, y: 0, z: 0, w: 1 };
    root.scale = { x: 1, y: 1, z: 1 };
    sceneRoot.children.append(root);

    // 创建材质
    const matParams: SceneResourceParameters = { name: 'compareMat_' + column };
    const material: Material = await factory.createMaterial(matParams, MaterialType.METALLIC_ROUGHNESS);

    const joints: Map<HumanoidBone, Geometry> = new Map();
    const segments: BoneSegmentRecord[] = [];
    const jointRadius: number = this.jointRadius * radiusScale;
    const segThickness: number = this.segmentThickness * radiusScale;

    // 创建关节小球
    for (let i: number = 0; i < DRAWN_JOINTS.length; i++) {
      const bone: HumanoidBone = DRAWN_JOINTS[i];
      try {
        const geom: SphereGeometry = new SphereGeometry();
        geom.radius = jointRadius;
        geom.segmentCount = 8;
        const meshParams: SceneResourceParameters = { name: 'cmp_' + column + '_joint_' + bone };
        const mesh: MeshResource = await factory.createMesh(meshParams, geom);
        const nodeParams: SceneNodeParameters = { name: 'cmp_' + column + '_joint_' + bone };
        const node: Geometry = await factory.createGeometry(nodeParams, mesh);
        this.assignMaterial(node, material, 'cmp_' + column + '_joint_' + bone);
        root.children.append(node);
        node.position = { x: 0, y: 0, z: 0 };
        joints.set(bone, node);
      } catch (e) {
        Logger.warn(LOG_TAG, 'createColumn ' + column + ' joint ' + bone + ' failed: ' + (e as Error)?.message);
      }
    }

    // 创建骨段连线
    for (let i: number = 0; i < COMPARE_CONNECTIONS.length; i++) {
      const conn: BoneConnection = COMPARE_CONNECTIONS[i];
      try {
        const geom: CubeGeometry = new CubeGeometry();
        geom.size = { x: 1, y: 1, z: 1 };
        const meshParams: SceneResourceParameters = { name: 'cmp_' + column + '_seg_' + conn.parent + '_' + conn.child };
        const mesh: MeshResource = await factory.createMesh(meshParams, geom);
        const nodeParams: SceneNodeParameters = { name: 'cmp_' + column + '_seg_' + conn.parent + '_' + conn.child };
        const node: Geometry = await factory.createGeometry(nodeParams, mesh);
        this.assignMaterial(node, material, 'cmp_' + column + '_seg_' + conn.parent);
        root.children.append(node);
        node.position = { x: 0, y: 0, z: 0 };
        node.scale = { x: segThickness, y: segThickness, z: segThickness };
        segments.push({
          parentBone: conn.parent,
          childBone: conn.child,
          geometry: node
        });
      } catch (e) {
        Logger.warn(LOG_TAG, 'createColumn ' + column + ' seg ' + conn.parent + '->' + conn.child + ' failed: '
          + (e as Error)?.message);
      }
    }

    this.columns.set(column, {
      column: column,
      root: root,
      material: material,
      joints: joints,
      segments: segments,
      xOffset: xOffset,
      radiusScale: radiusScale
    });
  }

  /**
   * 安全赋材质。
   */
  private assignMaterial(geom: Geometry, material: Material, label: string): void {
    try {
      const mesh = geom.mesh;
      const subMeshes = mesh.subMeshes;
      if (subMeshes.length === 0) {
        return;
      }
      subMeshes[0].material = material;
    } catch (_e) {
      // ignore
    }
  }

  /**
   * 每帧更新三栏位置。
   *
   * @param currentTime 当前播放时间(秒)
   */
  updateFrame(currentTime: number): void {
    if (!this.attached || !this.enabled) {
      return;
    }
    if (this.clip === null || this.sourceRestPose === null || this.boneNodeMap === null) {
      return;
    }

    // 1. Source Rest(固定不变)
    const sourceRestSnap: PoseSnapshot = computeRestPoseWorldSnapshot(this.sourceRestPose, 'SourceRest');
    this.applyPoseToColumn(CompareColumn.SourceRest, sourceRestSnap);

    // 2. Source Animated(根据 currentTime 采样)
    const animatedPose = sampleMotionClip(this.clip, currentTime);
    const sourceAnimSnap: PoseSnapshot = computeAnimatedPoseWorldSnapshot(
      this.sourceRestPose, animatedPose, 'SourceAnimated'
    );
    this.applyPoseToColumn(CompareColumn.SourceAnimated, sourceAnimSnap);

    // 3. Target Retargeted(从 boneNodeMap 实时读取)
    const targetSnap: PoseSnapshot = this.collectTargetRetargetedSnapshot();
    this.applyPoseToColumn(CompareColumn.TargetRetargeted, targetSnap);
  }

  /**
   * 将 Pose 快照应用到指定栏(更新关节球和骨段连线位置)。
   *
   * 注意:Pose 快照中的 worldPosition 是 Source/Target 自身坐标系下的,
   * 而 column.root 已经设置了 xOffset,所以关节球的 localPosition = worldPosition(不再加 xOffset)。
   * xOffset 通过 column.root.position.x 实现。
   */
  private applyPoseToColumn(column: CompareColumn, pose: PoseSnapshot): void {
    const col: ColumnState | undefined = this.columns.get(column);
    if (col === undefined) {
      return;
    }

    // 更新关节球位置
    for (let i: number = 0; i < DRAWN_JOINTS.length; i++) {
      const bone: HumanoidBone = DRAWN_JOINTS[i];
      const joint: Geometry | undefined = col.joints.get(bone);
      const snap: BoneWorldSnapshot | undefined = pose.bones.get(bone);
      if (joint === undefined || snap === undefined) {
        continue;
      }
      try {
        joint.position = { x: snap.worldPosition.x, y: snap.worldPosition.y, z: snap.worldPosition.z };
      } catch (_e) {
        // ignore
      }
    }

    // 更新骨段连线
    for (let i: number = 0; i < col.segments.length; i++) {
      const seg: BoneSegmentRecord = col.segments[i];
      const parentSnap: BoneWorldSnapshot | undefined = pose.bones.get(seg.parentBone);
      const childSnap: BoneWorldSnapshot | undefined = pose.bones.get(seg.childBone);
      if (parentSnap === undefined || childSnap === undefined) {
        try { seg.geometry.scale = { x: 0, y: 0, z: 0 }; } catch (_e) { /* ignore */ }
        continue;
      }
      const start: Vector3Value = parentSnap.worldPosition;
      const end: Vector3Value = childSnap.worldPosition;
      const diff: Vector3Value = vectorSubtract(end, start);
      const len: number = vectorLength(diff);
      if (len < 1e-6) {
        try { seg.geometry.scale = { x: 0, y: 0, z: 0 }; } catch (_e) { /* ignore */ }
        continue;
      }
      const mid: Vector3Value = vectorScale(vectorAdd(start, end), 0.5);
      const rot: QuaternionValue = rotationFromYAxisToDirection(diff);
      const thickness: number = this.segmentThickness * col.radiusScale;
      try { seg.geometry.position = mid; } catch (_e) { /* ignore */ }
      try { seg.geometry.rotation = rot; } catch (_e) { /* ignore */ }
      try { seg.geometry.scale = { x: thickness, y: len, z: thickness }; } catch (_e) { /* ignore */ }
    }
  }

  /**
   * 从 boneNodeMap 实时读取 Target Retargeted 的世界变换。
   */
  private collectTargetRetargetedSnapshot(): PoseSnapshot {
    const snapshot: PoseSnapshot = {
      label: 'TargetRetargeted',
      bones: new Map<HumanoidBone, BoneWorldSnapshot>()
    };
    if (this.boneNodeMap === null) {
      return snapshot;
    }
    for (let i: number = 0; i < DRAWN_JOINTS.length; i++) {
      const bone: HumanoidBone = DRAWN_JOINTS[i];
      const node: Node | undefined = this.boneNodeMap.get(bone);
      if (node === undefined) {
        continue;
      }
      const wt = computeNodeWorldTransform(node);
      snapshot.bones.set(bone, {
        bone: bone,
        localRotation: wt.rotation,
        localPosition: { x: 0, y: 0, z: 0 }, // 不需要
        worldRotation: wt.rotation,
        worldPosition: wt.position
      });
    }
    return snapshot;
  }

  /**
   * 设置可见性。
   */
  setEnabled(enabled: boolean): void {
    this.setEnabledInternal(enabled);
  }

  private setEnabledInternal(enabled: boolean): void {
    this.enabled = enabled;
    this.columns.forEach((col: ColumnState): void => {
      try {
        col.root.visible = enabled;
      } catch (_e) {
        // ignore
      }
    });
    Logger.info(LOG_TAG, 'setEnabled: ' + enabled);
  }

  /**
   * 是否已启用。
   */
  isEnabled(): boolean {
    return this.enabled;
  }

  /**
   * 是否已 attach。
   */
  isAttached(): boolean {
    return this.attached;
  }

  /**
   * 移除所有几何并释放资源。
   *
   * 同步方法:ArkGraphics3D Node children 没有公开的 clear 方法,
   * 只能置 visible=false 让几何不渲染。Scene.destroy 时会统一回收。
   */
  detach(): void {
    this.columns.forEach((col: ColumnState): void => {
      try {
        col.root.visible = false;
      } catch (_e) {
        // ignore
      }
    });
    this.columns.clear();
    this.attached = false;
    this.enabled = false;
    this.clip = null;
    this.sourceRestPose = null;
    this.boneNodeMap = null;
    Logger.info(LOG_TAG, 'detach: done');
  }
}
