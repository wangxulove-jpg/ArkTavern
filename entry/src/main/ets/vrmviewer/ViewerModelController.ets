/**
 * ViewerModelController VRM Viewer 模型管理器
 *
 * 负责测试 VRM 加载、模型替换、加载失败处理、状态推进。
 * 通过 loadGeneration 防止异步竞态,通过 isDisposed 防止销毁后回调。
 *
 * Reference:
 * - figure-main: index.html L899–1055 (loadVRM: GLTFLoader + VRMLoaderPlugin,
 *   旧模型卸载, VRM 0.x/1.x 旋转处理), L830–832 (replaceWithDefaultVrm)
 * - ownverse-vrm-viewer: analysis/MODEL_LOADING_PIPELINE.md (VRM 加载链),
 *   analysis/VIEWER_ARCHITECTURE.md §5.2 Avatar Swap Flow
 *
 * 模型替换流程(任务指令第十一条):
 * 1. 标记 LOADING_MODEL
 * 2. generation = ++loadGeneration
 * 3. 停止旧模型更新
 * 4. 从 Scene 移除旧模型
 * 5. 释放旧模型资源
 * 6. 清空旧引用
 * 7. 加载新模型
 * 8. 检查 generation 是否过期
 * 9. 设置初始变换(rotation Y=π)
 * 10. 加入 Scene
 * 11. 重置 Camera
 * 12. 标记 READY
 */

import { Node, Scene } from '@kit.ArkGraphics3D';
import {
  FrameUpdatable
} from './ViewerFrameLoop';
import {
  ModelState,
  ViewerError,
  ViewerState,
  ViewerTestAssets,
  VRM_MODEL_Y_ROTATION_RAD,
  quaternionFromEulerY
} from './ViewerTypes';
import { ViewerCameraController } from './ViewerCameraController';
import { ViewerResourceDisposer } from './ViewerResourceDisposer';
import { ViewerSceneController } from './ViewerSceneController';

/**
 * 状态变更回调,用于通知 UI 层。
 */
export interface ViewerStateListener {
  onViewerStateChanged(state: ViewerState): void;
  onModelStateChanged(state: ModelState): void;
  onError(message: string): void;
}

/**
 * 模型控制器。
 *
 * 异步竞态防护:
 * - loadGeneration: 每次 loadModel 递增,异步回调首检 myGen !== this.loadGeneration 则放弃。
 * - isDisposed: 销毁后忽略所有回调。
 */
export class ViewerModelController implements FrameUpdatable {
  private sceneController: ViewerSceneController;
  private cameraController: ViewerCameraController;
  private disposer: ViewerResourceDisposer;

  private currentModel: Node | null = null;
  private modelState: ModelState = ModelState.NOT_LOADED;
  private viewerState: ViewerState = ViewerState.NOT_INITIALIZED;

  private loadGeneration: number = 0;
  private isDisposed: boolean = false;

  private listener: ViewerStateListener | null = null;

  /**
   * 已加载的模型 Scene(需在 dispose 时销毁,避免泄漏)。
   * importScene 后,原 Scene 的资源被共享,但 Scene 对象本身仍需销毁。
   */
  private loadedScene: Scene | null = null;

  constructor(
    sceneController: ViewerSceneController,
    cameraController: ViewerCameraController,
    disposer: ViewerResourceDisposer
  ) {
    this.sceneController = sceneController;
    this.cameraController = cameraController;
    this.disposer = disposer;
  }

  /**
   * 设置状态监听器。
   */
  public setListener(listener: ViewerStateListener | null): void {
    this.listener = listener;
  }

  /**
   * 加载默认测试 VRM。
   *
   * 使用 $rawfile 加载 rawfile/vrm/default.vrm。
   */
  public async loadDefault(): Promise<void> {
    const uri: string = ViewerTestAssets.DEFAULT_VRM;
    await this.loadModel(uri);
  }

  /**
   * 加载指定 URI 的 VRM 模型。
   *
   * 编排替换流程(见文件头注释)。
   *
   * @param uri VRM 资源 URI(rawfile 相对路径字符串)
   */
  public async loadModel(uri: string): Promise<void> {
    // 1. 标记 LOADING_MODEL
    this.setViewerState(ViewerState.LOADING_MODEL);
    this.setModelState(ModelState.LOADING);

    // 2. 递增 generation
    const myGen: number = ++this.loadGeneration;

    // 3-6. 释放旧模型
    if (this.currentModel !== null) {
      this.sceneController.detachModel(this.currentModel);
      this.disposer.disposeModel(this.currentModel);
      this.currentModel = null;
    }

    // 释放旧的 loadedScene
    if (this.loadedScene !== null) {
      try {
        this.loadedScene.destroy();
      } catch (_) {
        // 忽略
      }
      this.loadedScene = null;
    }

    // 7. 加载新模型
    let newScene: Scene | null = null;
    try {
      newScene = await Scene.load($rawfile(uri));
    } catch (e) {
      // 加载失败
      if (this.isDisposed || myGen !== this.loadGeneration) {
        // 已过期或已销毁,清理半初始化对象
        if (newScene !== null) {
          try {
            newScene.destroy();
          } catch (_) {
            // 忽略
          }
        }
        return;
      }
      const msg = e instanceof Error ? e.message : String(e);
      this.handleLoadFailure(`VRM load failed: ${msg}`, null, null);
      return;
    }

    // 8. 检查 generation 与销毁状态
    if (this.isDisposed || myGen !== this.loadGeneration) {
      // 已过期,清理半初始化对象
      this.disposer.cleanupHalfInitialized(newScene, null);
      return;
    }

    if (newScene === null) {
      this.handleLoadFailure('VRM load failed: Scene.load returned null', null, null);
      return;
    }

    // 检查 Scene 树是否为空
    const newRoot = newScene.root;
    if (newRoot === null) {
      this.handleLoadFailure('VRM load failed: scene.root is null', newScene, null);
      return;
    }

    if (newRoot.children.count() === 0) {
      this.handleLoadFailure('VRM load failed: scene tree is empty', newScene, null);
      return;
    }

    // 9. 通过 importScene 将新 Scene 导入主 Scene
    //    ArkGraphics3D Scene.importScene(name, sourceScene, parent) 返回新 Node
    const mainScene = this.sceneController.getScene();
    if (mainScene === null) {
      this.handleLoadFailure('Main scene not initialized', newScene, null);
      return;
    }

    const mainRoot = mainScene.root;
    if (mainRoot === null) {
      this.handleLoadFailure('Main scene root is null', newScene, null);
      return;
    }

    let importedNode: Node | null = null;
    try {
      importedNode = mainScene.importScene('vrmModel', newScene, mainRoot);
    } catch (e) {
      const msg = e instanceof Error ? e.message : String(e);
      this.handleLoadFailure(`importScene failed: ${msg}`, newScene, null);
      return;
    }

    if (importedNode === null) {
      this.handleLoadFailure('importScene returned null', newScene, null);
      return;
    }

    // 再次检查 generation(importScene 是同步的,但仍检查以防万一)
    if (this.isDisposed || myGen !== this.loadGeneration) {
      this.disposer.disposeModel(importedNode);
      try {
        newScene.destroy();
      } catch (_) {
        // 忽略
      }
      return;
    }

    // 10. 设置初始变换:rotation Y = π
    //     Reference: figure-main vrm.scene.rotation.y = Math.PI
    importedNode.rotation = quaternionFromEulerY(VRM_MODEL_Y_ROTATION_RAD);
    importedNode.position = { x: 0, y: 0, z: 0 };
    importedNode.scale = { x: 1, y: 1, z: 1 };

    // 11. 保存引用
    this.currentModel = importedNode;
    this.loadedScene = newScene;

    // 12. 重置 Camera
    this.cameraController.reset();

    // 13. 标记 READY
    this.setModelState(ModelState.READY);
    this.setViewerState(ViewerState.READY);
  }

  /**
   * 替换模型(本阶段与 loadModel 等价)。
   *
   * @param uri VRM 资源 URI(rawfile 相对路径字符串)
   */
  public async replaceModel(uri: string): Promise<void> {
    await this.loadModel(uri);
  }

  /**
   * 重置模型变换到默认值。
   * 用于"重置"按钮。
   */
  public resetModelTransform(): void {
    const model = this.currentModel;
    if (model === null) {
      return;
    }
    model.rotation = quaternionFromEulerY(VRM_MODEL_Y_ROTATION_RAD);
    model.position = { x: 0, y: 0, z: 0 };
    model.scale = { x: 1, y: 1, z: 1 };
  }

  /**
   * 获取当前模型根节点(供调试)。
   */
  public getCurrentModel(): Node | null {
    return this.currentModel;
  }

  /**
   * 获取当前 Viewer 状态。
   */
  public getViewerState(): ViewerState {
    return this.viewerState;
  }

  /**
   * 获取当前模型状态。
   */
  public getModelState(): ModelState {
    return this.modelState;
  }

  /**
   * 设置初始 Viewer 状态(由页面在 initialize 完成后调用)。
   */
  public setInitialViewerState(state: ViewerState): void {
    this.setViewerState(state);
  }

  /**
   * 帧循环更新接口(本阶段为空,接口保留)。
   *
   * Reference: figure-main animate() 中 currentVrm.update(clock.getDelta());
   *            OWNverse avatar.update(delta)。
   * 本阶段不实现 Humanoid/Expression/SpringBone,此方法为空。
   */
  public update(_deltaSeconds: number): void {
    // 本阶段空实现
  }

  /**
   * 销毁模型控制器,释放当前模型资源。
   *
   * 幂等:重复调用不崩溃。
   */
  public destroy(): void {
    if (this.isDisposed) {
      return;
    }
    this.isDisposed = true;

    if (this.currentModel !== null) {
      this.sceneController.detachModel(this.currentModel);
      this.disposer.disposeModel(this.currentModel);
      this.currentModel = null;
    }

    if (this.loadedScene !== null) {
      try {
        this.loadedScene.destroy();
      } catch (_) {
        // 忽略
      }
      this.loadedScene = null;
    }

    this.setModelState(ModelState.NOT_LOADED);
    this.setViewerState(ViewerState.DISPOSED);
  }

  /**
   * 处理加载失败:清理半初始化对象,转 FAILED 状态。
   */
  private handleLoadFailure(message: string, scene: Scene | null, node: Node | null): void {
    this.disposer.cleanupHalfInitialized(scene, node);
    this.currentModel = null;
    this.loadedScene = null;
    this.setModelState(ModelState.FAILED);
    this.setViewerState(ViewerState.FAILED);
    const l = this.listener;
    if (l !== null) {
      l.onError(message);
    }
  }

  /**
   * 设置 Viewer 状态并通知监听器。
   */
  private setViewerState(state: ViewerState): void {
    this.viewerState = state;
    const l = this.listener;
    if (l !== null) {
      l.onViewerStateChanged(state);
    }
  }

  /**
   * 设置模型状态并通知监听器。
   */
  private setModelState(state: ModelState): void {
    this.modelState = state;
    const l = this.listener;
    if (l !== null) {
      l.onModelStateChanged(state);
    }
  }
}
