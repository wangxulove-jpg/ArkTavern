/**
 * Character3DPanelViewModel 聊天页 3D 展示 ViewModel
 *
 * T-3D.5: 单人聊天页 3D 展示接入与设置开关
 *
 * 职责:
 * - 聊天页上半部分 3D 模型展示的轻量 ViewModel
 * - 内部组合 Character3DPocViewModel,复用 Scene 加载/Camera Fit/拖动旋转/生命周期管理
 * - 只暴露聊天页需要的 API,不暴露 PoC 专属方法(importModel/clearModel/Slider 配置等)
 * - 不读取聊天正文 / Prompt / API Key
 * - 不直接依赖 @ohos.net.http / @ohos.security.asset
 *
 * 架构分层:
 * ChatPage → Character3DPanel → Character3DPanelViewModel → Character3DPocViewModel → Character3DService → ArkGraphics3D
 *
 * 与 Character3DPocViewModel 的差异:
 * - 不提供 importModel / clearModel / importFromRawfile(聊天页不允许导入模型)
 * - 不提供 updateDisplayConfig / saveDisplayConfig / resetDisplayConfig / autoFitView(详细配置留在 PoC 页)
 * - 只提供:initialize / dispose / onPageShown / onPageHidden / handleDragX / resetView
 * - 回调精简:onStateChanged / onRotationChanged / onError / onModelSourceChanged
 *
 * 生命周期:
 * - ChatPage aboutToAppear 时由 Character3DPanel 创建
 * - Character3DPanel aboutToAppear 调用 initialize()
 * - Character3DPanel onPageShow / onPageHide 转发
 * - Character3DPanel aboutToDisappear 调用 dispose()
 */

import { Scene } from '@kit.ArkGraphics3D';
import { Character3DPocViewModel } from './Character3DPocViewModel';
import { Character3DLoadStateEnum } from '../models/character3d/Character3DLoadState';
import { Character3DService } from '../services/Character3DService';
import { GltfModelInfo } from '../parser/GltfValidator';
import { Character3DDisplayConfig } from '../models/character3d/Character3DDisplayConfig';
import { TouchPointData } from '../models/character3d/Character3DGestureHandler';

const LOG_TAG: string = 'Char3DPanelVM';

export class Character3DPanelViewModel {
  /** 内部复用的 PoC ViewModel(不暴露给外部) */
  private pocVm: Character3DPocViewModel;
  /** 是否已 dispose */
  private disposed: boolean = false;

  /** 状态变更回调 */
  onStateChanged: ((state: Character3DLoadStateEnum) => void) | null = null;
  /** 旋转变更回调 */
  onRotationChanged: ((rotationYDeg: number) => void) | null = null;
  /** 错误回调 */
  onError: ((message: string) => void) | null = null;
  /** 模型来源变更回调 */
  onModelSourceChanged: ((displayName: string, isExternal: boolean, modelInfo: GltfModelInfo | null) => void) | null = null;

  constructor() {
    this.pocVm = new Character3DPocViewModel();
    this.bindPocCallbacks();
  }

  /**
   * 绑定 PoC ViewModel 回调,转发到本 ViewModel 的回调。
   */
  private bindPocCallbacks(): void {
    this.pocVm.onStateChanged = (state: Character3DLoadStateEnum): void => {
      if (this.disposed) {
        return;
      }
      if (this.onStateChanged !== null) {
        this.onStateChanged(state);
      }
    };
    this.pocVm.onRotationChanged = (rotationYDeg: number): void => {
      if (this.disposed) {
        return;
      }
      if (this.onRotationChanged !== null) {
        this.onRotationChanged(rotationYDeg);
      }
    };
    this.pocVm.onError = (message: string): void => {
      if (this.disposed) {
        return;
      }
      if (this.onError !== null) {
        this.onError(message);
      }
    };
    this.pocVm.onModelSourceChanged = (displayName: string, isExternal: boolean, modelInfo: GltfModelInfo | null): void => {
      if (this.disposed) {
        return;
      }
      if (this.onModelSourceChanged !== null) {
        this.onModelSourceChanged(displayName, isExternal, modelInfo);
      }
    };
  }

  /**
   * 注入 Character3DService(必须在 initialize 前调用)。
   */
  setService(service: Character3DService): void {
    if (this.disposed) {
      return;
    }
    this.pocVm.setService(service);
  }

  /**
   * 初始化并启动加载。
   * 幂等:已 Loading/Ready/Playing/Paused 时忽略。
   */
  async initialize(): Promise<void> {
    if (this.disposed) {
      return;
    }
    await this.pocVm.initialize();
  }

  /**
   * 页面恢复可见时恢复播放。
   */
  onPageShown(): void {
    if (this.disposed) {
      return;
    }
    this.pocVm.onPageShown();
  }

  /**
   * 页面不可见时暂停渲染。
   */
  onPageHidden(): void {
    if (this.disposed) {
      return;
    }
    this.pocVm.onPageHidden();
  }

  /**
   * 处理水平拖动(旋转模型)。
   * 只改内存,不落盘(高频写盘禁止)。
   */
  handleDragX(deltaPxX: number): void {
    if (this.disposed) {
      return;
    }
    this.pocVm.handleDragX(deltaPxX);
  }

  /**
   * T-3D.5A: 处理垂直拖动(Pitch 旋转)。
   * 只改内存,不落盘(高频写盘禁止)。
   */
  handleDragY(deltaPxY: number): void {
    if (this.disposed) {
      return;
    }
    this.pocVm.handleDragY(deltaPxY);
  }

  /**
   * T-3D.5A: 更新模型显示比例(只改内存,不落盘)。
   * 用于 Slider 实时预览。
   */
  updateScale(scale: number): void {
    if (this.disposed) {
      return;
    }
    this.pocVm.updateDisplayConfig({ scale: scale });
  }

  /**
   * T-3D.5A: 保存当前显示配置到 Preferences(落盘)。
   */
  async saveDisplayConfig(): Promise<void> {
    if (this.disposed) {
      return;
    }
    await this.pocVm.saveDisplayConfig();
  }

  /**
   * T-3D.5A: 恢复默认显示配置(基于当前模型 autoFit)。
   */
  async resetDisplayConfig(): Promise<void> {
    if (this.disposed) {
      return;
    }
    await this.pocVm.resetDisplayConfig();
  }

  /**
   * T-3D.5A: 获取当前显示配置(用于 Slider 初始值)。
   */
  getDisplayConfig(): Character3DDisplayConfig {
    return this.pocVm.getDisplayConfig();
  }

  /**
   * T-3D.5A: 是否有外部模型(用于判断是否显示 scale 调节)。
   */
  hasExternalModel(): boolean {
    return this.pocVm.isExternalModel();
  }

  /**
   * 重置视角(Y 轴旋转归零,保留其他显示参数)。
   */
  resetView(): void {
    if (this.disposed) {
      return;
    }
    this.pocVm.resetView();
  }

  // ===== T-3D.5B: 手势状态机代理(TouchEvent 驱动) =====

  /**
   * T-3D.5B: 处理触摸开始(由 Character3DPanel 的 onTouch 转发)。
   * @param touches 所有当前活跃触摸点
   * @param changedId 新按下的指针 id
   */
  handleTouchStart(touches: TouchPointData[], changedId: number): void {
    if (this.disposed) {
      return;
    }
    this.pocVm.handleTouchStart(touches, changedId);
  }

  /**
   * T-3D.5B: 处理触摸移动。
   */
  handleTouchMove(touches: TouchPointData[]): void {
    if (this.disposed) {
      return;
    }
    this.pocVm.handleTouchMove(touches);
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
    this.pocVm.handleTouchUp(touches, changedId);
  }

  /**
   * T-3D.5B: 处理触摸取消。
   */
  handleTouchCancel(): void {
    if (this.disposed) {
      return;
    }
    this.pocVm.handleTouchCancel();
  }

  /**
   * T-3D.5B: 设置手势视口尺寸。
   */
  setGestureViewport(width: number, height: number): void {
    if (this.disposed) {
      return;
    }
    this.pocVm.setGestureViewport(width, height);
  }

  /**
   * T-3D.5B: 设置旋转灵敏度(0.2 ~ 2.0)。
   */
  setRotationSensitivity(sensitivity: number): void {
    if (this.disposed) {
      return;
    }
    this.pocVm.setRotationSensitivity(sensitivity);
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
    this.pocVm.dispose();
    this.onStateChanged = null;
    this.onRotationChanged = null;
    this.onError = null;
    this.onModelSourceChanged = null;
  }

  /**
   * 获取当前加载状态。
   */
  getState(): Character3DLoadStateEnum {
    return this.pocVm.getState();
  }

  /**
   * 获取当前 Scene(用于 Component3D 渲染)。
   * 未加载或已释放时返回 null。
   */
  getScene(): Scene | null {
    return this.pocVm.getScene();
  }

  /**
   * 获取当前 Y 轴旋转角度。
   */
  getRotationYDeg(): number {
    return this.pocVm.getRotationYDeg();
  }

  /**
   * 是否已 dispose。
   */
  isDisposed(): boolean {
    return this.disposed;
  }

  /**
   * 是否为外部模型(非程序化几何体)。
   */
  isExternalModel(): boolean {
    return this.pocVm.isExternalModel();
  }

  /**
   * 获取模型来源显示文本。
   */
  getModelSourceText(): string {
    return this.pocVm.getModelSourceText();
  }

  /**
   * 获取当前模型信息(用于判断是否有模型)。
   */
  getModelInfo(): GltfModelInfo | null {
    return this.pocVm.getModelInfo();
  }

  /**
   * 是否有动画。
   */
  hasAnimation(): boolean {
    return this.pocVm.hasAnimation();
  }
}
