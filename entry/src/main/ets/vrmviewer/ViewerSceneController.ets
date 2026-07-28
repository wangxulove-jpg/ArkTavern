/**
 * ViewerSceneController VRM Viewer Scene 管理器
 *
 * 负责 Scene 创建、Camera 创建、Light 创建、背景设置、模型挂载/移除、销毁。
 * 不直接持有模型引用(由 ViewerModelController 管理)。
 *
 * Reference:
 * - figure-main: index.html L434–489 (initThree: Scene/Camera/Light/背景初始化)
 * - ownverse-vrm-viewer: analysis/SCENE_PIPELINE.md (Renderer/Scene/Camera/Controls/Light),
 *   analysis/VIEWER_ARCHITECTURE.md §3 Bootstrap Sequence
 */

import {
  Camera,
  Color,
  DirectionalLight,
  EnvironmentBackgroundType,
  Light,
  LightType,
  Node,
  RenderingPipelineType,
  Scene,
  SceneNodeParameters,
  CameraParameters
} from '@kit.ArkGraphics3D';
import {
  DEFAULT_BACKGROUND_COLOR,
  DEFAULT_CAMERA_FAR,
  DEFAULT_CAMERA_FOV,
  DEFAULT_CAMERA_NEAR,
  DEFAULT_CAMERA_POSITION,
  DEFAULT_CAMERA_TARGET,
  DEFAULT_LIGHT_COLOR,
  DEFAULT_LIGHT_INTENSITY,
  DEFAULT_LIGHT_POSITION,
  ViewerError,
  ViewerState
} from './ViewerTypes';

/**
 * Scene 控制器,持有 Scene/Camera/Light 三个核心资源。
 *
 * 生命周期:
 * - initialize(): 创建空 Scene + Camera + Light,转 READY(无模型)。
 * - attachModel(node): 将模型根节点挂到 Scene.root 下。
 * - detachModel(node): 从 Scene.root 移除模型根节点。
 * - destroy(): 释放 Light/Camera/Scene。
 */
export class ViewerSceneController {
  private scene: Scene | null = null;
  private camera: Camera | null = null;
  private light: Light | null = null;

  /**
   * 创建空 Scene、Camera、Light,并完成默认配置。
   *
   * 幂等:重复调用不会重复创建,直接返回。
   *
   * @throws ViewerError 若 Scene/Camera/Light 创建失败
   */
  public async initialize(): Promise<void> {
    if (this.scene !== null) {
      return;
    }

    try {
      // 1. 创建空 Scene(不传 uri,返回空场景)
      //    Reference: figure-main `new THREE.Scene()`
      //               ownverse SCENE_PIPELINE §1
      this.scene = await Scene.load();

      if (this.scene === null) {
        throw new Error('Scene.load() returned null');
      }

      const factory = this.scene.getResourceFactory();

      // 2. 创建 Camera 并配置默认参数
      //    Reference: figure-main PerspectiveCamera(30, aspect, 0.1, 20),
      //               position=(0,1.25,2); OWNverse (0,1.5,3);
      //               任务指令采纳 (0,1.5,3) + far=1000
      const camParams: SceneNodeParameters = { name: 'viewerCamera' };
      const camExtra: CameraParameters = {
        renderingPipeline: RenderingPipelineType.FORWARD_LIGHTWEIGHT
      };
      this.camera = await factory.createCamera(camParams, camExtra);

      if (this.camera === null) {
        throw new Error('createCamera() returned null');
      }

      this.camera.fov = DEFAULT_CAMERA_FOV;
      this.camera.nearPlane = DEFAULT_CAMERA_NEAR;
      this.camera.farPlane = DEFAULT_CAMERA_FAR;
      this.camera.position = DEFAULT_CAMERA_POSITION;
      // 相机看向 (0,1.5,0):视线方向 = target - position = (0,0,-1),
      // 与相机本地 -Z 前向一致,故 rotation = identity。
      this.camera.rotation = { x: 0, y: 0, z: 0, w: 1 };
      this.camera.clearColor = DEFAULT_BACKGROUND_COLOR;
      this.camera.enabled = true;

      // 3. 将 Camera 挂到 Scene.root
      //    ArkGraphics3D 要求 Camera 作为 Node 挂在 Scene 树中才能生效
      const rootForCam = this.scene.root;
      if (rootForCam !== null) {
        rootForCam.children.append(this.camera);
      }

      // 4. 创建 DirectionalLight
      //    Reference: figure-main DirectionalLight(white, 3.0) pos=(1,1,1).normalize()
      //               ownverse DirectionalLight(white) dir=(1,1,1).normalize()
      const lightParams: SceneNodeParameters = { name: 'mainLight' };
      this.light = await factory.createLight(lightParams, LightType.DIRECTIONAL);

      if (this.light === null) {
        throw new Error('createLight() returned null');
      }

      this.light.color = DEFAULT_LIGHT_COLOR;
      this.light.intensity = DEFAULT_LIGHT_INTENSITY;
      this.light.position = DEFAULT_LIGHT_POSITION;
      this.light.rotation = { x: 0, y: 0, z: 0, w: 1 };
      this.light.enabled = true;
      this.light.shadowEnabled = false;

      const rootForLight = this.scene.root;
      if (rootForLight !== null) {
        rootForLight.children.append(this.light);
      }

      // 5. 设置背景:BACKGROUND_NONE 让 Camera.clearColor 生效
      //    Reference: ArkGraphics3D Camera.clearColor 文档:
      //    "Background clear color (environment background overrides this color,
      //     BACKGROUND_NONE is needed for this to actually take effect)."
      this.scene.environment.backgroundType = EnvironmentBackgroundType.BACKGROUND_NONE;
    } catch (e) {
      // 初始化失败:清理已创建的资源
      this.cleanupPartialInit();
      const msg = e instanceof Error ? e.message : String(e);
      throw new ViewerError(`Scene initialize failed: ${msg}`, ViewerState.INITIALIZING);
    }
  }

  /**
   * 将模型根节点挂到 Scene.root 下。
   *
   * @param node 模型根节点(来自另一个 Scene.load(uri) 的 root)
   */
  public attachModel(node: Node): void {
    const s = this.scene;
    if (s === null) {
      return;
    }
    const root = s.root;
    if (root === null) {
      return;
    }
    root.children.append(node);
  }

  /**
   * 从 Scene.root 移除模型根节点(不销毁,由 ResourceDisposer 负责)。
   *
   * @param node 模型根节点
   */
  public detachModel(node: Node): void {
    const s = this.scene;
    if (s === null) {
      return;
    }
    const root = s.root;
    if (root === null) {
      return;
    }
    root.children.remove(node);
  }

  /**
   * 获取 Scene 供 Component3D 绑定。
   * @returns Scene 或 null(未初始化)
   */
  public getScene(): Scene | null {
    return this.scene;
  }

  /**
   * 获取 Camera 供 CameraController 操作。
   * @returns Camera 或 null(未初始化)
   */
  public getCamera(): Camera | null {
    return this.camera;
  }

  /**
   * 获取 Light 供调试显示。
   * @returns Light 或 null(未初始化)
   */
  public getLight(): Light | null {
    return this.light;
  }

  /**
   * 设置背景色(通过 Camera.clearColor)。
   * 必须保证 environment.backgroundType = BACKGROUND_NONE 才能生效。
   *
   * @param color 背景色
   */
  public setBackgroundColor(color: Color): void {
    if (this.camera !== null) {
      this.camera.clearColor = color;
    }
  }

  /**
   * 销毁 Scene 及其所有子资源(Light/Camera)。
   *
   * 幂等:重复调用不崩溃。
   * 注意:模型资源由 ViewerResourceDisposer 单独释放。
   */
  public destroy(): void {
    if (this.light !== null) {
      try {
        this.light.destroy();
      } catch (_) {
        // 忽略重复销毁
      }
      this.light = null;
    }

    if (this.camera !== null) {
      try {
        this.camera.destroy();
      } catch (_) {
        // 忽略重复销毁
      }
      this.camera = null;
    }

    if (this.scene !== null) {
      try {
        this.scene.destroy();
      } catch (_) {
        // 忽略重复销毁
      }
      this.scene = null;
    }
  }

  /**
   * 初始化失败时清理已创建的部分资源。
   */
  private cleanupPartialInit(): void {
    if (this.light !== null) {
      try {
        this.light.destroy();
      } catch (_) {
        // 忽略
      }
      this.light = null;
    }
    if (this.camera !== null) {
      try {
        this.camera.destroy();
      } catch (_) {
        // 忽略
      }
      this.camera = null;
    }
    if (this.scene !== null) {
      try {
        this.scene.destroy();
      } catch (_) {
        // 忽略
      }
      this.scene = null;
    }
  }
}
