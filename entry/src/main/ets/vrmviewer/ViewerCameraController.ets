/**
 * ViewerCameraController VRM Viewer 相机管理器
 *
 * 负责相机重置与 resize 通知。相机创建由 ViewerSceneController 完成。
 *
 * Reference:
 * - figure-main: index.html L442–448 (PerspectiveCamera 创建与 position),
 *   L1907–1973 (smoothResetCamera 缓动重置)
 * - ownverse-vrm-viewer: analysis/CAMERA_PIPELINE.md (相机参数与 controls.reset),
 *   analysis/VIEWER_ARCHITECTURE.md §4 Per-Frame Loop (controls.update)
 */

import { Camera } from '@kit.ArkGraphics3D';
import { FrameUpdatable } from './ViewerFrameLoop';
import {
  DEFAULT_CAMERA_FAR,
  DEFAULT_CAMERA_FOV,
  DEFAULT_CAMERA_NEAR,
  DEFAULT_CAMERA_POSITION
} from './ViewerTypes';

/**
 * 相机控制器。
 *
 * ArkGraphics3D Camera 无 `aspect` / `target` / `lookAt` API:
 * - aspect 由渲染目标隐式决定(无法显式设置)。
 * - target/lookAt 需手动计算朝向四元数。
 *
 * 默认配置:相机位于 (0,1.5,3) 看向 (0,1.5,0),
 * 视线方向 = (0,0,-1) 与相机本地 -Z 前向一致,rotation = identity。
 */
export class ViewerCameraController implements FrameUpdatable {
  private camera: Camera | null = null;

  /**
   * 绑定已创建的 Camera(由 ViewerSceneController 创建)。
   *
   * @param camera Camera 实例
   */
  public bind(camera: Camera | null): void {
    this.camera = camera;
  }

  /**
   * 解绑 Camera(不销毁,销毁由 SceneController 负责)。
   */
  public unbind(): void {
    this.camera = null;
  }

  /**
   * 重置相机到默认位置/朝向/FOV/近远平面。
   *
   * Reference: figure-main smoothResetCamera 的最终状态;
   *            OWNverse controls.reset() 恢复 (0,1.5,3)/(0,1.5,0)。
   * 本阶段不做缓动,直接赋值。
   */
  public reset(): void {
    const cam = this.camera;
    if (cam === null) {
      return;
    }
    cam.position = DEFAULT_CAMERA_POSITION;
    cam.rotation = { x: 0, y: 0, z: 0, w: 1 };
    cam.fov = DEFAULT_CAMERA_FOV;
    cam.nearPlane = DEFAULT_CAMERA_NEAR;
    cam.farPlane = DEFAULT_CAMERA_FAR;
  }

  /**
   * 通知视口尺寸变化。
   *
   * ArkGraphics3D Camera 无 `aspect` 属性,aspect 由 Component3D 渲染目标隐式决定。
   * 此方法仅作为接口保留,本阶段为空实现。
   *
   * Reference: figure-main window.resize → camera.aspect = w/h + renderer.setSize;
   *            OWNverse syncRendererSize 每帧轮询容器尺寸;
   *            ArkTavern 改用 ArkUI onAreaChange 事件驱动(无需每帧轮询)。
   *
   * @param _width 视口宽度(vp)
   * @param _height 视口高度(vp)
   */
  public onResize(_width: number, _height: number): void {
    // ArkGraphics3D Camera 无 aspect 属性,空实现。
    // 渲染尺寸由 Component3D.renderWidth/renderHeight 控制。
  }

  /**
   * 帧循环更新接口(本阶段为空,接口保留)。
   *
   * Reference: figure-main animate() 中 controls.update();
   *            OWNverse per-frame controls.update(delta)。
   * 本阶段不实现 OrbitControls,此方法为空。
   *
   * @param _deltaSeconds 距离上一帧的秒数
   */
  public update(_deltaSeconds: number): void {
    // 本阶段空实现
  }

  /**
   * 获取绑定的 Camera(供调试显示)。
   * @returns Camera 或 null
   */
  public getCamera(): Camera | null {
    return this.camera;
  }
}
