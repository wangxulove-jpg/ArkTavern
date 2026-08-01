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
      case 'UNINITIALIZED':
        return ArkWebAnimationState.UNINITIALIZED;
      case 'IDLE':
        return ArkWebAnimationState.IDLE;
      case 'LOADING':
        return ArkWebAnimationState.LOADING;
      case 'READY':
        return ArkWebAnimationState.READY;
      case 'PLAYING':
        return ArkWebAnimationState.PLAYING;
      case 'PAUSED':
        return ArkWebAnimationState.PAUSED;
      case 'STOPPED':
        return ArkWebAnimationState.STOPPED;
      case 'FAILED':
        return ArkWebAnimationState.FAILED;
      case 'DISPOSED':
        return ArkWebAnimationState.DISPOSED;
      default:
        return ArkWebAnimationState.UNINITIALIZED;
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

/**
 * Phase 1D-2C-2B: Bridge 错误详情接口。
 * 用于 normalizeRunJavaScriptResult 中返回受控错误 JSON 的类型化对象字面量。
 */
interface BridgeErrorDetail {
  code: string;
  message: string;
  phase: string;
  recoverable: boolean;
  rawSummary?: string;
}

/**
 * Phase 1D-2C-2B: Bridge 错误结果接口。
 * 用于 normalizeRunJavaScriptResult 中返回受控错误 JSON 的类型化对象字面量。
 */
interface BridgeErrorResult {
  success: boolean;
  error: BridgeErrorDetail;
}

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

  /**
   * Phase 1D-2C-2A: 调用 window.arkTavernViewerBridge.retryInitializeViewer()
   *
   * 仅在 Viewer 处于 FAILED 状态时由 Controller 调用。Web 端方法同步返回 JSON 字符串:
   *   成功启动重试:{"success": true, "state": "INITIALIZING"}
   *   当前非 FAILED:{"success": false, "error": {"code": "RETRY_NOT_ALLOWED", ...}}
   *
   * 重试结果通过 onViewerReady / onViewerError 回调推进 Controller 状态机。
   */
  async retryInitializeViewer(): Promise<string> {
    return this.call('retryInitializeViewer');
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

  /**
   * Phase 2A-2: 调用 window.arkTavernViewerBridge.focusCameraOnCurrentModel()
   *
   * 聚焦到当前已加载模型,计算包围盒并调整相机位置和目标。
   */
  async focusCameraOnCurrentModel(): Promise<string> {
    return this.call('focusCameraOnCurrentModel');
  }

  // ===== Phase 4B-1: Runtime 渲染 Profile =====

  /**
   * Phase 4B-1: 调用 window.arkTavernViewerBridge.setRenderProfile(profile)
   *
   * 设置渲染 Profile (VIEWER / CHAT_STAGE)。
   * CHAT_STAGE: renderer alpha=true, clearAlpha=0, scene.background=null,
   *             Grid 隐藏, Canvas 透明, 相机控制禁用。
   * VIEWER: 恢复深色实体背景与相机控制。
   *
   * @param profile 'VIEWER' | 'CHAT_STAGE'
   * @returns JSON 字符串,形如 {"success": true, "state": "READY", "profile": "CHAT_STAGE"}
   */
  async setRenderProfile(profile: string): Promise<string> {
    return this.callWithStringArg('setRenderProfile', profile);
  }

  /**
   * Phase 4B-1: 调用 window.arkTavernViewerBridge.getRenderProfile()
   *
   * 获取当前渲染 Profile。
   *
   * @returns JSON 字符串,形如 {"success": true, "state": "READY", "profile": "VIEWER"}
   */
  async getRenderProfile(): Promise<string> {
    return this.call('getRenderProfile');
  }

  /**
   * Phase 4B-1 / 4B-2R: 调用 window.arkTavernViewerBridge.fitAvatarFullBody(paramsJson)
   *
   * 聊天页面默认全身构图。基于模型 BoundingBox / BoundingSphere / FOV / 视口,
   * 调整相机 position / target / distance,使模型全身可见。
   * 不修改 VRM scene scale 或 position。
   *
   * Phase 4B-2R: 支持可选 fillRatio 参数 (0 < fillRatio < 1) 控制模型垂直占比。
   *   - paramsJson 为空字符串 → 默认 margin=1.15 (向后兼容)
   *   - paramsJson = '{"fillRatio":0.78}' → margin=1/0.78 ≈ 1.282 (模型占垂直约 78%)
   *
   * @param paramsJson 可选 JSON 字符串,形如 {"fillRatio": 0.78};空字符串表示使用默认参数
   * @returns JSON 字符串,形如
   *   {"success": true, "state": "READY", "cameraState": {...}, "bounds": {...}}
   */
  async fitAvatarFullBody(paramsJson: string): Promise<string> {
    if (paramsJson.length > 0) {
      return this.callWithStringArg('fitAvatarFullBody', paramsJson);
    }
    return this.call('fitAvatarFullBody');
  }

  /**
   * Phase 4B-2R2: 调用 window.arkTavernViewerBridge.applyCameraZoomMultiplier(paramsJson)
   *
   * 通过调整相机到目标点的距离实现视觉缩放,不修改模型 transform。
   * 倍率范围 0.5~3.0,1.0 为默认。
   *   - multiplier > 1: 相机靠近目标,模型视觉放大
   *   - multiplier < 1: 相机远离目标,模型视觉缩小
   *
   * @param paramsJson JSON 字符串,形如 '{"multiplier":1.5}'
   * @returns JSON 字符串,形如
   *   {"success": true, "state": "READY", "cameraState": {...}, "multiplier": 1.5}
   */
  async applyCameraZoomMultiplier(paramsJson: string): Promise<string> {
    return this.callWithStringArg('applyCameraZoomMultiplier', paramsJson);
  }

  /**
   * Phase 2A-2: 调用 window.arkTavernViewerBridge.getCameraState()
   *
   * 获取当前 Camera 状态(供 Debug Tab 显示)。
   */
  async getCameraState(): Promise<string> {
    return this.call('getCameraState');
  }

  // ===== Phase 2B: 平滑重置 =====

  /**
   * Phase 2B: 调用 window.arkTavernViewerBridge.smoothResetCamera(options)
   *
   * 同步启动平滑重置过渡。最终状态通过 getCameraTransitionState() 轮询获取。
   *
   * @param optionsJson 选项 JSON 字符串,形如 '{"durationSeconds":0.45,"preserveControlsEnabled":true}'
   *   - durationSeconds: 过渡时长(0.1~2.0 秒),默认 0.45
   *   - preserveControlsEnabled: 是否保持 controls.enabled,默认 true
   * @returns JSON 字符串
   *   启动成功: {"success": true, "state": "READY", "transitionState": "RUNNING", "transition": {...}}
   *   启动失败: {"success": false, "error": {...}, "transitionState": "..."}
   */
  async smoothResetCamera(optionsJson: string): Promise<string> {
    return this.callWithStringArg('smoothResetCamera', optionsJson);
  }

  /**
   * Phase 2B: 调用 window.arkTavernViewerBridge.getCameraTransitionState()
   *
   * 获取当前相机过渡状态,用于轮询平滑重置进度。
   *
   * @returns JSON 字符串
   *   {"success": true, "state": "READY", "transition": {...}}
   *   transition.state: IDLE/RUNNING/COMPLETED/CANCELLED/FAILED/DISPOSED
   */
  async getCameraTransitionState(): Promise<string> {
    return this.call('getCameraTransitionState');
  }

  /**
   * Phase 2B: 调用 window.arkTavernViewerBridge.cancelCameraTransition(reason)
   *
   * 取消正在运行的平滑相机过渡,保留取消瞬间的相机位置。
   *
   * @param reason 取消原因字符串
   * @returns JSON 字符串
   *   {"success": true, "state": "READY", "transition": {...}}
   */
  async cancelCameraTransition(reason: string): Promise<string> {
    return this.callWithStringArg('cancelCameraTransition', reason);
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

  // ===== Phase 1D-2C-1: 运行时诊断 =====

  /**
   * 调用 window.arkTavernViewerBridge.getVrmRuntimeDiagnostic()
   *
   * 同步获取 Web 端最近一条运行时诊断记录。
   * 诊断记录由 Provider / Coordinator / GLTFLoader 通过 onDiagnostic 回调上报,
   * 收集在 Web 端诊断中心,只保留最近一条。
   *
   * 返回的 JSON 字符串结构:
   *   {"success": true, "diagnostic": <VrmRuntimeDiagnostic|null>}
   *   diagnostic 字段:
   *     - stage: 阶段字符串(见 VrmRuntimeStage)
   *     - code: 错误码(底层原始错误码)
   *     - message: 错误消息(已截断,不含完整堆栈)
   *     - resourceId: opaque resource id(不含 cachePath)
   *     - requestMethod: HEAD / GET
   *     - httpStatus: HTTP 状态码
   *     - mimeType: 响应 Content-Type
   *     - contentLength: 响应 Content-Length
   *     - timestamp: 发生时间戳(ms)
   *
   * 安全约束:
   * - diagnostic 不含 cachePath / sourceUri / fd / stack / 用户目录
   * - 由 Web 端诊断中心做字段白名单过滤
   *
   * @returns JSON 字符串
   */
  async getVrmRuntimeDiagnostic(): Promise<string> {
    return this.call('getVrmRuntimeDiagnostic');
  }

  /**
   * 调用 window.arkTavernViewerBridge.clearVrmRuntimeDiagnostic()
   *
   * 清除 Web 端诊断中心最近一条诊断记录。
   * 不影响 Provider / Coordinator / GLTFLoader 的运行状态。
   *
   * @returns JSON 字符串,形如 {"success": true, "state": "DIAGNOSTIC_CLEARED"}
   */
  async clearVrmRuntimeDiagnostic(): Promise<string> {
    return this.call('clearVrmRuntimeDiagnostic');
  }

  // ===== Phase 2A-1: Camera Controls enable/disable =====

  /**
   * 调用 window.arkTavernViewerBridge.setCameraControlsEnabled(enabled)
   *
   * 用于控制面板触摸隔离:控制面板发生触摸时禁用 OrbitControls,
   * 触摸结束或取消时恢复 OrbitControls。
   *
   * Bridge 参数必须是布尔值,禁止字符串 "true" / 数字 1 / 任意对象。
   *
   * @param enabled true=启用;false=禁用
   * @returns JSON 字符串,形如 {"success": true, "enabled": true|false}
   */
  async setCameraControlsEnabled(enabled: boolean): Promise<string> {
    return this.callWithBooleanArg('setCameraControlsEnabled', enabled);
  }

  /**
   * 调用 window.arkTavernViewerBridge.getCameraControlsEnabled()
   *
   * @returns JSON 字符串,形如 {"success": true, "enabled": true|false}
   */
  async getCameraControlsEnabled(): Promise<string> {
    return this.call('getCameraControlsEnabled');
  }

  // ===== Phase 2A-1: Scene 设置(背景 / 网格 / 灯光) =====

  /**
   * 调用 window.arkTavernViewerBridge.setSceneBackgroundColor(color)
   *
   * 设置场景背景颜色。只允许 #RRGGBB 格式(6 位十六进制)。
   *
   * @param color #RRGGBB 格式
   * @returns JSON 字符串,形如 {"success": true, "color": "#RRGGBB"}
   */
  async setSceneBackgroundColor(color: string): Promise<string> {
    return this.callWithStringArg('setSceneBackgroundColor', color);
  }

  /**
   * 调用 window.arkTavernViewerBridge.setSceneGridVisible(visible)
   *
   * 设置网格显示。GridHelper 只创建一次,切换只修改 visible。
   *
   * @param visible true=显示网格;false=隐藏网格
   * @returns JSON 字符串,形如 {"success": true, "visible": true|false}
   */
  async setSceneGridVisible(visible: boolean): Promise<string> {
    return this.callWithBooleanArg('setSceneGridVisible', visible);
  }

  /**
   * 调用 window.arkTavernViewerBridge.setSceneLightIntensity(intensity)
   *
   * 设置主方向光强度。合法范围 0.0 ~ 4.0。
   * ArkUI 百分比映射:intensity = percentage / 25.0
   *
   * @param intensity 0.0 ~ 4.0
   * @returns JSON 字符串,形如 {"success": true, "intensity": <number>}
   */
  async setSceneLightIntensity(intensity: number): Promise<string> {
    return this.callWithNumberArg('setSceneLightIntensity', intensity);
  }

  /**
   * 调用 window.arkTavernViewerBridge.getSceneSettings()
   *
   * 获取场景设置快照(背景颜色 / 网格 / 灯光)。
   *
   * @returns JSON 字符串,形如
   *   {"success": true, "settings": {"backgroundColor": "...", "gridVisible": ..., "lightIntensity": ...}}
   */
  async getSceneSettings(): Promise<string> {
    return this.call('getSceneSettings');
  }

  // ===== Phase 2F: 环境贴图与天空盒 =====

  /**
   * Phase 2F: 调用 window.arkTavernViewerBridge.initializeEnvironment()
   *
   * 初始化环境贴图(程序化 RoomEnvironment + PMREMGenerator)。
   * 同步执行,由 ViewerScene.initializeEnvironment 完成。
   *
   * 初始化失败:
   *   - 保留现有纯色背景和灯光
   *   - 不影响 ViewerState(仍为 READY)
   *
   * @returns JSON 字符串
   *   成功:{"success": true, "state": "READY", "environmentState": "READY", "settings": {...}}
   *   失败:{"success": false, "error": {...}, "settings": {...}}
   */
  async initializeEnvironment(): Promise<string> {
    return this.call('initializeEnvironment');
  }

  /**
   * Phase 2F: 调用 window.arkTavernViewerBridge.setEnvironmentEnabled(enabled)
   *
   * 启用/禁用环境光照。
   * 启用:scene.environment = environmentTexture
   * 禁用:scene.environment = null,自动关闭天空盒(如开启)
   *
   * @param enabled true=启用;false=禁用
   * @returns JSON 字符串
   *   成功:{"success": true, "enabled": true|false, "settings": {...}}
   *   失败:{"success": false, "error": {...}}
   */
  async setEnvironmentEnabled(enabled: boolean): Promise<string> {
    return this.callWithBooleanArg('setEnvironmentEnabled', enabled);
  }

  /**
   * Phase 2F: 调用 window.arkTavernViewerBridge.setSkyboxVisible(visible)
   *
   * 显示/隐藏天空盒。
   * 显示:scene.background = environmentTexture(保存当前纯色背景)
   * 隐藏:scene.background = 保存的纯色背景
   *
   * 前置条件:environmentState === READY && environmentEnabled === true
   *
   * @param visible true=显示天空盒;false=隐藏天空盒
   * @returns JSON 字符串
   *   成功:{"success": true, "visible": true|false, "settings": {...}}
   *   失败:{"success": false, "error": {...}}
   */
  async setSkyboxVisible(visible: boolean): Promise<string> {
    return this.callWithBooleanArg('setSkyboxVisible', visible);
  }

  /**
   * Phase 2F: 调用 window.arkTavernViewerBridge.setEnvironmentIntensity(intensity)
   *
   * 设置环境强度(使用 scene.environmentIntensity)。
   * 合法范围 0.0 ~ 2.0。
   * ArkUI 百分比映射:intensity = percentage / 100.0
   *
   * @param intensity 0.0 ~ 2.0
   * @returns JSON 字符串
   *   成功:{"success": true, "intensity": <number>, "settings": {...}}
   *   失败:{"success": false, "error": {...}}
   */
  async setEnvironmentIntensity(intensity: number): Promise<string> {
    return this.callWithNumberArg('setEnvironmentIntensity', intensity);
  }

  /**
   * Phase 2F: 调用 window.arkTavernViewerBridge.getEnvironmentSettings()
   *
   * 获取环境设置快照。
   *
   * @returns JSON 字符串,形如
   *   {"success": true, "settings": {"state": "...", "source": "...", ...}}
   */
  async getEnvironmentSettings(): Promise<string> {
    return this.call('getEnvironmentSettings');
  }

  // ===== Phase 3A: Animation System (只读查询) =====

  /**
   * Phase 3A: 调用 window.arkTavernViewerBridge.getAnimationState()
   *
   * 获取动画系统当前状态(只读)。
   * 不触发动画加载/播放,仅查询 AnimationController.getState()。
   *
   * @returns JSON 字符串,形如
   *   {"success": true, "state": "IDLE"}
   *   state 枚举:UNINITIALIZED / IDLE / LOADING / READY / PLAYING / PAUSED / STOPPED / FAILED / DISPOSED
   */
  async getAnimationState(): Promise<string> {
    return this.call('getAnimationState');
  }

  /**
   * Phase 3A: 调用 window.arkTavernViewerBridge.getAnimationDebugState()
   *
   * 获取动画系统调试状态快照(只读)。
   * 包含 state / vrmBound / mixerReady / clipReady / actionReady / animationName /
   * duration / currentTime / playbackSpeed / loop / errorCode / errorMessage。
   *
   * @returns JSON 字符串,形如
   *   {"success": true, "debugState": {"state": "...", "vrmBound": ..., ...}}
   */
  async getAnimationDebugState(): Promise<string> {
    return this.call('getAnimationDebugState');
  }

  /**
   * Phase 3A 依赖补齐: 调用 window.arkTavernViewerBridge.getAnimationDependencyState()
   *
   * 获取动画系统依赖状态(只读),包含 three-vrm-animation 依赖可用性。
   * 不暴露 Node 模块路径、本机绝对路径、完整 package.json、许可证全文。
   *
   * @returns JSON 字符串,形如
   *   {"success": true, "dependencyState": {"available": true, "packageName": "...", "version": "3.5.5", "loaderAvailable": true, "clipFactoryAvailable": true, "runtimeNetworkRequired": false}}
   */
  async getAnimationDependencyState(): Promise<string> {
    return this.call('getAnimationDependencyState');
  }

  /**
   * Phase 3A — VRMA 文件导入与最小播放闭环: 调用 window.arkTavernViewerBridge.loadAnimationResource(resourceJson)
   *
   * 同步返回加载启动结果(不返回 Promise):
   *   {"success": true, "state": "LOADING", "generation": <number>}
   *   {"success": false, "error": {"code": "...", "message": "..."}}
   *
   * 异步结果通过 getAnimationState() / getAnimationDebugState() 查询。
   *
   * @param resourceJson ArkTS 传入的 JSON 字符串
   *   必需字段:resourceUrl / resourceId / displayName / mimeType / size
   *   禁止字段:cachePath / sourceUri (ArkTS 已剥离)
   * @returns JSON 字符串
   */
  async loadAnimationResource(resourceJson: string): Promise<string> {
    return this.callWithStringArg('loadAnimationResource', resourceJson);
  }

  /**
   * Phase 3A — VRMA 文件导入与最小播放闭环: 调用 window.arkTavernViewerBridge.playAnimation()
   *
   * @returns JSON 字符串
   *   {"success": true, "state": "PLAYING"}
   *   {"success": false, "error": {"code": "...", "message": "..."}}
   */
  async playAnimation(): Promise<string> {
    return this.call('playAnimation');
  }

  /**
   * Phase 3A — VRMA 文件导入与最小播放闭环: 调用 window.arkTavernViewerBridge.pauseAnimation()
   *
   * @returns JSON 字符串
   *   {"success": true, "state": "PAUSED"}
   *   {"success": false, "error": {"code": "...", "message": "..."}}
   */
  async pauseAnimation(): Promise<string> {
    return this.call('pauseAnimation');
  }

  /**
   * Phase 3A — VRMA 文件导入与最小播放闭环: 调用 window.arkTavernViewerBridge.stopAnimation(optionsJson)
   *
   * @param optionsJson 可选 JSON 字符串 {resetPose?: boolean},默认 resetPose=true
   * @returns JSON 字符串
   *   {"success": true, "state": "STOPPED"}
   *   {"success": false, "error": {"code": "...", "message": "..."}}
   */
  async stopAnimation(optionsJson: string): Promise<string> {
    return this.callWithStringArg('stopAnimation', optionsJson);
  }

  /**
   * 调用 window.arkTavernViewerBridge.setAnimationLoop(enabledJson)
   *
   * 设置动画循环播放开关, 立即应用到当前 AnimationAction。
   *
   * @param enabledJson JSON 字符串 {"enabled": true|false}
   * @returns JSON 字符串
   *   {"success": true, "loop": true|false}
   *   {"success": false, "error": {"code": "...", "message": "..."}}
   */
  async setAnimationLoop(enabledJson: string): Promise<string> {
    return this.callWithStringArg('setAnimationLoop', enabledJson);
  }

  // ===== Phase 3D-2 — JSON 姿势解析、应用与恢复 =====

  /**
   * Phase 3D-2: 调用 window.arkTavernViewerBridge.applyPose(poseJson)
   *
   * 将 ArkTS 从持久 JSON 文件读取并构造的受控姿势数据传给 Web 端,
   * 应用到当前 VRM Humanoid 的 normalized bones。
   *
   * Web 端会:
   *   1. 字段白名单校验(禁止 absolutePath / relativePath / filesDir 等)
   *   2. 应用前 stopAnimation
   *   3. resetNormalizedPose
   *   4. 遍历有效骨骼,设置 quaternion + normalize + updateMatrix
   *   5. 记录 currentPoseId, state=APPLIED
   *
   * @param poseJson 受控姿势数据 JSON 字符串
   *   { poseId, displayName, bones | humanBones | pose }
   * @returns JSON 字符串
   *   成功:{"success": true, "state": "APPLIED", "poseId": "...", "displayName": "...", "appliedBoneCount": N, "ignoredBoneCount": M}
   *   失败:{"success": false, "error": {"code": "POSE_*", "message": "..."}}
   */
  async applyPose(poseJson: string): Promise<string> {
    return this.callWithStringArg('applyPose', poseJson);
  }

  /**
   * Phase 3D-2: 调用 window.arkTavernViewerBridge.resetPose()
   *
   * 恢复 VRM Humanoid 到 normalized rest pose,清空 currentPoseId。
   * 恢复失败不影响 ViewerState / ModelState / AnimationState。
   *
   * @returns JSON 字符串
   *   {"success": true, "state": "IDLE"}
   *   {"success": false, "error": {"code": "POSE_*", "message": "..."}}
   */
  async resetPose(): Promise<string> {
    return this.call('resetPose');
  }

  /**
   * Phase 3D-2: 调用 window.arkTavernViewerBridge.getPoseState()
   *
   * 获取姿势系统只读状态快照。
   *
   * @returns JSON 字符串
   *   {"success": true, "state": "IDLE|APPLIED|FAILED|DISPOSED", "poseId": "...", "displayName": "...", "appliedBoneCount": N, "ignoredBoneCount": M}
   */
  async getPoseState(): Promise<string> {
    return this.call('getPoseState');
  }

  /**
   * Phase 3D-2: 调用 window.arkTavernViewerBridge.getPoseDebugState()
   *
   * 获取姿势系统调试状态快照(包含 lastIgnoredBones / lastErrorCode / lastErrorMessage)。
   *
   * @returns JSON 字符串
   *   {"success": true, "debugState": {state, vrmBound, currentPoseId, currentDisplayName, appliedBoneCount, ignoredBoneCount, lastIgnoredBones, lastErrorCode, lastErrorMessage}}
   */
  async getPoseDebugState(): Promise<string> {
    return this.call('getPoseDebugState');
  }

  // ===== Phase 3E-1 — VRM 表情系统 =====

  /**
   * Phase 3E-1: 调用 window.arkTavernViewerBridge.getAvailableExpressions()
   *
   * 获取当前 VRM 真实可用 Expression 列表。
   * 模型 READY 后只读取列表,不自动设置任何表情。
   * 不得假定所有模型都支持 happy/angry/sad/relaxed/surprised/neutral。
   *
   * @returns JSON 字符串
   *   成功: {"success": true, "expressions": [{"name":"happy","weight":0,"isPreset":true}, ...]}
   *   失败: {"success": false, "error": {"code": "EXPRESSION_VRM_MISSING|...", "message": "..."}}
   */
  async getAvailableExpressions(): Promise<string> {
    return this.call('getAvailableExpressions');
  }

  /**
   * Phase 3E-1: 调用 window.arkTavernViewerBridge.setExpression(paramsJson)
   *
   * 设置单个业务表情权重。参数为 JSON 字符串,避免向 JavaScript 传文件路径或模型内部对象:
   *   {"name": "happy", "weight": 1}
   *
   * 表情错误不得改变 ViewerState / ModelState / AnimationState / PoseState。
   *
   * @param paramsJson JSON 字符串 {name: string, weight: number}
   * @returns JSON 字符串
   *   成功: {"success": true, "state": "APPLIED", "name": "happy", "weight": 1}
   *   失败: {"success": false, "error": {"code": "EXPRESSION_*", "message": "..."}}
   */
  async setExpression(paramsJson: string): Promise<string> {
    return this.callWithStringArg('setExpression', paramsJson);
  }

  /**
   * Phase 3E-1: 调用 window.arkTavernViewerBridge.resetExpression()
   *
   * 清除业务表情,恢复 neutral。不强制把 neutral 设置为 1。
   * 保留口型通道 aa/ee/ih/oh/ou (LIP_SYNC_CHANNELS_PRESERVED: YES)。
   *
   * @returns JSON 字符串
   *   成功: {"success": true, "state": "READY"}
   *   失败: {"success": false, "error": {"code": "EXPRESSION_*", "message": "..."}}
   */
  async resetExpression(): Promise<string> {
    return this.call('resetExpression');
  }

  /**
   * Phase 3E-1: 调用 window.arkTavernViewerBridge.getExpressionState()
   *
   * 获取表情系统状态(只读)。
   *
   * @returns JSON 字符串
   *   {"success": true, "state": "UNBOUND|READY|APPLIED|FAILED|DISPOSED",
   *    "currentExpressionName": "...", "currentExpressionWeight": N, "expressionManagerReady": bool}
   */
  async getExpressionState(): Promise<string> {
    return this.call('getExpressionState');
  }

  /**
   * Phase 3E-1: 调用 window.arkTavernViewerBridge.getExpressionDebugState()
   *
   * 获取表情系统调试状态快照(只读)。
   *
   * @returns JSON 字符串
   *   {"success": true, "debugState": {state, vrmBound, expressionManagerReady,
   *    availableExpressionCount, currentExpressionName, currentExpressionWeight,
   *    lastErrorCode, lastErrorMessage, lipSyncChannelsPreserved}}
   */
  async getExpressionDebugState(): Promise<string> {
    return this.call('getExpressionDebugState');
  }

  /**
   * Phase 3E-2: 调用 window.arkTavernViewerBridge.setTemporaryExpression(paramsJson)
   *
   * 设置临时表情,到期后按 restorePolicy 恢复或清除。
   *
   * @param paramsJson JSON 字符串 {name, weight, durationMs, restorePolicy}
   * @returns JSON 字符串
   *   {"success": true, "state": "APPLIED", "temporaryExpressionName": "...",
   *    "temporaryExpressionWeight": 1, "expiresAt": <timestamp>}
   */
  async setTemporaryExpression(paramsJson: string): Promise<string> {
    return this.callWithStringArg('setTemporaryExpression', paramsJson);
  }

  /**
   * Phase 3E-2: 调用 window.arkTavernViewerBridge.cancelTemporaryExpression()
   *
   * 取消当前临时表情,使旧 timeout 失效,清空临时状态。
   * 不恢复任何表情,不改变 currentExpressionName / currentExpressionWeight。
   *
   * @returns JSON 字符串 {"success": true, "state": "..."}
   */
  async cancelTemporaryExpression(): Promise<string> {
    return this.call('cancelTemporaryExpression');
  }

  /**
   * Phase 3E-2: 调用 window.arkTavernViewerBridge.getTemporaryExpressionState()
   *
   * 获取临时表情状态快照(只读)。
   *
   * @returns JSON 字符串
   *   {"success": true, "temporaryExpressionName": "...",
   *    "temporaryExpressionWeight": 1, "temporaryExpiresAt": <ts>,
   *    "temporaryRestorePolicy": "PREVIOUS", "restoreExpressionName": "...",
   *    "restoreExpressionWeight": 0, "temporaryGeneration": <n>}
   */
  async getTemporaryExpressionState(): Promise<string> {
    return this.call('getTemporaryExpressionState');
  }

  /**
   * Phase 3E-2: 调用 window.arkTavernViewerBridge.setExpressionByAlias(paramsJson)
   *
   * 通过业务 expressionId 设置表情,使用持久化别名映射解析真实 expressionName。
   *
   * @param paramsJson JSON 字符串 {expressionId, aliases, weight}
   * @returns JSON 字符串 {"success": true, "state": "APPLIED", "name": "...", "weight": 1}
   */
  async setExpressionByAlias(paramsJson: string): Promise<string> {
    return this.callWithStringArg('setExpressionByAlias', paramsJson);
  }

  /**
   * Phase 3E-2: 调用 window.arkTavernViewerBridge.setTemporaryExpressionByAlias(paramsJson)
   *
   * 通过业务 expressionId 设置临时表情。
   *
   * @param paramsJson JSON 字符串 {expressionId, aliases, weight, durationMs, restorePolicy}
   * @returns JSON 字符串
   *   {"success": true, "state": "APPLIED", "temporaryExpressionName": "...",
   *    "temporaryExpressionWeight": 1, "expiresAt": <ts>}
   */
  async setTemporaryExpressionByAlias(paramsJson: string): Promise<string> {
    return this.callWithStringArg('setTemporaryExpressionByAlias', paramsJson);
  }

  /**
   * Phase 3E-2: 调用 window.arkTavernViewerBridge.resolveExpressionAlias(paramsJson)
   *
   * 解析业务 expressionId 到模型真实 expressionName。
   *
   * @param paramsJson JSON 字符串 {expressionId, aliases}
   * @returns JSON 字符串
   *   - 成功: {"success": true, "expressionName": "Joy"}
   *   - 失败: {"success": false, "error": {"code": "EXPRESSION_ALIAS_NOT_RESOLVED", ...}}
   */
  async resolveExpressionAlias(paramsJson: string): Promise<string> {
    return this.callWithStringArg('resolveExpressionAlias', paramsJson);
  }

  private async call(methodName: string): Promise<string> {
    const fn = this.runJs;
    if (fn === null) {
      throw new Error(`JsCaller not bound: cannot call ${methodName}`);
    }
    const script: string = this.buildBridgeCallScript(methodName, '');
    const raw: string = await fn(script);
    return this.normalizeRunJavaScriptResult(raw);
  }

  private async callWithArgs(methodName: string, args: number[]): Promise<string> {
    const fn = this.runJs;
    if (fn === null) {
      throw new Error(`JsCaller not bound: cannot call ${methodName}`);
    }
    // Phase 1D-2C-2B: 数字参数必须 isFinite,禁止 NaN/Infinity 注入
    const safeArgs: string[] = [];
    for (let i = 0; i < args.length; i++) {
      const n: number = args[i];
      if (!isFinite(n)) {
        throw new Error(`JsCaller.callWithArgs(${methodName}): argument at index ${i} is not finite (n=${n})`);
      }
      safeArgs.push(String(n));
    }
    const argsExpr: string = safeArgs.join(', ');
    const script: string = this.buildBridgeCallScript(methodName, argsExpr);
    const raw: string = await fn(script);
    return this.normalizeRunJavaScriptResult(raw);
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
    // 自动转义单引号 / 双引号 / 反斜杠 / 换行 / Unicode 分隔符,防止 JavaScript 注入
    const argLiteral: string = JSON.stringify(strArg);
    const script: string = this.buildBridgeCallScript(methodName, argLiteral);
    const raw: string = await fn(script);
    return this.normalizeRunJavaScriptResult(raw);
  }

  /**
   * Phase 2A-1: 调用需要单个 boolean 参数的 Bridge 方法。
   *
   * 用于 setCameraControlsEnabled / setSceneGridVisible。
   * 严格布尔校验:确保参数为 JS 原生 true / false,拒绝字符串 "true" / 数字 1 / 任意对象。
   *
   * @param methodName Bridge 方法名
   * @param boolArg 布尔参数
   */
  private async callWithBooleanArg(methodName: string, boolArg: boolean): Promise<string> {
    const fn = this.runJs;
    if (fn === null) {
      throw new Error(`JsCaller not bound: cannot call ${methodName}`);
    }
    // 严格布尔字面量:只能为 true 或 false
    const argLiteral: string = boolArg ? 'true' : 'false';
    const script: string = this.buildBridgeCallScript(methodName, argLiteral);
    const raw: string = await fn(script);
    return this.normalizeRunJavaScriptResult(raw);
  }

  /**
   * Phase 2A-1: 调用需要单个 number 参数的 Bridge 方法。
   *
   * 用于 setSceneLightIntensity。
   * 数字参数必须 isFinite,禁止 NaN/Infinity 注入。
   *
   * @param methodName Bridge 方法名
   * @param numArg 数字参数
   */
  private async callWithNumberArg(methodName: string, numArg: number): Promise<string> {
    const fn = this.runJs;
    if (fn === null) {
      throw new Error(`JsCaller not bound: cannot call ${methodName}`);
    }
    if (!isFinite(numArg)) {
      throw new Error(`JsCaller.callWithNumberArg(${methodName}): argument is not finite (n=${numArg})`);
    }
    const argLiteral: string = String(numArg);
    const script: string = this.buildBridgeCallScript(methodName, argLiteral);
    const raw: string = await fn(script);
    return this.normalizeRunJavaScriptResult(raw);
  }

  /**
   * Phase 1D-2C-2B: 统一构造 Bridge 调用脚本。
   *
   * 使用立即执行函数(IIFE)作为脚本顶层表达式,确保 runJavaScript 拿到稳定的返回值。
   * 所有路径(成功 / Bridge 缺失 / 方法缺失 / 异常)均显式 `return` JSON 字符串。
   *
   * 关键约束:
   * - IIFE 本身是整个脚本的最后一个表达式
   * - 成功路径 `return method.call(bridge)`,保持 this 指向 bridge
   * - Bridge 缺失 / 方法缺失 / 异常路径均 `return JSON.stringify({...})`
   * - 不出现 `bridge.method();` 形式的无返回值调用
   *
   * @param methodName Bridge 方法名(已在白名单中校验)
   * @param argExpressions 参数表达式字符串(已序列化,空字符串表示无参数)
   */
  private buildBridgeCallScript(methodName: string, argExpressions: string): string {
    // 参数表达式为空时调用形如 `method.call(bridge)`,否则 `method.call(bridge, arg1, arg2)`
    const callArgs: string = argExpressions.length > 0 ? `bridge, ${argExpressions}` : 'bridge';
    return `(function () {
  try {
    var bridge = window.arkTavernViewerBridge;
    if (!bridge) {
      // Phase 1D-2C-2C: 主 Bridge 不存在,查询 bootstrap.js 引导层状态
      // 区分 APP_MODULE_LOAD_FAILED / APP_MODULE_EXECUTION_FAILED / APP_BRIDGE_NOT_READY / BOOTSTRAP_BRIDGE_NOT_FOUND
      var bootstrapBridge = window.arkTavernBootstrapBridge;
      var bootstrapState = null;
      var bootstrapAvailable = false;

      if (bootstrapBridge && typeof bootstrapBridge.getBootstrapState === 'function') {
        bootstrapAvailable = true;
        try {
          bootstrapState = bootstrapBridge.getBootstrapState();
        } catch (_) {
          bootstrapState = null;
        }
      }

      // 解析 bootstrapState,提取 phase / errorCode / errorMessage / source / line / column
      var bsPhase = '';
      var bsErrorCode = '';
      var bsErrorMessage = '';
      var bsSource = '';
      var bsLine = 0;
      var bsColumn = 0;

      if (bootstrapState) {
        try {
          var bsParsed = JSON.parse(bootstrapState);
          if (bsParsed && bsParsed.state) {
            var s = bsParsed.state;
            bsPhase = s.phase || '';
            bsErrorCode = s.errorCode || '';
            bsErrorMessage = s.errorMessage || '';
            bsSource = s.source || '';
            bsLine = s.line || 0;
            bsColumn = s.column || 0;
          }
        } catch (_) {
          // bootstrapState 不是合法 JSON,忽略
        }
      }

      // 根据 bootstrap 状态映射错误码
      var mappedCode = 'APP_BRIDGE_NOT_READY';
      var mappedMessage = 'window.arkTavernViewerBridge is unavailable';
      var mappedPhase = 'APP_BOOTSTRAP';

      if (!bootstrapAvailable) {
        // bootstrap.js 自身未加载(经典脚本加载失败)
        mappedCode = 'BOOTSTRAP_BRIDGE_NOT_FOUND';
        mappedMessage = 'window.arkTavernBootstrapBridge is unavailable (bootstrap.js not loaded)';
        mappedPhase = 'APP_BOOTSTRAP';
      } else if (bsPhase === 'APP_MODULE_FAILED') {
        // app.js 模块加载或执行失败
        if (bsErrorCode === 'WINDOW_ERROR') {
          mappedCode = 'APP_MODULE_EXECUTION_FAILED';
          mappedMessage = bsErrorMessage || 'app.js module execution failed';
        } else if (bsErrorCode === 'UNHANDLED_REJECTION') {
          mappedCode = 'APP_MODULE_LOAD_FAILED';
          mappedMessage = bsErrorMessage || 'app.js module load failed';
        } else {
          mappedCode = 'APP_MODULE_EXECUTION_FAILED';
          mappedMessage = bsErrorMessage || 'app.js module failed';
        }
        mappedPhase = bsPhase;
      } else if (bsPhase === 'APP_MODULE_LOADING') {
        // app.js 模块正在加载(import 解析中)
        mappedCode = 'APP_BRIDGE_NOT_READY';
        mappedMessage = 'app.js module is still loading';
        mappedPhase = bsPhase;
      } else if (bsPhase === 'APP_MODULE_EXECUTING') {
        // app.js 模块正在执行,但 Bridge 尚未创建
        mappedCode = 'APP_BRIDGE_NOT_READY';
        mappedMessage = 'app.js module is executing, bridge not yet ready';
        mappedPhase = bsPhase;
      } else if (bsPhase === 'BOOTSTRAP_READY') {
        // bootstrap.js 已加载,但 app.js 尚未开始执行
        mappedCode = 'APP_BRIDGE_NOT_READY';
        mappedMessage = 'app.js module has not started';
        mappedPhase = bsPhase;
      }

      return JSON.stringify({
        success: false,
        error: {
          code: mappedCode,
          message: mappedMessage,
          phase: mappedPhase,
          recoverable: true,
          bootstrapState: bootstrapState,
          bootstrapPhase: bsPhase,
          bootstrapSource: bsSource,
          bootstrapLine: bsLine,
          bootstrapColumn: bsColumn
        }
      });
    }
    var method = bridge['${methodName}'];
    if (typeof method !== 'function') {
      return JSON.stringify({
        success: false,
        error: {
          code: 'BRIDGE_METHOD_NOT_FOUND',
          message: 'Bridge method is unavailable: ${methodName}',
          phase: 'BRIDGE_CALL',
          recoverable: true
        }
      });
    }
    return method.call(${callArgs});
  } catch (error) {
    return JSON.stringify({
      success: false,
      error: {
        code: 'BRIDGE_CALL_FAILED',
        message: error && error.message ? String(error.message) : String(error),
        phase: 'BRIDGE_CALL',
        recoverable: true
      }
    });
  }
})()`;
  }

  /**
   * Phase 1D-2C-2B: 规范化 runJavaScript 返回值。
   *
   * ArkWeb runJavaScript 可能返回 null / undefined / 空字符串 / [object Promise] /
   * 普通 JSON 字符串 / 被额外引号包裹的 JSON / 非 JSON 字符串。本方法统一处理为
   * 合法 JSON 字符串或受控错误 JSON。
   *
   * 处理顺序:
   * 1. null / undefined / 空字符串 → BRIDGE_RESULT_EMPTY
   * 2. 字符串 "null" / "undefined" → BRIDGE_RESULT_EMPTY
   * 3. [object Promise] / Promise 特征 → BRIDGE_RESULT_PROMISE
   * 4. 被额外引号包裹的 JSON(双层编码)→ 解包一层后返回内部 JSON
   * 5. 普通 JSON 对象字符串 → 原样返回
   * 6. 非 JSON 字符串 → BRIDGE_RESULT_NOT_JSON(含截断 rawSummary)
   *
   * 安全约束:
   * - rawSummary 截断到 200 字符,不含完整执行脚本
   * - 不无限递归解包,最多解包 1 层
   * - 不把合法空对象 JSON 无依据判定为 Promise
   */
  private normalizeRunJavaScriptResult(raw: string): string {
    // 1. null / undefined / 空字符串
    if (raw === null || raw === undefined || raw.length === 0) {
      return this.makeBridgeErrorJson('BRIDGE_RESULT_EMPTY', 'Bridge call returned no value', true);
    }

    const trimmed: string = raw.trim();

    // 2. 字符串 "null" / "undefined"(JS null/undefined 被 runJavaScript 字符串化)
    if (trimmed === 'null' || trimmed === 'undefined') {
      return this.makeBridgeErrorJson('BRIDGE_RESULT_EMPTY', 'Bridge call returned no value', true);
    }

    // 3. [object Promise] / 明确 Promise 特征
    //    注意:只在有明确 Promise 特征时判定,不把合法空对象 JSON({})误判为 Promise。
    //    合法空对象 JSON "{}" 会在步骤 7 原样返回,不进入此分支。
    //    Promise.toString() 输出 "[object Promise]",是唯一的明确 Promise 特征。
    if (trimmed === '[object Promise]' ||
        trimmed.indexOf('[object Promise]') >= 0) {
      return this.makeBridgeErrorJson('BRIDGE_RESULT_PROMISE', 'Bridge call returned a Promise (method may be async)', false);
    }

    // 4. 尝试作为普通 JSON 解析
    let firstParse: Object | null = null;
    try {
      firstParse = JSON.parse(trimmed);
    } catch (e) {
      // 5. 非 JSON 字符串 → BRIDGE_RESULT_NOT_JSON
      //    rawSummary 截断到 200 字符,避免泄露完整脚本
      const summary: string = trimmed.length > 200 ? trimmed.substring(0, 200) + '...' : trimmed;
      return this.makeBridgeErrorJsonWithRaw('BRIDGE_RESULT_NOT_JSON', 'Bridge call returned a non-JSON value', true, summary);
    }

    // 6. 如果 firstParse 是字符串,可能是被额外引号包裹的 JSON,尝试解包一层
    if (typeof firstParse === 'string') {
      const inner: string = firstParse as string;
      // 内部字符串为空 → BRIDGE_RESULT_EMPTY
      if (inner.length === 0) {
        return this.makeBridgeErrorJson('BRIDGE_RESULT_EMPTY', 'Bridge call returned no value', true);
      }
      // 内部字符串以 { 或 [ 开头,视为 JSON,原样返回内部字符串
      const innerTrimmed: string = inner.trim();
      if (innerTrimmed.startsWith('{') || innerTrimmed.startsWith('[')) {
        return innerTrimmed;
      }
      // 内部字符串是 "null" / "undefined" → BRIDGE_RESULT_EMPTY
      if (innerTrimmed === 'null' || innerTrimmed === 'undefined') {
        return this.makeBridgeErrorJson('BRIDGE_RESULT_EMPTY', 'Bridge call returned no value', true);
      }
      // 内部字符串非 JSON → BRIDGE_RESULT_NOT_JSON
      const summary: string = innerTrimmed.length > 200 ? innerTrimmed.substring(0, 200) + '...' : innerTrimmed;
      return this.makeBridgeErrorJsonWithRaw('BRIDGE_RESULT_NOT_JSON', 'Bridge call returned a non-JSON value', true, summary);
    }

    // 7. 普通 JSON 对象 / 数组 → 原样返回 trimmed
    return trimmed;
  }

  /**
   * Phase 1D-2C-2B: 构造 Bridge 错误 JSON 字符串(不带 rawSummary)。
   * 使用类型化对象字面量,满足 ArkTS arkts-no-untyped-obj-literals 规则。
   */
  private makeBridgeErrorJson(code: string, message: string, recoverable: boolean): string {
    const errorDetail: BridgeErrorDetail = {
      code: code,
      message: message,
      phase: 'BRIDGE_CALL',
      recoverable: recoverable
    };
    const result: BridgeErrorResult = {
      success: false,
      error: errorDetail
    };
    return JSON.stringify(result);
  }

  /**
   * Phase 1D-2C-2B: 构造 Bridge 错误 JSON 字符串(带 rawSummary)。
   * 用于 BRIDGE_RESULT_NOT_JSON,附带截断后的原始返回摘要。
   */
  private makeBridgeErrorJsonWithRaw(code: string, message: string, recoverable: boolean, rawSummary: string): string {
    const errorDetail: BridgeErrorDetail = {
      code: code,
      message: message,
      phase: 'BRIDGE_CALL',
      recoverable: recoverable,
      rawSummary: rawSummary
    };
    const result: BridgeErrorResult = {
      success: false,
      error: errorDetail
    };
    return JSON.stringify(result);
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
