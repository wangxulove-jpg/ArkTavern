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

  /**
   * Phase 1D-2C-2A: 初始化请求代次。
   *
   * 防止 onPageEnd 重复触发 initializeViewer:
   * - 0:从未请求初始化
   * - 1:已请求过一次初始化(onPageEnd 触发)
   * - 后续值:每次 retryInitializeViewer 递增
   *
   * 规则:
   * - UNINITIALIZED → 启动一次 initialize
   * - INITIALIZING → 返回当前状态,不再次 initialize
   * - READY → 幂等返回 READY
   * - FAILED → 默认返回保存的错误,只有明确点击"重试 Viewer"才重新初始化
   * - onPageEnd 每次页面实例只触发一次初始化请求
   */
  private initializeGeneration: number = 0;
  /** onPageEnd 是否已请求过初始化(防止页面实例内重复初始化)。 */
  private initializeRequestedFromPageEnd: boolean = false;

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

  // ===== Phase 1D-2C-1: 运行时诊断 =====

  /**
   * 获取 Web 端最近一条运行时诊断记录。
   *
   * 诊断由 Provider / Coordinator / GLTFLoader 通过 onDiagnostic 回调上报到 Web 端诊断中心。
   * ArkTS 端通过本方法轮询拉取,在页面显示真实失败阶段、错误码和错误信息。
   *
   * @returns JSON 字符串
   *   {"success": true, "diagnostic": <VrmRuntimeDiagnostic|null>}
   *   diagnostic 不含 cachePath / sourceUri / fd / stack / 用户目录
   */
  async getVrmRuntimeDiagnostic(): Promise<string> {
    if (this.disposed) {
      return JSON.stringify({ success: false, error: 'disposed' });
    }
    try {
      return await this.jsCaller.getVrmRuntimeDiagnostic();
    } catch (e) {
      const msg = e instanceof Error ? e.message : String(e);
      return JSON.stringify({ success: false, error: msg });
    }
  }

  /**
   * 清除 Web 端诊断中心最近一条诊断记录。
   *
   * 不影响 Provider / Coordinator / GLTFLoader 的运行状态。
   *
   * @returns JSON 字符串,形如 {"success": true, "state": "DIAGNOSTIC_CLEARED"}
   */
  async clearVrmRuntimeDiagnostic(): Promise<string> {
    if (this.disposed) {
      return JSON.stringify({ success: false, error: 'disposed' });
    }
    try {
      return await this.jsCaller.clearVrmRuntimeDiagnostic();
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
   * 3. 触发 initializeViewer(每次页面实例只触发一次)
   *
   * Phase 1D-2C-2A:
   * - 防止重复初始化:onPageEnd 多次触发时,只第一次调用 initializeViewer
   * - 解析 initializeViewer 同步返回的 JSON 字符串
   * - 正确处理 INITIALIZING 状态(不当作失败)
   * - 失败时完整保留 error.code / error.message / error.phase / error.recoverable
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

      // 3. Phase 1D-2C-2A: 防止重复初始化
      //    onPageEnd 在页面实例内只触发一次 initializeViewer 请求
      if (this.initializeRequestedFromPageEnd) {
        console.info(`[ArkWebVrmViewerController] initializeViewer already requested (state=${this.state}), skip`);
        return;
      }
      this.initializeRequestedFromPageEnd = true;
      this.initializeGeneration++;

      // 4. 切换状态为 INITIALIZING
      this.setState(ArkWebViewerState.INITIALIZING, '正在调用 initializeViewer');

      // 5. 启动初始化超时保护
      this.startInitTimeout();

      // 6. 调用 Web 端 initializeViewer(同步返回 JSON 字符串)
      const resultJson: string = await this.jsCaller.initializeViewer();
      console.info('[ArkWebVrmViewerController] initializeViewer result: ' + resultJson);

      // 7. Phase 1D-2C-2A: 解析返回结果(支持 INITIALIZING / READY / FAILED)
      const parsed: InitResultParseOutcome = this.parseInitResultJson(resultJson);

      if (parsed.kind === 'INITIALIZING') {
        // success=true,state=INITIALIZING → 保持 INITIALIZING,等待 onViewerReady/onViewerError
        this.clearInitTimeout();
        console.info('[ArkWebVrmViewerController] initializeViewer returned INITIALIZING, waiting for callback');
        // 状态保持 INITIALIZING,不修改 detail(避免覆盖更具体的进度)
        return;
      }

      if (parsed.kind === 'READY') {
        // success=true,state=READY → 直接推进到 READY(理论罕见,Web 端通常异步)
        this.clearInitTimeout();
        console.info('[ArkWebVrmViewerController] initializeViewer returned READY directly');
        this.onViewerReady();
        return;
      }

      // parsed.kind === 'FAILED'
      this.clearInitTimeout();
      this.handleInitFailure(parsed);
    } catch (e) {
      this.clearInitTimeout();
      const msg = e instanceof Error ? e.message : String(e);
      console.error('[ArkWebVrmViewerController] onPageEnd failed: ' + msg);
      const fail: InitResultParseOutcome = {
        kind: 'FAILED',
        code: ArkWebViewerErrorCode.INIT_FAILED,
        message: `onPageEnd 异常: ${msg}`,
        phase: 'INITIALIZING',
        recoverable: true,
        rawSummary: msg
      };
      this.handleInitFailure(fail);
    }
  }

  /**
   * Phase 1D-2C-2A: 重试 Viewer 初始化。
   *
   * 仅在 Viewer 处于 FAILED 状态时有效。由页面"重试 Viewer"按钮调用。
   *
   * 行为:
   * 1. 校验当前状态为 FAILED(否则返回 RETRY_NOT_ALLOWED)
   * 2. 清除 lastErrorCode / lastErrorMessage
   * 3. 递增 initializeGeneration
   * 4. 状态切换为 INITIALIZING
   * 5. 启动超时保护
   * 6. 调用 Web 端 retryInitializeViewer(同步返回 JSON 字符串)
   * 7. 解析返回结果(INITIALIZING / READY / FAILED)
   * 8. 等待 onViewerReady / onViewerError 回调推进状态
   */
  async retryInitializeViewer(): Promise<void> {
    if (this.disposed) {
      console.warn('[ArkWebVrmViewerController] retryInitializeViewer ignored: disposed');
      return;
    }
    if (this.state !== ArkWebViewerState.FAILED) {
      console.warn(`[ArkWebVrmViewerController] retryInitializeViewer ignored: state=${this.state} (requires FAILED)`);
      return;
    }

    // 清除当前 Viewer 错误
    this.lastErrorCode = '';
    this.lastErrorMessage = '';

    // 递增代次,触发新的初始化请求
    this.initializeGeneration++;

    // 状态切换为 INITIALIZING
    this.setState(ArkWebViewerState.INITIALIZING, '正在重试 initializeViewer');

    // 启动超时保护
    this.startInitTimeout();

    try {
      const resultJson: string = await this.jsCaller.retryInitializeViewer();
      console.info('[ArkWebVrmViewerController] retryInitializeViewer result: ' + resultJson);

      const parsed: InitResultParseOutcome = this.parseInitResultJson(resultJson);

      if (parsed.kind === 'INITIALIZING') {
        this.clearInitTimeout();
        console.info('[ArkWebVrmViewerController] retryInitializeViewer returned INITIALIZING, waiting for callback');
        return;
      }

      if (parsed.kind === 'READY') {
        this.clearInitTimeout();
        console.info('[ArkWebVrmViewerController] retryInitializeViewer returned READY directly');
        this.onViewerReady();
        return;
      }

      this.clearInitTimeout();
      this.handleInitFailure(parsed);
    } catch (e) {
      this.clearInitTimeout();
      const msg = e instanceof Error ? e.message : String(e);
      console.error('[ArkWebVrmViewerController] retryInitializeViewer failed: ' + msg);
      const fail: InitResultParseOutcome = {
        kind: 'FAILED',
        code: ArkWebViewerErrorCode.INIT_FAILED,
        message: `retryInitializeViewer 异常: ${msg}`,
        phase: 'INITIALIZING',
        recoverable: true,
        rawSummary: msg
      };
      this.handleInitFailure(fail);
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
          ArkWebViewerErrorCode.VIEWER_READY_TIMEOUT,
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

  /**
   * Phase 1D-2C-2A: 解析 initializeViewer / retryInitializeViewer 同步返回的 JSON 字符串。
   *
   * 支持的合法返回形式:
   *   {"success": true, "state": "READY"}
   *   {"success": true, "state": "INITIALIZING"}
   *   {"success": false, "error": {"code": "...", "message": "...", "phase": "...", "recoverable": false}}
   *
   * 异常返回兼容:
   *   - 空字符串 → INITIALIZE_RESULT_EMPTY
   *   - 非法 JSON → INITIALIZE_RESULT_NOT_JSON
   *   - [object Promise] → INITIALIZE_RESULT_PROMISE(Bridge 误声明为 async)
   *   - error 是字符串 / 顶层 message / 缺失字段 → 统一降级为 UNKNOWN
   *
   * 安全约束:不记录完整脚本,rawSummary 截断到 200 字符,过滤敏感路径。
   */
  private parseInitResultJson(resultJson: string): InitResultParseOutcome {
    // 1. 空字符串
    if (resultJson === null || resultJson === undefined || resultJson.length === 0) {
      return {
        kind: 'FAILED',
        code: ArkWebViewerErrorCode.INITIALIZE_RESULT_EMPTY,
        message: 'initializeViewer 返回空字符串',
        phase: 'INITIALIZING',
        recoverable: true,
        rawSummary: ''
      };
    }

    const trimmed: string = resultJson.trim();

    // 2. [object Promise](Bridge 误声明为 async)
    if (trimmed === '[object Promise]' || trimmed.indexOf('[object Promise]') >= 0) {
      return {
        kind: 'FAILED',
        code: ArkWebViewerErrorCode.INITIALIZE_RESULT_PROMISE,
        message: 'initializeViewer 返回 [object Promise](可能被声明为 async)',
        phase: 'INITIALIZING',
        recoverable: false,
        rawSummary: this.summarizeRaw(trimmed)
      };
    }

    // 3. JSON.parse
    let parsed: Record<string, Object> | null = null;
    try {
      parsed = JSON.parse(trimmed) as Record<string, Object>;
    } catch (e) {
      // 非法 JSON
      const parseErr: string = e instanceof Error ? e.message : String(e);
      return {
        kind: 'FAILED',
        code: ArkWebViewerErrorCode.INITIALIZE_RESULT_NOT_JSON,
        message: `initializeViewer 返回非法 JSON: ${parseErr}`,
        phase: 'INITIALIZING',
        recoverable: false,
        rawSummary: this.summarizeRaw(trimmed)
      };
    }

    if (parsed === null || typeof parsed !== 'object') {
      return {
        kind: 'FAILED',
        code: ArkWebViewerErrorCode.INITIALIZE_RESULT_NOT_JSON,
        message: 'initializeViewer 返回非对象 JSON',
        phase: 'INITIALIZING',
        recoverable: false,
        rawSummary: this.summarizeRaw(trimmed)
      };
    }

    // 4. 提取 success / state / error
    const successRaw: Object | undefined = parsed['success'];
    const success: boolean = successRaw === true;
    const stateRaw: Object | undefined = parsed['state'];
    const state: string = (stateRaw !== undefined && stateRaw !== null) ? String(stateRaw) : '';

    // 5. success=true 分支
    if (success) {
      if (state === 'READY') {
        return { kind: 'READY' };
      }
      // state === 'INITIALIZING' 或其他 → 视为 INITIALIZING(保守)
      return { kind: 'INITIALIZING' };
    }

    // 6. success=false 分支:提取 error 字段(支持对象 / 字符串 / 缺失)
    const errorRaw: Object | undefined = parsed['error'];
    let errCode: string = ArkWebViewerErrorCode.UNKNOWN;
    let errMsg: string = '未知错误';
    let errPhase: string = 'INITIALIZING';
    let errRecoverable: boolean = true;
    let errRawSummary: string = '';

    if (errorRaw !== null && errorRaw !== undefined) {
      if (typeof errorRaw === 'string') {
        // error 是字符串:视为 message
        errMsg = String(errorRaw);
      } else if (typeof errorRaw === 'object') {
        // error 是对象:提取 code / message / phase / recoverable / rawSummary
        // Phase 1D-2C-2B: 同时提取 rawSummary,保留 JsCaller 规范化的原始返回摘要
        const errObj: Record<string, Object> = errorRaw as Record<string, Object>;
        const codeRaw: Object | undefined = errObj['code'];
        if (codeRaw !== undefined && codeRaw !== null) {
          errCode = String(codeRaw);
        }
        const msgRaw: Object | undefined = errObj['message'];
        if (msgRaw !== undefined && msgRaw !== null) {
          errMsg = String(msgRaw);
        }
        const phaseRaw: Object | undefined = errObj['phase'];
        if (phaseRaw !== undefined && phaseRaw !== null) {
          errPhase = String(phaseRaw);
        }
        const recRaw: Object | undefined = errObj['recoverable'];
        if (recRaw !== undefined && recRaw !== null) {
          errRecoverable = recRaw === true;
        }
        // Phase 1D-2C-2B: 提取 rawSummary(JsCaller 在 BRIDGE_RESULT_NOT_JSON 时附带)
        const rawSummaryRaw: Object | undefined = errObj['rawSummary'];
        if (rawSummaryRaw !== undefined && rawSummaryRaw !== null) {
          errRawSummary = String(rawSummaryRaw);
        }

        // Phase 1D-2C-2C: 提取 bootstrap 引导层详情(JsCaller 在 APP_* 错误时附带)
        // 把 bootstrapPhase / bootstrapSource / bootstrapLine / bootstrapColumn 追加到 rawSummary,
        // 最多 500 字符,不含完整 stack。
        const bsPhaseRaw: Object | undefined = errObj['bootstrapPhase'];
        const bsSourceRaw: Object | undefined = errObj['bootstrapSource'];
        const bsLineRaw: Object | undefined = errObj['bootstrapLine'];
        const bsColumnRaw: Object | undefined = errObj['bootstrapColumn'];
        const bsStateRaw: Object | undefined = errObj['bootstrapState'];

        if (bsPhaseRaw !== undefined && bsPhaseRaw !== null) {
          const bsPhase: string = String(bsPhaseRaw);
          const bsSource: string = bsSourceRaw !== undefined && bsSourceRaw !== null ? String(bsSourceRaw) : '';
          const bsLine: number = bsLineRaw !== undefined && bsLineRaw !== null ? Number(bsLineRaw) : 0;
          const bsColumn: number = bsColumnRaw !== undefined && bsColumnRaw !== null ? Number(bsColumnRaw) : 0;

          // 构造 bootstrap 详情摘要(最多 500 字符)
          let bsDetail: string = `[bootstrap phase=${bsPhase}`;
          if (bsSource.length > 0) {
            // source 可能是完整 URL,只保留文件名部分,避免泄露完整路径
            const sourceFileName: string = bsSource.split('/').pop() || bsSource;
            bsDetail += ` source=${sourceFileName}:${bsLine}:${bsColumn}`;
          }
          bsDetail += ']';

          // 如果 errRawSummary 已有内容,追加 bootstrap 详情;否则直接使用
          if (errRawSummary.length > 0) {
            errRawSummary = errRawSummary + ' ' + bsDetail;
          } else {
            errRawSummary = bsDetail;
          }

          // 截断到 500 字符
          if (errRawSummary.length > 500) {
            errRawSummary = errRawSummary.substring(0, 500) + '...';
          }
        } else if (bsStateRaw !== undefined && bsStateRaw !== null) {
          // bootstrapPhase 缺失但有 bootstrapState,记录原始 state 字符串(截断到 200 字符)
          const bsStateStr: string = String(bsStateRaw);
          const bsStateSummary: string = bsStateStr.length > 200 ? bsStateStr.substring(0, 200) + '...' : bsStateStr;
          if (errRawSummary.length > 0) {
            errRawSummary = errRawSummary + ' [bootstrapState=' + bsStateSummary + ']';
          } else {
            errRawSummary = '[bootstrapState=' + bsStateSummary + ']';
          }
          if (errRawSummary.length > 500) {
            errRawSummary = errRawSummary.substring(0, 500) + '...';
          }
        }
      }
    } else {
      // error 缺失:尝试顶层 message
      const topMsg: Object | undefined = parsed['message'];
      if (topMsg !== undefined && topMsg !== null) {
        errMsg = String(topMsg);
      }
    }

    return {
      kind: 'FAILED',
      code: errCode,
      message: errMsg,
      phase: errPhase,
      recoverable: errRecoverable,
      // Phase 1D-2C-2B: 优先使用 JsCaller 规范化时附带的 rawSummary(error.rawSummary),
      // 仅在 JsCaller 未提供时回退到 Controller 自身解析的 trimmed 摘要
      rawSummary: errRawSummary.length > 0 ? errRawSummary : this.summarizeRaw(trimmed)
    };
  }

  /**
   * Phase 1D-2C-2A: 截断原始返回摘要(最多 200 字符),用于日志和诊断显示。
   * 不显示完整脚本或敏感路径。
   */
  private summarizeRaw(raw: string): string {
    if (raw.length <= 200) {
      return raw;
    }
    return raw.substring(0, 200) + '...';
  }

  /**
   * Phase 1D-2C-2A: 处理 initializeViewer / retryInitializeViewer 同步返回的失败结果。
   *
   * 与旧版差异:
   * - 不再使用正则匹配 error 字段(只能匹配字符串形式)
   * - 改为 JSON.parse 提取 error.code / error.message / error.phase / error.recoverable
   * - 完整保留底层错误码(不压缩为 INIT_FAILED)
   * - 保留原始返回摘要(用于诊断显示,不含完整脚本)
   */
  private handleInitFailure(parsed: InitResultParseOutcome): void {
    if (parsed.kind !== 'FAILED') {
      return;
    }
    const code: string = parsed.code !== undefined ? parsed.code : ArkWebViewerErrorCode.UNKNOWN;
    const message: string = parsed.message !== undefined ? parsed.message : '未知错误';
    const phase: string = parsed.phase !== undefined ? parsed.phase : 'INITIALIZING';
    const recoverable: boolean = parsed.recoverable !== undefined ? parsed.recoverable : true;
    const rawSummary: string = parsed.rawSummary !== undefined ? parsed.rawSummary : '';
    const displayMessage: string = rawSummary.length > 0
      ? `${message} (raw: ${rawSummary})`
      : message;
    this.onViewerError(code, displayMessage, phase, recoverable);
  }
}

/**
 * Phase 1D-2C-2A: initializeViewer / retryInitializeViewer 返回结果解析outcome。
 *
 * - kind=READY:success=true,state=READY → 直接推进到 READY
 * - kind=INITIALIZING:success=true,state=INITIALIZING → 等待 onViewerReady/onViewerError
 * - kind=FAILED:success=false 或解析失败 → 调用 onViewerError
 */
interface InitResultParseOutcome {
  /** 解析结果分类。 */
  kind: 'READY' | 'INITIALIZING' | 'FAILED';
  /** 错误码(kind=FAILED 时有效)。 */
  code?: string;
  /** 错误消息(kind=FAILED 时有效)。 */
  message?: string;
  /** 错误阶段(kind=FAILED 时有效)。 */
  phase?: string;
  /** 是否可恢复(kind=FAILED 时有效)。 */
  recoverable?: boolean;
  /** 原始返回摘要(截断到 200 字符,用于诊断显示)。 */
  rawSummary?: string;
}
