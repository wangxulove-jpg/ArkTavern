/**
 * ActionAvatarPreviewViewModel 动作详情 3D 预览 ViewModel
 *
 * T-4.2 阶段 5: 动作详情弹窗显示当前 Avatar 的真实 3D 动作预览
 *
 * 职责:
 * - 通过 AvatarLibraryService 读取当前激活 Avatar
 * - 加载 Avatar Scene(file://<runtimeUri>)
 * - 补全相机和灯光(若 Avatar GLB 未自带)
 * - 尝试播放 Avatar 自带动画(若存在)
 * - 提供 play/pause/replay/stop 控制
 * - 通过 onStateChanged / onError / onSceneReady 回调通知 UI
 * - generation token 防止异步旧 Scene 覆盖新 Scene
 *
 * 设计说明:
 * - 不实现跨 Scene 动画重定向(ArkGraphics3D API 不支持手动采样 Animation 关键帧)
 * - 若 Avatar 无自带动画,显示静态 Avatar + "当前模型无内置动画" 提示
 * - 预览期间不修改 Avatar 的 displayConfig(只读不写)
 * - 弹窗关闭时调用 dispose() 释放 Scene
 *
 * 生命周期:
 * - 弹窗打开: initialize(avatarId, actionCard)
 * - 切换动作: switchAction(actionCard)
 * - 弹窗关闭: dispose()
 */

import {
  Scene,
  Animation,
  Node,
  Camera,
  Light,
  LightType,
  Position3,
  Quaternion,
  SceneResourceParameters,
  SceneNodeParameters,
  SceneResourceFactory
} from '@kit.ArkGraphics3D';
import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { AvatarLibraryService } from '../services/AvatarLibraryService';
import { AvatarRecord } from '../storage/AvatarLibraryStore';
import { Character3DService } from '../services/Character3DService';
import { GltfModelInfo } from '../parser/GltfValidator';
import { ModelBounds, computeBoundsFromGltf, computeAutoFitDisplayConfig } from '../models/character3d/ModelBounds';
import { Character3DDisplayConfig } from '../models/character3d/Character3DDisplayConfig';
import { Logger } from '../utils/Logger';
import { quaternionToEulerDeg } from '../utils/QuaternionUtil';
import {
  vectorSubtract,
  vectorNormalize,
  vectorDot
} from '../utils/SceneNodeTransformUtil';
import { util } from '@kit.ArkTS';
import { HumanoidRetargetPlaybackController, RetargetPlaybackState, RetargetPlaybackConfig } from '../services/HumanoidRetargetPlaybackController';
import { collectSceneNodes, SceneNodeCollectResult } from '../services/SceneNodeCollector';
import { collectTargetRestPose, TargetRestPoseCollectResult } from '../services/TargetRestPoseCollector';
import { HumanoidProvider, HumanoidProviderInput } from '../services/HumanoidProvider';
import { computeWorldRestRotations } from '../services/HumanoidRetargetor';
import { parseAnimationByName, parseSourceRestPose, AnimationDataParseResult, SourceRestPoseParseResult } from '../parser/GltfAnimationDataParser';
import { HumanoidMotionClip, HumanoidRestPose, BoneRestTransform, RootMotionMode, QuaternionValue, Vector3Value } from '../models/character3d/HumanoidMotionClip';
import { HumanoidBone } from '../models/character3d/HumanoidBone';
import { VrmAsset } from '../models/character3d/vrm/VrmAsset';
import { BUILTIN_ACTION_RAWFILE_DIR, BUILTIN_PACK_FILE_NAME } from '../models/character3d/BuiltInActionManifest';
import { detectVrm } from '../parser/VrmDetector';
import { importVrm } from '../parser/VRMImporter';
import { GltfValidator } from '../parser/GltfValidator';
import {
  AvatarOrientationCalibration,
  AvatarOrientationMode,
  OrientationConfidence,
  AvatarOrientationAnalysis,
  createDefaultCalibration,
  applyManualOverride
} from '../models/character3d/AvatarOrientationCalibration';
import { AvatarOrientationCalibrationStore } from '../storage/AvatarOrientationCalibrationStore';
import { analyzeOrientation, logAnalysisSummary } from '../services/AvatarOrientationAnalyzer';
import { TargetAvatarSkeletonController } from '../services/TargetAvatarSkeletonController';
import { SourceTargetCompareSkeleton } from '../services/SourceTargetCompareSkeleton';
import {
  collectFullDiagnosticSnapshot,
  logFullDiagnosticSnapshot,
  diagnoseRetargetBaseline,
  runFullBasisAndAxisDiagnostic,
  FullDiagnosticSnapshot
} from '../services/SourceRetargetDiagnosticCollector';
import {
  SkeletonDisplayMode,
  getAllSkeletonDisplayModes,
  shouldShowModel,
  shouldShowSkeleton,
  shouldUseSourceActionPreview
} from '../models/character3d/SkeletonDisplayMode';
import { classifyRestPose, RestPoseType, RestPoseClassification } from '../services/RestPoseClassifier';

const LOG_TAG: string = 'ActionAvatarPreviewVM';

/** T-4.2D: 预览相机 FOV(与 PoC CAMERA_FOV 一致) */
const PREVIEW_CAMERA_FOV: number = 45;
/** T-4.2D: 预览相机默认 near(动态调整) */
const PREVIEW_CAMERA_NEAR: number = 0.1;
/** T-4.2D: 预览相机默认 far(动态调整) */
const PREVIEW_CAMERA_FAR: number = 100;
/** T-4.2D: 预览灯光强度 */
const PREVIEW_LIGHT_INTENSITY: number = 3.0;

/**
 * 预览状态。
 */
export enum ActionPreview3DState {
  /** 初始空闲 */
  Idle = 'Idle',
  /** 正在加载 Avatar Scene */
  LoadingAvatar = 'LoadingAvatar',
  /** 正在加载动作资产 */
  LoadingMotion = 'LoadingMotion',
  /** 正在准备重定向(建立骨骼映射) */
  PreparingRetarget = 'PreparingRetarget',
  /** Avatar Scene 加载完成,可播放 */
  Ready = 'Ready',
  /** 动画播放中 */
  Playing = 'Playing',
  /** 动画暂停 */
  Paused = 'Paused',
  /** 加载或播放失败 */
  Failed = 'Failed',
  /** 当前 Avatar 无内置动画,仅静态显示(保留向后兼容,T-4.2E 后不再使用) */
  StaticOnly = 'StaticOnly'
}

/**
 * T-4.2G-A2: 骨架信息查询结果。
 */
export interface SkeletonInfoResult {
  /** 关节小球数量 */
  joints: number;
  /** 骨段连线数量 */
  segments: number;
  /** Rest Pose 分类类型 */
  poseType: RestPoseType;
  /** 分类置信度 [0, 1] */
  confidence: number;
  /** 分类诊断信息 */
  message: string;
}

/**
 * 动作卡片最小信息(避免依赖 ActionCardItem 完整类型)。
 */
export interface PreviewActionInfo {
  /** 动作 ID */
  actionId: string;
  /** 动作显示名 */
  displayName: string;
  /** Clip 名 */
  clipName: string;
  /** Clip 索引 */
  clipIndex: number;
  /** 是否循环 */
  loop: boolean;
  /** 时长(ms) */
  durationMs: number;
}

/**
 * 动作详情 3D 预览 ViewModel。
 */
export class ActionAvatarPreviewViewModel {
  /** Avatar 模型库服务(读取激活 Avatar) */
  private avatarLibraryService: AvatarLibraryService | null = null;
  /** T-4.2D: Character3DService(用于 getModelInfoByUri 计算 bounds) */
  private character3DService: Character3DService | null = null;
  /** T-4.2E: App context(用于读取 rawfile 动作包) */
  private appContext: common.Context | null = null;
  /** 当前 Scene 实例 */
  private sceneValue: Scene | null = null;
  /** 当前播放的动画(ArkGraphics3D 内置动画模式) */
  private currentAnimation: Animation | null = null;
  /** 当前预览状态 */
  private stateValue: ActionPreview3DState = ActionPreview3DState.Idle;
  /** 当前 Avatar 显示名 */
  private avatarDisplayName: string = '';
  /** 当前 Avatar avatarId */
  private loadedAvatarId: string = '';
  /** 当前动作信息 */
  private currentAction: PreviewActionInfo | null = null;
  /** Scene 加载代际(每次重新加载递增) */
  private sceneLoadGeneration: number = 0;
  /** 是否已 dispose */
  private disposed: boolean = false;
  /** T-4.2D: 当前模型 Bounds(诊断用) */
  private currentBounds: ModelBounds | null = null;
  /** T-4.2D: 当前自适应显示配置 */
  private currentDisplayConfig: Character3DDisplayConfig | null = null;

  // ==================== T-4.2E: Humanoid Retarget Runtime ====================

  /** T-4.2E: 重定向播放控制器 */
  private retargetController: HumanoidRetargetPlaybackController | null = null;
  /** T-4.2E: 动作包 GLB ArrayBuffer(缓存,避免重复读取) */
  private actionPackBuffer: ArrayBuffer | null = null;
  /** T-4.2E: Avatar GLB ArrayBuffer(用于建立 nodeIndex→SceneNode 映射) */
  private avatarGlbBuffer: ArrayBuffer | null = null;
  /** T-4.2E: 当前播放模式(true=Retarget Controller,false=ArkGraphics3D 内置动画) */
  private useRetargetMode: boolean = false;

  // ==================== T-4.2G: Orientation Calibration ====================

  /** T-4.2G: 方向校准存储(按 avatarId 持久化) */
  private calibrationStore: AvatarOrientationCalibrationStore | null = null;
  /** T-4.2G: 当前生效的校准数据(Memory cache,与 Preferences 同步) */
  private currentCalibration: AvatarOrientationCalibration | null = null;
  /** T-4.2G: 最近一次自动分析结果(用于 UI 显示候选评分与理由) */
  private lastAnalysis: AvatarOrientationAnalysis | null = null;

  // ==================== T-4.2G-A2: Target Avatar Skeleton ====================

  /** T-4.2G-A2: 目标骨架可视化控制器 */
  private skeletonController: TargetAvatarSkeletonController | null = null;
  /** T-4.2G-A2: 当前显示模式
   *  T-4.2G-A2 统一姿势: 默认改为 ModelOnly,避免普通用户被调试骨架干扰。
   *  用户主动选择"模型 + 骨架"后才显示骨架。 */
  private currentDisplayMode: SkeletonDisplayMode = SkeletonDisplayMode.ModelOnly;
  /** T-4.2G-A2: 当前 Rest Pose 分类结果(用于 UI 显示) */
  private restPoseClassification: RestPoseClassification | null = null;
  /** T-4.2G-A2: 当前模型根节点列表(用于显示模式切换时控制可见性) */
  private modelRootNodes: Node[] = [];

  // ==================== T-4.2G-A4: Source/Target Retarget Diagnostic ====================

  /** T-4.2G-A4: Source/Target 三栏对比可视化控制器(Debug-only) */
  private compareSkeleton: SourceTargetCompareSkeleton | null = null;
  /** T-4.2G-A4: 当前 clip 引用(用于诊断采样) */
  private currentClip: HumanoidMotionClip | null = null;
  /** T-4.2G-A4: 当前 Source Rest Pose 引用(用于诊断) */
  private currentSourceRestPose: HumanoidRestPose | null = null;
  /** T-4.2G-A4: 当前 Target Rest Pose 引用(用于诊断) */
  private currentTargetRestPose: HumanoidRestPose | null = null;
  /** T-4.2G-A4: 当前 boneNodeMap 引用(用于诊断) */
  private currentBoneNodeMap: Map<HumanoidBone, Node> | null = null;

  /** 状态变更回调 */
  onStateChanged: ((state: ActionPreview3DState) => void) | null = null;
  /** 错误信息回调 */
  onError: ((message: string) => void) | null = null;
  /** Scene 就绪回调(UI 拿到 Scene 引用渲染 Component3D) */
  onSceneReady: ((scene: Scene | null) => void) | null = null;
  /** Avatar 信息回调(显示名 + 是否有动画) */
  onAvatarInfo: ((displayName: string, hasAnimation: boolean) => void) | null = null;
  /** T-4.2E: 准备进度回调(显示"正在准备动作..."等) */
  onPrepareProgress: ((message: string) => void) | null = null;
  /** T-4.2G: 校准变更回调(UI 刷新校准面板) */
  onCalibrationChanged: ((calibration: AvatarOrientationCalibration | null,
                          analysis: AvatarOrientationAnalysis | null) => void) | null = null;
  /** T-4.2G-A2: 显示模式变更回调(UI 刷新模式选择器) */
  onDisplayModeChanged: ((mode: SkeletonDisplayMode) => void) | null = null;
  /** T-4.2G-A2: 骨架信息回调(关节数、骨段数、姿态分类、置信度) */
  onSkeletonInfo: ((joints: number, segments: number, poseType: RestPoseType,
                    confidence: number, message: string) => void) | null = null;

  /**
   * 注入 AvatarLibraryService。
   */
  setAvatarLibraryService(service: AvatarLibraryService): void {
    this.avatarLibraryService = service;
  }

  /**
   * T-4.2D: 注入 Character3DService(用于 getModelInfoByUri 计算 bounds)。
   */
  setCharacter3DService(service: Character3DService): void {
    this.character3DService = service;
  }

  /**
   * T-4.2E: 注入 App context(用于读取 rawfile 动作包)。
   */
  setAppContext(context: common.Context): void {
    this.appContext = context;
  }

  /**
   * T-4.2G: 注入方向校准存储服务。
   *
   * 必须在 initialize 之前注入,否则校准数据不会持久化。
   */
  setCalibrationStore(store: AvatarOrientationCalibrationStore): void {
    this.calibrationStore = store;
  }

  /**
   * T-4.2G: 获取当前校准数据(Memory cache)。
   *
   * 用于 UI 显示当前模式、Yaw、置信度等。
   */
  getCurrentCalibration(): AvatarOrientationCalibration | null {
    return this.currentCalibration;
  }

  /**
   * T-4.2G: 获取最近一次自动分析结果。
   *
   * 用于 UI 显示候选评分与理由。
   */
  getLastAnalysis(): AvatarOrientationAnalysis | null {
    return this.lastAnalysis;
  }

  /**
   * T-4.2G: 应用手动校准覆盖。
   *
   * 流程:
   * 1. 基于 currentCalibration 应用 override 生成新 calibration
   * 2. 持久化到 Store
   * 3. 立即更新 Retarget Controller
   * 4. 触发 onCalibrationChanged 回调
   *
   * @param mode 用户选择的模式
   * @param customYaw Custom 模式下的 yaw 偏移(度)
   * @param customSwap Custom 模式下的左右交换
   * @param customInvert Custom 模式下的 Forward 反转
   * @returns true 表示已应用并持久化
   */
  async applyManualCalibration(
    mode: AvatarOrientationMode,
    customYaw: number,
    customSwap: boolean,
    customInvert: boolean
  ): Promise<boolean> {
    if (this.currentCalibration === null) {
      Logger.warn(LOG_TAG, 'applyManualCalibration: currentCalibration null');
      return false;
    }
    const next: AvatarOrientationCalibration = applyManualOverride(
      this.currentCalibration,
      mode,
      customYaw,
      customSwap,
      customInvert
    );
    this.currentCalibration = next;

    // 持久化
    if (this.calibrationStore !== null) {
      const ok: boolean = await this.calibrationStore.save(next);
      Logger.info(LOG_TAG, 'applyManualCalibration: saved=' + ok + ', mode=' + mode);
    }

    // 立即更新 Controller(运行时切换)
    if (this.retargetController !== null) {
      this.retargetController.updateCalibration(next);
    }

    // 通知 UI
    if (this.onCalibrationChanged !== null) {
      this.onCalibrationChanged(next, this.lastAnalysis);
    }
    return true;
  }

  /**
   * T-4.2G: 恢复自动检测模式(mode = Auto)。
   *
   * 不删除已保存的自动结果,只是把模式切回 Auto,让自动分析重新生效。
   */
  async restoreAutoCalibration(): Promise<boolean> {
    if (this.currentCalibration === null) {
      return false;
    }
    return await this.applyManualCalibration(
      AvatarOrientationMode.Auto,
      0,
      false,
      false
    );
  }

  /**
   * T-4.2G: 恢复默认(Normal 模式,无校正)。
   *
   * 等价于 applyManualCalibration(Normal, 0, false, false)。
   */
  async restoreDefaultCalibration(): Promise<boolean> {
    if (this.currentCalibration === null) {
      return false;
    }
    return await this.applyManualCalibration(
      AvatarOrientationMode.Normal,
      0,
      false,
      false
    );
  }

  // ==================== T-4.2G-A2: Display Mode & Skeleton API ====================

  /**
   * T-4.2G-A2: 获取当前显示模式。
   */
  getCurrentDisplayMode(): SkeletonDisplayMode {
    return this.currentDisplayMode;
  }

  /**
   * T-4.2G-A2: 设置显示模式。
   *
   * 仅切换几何可见性,不影响模型真实姿态(不调用 retargetController)。
   *
   * @param mode 目标显示模式
   */
  setDisplayMode(mode: SkeletonDisplayMode): void {
    if (this.currentDisplayMode === mode) {
      return;
    }
    this.currentDisplayMode = mode;
    Logger.info(LOG_TAG, 'setDisplayMode: ' + mode);
    this.applyDisplayModeVisibility();
    if (this.onDisplayModeChanged !== null) {
      this.onDisplayModeChanged(mode);
    }
  }

  /**
   * T-4.2G-A3: 设置 Debug 红绿点可视化模式。
   *
   * 启用后显示 6 个关键骨骼(左右 Shoulder/Elbow/Hand)的诊断几何:
   * - 红色球(较大):avatarBoneWorld(从 boneNodeMap 计算)
   * - 绿色球(较小):jointNode 的实际渲染位置
   * - 黄色线:误差连线(若 error<1e-6 则隐藏)
   *
   * 仅 IS_DEV_BUILD 时由 UI 调用,正式版不应暴露。
   *
   * @param enabled 是否启用 Debug 可视化
   */
  setSkeletonDebugMode(enabled: boolean): void {
    if (this.skeletonController !== null) {
      this.skeletonController.setDebugMode(enabled);
    } else {
      Logger.warn(LOG_TAG, 'setSkeletonDebugMode: skeletonController null, skip');
    }
  }

  /**
   * T-4.2G-A3: 手动触发一次三组坐标对齐诊断输出。
   *
   * 立即输出当前 6 个关键骨骼的三组坐标:
   * - avatarWorld(从 boneNodeMap 计算)
   * - jointLocal(joint.geometry.position)
   * - jointWorld(greenSphere 的 World Transform)
   * - error = distance(avatarWorld, jointWorld)
   *
   * 用于静止姿势验收,不依赖帧计数。
   */
  triggerSkeletonDiagnostic(): void {
    if (this.skeletonController !== null) {
      this.skeletonController.triggerDiagnosticSnapshot();
    } else {
      Logger.warn(LOG_TAG, 'triggerSkeletonDiagnostic: skeletonController null, skip');
    }
  }

  /**
   * T-4.2G-A3: 获取 Debug 模式状态。
   */
  isSkeletonDebugMode(): boolean {
    return this.skeletonController !== null ? this.skeletonController.isDebugMode() : false;
  }

  /**
   * T-4.2G-A4: 手动触发 Source/Target 重定向基准诊断。
   *
   * 采集三套姿态完整数据:
   *   - Source Rest(从 sourceRestPose 计算)
   *   - Source Animated t=0/0.5s/1.0s(从 sampleMotionClip + sourceRestPose 计算)
   *   - Target Rest(从 targetRestPose 计算)
   *
   * 输出:
   *   - 每根骨骼的 localRotation / localPosition / worldRotation / worldPosition
   *   - 动画第 0 帧与 Source Rest 的逐骨骼 Delta(重点 UpperArm/LowerArm)
   *   - Source Rest Pose 来源说明
   *   - Source/Target Rest Pose 分类(T Pose / A Pose / ArmsDown)
   *   - 重定向基准问题诊断结果
   *
   * 用于回答任务要求 14 项必答中的:
   *   1. 原"源动作示意"是否为硬编码 → 见日志 sourceRestOrigin
   *   2. 动作包真实 Source Rest Pose 类型 → sourceRestClassification
   *   3. Source Rest Pose 来自哪里 → sourceRestOrigin
   *   4. 动画第 0 帧与 Source Rest 的 UpperArm 差值 → [FocusBonesDelta]
   *   5. 当前是否混用了不同骨架的 Rest Pose → 见 diagnoseRetargetBaseline 输出
   */
  triggerSourceTargetDiagnostic(): void {
    if (this.currentClip === null
      || this.currentSourceRestPose === null
      || this.currentTargetRestPose === null) {
      Logger.warn(LOG_TAG, 'triggerSourceTargetDiagnostic: missing prerequisites, skip');
      return;
    }

    Logger.info(LOG_TAG, '=== T-4.2G-A4 triggerSourceTargetDiagnostic ===');
    const snapshot: FullDiagnosticSnapshot = collectFullDiagnosticSnapshot(
      this.currentClip,
      this.currentSourceRestPose,
      this.currentTargetRestPose
    );
    logFullDiagnosticSnapshot(snapshot);

    // 诊断重定向基准问题
    const issues: string[] = diagnoseRetargetBaseline(snapshot);
    if (issues.length === 0) {
      Logger.info(LOG_TAG, 'T-4.2G-A4 diagnoseRetargetBaseline: NO ISSUES DETECTED');
    } else {
      Logger.warn(LOG_TAG, 'T-4.2G-A4 diagnoseRetargetBaseline: ' + issues.length + ' issue(s):');
      for (let i: number = 0; i < issues.length; i++) {
        Logger.warn(LOG_TAG, '  [' + (i + 1) + '] ' + issues[i]);
      }
    }

    // T-4.2G-A4B: 单骨骼轴测试(12 组) + Source/Target Basis 比较(4 根手臂骨骼)
    // 复用同一触发按钮,不新增 UI 入口
    runFullBasisAndAxisDiagnostic(this.currentSourceRestPose, this.currentTargetRestPose);

    Logger.info(LOG_TAG, '=== T-4.2G-A4 triggerSourceTargetDiagnostic End ===');
  }

  /**
   * T-4.2G-A4: 设置 Source/Target 三栏对比可视化(Debug-only)。
   *
   * 启用后同屏显示三栏:
   *   - 灰色(偏左,小关节球):Source Rest Pose
   *   - 蓝色(居中,中关节球):Source Animated Pose(实时采样当前播放时间)
   *   - 绿色(偏右,大关节球):Target Retargeted Pose(从 boneNodeMap 实时读取)
   *
   * 注意:启用后会显示三栏骨架几何,模型本身不隐藏(用户可同时观察模型与三栏对比)。
   * 验收后应关闭此模式。
   *
   * @param enabled 是否启用三栏对比
   */
  setSourceTargetCompareMode(enabled: boolean): void {
    if (this.compareSkeleton !== null) {
      this.compareSkeleton.setEnabled(enabled);
      // 启用时立即刷新一帧(显示当前状态)
      if (enabled && this.retargetController !== null) {
        const currentTime: number = this.retargetController.getCurrentTime();
        this.compareSkeleton.updateFrame(currentTime);
      } else if (enabled) {
        // 未播放时也显示 Source Rest 和 Target Rest
        this.compareSkeleton.updateFrame(0);
      }
    } else {
      Logger.warn(LOG_TAG, 'setSourceTargetCompareMode: compareSkeleton null, skip');
    }
  }

  /**
   * T-4.2G-A4: 获取 Source/Target 三栏对比可视化状态。
   */
  isSourceTargetCompareMode(): boolean {
    return this.compareSkeleton !== null ? this.compareSkeleton.isEnabled() : false;
  }

  /**
   * T-4.2G-A2: 获取所有可用显示模式(UI 列表渲染)。
   */
  getAvailableDisplayModes(): SkeletonDisplayMode[] {
    const infos = getAllSkeletonDisplayModes();
    const modes: SkeletonDisplayMode[] = [];
    for (let i = 0; i < infos.length; i++) {
      modes.push(infos[i].mode);
    }
    return modes;
  }

  /**
   * T-4.2G-A2: 获取当前骨架信息(关节数、骨段数)。
   */
  getSkeletonInfo(): SkeletonInfoResult {
    const joints: number = this.skeletonController !== null ? this.skeletonController.getJointCount() : 0;
    const segments: number = this.skeletonController !== null ? this.skeletonController.getSegmentCount() : 0;
    const poseType: RestPoseType = this.restPoseClassification !== null
      ? this.restPoseClassification.type : RestPoseType.Unknown;
    const confidence: number = this.restPoseClassification !== null
      ? this.restPoseClassification.confidence : 0;
    const message: string = this.restPoseClassification !== null
      ? this.restPoseClassification.message : '';
    const result: SkeletonInfoResult = {
      joints: joints,
      segments: segments,
      poseType: poseType,
      confidence: confidence,
      message: message
    };
    return result;
  }

  /**
   * T-4.2G-A2: 应用当前显示模式的可见性。
   *
   * T-4.2G-A2 统一姿势:
   * - ModelOnly: 显示模型,隐藏骨架
   * - ModelWithSkeleton: 显示模型 + 骨架
   * - SkeletonOnly: 隐藏模型,显示骨架
   * - SourceActionPreview: 隐藏 3D 模型和 3D 骨架,由 UI 渲染 2D 源动作卡片
   *
   * 不修改 retargetController 状态,只修改几何 visible 属性。
   * 不重新加载 Scene,不重置动作时间。
   */
  private applyDisplayModeVisibility(): void {
    const showModel: boolean = shouldShowModel(this.currentDisplayMode);
    const showSkeleton: boolean = shouldShowSkeleton(this.currentDisplayMode);

    // 控制模型根节点可见性
    for (let i = 0; i < this.modelRootNodes.length; i++) {
      try {
        this.modelRootNodes[i].visible = showModel;
      } catch (e) {
        // ignore
      }
    }

    // 控制骨架可见性
    if (this.skeletonController !== null) {
      this.skeletonController.setVisible(showSkeleton);
    }

    Logger.info(LOG_TAG, 'applyDisplayModeVisibility: mode=' + this.currentDisplayMode
      + ' showModel=' + showModel + ' showSkeleton=' + showSkeleton);
  }

  /**
   * 初始化预览:加载当前激活 Avatar。
   *
   * @param action 初始动作信息
   */
  async initialize(action: PreviewActionInfo): Promise<void> {
    if (this.disposed) {
      Logger.warn(LOG_TAG, 'initialize ignored: disposed');
      return;
    }
    this.currentAction = action;
    await this.loadActiveAvatarScene();
  }

  /**
   * 切换动作(不重新加载 Avatar Scene)。
   *
   * T-4.2E: 优先使用 Retarget 模式重新准备新动作;
   * 回退到 Avatar 自带动画模式。
   */
  async switchAction(action: PreviewActionInfo): Promise<void> {
    if (this.disposed) {
      return;
    }
    this.currentAction = action;
    if (this.sceneValue === null) {
      // Scene 尚未加载完成,等待 initialize 完成后会自动播放
      return;
    }
    // 停止当前动画/重定向
    if (this.useRetargetMode && this.retargetController !== null) {
      this.retargetController.stop();
    } else {
      this.stopInternal();
    }

    // T-4.2E: 优先重新准备 Retarget Controller(新动作)
    if (this.avatarLibraryService !== null) {
      const activeAvatar: AvatarRecord | null = await this.avatarLibraryService.getActiveAvatar();
      if (activeAvatar !== null) {
        const retargetOk: boolean = await this.prepareRetargetController(activeAvatar, this.sceneLoadGeneration);
        if (retargetOk) {
          this.useRetargetMode = true;
          if (this.retargetController !== null) {
            this.retargetController.play();
          }
          if (this.onAvatarInfo !== null) {
            this.onAvatarInfo(this.avatarDisplayName, true);
          }
          return;
        }
      }
    }

    // 回退:尝试 Avatar 自带动画
    this.useRetargetMode = false;
    const hasAnimation: boolean = this.tryPlayActionClip();
    if (this.onAvatarInfo !== null) {
      this.onAvatarInfo(this.avatarDisplayName, hasAnimation);
    }
  }

  /**
   * 播放(从 Ready/Paused/StaticOnly 进入 Playing)。
   *
   * T-4.2E: 优先使用 HumanoidRetargetPlaybackController(外部动作重定向);
   * 仅当目标模型自带动画时才调用 ArkGraphics3D Animation。
   */
  play(): void {
    if (this.disposed || this.sceneValue === null) {
      return;
    }
    if (this.stateValue === ActionPreview3DState.Playing) {
      return;
    }
    // T-4.2E: 优先使用 Retarget Controller
    if (this.useRetargetMode && this.retargetController !== null) {
      this.retargetController.play();
      return;
    }
    // T-4.2G-A3: Ready 状态下用户点击播放,若 currentAnimation 为空,
    // 尝试查找并启动 Avatar 自带动画(因为 Scene 加载后不自动播放)
    if (this.currentAnimation === null) {
      // 尝试启动自带动画
      const started: boolean = this.tryPlayActionClip();
      if (!started) {
        Logger.warn(LOG_TAG, 'play: no animation available');
        this.fireError('当前模型无可播放的动作');
      }
      return;
    }
    try {
      this.currentAnimation.enabled = true;
      this.currentAnimation.start();
      this.setState(ActionPreview3DState.Playing);
    } catch (e) {
      Logger.error(LOG_TAG, 'play failed: ' + (e as Error)?.message);
      this.fireError('播放失败: ' + (e as Error)?.message);
    }
  }

  /**
   * 暂停(从 Playing 进入 Paused)。
   */
  pause(): void {
    if (this.disposed || this.stateValue !== ActionPreview3DState.Playing) {
      return;
    }
    // T-4.2E: 优先使用 Retarget Controller
    if (this.useRetargetMode && this.retargetController !== null) {
      this.retargetController.pause();
      return;
    }
    if (this.currentAnimation === null) {
      return;
    }
    try {
      this.currentAnimation.pause();
      this.setState(ActionPreview3DState.Paused);
    } catch (e) {
      Logger.warn(LOG_TAG, 'pause failed: ' + (e as Error)?.message);
    }
  }

  /**
   * 重播(回到 0 秒并播放)。
   */
  replay(): void {
    if (this.disposed || this.sceneValue === null) {
      return;
    }
    // T-4.2E: 优先使用 Retarget Controller
    if (this.useRetargetMode && this.retargetController !== null) {
      this.retargetController.replay();
      return;
    }
    if (this.currentAnimation === null) {
      return;
    }
    try {
      this.currentAnimation.stop();
      this.currentAnimation.enabled = true;
      this.currentAnimation.start();
      this.setState(ActionPreview3DState.Playing);
    } catch (e) {
      Logger.warn(LOG_TAG, 'replay failed: ' + (e as Error)?.message);
      this.fireError('重播失败: ' + (e as Error)?.message);
    }
  }

  /**
   * 停止(回到 rest pose)。
   */
  stop(): void {
    // T-4.2E: 优先使用 Retarget Controller
    if (this.useRetargetMode && this.retargetController !== null) {
      this.retargetController.stop();
      if (this.stateValue !== ActionPreview3DState.Failed) {
        this.setState(ActionPreview3DState.Ready);
      }
      return;
    }
    this.stopInternal();
    if (this.stateValue !== ActionPreview3DState.Failed) {
      this.setState(ActionPreview3DState.Ready);
    }
  }

  /**
   * 内部停止(不修改状态)。
   */
  private stopInternal(): void {
    if (this.currentAnimation !== null) {
      try {
        this.currentAnimation.stop();
      } catch (_e) {
        // ignore
      }
    }
  }

  /**
   * 释放资源(弹窗关闭时调用)。
   */
  dispose(): void {
    if (this.disposed) {
      return;
    }
    this.disposed = true;
    Logger.info(LOG_TAG, 'dispose: releasing scene');
    // T-4.2E: 释放 Retarget Controller(恢复 Rest Pose + 取消定时器)
    if (this.retargetController !== null) {
      try {
        this.retargetController.dispose();
      } catch (_e) {
        // ignore
      }
      this.retargetController = null;
    }
    // T-4.2G-A2: 释放 Skeleton Controller(必须在 scene.destroy 之前,以移除骨架几何)
    if (this.skeletonController !== null) {
      try {
        // detach 内部无 await,同步执行,可安全在 sync dispose 中调用
        this.skeletonController.detach();
      } catch (_e) {
        // ignore
      }
      this.skeletonController = null;
    }
    // T-4.2G-A4: 释放 Compare Skeleton(必须在 scene.destroy 之前,以移除三栏对比几何)
    if (this.compareSkeleton !== null) {
      try {
        // detach 内部无 await,同步执行,可安全在 sync dispose 中调用
        this.compareSkeleton.detach();
      } catch (_e) {
        // ignore
      }
      this.compareSkeleton = null;
    }
    // T-4.2G-A4: 清理诊断引用
    this.currentClip = null;
    this.currentSourceRestPose = null;
    this.currentTargetRestPose = null;
    this.currentBoneNodeMap = null;
    this.restPoseClassification = null;
    this.modelRootNodes = [];
    this.useRetargetMode = false;
    this.actionPackBuffer = null;
    this.avatarGlbBuffer = null;
    this.stopInternal();
    this.currentAnimation = null;
    if (this.sceneValue !== null) {
      try {
        this.sceneValue.destroy();
      } catch (_e) {
        // ignore
      }
      this.sceneValue = null;
    }
    if (this.onSceneReady !== null) {
      this.onSceneReady(null);
    }
    this.setState(ActionPreview3DState.Idle);
  }

  /**
   * 获取当前 Scene 引用(UI 用于 Component3D)。
   */
  getScene(): Scene | null {
    return this.sceneValue;
  }

  /**
   * 获取当前状态。
   */
  getState(): ActionPreview3DState {
    return this.stateValue;
  }

  /**
   * 获取当前 Avatar 显示名。
   */
  getAvatarDisplayName(): string {
    return this.avatarDisplayName;
  }

  /**
   * 加载当前激活 Avatar 的 Scene。
   *
   * T-4.2C: 加入完整状态机日志(Idle→LoadingAvatar→Ready/StaticOnly/Playing/Failed)。
   */
  private async loadActiveAvatarScene(): Promise<void> {
    Logger.info(LOG_TAG, 'stateMachine: Idle→LoadingAvatar, action='
      + (this.currentAction !== null ? this.currentAction.clipName : 'null')
      + ', clipIndex=' + (this.currentAction !== null ? this.currentAction.clipIndex : -1));
    if (this.avatarLibraryService === null) {
      Logger.error(LOG_TAG, 'loadActiveAvatarScene: AvatarLibraryService null');
      this.fireError('AvatarLibraryService 未注入');
      this.setState(ActionPreview3DState.Failed);
      return;
    }
    this.setState(ActionPreview3DState.LoadingAvatar);
    const generation: number = ++this.sceneLoadGeneration;
    Logger.info(LOG_TAG, 'loadActiveAvatarScene: generation=' + generation);

    try {
      const activeAvatar: AvatarRecord | null = await this.avatarLibraryService.getActiveAvatar();
      if (generation !== this.sceneLoadGeneration) {
        Logger.info(LOG_TAG, 'late callback discarded: avatar lookup');
        return;
      }
      if (activeAvatar === null) {
        Logger.warn(LOG_TAG, 'loadActiveAvatarScene: activeAvatar null');
        this.fireError('未选择当前 Avatar,请先在模型库中设为当前');
        this.setState(ActionPreview3DState.Failed);
        return;
      }
      this.loadedAvatarId = activeAvatar.avatarId;
      this.avatarDisplayName = activeAvatar.displayName;
      Logger.info(LOG_TAG, 'loadActiveAvatarScene: avatarId=' + activeAvatar.avatarId.substring(0, 8)
        + ', name=' + activeAvatar.displayName
        + ', isVrm=' + activeAvatar.isVrm
        + ', vrmVersion=' + activeAvatar.vrmVersion
        + ', modelUri=' + activeAvatar.modelUri
        + ', sourceSha256=' + activeAvatar.sourceSha256.substring(0, 8));

      // 释放旧 Scene(若存在)
      this.releaseSceneInternal();

      // 加载新 Scene
      Logger.info(LOG_TAG, 'stateMachine: LoadingAvatar→Scene.load start, uri=' + activeAvatar.modelUri);
      const scene: Scene = await Scene.load(activeAvatar.modelUri);
      if (generation !== this.sceneLoadGeneration) {
        Logger.info(LOG_TAG, 'late callback discarded: scene loaded');
        try {
          scene.destroy();
        } catch (_e) {
          // ignore
        }
        return;
      }
      this.sceneValue = scene;
      Logger.info(LOG_TAG, 'Scene.load returned ok, animations=' + scene.animations.length);

      // 补全相机和灯光
      await this.supplementScene(scene, generation, activeAvatar.modelUri);
      if (generation !== this.sceneLoadGeneration) {
        return;
      }
      // T-4.2E: 读取 Avatar GLB ArrayBuffer(用于建立 nodeIndex→SceneNode 映射)
      try {
        this.avatarGlbBuffer = await this.readAvatarGlbBuffer(activeAvatar.modelUri);
        Logger.info(LOG_TAG, 'loadActiveAvatarScene: avatarGlbBuffer loaded, size='
          + (this.avatarGlbBuffer !== null ? this.avatarGlbBuffer.byteLength : 0));
      } catch (e) {
        Logger.warn(LOG_TAG, 'loadActiveAvatarScene: readAvatarGlbBuffer failed: ' + (e as Error)?.message);
      }
      // 通知 UI Scene 就绪
      Logger.info(LOG_TAG, 'stateMachine: →onSceneReady, sceneValue=' + (this.sceneValue !== null));
      if (this.onSceneReady !== null) {
        this.onSceneReady(scene);
      }
      // T-4.2E: 优先准备 Retarget Controller(外部动作重定向)
      // 若 Avatar 无内置动画,这是唯一播放路径
      const retargetOk: boolean = await this.prepareRetargetController(activeAvatar, generation);
      if (generation !== this.sceneLoadGeneration) {
        return;
      }
      let hasAnimation: boolean = false;
      if (retargetOk) {
        // T-4.2G-A3: Retarget 模式但"不自动播放"。
        // 之前自动 play() 会触发第二轮布局变化和 Surface 重新初始化,导致闪烁。
        // 现在只准备 Controller,进入 Ready 状态,等用户点击播放。
        this.useRetargetMode = true;
        hasAnimation = true;
        Logger.info(LOG_TAG, 'stateMachine: retarget ready (NOT auto-playing, wait for user)');
      } else {
        // 回退:Avatar 自带动画模式也不自动播放
        hasAnimation = this.hasActionClip();
        Logger.info(LOG_TAG, 'stateMachine: builtin clip check, hasAnimation=' + hasAnimation);
      }
      // T-4.2G-A3: 进入 Ready 状态(不自动播放),让 UI 显示模型并等待用户操作
      this.setState(ActionPreview3DState.Ready);
      if (this.onAvatarInfo !== null) {
        this.onAvatarInfo(this.avatarDisplayName, hasAnimation);
      }
      Logger.info(LOG_TAG, 'stateMachine: loadActiveAvatarScene done, hasAnimation=' + hasAnimation
        + ', useRetargetMode=' + this.useRetargetMode + ' (Ready, no auto-play)');
    } catch (e) {
      if (generation !== this.sceneLoadGeneration) {
        return;
      }
      Logger.error(LOG_TAG, 'loadActiveAvatarScene failed: ' + (e as Error)?.message);
      this.fireError('加载 Avatar 失败: ' + (e as Error)?.message);
      this.setState(ActionPreview3DState.Failed);
    }
  }

  /**
   * T-4.2D: 为 Scene 补全相机和灯光(bounds 驱动自动取景)。
   *
   * 修复前:硬编码 camera position = {0, 1.2, 3.0},未设置 enabled/rotation/fov/near/far,
   *        未应用 modelRootNodes transform → 灰屏。
   * 修复后:复用 PoC 已验证的 bounds 驱动取景逻辑:
   *   1. 通过 Character3DService.getModelInfoByUri 获取 GltfModelInfo
   *   2. computeBoundsFromGltf 计算 ModelBounds
   *   3. computeAutoFitDisplayConfig 计算自适应 scale/cameraDistance
   *   4. 收集 modelRootNodes(sceneRoot 下原有 children)
   *   5. 创建 Camera:enabled=true, rotation=identity(看向 -Z), fov/near/far, position=(0,0,camDist)
   *   6. 创建 Light
   *   7. 对 modelRootNodes 应用 transform:position=-center*scale, scale=autoFit.scale
   */
  private async supplementScene(scene: Scene, generation: number, modelUri: string): Promise<void> {
    const factory: SceneResourceFactory = scene.getResourceFactory();
    const sceneRoot: Node | null = scene.root;
    if (sceneRoot === null) {
      Logger.warn(LOG_TAG, 'supplementScene: scene.root is null');
      return;
    }

    // T-4.2D: 1-3. 计算 bounds 和自适应配置
    let bounds: ModelBounds | null = null;
    let autoFit: Character3DDisplayConfig | null = null;
    let modelInfo: GltfModelInfo | null = null;
    if (this.character3DService !== null) {
      try {
        modelInfo = await this.character3DService.getModelInfoByUri(modelUri);
      } catch (e) {
        Logger.warn(LOG_TAG, 'supplementScene: getModelInfoByUri failed: ' + (e as Error)?.message);
      }
    }
    if (modelInfo !== null) {
      bounds = computeBoundsFromGltf(modelInfo);
      if (bounds !== null) {
        autoFit = computeAutoFitDisplayConfig(bounds);
        this.currentBounds = bounds;
        this.currentDisplayConfig = autoFit;
        Logger.info(LOG_TAG, 'supplementScene: bounds computed, center=('
          + bounds.centerX.toFixed(3) + ',' + bounds.centerY.toFixed(3) + ',' + bounds.centerZ.toFixed(3)
          + ') size=(' + bounds.width.toFixed(3) + ',' + bounds.height.toFixed(3) + ',' + bounds.depth.toFixed(3)
          + ') radius=' + bounds.radius.toFixed(3)
          + ', autoFit scale=' + autoFit.scale.toFixed(4)
          + ', camDist=' + autoFit.cameraDistance.toFixed(3));
      } else {
        Logger.warn(LOG_TAG, 'supplementScene: bounds null (no POSITION accessor)');
      }
    } else {
      Logger.warn(LOG_TAG, 'supplementScene: modelInfo null, using default config');
    }

    // T-4.2D: 6. 记录 Renderable 诊断数据
    const childCount: number = sceneRoot.children.count();
    let meshNodeCount: number = 0;
    const modelRootNodes: Node[] = [];
    for (let i: number = 0; i < childCount; i++) {
      const n: Node | null = sceneRoot.children.get(i);
      if (n !== null) {
        modelRootNodes.push(n);
        // 检查是否有 mesh(简化判断)
        try {
          const nName: string = n.name;
          if (nName.length > 0) {
            meshNodeCount++;
          }
        } catch (_e) {
          // ignore
        }
      }
    }
    // T-4.2G-A2: 保存模型根节点列表(用于显示模式切换时控制可见性)
    this.modelRootNodes = modelRootNodes;
    Logger.info(LOG_TAG, 'supplementScene: sceneRoot childrenCount=' + childCount
      + ', modelRootNodes=' + modelRootNodes.length
      + ', meshCount=' + (modelInfo !== null ? modelInfo.meshCount : -1)
      + ', nodeCount=' + (modelInfo !== null ? modelInfo.nodeCount : -1)
      + ', hasSkins=' + (modelInfo !== null ? modelInfo.hasSkins : false));

    // T-4.2D: 7. 创建 Camera(关键:enabled=true, rotation=identity)
    Logger.info(LOG_TAG, 'supplementScene: creating camera');
    const cameraParams: SceneNodeParameters = { name: 'previewCamera' };
    const camera: Camera = await factory.createCamera(cameraParams);
    if (generation !== this.sceneLoadGeneration) {
      return;
    }
    // 计算 camera distance(优先使用 autoFit,回退默认值)
    const camDist: number = autoFit !== null ? autoFit.cameraDistance : 3.0;
    const camScale: number = autoFit !== null ? autoFit.scale : 1.0;
    // T-4.2G-A2 修复: 调整相机配置顺序,与 PoC applyCameraFit 保持一致
    // 必须先配置 position/fov/near/far,最后才设置 enabled=true 和 rotation
    // 否则 camera 在 enabled=true 时使用默认视锥体渲染,可能导致模型不可见
    try {
      // 步骤 1: 配置 position
      camera.position = { x: 0, y: 0, z: camDist } as Position3;
      // 步骤 2: 配置 fov
      camera.fov = PREVIEW_CAMERA_FOV;
      // 步骤 3: 动态 near/far(参考 PoC computeDynamicNearFar)
      const scaledRadius: number = bounds !== null ? bounds.radius * camScale : 1.0;
      const near: number = Math.max(0.05, camDist - scaledRadius * 1.5);
      const far: number = camDist + scaledRadius * 4.0;
      camera.nearPlane = near;
      camera.farPlane = far;
      // 步骤 4: 最后启用 camera(SDK 默认 false,不启用就是空白)
      camera.enabled = true;
      // 步骤 5: 设置朝向四元数为单位四元数,使 Camera 看向 -Z 方向
      camera.rotation = { x: 0, y: 0, z: 0, w: 1 } as Quaternion;
      Logger.info(LOG_TAG, 'supplementScene: camera configured, enabled=true'
        + ', pos=(0,0,' + camDist.toFixed(3) + ')'
        + ', fov=' + PREVIEW_CAMERA_FOV
        + ', near=' + near.toFixed(3)
        + ', far=' + far.toFixed(3));
    } catch (e) {
      Logger.error(LOG_TAG, 'supplementScene: camera config failed: ' + (e as Error)?.message);
    }
    try {
      sceneRoot.children.append(camera);
      Logger.info(LOG_TAG, 'supplementScene: camera appended to sceneRoot');
    } catch (e) {
      Logger.warn(LOG_TAG, 'supplementScene: append camera failed: ' + (e as Error)?.message);
    }

    // T-4.2D: 8. 创建 Light
    Logger.info(LOG_TAG, 'supplementScene: creating light');
    const lightParams: SceneNodeParameters = { name: 'previewLight' };
    const light: Light = await factory.createLight(lightParams, LightType.DIRECTIONAL);
    if (generation !== this.sceneLoadGeneration) {
      return;
    }
    try {
      light.position = { x: 2, y: 5, z: 3 } as Position3;
      light.intensity = PREVIEW_LIGHT_INTENSITY;
      light.shadowEnabled = false;
    } catch (e) {
      Logger.warn(LOG_TAG, 'supplementScene: light config failed: ' + (e as Error)?.message);
    }
    try {
      sceneRoot.children.append(light);
      Logger.info(LOG_TAG, 'supplementScene: light appended to sceneRoot');
    } catch (e) {
      Logger.warn(LOG_TAG, 'supplementScene: append light failed: ' + (e as Error)?.message);
    }

    // T-4.2D: 9. 对 modelRootNodes 应用 transform(让模型中心移到原点,scale 适配视口)
    // 关键修复 5: 不应用 transform 的话,模型可能不在原点,scale 可能异常
    if (modelRootNodes.length > 0 && autoFit !== null && bounds !== null) {
      const scale: number = autoFit.scale;
      // 模型中心应用 scale 后的位置 = center * scale
      // 要让模型中心移到原点:node.position = -center * scale
      const posX: number = -bounds.centerX * scale;
      const posY: number = -bounds.centerY * scale;
      const posZ: number = -bounds.centerZ * scale;
      const posFinal: Position3 = { x: posX, y: posY, z: posZ };
      const scaleFinal: Position3 = { x: scale, y: scale, z: scale };
      const rotFinal: Quaternion = { x: 0, y: 0, z: 0, w: 1 };
      let appliedCount: number = 0;
      for (let i: number = 0; i < modelRootNodes.length; i++) {
        try {
          modelRootNodes[i].position = posFinal;
          modelRootNodes[i].rotation = rotFinal;
          modelRootNodes[i].scale = scaleFinal;
          appliedCount++;
        } catch (e) {
          Logger.warn(LOG_TAG, 'supplementScene: apply transform node[' + i + '] failed: '
            + (e as Error)?.message);
        }
      }
      Logger.info(LOG_TAG, 'supplementScene: transform applied, count=' + appliedCount
        + '/' + modelRootNodes.length
        + ', scale=' + scale.toFixed(4)
        + ', pos=(' + posX.toFixed(3) + ',' + posY.toFixed(3) + ',' + posZ.toFixed(3) + ')');
    } else if (modelRootNodes.length > 0 && (autoFit === null || bounds === null)) {
      Logger.warn(LOG_TAG, 'supplementScene: bounds/autoFit null, modelRootNodes transform skipped');
    }

    // T-4.2G-A2 关键修复: 模型 transform 应用后,重新更新相机 position/fov/near/far
    // 与 PoC applyDisplayConfigToScene 保持一致:在 camera append 之后,
    // 且模型 transform 完成后,再次更新相机参数确保渲染正确
    // 否则 camera 可能使用旧的视锥体参数导致模型被裁剪
    try {
      camera.position = { x: 0, y: 0, z: camDist } as Position3;
      camera.fov = PREVIEW_CAMERA_FOV;
      const scaledRadius2: number = bounds !== null ? bounds.radius * camScale : 1.0;
      const near2: number = Math.max(0.05, camDist - scaledRadius2 * 1.5);
      const far2: number = camDist + scaledRadius2 * 4.0;
      camera.nearPlane = near2;
      camera.farPlane = far2;
      Logger.info(LOG_TAG, 'supplementScene: camera re-configured after model transform'
        + ', pos=(0,0,' + camDist.toFixed(3) + ')'
        + ', near=' + near2.toFixed(3)
        + ', far=' + far2.toFixed(3));
    } catch (e) {
      Logger.warn(LOG_TAG, 'supplementScene: camera re-config failed: ' + (e as Error)?.message);
    }

    Logger.info(LOG_TAG, 'supplementScene: done');
  }

  /**
   * 尝试播放动作对应的 Clip。
   *
   * 策略:
   * 1. 优先按 clipIndex 匹配 Avatar Scene 的 animations[clipIndex]
   * 2. clipIndex 无效时回退到 animations[0]
   * 3. Avatar 无动画时进入 StaticOnly 状态
   *
   * @returns true 表示找到并开始播放动画;false 表示无动画
   */
  private tryPlayActionClip(): boolean {
    if (this.sceneValue === null) {
      return false;
    }
    const animations: Animation[] = this.sceneValue.animations;
    if (animations.length === 0) {
      Logger.info(LOG_TAG, 'tryPlayActionClip: Avatar has no animations, static preview');
      this.setState(ActionPreview3DState.StaticOnly);
      return false;
    }
    // 停止旧动画
    this.stopInternal();

    // 优先按 clipIndex 选择
    let targetIndex: number = -1;
    if (this.currentAction !== null
      && this.currentAction.clipIndex >= 0
      && this.currentAction.clipIndex < animations.length) {
      targetIndex = this.currentAction.clipIndex;
    } else {
      // 回退到第一个动画
      targetIndex = 0;
    }
    try {
      const anim: Animation = animations[targetIndex];
      anim.enabled = true;
      anim.start();
      this.currentAnimation = anim;
      this.setState(ActionPreview3DState.Playing);
      Logger.info(LOG_TAG, 'tryPlayActionClip: playing anim[' + targetIndex + ']'
        + ', total=' + animations.length);
      return true;
    } catch (e) {
      Logger.error(LOG_TAG, 'tryPlayActionClip failed: ' + (e as Error)?.message);
      this.setState(ActionPreview3DState.StaticOnly);
      return false;
    }
  }

  /**
   * T-4.2G-A3: 检查 Avatar 是否有可播放的内置动画(只检查,不播放)。
   *
   * 用于 Scene 加载完成后只进入 Ready 状态,不自动播放。
   * 用户点击播放按钮时才真正调用 tryPlayActionClip 启动动画。
   */
  private hasActionClip(): boolean {
    if (this.sceneValue === null) {
      return false;
    }
    const animations: Animation[] = this.sceneValue.animations;
    return animations.length > 0;
  }

  /**
   * 释放当前 Scene(内部方法,不修改状态)。
   */
  private releaseSceneInternal(): void {
    this.stopInternal();
    this.currentAnimation = null;
    // T-4.2G-A2: 清理 Skeleton Controller 引用(Scene 即将销毁,几何随之释放)
    this.skeletonController = null;
    this.modelRootNodes = [];
    this.restPoseClassification = null;
    if (this.sceneValue !== null) {
      try {
        this.sceneValue.destroy();
      } catch (_e) {
        // ignore
      }
      this.sceneValue = null;
    }
  }

  /**
   * 设置状态并通知 UI。
   */
  private setState(state: ActionPreview3DState): void {
    this.stateValue = state;
    if (this.onStateChanged !== null) {
      this.onStateChanged(state);
    }
  }

  /**
   * 触发错误回调。
   */
  private fireError(message: string): void {
    if (this.onError !== null) {
      this.onError(message);
    }
  }

  // ==================== T-4.2E: Retarget Controller 准备 ====================

  /**
   * T-4.2E: 读取 Avatar GLB 文件为 ArrayBuffer(用于建立 nodeIndex→SceneNode 映射)。
   *
   * @param modelUri 模型 URI(file:// 开头)
   * @returns ArrayBuffer 或 null
   */
  private async readAvatarGlbBuffer(modelUri: string): Promise<ArrayBuffer | null> {
    try {
      let path: string = modelUri;
      if (path.startsWith('file://')) {
        path = path.substring('file://'.length);
      }
      const file: fileIo.File = fileIo.openSync(path, fileIo.OpenMode.READ_ONLY);
      try {
        const stat: fileIo.Stat = fileIo.statSync(file.fd);
        const size: number = stat.size;
        const buffer: ArrayBuffer = new ArrayBuffer(size);
        fileIo.readSync(file.fd, buffer);
        return buffer;
      } finally {
        fileIo.closeSync(file);
      }
    } catch (e) {
      Logger.warn(LOG_TAG, 'readAvatarGlbBuffer failed: ' + (e as Error)?.message);
      return null;
    }
  }

  /**
   * T-4.2E: 读取内置动作包 GLB 为 ArrayBuffer(带缓存)。
   *
   * @returns ArrayBuffer 或 null
   */
  private async readActionPackBuffer(): Promise<ArrayBuffer | null> {
    if (this.actionPackBuffer !== null) {
      return this.actionPackBuffer;
    }
    if (this.appContext === null) {
      Logger.error(LOG_TAG, 'readActionPackBuffer: appContext null');
      return null;
    }
    try {
      const rawfilePath: string = BUILTIN_ACTION_RAWFILE_DIR + '/' + BUILTIN_PACK_FILE_NAME;
      Logger.info(LOG_TAG, 'readActionPackBuffer: reading rawfile: ' + rawfilePath);
      const data: Uint8Array = await this.appContext.resourceManager.getRawFileContent(rawfilePath);
      const ab: ArrayBuffer = new ArrayBuffer(data.byteLength);
      const view: Uint8Array = new Uint8Array(ab);
      view.set(data);
      this.actionPackBuffer = ab;
      Logger.info(LOG_TAG, 'readActionPackBuffer: ok, size=' + ab.byteLength);
      return ab;
    } catch (e) {
      Logger.error(LOG_TAG, 'readActionPackBuffer failed: ' + (e as Error)?.message);
      return null;
    }
  }

  /**
   * T-4.2E: 直接从 GLB Buffer 解析 VRM 资产(不依赖 sourceSha256 持久化)。
   *
   * 流程:
   * 1. parseGlb 获取 glTF JSON + BIN chunk
   * 2. GltfValidator 提取 nodeNames 等 modelInfo
   * 3. detectVrm 检测 VRM 扩展
   * 4. importVrm 解析 VRM 资产(meta/humanoid/expressions/lookAt/springBone)
   *
   * @param glbBuffer Avatar GLB ArrayBuffer
   * @returns VrmAsset 或 null(非 VRM 或解析失败)
   */
  private parseVrmFromGlbBuffer(glbBuffer: ArrayBuffer): VrmAsset | null {
    try {
      // 1. 验证 GLB 并提取 modelInfo(含 nodeNames)
      const validationResult = GltfValidator.validate(glbBuffer);
      if (!validationResult.valid || validationResult.gltfJson === null) {
        Logger.warn(LOG_TAG, 'parseVrmFromGlbBuffer: GLB validation failed: ' + validationResult.errorMessage);
        return null;
      }
      const gltfJson: Record<string, Object> = validationResult.gltfJson;
      const modelInfo = validationResult.modelInfo;

      // 2. 检测 VRM 扩展
      const detection = detectVrm(gltfJson);
      if (!detection.isVrm) {
        Logger.warn(LOG_TAG, 'parseVrmFromGlbBuffer: not a VRM file');
        return null;
      }
      Logger.info(LOG_TAG, 'parseVrmFromGlbBuffer: VRM detected, version=' + detection.version
        + ', specVersion=' + detection.specVersion);

      // 3. 导入 VRM 资产
      const vrmResult = importVrm({
        gltfJson: gltfJson,
        sourceSha256: '',
        nodeNames: modelInfo.nodeNames,
        nodeCount: modelInfo.nodeCount,
        meshCount: modelInfo.meshCount,
        materialCount: modelInfo.materialCount,
        imageCount: 0
      });
      if (!vrmResult.isVrm || !vrmResult.asset.valid) {
        Logger.warn(LOG_TAG, 'parseVrmFromGlbBuffer: VRM import failed: ' + vrmResult.error);
        return null;
      }
      Logger.info(LOG_TAG, 'parseVrmFromGlbBuffer: VRM parsed ok, humanoid.bones='
        + vrmResult.asset.humanoid.bones.length
        + ', valid=' + vrmResult.asset.humanoid.valid);
      return vrmResult.asset;
    } catch (e) {
      Logger.error(LOG_TAG, 'parseVrmFromGlbBuffer exception: ' + (e as Error)?.message);
      return null;
    }
  }

  /**
   * T-4.2E: 准备 Retarget Controller(外部动作重定向)。
   *
   * 流程:
   * 1. 读取动作包 GLB → ArrayBuffer
   * 2. 解析指定名称的动画 → HumanoidMotionClip
   * 3. 解析源 Rest Pose(动作包 nodes 默认 TRS)
   * 4. 直接从 avatarGlbBuffer 解析 VRM 资产(不依赖 sourceSha256 持久化)
   *    - parseGlb + detectVrm + importVrm → VrmAsset.humanoid
   * 5. 建立 nodeIndex→SceneNode 映射(collectSceneNodes)
   * 6. 收集目标 Rest Pose(collectTargetRestPose)
   * 7. 创建 RetargetPlaybackConfig 并 prepare
   *
   * @param activeAvatar 当前激活 Avatar
   * @param generation 加载代际(防止旧回调)
   * @returns true 表示准备成功;false 表示失败(已设置 Failed 状态)
   */
  private async prepareRetargetController(
    activeAvatar: AvatarRecord,
    generation: number
  ): Promise<boolean> {
    if (this.sceneValue === null) {
      Logger.warn(LOG_TAG, 'prepareRetargetController: scene is null');
      return false;
    }
    if (this.currentAction === null) {
      Logger.warn(LOG_TAG, 'prepareRetargetController: currentAction is null');
      return false;
    }

    this.setState(ActionPreview3DState.LoadingMotion);
    if (this.onPrepareProgress !== null) {
      this.onPrepareProgress('正在加载动作资源……');
    }

    // 1. 读取动作包
    const actionPackBuf: ArrayBuffer | null = await this.readActionPackBuffer();
    if (generation !== this.sceneLoadGeneration) {
      return false;
    }
    if (actionPackBuf === null) {
      this.fireError('动作包不存在或读取失败');
      this.setState(ActionPreview3DState.Failed);
      return false;
    }

    // 2. 解析动画 Clip
    const clipName: string = this.currentAction.clipName;
    const clipId: string = this.currentAction.actionId;
    const loop: boolean = this.currentAction.loop;
    Logger.info(LOG_TAG, 'prepareRetargetController: parsing clip="' + clipName + '", loop=' + loop);
    const parseResult: AnimationDataParseResult = parseAnimationByName(actionPackBuf, clipName, clipId, loop);
    if (!parseResult.success || parseResult.clip === null) {
      this.fireError('动作解析失败: ' + parseResult.errorMessage);
      this.setState(ActionPreview3DState.Failed);
      return false;
    }
    const clip: HumanoidMotionClip = parseResult.clip;
    if (generation !== this.sceneLoadGeneration) {
      return false;
    }

    // 检查是否有 CUBICSPLINE 警告
    const hasCubicSpline: boolean = clip.warnings.some((w: string): boolean => w.indexOf('CUBICSPLINE') >= 0);
    if (hasCubicSpline) {
      Logger.warn(LOG_TAG, 'prepareRetargetController: clip contains CUBICSPLINE (unsupported), may not animate correctly');
    }

    // 3. 解析源 Rest Pose
    if (this.onPrepareProgress !== null) {
      this.onPrepareProgress('正在解析动作骨架……');
    }
    const sourceRestResult: SourceRestPoseParseResult = parseSourceRestPose(actionPackBuf);
    if (!sourceRestResult.success || sourceRestResult.restPose === null) {
      this.fireError('源骨架 Rest Pose 解析失败: ' + sourceRestResult.errorMessage);
      this.setState(ActionPreview3DState.Failed);
      return false;
    }
    if (generation !== this.sceneLoadGeneration) {
      return false;
    }

    // 4. 获取目标 VRM HumanoidProvider
    this.setState(ActionPreview3DState.PreparingRetarget);
    if (this.onPrepareProgress !== null) {
      this.onPrepareProgress('正在建立骨骼映射……');
    }
    if (!activeAvatar.isVrm) {
      // 非 VRM 模型暂不支持重定向(需要手动映射)
      Logger.warn(LOG_TAG, 'prepareRetargetController: non-VRM avatar, retarget not supported');
      this.fireError('非 VRM 模型暂不支持动作重定向');
      this.setState(ActionPreview3DState.Failed);
      return false;
    }

    // T-4.2E: 直接从 Avatar GLB Buffer 解析 VRM(不依赖 sourceSha256 持久化)
    // 旧实现:const vrmAsset = await this.character3DService.getVrmAsset(activeAvatar.sourceSha256);
    // 问题:旧 Avatar 记录可能 sourceSha256 为空,导致 getVrmAsset 返回 null
    // 新实现:直接读取 avatarGlbBuffer,调用 parseGlb + detectVrm + importVrm
    if (this.avatarGlbBuffer === null) {
      this.fireError('Avatar GLB 缓冲区为空,无法解析 VRM');
      this.setState(ActionPreview3DState.Failed);
      return false;
    }
    const vrmAsset: VrmAsset | null = this.parseVrmFromGlbBuffer(this.avatarGlbBuffer);
    if (generation !== this.sceneLoadGeneration) {
      return false;
    }
    if (vrmAsset === null) {
      this.fireError('VRM 资产解析失败(非 VRM 文件或解析错误)');
      this.setState(ActionPreview3DState.Failed);
      return false;
    }
    if (!vrmAsset.humanoid.valid) {
      this.fireError('VRM Humanoid 映射无效(声明骨骼数=' + vrmAsset.humanoid.bones.length + ')');
      this.setState(ActionPreview3DState.Failed);
      return false;
    }

    // 构建 HumanoidProvider(VRM 显式映射)
    const providerInput: HumanoidProviderInput = {
      vrmHumanoid: vrmAsset.humanoid,
      manualMapping: null,
      autoMapping: null
    };
    const provider: HumanoidProvider = new HumanoidProvider(providerInput);
    Logger.info(LOG_TAG, 'prepareRetargetController: HumanoidProvider built, source='
      + (provider.getPrimarySource())
      + ', mapped=' + provider.getMappedCount()
      + ', required=' + provider.getRequiredMappedCount());

    // 5. 建立 nodeIndex→SceneNode 映射(avatarGlbBuffer 已在步骤 4 验证非空)
    const glbBuf: ArrayBuffer = this.avatarGlbBuffer as ArrayBuffer;
    const sceneNodeResult: SceneNodeCollectResult = collectSceneNodes(this.sceneValue, glbBuf);
    if (!sceneNodeResult.success) {
      this.fireError('SceneNode 索引失败: ' + sceneNodeResult.errorMessage);
      this.setState(ActionPreview3DState.Failed);
      return false;
    }
    if (generation !== this.sceneLoadGeneration) {
      return false;
    }
    Logger.info(LOG_TAG, 'prepareRetargetController: scene nodes collected, matched='
      + sceneNodeResult.nodeIndexMap.size + '/' + sceneNodeResult.totalNodes);

    // 6. 收集目标 Rest Pose
    const targetRestResult: TargetRestPoseCollectResult = collectTargetRestPose(provider, sceneNodeResult.nodeIndexMap);
    if (targetRestResult.missingRequired.length > 0) {
      const missingNames: string = targetRestResult.missingRequired.join(', ');
      this.fireError('目标 VRM 骨架缺失必需骨骼: ' + missingNames);
      this.setState(ActionPreview3DState.Failed);
      return false;
    }
    if (generation !== this.sceneLoadGeneration) {
      return false;
    }
    Logger.info(LOG_TAG, 'prepareRetargetController: target rest pose collected, bones='
      + targetRestResult.collectedCount + ', missing=' + targetRestResult.missingBones.length);

    // T-4.2F: 计算源骨架每根骨骼的 rest 世界旋转(用于父空间 delta 转换)
    // 解决 source(A Pose)与 target(T Pose)局部坐标系差异导致的手臂弯曲方向错误
    const sourceWorldRestMap: Map<HumanoidBone, QuaternionValue> = computeWorldRestRotations(sourceRestResult.restPose);
    Logger.info(LOG_TAG, 'prepareRetargetController: source world rest map computed, size=' + sourceWorldRestMap.size);

    // T-4.2F: 输出手臂链映射诊断日志
    this.logArmMappingInfo(clip, targetRestResult, provider);

    // T-4.2G-A: 输出关键骨骼 Rest Pose 诊断(确认 T Pose vs A Pose vs 双臂下垂)
    this.logRestPoseDiagnostics(sourceRestResult.restPose, targetRestResult.restPose);

    // T-4.2G-A: 对比 GLB nodes 原始 TRS 与 SceneNode.rotation,确认是否一致
    if (this.avatarGlbBuffer !== null) {
      this.logGlbNodeRestPose(this.avatarGlbBuffer, vrmAsset);
    }

    // T-4.2G: 加载或分析方向校准
    // 优先级:Manual Override → Cached Auto Result → New Auto Analysis → Safe Default
    const calibration: AvatarOrientationCalibration | null = await this.loadOrAnalyzeCalibration(
      activeAvatar,
      sourceRestResult.restPose,
      targetRestResult.restPose
    );
    if (generation !== this.sceneLoadGeneration) {
      return false;
    }

    // 7. 创建并准备 Retarget Controller
    // 释放旧 Controller
    if (this.retargetController !== null) {
      try {
        this.retargetController.dispose();
      } catch (_e) {
        // ignore
      }
      this.retargetController = null;
    }

    const config: RetargetPlaybackConfig = {
      clip: clip,
      sourceRestPose: sourceRestResult.restPose,
      targetRestPose: targetRestResult.restPose,
      boneNodeMap: targetRestResult.boneNodeMap,
      rootMotionMode: RootMotionMode.HipsOnly,
      speed: 1.0,
      sourceWorldRestMap: sourceWorldRestMap,
      calibration: calibration
    };

    const controller: HumanoidRetargetPlaybackController = new HumanoidRetargetPlaybackController();
    // 连接状态回调
    controller.onStateChanged = (state: RetargetPlaybackState): void => {
      this.onRetargetStateChanged(state);
    };
    controller.onError = (message: string): void => {
      this.fireError('重定向播放错误: ' + message);
    };

    const prepareResult = controller.prepare(config);
    if (!prepareResult.success) {
      this.fireError('重定向准备失败: ' + prepareResult.errorMessage);
      this.setState(ActionPreview3DState.Failed);
      return false;
    }

    this.retargetController = controller;

    // T-4.2G-A2: 创建并挂载 Target Avatar Skeleton Controller
    // 必须在 retargetController.prepare 成功后,确保 boneNodeMap 中的 Node 已就绪
    await this.attachSkeletonController(
      targetRestResult.boneNodeMap,
      targetRestResult.restPose
    );
    if (generation !== this.sceneLoadGeneration) {
      return false;
    }

    // T-4.2G-A4: 保存诊断引用(用于 Source/Target 对比诊断)
    this.currentClip = clip;
    this.currentSourceRestPose = sourceRestResult.restPose;
    this.currentTargetRestPose = targetRestResult.restPose;
    this.currentBoneNodeMap = targetRestResult.boneNodeMap;

    // T-4.2G-A4: 创建并挂载 Source/Target 三栏对比可视化(默认隐藏)
    await this.attachCompareSkeleton(
      clip,
      sourceRestResult.restPose,
      targetRestResult.boneNodeMap
    );

    // T-4.2G-A2: 连接帧回调(每帧 retarget 写入 SceneNode 后刷新骨架)
    controller.onFrameApplied = (): void => {
      if (this.skeletonController !== null) {
        this.skeletonController.updateFrame();
      }
      // T-4.2G-A4: 同步刷新三栏对比可视化
      if (this.compareSkeleton !== null && this.compareSkeleton.isEnabled()) {
        const currentTime: number = controller.getCurrentTime();
        this.compareSkeleton.updateFrame(currentTime);
      }
    };
    // T-4.2G-A2: 连接停止回调(停止后恢复 Rest Pose 时同步刷新骨架)
    controller.onStopped = (): void => {
      if (this.skeletonController !== null) {
        this.skeletonController.restoreRestPose();
      }
      // T-4.2G-A4: 停止时刷新三栏(Source Animated 回到 t=0)
      if (this.compareSkeleton !== null && this.compareSkeleton.isEnabled()) {
        this.compareSkeleton.updateFrame(0);
      }
    };

    Logger.info(LOG_TAG, 'prepareRetargetController: success, clip=' + clip.name
      + ', duration=' + clip.durationSeconds.toFixed(3)
      + ', tracks=' + clip.tracks.length
      + ', targetBones=' + targetRestResult.collectedCount);
    return true;
  }

  /**
   * T-4.2G-A4: 创建并挂载 Source/Target 三栏对比可视化控制器。
   *
   * 默认隐藏,仅 setSourceTargetCompareMode(true) 时显示。
   *
   * @param clip 当前动作 clip
   * @param sourceRestPose Source Rest Pose
   * @param boneNodeMap Target boneNodeMap
   */
  private async attachCompareSkeleton(
    clip: HumanoidMotionClip,
    sourceRestPose: HumanoidRestPose,
    boneNodeMap: Map<HumanoidBone, Node>
  ): Promise<void> {
    // 释放旧 compareSkeleton
    if (this.compareSkeleton !== null) {
      try {
        this.compareSkeleton.detach();
      } catch (_e) {
        // ignore
      }
      this.compareSkeleton = null;
    }

    if (this.sceneValue === null) {
      Logger.warn(LOG_TAG, 'attachCompareSkeleton: scene is null, skip');
      return;
    }

    // 计算模型高度
    let modelHeight: number = 1.7;
    if (this.currentBounds !== null) {
      modelHeight = this.currentBounds.height;
    }

    const compare: SourceTargetCompareSkeleton = new SourceTargetCompareSkeleton();
    try {
      await compare.attach(this.sceneValue, clip, sourceRestPose, boneNodeMap, modelHeight);
      this.compareSkeleton = compare;
      Logger.info(LOG_TAG, 'attachCompareSkeleton: attached');
    } catch (e) {
      Logger.error(LOG_TAG, 'attachCompareSkeleton failed: ' + (e as Error)?.message);
      this.compareSkeleton = null;
    }
  }

  /**
   * T-4.2G-A2: 创建并挂载 Target Avatar Skeleton Controller。
   *
   * 流程:
   * 1. 释放旧 SkeletonController(若存在)
   * 2. 计算模型高度(从 currentBounds)
   * 3. 创建新 SkeletonController 并 attach 到当前 Scene
   * 4. 使用 World Position 分类 Rest Pose
   * 5. 应用当前显示模式可见性
   * 6. 通知 UI 骨架信息
   *
   * @param boneNodeMap 目标骨骼→SceneNode 映射
   * @param targetRestPose 目标 Rest Pose
   */
  private async attachSkeletonController(
    boneNodeMap: Map<HumanoidBone, Node>,
    targetRestPose: HumanoidRestPose
  ): Promise<void> {
    // 1. 释放旧 SkeletonController
    if (this.skeletonController !== null) {
      try {
        await this.skeletonController.dispose();
      } catch (_e) {
        // ignore
      }
      this.skeletonController = null;
    }

    if (this.sceneValue === null) {
      Logger.warn(LOG_TAG, 'attachSkeletonController: scene is null, skip');
      return;
    }

    // 2. 计算模型高度(从 currentBounds)
    let modelHeight: number = 1.7;
    if (this.currentBounds !== null) {
      modelHeight = this.currentBounds.height;
    }

    // 3. 创建并 attach
    const skeleton: TargetAvatarSkeletonController = new TargetAvatarSkeletonController();
    try {
      await skeleton.attach(this.sceneValue, boneNodeMap, targetRestPose, modelHeight);
      this.skeletonController = skeleton;
      Logger.info(LOG_TAG, 'attachSkeletonController: attached, joints=' + skeleton.getJointCount()
        + ', segments=' + skeleton.getSegmentCount());
    } catch (e) {
      Logger.error(LOG_TAG, 'attachSkeletonController failed: ' + (e as Error)?.message);
      this.skeletonController = null;
      return;
    }

    // 4. 分类 Rest Pose(基于 World Position)
    try {
      const worldPositions: Map<HumanoidBone, Vector3Value> = skeleton.getWorldPositions();
      this.restPoseClassification = classifyRestPose(worldPositions);
      Logger.info(LOG_TAG, 'attachSkeletonController: pose classified, type='
        + this.restPoseClassification.type
        + ', avgAngle=' + this.restPoseClassification.avgArmAngleDeg.toFixed(1)
        + ', confidence=' + this.restPoseClassification.confidence.toFixed(2));
      // T-4.2G-A2: 真实 Target Rest Pose 验证(基于世界方向向量)
      // 输出 T Pose 三项特征:
      //   - 左右手臂接近水平(armDir.y ≈ 0)
      //   - 手臂方向与 bodyUp 近似垂直(dot(armDir, bodyUp) ≈ 0)
      //   - 左右手臂方向互相相反(dot(leftArmDir, rightArmDir) ≈ -1)
      this.logTPoseVerification(worldPositions);
    } catch (e) {
      Logger.warn(LOG_TAG, 'attachSkeletonController: classifyRestPose failed: ' + (e as Error)?.message);
      this.restPoseClassification = null;
    }

    // 5. 应用当前显示模式可见性
    this.applyDisplayModeVisibility();

    // 6. 通知 UI 骨架信息
    if (this.onSkeletonInfo !== null) {
      const info = this.getSkeletonInfo();
      this.onSkeletonInfo(info.joints, info.segments, info.poseType,
        info.confidence, info.message);
    }
  }

  /**
   * T-4.2G-A2: 真实 Target Rest Pose 验证(基于世界方向向量)。
   *
   * 不再使用人工构造的 ±90° 作为唯一依据,改为输出 T Pose 三项特征:
   * - 左右手臂接近水平(armDir.y 绝对值小)
   * - 手臂方向与 bodyUp 近似垂直(夹角接近 90°)
   * - 左右手臂方向互相相反(dot(leftArmDir, rightArmDir) ≈ -1)
   *
   * 注意:姿态分类仅用于诊断,目标骨架仍必须使用真实节点位置,
   * 不允许根据分类生成固定姿势。
   */
  private logTPoseVerification(worldPositions: Map<HumanoidBone, Vector3Value>): void {
    const hips: Vector3Value | undefined = worldPositions.get(HumanoidBone.Hips);
    const chest: Vector3Value | undefined = worldPositions.get(HumanoidBone.Chest);
    const head: Vector3Value | undefined = worldPositions.get(HumanoidBone.Head);
    const leftShoulder: Vector3Value | undefined = worldPositions.get(HumanoidBone.LeftShoulder);
    const rightShoulder: Vector3Value | undefined = worldPositions.get(HumanoidBone.RightShoulder);
    const leftHand: Vector3Value | undefined = worldPositions.get(HumanoidBone.LeftHand);
    const rightHand: Vector3Value | undefined = worldPositions.get(HumanoidBone.RightHand);
    if (hips === undefined || chest === undefined || head === undefined) {
      Logger.warn(LOG_TAG, 'logTPoseVerification: Hips/Chest/Head missing, skip');
      return;
    }
    const bodyUp: Vector3Value = vectorNormalize(vectorSubtract(head, hips));
    const fmt: (v: Vector3Value) => string = (v: Vector3Value): string => {
      return '(' + v.x.toFixed(3) + ',' + v.y.toFixed(3) + ',' + v.z.toFixed(3) + ')';
    };
    let msg: string = 'TPose verify: bodyUp=' + fmt(bodyUp);
    if (leftShoulder !== undefined && leftHand !== undefined) {
      const leftDir: Vector3Value = vectorNormalize(vectorSubtract(leftHand, leftShoulder));
      const leftDotUp: number = vectorDot(leftDir, bodyUp);
      msg += ' | leftDir=' + fmt(leftDir)
        + ' dot(bodyUp)=' + leftDotUp.toFixed(3)
        + ' angle=' + (Math.acos(Math.max(-1, Math.min(1, leftDotUp))) * 180 / Math.PI).toFixed(1) + '°';
    } else {
      msg += ' | leftArm: missing';
    }
    if (rightShoulder !== undefined && rightHand !== undefined) {
      const rightDir: Vector3Value = vectorNormalize(vectorSubtract(rightHand, rightShoulder));
      const rightDotUp: number = vectorDot(rightDir, bodyUp);
      msg += ' | rightDir=' + fmt(rightDir)
        + ' dot(bodyUp)=' + rightDotUp.toFixed(3)
        + ' angle=' + (Math.acos(Math.max(-1, Math.min(1, rightDotUp))) * 180 / Math.PI).toFixed(1) + '°';
    } else {
      msg += ' | rightArm: missing';
    }
    if (leftShoulder !== undefined && leftHand !== undefined
      && rightShoulder !== undefined && rightHand !== undefined) {
      const leftDir2: Vector3Value = vectorNormalize(vectorSubtract(leftHand, leftShoulder));
      const rightDir2: Vector3Value = vectorNormalize(vectorSubtract(rightHand, rightShoulder));
      const leftRightDot: number = vectorDot(leftDir2, rightDir2);
      msg += ' | dot(leftDir,rightDir)=' + leftRightDot.toFixed(3)
        + (leftRightDot < -0.7 ? ' (T Pose: arms opposite)' : '');
    }
    Logger.info(LOG_TAG, msg);
  }

  /**
   * T-4.2E: Retarget Controller 状态变更回调。
   *
   * 将 RetargetPlaybackState 映射到 ActionPreview3DState。
   */
  private onRetargetStateChanged(retargetState: RetargetPlaybackState): void {
    if (this.disposed) {
      return;
    }
    switch (retargetState) {
      case RetargetPlaybackState.Ready:
        this.setState(ActionPreview3DState.Ready);
        break;
      case RetargetPlaybackState.Playing:
        this.setState(ActionPreview3DState.Playing);
        break;
      case RetargetPlaybackState.Paused:
        this.setState(ActionPreview3DState.Paused);
        break;
      case RetargetPlaybackState.Stopped:
        // 停止后恢复到 Ready(可重新播放)
        this.setState(ActionPreview3DState.Ready);
        break;
      case RetargetPlaybackState.Failed:
        this.setState(ActionPreview3DState.Failed);
        break;
      default:
        // Idle / Preparing / Disposed 不改变 ViewModel 状态
        break;
    }
  }

  // T-4.2E-Closeout: 单骨骼运行时写入测试代码已删除(SceneNode.rotation 写入已验证有效)

  // ==================== T-4.2G: Orientation Calibration ====================

  /**
   * T-4.2G: 加载或分析方向校准。
   *
   * 优先级:
   *   1. Manual Override(已保存且 isManualOverride=true):直接使用
   *   2. Cached Auto Result(已保存且 sha 匹配):使用缓存,但仍可被手动覆盖
   *   3. New Auto Analysis(未保存或 sha 不匹配):运行 analyzeOrientation
   *   4. Safe Default(分析失败或异常):createDefaultCalibration(Normal)
   *
   * 副作用:
   * - 设置 this.currentCalibration
   * - 设置 this.lastAnalysis(若执行了新分析)
   * - 触发 onCalibrationChanged 回调
   * - 新分析结果会持久化到 Store(若 store 可用)
   *
   * @param activeAvatar 当前 Avatar
   * @param sourceRestPose 源骨架 Rest Pose
   * @param targetRestPose 目标骨架 Rest Pose
   * @returns 校准数据(可为 null 表示 Store 未注入且分析失败,使用安全默认值)
   */
  private async loadOrAnalyzeCalibration(
    activeAvatar: AvatarRecord,
    sourceRestPose: HumanoidRestPose,
    targetRestPose: HumanoidRestPose
  ): Promise<AvatarOrientationCalibration | null> {
    const avatarId: string = activeAvatar.avatarId;
    const sourceSha256: string = activeAvatar.sourceSha256;

    // 1. 从 Store 加载(若已注入)
    let cached: AvatarOrientationCalibration | null = null;
    let shaMatched: boolean = false;
    if (this.calibrationStore !== null) {
      try {
        const loadResult = await this.calibrationStore.loadOrCreateDefault(avatarId, sourceSha256);
        cached = loadResult.calibration;
        shaMatched = loadResult.sourceSha256Matched;
      } catch (e) {
        Logger.warn(LOG_TAG, 'loadOrAnalyzeCalibration: store load failed: ' + (e as Error)?.message);
      }
    }

    // 2. 判断是否需要重新分析
    // 需要重新分析的条件:
    //   - cached === null(Store 未注入或加载失败)
    //   - !shaMatched(模型文件变了)
    //   - cached.autoConfidence === Unknown(之前分析失败)
    const needAnalyze: boolean = cached === null
      || !shaMatched
      || (cached as AvatarOrientationCalibration).autoConfidence === OrientationConfidence.Unknown;

    let analysis: AvatarOrientationAnalysis | null = null;
    if (needAnalyze) {
      // 3. 执行新的自动分析
      try {
        analysis = analyzeOrientation(sourceRestPose, targetRestPose);
        this.lastAnalysis = analysis;
        logAnalysisSummary(analysis);
      } catch (e) {
        Logger.warn(LOG_TAG, 'loadOrAnalyzeCalibration: analyzeOrientation failed: ' + (e as Error)?.message);
        analysis = null;
      }
    }

    // 4. 构建最终的 calibration
    let result: AvatarOrientationCalibration;
    if (cached !== null && !needAnalyze) {
      // 使用缓存(手动覆盖优先,自动结果次之)
      result = cached as AvatarOrientationCalibration;
      Logger.info(LOG_TAG, 'loadOrAnalyzeCalibration: use cached, mode=' + result.mode
        + ', isManual=' + result.isManualOverride);
    } else if (cached !== null && needAnalyze && analysis !== null) {
      // 已有缓存(可能是手动覆盖)+ 新分析结果
      // 保留用户的 mode 和 isManualOverride,只更新 autoDetected 字段
      result = {
        avatarId: (cached as AvatarOrientationCalibration).avatarId,
        sourceSha256: sourceSha256,
        mode: (cached as AvatarOrientationCalibration).mode,
        autoDetectedMode: analysis.selectedMode,
        autoConfidence: analysis.confidence,
        yawOffsetDeg: (cached as AvatarOrientationCalibration).yawOffsetDeg,
        swapLeftRight: (cached as AvatarOrientationCalibration).swapLeftRight,
        invertForward: (cached as AvatarOrientationCalibration).invertForward,
        autoReasonCode: analysis.reasonCode,
        isManualOverride: (cached as AvatarOrientationCalibration).isManualOverride,
        updatedAt: Date.now()
      };
      // 持久化(更新 autoDetected 字段)
      if (this.calibrationStore !== null) {
        await this.calibrationStore.save(result);
      }
      Logger.info(LOG_TAG, 'loadOrAnalyzeCalibration: updated cached with new analysis, mode=' + result.mode
        + ', autoMode=' + result.autoDetectedMode
        + ', confidence=' + result.autoConfidence);
    } else if (cached === null && analysis !== null) {
      // 无缓存,使用新分析结果
      result = {
        avatarId: avatarId,
        sourceSha256: sourceSha256,
        mode: AvatarOrientationMode.Auto,
        autoDetectedMode: analysis.selectedMode,
        autoConfidence: analysis.confidence,
        yawOffsetDeg: 0,
        swapLeftRight: false,
        invertForward: false,
        autoReasonCode: analysis.reasonCode,
        isManualOverride: false,
        updatedAt: Date.now()
      };
      if (this.calibrationStore !== null) {
        await this.calibrationStore.save(result);
      }
      Logger.info(LOG_TAG, 'loadOrAnalyzeCalibration: new analysis saved, mode=Auto'
        + ', autoMode=' + result.autoDetectedMode
        + ', confidence=' + result.autoConfidence);
    } else {
      // 分析失败且无缓存:使用安全默认值
      result = createDefaultCalibration(avatarId, sourceSha256);
      Logger.warn(LOG_TAG, 'loadOrAnalyzeCalibration: fallback to default (analysis failed and no cache)');
    }

    this.currentCalibration = result;

    // 5. 通知 UI
    if (this.onCalibrationChanged !== null) {
      this.onCalibrationChanged(result, this.lastAnalysis);
    }

    return result;
  }

  /**
   * T-4.2F: 输出手臂链映射诊断日志。
   *
   * 检查 LeftShoulder / LeftUpperArm / LeftLowerArm / LeftHand /
   *      RightShoulder / RightUpperArm / RightLowerArm / RightHand
   * 是否都正确映射到唯一目标节点,以及对应 source track 是否存在。
   *
   * 不输出敏感信息(只输出骨骼名、节点是否存在、track 是否存在)。
   */
  private logArmMappingInfo(
    clip: HumanoidMotionClip,
    targetRestResult: TargetRestPoseCollectResult,
    provider: HumanoidProvider
  ): void {
    const armBones: HumanoidBone[] = [
      HumanoidBone.LeftShoulder,
      HumanoidBone.LeftUpperArm,
      HumanoidBone.LeftLowerArm,
      HumanoidBone.LeftHand,
      HumanoidBone.RightShoulder,
      HumanoidBone.RightUpperArm,
      HumanoidBone.RightLowerArm,
      HumanoidBone.RightHand
    ];
    // 收集 source clip 中存在的骨骼名
    const sourceBones: Set<HumanoidBone> = new Set<HumanoidBone>();
    for (let i: number = 0; i < clip.tracks.length; i++) {
      sourceBones.add(clip.tracks[i].bone);
    }
    Logger.info(LOG_TAG, 'Retarget arm mapping: clip=' + clip.name
      + ', sourceTrackCount=' + clip.tracks.length
      + ', mappingSource=' + provider.getPrimarySource());
    for (let i: number = 0; i < armBones.length; i++) {
      const bone: HumanoidBone = armBones[i];
      const hasTargetNode: boolean = targetRestResult.boneNodeMap.has(bone);
      const hasSourceTrack: boolean = sourceBones.has(bone);
      const hasRest: boolean = targetRestResult.restPose.bones.has(bone);
      Logger.info(LOG_TAG, '  bone=' + bone
        + ', targetNode=' + (hasTargetNode ? 'yes' : 'NO')
        + ', sourceTrack=' + (hasSourceTrack ? 'yes' : 'no')
        + ', targetRest=' + (hasRest ? 'yes' : 'no'));
    }
  }

  /**
   * T-4.2G-A: 输出关键骨骼的 Rest Pose 旋转值,用于诊断 T Pose vs A Pose vs 双臂下垂。
   *
   * 通过四元数转换欧拉角,显示 UpperArm 的旋转角度,判断 Rest Pose 类型:
   * - T Pose: UpperArm 绕 X 轴约 ±90°(双臂水平展开)
   * - A Pose: UpperArm 绕 X 轴约 ±45°(双臂斜下展开)
   * - 双臂下垂: UpperArm 旋转接近 identity(0°)
   */
  private logRestPoseDiagnostics(
    sourceRest: HumanoidRestPose,
    targetRest: HumanoidRestPose
  ): void {
    const diagnosticBones: HumanoidBone[] = [
      HumanoidBone.Hips,
      HumanoidBone.Spine,
      HumanoidBone.Chest,
      HumanoidBone.LeftUpperArm,
      HumanoidBone.RightUpperArm,
      HumanoidBone.LeftLowerArm,
      HumanoidBone.RightLowerArm
    ];
    Logger.info(LOG_TAG, '=== T-4.2G-A Rest Pose Diagnostics ===');
    for (let i: number = 0; i < diagnosticBones.length; i++) {
      const bone: HumanoidBone = diagnosticBones[i];
      const sRest: BoneRestTransform | undefined = sourceRest.bones.get(bone);
      const tRest: BoneRestTransform | undefined = targetRest.bones.get(bone);
      if (sRest !== undefined) {
        const euler: number[] = quaternionToEulerDeg(sRest.localRotation);
        Logger.info(LOG_TAG, 'RestPose source ' + bone
          + ': q=(' + sRest.localRotation.x.toFixed(3) + ',' + sRest.localRotation.y.toFixed(3)
          + ',' + sRest.localRotation.z.toFixed(3) + ',' + sRest.localRotation.w.toFixed(3) + ')'
          + ' euler=(' + euler[0].toFixed(1) + ',' + euler[1].toFixed(1) + ',' + euler[2].toFixed(1) + ')deg');
      } else {
        Logger.info(LOG_TAG, 'RestPose source ' + bone + ': MISSING');
      }
      if (tRest !== undefined) {
        const euler: number[] = quaternionToEulerDeg(tRest.localRotation);
        Logger.info(LOG_TAG, 'RestPose target ' + bone
          + ': q=(' + tRest.localRotation.x.toFixed(3) + ',' + tRest.localRotation.y.toFixed(3)
          + ',' + tRest.localRotation.z.toFixed(3) + ',' + tRest.localRotation.w.toFixed(3) + ')'
          + ' euler=(' + euler[0].toFixed(1) + ',' + euler[1].toFixed(1) + ',' + euler[2].toFixed(1) + ')deg');
      } else {
        Logger.info(LOG_TAG, 'RestPose target ' + bone + ': MISSING');
      }
    }
    Logger.info(LOG_TAG, '=== Rest Pose Diagnostics End ===');
  }

  /**
   * T-4.2G-A: 解析 Avatar GLB 的 nodes,输出关键骨骼的原始 TRS,与 SceneNode 对比。
   *
   * 用于确认 SceneNode.rotation 是否等于 GLB nodes 的默认 rotation。
   * 如果不一致,说明 ArkGraphics3D Scene.load 修改了骨骼旋转。
   */
  private logGlbNodeRestPose(glbBuffer: ArrayBuffer, vrmAsset: VrmAsset): void {
    try {
      // 解析 GLB JSON
      const view: DataView = new DataView(glbBuffer);
      const magic: number = view.getUint32(0, true);
      if (magic !== 0x46546C67) { // 'glTF'
        Logger.info(LOG_TAG, 'logGlbNodeRestPose: not a GLB');
        return;
      }
      const jsonLength: number = view.getUint32(12, true);
      const jsonBytes: Uint8Array = new Uint8Array(glbBuffer, 20, jsonLength);
      const textDecoder: util.TextDecoder = util.TextDecoder.create('utf-8');
      const jsonStr: string = textDecoder.decodeToString(jsonBytes);
      const json: Record<string, Object> = JSON.parse(jsonStr) as Record<string, Object>;
      const nodes: Object[] | undefined = json['nodes'] as Object[] | undefined;
      if (nodes === undefined) {
        Logger.info(LOG_TAG, 'logGlbNodeRestPose: no nodes');
        return;
      }

      // 构建 bone → nodeIndex 映射(从 VRM humanoid)
      const boneToNodeIndex: Map<HumanoidBone, number> = new Map<HumanoidBone, number>();
      for (let i: number = 0; i < vrmAsset.humanoid.bones.length; i++) {
        const hb: HumanoidBone = vrmAsset.humanoid.bones[i].target;
        const idx: number = vrmAsset.humanoid.bones[i].nodeIndex;
        if (idx >= 0) {
          boneToNodeIndex.set(hb, idx);
        }
      }

      const diagnosticBones: HumanoidBone[] = [
        HumanoidBone.Hips,
        HumanoidBone.Spine,
        HumanoidBone.Chest,
        HumanoidBone.LeftUpperArm,
        HumanoidBone.RightUpperArm,
        HumanoidBone.LeftLowerArm,
        HumanoidBone.RightLowerArm
      ];
      Logger.info(LOG_TAG, '=== T-4.2G-A GLB Node Original TRS ===');
      for (let i: number = 0; i < diagnosticBones.length; i++) {
        const bone: HumanoidBone = diagnosticBones[i];
        const nodeIndex: number | undefined = boneToNodeIndex.get(bone);
        if (nodeIndex === undefined || nodeIndex >= nodes.length) {
          Logger.info(LOG_TAG, 'GLBNode ' + bone + ': nodeIndex missing');
          continue;
        }
        const node: Record<string, Object> = nodes[nodeIndex] as Record<string, Object>;
        const nameObj: Object | undefined = node['name'];
        const nodeName: string = (nameObj !== undefined && nameObj !== null) ? String(nameObj) : '';
        const rot: Object | undefined = node['rotation'];
        if (rot !== undefined) {
          const arr: number[] = rot as number[];
          const q: QuaternionValue = { x: arr[0], y: arr[1], z: arr[2], w: arr[3] };
          const euler: number[] = quaternionToEulerDeg(q);
          Logger.info(LOG_TAG, 'GLBNode ' + bone + ' (name=' + nodeName + ', idx=' + nodeIndex + ')'
            + ': q=(' + q.x.toFixed(3) + ',' + q.y.toFixed(3) + ',' + q.z.toFixed(3) + ',' + q.w.toFixed(3) + ')'
            + ' euler=(' + euler[0].toFixed(1) + ',' + euler[1].toFixed(1) + ',' + euler[2].toFixed(1) + ')deg');
        } else {
          Logger.info(LOG_TAG, 'GLBNode ' + bone + ' (name=' + nodeName + ', idx=' + nodeIndex + ')'
            + ': rotation missing (identity)');
        }
      }
      Logger.info(LOG_TAG, '=== GLB Node Original TRS End ===');
    } catch (e) {
      Logger.warn(LOG_TAG, 'logGlbNodeRestPose failed: ' + (e as Error)?.message);
    }
  }
}
