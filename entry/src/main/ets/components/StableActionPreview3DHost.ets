/**
 * StableActionPreview3DHost 稳定 3D 预览宿主组件
 *
 * T-4.2G-A3: Component3D Surface 闪烁/黑屏修复
 *
 * 关键设计:
 * - 不使用 if 条件控制 Component3D 创建
 * - 始终创建 Component3D,传入 scene(可能为 null)
 * - ArkGraphics3D 内部会处理 null Scene(显示空白)
 * - 当 scene 从 null 变为非 null 时,Component3D 自动绑定,不重建
 *
 * 这避免了 if 条件变化导致的 Component3D 重建问题。
 * ArkUI 的 @Prop 对 Scene 引用的监听足以触发 Component3D 内部更新。
 */

import { Scene } from '@kit.ArkGraphics3D';
import { Logger } from '../utils/Logger';

const HOST_LOG_TAG: string = 'StableActionPreview3DHost';

@Component
export struct StableActionPreview3DHost {
  /** 接收的 Scene 引用(父组件传入) */
  @Prop @Watch('onSceneChanged') scene: Scene | null = null;
  /** 控制可见性 */
  @Prop @Watch('onVisibleChanged') visible: boolean = false;

  /**
   * Scene 变化回调(仅日志,不修改任何状态)。
   */
  private onSceneChanged(): void {
    Logger.info(HOST_LOG_TAG, 'Host receive scene: incomingNull=' + (this.scene === null));
  }

  /**
   * 可见性变化回调(仅日志)。
   */
  private onVisibleChanged(): void {
    Logger.info(HOST_LOG_TAG, 'Host visible change: visible=' + this.visible);
  }

  aboutToAppear(): void {
    Logger.info(HOST_LOG_TAG, 'Host aboutToAppear: incomingSceneNull=' + (this.scene === null));
  }

  aboutToDisappear(): void {
    Logger.info(HOST_LOG_TAG, 'Host aboutToDisappear');
  }

  build(): void {
    // 关键: 不使用 if 条件,始终创建 Component3D
    // scene 为 null 时 Component3D 显示空白,但不重建
    // scene 从 null 变为非 null 时,Component3D 自动绑定,不触发重建
    Stack() {
      Component3D({
        scene: this.scene as Scene,
        modelType: ModelType.SURFACE
      })
        .width('100%')
        .height('100%')
        .opacity(this.visible ? 1 : 0);
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#1a1a1a');
  }
}
