/**
 * ArkWebVrmViewerController — ArkWeb VRM Viewer 主控制器
 *
 * 职责:
 * 1. 管理 WebviewController 生命周期
 * 2. 注册 Native Bridge(arkTavernNative)到 Web 端
 * 3. 绑定 JsCaller(arkTavernViewerBridge)用于调用 Web 端
 * 4. 维护 ArkWebViewerState 状态机
 * 5. 提供 initializeViewer / disposeViewer / getViewerState 接口给页面
 * 6. 在 onPageEnd 时注册 Bridge 并触发初始化
 *
 * 状态机(Phase 1A 子集):
 * - UNINITIALIZED → INITIALIZING → READY
 * - UNINITIALIZED → INITIALIZING → FAILED
 * - 任意 → DISPOSING → DISPOSED
 *
 * Reference:
 * - HarmonyOS ArkWeb: WebviewController.registerJavaScriptProxy / runJavaScript
 * - figure-main: initThree / disposeVrm(本阶段未实现,仅保留接口)
 * - ownverse-vrm-viewer: VIEWER_ARCHITECTURE.md §Bootstrap Sequence
 */
import { webview } from '@kit.ArkWeb';
import {
  ArkWebAnimationState,
  ArkWebModelState,
  ArkWebViewerConfig,
  ArkWebViewerErrorCode,
  ArkWebViewerState
} from './ArkWebVrmViewerTypes';
import {
  ArkWebViewerBridgeListener,
  ArkWebViewerJsCaller,
  ArkWebVrmViewerNativeBridge
} from './ArkWebVrmViewerBridge';

/**
 * Viewer 事件监听器(供页面订阅状态变化)。
 */
export interface ArkWebViewerEventListener {
  onStateChanged(state: ArkWebViewerState, detail: string): void;
  onError(code: string, message: string): void;
}

/**
 * ArkWeb VRM Viewer 主控制器。
 *
 * 使用方式:
 * 1. 页面 aboutToAppear 创建实例
 * 2. 在 Web 组件的 controller 属性传入 getWebviewController()
 * 3. 在 Web 组件的 onControllerAttached 回调中调用 onControllerAttached()
 * 4. 在 Web 组件的 onPageEnd 回调中调用 onPageEnd()
 * 5. 页面 aboutToDisappear 调用 destroy()
 */
export class ArkWebVrmViewerController implements ArkWebViewerBridgeListener {
  private webviewController: webview.WebviewController = new webview.WebviewController();
  private nativeBridge: ArkWebVrmViewerNativeBridge = new ArkWebVrmViewerNativeBridge();
  private jsCaller: ArkWebViewerJsCaller = new ArkWebViewerJsCaller();

  private state: ArkWebViewerState = ArkWebViewerState.UNINITIALIZED;
  private detail: string = '未初始化';
  private lastErrorCode: string = '';
  private lastErrorMessage: string = '';

  private listener: ArkWebViewerEventListener | null = null;
  private disposed: boolean = false;

  /** 初始化超时计时器 ID。 */
  private initTimerId: number = -1;

  constructor() {
    // Native Bridge 的回调由本类处理
    this.nativeBridge.setListener(this);
  }

  /** 设置事件监听器(通常是页面)。 */
  setEventListener(listener: ArkWebViewerEventListener): void {
    this.listener = listener;
  }

  /** 获取 WebviewController,供 Web 组件使用。 */
  getWebviewController(): webview.WebviewController {
    return this.webviewController;
  }

  /** 获取当前状态。 */
  getState(): ArkWebViewerState {
    return this.state;
  }

  /** 获取详细描述。 */
  getDetail(): string {
    return this.detail;
  }

  /** 获取最近错误代码。 */
  getLastErrorCode(): string {
    return this.lastErrorCode;
  }

  /** 获取最近错误信息。 */
  getLastErrorMessage(): string {
    return this.lastErrorMessage;
  }

  // ===== Phase 1B 新增:相机 / Resize / Scene State 控制接口 =====

  /**
   * 重置相机到默认位置与目标点。
   * 由页面"聚焦" / "重置"按钮调用。
   * 内部通过 Bridge 调用 Web 端 ViewerCore.resetCamera()。
   */
  async resetCamera(): Promise<void> {
    if (this.disposed) {
      console.warn('[ArkWebVrmViewerController] resetCamera ignored: disposed');
      return;
    }
    try {
      const resultJson: string = await this.jsCaller.resetCamera();
      console.info('[ArkWebVrmViewerController] resetCamera result: ' + resultJson);
    } catch (e) {
      const msg = e instanceof Error ? e.message : String(e);
      console.warn('[ArkWebVrmViewerController] resetCamera failed: ' + msg);
    }
  }

  /**
   * 主动通知 Web 端 Viewer 尺寸变化。
   * 当 ArkUI 检测到 Web 组件容器尺寸变化时调用(配合 ResizeObserver 兜底)。
   * @param width 容器宽度(px)
   * @param height 容器高度(px)
   */
  async resizeViewer(width: number, height: number): Promise<void> {
    if (this.disposed) {
      return;
    }
    if (width <= 0 || height <= 0) {
      return;
    }
    try {
      await this.jsCaller.resizeViewer(width, height);
    } catch (e) {
      const msg = e instanceof Error ? e.message : String(e);
      console.warn('[ArkWebVrmViewerController] resizeViewer failed: ' + msg);
    }
  }

  /**
   * 获取场景详细状态(供调试 Tab 显示)。
   * 返回 JSON 字符串,包含 sceneReady / cameraReady / frameLoopRunning 等字段。
   */
  async getSceneState(): Promise<string> {
    if (this.disposed) {
      return JSON.stringify({ success: false, error: 'disposed' });
    }
    try {
      return await this.jsCaller.getSceneState();
    } catch (e) {
      const msg = e instanceof Error ? e.message : String(e);
      return JSON.stringify({ success: false, error: msg });
    }
  }

  // ===== Phase 1D-2A: 缓存模型资源协议骨架(不触发加载) =====

  /**
   * 准备模型资源(仅保存元数据到 Web 端 keeper,不触发加载)。
   *
   * @param resourceJson 资源元数据 JSON 字符串
   *   必需字段:resourceUrl / displayName / mimeType / size / extension
   *   禁止字段:cachePath / sourceUri(keeper 会自动过滤)
   * @returns Web 端 keeper 返回的 JSON 字符串
   */
  async prepareModelResource(resourceJson: string): Promise<string> {
    if (this.disposed) {
      return JSON.stringify({ success: false, error: 'disposed' });
    }
    try {
      return await this.jsCaller.prepareModelResource(resourceJson);
    } catch (e) {
      const msg = e instanceof Error ? e.message : String(e);
      return JSON.stringify({ success: false, error: msg });
    }
  }

  /**
   * 获取当前已准备的模型资源。
   * @returns JSON 字符串,形如 {"success": true, "resource": <object|null>}
   */
  async getPreparedModelResource(): Promise<string> {
    if (this.disposed) {
      return JSON.stringify({ success: false, error: 'disposed' });
    }
    try {
      return await this.jsCaller.getPreparedModelResource();
    } catch (e) {
      const msg = e instanceof Error ? e.message : String(e);
      return JSON.stringify({ success: false, error: msg });
    }
  }

  /**
   * 清除已准备的模型资源(不影响已加载模型,本阶段无已加载模型)。
   * @returns JSON 字符串,形如 {"success": true, "state": "RESOURCE_CLEARED"}
   */
  async clearPreparedModelResource(): Promise<string> {
    if (this.disposed) {
      return JSON.stringify({ success: false, error: 'disposed' });
    }
    try {
      return await this.jsCaller.clearPreparedModelResource();
    } catch (e) {
      const msg = e instanceof Error ? e.message : String(e);
      return JSON.stringify({ success: false, error: msg });
    }
  }

  // ===== Phase 1D-2B-1: 资源探测(HEAD 请求校验,不读取模型文件) =====

  /**
   * 启动资源探测(HEAD 请求)。
   *
   * 同步启动探测任务,立即返回。最终结果通过 getModelResourceProbeResult() 轮询获取。
   *
   * JavaScript 端行为:
   * - 从 preparedResource keeper 获取资源元数据
   * - 调用 ViewerModelResourceProbe.probe(resource) 异步发起 HEAD fetch
   * - 校验响应:status === 200 / Content-Type / Content-Length / X-ArkTavern-Resource-Id
   * - 结果存储在 probe.lastResult(VERIFIED / FAILED)
   *
   * 严格不调用:
   * - GLTFLoader.load()
   * - ViewerModelLoader.loadModel()
   * - response.arrayBuffer() / response.blob() / response.body.getReader()
   *
   * @returns JSON 字符串
   *   启动成功:{"success": true, "state": "PROBING", "message": "..."}
   *   启动失败:{"success": false, "error": {"code": "...", "message": "..."}}
   */
  async probePreparedModelResource(): Promise<string> {
    if (this.disposed) {
      return JSON.stringify({ success: false, error: 'disposed' });
    }
    try {
      return await this.jsCaller.probePreparedModelResource();
    } catch (e) {
      const msg = e instanceof Error ? e.message : String(e);
      return JSON.stringify({ success: false, error: msg });
    }
  }

  /**
   * 获取最近一次探测结果(同步)。
   *
   * 用于轮询 probePreparedModelResource() 启动后的最终结果。
   *
   * @returns JSON 字符串
   *   {"success": true, "result": <ModelResourceProbeResult|null>}
   *   result.state 为 NOT_PROBED / PROBING / VERIFIED / FAILED
   */
  async getModelResourceProbeResult(): Promise<string> {
    if (this.disposed) {
      return JSON.stringify({ success: false, error: 'disposed' });
    }
    try {
      return await this.jsCaller.getModelResourceProbeResult();
    } catch (e) {
      const msg = e instanceof Error ? e.message : String(e);
      return JSON.stringify({ success: false, error: msg });
    }
  }

  /**
   * 清除探测状态(资源被替换 / 清除时由 keeper 方法自动调用)。
   *
   * - 重置 probe.state 为 NOT_PROBED
   * - 清空 probe.lastResult
   * - 不影响正在进行的探测(代次检查会让其结果过期)
   *
   * @returns JSON 字符串,形如 {"success": true, "state": "PROBE_CLEARED"}
   */
  async clearModelResourceProbe(): Promise<string> {
    if (this.disposed) {
      return JSON.stringify({ success: false, error: 'disposed' });
    }
    try {
      return await this.jsCaller.clearModelResourceProbe();
    } catch (e) {
      const msg = e instanceof Error ? e.message : String(e);
      return JSON.stringify({ success: false, error: msg });
    }
  }

  // ===== Phase 1D-2B-2: 用户模型加载(GLTFLoader 实际加载与原子替换) =====

  /**
   * 启动用户模型加载。
   *
   * 同步启动加载任务,立即返回。最终结果通过 getPreparedModelLoadResult() 轮询获取。
   *
   * JavaScript 端行为:
   * - 从 preparedResource keeper 获取资源元数据
   * - 从 arkTavernModelResourceProbe 获取探测结果
   * - 调用 ViewerUserModelLoadCoordinator.start(resource, probeResult)
   *   - 检查前置条件:Viewer READY / 资源已准备 / 探测 VERIFIED / URL 一致 / ID 一致 / 格式允许
   *   - 通过后调用 ViewerCore.loadUserModelResource(resource)
   *     → ViewerModelLoader.loadModel(resourceUrl, displayName)
   *     → GLTFLoader GET 受控 URL
   *     → ArkWebModelResourceProvider FD 响应
   *     → 新 VRM 解析与优化
   *     → onReplaceModel 同步完成 Scene 替换
   *     → 提交 currentVrm / displayName
   *     → 释放旧模型
   *     → state = READY
   *
   * 严格不:
   * - 不接受 URL 参数
   * - 不直接调用 GLTFLoader.load()
   * - 不直接调用 fetch / arrayBuffer / blob
   *
   * 失败时:
   * - Provider 保持 READY
   * - PreparedResource 保持
   * - ProbeResult 保持 VERIFIED
   * - 当前模型保持显示
   * - 用户可再次点击"加载模型"
   *
   * @returns JSON 字符串
   *   启动成功:{"success": true, "state": "LOADING", "message": "..."}
   *   启动失败:{"success": false, "error": {"code": "...", "message": "..."}}
   */
  async loadPreparedModelResource(): Promise<string> {
    if (this.disposed) {
      return JSON.stringify({ success: false, error: 'disposed' });
    }
    try {
      return await this.jsCaller.loadPreparedModelResource();
    } catch (e) {
      const msg = e instanceof Error ? e.message : String(e);
      return JSON.stringify({ success: false, error: msg });
    }
  }

  /**
   * 获取最近一次用户模型加载结果(同步)。
   *
   * 用于轮询 loadPreparedModelResource() 启动后的最终结果。
   *
   * @returns JSON 字符串
   *   {"success": true, "result": <UserModelLoadResult|null>}
   *   result.state 为 NOT_REQUESTED / LOADING / READY / FAILED / DISPOSED
   *   result 不含 cachePath / sourceUri / 文件描述符
   */
  async getPreparedModelLoadResult(): Promise<string> {
    if (this.disposed) {
      return JSON.stringify({ success: false, error: 'disposed' });
    }
    try {
      return await this.jsCaller.getPreparedModelLoadResult();
    } catch (e) {
      const msg = e instanceof Error ? e.message : String(e);
      return JSON.stringify({ success: false, error: msg });
    }
  }

  /**
   * 清除用户模型加载结果(不影响已加载模型)。
   *
   * - 重置 coordinator.state 为 NOT_REQUESTED
   * - 清空 coordinator.lastResult
   * - 不影响已加载到 Viewer 的模型
   *
   * @returns JSON 字符串,形如 {"success": true, "state": "LOAD_RESULT_CLEARED"}
   */
  async clearPreparedModelLoadResult(): Promise<string> {
    if (this.disposed) {
      return JSON.stringify({ success: false, error: 'disposed' });
    }
    try {
      return await this.jsCaller.clearPreparedModelLoadResult();
    } catch (e) {
      const msg = e instanceof Error ? e.message : String(e);
      return JSON.stringify({ success: false, error: msg });
    }
  }

  // ===== Web 组件生命周期回调 =====

  /**
   * Web 组件控制器已附加。
   * 此时可以配置 WebviewController(如开启调试)。
   */
  onControllerAttached(): void {
    if (this.disposed) {
      return;
    }
    try {
      // 开启 Web 调试(便于 hdc 连接时调试,生产可关闭)
      webview.WebviewController.setWebDebuggingAccess(true);
      console.info('[ArkWebVrmViewerController] Web controller attached, debugging access enabled');
    } catch (e) {
      console.warn('[ArkWebVrmViewerController] setWebDebuggingAccess failed: ' + (e instanceof Error ? e.message : String(e)));
    }
  }

  /**
   * Web 页面加载完成(对应 Web 组件 onPageEnd)。
   *
   * 此时:
   * 1. 注册 Native Bridge(arkTavernNative)到 Web 端
   * 2. 绑定 JsCaller(arkTavernViewerBridge)
   * 3. 触发 initializeViewer
   */
  async onPageEnd(): Promise<void> {
    if (this.disposed) {
      return;
    }
    console.info('[ArkWebVrmViewerController] Web page loaded, registering bridge');

    try {
      // 1. 注册 Native Bridge
      //    方法名必须与 ArkWebVrmViewerNativeBridge 的方法一致
      this.webviewController.registerJavaScriptProxy(
        this.nativeBridge,
        ArkWebViewerConfig.BRIDGE_NAME_NATIVE,
        ArkWebViewerConfig.BRIDGE_METHODS_NATIVE.slice()
      );
      this.nativeBridge.markRegistered();
      console.info('[ArkWebVrmViewerController] Native bridge registered as window.' + ArkWebViewerConfig.BRIDGE_NAME_NATIVE);

      // 2. 绑定 JsCaller(使用闭包捕获 runJavaScript)
      this.jsCaller.bind((script: string): Promise<string> => {
        return this.webviewController.runJavaScript(script);
      });

      // 3. 切换状态为 INITIALIZING
      this.setState(ArkWebViewerState.INITIALIZING, '正在调用 initializeViewer');

      // 4. 启动初始化超时保护
      this.startInitTimeout();

      // 5. 调用 Web 端 initializeViewer
      const resultJson: string = await this.jsCaller.initializeViewer();
      this.clearInitTimeout();

      console.info('[ArkWebVrmViewerController] initializeViewer result: ' + resultJson);

      // 解析结果(简单判断,不依赖 JSON.parse,避免 ArkTS 类型问题)
      if (resultJson.indexOf('"success":true') >= 0 || resultJson.indexOf('"success": true') >= 0) {
        // 成功:状态由 onViewerReady 回调推进到 READY,这里不直接设置
        console.info('[ArkWebVrmViewerController] initializeViewer succeeded, waiting for onViewerReady');
      } else {
        // 失败
        this.handleInitFailure(resultJson);
      }
    } catch (e) {
      this.clearInitTimeout();
      const msg = e instanceof Error ? e.message : String(e);
      console.error('[ArkWebVrmViewerController] onPageEnd failed: ' + msg);
      this.handleInitFailure(JSON.stringify({ success: false, error: msg }));
    }
  }

  /** 页面销毁时调用。 */
  destroy(): void {
    if (this.disposed) {
      return;
    }
    console.info('[ArkWebVrmViewerController] destroy() called');
    this.setState(ArkWebViewerState.DISPOSING, '正在销毁 Viewer');

    this.clearInitTimeout();

    // 通知 Web 端 dispose(异步,不等待)
    this.jsCaller.disposeViewer().then((_result: string) => {
      console.info('[ArkWebVrmViewerController] Web side disposed');
    }).catch((e: Object) => {
      console.warn('[ArkWebVrmViewerController] Web side dispose failed: ' + (e instanceof Error ? e.message : String(e)));
    });

    this.jsCaller.unbind();
    this.nativeBridge.dispose();

    this.setState(ArkWebViewerState.DISPOSED, 'Viewer 已销毁');
    this.disposed = true;
  }

  // ===== ArkWebViewerBridgeListener 实现 =====
  // 由 Native Bridge 在 Web 端调用时触发

  onViewerReady(): void {
    if (this.disposed) {
      return;
    }
    this.lastErrorCode = '';
    this.lastErrorMessage = '';
    this.setState(ArkWebViewerState.READY, 'Viewer 就绪 (Phase 1B: Three.js Scene 已挂载)');
  }

  onViewerError(code: string, message: string, phase: string, _recoverable: boolean): void {
    if (this.disposed) {
      return;
    }
    console.warn(`[ArkWebVrmViewerController] viewer error: code=${code}, phase=${phase}, msg=${message}`);
    this.lastErrorCode = code;
    this.lastErrorMessage = message;
    this.setState(ArkWebViewerState.FAILED, `错误: ${message}`);
    if (this.listener !== null) {
      this.listener.onError(code, message);
    }
  }

  onModelStateChanged(_state: ArkWebModelState): void {
    // Phase 1A:模型状态变化不更新 Viewer 状态机,仅记录
    // Phase 1C 之后将在此推进到 MODEL_READY
  }

  onAnimationStateChanged(_state: ArkWebAnimationState): void {
    // Phase 1A:动画状态变化不处理
    // Phase 3+ 将在此推进到 ANIMATION_READY
  }

  // ===== 内部方法 =====

  private setState(state: ArkWebViewerState, detail: string): void {
    if (this.disposed && state !== ArkWebViewerState.DISPOSED) {
      return;
    }
    this.state = state;
    this.detail = detail;
    console.info(`[ArkWebVrmViewerController] state=${state}, detail=${detail}`);
    if (this.listener !== null) {
      this.listener.onStateChanged(state, detail);
    }
  }

  private startInitTimeout(): void {
    this.clearInitTimeout();
    this.initTimerId = setTimeout(() => {
      if (this.state === ArkWebViewerState.INITIALIZING) {
        console.warn('[ArkWebVrmViewerController] initializeViewer timeout');
        this.onViewerError(
          ArkWebViewerErrorCode.INIT_FAILED,
          'Viewer 初始化超时',
          'INITIALIZING',
          true
        );
      }
    }, ArkWebViewerConfig.INIT_TIMEOUT_MS);
  }

  private clearInitTimeout(): void {
    if (this.initTimerId >= 0) {
      clearTimeout(this.initTimerId);
      this.initTimerId = -1;
    }
  }

  private handleInitFailure(resultJson: string): void {
    let errorMsg: string = '未知错误';
    // 简单字符串匹配提取 error 字段(避免 JSON.parse 的类型问题)
    const errorMatch: RegExpMatchArray | null = resultJson.match(/"error"\s*:\s*"([^"]*)"/);
    if (errorMatch !== null && errorMatch.length >= 2) {
      errorMsg = errorMatch[1];
    }
    this.onViewerError(
      ArkWebViewerErrorCode.INIT_FAILED,
      `initializeViewer 失败: ${errorMsg}`,
      'INITIALIZING',
      true
    );
  }
}
