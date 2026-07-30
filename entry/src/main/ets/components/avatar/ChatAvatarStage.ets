/**
 * ChatAvatarStage — 单人聊天页面透明 Avatar Stage 组件 (Phase 4B-1)
 *
 * 职责:
 *   - 在 aboutToAppear 时创建 ArkWebChatAvatarStageController, 管理其生命周期
 *   - 渲染透明 Web 组件 (背景由 Web 端 CHAT_STAGE profile 实现透明)
 *   - 通过 visible 参数控制显示/隐藏 (不销毁模型)
 *   - onAreaChange 触发 refitFullBody (带尺寸阈值过滤, 避免输入法弹出触发)
 *   - 不响应触摸 (hitTestBehavior=Transparent), 让触摸穿透到聊天消息层
 *   - 通过 onControllerReady 回调将控制器暴露给 ChatPage
 *
 * 页面层级 (ChatPage Stack):
 *   - 背景图片层 (最底)
 *   - ChatAvatarStage (本组件, 透明 Web + VRM 模型)
 *   - 聊天消息列表层
 *   - 输入区域
 *   - 顶部导航 / AI 按钮 / AI 面板 (最顶)
 *
 * 不做的事:
 *   - 不设置 .opacity() 制造透明 (透明由 Web 端 CHAT_STAGE profile 完成)
 *   - 不绘制实体 Scene 背景 / 全屏遮罩
 *   - 不修改背景图片
 *   - 不响应模型拖拽 / 缩放
 *
 * Reference:
 *   - AGENTS.md Phase 4B-1 §页面层级 / §模型开关 / §页面尺寸变化
 *   - ArkWebChatAvatarStageController.ets (业务控制器)
 */

import { common } from '@kit.AbilityKit';
import {
  ArkWebViewerConfig
} from '../../vrmviewer/ArkWebVrmViewerTypes';
import {
  ArkWebChatAvatarStageController
} from '../../vrmviewer/ArkWebChatAvatarStageController';

const LOG_TAG: string = 'ChatAvatarStage';

/**
 * 尺寸变化触发 refitFullBody 的阈值 (vp)。
 *
 * 小于该阈值的尺寸变化 (如输入法弹出导致的小幅高度变化) 不触发 refitFullBody。
 */
const RESIZE_THRESHOLD_VP: number = 60;

/**
 * 控制器就绪回调类型。
 *
 * ChatAvatarStage 在 aboutToAppear 创建控制器后调用此回调,
 * ChatPage 保存控制器引用用于调用 publishPerformanceFromPanel 等方法。
 */
export type OnControllerReadyCallback = (controller: ArkWebChatAvatarStageController) => void;

/**
 * 单人聊天页面透明 Avatar Stage 组件。
 *
 * 使用方式:
 *   ChatAvatarStage({
 *     visible: this.chatAvatarVisible,
 *     onControllerReady: (controller) => { this.avatarStageController = controller; }
 *   })
 */
@Component
export struct ChatAvatarStage {
  /** 是否可见 (false 时隐藏 Stage 但不销毁模型) */
  @Prop @Watch('onVisibleChanged') visible: boolean = true;
  /** 控制器就绪回调 (aboutToAppear 创建控制器后调用一次) */
  onControllerReady: OnControllerReadyCallback | null = null;

  /** 内部创建的控制器 */
  private controller: ArkWebChatAvatarStageController | null = null;
  /** 上次记录的宽度 (用于尺寸变化阈值过滤) */
  private lastWidth: number = 0;
  /** 上次记录的高度 (用于尺寸变化阈值过滤) */
  private lastHeight: number = 0;

  aboutToAppear(): void {
    // 创建控制器 (生命周期由本组件管理)
    try {
      this.controller = new ArkWebChatAvatarStageController();
      // 初始化控制器 (创建 AssetLibrary / Provider / PerformanceController 等)
      const ctx: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
      this.controller.init(ctx);
      // 通知 ChatPage 控制器已就绪
      if (this.onControllerReady !== null) {
        this.onControllerReady!(this.controller);
      }
    } catch (e) {
      console.warn(LOG_TAG, 'aboutToAppear create controller failed: ' +
        (e instanceof Error ? e.message : String(e)));
    }
  }

  aboutToDisappear(): void {
    if (this.controller !== null) {
      this.controller.dispose();
      this.controller = null;
    }
  }

  /**
   * Phase 4B-1R §第五项: 可见性切换回调。
   *
   * 模型从关闭切换为开启时:
   *   - 重新确认 Stage 尺寸 (已在 setStageSize 中维护)
   *   - 如果 Model READY, 重新 fitAvatarFullBody (controller 内部会校验状态)
   */
  onVisibleChanged(): void {
    if (this.controller === null) {
      return;
    }
    if (this.visible) {
      // Phase 4B-2: 切回可见时通知 ShotDirector 恢复 FULL_BODY
      // (ShotDirector 内部会触发 refitFullBody, 不恢复隐藏前的脸部镜头)
      this.controller!.onStageVisible().catch((e: Object): void => {
        console.warn(LOG_TAG, 'onStageVisible failed: ' +
          (e instanceof Error ? e.message : String(e)));
      });
    }
  }

  build() {
    if (this.controller === null) {
      // 控制器创建失败时不渲染
    } else {
      Stack() {
        Web({
          src: $rawfile(ArkWebViewerConfig.VIEWER_PAGE_PATH),
          controller: this.controller!.getWebviewController()
        })
          .width('100%')
          .height('100%')
          // Phase 4B-1R 透明背景修复:
          // ArkWeb Web 组件必须使用 Color.Transparent (ARGB #00000000) 才能真正透明。
          // CSS 字符串 'transparent' 不被 ArkUI 原生组件识别, 会被当作无效值,
          // 导致 Web 容器使用默认不透明背景, 遮挡聊天页面背景图片。
          // 透明效果链路:
          //   Web 组件 backgroundColor = Color.Transparent (容器透明)
          //   + Web 端 CHAT_STAGE Profile (renderer clearAlpha=0 + scene.background=null)
          //   + CSS body.chat-stage { background: transparent !important }
          .backgroundColor(Color.Transparent)
          .javaScriptAccess(true)
          .domStorageAccess(true)
          .fileAccess(true)
          .onControllerAttached(() => {
            if (this.controller !== null) {
              this.controller.onWebControllerAttached();
            }
          })
          .onPageEnd(() => {
            if (this.controller !== null) {
              this.controller.onWebPageEnd();
            }
          })
          // Phase 4B-1R 修复: 资源请求拦截 (根本原因: 缺少此回调导致 ark-tavern.local
          // 模型资源 URL 无法映射到本地文件, 资源探测失败, 模型不可见)
          .onInterceptRequest((event: OnInterceptRequestEvent) => {
            if (this.controller === null) {
              return null;
            }
            const request: WebResourceRequest = event.request;
            const url: string = request.getRequestUrl();
            const method: string = request.getRequestMethod();
            const requestHeaders: Array<Header> = request.getRequestHeader();
            const response: WebResourceResponse | null =
              this.controller!.interceptResourceRequest(url, method, requestHeaders);
            if (response !== null) {
              return response;
            }
            return null;
          })
          .onErrorReceive((_e) => {
            console.warn(LOG_TAG, 'Web page load error');
          })
      }
      .width('100%')
      .height('100%')
      // 不响应触摸: 让触摸穿透到下层聊天消息列表
      // 模型默认不响应拖拽和缩放 (CHAT_STAGE profile 已禁用相机控制)
      .hitTestBehavior(HitTestMode.Transparent)
      .onAreaChange((_oldValue: Area, newValue: Area) => {
        this.handleAreaChange(newValue);
      })
      // visible=false 时隐藏整个 Stage (visibility=Hidden 保留布局, 不销毁 Web)
      .visibility(this.visible ? Visibility.Visible : Visibility.Hidden)
    }
  }

  /**
   * 处理尺寸变化。
   *
   * 防抖策略:
   *   - 始终向 controller 报告最新尺寸 (供诊断 + 全身构图使用)
   *   - 宽度或高度变化超过 RESIZE_THRESHOLD_VP 才触发 refitFullBody
   *   - 输入法弹出等小幅变化被过滤 (不触发 refit, 但仍更新 stageWidth/stageHeight)
   */
  private handleAreaChange(newArea: Area): void {
    if (this.controller === null) {
      return;
    }
    const newWidth: number = this.areaToNumber(newArea.width);
    const newHeight: number = this.areaToNumber(newArea.height);
    if (newWidth <= 0 || newHeight <= 0) {
      return;
    }
    // Phase 4B-1R §第五项: 始终向 controller 报告尺寸 (诊断 + MODEL_READY 后构图依赖此值)
    this.controller!.setStageSize(newWidth, newHeight);
    // 首次记录
    if (this.lastWidth === 0 || this.lastHeight === 0) {
      this.lastWidth = newWidth;
      this.lastHeight = newHeight;
      return;
    }
    const widthDelta: number = Math.abs(newWidth - this.lastWidth);
    const heightDelta: number = Math.abs(newHeight - this.lastHeight);
    // 阈值过滤: 小幅变化不触发 refit
    if (widthDelta < RESIZE_THRESHOLD_VP && heightDelta < RESIZE_THRESHOLD_VP) {
      return;
    }
    this.lastWidth = newWidth;
    this.lastHeight = newHeight;
    // 触发重新构图 (controller 内部会检查 MODEL_READY 状态)
    this.controller!.refitFullBody();
  }

  /**
   * 将 Area 的尺寸 (Length) 转换为数字 (vp)。
   */
  private areaToNumber(length: Length): number {
    if (typeof length === 'number') {
      return length;
    }
    if (typeof length === 'string') {
      // 去除 vp / px 单位, 解析数字部分
      const numStr: string = length.replace(/vp$|px$/, '');
      const num: number = parseFloat(numStr);
      return isNaN(num) ? 0 : num;
    }
    return 0;
  }
}
