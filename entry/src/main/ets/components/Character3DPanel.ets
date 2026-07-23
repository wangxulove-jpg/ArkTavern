/**
 * Character3DPanel 聊天页 3D 角色展示组件
 *
 * T-3D.5: 单人聊天页 3D 展示接入与设置开关
 * T-3D.5A: 键盘折叠 / 上下旋转 / 旋转中心跟随
 *
 * 职责:
 * - 聊天页上半部分 3D 模型展示的独立组件
 * - 复用 Character3DPanelViewModel,不直接操作 Scene/Preferences/文件
 * - 显示状态:Loading / Ready / Failed / NoModel / Paused
 * - 支持左右+上下拖动旋转、重置视角小按钮
 * - 无模型时显示占位 + 前往 3D 模型设置入口
 * - 加载失败时显示重试 + 隐藏 3D 区域
 * - 不显示 PoC 的 8 个 Slider 配置面板
 *
 * 架构分层:
 * ChatPage → Character3DPanel → Character3DPanelViewModel → Character3DPocViewModel → Character3DService → ArkGraphics3D
 *
 * 生命周期:
 * - aboutToAppear:创建 ViewModel + 绑定回调 + 注入 Service + initialize
 * - onPageShow / onPageHide:转发给 ViewModel
 * - aboutToDisappear:dispose ViewModel
 *
 * 触摸冲突处理:
 * - Component3D 绑定 PanGesture(同时响应水平和垂直拖动)
 * - 3D 区域与聊天列表是兄弟节点,不互相干扰
 * - collapsed=true 时不渲染 Component3D,手势自然不响应
 *
 * 键盘折叠(T-3D.5A):
 * - collapsed=true 时高度为 0,不渲染 Component3D
 * - Scene 不销毁,配置不修改
 * - 键盘收起后恢复渲染,视角和 scale 保持不变
 */

import { Scene } from '@kit.ArkGraphics3D';
import { router } from '@kit.ArkUI';
import { Character3DPanelViewModel } from '../viewmodels/Character3DPanelViewModel';
import { Character3DLoadStateEnum } from '../models/character3d/Character3DLoadState';
import { AppServices } from '../services/AppServices';
import { GltfModelInfo } from '../parser/GltfValidator';
import { Logger } from '../utils/Logger';
import { TouchPointData, TouchPhase } from '../models/character3d/Character3DGestureHandler';

const LOG_TAG: string = 'Char3DPanel';

@Component
export struct Character3DPanel {
  /** 是否启用(由 ChatPage 传入,控制是否创建 ViewModel) */
  @Prop enabled3D: boolean = false;
  /** T-3D.5A: 是否折叠(键盘弹起时折叠到 0,不渲染 Component3D,不销毁 Scene) */
  @Prop collapsed: boolean = false;
  /** 隐藏 3D 区域回调(由 ChatPage 传入,点击"隐藏 3D 区域"按钮时调用) */
  onHide3D: (() => void) | null = null;

  /** ViewModel(@State 触发 UI 刷新) */
  @State private vm: Character3DPanelViewModel = new Character3DPanelViewModel();
  /** 当前加载状态 */
  @State private loadState: Character3DLoadStateEnum = Character3DLoadStateEnum.Disposed;
  /** 当前 Scene(null 时不渲染 Component3D) */
  @State private scene: Scene | null = null;
  /** 错误信息 */
  @State private errorMessage: string = '';
  /** 模型显示名(用于判断是否有模型) */
  @State private modelDisplayName: string = '';
  /** 是否为外部模型 */
  @State private isExternalModel: boolean = false;
  /** 当前模型信息 */
  @State private modelInfo: GltfModelInfo | null = null;
  /** 是否已初始化(避免重复 initialize) */
  @State private initialized: boolean = false;

  /** T-3D.5D: zoomFactor 调节请求(-1 表示无请求,>=0 表示请求更新 zoomFactor,范围 0.10~20.0) */
  @StorageProp('chat3dScaleRequest') @Watch('onZoomFactorRequest') private scaleRequest: number = -1;
  /** T-3D.5A: 保存配置请求(递增计数,每次变化触发落盘) */
  @StorageProp('chat3dSaveRequest') @Watch('onSaveRequest') private saveRequest: number = 0;
  /** T-3D.5A: 自动适配请求(递增计数,每次变化触发 resetDisplayConfig) */
  @StorageProp('chat3dAutoFitRequest') @Watch('onAutoFitRequest') private autoFitRequest: number = 0;
  /** T-3D.5B: 旋转灵敏度配置变更通知 */
  @StorageProp('chat3dConfigVersion') @Watch('onChat3DConfigVersionChanged') private chat3DConfigVersion: number = 0;
  /** T-3D.5B: 当前旋转灵敏度(初始化时从 Chat3DDisplaySettings 读取) */
  @State private rotationSensitivity: number = 1.0;

  async aboutToAppear(): Promise<void> {
    if (!this.enabled3D) {
      return;
    }
    Logger.info(LOG_TAG, 'aboutToAppear');
    this.bindVmCallbacks();
    try {
      await AppServices.whenReady();
      const service = AppServices.getCharacter3DService();
      if (service !== null) {
        this.vm.setService(service);
      } else {
        Logger.warn(LOG_TAG, 'Character3DService is null');
      }
      // T-3D.5B: 读取旋转灵敏度初始值
      const settings = AppServices.getChat3DDisplaySettings();
      this.rotationSensitivity = settings.getRotationSensitivity();
      this.vm.setRotationSensitivity(this.rotationSensitivity);
    } catch (e) {
      Logger.warn(LOG_TAG, 'AppServices not ready: ' + (e as Error)?.message);
    }
    this.initialized = true;
    await this.vm.initialize();
  }

  aboutToDisappear(): void {
    if (!this.initialized) {
      return;
    }
    Logger.info(LOG_TAG, 'aboutToDisappear');
    this.vm.dispose();
  }

  onPageShow(): void {
    if (!this.initialized) {
      return;
    }
    this.vm.onPageShown();
  }

  onPageHide(): void {
    if (!this.initialized) {
      return;
    }
    this.vm.onPageHidden();
  }

  /**
   * 绑定 ViewModel 回调。
   * dispose 时 ViewModel 会清空回调,无需在此解绑。
   */
  private bindVmCallbacks(): void {
    this.vm.onStateChanged = (state: Character3DLoadStateEnum): void => {
      this.loadState = state;
      this.scene = this.vm.getScene();
      if (state === Character3DLoadStateEnum.Disposed) {
        this.scene = null;
      }
    };
    this.vm.onError = (message: string): void => {
      this.errorMessage = message;
    };
    this.vm.onModelSourceChanged = (displayName: string, isExternal: boolean, info: GltfModelInfo | null): void => {
      this.modelDisplayName = displayName;
      this.isExternalModel = isExternal;
      this.modelInfo = info;
    };
  }

  /**
   * T-3D.5D: 响应 zoomFactor 调节请求(实时预览,只改内存不落盘)。
   * scaleRequest 字段语义改为 zoomFactor(0.10 ~ 20.0),
   * AppStorage key 保持 'chat3dScaleRequest' 不变以兼容已落盘的计数器语义。
   */
  private onZoomFactorRequest(): void {
    if (!this.initialized || this.scaleRequest < 0) {
      return;
    }
    this.vm.updateZoomFactor(this.scaleRequest);
  }

  /**
   * T-3D.5A: 响应保存配置请求(Slider 拖动结束后落盘)。
   */
  private onSaveRequest(): void {
    if (!this.initialized || this.saveRequest === 0) {
      return;
    }
    this.vm.saveDisplayConfig().catch((e: Error): void => {
      Logger.warn(LOG_TAG, 'saveDisplayConfig failed: ' + e.message);
    });
  }

  /**
   * T-3D.5A: 响应自动适配请求(恢复当前模型 autoFit 配置)。
   */
  private onAutoFitRequest(): void {
    if (!this.initialized || this.autoFitRequest === 0) {
      return;
    }
    this.vm.resetDisplayConfig().catch((e: Error): void => {
      Logger.warn(LOG_TAG, 'resetDisplayConfig failed: ' + e.message);
    });
  }

  /**
   * T-3D.5B: 响应 3D 配置变更(旋转灵敏度)。
   */
  private onChat3DConfigVersionChanged(): void {
    if (!this.initialized) {
      return;
    }
    try {
      const settings = AppServices.getChat3DDisplaySettings();
      const newSensitivity: number = settings.getRotationSensitivity();
      if (newSensitivity !== this.rotationSensitivity) {
        this.rotationSensitivity = newSensitivity;
        this.vm.setRotationSensitivity(newSensitivity);
      }
    } catch (_e) {
      // 忽略
    }
  }

  /**
   * T-3D.5B: 将 ArkUI TouchEvent 转换为 TouchPointData[] 并转发到 ViewModel。
   */
  private handleTouchEvent(event: TouchEvent): void {
    if (!this.initialized || this.collapsed) {
      return;
    }
    const touches: TouchObject[] = event.touches;
    const changedTouches: TouchObject[] = event.changedTouches;
    const points: TouchPointData[] = [];
    for (let i = 0; i < touches.length; i++) {
      const t: TouchObject = touches[i];
      points.push({ id: t.id, x: t.x, y: t.y });
    }
    const phase: TouchPhase = this.touchTypeToPhase(event.type);
    if (phase === TouchPhase.Down || phase === TouchPhase.Up) {
      const changedId: number = changedTouches.length > 0 ? changedTouches[0].id : -1;
      if (phase === TouchPhase.Down) {
        this.vm.handleTouchStart(points, changedId);
      } else {
        this.vm.handleTouchUp(points, changedId);
      }
    } else if (phase === TouchPhase.Move) {
      this.vm.handleTouchMove(points);
    } else if (phase === TouchPhase.Cancel) {
      this.vm.handleTouchCancel();
    }
  }

  /**
   * T-3D.5B: ArkUI TouchType → TouchPhase。
   */
  private touchTypeToPhase(type: TouchType): TouchPhase {
    if (type === TouchType.Down) {
      return TouchPhase.Down;
    }
    if (type === TouchType.Up) {
      return TouchPhase.Up;
    }
    if (type === TouchType.Move) {
      return TouchPhase.Move;
    }
    return TouchPhase.Cancel;
  }

  build() {
    // T-3D.5A: collapsed=true 时(键盘弹起)高度为 0,不渲染 Component3D
    // Scene 不销毁,配置不修改,键盘收起后恢复渲染
    if (this.collapsed) {
      Stack()
        .width('100%')
        .height(0)
    } else {
    Stack() {
      // 加载中
      if (this.loadState === Character3DLoadStateEnum.Loading
        || this.loadState === Character3DLoadStateEnum.Disposed) {
        Column() {
          LoadingProgress()
            .width(32)
            .height(32)
            .color($r('app.color.app_text_tertiary'))
          Text($r('app.string.chat_3d_loading'))
            .fontSize($r('app.float.app_font_caption'))
            .fontColor($r('app.color.app_text_tertiary'))
            .margin({ top: 8 })
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
      } else if (this.loadState === Character3DLoadStateEnum.Failed) {
        // 加载失败
        Column() {
          SymbolGlyph($r('sys.symbol.exclamationmark_triangle'))
            .fontSize(28)
            .fontColor([$r('app.color.app_danger')])
            .margin({ bottom: 8 })
          Text($r('app.string.chat_3d_load_failed'))
            .fontSize($r('app.float.app_font_caption'))
            .fontColor($r('app.color.app_text_secondary'))
            .margin({ bottom: 12 })
          Row() {
            Button($r('app.string.chat_3d_retry'))
              .fontSize($r('app.float.app_font_caption'))
              .backgroundColor($r('app.color.app_accent'))
              .fontColor($r('app.color.app_on_accent'))
              .borderRadius($r('app.float.app_radius_sm'))
              .height(32)
              .padding({ left: 16, right: 16 })
              .onClick(() => {
                this.errorMessage = '';
                this.vm.dispose();
                // 重新创建 ViewModel 并初始化
                this.vm = new Character3DPanelViewModel();
                this.bindVmCallbacks();
                // 重新注入 Service
                const service = AppServices.getCharacter3DService();
                if (service !== null) {
                  this.vm.setService(service);
                }
                this.vm.initialize().catch((e: Error): void => {
                  Logger.warn(LOG_TAG, 'retry initialize failed: ' + e.message);
                });
              })

            Button($r('app.string.chat_3d_hide'))
              .fontSize($r('app.float.app_font_caption'))
              .backgroundColor($r('app.color.app_surface_2'))
              .fontColor($r('app.color.app_text_secondary'))
              .borderRadius($r('app.float.app_radius_sm'))
              .height(32)
              .padding({ left: 16, right: 16 })
              .margin({ left: 8 })
              .onClick(() => {
                if (this.onHide3D !== null) {
                  this.onHide3D();
                }
              })
          }
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
      } else if (this.scene !== null
        && (this.loadState === Character3DLoadStateEnum.Ready
          || this.loadState === Character3DLoadStateEnum.Playing
          || this.loadState === Character3DLoadStateEnum.Paused)) {
        // 正常渲染 3D 模型
        Component3D({
          scene: this.scene as Scene,
          modelType: ModelType.SURFACE
        })
          .width('100%')
          .height('100%')
          .onTouch((event: TouchEvent) => {
            // T-3D.5B: 使用 TouchEvent 驱动手势状态机,替代 PanGesture
            // - 单指:旋转(无惯性,手指停止立即停止)
            // - 双指:平移或缩放(互斥,锁定后不切换)
            this.handleTouchEvent(event);
          })
          .onAreaChange((_oldValue: Area, newValue: Area) => {
            // T-3D.5B: 同步视口尺寸到手势处理器(用于双指平移世界单位转换)
            const w: number = typeof newValue.width === 'number' ? newValue.width : 0;
            const h: number = typeof newValue.height === 'number' ? newValue.height : 0;
            if (w > 0 && h > 0) {
              this.vm.setGestureViewport(w, h);
            }
          })

        // 右上角:重置视角小按钮
        Button({ type: ButtonType.Circle, stateEffect: false }) {
          SymbolGlyph($r('sys.symbol.arrow_counterclockwise'))
            .fontSize(14)
            .fontColor([$r('app.color.app_text_secondary')])
        }
        .backgroundColor('rgba(255,255,255,0.7)')
        .borderRadius(16)
        .width(32)
        .height(32)
        .position({ x: '100%', y: 0 })
        .markAnchor({ x: '100%', y: 0 })
        .margin({ right: 8, top: 8 })
        .onClick(() => {
          this.vm.resetView();
        })
      } else {
        // 无模型兜底(Ready 但 scene 为空,或未导入模型)
        Column() {
          Text('🧊')
            .fontSize(28)
            .margin({ bottom: 8 })
          Text($r('app.string.chat_3d_no_model'))
            .fontSize($r('app.float.app_font_caption'))
            .fontColor($r('app.color.app_text_tertiary'))
            .margin({ bottom: 12 })
          Button($r('app.string.chat_3d_go_settings'))
            .fontSize($r('app.float.app_font_caption'))
            .backgroundColor($r('app.color.app_surface_2'))
            .fontColor($r('app.color.app_text_secondary'))
            .borderRadius($r('app.float.app_radius_sm'))
            .height(32)
            .padding({ left: 16, right: 16 })
            .onClick(() => {
              router.pushUrl({ url: 'pages/Character3DPocPage' });
            })
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.app_surface_1'))
    .clip(true)
    }
  }
}
