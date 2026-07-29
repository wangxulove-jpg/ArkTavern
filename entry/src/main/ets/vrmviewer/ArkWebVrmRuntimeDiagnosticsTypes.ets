/**
 * ArkWebVrmRuntimeDiagnosticsTypes — VRM 运行时诊断类型定义(Phase 1D-2C-1)
 *
 * 职责:
 * - 定义运行时阶段枚举(VrmRuntimeStage),覆盖导入、恢复、资源、探测、加载、Provider、GLTFLoader、模型替换全链路
 * - 定义诊断记录结构(VrmRuntimeDiagnostic),供 Provider / Coordinator / GLTFLoader 上报
 * - 通过 Bridge 暴露给 ArkTS 端,在页面显示真实失败阶段、错误码和错误信息
 *
 * 安全约束(AGENTS.md Phase 1D-2C-1 §十三):
 * - 诊断记录禁止包含 cachePath / sourceUri / 文件描述符数值 / 完整异常堆栈 / 用户目录
 * - 仅保留阶段、错误码、错误消息(已截断)、资源 ID、请求方法、HTTP 状态、MIME、Content-Length、时间戳
 *
 * Reference:
 * - AGENTS.md Phase 1D-2C-1 §十三 / §十四 / §十五 / §十六 / §十七
 * - ITEM-009 实施记录(ARKWEB_FIGURE_PORT_LOG.md)
 */

/**
 * VRM 运行时阶段。
 *
 * 与 Web 端 ViewerBridge.js 中的 VRM_RUNTIME_STAGE 字符串对齐。
 * 用于精确定位失败发生在哪一步,避免把所有错误压缩成"加载失败"。
 *
 * Phase 1D-2C-2A 新增启动阶段(ARKWEB_PAGE_END ~ VIEWER_INITIALIZE_FAILED),
 * 覆盖 Web 页面加载完成 → Bridge 绑定 → 初始化请求 → 容器查找 →
 * Scene/Camera/ModelLoader/FrameLoop 就绪 → Viewer READY 全链路。
 */
export enum VrmRuntimeStage {
  /** 初始空闲状态。 */
  IDLE = 'IDLE',
  // ===== Phase 1D-2C-2A: 启动阶段 =====
  /** Web 页面加载完成(ArkTS onPageEnd 触发)。 */
  ARKWEB_PAGE_END = 'ARKWEB_PAGE_END',
  /** window.arkTavernViewerBridge 已绑定。 */
  JS_BRIDGE_BOUND = 'JS_BRIDGE_BOUND',
  /** ArkTS 调用 initializeViewer(已进入 Bridge 方法)。 */
  INITIALIZE_REQUESTED = 'INITIALIZE_REQUESTED',
  /** initializeViewer 返回结果已收到(ArkTS 端解析完成)。 */
  INITIALIZE_RESULT_RECEIVED = 'INITIALIZE_RESULT_RECEIVED',
  /** HTML 容器 ViewerStage 已找到。 */
  VIEWER_CONTAINER_FOUND = 'VIEWER_CONTAINER_FOUND',
  /** HTML 容器 ViewerStage 未找到(致命错误)。 */
  VIEWER_CONTAINER_NOT_FOUND = 'VIEWER_CONTAINER_NOT_FOUND',
  /** ViewerCore.initialize 已启动(异步初始化中)。 */
  VIEWER_CORE_INITIALIZING = 'VIEWER_CORE_INITIALIZING',
  /** ViewerScene 已就绪。 */
  VIEWER_SCENE_READY = 'VIEWER_SCENE_READY',
  /** ViewerCamera 已就绪。 */
  VIEWER_CAMERA_READY = 'VIEWER_CAMERA_READY',
  /** ViewerModelLoader 已就绪。 */
  VIEWER_MODEL_LOADER_READY = 'VIEWER_MODEL_LOADER_READY',
  /** ViewerFrameLoop 已就绪(渲染循环已启动)。 */
  VIEWER_FRAME_LOOP_READY = 'VIEWER_FRAME_LOOP_READY',
  /** Viewer 已就绪(_state = READY,_notifyReady 已调用)。 */
  VIEWER_READY = 'VIEWER_READY',
  /** Viewer 初始化失败(_state = FAILED,_notifyError 已调用)。 */
  VIEWER_INITIALIZE_FAILED = 'VIEWER_INITIALIZE_FAILED',
  // ===== Phase 1D-2C-1: 导入/恢复/资源/探测/加载阶段 =====
  /** 导入完成,资源尚未注册。 */
  IMPORT_READY = 'IMPORT_READY',
  /** 恢复完成,资源尚未注册。 */
  RESTORE_READY = 'RESTORE_READY',
  /** 资源已注册到 Provider。 */
  RESOURCE_REGISTERED = 'RESOURCE_REGISTERED',
  /** 资源元数据已传给 Web 端 keeper。 */
  RESOURCE_PREPARED = 'RESOURCE_PREPARED',
  /** 探测已启动(HEAD 请求已发出)。 */
  PROBE_STARTED = 'PROBE_STARTED',
  /** 探测通过(HEAD 200 + 头部校验通过)。 */
  PROBE_VERIFIED = 'PROBE_VERIFIED',
  /** 探测失败(HTTP 状态 / MIME / Length / ID 校验未通过)。 */
  PROBE_FAILED = 'PROBE_FAILED',
  /** 用户模型加载已启动。 */
  LOAD_STARTED = 'LOAD_STARTED',
  /** Provider 收到 HEAD 请求(不打开文件)。 */
  PROVIDER_HEAD = 'PROVIDER_HEAD',
  /** Provider 收到 GET 请求(打开文件传输 FD)。 */
  PROVIDER_GET = 'PROVIDER_GET',
  /** Provider 响应已构造完成(成功或失败)。 */
  PROVIDER_RESPONSE = 'PROVIDER_RESPONSE',
  /** GLTFLoader.load() 已调用。 */
  GLTF_LOAD_STARTED = 'GLTF_LOAD_STARTED',
  /** GLTFLoader 进度回调(onProgress)。 */
  GLTF_LOAD_PROGRESS = 'GLTF_LOAD_PROGRESS',
  /** GLTFLoader 加载失败(onError)。 */
  GLTF_LOAD_FAILED = 'GLTF_LOAD_FAILED',
  /** VRM 数据已校验(VRMLoaderPlugin 解析完成)。 */
  VRM_DATA_VALIDATED = 'VRM_DATA_VALIDATED',
  /** 模型替换开始(旧模型待释放,新模型待挂载)。 */
  MODEL_REPLACE_STARTED = 'MODEL_REPLACE_STARTED',
  /** 模型替换已提交(scene.addModel + removeModel 完成)。 */
  MODEL_REPLACE_COMMITTED = 'MODEL_REPLACE_COMMITTED',
  /** 模型替换失败(scene 替换过程抛异常)。 */
  MODEL_REPLACE_FAILED = 'MODEL_REPLACE_FAILED'
}

/**
 * 诊断记录结构。
 *
 * 字段白名单(AGENTS.md Phase 1D-2C-1 §十三):
 * - stage:阶段枚举字符串
 * - code:错误码(底层原始错误码,不压缩)
 * - message:错误消息(已截断,不含完整堆栈)
 * - resourceId:opaque resource id(不含 cachePath)
 * - requestMethod:HEAD / GET
 * - httpStatus:HTTP 状态码(0 表示未收到响应)
 * - mimeType:响应 Content-Type(空字符串表示无)
 * - contentLength:响应 Content-Length(0 表示无)
 * - timestamp:发生时间戳(ms,0 表示未记录)
 *
 * 禁止字段:
 * - cachePath(受控缓存路径,只允许在应用内部 Preferences)
 * - sourceUri(用户原始 URI)
 * - fd(文件描述符数值)
 * - stack(完整 JavaScript 堆栈)
 * - 用户目录路径
 */
export interface VrmRuntimeDiagnostic {
  /** 阶段(见 VrmRuntimeStage)。 */
  stage: VrmRuntimeStage;
  /** 错误码(底层原始错误码,如 RESOURCE_OPEN_FAILED / GLTF_LOAD_FAILED)。 */
  code: string;
  /** 错误消息(已截断,不含完整堆栈)。 */
  message: string;
  /** opaque resource id(与 URL 中 /model/<id> 一致)。 */
  resourceId: string;
  /** 请求方法:HEAD / GET(空字符串表示非 HTTP 阶段)。 */
  requestMethod: string;
  /** HTTP 状态码(0 表示未收到响应,如 fetch 失败)。 */
  httpStatus: number;
  /** 响应 Content-Type(空字符串表示无)。 */
  mimeType: string;
  /** 响应 Content-Length(0 表示无)。 */
  contentLength: number;
  /** 发生时间戳(ms,0 表示未记录)。 */
  timestamp: number;
}

/**
 * 默认空诊断(用于初始化)。
 */
export function emptyVrmRuntimeDiagnostic(): VrmRuntimeDiagnostic {
  return {
    stage: VrmRuntimeStage.IDLE,
    code: '',
    message: '',
    resourceId: '',
    requestMethod: '',
    httpStatus: 0,
    mimeType: '',
    contentLength: 0,
    timestamp: 0
  };
}

/**
 * 把 VrmRuntimeStage 字符串解析为枚举。
 * 无法识别时返回 IDLE(保守策略)。
 */
export function parseVrmRuntimeStage(s: string): VrmRuntimeStage {
  switch (s) {
    case 'IDLE':
      return VrmRuntimeStage.IDLE;
    // Phase 1D-2C-2A: 启动阶段
    case 'ARKWEB_PAGE_END':
      return VrmRuntimeStage.ARKWEB_PAGE_END;
    case 'JS_BRIDGE_BOUND':
      return VrmRuntimeStage.JS_BRIDGE_BOUND;
    case 'INITIALIZE_REQUESTED':
      return VrmRuntimeStage.INITIALIZE_REQUESTED;
    case 'INITIALIZE_RESULT_RECEIVED':
      return VrmRuntimeStage.INITIALIZE_RESULT_RECEIVED;
    case 'VIEWER_CONTAINER_FOUND':
      return VrmRuntimeStage.VIEWER_CONTAINER_FOUND;
    case 'VIEWER_CONTAINER_NOT_FOUND':
      return VrmRuntimeStage.VIEWER_CONTAINER_NOT_FOUND;
    case 'VIEWER_CORE_INITIALIZING':
      return VrmRuntimeStage.VIEWER_CORE_INITIALIZING;
    case 'VIEWER_SCENE_READY':
      return VrmRuntimeStage.VIEWER_SCENE_READY;
    case 'VIEWER_CAMERA_READY':
      return VrmRuntimeStage.VIEWER_CAMERA_READY;
    case 'VIEWER_MODEL_LOADER_READY':
      return VrmRuntimeStage.VIEWER_MODEL_LOADER_READY;
    case 'VIEWER_FRAME_LOOP_READY':
      return VrmRuntimeStage.VIEWER_FRAME_LOOP_READY;
    case 'VIEWER_READY':
      return VrmRuntimeStage.VIEWER_READY;
    case 'VIEWER_INITIALIZE_FAILED':
      return VrmRuntimeStage.VIEWER_INITIALIZE_FAILED;
    // Phase 1D-2C-1: 导入/恢复/资源/探测/加载阶段
    case 'IMPORT_READY':
      return VrmRuntimeStage.IMPORT_READY;
    case 'RESTORE_READY':
      return VrmRuntimeStage.RESTORE_READY;
    case 'RESOURCE_REGISTERED':
      return VrmRuntimeStage.RESOURCE_REGISTERED;
    case 'RESOURCE_PREPARED':
      return VrmRuntimeStage.RESOURCE_PREPARED;
    case 'PROBE_STARTED':
      return VrmRuntimeStage.PROBE_STARTED;
    case 'PROBE_VERIFIED':
      return VrmRuntimeStage.PROBE_VERIFIED;
    case 'PROBE_FAILED':
      return VrmRuntimeStage.PROBE_FAILED;
    case 'LOAD_STARTED':
      return VrmRuntimeStage.LOAD_STARTED;
    case 'PROVIDER_HEAD':
      return VrmRuntimeStage.PROVIDER_HEAD;
    case 'PROVIDER_GET':
      return VrmRuntimeStage.PROVIDER_GET;
    case 'PROVIDER_RESPONSE':
      return VrmRuntimeStage.PROVIDER_RESPONSE;
    case 'GLTF_LOAD_STARTED':
      return VrmRuntimeStage.GLTF_LOAD_STARTED;
    case 'GLTF_LOAD_PROGRESS':
      return VrmRuntimeStage.GLTF_LOAD_PROGRESS;
    case 'GLTF_LOAD_FAILED':
      return VrmRuntimeStage.GLTF_LOAD_FAILED;
    case 'VRM_DATA_VALIDATED':
      return VrmRuntimeStage.VRM_DATA_VALIDATED;
    case 'MODEL_REPLACE_STARTED':
      return VrmRuntimeStage.MODEL_REPLACE_STARTED;
    case 'MODEL_REPLACE_COMMITTED':
      return VrmRuntimeStage.MODEL_REPLACE_COMMITTED;
    case 'MODEL_REPLACE_FAILED':
      return VrmRuntimeStage.MODEL_REPLACE_FAILED;
    default:
      return VrmRuntimeStage.IDLE;
  }
}
