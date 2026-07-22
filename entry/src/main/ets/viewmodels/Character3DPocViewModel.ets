/**
 * Character3DPocViewModel 3D 渲染 PoC ViewModel
 *
 * 临时开发测试: T-3D.1 内置模型与 3D 渲染 PoC;T-3D.2 扩展支持外部 GLB 导入
 *
 * 职责:
 * - 管理 Scene / Animation / Camera / Light 生命周期
 * - 状态机驱动(Disposed/Loading/Ready/Playing/Paused/Failed)
 * - operationId 防止迟到回调更新已销毁页面
 * - 拖动旋转角度累积 + 视角重置
 * - T-3D.1: 程序化构建简单人形占位(无外部 GLB 时降级为几何体场景)
 * - T-3D.2: 通过 Scene.load(uri) 加载外部 GLB/GLTF 模型文件
 * - T-3D.2: 加载外部模型后补全 camera/light(若模型未自带)
 * - 不读取聊天正文 / Prompt / API Key
 *
 * 实际使用的 HarmonyOS API:
 * - @kit.ArkGraphics3D 的 Scene.load() / scene.destroy() / scene.getResourceFactory()
 * - SceneResourceFactory.createCamera / createLight / createMaterial / createMesh / createGeometry
 * - CubeGeometry / SphereGeometry (几何体定义)
 * - Material / MaterialType (材质,第一版不设置 PBR 属性)
 * - Animation.start / stop / pause / restart
 * - Node.position / rotation / scale
 *
 * 已知限制(必须在 PoC 报告中明确):
 * - 外部 GLB 模型的动画支持取决于模型本身是否包含动画
 * - 外部模型的旋转锚点选取第一个 node 作为 root,可能不适用于所有模型
 */

import {
  Scene,
  Animation,
  Node,
  Camera,
  Light,
  LightType,
  Material,
  MaterialType,
  Mesh,
  SubMesh,
  MeshResource,
  Geometry,
  CubeGeometry,
  SphereGeometry,
  Position3,
  Quaternion,
  SceneResourceParameters,
  SceneNodeParameters,
  SceneResourceFactory
} from '@kit.ArkGraphics3D';
import { Logger } from '../utils/Logger';
import {
  Character3DLoadStateEnum,
  isValidStateTransition,
  isDisposedState,
  computeDragRotationDeg,
  normalizeRotationDeg,
  DEFAULT_VIEW_ROTATION_Y_DEG
} from '../models/character3d/Character3DLoadState';
import { Character3DService, Character3DImportResult } from '../services/Character3DService';
import { GltfModelInfo } from '../parser/GltfValidator';
import {
  Character3DDisplayConfig,
  createDefaultDisplayConfig,
  sanitizeDisplayConfig,
  CAMERA_HEIGHT,
  CAMERA_FOV,
  CAMERA_NEAR,
  CAMERA_FAR,
  DEFAULT_ROTATION_X_DEG
} from '../models/character3d/Character3DDisplayConfig';
import {
  ModelBounds,
  computeBoundsFromGltf,
  computeAutoFitDisplayConfig,
  isBoundsValid
} from '../models/character3d/ModelBounds';
import {
  Character3DGestureHandler,
  GestureState,
  TouchPhase,
  TouchPointData,
  GestureCallbacks,
  GestureConfigSnapshot
} from '../models/character3d/Character3DGestureHandler';

const LOG_TAG: string = 'Char3DPocVM';

/** 拖动灵敏度(度/像素) */
const DRAG_SENSITIVITY: number = 0.3;
/** 单次拖动最大旋转度数 */
const DRAG_MAX_DEG: number = 60;
/** T-3D.5A: Pitch(垂直旋转)限制范围 [-60, 60] 度,避免模型倒置 */
const PITCH_MIN_DEG: number = -60;
const PITCH_MAX_DEG: number = 60;
/** T-3D.5A: 拖动死区(像素),小于此值视为抖动,不触发旋转 */
const DRAG_DEAD_ZONE_PX: number = 3;

/**
 * PoC ViewModel。
 *
 * 使用方式:
 * 1. aboutToAppear 调用 initialize() 启动加载
 * 2. onPageShow / onPageHide 调用 onResume / onPause
 * 3. aboutToDisappear 调用 dispose()
 * 4. UI 通过 onStateChanged / onRotationChanged 回调刷新
 */
export class Character3DPocViewModel {
  /** 当前加载状态 */
  private stateValue: Character3DLoadStateEnum = Character3DLoadStateEnum.Disposed;
  /** 操作 ID,每次 dispose / reload 递增,迟到回调通过比对 ID 失效 */
  private operationId: number = 0;
  /** 当前 Scene 实例(null 表示未加载或已释放) */
  private sceneValue: Scene | null = null;
  /** 根节点(用于旋转整个人形占位) */
  private rootNode: Node | null = null;
  /** 相机实例 */
  private cameraValue: Camera | null = null;
  /** 当前播放的动画(null 表示无动画或未播放) */
  private currentAnimation: Animation | null = null;
  /** 当前 Y 轴旋转角度(度数,累积) */
  private rotationYDeg: number = DEFAULT_VIEW_ROTATION_Y_DEG;
  /** 是否已 dispose */
  private disposed: boolean = false;
  /** 是否已暂停(页面不可见时) */
  private pageHidden: boolean = false;
  /** Character3DService 实例(可选,用于导入/读取/清除外部模型) */
  private service: Character3DService | null = null;
  /** 当前加载的模型 URI(空字符串表示使用程序化几何体) */
  private currentModelUri: string = '';
  /** 当前加载的模型显示名(空字符串表示使用程序化几何体) */
  private currentDisplayName: string = '';
  /** 当前加载的模型摘要信息(导入后由 GltfValidator 提取;程序化几何体或重启后未验证时为 null) */
  private currentModelInfo: GltfModelInfo | null = null;
  /** T-3D.4A: 当前模型标识(使用 displayName,用于 per-model 显示配置隔离) */
  private currentModelId: string = '';
  /** T-3D.4A: 当前模型 Bounds(从 GltfModelInfo 计算,用于 autoFit 和 UI 显示) */
  private currentBounds: ModelBounds | null = null;
  /** T-3D.4: 显示配置(内存态,初始化时从 Preferences 读取,updateDisplayConfig 只改内存,saveDisplayConfig 才落盘) */
  private displayConfig: Character3DDisplayConfig = createDefaultDisplayConfig();
  /** 模型来源变更回调(导入/清除时触发) */
  onModelSourceChanged: ((displayName: string, isExternal: boolean, modelInfo: GltfModelInfo | null) => void) | null = null;
  /** 状态变更回调 */
  onStateChanged: ((state: Character3DLoadStateEnum) => void) | null = null;
  /** 旋转变更回调 */
  onRotationChanged: ((rotationYDeg: number) => void) | null = null;
  /** 错误信息(Failed 状态时非空) */
  onError: ((message: string) => void) | null = null;
  /** 触摸反馈回调 */
  onTouchFeedback: (() => void) | null = null;
  /** T-3D.4: 显示配置变更回调(UI 实时刷新 Slider/数值) */
  onDisplayConfigChanged: ((config: Character3DDisplayConfig) => void) | null = null;
  /** T-3D.5B: 手势状态机处理器 */
  private gestureHandler: Character3DGestureHandler = new Character3DGestureHandler();
  /** T-3D.5B: 手势处理器是否已初始化(绑定回调) */
  private gestureHandlerInited: boolean = false;

  /**
   * 初始化并启动加载。
   * 幂等:已 Loading/Ready/Playing/Paused 时忽略。
   * 如果注入了 Character3DService,会先读取已保存的模型 URI。
   */
  async initialize(): Promise<void> {
    if (this.disposed) {
      Logger.warn(LOG_TAG, 'initialize ignored: disposed');
      return;
    }
    if (this.stateValue !== Character3DLoadStateEnum.Disposed
      && this.stateValue !== Character3DLoadStateEnum.Failed) {
      Logger.warn(LOG_TAG, 'initialize ignored: state=' + this.stateValue);
      return;
    }
    // T-3D.2:如果有 service,先读取已保存的模型配置
    if (this.service !== null) {
      try {
        const config = await this.service.getConfig();
        if (config.modelUri.length > 0 && config.fileExists) {
          this.currentModelUri = config.modelUri;
          this.currentDisplayName = config.displayName;
          this.currentModelId = config.displayName;
          Logger.info(LOG_TAG, 'initialize: found saved model, uri valid');
          // T-3D.4A: 重新读取模型文件获取 GltfModelInfo(支持 Bounds 计算和 autoFitView)
          const info: GltfModelInfo | null =
            await this.service.getModelInfoByUri(config.modelUri);
          if (info !== null) {
            this.currentModelInfo = info;
            Logger.info(LOG_TAG, 'initialize: model info loaded, meshes=' + info.meshCount
              + ', animations=' + info.animationCount
              + ', hasBounds=' + (info.boundsMin !== null));
            // T-3D.4A: 确保该 modelId 有自适应默认配置(首次恢复时保存 autoFit)
            try {
              const autoFit: Character3DDisplayConfig =
                this.service.computeAutoFitConfig(info);
              await this.service.ensureModelDefaultConfig(config.displayName, autoFit);
            } catch (eFit) {
              Logger.warn(LOG_TAG, 'initialize: ensureModelDefaultConfig failed: '
                + (eFit as Error)?.message);
            }
          } else {
            Logger.warn(LOG_TAG, 'initialize: getModelInfoByUri returned null');
          }
        } else if (config.modelUri.length > 0 && !config.fileExists) {
          // URI 存在但文件丢失,清空 Preferences 并回退到程序化几何体
          Logger.warn(LOG_TAG, 'initialize: saved model file missing, clearing');
          await this.service.clearModel();
          this.currentModelUri = '';
          this.currentDisplayName = '';
          this.currentModelId = '';
        } else {
          this.currentModelUri = '';
          this.currentDisplayName = '';
          this.currentModelId = '';
        }
        // T-3D.4A: 读取 per-model 显示配置(使用 currentModelId 隔离)
        try {
          this.displayConfig = await this.service.getDisplayConfig(this.currentModelId);
          // 将历史拖动旋转角度 rotationYDeg 同步为配置中的值
          this.rotationYDeg = this.displayConfig.rotationYDeg;
          Logger.info(LOG_TAG, 'initialize: display config loaded, modelId=' + this.currentModelId
            + ', scale=' + this.displayConfig.scale
            + ', rotY=' + this.displayConfig.rotationYDeg
            + ', camDist=' + this.displayConfig.cameraDistance);
        } catch (eCfg) {
          Logger.warn(LOG_TAG, 'initialize: load display config failed: ' + (eCfg as Error)?.message);
          this.displayConfig = createDefaultDisplayConfig();
        }
      } catch (e) {
        Logger.warn(LOG_TAG, 'initialize: read config failed: ' + (e as Error)?.message);
        this.currentModelUri = '';
        this.currentDisplayName = '';
        this.currentModelId = '';
      }
    }
    this.loadAsync();
  }

  /**
   * 异步加载场景。
   * 通过 operationId 防止迟到回调污染后续状态。
   *
   * 加载策略:
   * - currentModelUri 非空:调用 Scene.load(uri) 加载外部 GLB,补全 camera/light
   * - currentModelUri 为空:调用 Scene.load() 创建空场景,程序化构建几何体
   */
  private async loadAsync(): Promise<void> {
    const opId: number = ++this.operationId;
    this.setState(Character3DLoadStateEnum.Loading);
    try {
      if (this.currentModelUri.length > 0) {
        // T-3D.2:加载外部 GLB/GLTF 模型
        Logger.info(LOG_TAG, 'loadAsync: calling Scene.load(uri)');
        const scene: Scene = await Scene.load(this.currentModelUri);
        Logger.info(LOG_TAG, 'loadAsync: Scene.load(uri) returned');
        if (opId !== this.operationId) {
          Logger.info(LOG_TAG, 'late callback discarded: scene loaded');
          try {
            scene.destroy();
          } catch (_e) {
            // ignore
          }
          return;
        }
        this.sceneValue = scene;
        await this.supplementExternalScene(scene, opId);
        if (opId !== this.operationId) {
          Logger.info(LOG_TAG, 'late callback discarded: supplement done');
          return;
        }
      } else {
        // T-3D.1:程序化几何体场景
        Logger.info(LOG_TAG, 'loadAsync: calling Scene.load()');
        const scene: Scene = await Scene.load();
        Logger.info(LOG_TAG, 'loadAsync: Scene.load() returned');
        if (opId !== this.operationId) {
          Logger.info(LOG_TAG, 'late callback discarded: scene loaded');
          try {
            scene.destroy();
          } catch (_e) {
            // ignore
          }
          return;
        }
        this.sceneValue = scene;
        Logger.info(LOG_TAG, 'loadAsync: calling buildProceduralScene');
        await this.buildProceduralScene(scene, opId);
        Logger.info(LOG_TAG, 'loadAsync: buildProceduralScene returned');
        if (opId !== this.operationId) {
          Logger.info(LOG_TAG, 'late callback discarded: build done');
          return;
        }
      }
      this.setState(Character3DLoadStateEnum.Ready);
      // Ready 后自动开始待机"播放"(如果有动画)
      this.startIdleIfNeeded();
      // T-3D.5B: 场景就绪后初始化手势处理器,绑定相机距离和当前配置
      this.initGestureHandler();
      this.updateGestureConfig();
      // 通知 UI 模型来源
      this.fireModelSourceChanged();
      // T-3D.4: 通知 UI 当前显示配置(initialize 读取的持久化配置需要同步到 UI)
      if (this.onDisplayConfigChanged !== null) {
        this.onDisplayConfigChanged(this.displayConfig);
      }
      if (this.onRotationChanged !== null) {
        this.onRotationChanged(this.rotationYDeg);
      }
    } catch (e) {
      if (opId !== this.operationId) {
        return;
      }
      const err: Error = e as Error;
      const msg: string = err?.message ?? 'load failed';
      const stack: string = err?.stack ?? '';
      Logger.error(LOG_TAG, 'loadAsync failed: ' + msg + ' | stack: ' + stack);
      this.fireError('加载失败: ' + msg);
      this.setState(Character3DLoadStateEnum.Failed);
    }
  }

  /**
   * 为外部 GLB 模型场景补全 camera/light。
   *
   * T-3D.4A 改进:
   * - 从 currentModelInfo 计算 Bounds,缓存到 currentBounds
   * - 相机位置改为 (0, 0, cameraDistance),模型中心通过 offset 移到原点
   * - 输出详细诊断日志(mesh/bounds/camera fit)
   *
   * GLB 模型可能自带 camera/light,也可能不带。
   * 为了 PoC 简化,本方法始终创建 camera 和 light:
   * - 如果模型自带,我们的额外 camera/light 会叠加(通常不影响渲染)
   * - 如果模型不带,我们的 camera/light 保证场景可见
   *
   * rootNode 选取 scene.root(场景根节点),用于旋转整个场景。
   *
   * @param scene 已加载外部模型的场景
   * @param opId 当前操作 ID
   */
  private async supplementExternalScene(scene: Scene, opId: number): Promise<void> {
    const factory: SceneResourceFactory = scene.getResourceFactory();
    Logger.info(LOG_TAG, 'supplementExternalScene: start');

    // T-3D.4A: 计算 Bounds 并缓存
    if (this.currentModelInfo !== null) {
      this.currentBounds = computeBoundsFromGltf(this.currentModelInfo);
      if (this.currentBounds !== null) {
        Logger.info(LOG_TAG, 'supplementExternalScene: bounds computed, center=('
          + this.currentBounds.centerX.toFixed(3) + ','
          + this.currentBounds.centerY.toFixed(3) + ','
          + this.currentBounds.centerZ.toFixed(3) + ') size=('
          + this.currentBounds.width.toFixed(3) + ','
          + this.currentBounds.height.toFixed(3) + ','
          + this.currentBounds.depth.toFixed(3) + ') radius='
          + this.currentBounds.radius.toFixed(3));
      } else {
        Logger.warn(LOG_TAG, 'supplementExternalScene: bounds null (no POSITION accessor or invalid)');
      }
    } else {
      Logger.warn(LOG_TAG, 'supplementExternalScene: currentModelInfo null');
    }

    // T-3D.4A: 选取 scene root(用于挂载相机/灯光,不受模型变换影响)
    const sceneRoot: Node | null = scene.root;
    if (sceneRoot === null) {
      Logger.warn(LOG_TAG, 'supplementExternalScene: scene.root is null');
      return;
    }
    const childCount: number = sceneRoot.children.count();
    Logger.info(LOG_TAG, 'supplementExternalScene: sceneRoot name=' + sceneRoot.name
      + ', childrenCount=' + childCount.toString());

    // T-3D.4A: 选取模型根节点(用于 scale/offset/rotation 变换)
    // 优先使用 sceneRoot 的第一个子节点(模型的根节点),避免变换影响相机和灯光
    if (childCount > 0) {
      const modelRoot: Node | null = sceneRoot.children.get(0);
      if (modelRoot !== null) {
        this.rootNode = modelRoot;
        Logger.info(LOG_TAG, 'supplementExternalScene: model root selected, name=' + modelRoot.name);
      } else {
        this.rootNode = sceneRoot;
        Logger.warn(LOG_TAG, 'supplementExternalScene: first child null, using sceneRoot');
      }
    } else {
      this.rootNode = sceneRoot;
      Logger.warn(LOG_TAG, 'supplementExternalScene: no children, using sceneRoot as model root');
    }

    // 始终创建相机(保证有可见视角)
    Logger.info(LOG_TAG, 'supplementExternalScene: creating camera');
    const cameraParams: SceneNodeParameters = { name: 'mainCamera' };
    const camera: Camera = await factory.createCamera(cameraParams);
    if (opId !== this.operationId) {
      return;
    }
    // T-3D.4A: Camera Fit 统一封装,避免硬编码散落
    // 外部模型 camY=0(模型中心通过 offset 移到原点,相机正对原点)
    this.applyCameraFit(camera, 0, this.displayConfig.cameraDistance);
    this.cameraValue = camera;
    // T-3D.4A: 将相机挂载到 sceneRoot(不是 model root),避免被模型变换影响
    try {
      sceneRoot.children.append(camera);
      Logger.info(LOG_TAG, 'supplementExternalScene: camera appended to sceneRoot');
    } catch (e) {
      Logger.warn(LOG_TAG, 'supplementExternalScene: append camera failed: ' + (e as Error)?.message);
    }

    // 始终创建灯光(保证有光照)
    Logger.info(LOG_TAG, 'supplementExternalScene: creating light');
    const lightParams: SceneNodeParameters = { name: 'mainLight' };
    const light: Light = await factory.createLight(lightParams, LightType.DIRECTIONAL);
    if (opId !== this.operationId) {
      return;
    }
    const lightPos: Position3 = { x: 2, y: 5, z: 3 };
    light.position = lightPos;
    light.intensity = 3.0;
    light.shadowEnabled = false;
    // T-3D.4A: 将灯光挂载到 sceneRoot(不是 model root),避免被模型变换影响
    try {
      sceneRoot.children.append(light);
      Logger.info(LOG_TAG, 'supplementExternalScene: light appended to sceneRoot');
    } catch (e) {
      Logger.warn(LOG_TAG, 'supplementExternalScene: append light failed: ' + (e as Error)?.message);
    }

    Logger.info(LOG_TAG, 'supplementExternalScene: done');
    // 应用当前显示配置(scale/offset/rotation/camera)
    // T-3D.4A: 若当前 displayConfig 是默认配置(可能是旧全局配置),且 currentBounds 有效,
    // 重新计算自适应配置(确保模型可见)
    this.applyDisplayConfigToScene();
    Logger.info(LOG_TAG, 'supplementExternalScene: config applied, scale=' + this.displayConfig.scale
      + ', offset=(' + this.displayConfig.offsetX.toFixed(3) + ','
      + this.displayConfig.offsetY.toFixed(3) + ','
      + this.displayConfig.offsetZ.toFixed(3) + ')'
      + ', camDist=' + this.displayConfig.cameraDistance);
  }

  /**
   * 程序化构建简单人形占位场景。
   *
   * 结构:
   * - root(空节点,旋转锚点)
   *   ├─ head(Sphere, y=1.6)
   *   ├─ torso(Cube, y=0.9)
   *   ├─ leftArm(Cube, x=-0.6, y=1.1)
   *   └─ rightArm(Cube, x=0.6, y=1.1)
   * - camera(y=1.5, z=4, lookAt origin)
   * - directionalLight(y=5, intensity=3)
   *
   * @param scene 目标场景
   * @param opId 当前操作 ID
   */
  private async buildProceduralScene(scene: Scene, opId: number): Promise<void> {
    const factory: SceneResourceFactory = scene.getResourceFactory();
    Logger.info(LOG_TAG, 'buildProceduralScene: start');

    // T-3D.4A: 获取场景根节点(用于挂载创建的节点)
    const sceneRoot: Node | null = scene.root;
    if (sceneRoot === null) {
      Logger.error(LOG_TAG, 'buildProceduralScene: scene.root is null, cannot build scene');
      return;
    }
    Logger.info(LOG_TAG, 'buildProceduralScene: sceneRoot name=' + sceneRoot.name);

    // 创建 root 节点(旋转锚点)
    Logger.info(LOG_TAG, 'buildProceduralScene: creating root node');
    const rootParams: SceneNodeParameters = { name: 'HumanoidRoot' };
    const root: Node = await factory.createNode(rootParams);
    if (opId !== this.operationId) {
      return;
    }
    Logger.info(LOG_TAG, 'buildProceduralScene: root node created');
    const rootPos: Position3 = { x: 0, y: 0, z: 0 };
    root.position = rootPos;
    this.rootNode = root;
    // T-3D.4A: 将 root 挂载到场景树
    sceneRoot.children.append(root);
    Logger.info(LOG_TAG, 'buildProceduralScene: root appended to sceneRoot');

    // 创建材质(皮肤色)
    Logger.info(LOG_TAG, 'buildProceduralScene: creating skinMat');
    const skinMat: Material = await this.createMaterial(
      factory, 'skinMat', MaterialType.METALLIC_ROUGHNESS
    );
    if (opId !== this.operationId) {
      return;
    }
    Logger.info(LOG_TAG, 'buildProceduralScene: skinMat created');
    Logger.info(LOG_TAG, 'buildProceduralScene: creating clothMat');
    const clothMat: Material = await this.createMaterial(
      factory, 'clothMat', MaterialType.METALLIC_ROUGHNESS
    );
    if (opId !== this.operationId) {
      return;
    }
    Logger.info(LOG_TAG, 'buildProceduralScene: clothMat created');

    // 头部(Sphere)
    Logger.info(LOG_TAG, 'buildProceduralScene: creating head');
    const headGeom: SphereGeometry = new SphereGeometry();
    headGeom.radius = 0.3;
    const headMeshParams: SceneResourceParameters = { name: 'headMesh' };
    const headMesh: MeshResource = await factory.createMesh(headMeshParams, headGeom);
    if (opId !== this.operationId) {
      return;
    }
    Logger.info(LOG_TAG, 'buildProceduralScene: headMesh created');
    const headNodeParams: SceneNodeParameters = { name: 'head' };
    const head: Geometry = await factory.createGeometry(headNodeParams, headMesh);
    if (opId !== this.operationId) {
      return;
    }
    Logger.info(LOG_TAG, 'buildProceduralScene: head geometry created');
    const headPos: Position3 = { x: 0, y: 1.6, z: 0 };
    head.position = headPos;
    this.assignMaterialToGeometry(head, skinMat, 'head');
    root.children.append(head);
    Logger.info(LOG_TAG, 'buildProceduralScene: head appended to root');

    // 躯干(Cube)
    Logger.info(LOG_TAG, 'buildProceduralScene: creating torso');
    const torsoGeom: CubeGeometry = new CubeGeometry();
    torsoGeom.size = { x: 0.8, y: 1.0, z: 0.4 };
    const torsoMeshParams: SceneResourceParameters = { name: 'torsoMesh' };
    const torsoMesh: MeshResource = await factory.createMesh(torsoMeshParams, torsoGeom);
    if (opId !== this.operationId) {
      return;
    }
    Logger.info(LOG_TAG, 'buildProceduralScene: torsoMesh created');
    const torsoNodeParams: SceneNodeParameters = { name: 'torso' };
    const torso: Geometry = await factory.createGeometry(torsoNodeParams, torsoMesh);
    if (opId !== this.operationId) {
      return;
    }
    Logger.info(LOG_TAG, 'buildProceduralScene: torso geometry created');
    const torsoPos: Position3 = { x: 0, y: 0.8, z: 0 };
    torso.position = torsoPos;
    this.assignMaterialToGeometry(torso, clothMat, 'torso');
    root.children.append(torso);
    Logger.info(LOG_TAG, 'buildProceduralScene: torso appended to root');

    // 左臂(Cube)
    Logger.info(LOG_TAG, 'buildProceduralScene: creating leftArm');
    const leftArmGeom: CubeGeometry = new CubeGeometry();
    leftArmGeom.size = { x: 0.2, y: 0.9, z: 0.2 };
    const leftArmMeshParams: SceneResourceParameters = { name: 'leftArmMesh' };
    const armMesh: MeshResource = await factory.createMesh(leftArmMeshParams, leftArmGeom);
    if (opId !== this.operationId) {
      return;
    }
    Logger.info(LOG_TAG, 'buildProceduralScene: leftArmMesh created');
    const leftArmNodeParams: SceneNodeParameters = { name: 'leftArm' };
    const leftArm: Geometry = await factory.createGeometry(leftArmNodeParams, armMesh);
    if (opId !== this.operationId) {
      return;
    }
    Logger.info(LOG_TAG, 'buildProceduralScene: leftArm geometry created');
    const leftArmPos: Position3 = { x: -0.55, y: 0.95, z: 0 };
    leftArm.position = leftArmPos;
    this.assignMaterialToGeometry(leftArm, clothMat, 'leftArm');
    root.children.append(leftArm);
    Logger.info(LOG_TAG, 'buildProceduralScene: leftArm appended to root');

    // 右臂(复用左臂 mesh 模式,独立创建以避免共享冲突)
    Logger.info(LOG_TAG, 'buildProceduralScene: creating rightArm');
    const rightArmGeom: CubeGeometry = new CubeGeometry();
    rightArmGeom.size = { x: 0.2, y: 0.9, z: 0.2 };
    const rightArmMeshParams: SceneResourceParameters = { name: 'rightArmMesh' };
    const rightArmMesh: MeshResource = await factory.createMesh(rightArmMeshParams, rightArmGeom);
    if (opId !== this.operationId) {
      return;
    }
    Logger.info(LOG_TAG, 'buildProceduralScene: rightArmMesh created');
    const rightArmNodeParams: SceneNodeParameters = { name: 'rightArm' };
    const rightArm: Geometry = await factory.createGeometry(rightArmNodeParams, rightArmMesh);
    if (opId !== this.operationId) {
      return;
    }
    Logger.info(LOG_TAG, 'buildProceduralScene: rightArm geometry created');
    const rightArmPos: Position3 = { x: 0.55, y: 0.95, z: 0 };
    rightArm.position = rightArmPos;
    this.assignMaterialToGeometry(rightArm, clothMat, 'rightArm');
    root.children.append(rightArm);
    Logger.info(LOG_TAG, 'buildProceduralScene: rightArm appended to root');

    // 创建相机
    Logger.info(LOG_TAG, 'buildProceduralScene: creating camera');
    const cameraParams: SceneNodeParameters = { name: 'mainCamera' };
    const camera: Camera = await factory.createCamera(cameraParams);
    if (opId !== this.operationId) {
      return;
    }
    Logger.info(LOG_TAG, 'buildProceduralScene: camera created');
    // T-3D.4A: Camera Fit 统一封装,避免硬编码散落
    // 程序化几何体 camY=CAMERA_HEIGHT(几何体在原点上方,相机俯视)
    this.applyCameraFit(camera, CAMERA_HEIGHT, this.displayConfig.cameraDistance);
    this.cameraValue = camera;
    // T-3D.4A: 将相机挂载到场景树
    sceneRoot.children.append(camera);
    Logger.info(LOG_TAG, 'buildProceduralScene: camera appended to sceneRoot');

    // 创建方向光
    Logger.info(LOG_TAG, 'buildProceduralScene: creating light');
    const lightParams: SceneNodeParameters = { name: 'mainLight' };
    const light: Light = await factory.createLight(lightParams, LightType.DIRECTIONAL);
    if (opId !== this.operationId) {
      return;
    }
    Logger.info(LOG_TAG, 'buildProceduralScene: light created');
    const lightPos: Position3 = { x: 2, y: 5, z: 3 };
    light.position = lightPos;
    light.intensity = 3.0;
    light.shadowEnabled = false;
    // T-3D.4A: 将灯光挂载到场景树
    sceneRoot.children.append(light);
    Logger.info(LOG_TAG, 'buildProceduralScene: light appended to sceneRoot');

    Logger.info(LOG_TAG, 'buildProceduralScene: done');
    // 应用当前显示配置(scale/offset/rotation/camera)
    this.applyDisplayConfigToScene();
  }

  /**
   * 安全地给 Geometry 赋材质。
   * 若 mesh 或 subMeshes 为空则跳过并记录警告。
   *
   * @param geom 目标几何体节点
   * @param material 材质
   * @param label 日志标签
   */
  private assignMaterialToGeometry(geom: Geometry, material: Material, label: string): void {
    try {
      const mesh: Mesh = geom.mesh;
      const subMeshes: SubMesh[] = mesh.subMeshes;
      if (subMeshes.length === 0) {
        Logger.warn(LOG_TAG, 'assignMaterial: ' + label + ' has no subMeshes');
        return;
      }
      subMeshes[0].material = material;
      Logger.info(LOG_TAG, 'assignMaterial: ' + label + ' ok');
    } catch (e) {
      Logger.warn(LOG_TAG, 'assignMaterial: ' + label + ' failed: ' + (e as Error)?.message);
    }
  }

  /**
   * 创建材质(使用默认参数)。
   *
   * 注意:第一版不设置 baseColor,因为 MetallicRoughnessMaterial 的 as 类型转换
   * 在运行时可能失败。使用 createMaterial 返回的默认 Material 即可验证渲染管线。
   * 后续 T-3D.2/T-3D.3 再研究如何安全设置 PBR 属性。
   *
   * @param factory 资源工厂
   * @param name 材质名
   * @param materialType 材质类型
   */
  private async createMaterial(
    factory: SceneResourceFactory,
    name: string,
    materialType: MaterialType
  ): Promise<Material> {
    const params: SceneResourceParameters = { name: name };
    const mat: Material = await factory.createMaterial(params, materialType);
    return mat;
  }

  /**
   * 若有动画则启动待机动画。
   * 无动画时不报错,仅记录日志。
   */
  private startIdleIfNeeded(): void {
    if (this.sceneValue === null) {
      return;
    }
    const animations: Animation[] = this.sceneValue.animations;
    if (animations.length === 0) {
      Logger.info(LOG_TAG, 'no animations in scene, skip idle');
      return;
    }
    this.currentAnimation = animations[0];
    this.currentAnimation.enabled = true;
    this.currentAnimation.start();
    this.setState(Character3DLoadStateEnum.Playing);
  }

  /**
   * 播放(从 Ready/Paused 进入 Playing)。
   */
  play(): void {
    if (this.disposed || !this.canRespondToUserAction()) {
      return;
    }
    if (this.stateValue === Character3DLoadStateEnum.Playing) {
      return;
    }
    this.setState(Character3DLoadStateEnum.Playing);
    if (this.currentAnimation !== null) {
      try {
        this.currentAnimation.start();
      } catch (e) {
        Logger.warn(LOG_TAG, 'animation start failed: ' + (e as Error)?.message);
      }
    }
  }

  /**
   * 暂停(从 Playing 进入 Paused)。
   */
  pause(): void {
    if (this.disposed || this.stateValue !== Character3DLoadStateEnum.Playing) {
      return;
    }
    this.setState(Character3DLoadStateEnum.Paused);
    if (this.currentAnimation !== null) {
      try {
        this.currentAnimation.pause();
      } catch (e) {
        Logger.warn(LOG_TAG, 'animation pause failed: ' + (e as Error)?.message);
      }
    }
  }

  /**
   * 停止并回到 Ready(从 Playing/Paused 进入 Ready)。
   */
  stop(): void {
    if (this.disposed) {
      return;
    }
    if (this.stateValue !== Character3DLoadStateEnum.Playing
      && this.stateValue !== Character3DLoadStateEnum.Paused) {
      return;
    }
    this.setState(Character3DLoadStateEnum.Ready);
    if (this.currentAnimation !== null) {
      try {
        this.currentAnimation.stop();
      } catch (e) {
        Logger.warn(LOG_TAG, 'animation stop failed: ' + (e as Error)?.message);
      }
    }
  }

  /**
   * 重新加载(从任意非 Disposed 状态回到 Loading)。
   */
  reload(): void {
    if (this.disposed) {
      return;
    }
    this.releaseScene();
    this.operationId++;
    this.setState(Character3DLoadStateEnum.Disposed);
    this.loadAsync();
  }

  /**
   * 注入 Character3DService(必须在 initialize 之前调用)。
   * 注入后,initialize 会自动读取已保存的模型 URI。
   */
  setService(service: Character3DService): void {
    this.service = service;
  }

  /**
   * 导入外部 GLB/GLTF 模型文件。
   *
   * 流程:
   * 1. 调用 Character3DService.importModel 复制文件到沙箱并持久化路径
   * 2. 更新 currentModelUri / currentDisplayName / currentModelId / currentModelInfo
   * 3. T-3D.4A: 应用 autoFitConfig(若该 modelId 首次导入)
   * 4. 重新加载场景
   *
   * @param sourceUri DocumentViewPicker 返回的源 URI
   */
  async importModel(sourceUri: string): Promise<void> {
    if (this.disposed) {
      this.fireError('ViewModel 已释放,无法导入');
      return;
    }
    if (this.service === null) {
      this.fireError('未注入 Character3DService,无法导入');
      return;
    }
    if (sourceUri.length === 0) {
      this.fireError('源 URI 为空');
      return;
    }
    try {
      const result: Character3DImportResult = await this.service.importModel(sourceUri);
      this.currentModelUri = result.modelUri;
      this.currentDisplayName = result.displayName;
      this.currentModelId = result.displayName;
      this.currentModelInfo = result.modelInfo;
      // T-3D.4A: 读取该 modelId 的保存配置;若首次导入,service 已保存 autoFit 作为默认
      this.displayConfig = await this.service.getDisplayConfig(this.currentModelId);
      this.rotationYDeg = this.displayConfig.rotationYDeg;
      Logger.info(LOG_TAG, 'importModel ok, modelId=' + this.currentModelId
        + ', autoFit scale=' + result.autoFitConfig.scale
        + ', camDist=' + result.autoFitConfig.cameraDistance
        + ', reloading scene');
      this.reload();
    } catch (e) {
      const msg: string = (e as Error)?.message ?? 'import failed';
      Logger.error(LOG_TAG, 'importModel failed: ' + msg);
      this.fireError('导入失败: ' + msg);
    }
  }

  /**
   * 清除当前外部模型,回退到程序化几何体。
   */
  async clearModel(): Promise<void> {
    if (this.disposed) {
      this.fireError('ViewModel 已释放,无法清除');
      return;
    }
    if (this.service === null) {
      this.fireError('未注入 Character3DService,无法清除');
      return;
    }
    try {
      await this.service.clearModel();
      this.currentModelUri = '';
      this.currentDisplayName = '';
      this.currentModelId = '';
      this.currentModelInfo = null;
      this.currentBounds = null;
      this.displayConfig = createDefaultDisplayConfig();
      this.rotationYDeg = this.displayConfig.rotationYDeg;
      Logger.info(LOG_TAG, 'clearModel ok, reloading scene');
      this.reload();
    } catch (e) {
      const msg: string = (e as Error)?.message ?? 'clear failed';
      Logger.error(LOG_TAG, 'clearModel failed: ' + msg);
      this.fireError('清除失败: ' + msg);
    }
  }

  /**
   * 从 rawfile 加载内置测试模型(用于 T-3D.2 设备验证)。
   */
  async importFromRawfile(): Promise<void> {
    if (this.disposed) {
      this.fireError('ViewModel 已释放,无法导入');
      return;
    }
    if (this.service === null) {
      this.fireError('未注入 Character3DService,无法导入');
      return;
    }
    try {
      const result: Character3DImportResult = await this.service.importFromRawfile();
      this.currentModelUri = result.modelUri;
      this.currentDisplayName = result.displayName;
      this.currentModelId = result.displayName;
      this.currentModelInfo = result.modelInfo;
      // T-3D.4A: 读取该 modelId 的保存配置;若首次导入,service 已保存 autoFit 作为默认
      this.displayConfig = await this.service.getDisplayConfig(this.currentModelId);
      this.rotationYDeg = this.displayConfig.rotationYDeg;
      Logger.info(LOG_TAG, 'importFromRawfile ok, modelId=' + this.currentModelId
        + ', autoFit scale=' + result.autoFitConfig.scale
        + ', camDist=' + result.autoFitConfig.cameraDistance
        + ', reloading scene');
      this.reload();
    } catch (e) {
      const msg: string = (e as Error)?.message ?? 'import rawfile failed';
      Logger.error(LOG_TAG, 'importFromRawfile failed: ' + msg);
      this.fireError('导入测试模型失败: ' + msg);
    }
  }

  /**
   * T-3D.4A: 从 rawfile 按指定文件名加载模型(用于设备验收时导入真实模型)。
   *
   * 模拟器无 Download 目录,改用 rawfile 方式加载 teacher-love.glb。
   *
   * @param fileName rawfile 中的文件名(如 'teacher-love.glb')
   * @param displayName 显示名(用于 UI 和 modelId 隔离)
   */
  async importFromRawfileByName(fileName: string, displayName: string): Promise<void> {
    if (this.disposed) {
      this.fireError('ViewModel 已释放,无法导入');
      return;
    }
    if (this.service === null) {
      this.fireError('未注入 Character3DService,无法导入');
      return;
    }
    try {
      const result: Character3DImportResult =
        await this.service.importFromRawfileByName(fileName, displayName);
      this.currentModelUri = result.modelUri;
      this.currentDisplayName = result.displayName;
      this.currentModelId = result.displayName;
      this.currentModelInfo = result.modelInfo;
      // T-3D.4A: 读取该 modelId 的保存配置;若首次导入,service 已保存 autoFit 作为默认
      this.displayConfig = await this.service.getDisplayConfig(this.currentModelId);
      this.rotationYDeg = this.displayConfig.rotationYDeg;
      Logger.info(LOG_TAG, 'importFromRawfileByName ok, modelId=' + this.currentModelId
        + ', autoFit scale=' + result.autoFitConfig.scale
        + ', camDist=' + result.autoFitConfig.cameraDistance
        + ', reloading scene');
      this.reload();
    } catch (e) {
      const msg: string = (e as Error)?.message ?? 'import rawfile by name failed';
      Logger.error(LOG_TAG, 'importFromRawfileByName failed: ' + msg);
      this.fireError('导入模型失败: ' + msg);
    }
  }

  /**
   * 获取当前模型来源文本(用于 UI 显示)。
   * 返回 '程序化几何体' 或 '<模型显示名>'。
   */
  getModelSourceText(): string {
    if (this.currentDisplayName.length > 0) {
      return this.currentDisplayName;
    }
    return '程序化几何体';
  }

  /**
   * 是否加载了外部模型。
   */
  isExternalModel(): boolean {
    return this.currentModelUri.length > 0;
  }

  /**
   * 获取当前模型摘要信息(导入后非空;程序化几何体或重启后未验证时为 null)。
   */
  getModelInfo(): GltfModelInfo | null {
    return this.currentModelInfo;
  }

  /**
   * T-3D.4: 获取当前显示配置副本(供 UI 读取 Slider 当前值)。
   */
  getDisplayConfig(): Character3DDisplayConfig {
    return this.displayConfig;
  }

  /**
   * T-3D.4: 实时更新显示配置(只改内存,不落盘)。
   * 供 UI Slider 拖动过程中调用,避免高频写盘。
   * 调用后立即应用到场景,并触发 onDisplayConfigChanged 回调刷新 UI。
   *
   * @param partial 部分字段(仅需要变更的字段,其它字段保留)
   */
  updateDisplayConfig(partial: Partial<Character3DDisplayConfig>): void {
    if (this.disposed) {
      return;
    }
    const merged: Character3DDisplayConfig = {
      scale: partial.scale !== undefined ? partial.scale : this.displayConfig.scale,
      offsetX: partial.offsetX !== undefined ? partial.offsetX : this.displayConfig.offsetX,
      offsetY: partial.offsetY !== undefined ? partial.offsetY : this.displayConfig.offsetY,
      offsetZ: partial.offsetZ !== undefined ? partial.offsetZ : this.displayConfig.offsetZ,
      rotationXDeg: partial.rotationXDeg !== undefined
        ? partial.rotationXDeg : this.displayConfig.rotationXDeg,
      rotationYDeg: partial.rotationYDeg !== undefined
        ? partial.rotationYDeg : this.displayConfig.rotationYDeg,
      rotationZDeg: partial.rotationZDeg !== undefined
        ? partial.rotationZDeg : this.displayConfig.rotationZDeg,
      cameraDistance: partial.cameraDistance !== undefined
        ? partial.cameraDistance : this.displayConfig.cameraDistance
    };
    // sanitize 防御非法值,夹紧到合法范围
    const safe: Character3DDisplayConfig = sanitizeDisplayConfig(merged);
    this.displayConfig = safe;
    // 同步 rotationYDeg(拖动旋转与 Slider 共用同一字段)
    this.rotationYDeg = safe.rotationYDeg;
    this.applyDisplayConfigToScene();
    if (this.onDisplayConfigChanged !== null) {
      this.onDisplayConfigChanged(safe);
    }
    if (this.onRotationChanged !== null) {
      this.onRotationChanged(this.rotationYDeg);
    }
  }

  /**
   * T-3D.4A: 持久化当前 displayConfig 到 Preferences(按 currentModelId 隔离)。
   * 供 UI 在 Slider 拖动结束或点击"保存"按钮时调用。
   */
  async saveDisplayConfig(): Promise<void> {
    if (this.disposed || this.service === null) {
      return;
    }
    if (this.currentModelId.length === 0) {
      Logger.warn(LOG_TAG, 'saveDisplayConfig skipped: modelId empty');
      return;
    }
    try {
      const saved: Character3DDisplayConfig = await this.service.saveDisplayConfig(
        this.currentModelId, this.displayConfig
      );
      // 落盘后的 sanitized 值可能与内存有差异(夹紧),回写内存
      this.displayConfig = saved;
      this.rotationYDeg = saved.rotationYDeg;
      Logger.info(LOG_TAG, 'saveDisplayConfig ok, modelId=' + this.currentModelId);
    } catch (e) {
      Logger.warn(LOG_TAG, 'saveDisplayConfig failed: ' + (e as Error)?.message);
    }
  }

  /**
   * T-3D.4A: 恢复默认显示配置。
   * 若有 currentModelInfo,使用该模型的自适应默认配置;否则使用全局默认配置。
   * 同时落盘删除该 modelId 的保存配置(下次读取时回退自适应或全局默认)。
   */
  async resetDisplayConfig(): Promise<void> {
    if (this.disposed) {
      return;
    }
    let def: Character3DDisplayConfig;
    if (this.service !== null && this.currentModelInfo !== null && this.currentModelId.length > 0) {
      // T-3D.4A: 使用该模型的自适应默认配置
      try {
        def = await this.service.resetDisplayConfig(this.currentModelId, this.currentModelInfo);
      } catch (e) {
        Logger.warn(LOG_TAG, 'resetDisplayConfig persist failed: ' + (e as Error)?.message);
        def = createDefaultDisplayConfig();
      }
    } else {
      def = createDefaultDisplayConfig();
      if (this.service !== null && this.currentModelId.length > 0) {
        try {
          await this.service.resetDisplayConfig(this.currentModelId);
        } catch (e) {
          Logger.warn(LOG_TAG, 'resetDisplayConfig persist failed: ' + (e as Error)?.message);
        }
      }
    }
    this.displayConfig = def;
    this.rotationYDeg = def.rotationYDeg;
    this.applyDisplayConfigToScene();
    if (this.onDisplayConfigChanged !== null) {
      this.onDisplayConfigChanged(def);
    }
    if (this.onRotationChanged !== null) {
      this.onRotationChanged(this.rotationYDeg);
    }
  }

  /**
   * T-3D.4A: 自动适配视角。
   * 根据当前模型的 Bounds 重新计算 scale/offset/cameraDistance,应用到场景。
   * 不修改 rotation(保留用户当前视角方向)。
   */
  autoFitView(): void {
    if (this.disposed) {
      return;
    }
    if (this.currentModelInfo === null) {
      Logger.warn(LOG_TAG, 'autoFitView skipped: no model info');
      return;
    }
    const bounds: ModelBounds | null = computeBoundsFromGltf(this.currentModelInfo);
    if (!isBoundsValid(bounds)) {
      Logger.warn(LOG_TAG, 'autoFitView skipped: bounds invalid');
      return;
    }
    this.currentBounds = bounds;
    const autoFit: Character3DDisplayConfig = computeAutoFitDisplayConfig(bounds);
    // 保留用户当前的 rotationY(视角方向),其他字段使用 autoFit
    const merged: Character3DDisplayConfig = {
      scale: autoFit.scale,
      offsetX: autoFit.offsetX,
      offsetY: autoFit.offsetY,
      offsetZ: autoFit.offsetZ,
      rotationXDeg: autoFit.rotationXDeg,
      rotationYDeg: this.displayConfig.rotationYDeg,
      rotationZDeg: autoFit.rotationZDeg,
      cameraDistance: autoFit.cameraDistance
    };
    const safe: Character3DDisplayConfig = sanitizeDisplayConfig(merged);
    this.displayConfig = safe;
    this.rotationYDeg = safe.rotationYDeg;
    this.applyDisplayConfigToScene();
    if (this.onDisplayConfigChanged !== null) {
      this.onDisplayConfigChanged(safe);
    }
    if (this.onRotationChanged !== null) {
      this.onRotationChanged(this.rotationYDeg);
    }
    Logger.info(LOG_TAG, 'autoFitView applied, scale=' + safe.scale
      + ', camDist=' + safe.cameraDistance
      + ', offset=(' + safe.offsetX.toFixed(3) + ','
      + safe.offsetY.toFixed(3) + ',' + safe.offsetZ.toFixed(3) + ')');
  }

  /**
   * T-3D.4A: 获取当前模型 Bounds(用于 UI 显示模型尺寸摘要)。
   */
  getCurrentBounds(): ModelBounds | null {
    return this.currentBounds;
  }

  /**
   * 触发模型来源变更回调。
   */
  private fireModelSourceChanged(): void {
    if (this.onModelSourceChanged !== null) {
      this.onModelSourceChanged(
        this.currentDisplayName,
        this.currentModelUri.length > 0,
        this.currentModelInfo
      );
    }
  }

  /**
   * 页面不可见时暂停渲染。
   */
  onPageHidden(): void {
    this.pageHidden = true;
    if (this.stateValue === Character3DLoadStateEnum.Playing) {
      this.pause();
    }
  }

  /**
   * 页面恢复可见时恢复播放(如果之前在播放)。
   */
  onPageShown(): void {
    this.pageHidden = false;
    if (this.stateValue === Character3DLoadStateEnum.Paused && !this.disposed) {
      this.play();
    }
  }

  /**
   * 处理拖动(水平方向)。
   * 拖动只改内存中的 rotationYDeg,不落盘(高频写盘禁止)。
   * 拖动结束后由 UI 调用 saveDisplayConfig() 持久化。
   *
   * T-3D.5A: 增加死区,小幅抖动不触发旋转。
   *
   * @param deltaPxX X 轴像素位移(正为右,负为左)
   */
  handleDragX(deltaPxX: number): void {
    if (this.disposed || !this.canRespondToUserAction()) {
      return;
    }
    // T-3D.5A: 死区过滤
    if (Math.abs(deltaPxX) < DRAG_DEAD_ZONE_PX) {
      return;
    }
    const delta: number = computeDragRotationDeg(deltaPxX, DRAG_SENSITIVITY, DRAG_MAX_DEG);
    if (delta === 0) {
      return;
    }
    this.rotationYDeg = normalizeRotationDeg(this.rotationYDeg + delta);
    // 同步到 displayConfig 内存态(不落盘)
    this.displayConfig = {
      scale: this.displayConfig.scale,
      offsetX: this.displayConfig.offsetX,
      offsetY: this.displayConfig.offsetY,
      offsetZ: this.displayConfig.offsetZ,
      rotationXDeg: this.displayConfig.rotationXDeg,
      rotationYDeg: this.rotationYDeg,
      rotationZDeg: this.displayConfig.rotationZDeg,
      cameraDistance: this.displayConfig.cameraDistance
    };
    this.applyDisplayConfigToScene();
    if (this.onRotationChanged !== null) {
      this.onRotationChanged(this.rotationYDeg);
    }
  }

  /**
   * T-3D.5A: 处理拖动(垂直方向,Pitch 旋转)。
   *
   * 行为:
   * - deltaY > 0(向下拖)→ rotationXDeg 增加(模型抬头)
   * - deltaY < 0(向上拖)→ rotationXDeg 减少(模型低头)
   * - Pitch 限制在 [PITCH_MIN_DEG, PITCH_MAX_DEG] = [-60, 60]
   * - 死区过滤,小幅抖动不触发
   * - 只改内存,不落盘
   *
   * @param deltaPxY Y 轴像素位移(正为下,负为上)
   */
  handleDragY(deltaPxY: number): void {
    if (this.disposed || !this.canRespondToUserAction()) {
      return;
    }
    // T-3D.5A: 死区过滤
    if (Math.abs(deltaPxY) < DRAG_DEAD_ZONE_PX) {
      return;
    }
    const delta: number = computeDragRotationDeg(deltaPxY, DRAG_SENSITIVITY, DRAG_MAX_DEG);
    if (delta === 0) {
      return;
    }
    // Pitch 限制在 [-60, 60]
    let newPitch: number = this.displayConfig.rotationXDeg + delta;
    if (newPitch > PITCH_MAX_DEG) {
      newPitch = PITCH_MAX_DEG;
    }
    if (newPitch < PITCH_MIN_DEG) {
      newPitch = PITCH_MIN_DEG;
    }
    if (newPitch === this.displayConfig.rotationXDeg) {
      return;
    }
    // 同步到 displayConfig 内存态(不落盘)
    this.displayConfig = {
      scale: this.displayConfig.scale,
      offsetX: this.displayConfig.offsetX,
      offsetY: this.displayConfig.offsetY,
      offsetZ: this.displayConfig.offsetZ,
      rotationXDeg: newPitch,
      rotationYDeg: this.displayConfig.rotationYDeg,
      rotationZDeg: this.displayConfig.rotationZDeg,
      cameraDistance: this.displayConfig.cameraDistance
    };
    this.applyDisplayConfigToScene();
    if (this.onDisplayConfigChanged !== null) {
      this.onDisplayConfigChanged(this.displayConfig);
    }
  }

  /**
   * 重置视角(Y 轴和 X 轴旋转归零)。
   * 注意:仅重置 rotationX/Y,保留其他显示参数。如需全部重置请用 resetDisplayConfig。
   * T-3D.5A: 同时重置 Pitch(rotationXDeg),与上下旋转功能配套。
   */
  resetView(): void {
    if (this.disposed) {
      return;
    }
    this.rotationYDeg = DEFAULT_VIEW_ROTATION_Y_DEG;
    this.displayConfig = {
      scale: this.displayConfig.scale,
      offsetX: this.displayConfig.offsetX,
      offsetY: this.displayConfig.offsetY,
      offsetZ: this.displayConfig.offsetZ,
      rotationXDeg: DEFAULT_ROTATION_X_DEG,
      rotationYDeg: this.rotationYDeg,
      rotationZDeg: this.displayConfig.rotationZDeg,
      cameraDistance: this.displayConfig.cameraDistance
    };
    this.applyDisplayConfigToScene();
    if (this.onRotationChanged !== null) {
      this.onRotationChanged(this.rotationYDeg);
    }
    if (this.onDisplayConfigChanged !== null) {
      this.onDisplayConfigChanged(this.displayConfig);
    }
  }

  /**
   * 处理触摸反馈。
   */
  handleTouch(): void {
    if (this.disposed) {
      return;
    }
    if (this.onTouchFeedback !== null) {
      this.onTouchFeedback();
    }
  }

  // ===== T-3D.5B: 手势状态机(TouchEvent 驱动) =====

  /**
   * 初始化手势处理器(绑定回调)。
   * 幂等,在 initialize 完成后自动调用。
   */
  private initGestureHandler(): void {
    if (this.gestureHandlerInited) {
      return;
    }
    this.gestureHandlerInited = true;
    const callbacks: GestureCallbacks = {
      onRotate: (deltaYawDeg: number, deltaPitchDeg: number): void => {
        this.applyGestureRotate(deltaYawDeg, deltaPitchDeg);
      },
      onSetOffset: (offsetX: number, offsetY: number): void => {
        this.applyGestureOffset(offsetX, offsetY);
      },
      onSetScale: (scale: number): void => {
        this.applyGestureScale(scale);
      },
      onGestureEnd: (): void => {
        // 手势结束后落盘(异步,不阻塞手势)
        this.saveDisplayConfig().catch((e: Error): void => {
          Logger.warn(LOG_TAG, 'gesture end save failed: ' + e.message);
        });
      }
    };
    this.gestureHandler.setCallbacks(callbacks);
    this.gestureHandler.setCameraDistance(this.displayConfig.cameraDistance);
    this.updateGestureConfig();
  }

  /**
   * 同步当前 displayConfig 到手势处理器。
   */
  private updateGestureConfig(): void {
    const snapshot: GestureConfigSnapshot = {
      scale: this.displayConfig.scale,
      offsetX: this.displayConfig.offsetX,
      offsetY: this.displayConfig.offsetY
    };
    this.gestureHandler.updateCurrentConfig(snapshot);
    this.gestureHandler.updateCurrentPitch(this.displayConfig.rotationXDeg);
    this.gestureHandler.setCameraDistance(this.displayConfig.cameraDistance);
  }

  /**
   * 手势旋转回调:增量角度应用到 rotationYDeg/rotationXDeg。
   */
  private applyGestureRotate(deltaYawDeg: number, deltaPitchDeg: number): void {
    if (this.disposed) {
      return;
    }
    let changed: boolean = false;
    if (deltaYawDeg !== 0) {
      this.rotationYDeg = normalizeRotationDeg(this.rotationYDeg + deltaYawDeg);
      changed = true;
    }
    if (deltaPitchDeg !== 0) {
      let newPitch: number = this.displayConfig.rotationXDeg + deltaPitchDeg;
      if (newPitch > PITCH_MAX_DEG) {
        newPitch = PITCH_MAX_DEG;
      }
      if (newPitch < PITCH_MIN_DEG) {
        newPitch = PITCH_MIN_DEG;
      }
      if (newPitch !== this.displayConfig.rotationXDeg) {
        this.displayConfig = {
          scale: this.displayConfig.scale,
          offsetX: this.displayConfig.offsetX,
          offsetY: this.displayConfig.offsetY,
          offsetZ: this.displayConfig.offsetZ,
          rotationXDeg: newPitch,
          rotationYDeg: this.rotationYDeg,
          rotationZDeg: this.displayConfig.rotationZDeg,
          cameraDistance: this.displayConfig.cameraDistance
        };
        changed = true;
      }
    }
    if (changed) {
      // 确保 rotationYDeg 同步到 displayConfig
      if (this.displayConfig.rotationYDeg !== this.rotationYDeg) {
        this.displayConfig = {
          scale: this.displayConfig.scale,
          offsetX: this.displayConfig.offsetX,
          offsetY: this.displayConfig.offsetY,
          offsetZ: this.displayConfig.offsetZ,
          rotationXDeg: this.displayConfig.rotationXDeg,
          rotationYDeg: this.rotationYDeg,
          rotationZDeg: this.displayConfig.rotationZDeg,
          cameraDistance: this.displayConfig.cameraDistance
        };
      }
      this.applyDisplayConfigToScene();
      this.updateGestureConfig();
      if (this.onRotationChanged !== null) {
        this.onRotationChanged(this.rotationYDeg);
      }
      if (this.onDisplayConfigChanged !== null) {
        this.onDisplayConfigChanged(this.displayConfig);
      }
    }
  }

  /**
   * 手势平移回调:设置绝对 offset。
   */
  private applyGestureOffset(offsetX: number, offsetY: number): void {
    if (this.disposed) {
      return;
    }
    if (this.displayConfig.offsetX === offsetX && this.displayConfig.offsetY === offsetY) {
      return;
    }
    this.displayConfig = {
      scale: this.displayConfig.scale,
      offsetX: offsetX,
      offsetY: offsetY,
      offsetZ: this.displayConfig.offsetZ,
      rotationXDeg: this.displayConfig.rotationXDeg,
      rotationYDeg: this.displayConfig.rotationYDeg,
      rotationZDeg: this.displayConfig.rotationZDeg,
      cameraDistance: this.displayConfig.cameraDistance
    };
    this.applyDisplayConfigToScene();
    this.updateGestureConfig();
    if (this.onDisplayConfigChanged !== null) {
      this.onDisplayConfigChanged(this.displayConfig);
    }
  }

  /**
   * 手势缩放回调:设置绝对 scale。
   */
  private applyGestureScale(scale: number): void {
    if (this.disposed) {
      return;
    }
    if (this.displayConfig.scale === scale) {
      return;
    }
    this.displayConfig = {
      scale: scale,
      offsetX: this.displayConfig.offsetX,
      offsetY: this.displayConfig.offsetY,
      offsetZ: this.displayConfig.offsetZ,
      rotationXDeg: this.displayConfig.rotationXDeg,
      rotationYDeg: this.displayConfig.rotationYDeg,
      rotationZDeg: this.displayConfig.rotationZDeg,
      cameraDistance: this.displayConfig.cameraDistance
    };
    this.applyDisplayConfigToScene();
    this.updateGestureConfig();
    if (this.onDisplayConfigChanged !== null) {
      this.onDisplayConfigChanged(this.displayConfig);
    }
  }

  /**
   * T-3D.5B: 处理触摸开始(由 Character3DPanel 的 onTouch 转发)。
   * @param touches 所有当前活跃触摸点
   * @param changedId 新按下的指针 id
   */
  handleTouchStart(touches: TouchPointData[], changedId: number): void {
    if (this.disposed) {
      return;
    }
    this.initGestureHandler();
    this.updateGestureConfig();
    this.gestureHandler.handleTouch(TouchPhase.Down, touches, changedId, {
      scale: this.displayConfig.scale,
      offsetX: this.displayConfig.offsetX,
      offsetY: this.displayConfig.offsetY
    });
  }

  /**
   * T-3D.5B: 处理触摸移动。
   */
  handleTouchMove(touches: TouchPointData[]): void {
    if (this.disposed) {
      return;
    }
    this.gestureHandler.handleTouch(TouchPhase.Move, touches, -1, {
      scale: this.displayConfig.scale,
      offsetX: this.displayConfig.offsetX,
      offsetY: this.displayConfig.offsetY
    });
  }

  /**
   * T-3D.5B: 处理触摸抬起。
   * @param touches 抬起后剩余的活跃触摸点
   * @param changedId 抬起的指针 id
   */
  handleTouchUp(touches: TouchPointData[], changedId: number): void {
    if (this.disposed) {
      return;
    }
    this.gestureHandler.handleTouch(TouchPhase.Up, touches, changedId, {
      scale: this.displayConfig.scale,
      offsetX: this.displayConfig.offsetX,
      offsetY: this.displayConfig.offsetY
    });
  }

  /**
   * T-3D.5B: 处理触摸取消。
   */
  handleTouchCancel(): void {
    if (this.disposed) {
      return;
    }
    this.gestureHandler.handleTouch(TouchPhase.Cancel, [], -1, {
      scale: this.displayConfig.scale,
      offsetX: this.displayConfig.offsetX,
      offsetY: this.displayConfig.offsetY
    });
  }

  /**
   * T-3D.5B: 设置手势处理器视口尺寸。
   */
  setGestureViewport(width: number, height: number): void {
    this.gestureHandler.setViewport(width, height);
  }

  /**
   * T-3D.5B: 设置旋转灵敏度(0.2 ~ 2.0)。
   */
  setRotationSensitivity(sensitivity: number): void {
    this.gestureHandler.setRotationSensitivity(sensitivity);
  }

  /**
   * T-3D.5B: 获取当前手势状态(用于调试)。
   */
  getGestureState(): GestureState {
    return this.gestureHandler.getState();
  }

  /**
   * 释放所有资源。
   * 幂等:重复调用安全。
   */
  dispose(): void {
    if (this.disposed) {
      return;
    }
    this.disposed = true;
    this.operationId++;
    // T-3D.5B: 先释放手势处理器,确保后续回调不再触发
    this.gestureHandler.dispose();
    this.releaseScene();
    this.setState(Character3DLoadStateEnum.Disposed);
    this.onStateChanged = null;
    this.onRotationChanged = null;
    this.onError = null;
    this.onTouchFeedback = null;
    this.onModelSourceChanged = null;
    this.onDisplayConfigChanged = null;
  }

  /**
   * 释放 Scene 持有的资源(不修改 state)。
   */
  private releaseScene(): void {
    this.currentAnimation = null;
    this.cameraValue = null;
    this.rootNode = null;
    if (this.sceneValue !== null) {
      try {
        this.sceneValue.destroy();
      } catch (e) {
        Logger.warn(LOG_TAG, 'scene destroy failed: ' + (e as Error)?.message);
      }
      this.sceneValue = null;
    }
  }

  /**
   * 将当前 displayConfig 应用到场景:
   * - rootNode:position(补偿后 offset) + rotation(rotationXYZDeg) + scale(scale)
   * - camera:position(0, camY, cameraDistance) + fov/near/far
   *
   * T-3D.4A: 相机 Y 位置根据模型类型决定:
   * - 外部模型:camY = 0(模型中心通过 offset 移到原点,相机正对原点)
   * - 程序化几何体:camY = CAMERA_HEIGHT(几何体在原点上方,相机俯视)
   *
   * T-3D.5A: 旋转中心跟随(数学补偿方案)
   * - 问题:rootNode 同时设置 position(offset)和 rotation,旋转围绕 rootNode 原点
   *   模型几何体中心在 center 位置(相对 rootNode 原点),旋转时模型围绕 offset 公转
   * - 修复:计算旋转后的模型中心 R*(center*scale),rootNode.position = offset - R*(center*scale)
   *   这样模型中心(世界空间)= rootNode.position + R*(center*scale) = offset(固定)
   *   旋转围绕模型中心(= offset 位置)进行,实现原地自转
   * - 仅对外部模型且有有效 Bounds 时启用补偿
   * - 程序化几何体无 Bounds,保持原行为(围绕 rootNode 原点旋转)
   *
   * 若 rootNode 或 cameraValue 为 null 则跳过对应部分。
   */
  private applyDisplayConfigToScene(): void {
    const cfg: Character3DDisplayConfig = this.displayConfig;
    const isExternal: boolean = this.currentModelUri.length > 0;
    const camY: number = isExternal ? 0 : CAMERA_HEIGHT;
    // 应用到 root 节点
    if (this.rootNode !== null) {
      try {
        // 三轴旋转:按 ZYX 顺序合成四元数
        const rxRad: number = cfg.rotationXDeg * Math.PI / 180;
        const ryRad: number = cfg.rotationYDeg * Math.PI / 180;
        const rzRad: number = cfg.rotationZDeg * Math.PI / 180;
        const qx: Quaternion = this.quatFromAxisAngle(rxRad, 1, 0, 0);
        const qy: Quaternion = this.quatFromAxisAngle(ryRad, 0, 1, 0);
        const qz: Quaternion = this.quatFromAxisAngle(rzRad, 0, 0, 1);
        // 组合:q = qz * qy * qx (先 X 再 Y 再 Z)
        const qzy: Quaternion = this.quatMultiply(qz, qy);
        const qFinal: Quaternion = this.quatMultiply(qzy, qx);

        // T-3D.5A: 旋转中心跟随补偿
        // 模型几何体中心(相对 rootNode 原点,应用 scale 后)= center * scale
        // 旋转后模型中心(相对 rootNode 原点)= R * (center * scale)
        // 世界空间模型中心 = rootNode.position + R * (center * scale)
        // 要让模型中心固定在 offset 位置:rootNode.position = offset - R * (center * scale)
        let posX: number = cfg.offsetX;
        let posY: number = cfg.offsetY;
        let posZ: number = cfg.offsetZ;
        if (isExternal && this.currentBounds !== null) {
          const cx: number = this.currentBounds.centerX;
          const cy: number = this.currentBounds.centerY;
          const cz: number = this.currentBounds.centerZ;
          // 应用 scale 后的模型中心
          const scx: number = cx * cfg.scale;
          const scy: number = cy * cfg.scale;
          const scz: number = cz * cfg.scale;
          // 旋转后的模型中心 = R * (center * scale)
          const rotated: Position3 = this.rotateVec3(qFinal, scx, scy, scz);
          // rootNode.position = offset - 旋转后的模型中心
          posX = cfg.offsetX - rotated.x;
          posY = cfg.offsetY - rotated.y;
          posZ = cfg.offsetZ - rotated.z;
        }

        this.rootNode.position = { x: posX, y: posY, z: posZ };
        this.rootNode.rotation = qFinal;
        this.rootNode.scale = { x: cfg.scale, y: cfg.scale, z: cfg.scale };
      } catch (e) {
        Logger.warn(LOG_TAG, 'applyDisplayConfig root failed: ' + (e as Error)?.message);
      }
    }
    // 应用到相机
    if (this.cameraValue !== null) {
      try {
        this.cameraValue.position = {
          x: 0,
          y: camY,
          z: cfg.cameraDistance
        };
        this.cameraValue.fov = CAMERA_FOV;
        this.cameraValue.nearPlane = CAMERA_NEAR;
        this.cameraValue.farPlane = CAMERA_FAR;
      } catch (e) {
        Logger.warn(LOG_TAG, 'applyDisplayConfig camera failed: ' + (e as Error)?.message);
      }
    }
  }

  /**
   * T-3D.5A: 四元数旋转向量。
   * 使用公式:v' = v + 2*w*cross(q.xyz, v) + 2*cross(q.xyz, cross(q.xyz, v))
   * 等价于 v' = q * v * q^-1(对纯向量)
   *
   * @param q 单位四元数
   * @param x 向量 X
   * @param y 向量 Y
   * @param z 向量 Z
   * @returns 旋转后的向量
   */
  private rotateVec3(q: Quaternion, x: number, y: number, z: number): Position3 {
    const qx: number = q.x;
    const qy: number = q.y;
    const qz: number = q.z;
    const qw: number = q.w;
    // t = 2 * cross(q.xyz, v)
    const tx: number = 2 * (qy * z - qz * y);
    const ty: number = 2 * (qz * x - qx * z);
    const tz: number = 2 * (qx * y - qy * x);
    // v' = v + q.w * t + cross(q.xyz, t)
    return {
      x: x + qw * tx + (qy * tz - qz * ty),
      y: y + qw * ty + (qz * tx - qx * tz),
      z: z + qw * tz + (qx * ty - qy * tx)
    };
  }

  /**
   * T-3D.4A: 统一的 Camera Fit 方法。
   *
   * 职责:
   * - 设置 Camera 的 position/fov/near/far
   * - 显式启用 Camera(enabled=true,SDK 默认 false)
   * - 设置朝向四元数为单位四元数,使 Camera 在 (0,camY,camDist) 看向 -Z 方向
   *
   * 朝向说明(SDK lookAt 函数等价推导):
   * - eye = (0, camY, camDist),center = (0, camY, 0) - 实际 center 为模型中心
   * - forward = (center - eye) 归一化 = (0, 0, -1)(当 camY 相同时)
   * - up = (0, 1, 0)
   * - 计算 right = up × forward = (1, 0, 0)
   * - 旋转矩阵列向量为 (right, up, -forward) = 单位矩阵
   * - 对应四元数 = (0, 0, 0, 1) 单位四元数
   *
   * 模型中心对齐说明:
   * - 外部模型:camY=0,模型中心通过 displayConfig.offset 移到 (0,0,0),相机正对原点
   * - 程序化几何体:camY=CAMERA_HEIGHT,几何体在原点上方,相机略俯视
   * - 两种情况相机看向 -Z 方向,rotation 均为单位四元数
   *
   * 调用位置:
   * - supplementExternalScene(外部 GLB 加载后补全相机)
   * - buildProceduralScene(程序化几何体场景)
   * - 不在 applyDisplayConfigToScene 中调用(该方法只更新 position/fov/near/far,
   *   enabled 和 rotation 创建后保持不变)
   *
   * @param camera 待配置的 Camera 实例
   * @param camY 相机 Y 坐标(外部模型=0,程序化几何体=CAMERA_HEIGHT)
   * @param camDist 相机 Z 坐标(正数,来自 displayConfig.cameraDistance)
   */
  private applyCameraFit(camera: Camera, camY: number, camDist: number): void {
    try {
      const camPos: Position3 = { x: 0, y: camY, z: camDist };
      camera.position = camPos;
      camera.fov = CAMERA_FOV;
      camera.nearPlane = CAMERA_NEAR;
      camera.farPlane = CAMERA_FAR;
      // T-3D.4A 关键修复: Camera 创建后默认 enabled=false 且无朝向,必须显式启用
      // SDK 文档中 lookAt 函数为示例代码(非内置方法),单位四元数是其等价推导结果
      camera.enabled = true;
      camera.rotation = { x: 0, y: 0, z: 0, w: 1 };
      Logger.info(LOG_TAG, 'applyCameraFit: camY=' + camY.toFixed(3)
        + ', camDist=' + camDist.toFixed(3)
        + ', fov=' + CAMERA_FOV
        + ', enabled=true, rotation=identity');
    } catch (e) {
      Logger.error(LOG_TAG, 'applyCameraFit failed: ' + (e as Error)?.message);
    }
  }

  /**
   * 由轴角(弧度)构造四元数。
   */
  private quatFromAxisAngle(rad: number, ax: number, ay: number, az: number): Quaternion {
    const half: number = rad / 2;
    const s: number = Math.sin(half);
    return {
      x: ax * s,
      y: ay * s,
      z: az * s,
      w: Math.cos(half)
    };
  }

  /**
   * 四元数乘法:qResult = qA * qB。
   */
  private quatMultiply(a: Quaternion, b: Quaternion): Quaternion {
    return {
      x: a.w * b.x + a.x * b.w + a.y * b.z - a.z * b.y,
      y: a.w * b.y - a.x * b.z + a.y * b.w + a.z * b.x,
      z: a.w * b.z + a.x * b.y - a.y * b.x + a.z * b.w,
      w: a.w * b.w - a.x * b.x - a.y * b.y - a.z * b.z
    };
  }

  /**
   * 判断当前状态是否可响应用户操作。
   */
  private canRespondToUserAction(): boolean {
    return this.stateValue === Character3DLoadStateEnum.Ready
      || this.stateValue === Character3DLoadStateEnum.Playing
      || this.stateValue === Character3DLoadStateEnum.Paused;
  }

  /**
   * 安全切换状态。
   * 非法转换记录警告但不抛异常。
   */
  private setState(next: Character3DLoadStateEnum): void {
    if (this.disposed && next !== Character3DLoadStateEnum.Disposed) {
      return;
    }
    if (!isValidStateTransition(this.stateValue, next)) {
      // Disposed 状态下允许强制进入 Disposed(幂等)
      if (next === Character3DLoadStateEnum.Disposed) {
        this.stateValue = next;
        return;
      }
      Logger.warn(LOG_TAG, 'invalid transition: ' + this.stateValue + ' -> ' + next);
      return;
    }
    this.stateValue = next;
    if (this.onStateChanged !== null) {
      this.onStateChanged(next);
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

  /**
   * 获取当前状态。
   */
  getState(): Character3DLoadStateEnum {
    return this.stateValue;
  }

  /**
   * 获取当前 Scene 实例(供 Component3D 渲染)。
   * 已释放或未加载时返回 null。
   */
  getScene(): Scene | null {
    return this.sceneValue;
  }

  /**
   * 获取当前 Y 轴旋转角度(度数)。
   */
  getRotationYDeg(): number {
    return this.rotationYDeg;
  }

  /**
   * 是否已释放。
   */
  isDisposed(): boolean {
    return this.disposed || isDisposedState(this.stateValue);
  }

  /**
   * 是否有可用动画。
   */
  hasAnimation(): boolean {
    return this.sceneValue !== null && this.sceneValue.animations.length > 0;
  }
}
