/**
 * ArkWebVrmViewerBridge — JavaScript → ArkTS 回调桥
 *
 * 本类实例通过 WebviewController.registerJavaScriptProxy 注入到 Web 端,
 * 暴露为 window.arkTavernNative,供 ViewerBridge.js 调用:
 *   - onViewerReady()
 *   - onViewerError(errorJson)
 *   - onModelStateChanged(state)
 *   - onAnimationStateChanged(state)
 *
 * 注意:
 * - ArkTS struct 不能直接作为 javaScriptProxy 对象,必须用普通 class。
 * - registerJavaScriptProxy 的 methodList 必须与类方法名完全一致。
 * - 方法参数类型必须为 ArkWeb 基础类型(string / number / boolean)。
 *
 * Reference:
 * - HarmonyOS ArkWeb: WebviewController.registerJavaScriptProxy
 * - figure-main: index.html(无对应,Figure 在浏览器环境无 ArkTS 回调)
 * - ownverse-vrm-viewer: analysis/VIEWER_ARCHITECTURE.md §Bridge Layer
 */
import {
  ArkWebAnimationState,
  ArkWebModelState,
  ArkWebViewerErrorCode,
  ArkWebViewerState,
  parseViewerError
} from './ArkWebVrmViewerTypes';

/**
 * Bridge 事件监听器接口。
 * 由 ArkWebVrmViewerController 实现,Controller 收到回调后更新状态机并通知页面。
 */
export interface ArkWebViewerBridgeListener {
  onViewerReady(): void;
  onViewerError(code: string, message: string, phase: string, recoverable: boolean): void;
  onModelStateChanged(state: ArkWebModelState): void;
  onAnimationStateChanged(state: ArkWebAnimationState): void;
}

/**
 * Native Bridge 实现。
 *
 * 实例化后通过 registerJavaScriptProxy(listener, 'arkTavernNative', methodList) 注入。
 * JavaScript 端调用 window.arkTavernNative.onViewerReady() 时,
 * 实际调用本类的 onViewerReady 方法。
 *
 * 本类只负责接收回调,不做业务逻辑;业务逻辑由 listener(Controller)处理。
 */
export class ArkWebVrmViewerNativeBridge {
  private listener: ArkWebViewerBridgeListener | null = null;
  /** 标记是否已注册到 WebviewController,避免重复注册。 */
  private registered: boolean = false;
  /** 标记是否已销毁,销毁后忽略所有回调。 */
  private disposed: boolean = false;

  /** 设置事件监听器(通常是 Controller)。 */
  setListener(listener: ArkWebViewerBridgeListener): void {
    this.listener = listener;
  }

  /** 标记已注册。 */
  markRegistered(): void {
    this.registered = true;
  }

  /** 是否已注册。 */
  isRegistered(): boolean {
    return this.registered;
  }

  /** 销毁,清空引用,后续回调被忽略。 */
  dispose(): void {
    this.disposed = true;
    this.listener = null;
  }

  // ===== 暴露给 JavaScript 的方法 =====
  // 方法签名必须为 ArkWeb 基础类型,不能使用 ArkTS 复杂类型。
  // 方法名必须与 BRIDGE_METHODS_NATIVE 白名单一致。

  /** JavaScript 端调用 window.arkTavernNative.onViewerReady() */
  onViewerReady(): void {
    if (this.disposed) {
      console.warn('[ArkWebVrmViewerBridge] onViewerReady ignored: disposed');
      return;
    }
    console.info('[ArkWebVrmViewerBridge] onViewerReady');
    const l = this.listener;
    if (l !== null) {
      l.onViewerReady();
    }
  }

  /** JavaScript 端调用 window.arkTavernNative.onViewerError(errorJson) */
  onViewerError(errorJson: string): void {
    if (this.disposed) {
      console.warn('[ArkWebVrmViewerBridge] onViewerError ignored: disposed');
      return;
    }
    console.warn('[ArkWebVrmViewerBridge] onViewerError: ' + errorJson);
    const err = parseViewerError(errorJson);
    const l = this.listener;
    if (l !== null) {
      l.onViewerError(err.code, err.message, err.phase, err.recoverable);
    }
  }

  /** JavaScript 端调用 window.arkTavernNative.onModelStateChanged(state) */
  onModelStateChanged(state: string): void {
    if (this.disposed) {
      console.warn('[ArkWebVrmViewerBridge] onModelStateChanged ignored: disposed');
      return;
    }
    console.info('[ArkWebVrmViewerBridge] onModelStateChanged: ' + state);
    const l = this.listener;
    if (l !== null) {
      l.onModelStateChanged(this.parseModelState(state));
    }
  }

  /** JavaScript 端调用 window.arkTavernNative.onAnimationStateChanged(state) */
  onAnimationStateChanged(state: string): void {
    if (this.disposed) {
      console.warn('[ArkWebVrmViewerBridge] onAnimationStateChanged ignored: disposed');
      return;
    }
    console.info('[ArkWebVrmViewerBridge] onAnimationStateChanged: ' + state);
    const l = this.listener;
    if (l !== null) {
      l.onAnimationStateChanged(this.parseAnimationState(state));
    }
  }

  private parseModelState(state: string): ArkWebModelState {
    switch (state) {
      case 'NOT_LOADED':
        return ArkWebModelState.NOT_LOADED;
      case 'LOADING':
        return ArkWebModelState.LOADING;
      case 'READY':
        return ArkWebModelState.READY;
      case 'FAILED':
        return ArkWebModelState.FAILED;
      default:
        return ArkWebModelState.NOT_LOADED;
    }
  }

  private parseAnimationState(state: string): ArkWebAnimationState {
    switch (state) {
      case 'NOT_LOADED':
        return ArkWebAnimationState.NOT_LOADED;
      case 'LOADING':
        return ArkWebAnimationState.LOADING;
      case 'PLAYING':
        return ArkWebAnimationState.PLAYING;
      case 'PAUSED':
        return ArkWebAnimationState.PAUSED;
      case 'STOPPED':
        return ArkWebAnimationState.STOPPED;
      case 'FAILED':
        return ArkWebAnimationState.FAILED;
      default:
        return ArkWebAnimationState.NOT_LOADED;
    }
  }
}

/**
 * ArkTS → JavaScript 调用封装。
 *
 * 通过 WebviewController.runJavaScript 调用 window.arkTavernViewerBridge 上的方法。
 * 返回值为 Promise<string>,通常是 JSON 格式。
 *
 * 注意:runJavaScript 是异步的,需要在 WebviewController 关联的 Web 组件加载完成后调用。
 */
export class ArkWebViewerJsCaller {
  private runJs: ((script: string) => Promise<string>) | null = null;

  /** 注入 runJavaScript 实现(由 Controller 在 onPageEnd 时设置)。 */
  bind(runJs: (script: string) => Promise<string>): void {
    this.runJs = runJs;
  }

  /** 解绑。 */
  unbind(): void {
    this.runJs = null;
  }

  /** 调用 window.arkTavernViewerBridge.initializeViewer() */
  async initializeViewer(): Promise<string> {
    return this.call('initializeViewer');
  }

  /** 调用 window.arkTavernViewerBridge.disposeViewer() */
  async disposeViewer(): Promise<string> {
    return this.call('disposeViewer');
  }

  /** 调用 window.arkTavernViewerBridge.getViewerState() */
  async getViewerState(): Promise<string> {
    return this.call('getViewerState');
  }

  /** 调用 window.arkTavernViewerBridge.resetCamera() */
  async resetCamera(): Promise<string> {
    return this.call('resetCamera');
  }

  /** 调用 window.arkTavernViewerBridge.resizeViewer(width, height) */
  async resizeViewer(width: number, height: number): Promise<string> {
    return this.callWithArgs('resizeViewer', [width, height]);
  }

  /** 调用 window.arkTavernViewerBridge.getSceneState() */
  async getSceneState(): Promise<string> {
    return this.call('getSceneState');
  }

  // ===== Phase 1D-2A: 缓存模型资源协议骨架(不触发加载) =====

  /**
   * 调用 window.arkTavernViewerBridge.prepareModelResource(resourceJson)
   *
   * 将 ArkTS 端构造的资源元数据 JSON 字符串传给 Web 端 keeper。
   * keeper 会做字段白名单过滤,只保存 resourceUrl / displayName / mimeType / size / extension。
   * 严格不触发任何模型加载行为。
   *
   * @param resourceJson 资源元数据 JSON 字符串
   * @returns Web 端 keeper 返回的 JSON 字符串
   */
  async prepareModelResource(resourceJson: string): Promise<string> {
    return this.callWithStringArg('prepareModelResource', resourceJson);
  }

  /**
   * 调用 window.arkTavernViewerBridge.getPreparedModelResource()
   *
   * @returns JSON 字符串,形如 {"success": true, "resource": <object|null>}
   */
  async getPreparedModelResource(): Promise<string> {
    return this.call('getPreparedModelResource');
  }

  /**
   * 调用 window.arkTavernViewerBridge.clearPreparedModelResource()
   *
   * @returns JSON 字符串,形如 {"success": true, "state": "RESOURCE_CLEARED"}
   */
  async clearPreparedModelResource(): Promise<string> {
    return this.call('clearPreparedModelResource');
  }

  // ===== Phase 1D-2B-1: 资源探测(HEAD 请求校验,不读取模型文件) =====

  /**
   * 调用 window.arkTavernViewerBridge.probePreparedModelResource()
   *
   * 触发 JavaScript 端 ViewerModelResourceProbe.probe(),通过 HEAD 请求校验
   * 受控资源 URL 是否能正常访问,以及响应头(Content-Type / Content-Length /
   * X-ArkTavern-Resource-Id)是否符合预期。
   *
   * 严格不调用:
   * - GLTFLoader.load()
   * - ViewerModelLoader.loadModel()
   * - response.arrayBuffer() / response.blob() / response.body.getReader()
   *
   * 注意:JavaScript 端方法返回 Promise<string>,runJavaScript 会等待 Promise
   * 完成,返回 resolved value 字符串。
   *
   * @returns JSON 字符串,形如:
   *   成功:{"success": true, "result": <ModelResourceProbeResult>}
   *   失败:{"success": false, "error": {"code": "...", "message": "..."}}
   */
  async probePreparedModelResource(): Promise<string> {
    return this.call('probePreparedModelResource');
  }

  /**
   * 调用 window.arkTavernViewerBridge.getModelResourceProbeResult()
   *
   * 同步获取最近一次探测结果(不触发新的探测)。
   *
   * @returns JSON 字符串,形如:
   *   {"success": true, "result": <ModelResourceProbeResult|null>}
   */
  async getModelResourceProbeResult(): Promise<string> {
    return this.call('getModelResourceProbeResult');
  }

  /**
   * 调用 window.arkTavernViewerBridge.clearModelResourceProbe()
   *
   * 清除 JavaScript 端探测器状态(state 重置为 NOT_PROBED,lastResult 清空)。
   * 资源被替换 / 清除时由 keeper 方法自动调用,通常不需要页面直接调用。
   *
   * @returns JSON 字符串,形如 {"success": true, "state": "PROBE_CLEARED"}
   */
  async clearModelResourceProbe(): Promise<string> {
    return this.call('clearModelResourceProbe');
  }

  // ===== Phase 1D-2B-2: 用户模型加载(GLTFLoader 实际加载与原子替换) =====

  /**
   * 调用 window.arkTavernViewerBridge.loadPreparedModelResource()
   *
   * 启动用户模型加载。从 PreparedModelResourceKeeper 读取已准备的资源,
   * 结合探测结果,调用 ViewerUserModelLoadCoordinator.start() 同步启动异步加载。
   * 立即返回 LOADING 状态,最终结果通过 getPreparedModelLoadResult() 轮询获取。
   *
   * 严格不:
   * - 不接受 URL 参数(只从 keeper + probe 读取)
   * - 不直接调用 GLTFLoader.load()(由 ViewerCore.loadUserModelResource 委托)
   * - 不直接调用 fetch / arrayBuffer / blob
   *
   * 异步策略(AGENTS.md Phase 1D-2B-2 §十):
   * ArkWeb 的 runJavaScript 不应依赖 JavaScript Promise 返回值,因此:
   * 1. 本方法同步启动加载,立即返回 {"success": true, "state": "LOADING"}
   * 2. 加载异步进行,结果保存在 coordinator.lastResult 中
   * 3. ArkTS 端通过 getPreparedModelLoadResult() 轮询获取最终结果
   *
   * @returns JSON 字符串
   *   启动成功:{"success": true, "state": "LOADING", "message": "..."}
   *   启动失败:{"success": false, "error": {"code": "...", "message": "..."}}
   */
  async loadPreparedModelResource(): Promise<string> {
    return this.call('loadPreparedModelResource');
  }

  /**
   * 调用 window.arkTavernViewerBridge.getPreparedModelLoadResult()
   *
   * 同步获取最近一次用户模型加载结果(不触发新的加载)。
   *
   * @returns JSON 字符串,形如:
   *   {"success": true, "result": <UserModelLoadResult|null>}
   *   result.state 为 NOT_REQUESTED / LOADING / READY / FAILED / DISPOSED
   *   result 不含 cachePath / sourceUri / 文件描述符
   */
  async getPreparedModelLoadResult(): Promise<string> {
    return this.call('getPreparedModelLoadResult');
  }

  /**
   * 调用 window.arkTavernViewerBridge.clearPreparedModelLoadResult()
   *
   * 清除 JavaScript 端加载协调器状态(state 重置为 NOT_REQUESTED,lastResult 清空)。
   * 不影响已加载到 Viewer 的模型。
   *
   * @returns JSON 字符串,形如 {"success": true, "state": "LOAD_RESULT_CLEARED"}
   */
  async clearPreparedModelLoadResult(): Promise<string> {
    return this.call('clearPreparedModelLoadResult');
  }

  private async call(methodName: string): Promise<string> {
    const fn = this.runJs;
    if (fn === null) {
      throw new Error(`JsCaller not bound: cannot call ${methodName}`);
    }
    const script = `try { window.arkTavernViewerBridge && window.arkTavernViewerBridge.${methodName} && window.arkTavernViewerBridge.${methodName}(); } catch (e) { JSON.stringify({ success: false, error: (e && e.message) ? e.message : String(e) }); }`;
    return fn(script);
  }

  private async callWithArgs(methodName: string, args: number[]): Promise<string> {
    const fn = this.runJs;
    if (fn === null) {
      throw new Error(`JsCaller not bound: cannot call ${methodName}`);
    }
    const argsStr: string = args.map((n: number) => String(n)).join(', ');
    const script = `try { window.arkTavernViewerBridge && window.arkTavernViewerBridge.${methodName} && window.arkTavernViewerBridge.${methodName}(${argsStr}); } catch (e) { JSON.stringify({ success: false, error: (e && e.message) ? e.message : String(e) }); }`;
    return fn(script);
  }

  /**
   * 调用需要单个 string 参数的 Bridge 方法(Phase 1D-2A 新增)。
   *
   * 使用 JSON.stringify(arg) 把字符串转为 JS 字符串字面量,安全转义引号/反斜杠/换行,
   * 防止注入与转义问题。
   */
  private async callWithStringArg(methodName: string, strArg: string): Promise<string> {
    const fn = this.runJs;
    if (fn === null) {
      throw new Error(`JsCaller not bound: cannot call ${methodName}`);
    }
    // JSON.stringify 输出形如 "..."(含双引号),可直接作为 JS 字符串字面量
    const argLiteral: string = JSON.stringify(strArg);
    const script = `try { window.arkTavernViewerBridge && window.arkTavernViewerBridge.${methodName} && window.arkTavernViewerBridge.${methodName}(${argLiteral}); } catch (e) { JSON.stringify({ success: false, error: (e && e.message) ? e.message : String(e) }); }`;
    return fn(script);
  }
}

/**
 * 错误代码到ArkWebViewerErrorCode 的转换(供 Controller 使用)。
 */
export function toErrorCode(code: string): ArkWebViewerErrorCode {
  switch (code) {
    case 'INIT_FAILED':
      return ArkWebViewerErrorCode.INIT_FAILED;
    case 'DISPOSE_FAILED':
      return ArkWebViewerErrorCode.DISPOSE_FAILED;
    case 'MODEL_LOAD_FAILED':
      return ArkWebViewerErrorCode.MODEL_LOAD_FAILED;
    case 'ANIMATION_LOAD_FAILED':
      return ArkWebViewerErrorCode.ANIMATION_LOAD_FAILED;
    case 'WEBGL_UNAVAILABLE':
      return ArkWebViewerErrorCode.WEBGL_UNAVAILABLE;
    case 'INVALID_VRM':
      return ArkWebViewerErrorCode.INVALID_VRM;
    case 'FILE_UNREADABLE':
      return ArkWebViewerErrorCode.FILE_UNREADABLE;
    case 'INVALID_URI':
      return ArkWebViewerErrorCode.INVALID_URI;
    case 'PAGE_DISPOSED':
      return ArkWebViewerErrorCode.PAGE_DISPOSED;
    default:
      return ArkWebViewerErrorCode.UNKNOWN;
  }
}

/** 状态标签(供调试 Tab 显示)。 */
export function arkWebViewerStateLabel(state: ArkWebViewerState): string {
  return state;
}

/** 模型状态标签。 */
export function arkWebModelStateLabel(state: ArkWebModelState): string {
  return state;
}
