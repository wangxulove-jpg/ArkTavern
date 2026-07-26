/**
 * ActionAvatarPreview3D 动作详情 3D 预览组件
 *
 * T-4.2G-A2: 统一动作详情与管理窗口使用的 3D 预览组件
 *
 * 职责:
 * - 渲染 Component3D(由父页面通过 @Prop scene 传入)
 * - 显示加载中 / 失败 / 无动画等状态覆盖层
 * - 提供播放/暂停/重播/停止/(可选)应用 按钮
 * - 不直接持有 Scene/ViewModel 生命周期(由父页面管理)
 *
 * 设计说明:
 * - 组件本身无状态业务,仅做 UI 渲染和事件转发
 * - 父页面持有 ActionAvatarPreviewViewModel,负责 Scene 加载和动画控制
 * - Scene 通过 @Prop 传入,组件只负责渲染
 * - 顶部"模型名/动作名"由父页面标题栏显示,组件不再重复
 *
 * 生命周期:
 * - 父页面打开弹窗:创建 ViewModel + initialize + 绑定回调
 * - 父页面关闭弹窗:dispose ViewModel + 清空 scene
 */

import { Scene } from '@kit.ArkGraphics3D';
import {
  ActionPreview3DState
} from '../viewmodels/ActionAvatarPreviewViewModel';

const LOG_TAG: string = 'ActionAvatarPreview3D';

/**
 * 动作详情 3D 预览组件。
 *
 * 使用方式:
 * ActionAvatarPreview3D({
 *   scene: this.actionDialogScene,
 *   state: this.actionDialogState,
 *   errorMessage: this.actionDialogError,
 *   onPlay: () => { this.actionDialogVm?.play(); },
 *   onPause: () => { this.actionDialogVm?.pause(); },
 *   onReplay: () => { this.actionDialogVm?.replay(); },
 *   onStop: () => { this.actionDialogVm?.stop(); },
 *   onApply: () => { this.onClickApplyAction(); } // 可选,传入时显示"应用"按钮
 * })
 */
@Component
export struct ActionAvatarPreview3D {
  /** 当前 Scene(null 时不渲染 Component3D) */
  @Prop scene: Scene | null = null;
  /** 当前预览状态 */
  @Prop state: ActionPreview3DState = ActionPreview3DState.Idle;
  /** 错误信息(Failed 状态时非空) */
  @Prop errorMessage: string = '';

  /** 播放回调 */
  onPlay: (() => void) | null = null;
  /** 暂停回调 */
  onPause: (() => void) | null = null;
  /** 重播回调 */
  onReplay: (() => void) | null = null;
  /** 停止回调 */
  onStop: (() => void) | null = null;
  /** 重试回调(加载失败时) */
  onRetry: (() => void) | null = null;
  /** T-4.2G-A2: 应用动作到当前模型回调(传入时显示"应用"按钮) */
  onApply: (() => void) | null = null;

  build(): void {
    Column() {
      // 3D 预览区域(固定高度,避免灰色空白)
      Stack() {
        if (this.state === ActionPreview3DState.LoadingAvatar
          || this.state === ActionPreview3DState.LoadingMotion
          || this.state === ActionPreview3DState.PreparingRetarget) {
          // 加载中
          Column() {
            LoadingProgress()
              .width(36)
              .height(36)
              .color('#007DFF');
            Text('加载中...')
              .fontSize(13)
              .fontColor('#666666')
              .margin({ top: 8 });
          }
          .justifyContent(FlexAlign.Center)
          .alignItems(HorizontalAlign.Center);
        } else if (this.state === ActionPreview3DState.Failed) {
          // 加载失败
          Column() {
            Text('⚠')
              .fontSize(40)
              .fontColor('#ff9800');
            Text(this.errorMessage.length > 0 ? this.errorMessage : '预览加载失败')
              .fontSize(13)
              .fontColor('#666666')
              .margin({ top: 8, bottom: 12 })
              .textAlign(TextAlign.Center);
            if (this.onRetry !== null) {
              Button('重试')
                .fontSize(13)
                .height(32)
                .backgroundColor('#007DFF')
                .fontColor('#ffffff')
                .onClick(() => {
                  if (this.onRetry !== null) {
                    this.onRetry();
                  }
                });
            }
          }
          .justifyContent(FlexAlign.Center)
          .alignItems(HorizontalAlign.Center)
          .padding(16);
        } else if (this.scene !== null) {
          // 正常渲染 3D 场景
          Component3D({
            scene: this.scene as Scene,
            modelType: ModelType.SURFACE
          })
            .width('100%')
            .height('100%');

          // StaticOnly 状态叠加提示
          if (this.state === ActionPreview3DState.StaticOnly) {
            Column() {
              Text('当前模型无内置动画,仅静态预览')
                .fontSize(11)
                .fontColor('#666666')
                .backgroundColor('rgba(255,255,255,0.8)')
                .padding({ left: 8, right: 8, top: 4, bottom: 4 })
                .borderRadius(4);
            }
            .width('100%')
            .height('100%')
            .justifyContent(FlexAlign.End)
            .alignItems(HorizontalAlign.Center)
            .padding({ bottom: 8 });
          }
        } else {
          // 空闲或其他状态无 Scene
          Column() {
            Text('🎬')
              .fontSize(40);
            Text('等待加载预览...')
              .fontSize(13)
              .fontColor('#999999')
              .margin({ top: 8 });
          }
          .justifyContent(FlexAlign.Center)
          .alignItems(HorizontalAlign.Center);
        }
      }
      .width('100%')
      .height(380)
      .backgroundColor('#f0f0f0')
      .borderRadius(8);

      // 控制按钮:播放/暂停 | 重播 | 停止 | (可选)应用
      Row() {
        Button(this.getPlayButtonLabel())
          .fontSize(13)
          .height(34)
          .layoutWeight(1)
          .backgroundColor(this.getPlayButtonColor())
          .fontColor('#ffffff')
          .margin({ right: 4 })
          .enabled(this.canControlPlayback())
          .key('actionDetail.play')
          .onClick(() => {
            this.onPlaybackToggle();
          });
        Button('重播')
          .fontSize(13)
          .height(34)
          .layoutWeight(1)
          .backgroundColor('#28a745')
          .fontColor('#ffffff')
          .margin({ left: 4, right: 4 })
          .enabled(this.canControlPlayback())
          .key('actionDetail.replay')
          .onClick(() => {
            if (this.onReplay !== null) {
              this.onReplay();
            }
          });
        Button('停止')
          .fontSize(13)
          .height(34)
          .layoutWeight(1)
          .backgroundColor('#cccccc')
          .fontColor('#333333')
          .margin({ left: 4, right: 4 })
          .enabled(this.canControlPlayback())
          .key('actionDetail.stop')
          .onClick(() => {
            if (this.onStop !== null) {
              this.onStop();
            }
          });
        if (this.onApply !== null) {
          Button('应用')
            .fontSize(13)
            .height(34)
            .layoutWeight(1)
            .backgroundColor('#17a2b8')
            .fontColor('#ffffff')
            .margin({ left: 4 })
            .key('actionDetail.apply')
            .onClick(() => {
              if (this.onApply !== null) {
                this.onApply();
              }
            });
        }
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 8, bottom: 8 });
    }
    .width('100%')
    .backgroundColor('#ffffff')
    .borderRadius(8);
  }

  /**
   * 获取播放按钮文案。
   * Playing 状态显示"暂停",其他可播放状态显示"播放"。
   */
  private getPlayButtonLabel(): string {
    if (this.state === ActionPreview3DState.Playing) {
      return '暂停';
    }
    return '播放';
  }

  /**
   * 获取播放按钮颜色。
   */
  private getPlayButtonColor(): string {
    if (this.state === ActionPreview3DState.Playing) {
      return '#ff9800';
    }
    return '#007DFF';
  }

  /**
   * 是否可以控制播放(需要有 Scene 且非加载中/失败)。
   */
  private canControlPlayback(): boolean {
    return this.scene !== null
      && this.state !== ActionPreview3DState.LoadingAvatar
      && this.state !== ActionPreview3DState.LoadingMotion
      && this.state !== ActionPreview3DState.PreparingRetarget
      && this.state !== ActionPreview3DState.Failed
      && this.state !== ActionPreview3DState.StaticOnly;
  }

  /**
   * 播放/暂停切换。
   */
  private onPlaybackToggle(): void {
    if (this.state === ActionPreview3DState.Playing) {
      if (this.onPause !== null) {
        this.onPause();
      }
    } else {
      if (this.onPlay !== null) {
        this.onPlay();
      }
    }
  }
}
