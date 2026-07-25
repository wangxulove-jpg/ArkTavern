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
import { HumanoidRetargetPlaybackController, RetargetPlaybackState, RetargetPlaybackConfig } from '../services/HumanoidRetargetPlaybackController';
import { collectSceneNodes, SceneNodeCollectResult } from '../services/SceneNodeCollector';
import { collectTargetRestPose, TargetRestPoseCollectResult } from '../services/TargetRestPoseCollector';
import { HumanoidProvider, HumanoidProviderInput } from '../services/HumanoidProvider';
import { parseAnimationByName, parseSourceRestPose, AnimationDataParseResult, SourceRestPoseParseResult } from '../parser/GltfAnimationDataParser';
import { HumanoidMotionClip, RootMotionMode } from '../models/character3d/HumanoidMotionClip';
import { VrmAsset } from '../models/character3d/vrm/VrmAsset';
import { BUILTIN_ACTION_RAWFILE_DIR, BUILTIN_PACK_FILE_NAME } from '../models/character3d/BuiltInActionManifest';
import { detectVrm } from '../parser/VrmDetector';
import { importVrm } from '../parser/VRMImporter';
import { GltfValidator } from '../parser/GltfValidator';

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
    // 回退:ArkGraphics3D 内置动画
    if (this.currentAnimation === null) {
      Logger.warn(LOG_TAG, 'play: no animation available');
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
        // Retarget 模式:自动开始播放
        this.useRetargetMode = true;
        hasAnimation = true;
        if (this.retargetController !== null) {
          this.retargetController.play();
        }
      } else {
        // 回退:尝试 Avatar 自带动画
        hasAnimation = this.tryPlayActionClip();
      }
      if (this.onAvatarInfo !== null) {
        this.onAvatarInfo(this.avatarDisplayName, hasAnimation);
      }
      Logger.info(LOG_TAG, 'stateMachine: loadActiveAvatarScene done, hasAnimation=' + hasAnimation
        + ', useRetargetMode=' + this.useRetargetMode);
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
    try {
      // 关键修复 1: camera.enabled = true(SDK 默认 false,不启用就是空白)
      camera.enabled = true;
      // 关键修复 2: camera.rotation = identity(看向 -Z 方向)
      camera.rotation = { x: 0, y: 0, z: 0, w: 1 } as Quaternion;
      // 关键修复 3: camera.position = (0, 0, camDist)(模型中心通过 transform 移到原点)
      camera.position = { x: 0, y: 0, z: camDist } as Position3;
      // 关键修复 4: camera.fov/near/far
      camera.fov = PREVIEW_CAMERA_FOV;
      // 动态 near/far(参考 PoC computeDynamicNearFar)
      const scaledRadius: number = bounds !== null ? bounds.radius * camScale : 1.0;
      const near: number = Math.max(0.05, camDist - scaledRadius * 1.5);
      const far: number = camDist + scaledRadius * 4.0;
      camera.nearPlane = near;
      camera.farPlane = far;
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
   * 释放当前 Scene(内部方法,不修改状态)。
   */
  private releaseSceneInternal(): void {
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
      speed: 1.0
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
    Logger.info(LOG_TAG, 'prepareRetargetController: success, clip=' + clip.name
      + ', duration=' + clip.durationSeconds.toFixed(3)
      + ', tracks=' + clip.tracks.length
      + ', targetBones=' + targetRestResult.collectedCount);
    return true;
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
}
