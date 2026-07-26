/**
 * TargetAvatarSkeletonController 目标骨架可视化控制器
 *
 * T-4.2G-A2: 在与 Avatar 相同的 3D Scene 中绘制骨架调试层。
 *
 * 职责:
 * 1. attach:创建 skeletonRoot Node、关节小球(SphereGeometry)、骨段连线(CubeGeometry)
 *    挂到 sceneRoot 下,与 Avatar 共用相机、模型根节点和帧刷新
 * 2. updateFrame:每帧 retarget 后调用,从 boneNodeMap 读取 Node 实时 World Transform,
 *    更新关节小球 position 与骨段连线的 position/rotation/scale
 * 3. restoreRestPose:停止动画后,使用 Target Rest Pose 重新计算 World Position,
 *    使骨架与模型同步恢复 Rest Pose
 * 4. setVisible:切换骨架几何可见性(不删除几何)
 * 5. detach:移除骨架几何并释放资源
 *
 * 设计要点:
 * - 骨架几何节点不挂在 boneNodeMap 的骨骼节点下(避免被骨骼 scale 影响)
 * - 关节小球挂在 skeletonRoot 下,每帧用 World Position 更新
 * - 骨段连线两端根据 Parent/Child 关系的 World Position 计算
 * - 与 Avatar 模型共用同一个 scene、camera、light,渲染层级一致
 *
 * 数据源:
 * - boneNodeMap:Map<HumanoidBone, Node>,Node 来自 ArkGraphics3D
 * - 通过 SceneNodeTransformUtil.computeNodeWorldTransform 计算实时 World Transform
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
  HumanoidRestPose,
  Vector3Value,
  QuaternionValue
} from '../models/character3d/HumanoidMotionClip';
import { Logger } from '../utils/Logger';
import {
  computeNodeWorldTransform,
  WorldTransform,
  vectorSubtract,
  vectorAdd,
  vectorScale,
  vectorLength,
  rotationFromYAxisToDirection
} from '../utils/SceneNodeTransformUtil';

const LOG_TAG: string = 'TargetAvatarSkeleton';

/**
 * 骨骼连接关系(parent → child),用于绘制骨段连线。
 * 与 HumanoidBone 标准层级一致。
 */
interface BoneConnection {
  parent: HumanoidBone;
  child: HumanoidBone;
}

/**
 * 关节小球记录。
 */
interface JointRecord {
  bone: HumanoidBone;
  geometry: Geometry;
}

/**
 * 骨段连线记录。
 */
interface BoneSegmentRecord {
  parentBone: HumanoidBone;
  childBone: HumanoidBone;
  geometry: Geometry;
}

/**
 * 骨架几何尺寸常量(基于模型 bounds 动态调整)。
 */
interface SkeletonStyle {
  /** 关节小球半径 */
  jointRadius: number;
  /** 骨段截面边长(方形) */
  segmentThickness: number;
}

/** 默认骨架几何尺寸(模型 bounds 未知时使用) */
const DEFAULT_JOINT_RADIUS: number = 0.015;
const DEFAULT_SEGMENT_THICKNESS: number = 0.012;

/**
 * 标准骨骼连接列表(用于绘制骨段连线)。
 *
 * 层级:
 * Hips → Spine → Chest → UpperChest → Neck → Head
 * Hips → LeftUpperLeg → LeftLowerLeg → LeftFoot
 * Hips → RightUpperLeg → RightLowerLeg → RightFoot
 * UpperChest → LeftShoulder → LeftUpperArm → LeftLowerArm → LeftHand
 * UpperChest → RightShoulder → RightUpperArm → RightLowerArm → RightHand
 */
const BONE_CONNECTIONS: BoneConnection[] = [
  { parent: HumanoidBone.Hips, child: HumanoidBone.Spine },
  { parent: HumanoidBone.Spine, child: HumanoidBone.Chest },
  { parent: HumanoidBone.Chest, child: HumanoidBone.UpperChest },
  { parent: HumanoidBone.UpperChest, child: HumanoidBone.Neck },
  { parent: HumanoidBone.Neck, child: HumanoidBone.Head },

  // 左臂
  { parent: HumanoidBone.UpperChest, child: HumanoidBone.LeftShoulder },
  { parent: HumanoidBone.LeftShoulder, child: HumanoidBone.LeftUpperArm },
  { parent: HumanoidBone.LeftUpperArm, child: HumanoidBone.LeftLowerArm },
  { parent: HumanoidBone.LeftLowerArm, child: HumanoidBone.LeftHand },

  // 右臂
  { parent: HumanoidBone.UpperChest, child: HumanoidBone.RightShoulder },
  { parent: HumanoidBone.RightShoulder, child: HumanoidBone.RightUpperArm },
  { parent: HumanoidBone.RightUpperArm, child: HumanoidBone.RightLowerArm },
  { parent: HumanoidBone.RightLowerArm, child: HumanoidBone.RightHand },

  // 左腿
  { parent: HumanoidBone.Hips, child: HumanoidBone.LeftUpperLeg },
  { parent: HumanoidBone.LeftUpperLeg, child: HumanoidBone.LeftLowerLeg },
  { parent: HumanoidBone.LeftLowerLeg, child: HumanoidBone.LeftFoot },

  // 右腿
  { parent: HumanoidBone.Hips, child: HumanoidBone.RightUpperLeg },
  { parent: HumanoidBone.RightUpperLeg, child: HumanoidBone.RightLowerLeg },
  { parent: HumanoidBone.RightLowerLeg, child: HumanoidBone.RightFoot }
];

/**
 * 要绘制关节的关键骨骼列表(19 个)。
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
 * T-4.2G-A3: 诊断关键骨骼列表(6 个,左右 Shoulder/Elbow/Hand)。
 *
 * 仅这 6 个骨骼会输出三组坐标对齐诊断日志,并创建 Debug 红绿点几何。
 * 减少日志噪音,聚焦最易暴露对齐问题的关节。
 */
const DIAGNOSTIC_JOINTS: HumanoidBone[] = [
  HumanoidBone.LeftShoulder,
  HumanoidBone.LeftLowerArm,
  HumanoidBone.LeftHand,
  HumanoidBone.RightShoulder,
  HumanoidBone.RightLowerArm,
  HumanoidBone.RightHand
];

/**
 * T-4.2G-A3: 诊断点几何记录。
 *
 * - redSphere: 红色球,位置 = avatarBoneWorld(从 boneNodeMap 计算)
 * - greenSphere: 绿色球,位置 = jointNode 的最终 World Position
 *   (由于 jointNode 挂在 skeletonRoot 下,skeletonRoot World Transform 决定 jointLocal→jointWorld 的映射)
 * - errorLine: 黄色线段,连接 redSphere 和 greenSphere,长度 = error
 *
 * 仅在 setDebugMode(true) 时可见。
 */
interface DiagnosticJoint {
  bone: HumanoidBone;
  redSphere: Geometry;
  greenSphere: Geometry;
  errorLine: Geometry;
}

/**
 * 骨架控制器状态。
 */
export class TargetAvatarSkeletonController {
  /** 已创建的关节几何列表 */
  private joints: JointRecord[] = [];
  /** 已创建的骨段几何列表 */
  private segments: BoneSegmentRecord[] = [];
  /** skeletonRoot 节点(挂在 sceneRoot 下) */
  private skeletonRoot: Node | null = null;
  /** 骨架几何共享材质 */
  private skeletonMaterial: Material | null = null;
  /** 当前可见性 */
  private visible: boolean = true;
  /** 是否已 attach */
  private attached: boolean = false;
  /** boneNodeMap 引用(attach 时记录,updateFrame 时使用) */
  private boneNodeMap: Map<HumanoidBone, Node> | null = null;
  /** Target Rest Pose 引用(restoreRestPose 时使用) */
  private targetRestPose: HumanoidRestPose | null = null;
  /** 骨架几何尺寸 */
  private style: SkeletonStyle = {
    jointRadius: DEFAULT_JOINT_RADIUS,
    segmentThickness: DEFAULT_SEGMENT_THICKNESS
  };
  /** T-4.2G-A2: 帧计数器(用于每 30 帧采样诊断) */
  private frameCounter: number = 0;
  /** T-4.2G-A2: 缺失骨骼是否已输出过日志(避免重复) */
  private missingBonesLogged: boolean = false;

  // ========== T-4.2G-A3: 坐标对齐诊断 ==========
  /** Debug 红绿点几何列表(6 个关键骨骼) */
  private diagnosticJoints: DiagnosticJoint[] = [];
  /** 红色球材质(avatarBoneWorld) */
  private redMaterial: Material | null = null;
  /** 绿色球材质(jointWorld) */
  private greenMaterial: Material | null = null;
  /** 黄色线段材质(error line) */
  private yellowMaterial: Material | null = null;
  /** Debug 可视化是否启用 */
  private debugMode: boolean = false;
  /** 上一次诊断输出的帧号(避免连续触发) */
  private lastDiagnosticFrame: number = -1;
  /** 诊断球半径(基于 modelHeight 动态计算) */
  private diagnosticSphereRadius: number = 0.012;

  /**
   * 将骨架挂载到 Scene。
   *
   * 步骤:
   * 1. 创建 skeletonRoot Node,挂到 sceneRoot
   * 2. 创建共享材质(METALLIC_ROUGHNESS,默认色)
   * 3. 为每个 DRAWN_JOINTS 创建 SphereGeometry 关节小球
   * 4. 为每个 BONE_CONNECTIONS 创建 CubeGeometry 骨段连线
   * 5. 初始化位置(基于 Rest Pose 计算 World Position)
   *
   * @param scene 目标 Scene(与 Avatar 同一 Scene)
   * @param boneNodeMap Avatar 的 bone → Node 映射
   * @param targetRestPose Target Rest Pose(用于初始化骨架位置)
   * @param modelHeight 模型高度(用于动态调整骨架几何尺寸)
   */
  async attach(
    scene: Scene,
    boneNodeMap: Map<HumanoidBone, Node>,
    targetRestPose: HumanoidRestPose,
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

    this.boneNodeMap = boneNodeMap;
    this.targetRestPose = targetRestPose;

    // 根据模型高度调整骨架几何尺寸
    if (modelHeight > 0) {
      const scale: number = modelHeight / 1.7; // 1.7m 为基准
      this.style = {
        jointRadius: DEFAULT_JOINT_RADIUS * scale,
        segmentThickness: DEFAULT_SEGMENT_THICKNESS * scale
      };
      // T-4.2G-A3: 诊断球半径略大于关节球,便于观察
      this.diagnosticSphereRadius = modelHeight * 0.010;
    }

    const factory: SceneResourceFactory = scene.getResourceFactory();

    try {
      // 1. 创建 skeletonRoot
      const rootParams: SceneNodeParameters = { name: 'skeletonRoot' };
      this.skeletonRoot = await factory.createNode(rootParams);
      this.skeletonRoot.position = { x: 0, y: 0, z: 0 };
      this.skeletonRoot.rotation = { x: 0, y: 0, z: 0, w: 1 };
      this.skeletonRoot.scale = { x: 1, y: 1, z: 1 };
      sceneRoot.children.append(this.skeletonRoot);
      Logger.info(LOG_TAG, 'attach: skeletonRoot created and appended');

      // 2. 创建材质
      const matParams: SceneResourceParameters = { name: 'skeletonMat' };
      this.skeletonMaterial = await factory.createMaterial(matParams, MaterialType.METALLIC_ROUGHNESS);

      // 3. 创建关节小球
      const missingJoints: HumanoidBone[] = [];
      for (let i: number = 0; i < DRAWN_JOINTS.length; i++) {
        const bone: HumanoidBone = DRAWN_JOINTS[i];
        if (!boneNodeMap.has(bone)) {
          missingJoints.push(bone);
          continue;
        }
        const joint: Geometry | null = await this.createJointSphere(factory, bone);
        if (joint !== null) {
          this.joints.push({ bone: bone, geometry: joint });
        }
      }
      Logger.info(LOG_TAG, 'attach: joints created count=' + this.joints.length);

      // 4. 创建骨段连线
      const missingSegments: BoneConnection[] = [];
      for (let i: number = 0; i < BONE_CONNECTIONS.length; i++) {
        const conn: BoneConnection = BONE_CONNECTIONS[i];
        if (!boneNodeMap.has(conn.parent) || !boneNodeMap.has(conn.child)) {
          missingSegments.push(conn);
          continue;
        }
        const seg: Geometry | null = await this.createSegmentCube(factory, conn);
        if (seg !== null) {
          this.segments.push({
            parentBone: conn.parent,
            childBone: conn.child,
            geometry: seg
          });
        }
      }
      Logger.info(LOG_TAG, 'attach: segments created count=' + this.segments.length);

      // T-4.2G-A3: 创建 Debug 红绿点几何(默认隐藏,仅 setDebugMode(true) 时显示)
      await this.createDiagnosticGeometry(factory, boneNodeMap);
      Logger.info(LOG_TAG, 'attach: diagnosticJoints created count=' + this.diagnosticJoints.length);

      // 5. 初始化骨架位置(使用当前 boneNodeMap 的 World Position)
      this.updateFrame();

      this.attached = true;
      this.visible = true;

      // T-4.2G-A2: 一次性诊断日志(任务要求只在关键事件记录)
      // - targetSkeleton attach
      // - jointCount / segmentCount
      // - modelHeight
      // - rootTransform(从 Hips 向上遍历到 sceneRoot 的路径 transform)
      // - missingBones(一次性,不重复输出)
      this.logRootTransform();
      this.logMissingBones(missingJoints, missingSegments);
      // T-4.2G-A3: 输出 skeletonRoot / sceneRoot / modelRoot 的 local+world transform
      // 用于排查"骨架整体偏移"、"重复 Root Transform"等问题
      this.logRootsTransform(scene, boneNodeMap);
      Logger.info(LOG_TAG, 'attach: done, joints=' + this.joints.length
        + ' segments=' + this.segments.length
        + ', modelHeight=' + modelHeight.toFixed(3)
        + ', jointRadius=' + this.style.jointRadius.toFixed(4)
        + ', segmentThickness=' + this.style.segmentThickness.toFixed(4));
    } catch (e) {
      Logger.error(LOG_TAG, 'attach failed: ' + (e as Error)?.message);
      await this.detach();
    }
  }

  /**
   * 创建关节小球(SphereGeometry)。
   */
  private async createJointSphere(
    factory: SceneResourceFactory,
    bone: HumanoidBone
  ): Promise<Geometry | null> {
    try {
      const geom: SphereGeometry = new SphereGeometry();
      geom.radius = this.style.jointRadius;
      geom.segmentCount = 8;
      const meshParams: SceneResourceParameters = { name: 'joint_' + bone };
      const mesh: MeshResource = await factory.createMesh(meshParams, geom);
      const nodeParams: SceneNodeParameters = { name: 'joint_' + bone };
      const node: Geometry = await factory.createGeometry(nodeParams, mesh);
      // 赋材质
      if (this.skeletonMaterial !== null) {
        this.assignMaterial(node, this.skeletonMaterial, 'joint_' + bone);
      }
      // 挂到 skeletonRoot
      if (this.skeletonRoot !== null) {
        this.skeletonRoot.children.append(node);
      }
      // 初始位置(原点,updateFrame 会更新)
      node.position = { x: 0, y: 0, z: 0 };
      return node;
    } catch (e) {
      Logger.warn(LOG_TAG, 'createJointSphere failed for ' + bone + ': ' + (e as Error)?.message);
      return null;
    }
  }

  /**
   * 创建骨段连线(CubeGeometry,默认沿 Y 轴,长度=1,scale Y 控制实际长度)。
   */
  private async createSegmentCube(
    factory: SceneResourceFactory,
    conn: BoneConnection
  ): Promise<Geometry | null> {
    try {
      const geom: CubeGeometry = new CubeGeometry();
      // cube 默认 size=(1,1,1),中心在原点
      // 我们将 scale Y 用于长度,scale X/Z 用于粗细
      geom.size = { x: 1, y: 1, z: 1 };
      const meshParams: SceneResourceParameters = { name: 'seg_' + conn.parent + '_' + conn.child };
      const mesh: MeshResource = await factory.createMesh(meshParams, geom);
      const nodeParams: SceneNodeParameters = { name: 'seg_' + conn.parent + '_' + conn.child };
      const node: Geometry = await factory.createGeometry(nodeParams, mesh);
      // 赋材质
      if (this.skeletonMaterial !== null) {
        this.assignMaterial(node, this.skeletonMaterial, 'seg_' + conn.parent);
      }
      // 挂到 skeletonRoot
      if (this.skeletonRoot !== null) {
        this.skeletonRoot.children.append(node);
      }
      // 初始位置和 scale(原点,updateFrame 会更新)
      node.position = { x: 0, y: 0, z: 0 };
      node.scale = {
        x: this.style.segmentThickness,
        y: this.style.segmentThickness,
        z: this.style.segmentThickness
      };
      return node;
    } catch (e) {
      Logger.warn(LOG_TAG, 'createSegmentCube failed for ' + conn.parent + '->' + conn.child
        + ': ' + (e as Error)?.message);
      return null;
    }
  }

  /**
   * 安全地给 Geometry 赋材质。
   */
  private assignMaterial(geom: Geometry, material: Material, label: string): void {
    try {
      const mesh = geom.mesh;
      const subMeshes = mesh.subMeshes;
      if (subMeshes.length === 0) {
        Logger.warn(LOG_TAG, 'assignMaterial: ' + label + ' has no subMeshes');
        return;
      }
      subMeshes[0].material = material;
    } catch (e) {
      Logger.warn(LOG_TAG, 'assignMaterial: ' + label + ' failed: ' + (e as Error)?.message);
    }
  }

  /**
   * T-4.2G-A3: 创建 Debug 红绿点诊断几何。
   *
   * 为 DIAGNOSTIC_JOINTS 中每个骨骼创建:
   * - redSphere:位置 = avatarBoneWorld(从 boneNodeMap 计算)
   * - greenSphere:位置 = jointNode 的 World Position(即 joint.geometry.position 经 skeletonRoot 变换后)
   * - errorLine:连接 redSphere 和 greenSphere 的 cube
   *
   * 全部挂在 skeletonRoot 下,默认 visible=false。
   * 仅 setDebugMode(true) 时显示。
   *
   * 颜色区分:
   * - 红色球半径 = diagnosticSphereRadius(较大)
   * - 绿色球半径 = diagnosticSphereRadius × 0.6(较小)
   * - 黄色线 cube 尺寸 = (thickness, length, thickness)
   *
   * 注:ArkGraphics3D Material 颜色属性 API 在该项目中未确认可用,
   *     此处用不同半径辅助区分,颜色通过材质实例分离。
   *
   * @param factory 资源工厂
   * @param boneNodeMap 骨骼节点映射
   */
  private async createDiagnosticGeometry(
    factory: SceneResourceFactory,
    boneNodeMap: Map<HumanoidBone, Node>
  ): Promise<void> {
    // 创建三种材质实例(若 API 支持颜色,可后续扩展)
    const redParams: SceneResourceParameters = { name: 'diag_red_mat' };
    this.redMaterial = await factory.createMaterial(redParams, MaterialType.METALLIC_ROUGHNESS);
    const greenParams: SceneResourceParameters = { name: 'diag_green_mat' };
    this.greenMaterial = await factory.createMaterial(greenParams, MaterialType.METALLIC_ROUGHNESS);
    const yellowParams: SceneResourceParameters = { name: 'diag_yellow_mat' };
    this.yellowMaterial = await factory.createMaterial(yellowParams, MaterialType.METALLIC_ROUGHNESS);

    for (let i: number = 0; i < DIAGNOSTIC_JOINTS.length; i++) {
      const bone: HumanoidBone = DIAGNOSTIC_JOINTS[i];
      if (!boneNodeMap.has(bone)) {
        Logger.warn(LOG_TAG, 'createDiagnosticGeometry: skip ' + bone + ' (not in boneNodeMap)');
        continue;
      }
      try {
        // 红色球(较大)
        const redGeom: SphereGeometry = new SphereGeometry();
        redGeom.radius = this.diagnosticSphereRadius;
        redGeom.segmentCount = 8;
        const redMeshParams: SceneResourceParameters = { name: 'diag_red_' + bone };
        const redMesh: MeshResource = await factory.createMesh(redMeshParams, redGeom);
        const redNodeParams: SceneNodeParameters = { name: 'diag_red_' + bone };
        const redNode: Geometry = await factory.createGeometry(redNodeParams, redMesh);
        if (this.redMaterial !== null) {
          this.assignMaterial(redNode, this.redMaterial, 'diag_red_' + bone);
        }
        if (this.skeletonRoot !== null) {
          this.skeletonRoot.children.append(redNode);
        }
        redNode.position = { x: 0, y: 0, z: 0 };
        redNode.visible = false; // 默认隐藏

        // 绿色球(较小)
        const greenGeom: SphereGeometry = new SphereGeometry();
        greenGeom.radius = this.diagnosticSphereRadius * 0.6;
        greenGeom.segmentCount = 8;
        const greenMeshParams: SceneResourceParameters = { name: 'diag_green_' + bone };
        const greenMesh: MeshResource = await factory.createMesh(greenMeshParams, greenGeom);
        const greenNodeParams: SceneNodeParameters = { name: 'diag_green_' + bone };
        const greenNode: Geometry = await factory.createGeometry(greenNodeParams, greenMesh);
        if (this.greenMaterial !== null) {
          this.assignMaterial(greenNode, this.greenMaterial, 'diag_green_' + bone);
        }
        if (this.skeletonRoot !== null) {
          this.skeletonRoot.children.append(greenNode);
        }
        greenNode.position = { x: 0, y: 0, z: 0 };
        greenNode.visible = false;

        // 黄色误差线(cube,沿 Y 轴,scale Y = length)
        const lineGeom: CubeGeometry = new CubeGeometry();
        lineGeom.size = { x: 1, y: 1, z: 1 };
        const lineMeshParams: SceneResourceParameters = { name: 'diag_line_' + bone };
        const lineMesh: MeshResource = await factory.createMesh(lineMeshParams, lineGeom);
        const lineNodeParams: SceneNodeParameters = { name: 'diag_line_' + bone };
        const lineNode: Geometry = await factory.createGeometry(lineNodeParams, lineMesh);
        if (this.yellowMaterial !== null) {
          this.assignMaterial(lineNode, this.yellowMaterial, 'diag_line_' + bone);
        }
        if (this.skeletonRoot !== null) {
          this.skeletonRoot.children.append(lineNode);
        }
        lineNode.position = { x: 0, y: 0, z: 0 };
        lineNode.scale = { x: 0, y: 0, z: 0 }; // 默认隐藏(length=0)
        lineNode.visible = false;

        this.diagnosticJoints.push({
          bone: bone,
          redSphere: redNode,
          greenSphere: greenNode,
          errorLine: lineNode
        });
      } catch (e) {
        Logger.warn(LOG_TAG, 'createDiagnosticGeometry: ' + bone + ' failed: ' + (e as Error)?.message);
      }
    }
  }

  /**
   * 每帧更新骨架几何位置。
   *
   * 流程:
   * 1. 遍历 joints,从 boneNodeMap 取 Node,计算 World Position,写入关节小球 position
   * 2. 遍历 segments,计算两端骨骼的 World Position,更新骨段 position/rotation/scale
   * 3. T-4.2G-A3: 同步更新 Debug 红绿点几何位置
   * 4. 每 30 帧采样 RightShoulder/RightElbow/RightHand world position(开发验收诊断)
   * 5. T-4.2G-A3: 每 30 帧输出 6 个关键骨骼的三组坐标对齐诊断
   *
   * 必须在每帧 retarget 写入 SceneNode 之后调用,以反映最新的骨骼变换。
   * 旧帧的 Transform 会被新帧覆盖,不会出现"骨架慢一帧"。
   */
  updateFrame(): void {
    if (!this.attached || this.boneNodeMap === null) {
      return;
    }
    this.frameCounter++;

    // 1. 计算所有已绘制骨骼的 World Position(缓存,避免重复计算)
    const worldPositions: Map<HumanoidBone, Vector3Value> = new Map<HumanoidBone, Vector3Value>();
    for (let i: number = 0; i < this.joints.length; i++) {
      const joint: JointRecord = this.joints[i];
      const node: Node | undefined = this.boneNodeMap.get(joint.bone);
      if (node === undefined) {
        continue;
      }
      const wt: WorldTransform = computeNodeWorldTransform(node);
      worldPositions.set(joint.bone, wt.position);
      // 更新关节小球 position
      try {
        joint.geometry.position = {
          x: wt.position.x,
          y: wt.position.y,
          z: wt.position.z
        };
      } catch (_e) {
        // ignore
      }
    }

    // 2. 更新骨段连线
    for (let i: number = 0; i < this.segments.length; i++) {
      const seg: BoneSegmentRecord = this.segments[i];
      const p1: Vector3Value | undefined = worldPositions.get(seg.parentBone);
      const p2: Vector3Value | undefined = worldPositions.get(seg.childBone);
      if (p1 === undefined || p2 === undefined) {
        continue;
      }
      this.updateSegmentTransform(seg.geometry, p1, p2);
    }

    // 3. T-4.2G-A3: 同步更新 Debug 红绿点几何
    // - redSphere position = avatarBoneWorld(直接从 worldPositions 取)
    // - greenSphere position = jointNode 的 World Position(即 joint.geometry.position 经 skeletonRoot 变换后)
    //   由于 skeletonRoot World Transform 未知,这里读取 greenSphere 的实际 World Position
    // - errorLine 连接两者
    this.updateDiagnosticGeometry(worldPositions);

    // 4. T-4.2G-A2: 每 30 帧采样 RightShoulder/RightElbow/RightHand world position
    if (this.frameCounter % 30 === 1) {
      this.logSampleWorldPositions(worldPositions);
      // T-4.2G-A3: 同时输出 6 个关键骨骼的三组坐标对齐诊断
      this.logAlignmentDiagnostic(worldPositions);
    }
  }

  /**
   * T-4.2G-A3: 更新 Debug 红绿点诊断几何位置。
   *
   * - redSphere.position = avatarBoneWorld(从 boneNodeMap 计算)
   * - greenSphere.position = jointNode 的 Local Position(已写入 joint.geometry.position)
   *   注:jointNode 挂在 skeletonRoot 下,其 World Position 由 skeletonRoot World Transform 决定
   * - errorLine 连接 redSphere 和 greenSphere
   *
   * 通过读取 greenSphere 的 World Transform 验证 skeletonRoot 是否真的为 Identity。
   *
   * @param worldPositions 当前帧 Avatar 骨骼 World Position 快照
   */
  private updateDiagnosticGeometry(worldPositions: Map<HumanoidBone, Vector3Value>): void {
    for (let i: number = 0; i < this.diagnosticJoints.length; i++) {
      const diag: DiagnosticJoint = this.diagnosticJoints[i];
      const avatarWorld: Vector3Value | undefined = worldPositions.get(diag.bone);
      if (avatarWorld === undefined) {
        continue;
      }

      // 找到对应的 joint geometry,读取其 position(即 jointLocal)
      let jointLocal: Vector3Value = { x: 0, y: 0, z: 0 };
      for (let j: number = 0; j < this.joints.length; j++) {
        if (this.joints[j].bone === diag.bone) {
          try {
            const p = this.joints[j].geometry.position;
            jointLocal = { x: p.x, y: p.y, z: p.z };
          } catch (_e) {
            // ignore
          }
          break;
        }
      }

      // 红色球位置 = avatarBoneWorld
      try {
        diag.redSphere.position = {
          x: avatarWorld.x,
          y: avatarWorld.y,
          z: avatarWorld.z
        };
      } catch (_e) {
        // ignore
      }

      // 绿色球位置 = jointLocal(与关节小球相同)
      // 若 skeletonRoot 为 Identity,则 greenSphere World Position == jointLocal == avatarBoneWorld
      // 若 skeletonRoot 非 Identity,则 greenSphere World Position != avatarBoneWorld
      try {
        diag.greenSphere.position = {
          x: jointLocal.x,
          y: jointLocal.y,
          z: jointLocal.z
        };
      } catch (_e) {
        // ignore
      }

      // 黄色误差线:从 redSphere 到 greenSphere
      // 若两者重合,error=0,隐藏线段
      const diff: Vector3Value = vectorSubtract(jointLocal, avatarWorld);
      const errorLen: number = vectorLength(diff);
      if (errorLen < 1e-6) {
        try {
          diag.errorLine.scale = { x: 0, y: 0, z: 0 };
        } catch (_e) {
          // ignore
        }
      } else {
        const mid: Vector3Value = vectorScale(vectorAdd(avatarWorld, jointLocal), 0.5);
        const rot: QuaternionValue = rotationFromYAxisToDirection(diff);
        const lineThickness: number = this.diagnosticSphereRadius * 0.15;
        try {
          diag.errorLine.position = { x: mid.x, y: mid.y, z: mid.z };
        } catch (_e) {
          // ignore
        }
        try {
          diag.errorLine.rotation = { x: rot.x, y: rot.y, z: rot.z, w: rot.w };
        } catch (_e) {
          // ignore
        }
        try {
          diag.errorLine.scale = {
            x: lineThickness,
            y: errorLen,
            z: lineThickness
          };
        } catch (_e) {
          // ignore
        }
      }
    }
  }

  /**
   * T-4.2G-A3: 输出 6 个关键骨骼的三组坐标对齐诊断日志。
   *
   * 三组坐标:
   * - avatarWorld:从 boneNodeMap 计算 World Position(包含模型 Root Transform)
   * - jointLocal:joint.geometry.position(写入关节小球的 Local Position)
   * - jointWorld:jointNode 经过 skeletonRoot 父链变换后的 World Position
   *
   * 误差:error = distance(avatarWorld, jointWorld)
   *
   * 验收标准:error <= modelHeight × 0.005
   *
   * @param worldPositions 当前帧 Avatar 骨骼 World Position 快照
   */
  private logAlignmentDiagnostic(worldPositions: Map<HumanoidBone, Vector3Value>): void {
    const fmt: (v: Vector3Value) => string = (v: Vector3Value): string => {
      return '(' + v.x.toFixed(4) + ',' + v.y.toFixed(4) + ',' + v.z.toFixed(4) + ')';
    };

    Logger.info(LOG_TAG, '=== alignmentDiagnostic frame=' + this.frameCounter + ' ===');
    let maxError: number = 0;
    let maxErrorBone: string = '';
    for (let i: number = 0; i < this.diagnosticJoints.length; i++) {
      const diag: DiagnosticJoint = this.diagnosticJoints[i];
      const avatarWorld: Vector3Value | undefined = worldPositions.get(diag.bone);
      if (avatarWorld === undefined) {
        continue;
      }

      // 读取 jointLocal(joint.geometry.position)
      let jointLocal: Vector3Value = { x: 0, y: 0, z: 0 };
      try {
        const p = diag.greenSphere.position;
        jointLocal = { x: p.x, y: p.y, z: p.z };
      } catch (_e) {
        // ignore
      }

      // 读取 jointWorld(greenSphere 的 World Transform)
      // 由于 greenSphere 挂在 skeletonRoot 下,其 World Position = skeletonRoot World × jointLocal
      const greenWT: WorldTransform = computeNodeWorldTransform(diag.greenSphere);
      const jointWorld: Vector3Value = greenWT.position;

      // 误差 = distance(avatarWorld, jointWorld)
      const diff: Vector3Value = vectorSubtract(jointWorld, avatarWorld);
      const error: number = vectorLength(diff);

      if (error > maxError) {
        maxError = error;
        maxErrorBone = diag.bone;
      }

      Logger.info(LOG_TAG, '  ' + diag.bone
        + ' avatarWorld=' + fmt(avatarWorld)
        + ' jointLocal=' + fmt(jointLocal)
        + ' jointWorld=' + fmt(jointWorld)
        + ' error=' + error.toFixed(6));
    }
    Logger.info(LOG_TAG, '=== maxError=' + maxError.toFixed(6)
      + ' on ' + maxErrorBone + ' (threshold=modelHeight×0.005) ===');
  }

  /**
   * T-4.2G-A3: 输出 skeletonRoot / sceneRoot / modelRoot 的 local+world transform。
   *
   * 用于排查:
   * - skeletonRoot 是否真的为 Identity(挂载后是否被引擎修改)
   * - sceneRoot 是否为 Identity
   * - modelRoot 是否应用了非 Identity Transform(Root Transform)
   * - 骨架 World Transform 是否包含模型 Root Transform
   *
   * @param scene 当前 Scene
   * @param boneNodeMap 骨骼节点映射(用于定位 modelRoot)
   */
  private logRootsTransform(scene: Scene, boneNodeMap: Map<HumanoidBone, Node>): void {
    const fmtV: (v: Vector3Value) => string = (v: Vector3Value): string => {
      return '(' + v.x.toFixed(4) + ',' + v.y.toFixed(4) + ',' + v.z.toFixed(4) + ')';
    };
    const fmtQ: (q: QuaternionValue) => string = (q: QuaternionValue): string => {
      return '(' + q.x.toFixed(4) + ',' + q.y.toFixed(4) + ',' + q.z.toFixed(4) + ',' + q.w.toFixed(4) + ')';
    };
    const logNode: (label: string, n: Node | null) => void = (label: string, n: Node | null): void => {
      if (n === null) {
        Logger.info(LOG_TAG, 'rootsTransform: ' + label + ' = null');
        return;
      }
      let lp: Vector3Value = { x: 0, y: 0, z: 0 };
      let lr: QuaternionValue = { x: 0, y: 0, z: 0, w: 1 };
      let ls: Vector3Value = { x: 1, y: 1, z: 1 };
      try {
        const p = n.position; lp = { x: p.x, y: p.y, z: p.z };
      } catch (_e) { /* ignore */ }
      try {
        const r = n.rotation; lr = { x: r.x, y: r.y, z: r.z, w: r.w };
      } catch (_e) { /* ignore */ }
      try {
        const s = n.scale; ls = { x: s.x, y: s.y, z: s.z };
      } catch (_e) { /* ignore */ }
      const wt: WorldTransform = computeNodeWorldTransform(n);
      Logger.info(LOG_TAG, 'rootsTransform: ' + label
        + ' local[pos=' + fmtV(lp) + ',rot=' + fmtQ(lr) + ',scl=' + fmtV(ls) + ']'
        + ' world[pos=' + fmtV(wt.position) + ',rot=' + fmtQ(wt.rotation) + ',scl=' + fmtV(wt.scale) + ']'
        + ' parent=' + (n.parent === null ? 'null' : n.parent.name));
    };

    logNode('sceneRoot', scene.root);
    logNode('skeletonRoot', this.skeletonRoot);

    // modelRoot:从 Hips 向上遍历到 sceneRoot 的第一层子节点(即 GLB 顶层 node)
    const hipsNode: Node | undefined = boneNodeMap.get(HumanoidBone.Hips);
    if (hipsNode !== undefined) {
      let current: Node | null = hipsNode;
      let modelRoot: Node | null = null;
      while (current !== null) {
        if (current.parent !== null && current.parent.parent === null) {
          // current 的父节点是 sceneRoot,current 就是 modelRoot
          modelRoot = current;
          break;
        }
        current = current.parent;
      }
      logNode('modelRoot', modelRoot);
    } else {
      Logger.warn(LOG_TAG, 'rootsTransform: Hips node not found, cannot locate modelRoot');
    }
  }

  /**
   * T-4.2G-A3: 设置 Debug 可视化模式。
   *
   * 启用后显示 6 个关键骨骼的红绿点诊断几何:
   * - 红色球(较大):avatarBoneWorld
   * - 绿色球(较小):jointWorld(实际渲染位置)
   * - 黄色线:误差连线
   *
   * 默认关闭,仅 Debug 验收时启用。
   *
   * @param enabled 是否启用 Debug 可视化
   */
  setDebugMode(enabled: boolean): void {
    if (this.debugMode === enabled) {
      return;
    }
    this.debugMode = enabled;
    for (let i: number = 0; i < this.diagnosticJoints.length; i++) {
      const diag: DiagnosticJoint = this.diagnosticJoints[i];
      try {
        diag.redSphere.visible = enabled;
      } catch (_e) { /* ignore */ }
      try {
        diag.greenSphere.visible = enabled;
      } catch (_e) { /* ignore */ }
      try {
        diag.errorLine.visible = enabled;
      } catch (_e) { /* ignore */ }
    }
    Logger.info(LOG_TAG, 'setDebugMode: ' + enabled
      + ', diagnosticJoints=' + this.diagnosticJoints.length);
  }

  /**
   * T-4.2G-A3: 手动触发一次三组坐标对齐诊断输出。
   *
   * 用于静止姿势验收:不依赖帧计数,立即输出当前 6 个关键骨骼的三组坐标。
   */
  triggerDiagnosticSnapshot(): void {
    if (!this.attached || this.boneNodeMap === null) {
      Logger.warn(LOG_TAG, 'triggerDiagnosticSnapshot: not attached');
      return;
    }
    const worldPositions: Map<HumanoidBone, Vector3Value> = this.getWorldPositions();
    this.logAlignmentDiagnostic(worldPositions);
  }

  /**
   * T-4.2G-A3: 获取当前 Debug 模式状态。
   */
  isDebugMode(): boolean {
    return this.debugMode;
  }

  /**
   * T-4.2G-A2: 输出 Root Transform 诊断日志。
   *
   * 从 Hips 节点向上遍历到 sceneRoot,记录路径上每层节点的 name + position + rotation + scale。
   * 用于验证骨架 World Transform 是否包含模型 Root Transform。
   */
  private logRootTransform(): void {
    if (this.boneNodeMap === null) {
      return;
    }
    const hipsNode: Node | undefined = this.boneNodeMap.get(HumanoidBone.Hips);
    if (hipsNode === undefined) {
      Logger.warn(LOG_TAG, 'logRootTransform: Hips node not found');
      return;
    }

    // 收集从 Hips 到 root 的路径
    const path: Node[] = [];
    let current: Node | null = hipsNode;
    while (current !== null) {
      path.push(current);
      current = current.parent;
    }

    // 输出路径(从 root 到 Hips)
    const parts: string[] = [];
    for (let i: number = path.length - 1; i >= 0; i--) {
      const n: Node = path[i];
      let name: string = '?';
      let pos: string = '(?)';
      let rot: string = '(?)';
      let scl: string = '(?)';
      try {
        name = n.name;
      } catch (_e) {
        // ignore
      }
      try {
        const p = n.position;
        pos = '(' + p.x.toFixed(3) + ',' + p.y.toFixed(3) + ',' + p.z.toFixed(3) + ')';
      } catch (_e) {
        // ignore
      }
      try {
        const r = n.rotation;
        rot = '(' + r.x.toFixed(3) + ',' + r.y.toFixed(3) + ',' + r.z.toFixed(3) + ',' + r.w.toFixed(3) + ')';
      } catch (_e) {
        // ignore
      }
      try {
        const s = n.scale;
        scl = '(' + s.x.toFixed(3) + ',' + s.y.toFixed(3) + ',' + s.z.toFixed(3) + ')';
      } catch (_e) {
        // ignore
      }
      parts.push('[' + i + ']' + name + ' pos' + pos + ' rot' + rot + ' scl' + scl);
    }
    Logger.info(LOG_TAG, 'rootTransform: depth=' + path.length
      + ' chain=' + parts.join(' -> '));
  }

  /**
   * T-4.2G-A2: 一次性输出缺失骨骼日志(不重复输出)。
   *
   * @param missingJoints 缺失的关节骨骼列表
   * @param missingSegments 缺失的骨段连接列表
   */
  private logMissingBones(
    missingJoints: HumanoidBone[],
    missingSegments: BoneConnection[]
  ): void {
    if (this.missingBonesLogged) {
      return;
    }
    this.missingBonesLogged = true;
    if (missingJoints.length === 0 && missingSegments.length === 0) {
      Logger.info(LOG_TAG, 'missingBones: none (all 20 joints and 20 segments present)');
      return;
    }
    const jointNames: string[] = [];
    for (let i: number = 0; i < missingJoints.length; i++) {
      jointNames.push(missingJoints[i]);
    }
    const segNames: string[] = [];
    for (let i: number = 0; i < missingSegments.length; i++) {
      segNames.push(missingSegments[i].parent + '->' + missingSegments[i].child);
    }
    Logger.warn(LOG_TAG, 'missingBones: joints=[' + jointNames.join(',')
      + '] segments=[' + segNames.join(',') + ']'
      + ' (skipped, not fatal)');
  }

  /**
   * T-4.2G-A2: 每 30 帧采样 RightShoulder/RightElbow/RightHand world position。
   *
   * 用于开发验收时确认模型节点与骨架节点位置一致。
   * 不输出完整矩阵,只输出 3 个关键骨骼的 position。
   *
   * @param worldPositions 当前帧的 World Position 快照
   */
  private logSampleWorldPositions(worldPositions: Map<HumanoidBone, Vector3Value>): void {
    const rs: Vector3Value | undefined = worldPositions.get(HumanoidBone.RightShoulder);
    const re: Vector3Value | undefined = worldPositions.get(HumanoidBone.RightLowerArm);
    const rh: Vector3Value | undefined = worldPositions.get(HumanoidBone.RightHand);
    const fmt: (v: Vector3Value | undefined) => string = (v: Vector3Value | undefined): string => {
      if (v === undefined) {
        return 'N/A';
      }
      return '(' + v.x.toFixed(3) + ',' + v.y.toFixed(3) + ',' + v.z.toFixed(3) + ')';
    };
    Logger.info(LOG_TAG, 'sample frame=' + this.frameCounter
      + ' RightShoulder=' + fmt(rs)
      + ' RightElbow=' + fmt(re)
      + ' RightHand=' + fmt(rh));
  }

  /**
   * 更新单个骨段连线的 transform。
   *
   * cube 默认 size=(1,1,1),中心在原点,沿 Y 轴方向。
   * - position = 中点 (p1+p2)/2
   * - rotation = 从 +Y 轴旋转到 (p2-p1) 方向
   * - scale = (thickness, length, thickness)
   *
   * @param geom 骨段几何节点
   * @param p1 父骨骼 World Position
   * @param p2 子骨骼 World Position
   */
  private updateSegmentTransform(geom: Geometry, p1: Vector3Value, p2: Vector3Value): void {
    const diff: Vector3Value = vectorSubtract(p2, p1);
    const length: number = vectorLength(diff);
    if (length < 1e-6) {
      // 重合,隐藏骨段
      try {
        geom.scale = { x: 0, y: 0, z: 0 };
      } catch (_e) {
        // ignore
      }
      return;
    }

    // 中点
    const mid: Vector3Value = vectorScale(vectorAdd(p1, p2), 0.5);

    // 旋转:从 +Y 轴到 diff 方向
    const rot: QuaternionValue = rotationFromYAxisToDirection(diff);

    // 写入 transform
    try {
      geom.position = { x: mid.x, y: mid.y, z: mid.z };
    } catch (_e) {
      // ignore
    }
    try {
      geom.rotation = { x: rot.x, y: rot.y, z: rot.z, w: rot.w };
    } catch (_e) {
      // ignore
    }
    try {
      geom.scale = {
        x: this.style.segmentThickness,
        y: length,
        z: this.style.segmentThickness
      };
    } catch (_e) {
      // ignore
    }
  }

  /**
   * 恢复骨架到 Target Rest Pose 状态。
   *
   * 调用时机:停止动画后,模型已恢复 Target Rest Pose,骨架也需同步恢复。
   *
   * 由于模型已通过 HumanoidRetargetPlaybackController.restoreTargetRestPose()
   * 将 SceneNode 的 rotation/position 恢复到 Rest Pose,此处只需调用 updateFrame()
   * 重新读取 Node 的 World Position 即可。
   */
  restoreRestPose(): void {
    if (!this.attached) {
      return;
    }
    this.updateFrame();
    Logger.info(LOG_TAG, 'restoreRestPose: skeleton synced with model Rest Pose');
  }

  /**
   * 设置骨架几何可见性(不删除几何)。
   *
   * @param visible 是否可见
   */
  setVisible(visible: boolean): void {
    if (this.visible === visible) {
      return;
    }
    this.visible = visible;
    for (let i: number = 0; i < this.joints.length; i++) {
      try {
        this.joints[i].geometry.visible = visible;
      } catch (_e) {
        // ignore
      }
    }
    for (let i: number = 0; i < this.segments.length; i++) {
      try {
        this.segments[i].geometry.visible = visible;
      } catch (_e) {
        // ignore
      }
    }
    Logger.info(LOG_TAG, 'setVisible: ' + visible);
  }

  /**
   * 获取当前可见性。
   */
  isVisible(): boolean {
    return this.visible;
  }

  /**
   * 获取已绘制关节数量。
   */
  getJointCount(): number {
    return this.joints.length;
  }

  /**
   * 获取已绘制骨段数量。
   */
  getSegmentCount(): number {
    return this.segments.length;
  }

  /**
   * 获取当前所有已绘制骨骼的 World Position 快照。
   *
   * 用于 RestPoseClassifier 分类姿态。
   */
  getWorldPositions(): Map<HumanoidBone, Vector3Value> {
    const result: Map<HumanoidBone, Vector3Value> = new Map<HumanoidBone, Vector3Value>();
    if (this.boneNodeMap === null) {
      return result;
    }
    for (let i: number = 0; i < DRAWN_JOINTS.length; i++) {
      const bone: HumanoidBone = DRAWN_JOINTS[i];
      const node: Node | undefined = this.boneNodeMap.get(bone);
      if (node === undefined) {
        continue;
      }
      const wt: WorldTransform = computeNodeWorldTransform(node);
      result.set(bone, wt.position);
    }
    return result;
  }

  /**
   * 从 Scene 中移除骨架几何并释放资源。
   *
   * 调用 scene.destroy() 时,Scene 内的所有资源都会被释放,
   * 此处只需清空本地引用即可。
   */
  async detach(): Promise<void> {
    Logger.info(LOG_TAG, 'detach: start');
    // 从父节点移除 skeletonRoot
    if (this.skeletonRoot !== null) {
      try {
        const parent: Node | null = this.skeletonRoot.parent;
        if (parent !== null) {
          parent.children.remove(this.skeletonRoot);
        }
      } catch (e) {
        Logger.warn(LOG_TAG, 'detach: remove skeletonRoot failed: ' + (e as Error)?.message);
      }
    }
    this.joints = [];
    this.segments = [];
    this.skeletonRoot = null;
    this.skeletonMaterial = null;
    this.boneNodeMap = null;
    this.targetRestPose = null;
    this.attached = false;
    this.visible = true;
    // T-4.2G-A2: 重置诊断计数器(下次 attach 重新计数)
    this.frameCounter = 0;
    this.missingBonesLogged = false;
    // T-4.2G-A3: 清理诊断几何
    this.diagnosticJoints = [];
    this.redMaterial = null;
    this.greenMaterial = null;
    this.yellowMaterial = null;
    this.debugMode = false;
    this.lastDiagnosticFrame = -1;
    Logger.info(LOG_TAG, 'detach: done');
  }

  /**
   * 释放资源(detach 的别名,便于 ViewModel 统一调用 dispose)。
   */
  async dispose(): Promise<void> {
    await this.detach();
  }
}
