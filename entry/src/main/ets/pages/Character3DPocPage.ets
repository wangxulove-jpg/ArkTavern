/**
 * Character3DPocPage 3D 渲染 PoC 页面
 *
 * 临时开发测试: T-3D.1 内置模型与 3D 渲染 PoC;T-3D.2 扩展 GLB 导入;T-3D.3 模型兼容性检测
 *
 * 验证目标:
 * - Component3D + Scene API 渲染
 * - 程序化几何体场景(无 GLB 模型降级方案)
 * - 状态机 Loading/Ready/Playing/Paused/Failed/Disposed
 * - 播放/暂停/停止/重载
 * - 点击触摸反馈
 * - 左右拖动旋转
 * - 恢复默认视角
 * - 错误占位
 * - 页面离开释放资源
 * - 前后台切换暂停渲染
 * - T-3D.2: 导入外部 GLB/GLTF 模型文件并渲染
 * - T-3D.2: 清除模型回退到程序化几何体
 * - T-3D.3: 导入时显示模型摘要(网格/材质/动画/节点/相机数量)
 * - T-3D.3: 格式无效的文件被拒绝并显示错误
 *
 * 已知限制(必须在 PoC 报告中明确):
 * - 外部 GLB 模型的动画支持取决于模型本身
 * - 外部模型的旋转锚点选取第一个 node,可能不适用于所有模型
 */

import { router, promptAction } from '@kit.ArkUI';
import { picker } from '@kit.CoreFileKit';
import { Scene } from '@kit.ArkGraphics3D';
import { Character3DPocViewModel } from '../viewmodels/Character3DPocViewModel';
import { Character3DLoadStateEnum } from '../models/character3d/Character3DLoadState';
import { AppServices } from '../services/AppServices';
import { GltfModelInfo } from '../parser/GltfValidator';
import { Logger } from '../utils/Logger';
import { Character3DDisplayConfigTest } from '../test/Character3DDisplayConfigTest';
import { Chat3DPanelTest } from '../test/Chat3DPanelTest';
import { Character3DGestureHandlerTest } from '../test/Character3DGestureHandlerTest';
import {
  Character3DDisplayConfig,
  createDefaultDisplayConfig,
  OFFSET_MIN,
  OFFSET_MAX,
  ROTATION_MIN_DEG,
  ROTATION_MAX_DEG,
  CAMERA_DISTANCE_MIN,
  CAMERA_DISTANCE_MAX,
  DEFAULT_OFFSET_X,
  DEFAULT_OFFSET_Y,
  DEFAULT_OFFSET_Z,
  DEFAULT_ROTATION_X_DEG,
  DEFAULT_ROTATION_Y_DEG,
  DEFAULT_ROTATION_Z_DEG,
  DEFAULT_CAMERA_DISTANCE,
  VIEWER_ZOOM_FACTOR_MIN,
  VIEWER_ZOOM_FACTOR_MAX,
  VIEWER_ZOOM_FACTOR_DEFAULT,
  getZoomFactor
} from '../models/character3d/Character3DDisplayConfig';
import { TouchPointData, TouchPhase } from '../models/character3d/Character3DGestureHandler';

const LOG_TAG: string = 'Char3DPocPage';

@Entry
@Component
struct Character3DPocPage {
  @State private vm: Character3DPocViewModel = new Character3DPocViewModel();
  /** 当前加载状态(用于 UI 刷新) */
  @State private loadState: Character3DLoadStateEnum = Character3DLoadStateEnum.Disposed;
  /** 当前 Scene 实例(null 时不渲染 Component3D) */
  @State private scene: Scene | null = null;
  /** 当前 Y 轴旋转角度(度数,用于 UI 显示) */
  @State private rotationYDeg: number = 0;
  /** 错误信息(空表示无错误) */
  @State private errorMessage: string = '';
  /** 触摸反馈计数(用于 UI 闪烁) */
  @State private touchCount: number = 0;
  /** 当前模型显示名(空表示程序化几何体) */
  @State private modelDisplayName: string = '';
  /** 是否加载了外部模型 */
  @State private isExternalModel: boolean = false;
  /** 当前模型摘要信息(导入后非空;程序化几何体或重启后未验证时为 null) */
  @State private modelInfo: GltfModelInfo | null = null;
  /** 导入操作进行中(防止重复点击) */
  @State private isImporting: boolean = false;
  /** T-3D.4: 显示配置(用于 Slider 双向绑定) */
  @State private displayConfig: Character3DDisplayConfig = createDefaultDisplayConfig();
  /** T-3D.4: 显示配置面板是否展开 */
  @State private isPanelExpanded: boolean = false;
  /** T-3D.4: 保存按钮是否正在落盘(防重复点击) */
  @State private isSavingConfig: boolean = false;
  /** T-3D.5: 测试运行中 */
  @State private isRunningTests: boolean = false;
  /** T-3D.6C-C: 模型转换进度消息(空字符串表示无转换进行中) */
  @State private conversionProgressMessage: string = '';
  /** T-3D.6C-C: 模型转换进度百分比 */
  @State private conversionProgressPercent: number = 0;
  /** 顶部状态栏避让高度 */
  @StorageProp('statusBarHeight') statusBarHeight: number = 0;
  /** 底部导航栏避让高度 */
  @StorageProp('navigationBarHeight') navigationBarHeight: number = 0;

  async aboutToAppear(): Promise<void> {
    Logger.info(LOG_TAG, 'aboutToAppear');
    this.bindVmCallbacks();
    // T-3D.2:注入 Character3DService
    try {
      await AppServices.whenReady();
      const service = AppServices.getCharacter3DService();
      if (service !== null) {
        this.vm.setService(service);
      } else {
        Logger.warn(LOG_TAG, 'Character3DService is null, import disabled');
      }
    } catch (e) {
      Logger.warn(LOG_TAG, 'AppServices not ready: ' + (e as Error)?.message);
    }
    await this.vm.initialize();
  }

  aboutToDisappear(): void {
    Logger.info(LOG_TAG, 'aboutToDisappear');
    this.vm.dispose();
  }

  onPageShow(): void {
    Logger.info(LOG_TAG, 'onPageShow');
    this.vm.onPageShown();
  }

  onPageHide(): void {
    Logger.info(LOG_TAG, 'onPageHide');
    this.vm.onPageHidden();
  }

  /**
   * 绑定 ViewModel 回调。
   * dispose 时 ViewModel 会清空回调,无需在此解绑。
   */
  private bindVmCallbacks(): void {
    this.vm.onStateChanged = (state: Character3DLoadStateEnum): void => {
      this.loadState = state;
      // 状态变化时同步 Scene 引用(Ready/Playing/Paused 时非空,Disposed/Failed/Loading 时可能为空)
      this.scene = this.vm.getScene();
      if (state === Character3DLoadStateEnum.Failed) {
        // 错误信息由 onError 回调填充
      }
      if (state === Character3DLoadStateEnum.Disposed) {
        this.scene = null;
      }
    };
    this.vm.onRotationChanged = (deg: number): void => {
      this.rotationYDeg = deg;
    };
    this.vm.onError = (message: string): void => {
      this.errorMessage = message;
    };
    this.vm.onTouchFeedback = (): void => {
      this.touchCount++;
    };
    this.vm.onModelSourceChanged = (displayName: string, isExternal: boolean, info: GltfModelInfo | null): void => {
      this.modelDisplayName = displayName;
      this.isExternalModel = isExternal;
      this.modelInfo = info;
    };
    this.vm.onDisplayConfigChanged = (cfg: Character3DDisplayConfig): void => {
      this.displayConfig = cfg;
    };
  }

  /**
   * T-3D.5D: 将 ArkUI TouchEvent 转换为 TouchPointData[] 并转发到 ViewModel。
   *
   * 与 Character3DPanel.handleTouchEvent 保持完全一致:
   * - 转发完整 touches(不只是 touches[0])
   * - 处理 Down/Move/Up/Cancel 四种 phase
   * - 双指操作通过完整 touches 数组识别
   * - 双指转单指由 GestureHandler 的 suppressSingleRotate 处理
   */
  private handleTouchEvent(event: TouchEvent): void {
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
   * T-3D.5D: ArkUI TouchType → TouchPhase。
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
    Column() {
      this.titleBar()

      // 状态/错误信息条
      if (this.errorMessage.length > 0) {
        Text(this.errorMessage)
          .fontSize(12)
          .fontColor($r('app.color.app_danger'))
          .width('100%')
          .padding({ left: 16, right: 16, top: 6, bottom: 6 })
          .backgroundColor($r('app.color.app_surface_2'))
      }

      // T-3D.6C-C: 模型转换进度条
      if (this.conversionProgressMessage.length > 0) {
        Column() {
          Row() {
            LoadingProgress()
              .width(16)
              .height(16)
              .color($r('app.color.app_accent'))
              .margin({ right: 8 })
            Text(this.conversionProgressMessage)
              .fontSize(12)
              .fontColor($r('app.color.page_primary_text'))
              .layoutWeight(1)
            Text(this.conversionProgressPercent.toString() + '%')
              .fontSize(12)
              .fontColor($r('app.color.page_secondary_text'))
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 6, bottom: 6 })
          .alignItems(VerticalAlign.Center)

          Progress({ value: this.conversionProgressPercent, total: 100, type: ProgressType.Linear })
            .width('90%')
            .color($r('app.color.app_accent'))
            .margin({ bottom: 6 })
        }
        .width('100%')
        .backgroundColor($r('app.color.app_surface_2'))
      }

      // 3D 渲染区(占主要高度)
      this.renderArea()

      // T-3D.4: 显示配置面板(可折叠)
      this.displayConfigPanel()

      // 控制栏
      this.controlsBar()
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_background'))
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }

  /**
   * T-3D.4: 显示配置面板(可折叠)。
   * 折叠时仅显示一行摘要 + 展开按钮;展开时显示所有 Slider。
   */
  @Builder
  displayConfigPanel() {
    Column() {
      // 头部:标题 + 当前摘要 + 展开/折叠按钮
      Row() {
        Text('显示配置')
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.app_text_primary'))
        Blank()
        Text(this.displayConfigSummary())
          .fontSize(11)
          .fontColor($r('app.color.app_text_tertiary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .margin({ right: 8 })
        Button(this.isPanelExpanded ? '收起' : '展开')
          .fontSize(11)
          .backgroundColor($r('app.color.app_surface_2'))
          .fontColor($r('app.color.app_text_secondary'))
          .height(24)
          .padding({ left: 8, right: 8 })
          .onClick(() => {
            this.isPanelExpanded = !this.isPanelExpanded;
          })
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 6, bottom: 6 })

      // 展开时显示 Sliders
      if (this.isPanelExpanded) {
        this.displayConfigSliders()
      }
    }
    .width('100%')
    .backgroundColor($r('app.color.app_surface_1'))
  }

  /**
   * T-3D.4: 显示配置 Slider 列表。
   */
  @Builder
  displayConfigSliders() {
    Scroll() {
      Column() {
        // T-3D.5D 缩放倍率(相对自动适配尺寸,0.10~20.0,1.0 = 自动适配)
        this.sliderRow(
          '缩放倍率',
          getZoomFactor(this.displayConfig),
          VIEWER_ZOOM_FACTOR_MIN,
          VIEWER_ZOOM_FACTOR_MAX,
          VIEWER_ZOOM_FACTOR_DEFAULT,
          2,
          (v: number) => {
            this.vm.updateZoomFactor(v);
          }
        )
        // 垂直位置(offsetY)
        this.sliderRow(
          '垂直位置',
          this.displayConfig.offsetY,
          OFFSET_MIN,
          OFFSET_MAX,
          DEFAULT_OFFSET_Y,
          2,
          (v: number) => {
            this.vm.updateDisplayConfig({ offsetY: v });
          }
        )
        // 水平位置(offsetX)
        this.sliderRow(
          '水平位置',
          this.displayConfig.offsetX,
          OFFSET_MIN,
          OFFSET_MAX,
          DEFAULT_OFFSET_X,
          2,
          (v: number) => {
            this.vm.updateDisplayConfig({ offsetX: v });
          }
        )
        // 前后位置(offsetZ)
        this.sliderRow(
          '前后位置',
          this.displayConfig.offsetZ,
          OFFSET_MIN,
          OFFSET_MAX,
          DEFAULT_OFFSET_Z,
          2,
          (v: number) => {
            this.vm.updateDisplayConfig({ offsetZ: v });
          }
        )
        // 水平旋转(rotationY)
        this.sliderRow(
          '水平旋转',
          this.displayConfig.rotationYDeg,
          ROTATION_MIN_DEG,
          ROTATION_MAX_DEG,
          DEFAULT_ROTATION_Y_DEG,
          0,
          (v: number) => {
            this.vm.updateDisplayConfig({ rotationYDeg: v });
          }
        )
        // X 轴旋转
        this.sliderRow(
          'X 轴旋转',
          this.displayConfig.rotationXDeg,
          ROTATION_MIN_DEG,
          ROTATION_MAX_DEG,
          DEFAULT_ROTATION_X_DEG,
          0,
          (v: number) => {
            this.vm.updateDisplayConfig({ rotationXDeg: v });
          }
        )
        // Z 轴旋转
        this.sliderRow(
          'Z 轴旋转',
          this.displayConfig.rotationZDeg,
          ROTATION_MIN_DEG,
          ROTATION_MAX_DEG,
          DEFAULT_ROTATION_Z_DEG,
          0,
          (v: number) => {
            this.vm.updateDisplayConfig({ rotationZDeg: v });
          }
        )
        // 镜头距离
        this.sliderRow(
          '镜头距离',
          this.displayConfig.cameraDistance,
          CAMERA_DISTANCE_MIN,
          CAMERA_DISTANCE_MAX,
          DEFAULT_CAMERA_DISTANCE,
          2,
          (v: number) => {
            this.vm.updateDisplayConfig({ cameraDistance: v });
          }
        )

        // 操作按钮:恢复默认 + 保存
        Row() {
          Button('恢复默认')
            .fontSize(12)
            .backgroundColor($r('app.color.app_surface_2'))
            .fontColor($r('app.color.app_text_secondary'))
            .height(32)
            .layoutWeight(1)
            .margin({ right: 8 })
            .onClick(() => {
              this.handleResetDisplayConfig();
            })
          Button('保存配置')
            .fontSize(12)
            .enabled(!this.isSavingConfig)
            .backgroundColor($r('app.color.app_accent'))
            .fontColor(Color.White)
            .height(32)
            .layoutWeight(1)
            .onClick(() => {
              this.handleSaveDisplayConfig();
            })
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 4, bottom: 8 })
      }
    }
    .width('100%')
    .constraintSize({ maxHeight: 260 })
    .padding({ left: 0, right: 0, top: 0, bottom: 4 })
  }

  /**
   * T-3D.4: 单行 Slider(标签 + 数值 + 滑块)。
   * onChange 时实时调用 onDrag 回调(仅更新内存,不落盘)。
   *
   * @param label 标签文本
   * @param value 当前值
   * @param min 最小值
   * @param max 最大值
   * @param defVal 默认值(双击标签可恢复)
   * @param digits 保留小数位
   * @param onDrag 拖动回调
   */
  @Builder
  sliderRow(
    label: string,
    value: number,
    min: number,
    max: number,
    defVal: number,
    digits: number,
    onDrag: (v: number) => void
  ) {
    Column() {
      Row() {
        Text(label)
          .fontSize(12)
          .fontColor($r('app.color.app_text_secondary'))
          .width(72)
        Text(value.toFixed(digits))
          .fontSize(12)
          .fontColor($r('app.color.app_text_primary'))
          .width(48)
          .textAlign(TextAlign.RIGHT)
        Blank()
        // 双击标签恢复默认值(轻量级,不占用空间)
        Text('默认')
          .fontSize(10)
          .fontColor($r('app.color.app_text_tertiary'))
          .padding({ left: 4, right: 4, top: 2, bottom: 2 })
          .borderRadius(4)
          .backgroundColor($r('app.color.app_surface_2'))
          .onClick(() => {
            onDrag(defVal);
          })
      }
      .width('100%')
      .padding({ left: 16, right: 16 })

      Slider({
        value: value,
        min: min,
        max: max,
        step: digits === 0 ? 1 : 0.01
      })
        .width('100%')
        .blockColor($r('app.color.app_accent'))
        .selectedColor($r('app.color.app_accent'))
        .trackColor($r('app.color.app_surface_2'))
        .padding({ left: 16, right: 16 })
        .onChange((v: number, mode: SliderChangeMode) => {
          // mode === Moving/Click/End;实时更新内存,End 时落盘
          onDrag(v);
          if (mode === SliderChangeMode.End || mode === SliderChangeMode.Click) {
            // 拖动结束自动落盘(单字段变更也立即保存)
            this.handleSaveDisplayConfig();
          }
        })
    }
    .width('100%')
    .padding({ top: 2, bottom: 2 })
  }

  /**
   * T-3D.4: 显示配置摘要文本(折叠时显示)。
   * T-3D.5D: S(scale) 改为 Z(zoomFactor,相对自动适配尺寸)。
   */
  private displayConfigSummary(): string {
    const c: Character3DDisplayConfig = this.displayConfig;
    return 'Z:' + getZoomFactor(c).toFixed(2)
      + ' Y:' + c.offsetY.toFixed(2)
      + ' R:' + c.rotationYDeg.toFixed(0) + '°'
      + ' D:' + c.cameraDistance.toFixed(2);
  }

  /**
   * T-3D.4: 恢复默认显示配置。
   */
  private async handleResetDisplayConfig(): Promise<void> {
    if (this.isSavingConfig) {
      return;
    }
    try {
      await this.vm.resetDisplayConfig();
      promptAction.showToast({ message: '已恢复默认配置', duration: 1200 });
    } catch (e) {
      promptAction.showToast({ message: '恢复失败', duration: 1500 });
    }
  }

  /**
   * T-3D.4: 保存当前显示配置到 Preferences。
   */
  private async handleSaveDisplayConfig(): Promise<void> {
    if (this.isSavingConfig) {
      return;
    }
    this.isSavingConfig = true;
    try {
      await this.vm.saveDisplayConfig();
    } catch (e) {
      promptAction.showToast({ message: '保存失败', duration: 1500 });
    } finally {
      this.isSavingConfig = false;
    }
  }

  @Builder
  titleBar() {
    Row() {
      // 返回按钮
      Stack() {
        SymbolGlyph($r('sys.symbol.chevron_left'))
          .fontSize(24)
          .fontColor([$r('app.color.app_text_primary')])
      }
      .width(40)
      .height(40)
      .onClick(() => {
        router.back();
      })

      Blank()

      Text('3D 渲染 PoC')
        .fontSize(18)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.app_text_primary'))

      Blank()

      // T-3D.4A: 导入 teacher-love 测试模型(模拟器无 Download 目录,改用 rawfile)
      Button('导入模型')
        .fontSize(13)
        .enabled(!this.isImporting && this.loadState !== Character3DLoadStateEnum.Loading)
        .backgroundColor($r('app.color.app_surface_2'))
        .fontColor($r('app.color.app_text_secondary'))
        .height(32)
        .padding({ left: 10, right: 10 })
        .margin({ right: 8 })
        .onClick(() => {
          this.handleImportTeacherLove();
        })

      // 导入模型按钮(从文件选择器)
      Button('导入文件')
        .fontSize(13)
        .enabled(!this.isImporting && this.loadState !== Character3DLoadStateEnum.Loading)
        .backgroundColor($r('app.color.app_accent'))
        .fontColor(Color.White)
        .height(32)
        .padding({ left: 12, right: 12 })
        .onClick(() => {
          this.openModelPicker();
        })
    }
    .width('100%')
    .padding({ left: 12, right: 12, top: this.statusBarHeight + 4, bottom: 4 })
    .alignItems(VerticalAlign.Center)
  }

  /**
   * T-3D.4A: 从 rawfile 导入 teacher-love.glb(模拟器无 Download 目录的替代方案)。
   */
  private async handleImportTeacherLove(): Promise<void> {
    if (this.isImporting) {
      return;
    }
    this.isImporting = true;
    this.errorMessage = '';
    try {
      promptAction.showToast({ message: '正在导入 teacher-love 模型…', duration: 1500 });
      await this.vm.importFromRawfileByName('teacher-love.glb', 'teacher-love');
      promptAction.showToast({ message: '导入成功', duration: 1500 });
    } catch (e) {
      const msg: string = (e as Error)?.message ?? '导入失败';
      this.errorMessage = msg;
      promptAction.showToast({ message: '导入失败: ' + msg, duration: 2000 });
    } finally {
      this.isImporting = false;
    }
  }

  @Builder
  renderArea() {
    Stack() {
      if (this.loadState === Character3DLoadStateEnum.Loading
        || this.loadState === Character3DLoadStateEnum.Disposed) {
        // 加载中
        Column() {
          LoadingProgress()
            .width(48)
            .height(48)
          Text('正在加载 3D 场景…')
            .fontSize(13)
            .fontColor($r('app.color.app_text_secondary'))
            .margin({ top: 12 })
        }
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
      } else if (this.loadState === Character3DLoadStateEnum.Failed) {
        // 加载失败
        Column() {
          SymbolGlyph($r('sys.symbol.exclamationmark_triangle'))
            .fontSize(40)
            .fontColor([$r('app.color.app_danger')])
          Text('加载失败')
            .fontSize(14)
            .fontColor($r('app.color.app_text_secondary'))
            .margin({ top: 8 })
          Button('重试')
            .margin({ top: 12 })
            .onClick(() => {
              this.errorMessage = '';
              this.vm.reload();
            })
        }
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
      } else if (this.scene !== null) {
        // 正常渲染
        Component3D({
          scene: this.scene as Scene,
          modelType: ModelType.SURFACE
        })
          .width('100%')
          .height('100%')
          .onTouch((event: TouchEvent) => {
            // T-3D.5D: 转发完整 TouchEvent 到统一手势状态机,
            // 与 Character3DPanel 使用同一套 GestureHandler 逻辑:
            // - 单指:旋转(水平 yaw + 垂直 pitch,无惯性)
            // - 双指:平移或缩放(互斥,锁定后不切换)
            // - 双指转单指:抑制剩余手指立即旋转
            // - Cancel:清空状态,保留最后视角
            this.handleTouchEvent(event);
          })
          .onAreaChange((_oldValue: Area, newValue: Area) => {
            // T-3D.5D: 同步视口尺寸到 GestureHandler(用于双指平移世界单位换算)
            const w: number = typeof newValue.width === 'number' ? newValue.width : 0;
            const h: number = typeof newValue.height === 'number' ? newValue.height : 0;
            if (w > 0 && h > 0) {
              this.vm.setGestureViewport(w, h);
            }
          })

        // 触摸反馈浮层(短暂闪烁)
        if (this.touchCount > 0) {
          Text('👆')
            .fontSize(24)
            .padding(8)
            .borderRadius(20)
            .backgroundColor('rgba(47,115,255,0.2)')
            .opacity(0.8)
            .markAnchor({ x: '50%', y: '50%' })
            .position({ x: '50%', y: '50%' })
            .key('touch-feedback-' + this.touchCount.toString())
        }
      } else {
        // 兜底空状态
        Column() {
          Text('场景未就绪')
            .fontSize(13)
            .fontColor($r('app.color.app_text_tertiary'))
        }
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
      }
    }
    .width('100%')
    .layoutWeight(1)
    .backgroundColor($r('app.color.app_surface_1'))
  }

  @Builder
  controlsBar() {
    Column() {
      // 状态 + 旋转角度显示
      Row() {
        Text('状态: ' + this.stateDisplayText())
          .fontSize(12)
          .fontColor($r('app.color.app_text_secondary'))
        Blank()
        Text('旋转: ' + this.rotationYDeg.toFixed(0) + '°')
          .fontSize(12)
          .fontColor($r('app.color.app_text_secondary'))
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 8, bottom: 4 })

      // T-3D.2: 模型来源显示
      Row() {
        Text('模型: ' + this.modelSourceDisplayText())
          .fontSize(12)
          .fontColor(this.isExternalModel
            ? $r('app.color.app_accent')
            : $r('app.color.app_text_tertiary'))
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        if (this.isExternalModel) {
          Button('清除模型')
            .fontSize(11)
            .enabled(!this.isImporting)
            .backgroundColor($r('app.color.app_surface_2'))
            .fontColor($r('app.color.app_danger'))
            .height(28)
            .padding({ left: 8, right: 8 })
            .margin({ left: 8 })
            .onClick(() => {
              this.handleClearModel();
            })
          // T-3D.6A: 动作管理入口
          Button('动作管理')
            .fontSize(11)
            .backgroundColor($r('app.color.app_surface_2'))
            .fontColor($r('app.color.app_accent'))
            .height(28)
            .padding({ left: 8, right: 8 })
            .margin({ left: 8 })
            .onClick(() => {
              router.pushUrl({ url: 'pages/Character3DActionManagerPage' });
            })
        } else {
          // T-3D.2: 无外部模型时显示"加载测试模型"按钮(用于设备验证)
          Button('加载测试模型')
            .fontSize(11)
            .enabled(!this.isImporting && this.loadState !== Character3DLoadStateEnum.Loading)
            .backgroundColor($r('app.color.app_surface_2'))
            .fontColor($r('app.color.app_accent'))
            .height(28)
            .padding({ left: 8, right: 8 })
            .margin({ left: 8 })
            .onClick(() => {
              this.handleLoadTestModel();
            })
        }
      }
      .width('100%')
      .padding({ left: 16, right: 16, bottom: 4 })

      // T-3D.3: 模型摘要信息(仅外部模型导入后显示)
      if (this.isExternalModel && this.modelInfo !== null) {
        Text(this.modelSummaryText())
          .fontSize(11)
          .fontColor($r('app.color.app_text_tertiary'))
          .width('100%')
          .maxLines(2)
          .padding({ left: 16, right: 16, bottom: 4 })
      }

      // 动画状态提示
      if (!this.vm.hasAnimation()) {
        Text('提示: 当前场景无动画,动画未验证')
          .fontSize(11)
          .fontColor($r('app.color.app_text_tertiary'))
          .width('100%')
          .padding({ left: 16, right: 16, bottom: 4 })
      }

      // 按钮组(两行布局,确保所有按钮可见)
      // 第一行:播放/暂停/停止
      Row() {
        Button('播放')
          .fontSize(13)
          .enabled(this.canPlay())
          .backgroundColor(this.canPlay() ? $r('app.color.app_accent') : $r('app.color.app_surface_2'))
          .fontColor(this.canPlay() ? Color.White : $r('app.color.app_text_tertiary'))
          .height(36)
          .layoutWeight(1)
          .onClick(() => {
            this.vm.play();
          })

        Button('暂停')
          .fontSize(13)
          .enabled(this.canPause())
          .backgroundColor(this.canPause() ? $r('app.color.app_accent') : $r('app.color.app_surface_2'))
          .fontColor(this.canPause() ? Color.White : $r('app.color.app_text_tertiary'))
          .height(36)
          .layoutWeight(1)
          .margin({ left: 8, right: 8 })
          .onClick(() => {
            this.vm.pause();
          })

        Button('停止')
          .fontSize(13)
          .enabled(this.canStop())
          .backgroundColor(this.canStop() ? $r('app.color.app_accent') : $r('app.color.app_surface_2'))
          .fontColor(this.canStop() ? Color.White : $r('app.color.app_text_tertiary'))
          .height(36)
          .layoutWeight(1)
          .onClick(() => {
            this.vm.stop();
          })
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 4 })

      // 第二行:重置视角/自动适配/重载
      Row() {
        Button('重置视角')
          .fontSize(13)
          .enabled(this.canRespond())
          .backgroundColor(this.canRespond() ? $r('app.color.app_accent') : $r('app.color.app_surface_2'))
          .fontColor(this.canRespond() ? Color.White : $r('app.color.app_text_tertiary'))
          .height(36)
          .layoutWeight(1)
          .onClick(() => {
            this.vm.resetView();
          })

        Button('自动适配')
          .fontSize(13)
          .enabled(this.canRespond() && this.isExternalModel)
          .backgroundColor(this.canRespond() && this.isExternalModel
            ? $r('app.color.app_accent') : $r('app.color.app_surface_2'))
          .fontColor(this.canRespond() && this.isExternalModel
            ? Color.White : $r('app.color.app_text_tertiary'))
          .height(36)
          .layoutWeight(1)
          .margin({ left: 8, right: 8 })
          .onClick(() => {
            this.vm.autoFitView();
            promptAction.showToast({ message: '已自动适配视角', duration: 1200 });
          })

        Button('重载')
          .fontSize(13)
          .enabled(true)
          .backgroundColor($r('app.color.app_accent'))
          .fontColor(Color.White)
          .height(36)
          .layoutWeight(1)
          .onClick(() => {
            this.errorMessage = '';
            this.vm.reload();
          })
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 4 })

      // T-3D.5: 测试运行按钮(第三行)
      Row() {
        Button('运行测试(T-3D.4+T-3D.5+T-3D.5D)')
          .fontSize(13)
          .enabled(!this.isRunningTests)
          .backgroundColor(this.isRunningTests ? $r('app.color.app_surface_2') : $r('app.color.app_accent'))
          .fontColor(this.isRunningTests ? $r('app.color.app_text_tertiary') : Color.White)
          .height(36)
          .layoutWeight(1)
          .onClick(() => {
            this.handleRunAllTests();
          })
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 4, bottom: this.navigationBarHeight + 12 })
    }
    .width('100%')
    .backgroundColor($r('app.color.app_surface_1'))
  }

  /**
   * 状态显示文本。
   * T-3D.4A: Ready 状态根据是否有动画区分为"已显示"和"静态展示"。
   */
  private stateDisplayText(): string {
    switch (this.loadState) {
      case Character3DLoadStateEnum.Disposed: return '已释放';
      case Character3DLoadStateEnum.Loading: return '加载中';
      case Character3DLoadStateEnum.Ready:
        return this.vm.hasAnimation() ? '已显示' : '静态展示';
      case Character3DLoadStateEnum.Playing: return '播放中';
      case Character3DLoadStateEnum.Paused: return '已暂停';
      case Character3DLoadStateEnum.Failed: return '失败';
      default: return '未知';
    }
  }

  /**
   * 模型来源显示文本。
   */
  private modelSourceDisplayText(): string {
    if (this.isExternalModel && this.modelDisplayName.length > 0) {
      return this.modelDisplayName;
    }
    return '程序化几何体';
  }

  /**
   * T-3D.3: 模型摘要文本(网格/材质/动画/节点/相机 + 特性标记)。
   * 仅在 modelInfo 非空时调用。
   */
  private modelSummaryText(): string {
    const info: GltfModelInfo = this.modelInfo as GltfModelInfo;
    const parts: string[] = [];
    parts.push('网格:' + info.meshCount);
    parts.push('材质:' + info.materialCount);
    parts.push('动画:' + info.animationCount);
    parts.push('节点:' + info.nodeCount);
    parts.push('相机:' + info.cameraCount);
    const flags: string[] = [];
    if (info.hasSkins) { flags.push('骨骼'); }
    if (info.hasTextures) { flags.push('纹理'); }
    if (info.hasMorphTargets) { flags.push('形变'); }
    if (info.hasBinChunk) { flags.push('BIN:' + info.binChunkLength + 'B'); }
    let summary: string = parts.join('  ');
    if (flags.length > 0) {
      summary += '  [' + flags.join('/') + ']';
    }
    return summary;
  }

  /**
   * 打开系统文件选择器选择 GLB/GLTF 模型文件。
   */
  private async openModelPicker(): Promise<void> {
    if (this.isImporting) {
      return;
    }
    this.isImporting = true;
    let uris: string[] = [];
    try {
      const documentPicker = new picker.DocumentViewPicker();
      const options = new picker.DocumentSelectOptions();
      options.maxSelectNumber = 1;
      // T-3D.5A: 支持 .vrm 文件(VRM 本质是 GLB,保存时转为 .glb 渲染副本)
      options.fileSuffixFilters = ['.glb', '.gltf', '.vrm'];
      uris = await documentPicker.select(options);
    } catch (e) {
      // 用户取消或系统错误,静默处理
      this.isImporting = false;
      return;
    }
    if (uris.length === 0) {
      this.isImporting = false;
      return;
    }
    try {
      this.errorMessage = '';
      this.conversionProgressMessage = '';
      this.conversionProgressPercent = 0;
      promptAction.showToast({ message: '正在导入模型…', duration: 1500 });
      await this.vm.importModel(uris[0], (progress) => {
        this.conversionProgressMessage = progress.message;
        this.conversionProgressPercent = progress.percent;
      });
      this.conversionProgressMessage = '';
      this.conversionProgressPercent = 0;
      if (this.errorMessage.length === 0) {
        promptAction.showToast({ message: '导入成功', duration: 1500 });
      }
    } catch (e) {
      const msg: string = (e as Error)?.message ?? '导入失败';
      promptAction.showToast({ message: msg, duration: 2000 });
    } finally {
      this.conversionProgressMessage = '';
      this.conversionProgressPercent = 0;
      this.isImporting = false;
    }
  }

  /**
   * 清除当前外部模型,回退到程序化几何体。
   */
  private async handleClearModel(): Promise<void> {
    if (this.isImporting) {
      return;
    }
    this.isImporting = true;
    try {
      this.errorMessage = '';
      await this.vm.clearModel();
      if (this.errorMessage.length === 0) {
        promptAction.showToast({ message: '已清除模型', duration: 1500 });
      }
    } catch (e) {
      const msg: string = (e as Error)?.message ?? '清除失败';
      promptAction.showToast({ message: msg, duration: 2000 });
    } finally {
      this.isImporting = false;
    }
  }

  /**
   * 加载内置测试模型(从 rawfile 读取并写入沙箱)。
   * 仅用于 T-3D.2 设备验证。
   */
  private async handleLoadTestModel(): Promise<void> {
    if (this.isImporting) {
      return;
    }
    this.isImporting = true;
    try {
      this.errorMessage = '';
      promptAction.showToast({ message: '正在加载测试模型…', duration: 1500 });
      await this.vm.importFromRawfile();
      if (this.errorMessage.length === 0) {
        promptAction.showToast({ message: '测试模型已加载', duration: 1500 });
      }
    } catch (e) {
      const msg: string = (e as Error)?.message ?? '加载测试模型失败';
      promptAction.showToast({ message: msg, duration: 2000 });
    } finally {
      this.isImporting = false;
    }
  }

  private canPlay(): boolean {
    return this.loadState === Character3DLoadStateEnum.Ready
      || this.loadState === Character3DLoadStateEnum.Paused;
  }

  private canPause(): boolean {
    return this.loadState === Character3DLoadStateEnum.Playing;
  }

  private canStop(): boolean {
    return this.loadState === Character3DLoadStateEnum.Playing
      || this.loadState === Character3DLoadStateEnum.Paused;
  }

  private canRespond(): boolean {
    return this.loadState === Character3DLoadStateEnum.Ready
      || this.loadState === Character3DLoadStateEnum.Playing
      || this.loadState === Character3DLoadStateEnum.Paused;
  }

  /**
   * T-3D.5: 运行全部纯逻辑测试(T-3D.4 + T-3D.5 + T-3D.5D)。
   * 通过 toast 显示测试结果摘要。
   */
  private async handleRunAllTests(): Promise<void> {
    if (this.isRunningTests) {
      return;
    }
    this.isRunningTests = true;
    try {
      promptAction.showToast({ message: '正在运行测试…', duration: 1500 });
      // T-3D.4 显示配置测试(12 项)
      const r4 = Character3DDisplayConfigTest.runAllTests();
      // T-3D.5 聊天页 3D 面板测试(14 项)
      const r5 = await Chat3DPanelTest.runAllTests();
      // T-3D.5D 手势状态机测试(模拟 pointer 序列)
      const r5d = Character3DGestureHandlerTest.runAllTests();
      const totalPassed: number = r4.passed + r5.passed + r5d.passed;
      const totalFailed: number = r4.failed + r5.failed + r5d.failed;
      const total: number = r4.total + r5.total + r5d.total;
      const summary: string = '测试完成: ' + totalPassed + '/' + total + ' passed, '
        + totalFailed + ' failed'
        + '\nT-3D.4: ' + r4.passed + '/' + r4.total
        + '\nT-3D.5: ' + r5.passed + '/' + r5.total
        + '\nT-3D.5D: ' + r5d.passed + '/' + r5d.total;
      Logger.info('PoCPage', summary);
      promptAction.showToast({ message: summary, duration: 5000 });
    } catch (e) {
      const msg: string = (e as Error)?.message ?? '运行测试失败';
      promptAction.showToast({ message: msg, duration: 3000 });
    } finally {
      this.isRunningTests = false;
    }
  }
}
