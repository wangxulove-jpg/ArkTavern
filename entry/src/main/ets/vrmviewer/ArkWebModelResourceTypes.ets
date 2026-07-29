/**
 * ArkWebModelResourceTypes — 缓存模型资源暴露类型定义(Phase 1D-2A + 1D-2B-1 + 1D-2B-2)
 *
 * 定义把 ArkWebFileImportController 产出的 ImportedModelFile 暴露给 ArkWeb 所需的:
 * - 资源状态机(EMPTY / READY / DISPOSED)
 * - 资源探测状态机(NOT_PROBED / PROBING / VERIFIED / FAILED)(Phase 1D-2B-1)
 * - 公共资源接口(传给 JavaScript,不含真实路径)
 * - 内部资源接口(含 cachePath,仅 ArkTS 内部使用)
 * - 探测结果接口(Phase 1D-2B-1)
 * - 错误码
 * - URL 设计常量
 * - MIME 映射工具
 *
 * 本阶段范围:
 * - 类型与常量定义
 * - URL 格式:https://ark-tavern.local/model/<opaque-id>
 * - JavaScript 只能拿到 resourceUrl / displayName / mimeType / size / extension / gltfDependencyState(Phase 1D-2B-2)
 * - 探测结果含 statusCode / mimeType / contentLength / resourceId / redirected
 *
 * 本阶段不实现:
 * - 实际资源拦截(在 ArkWebModelResourceProvider 实现)
 * - loadModel Bridge(Phase 1D-2B-2)
 * - 模型实际加载与替换
 *
 * SDK 依据(来自 web.d.ts,API 23):
 * - Web(...).onInterceptRequest(callback: Callback<OnInterceptRequestEvent, WebResourceResponse>)
 * - WebResourceResponse.setResponseData(data: string | number | Resource | ArrayBuffer)
 *   - number 类型表示 file handle(FD),用于流式返回缓存文件,避免 9MB+ 文件全量加载到内存
 *
 * Reference:
 * - AGENTS.md Phase 1D-2A / 1D-2B-1 / 1D-2B-2 规范
 * - ITEM-006 / ITEM-007 / ITEM-008 SDK 核查记录(ARKWEB_FIGURE_PORT_LOG.md)
 */

import { GltfDependencyState } from './ArkWebModelImportTypes';

/**
 * 模型资源状态机。
 *
 * 状态流转:
 *   EMPTY → READY        (registerFile 成功)
 *   READY → EMPTY        (unregisterCurrent)
 *   READY → READY        (registerFile 替换,旧资源失效)
 *   任意 → DISPOSED      (dispose)
 *
 * DISPOSED 后所有 matchesRequest / handleRequest 都返回 false / null。
 */
export enum ModelResourceState {
  /** 无注册资源(初始态或已 unregister)。 */
  EMPTY = 'EMPTY',
  /** 资源已就绪,可响应 ArkWeb 资源请求。 */
  READY = 'READY',
  /** Provider 已销毁,拒绝所有请求。 */
  DISPOSED = 'DISPOSED'
}

/**
 * 模型资源探测状态机(Phase 1D-2B-1)。
 *
 * 状态流转:
 *   NOT_PROBED → PROBING       (probe 开始)
 *   PROBING → VERIFIED         (HEAD 请求校验通过)
 *   PROBING → FAILED           (校验失败 / fetch 失败 / 状态码错误 / MIME 不匹配 等)
 *   VERIFIED → PROBING         (重新探测)
 *   FAILED → PROBING           (重试)
 *   任意 → NOT_PROBED          (clear,资源被替换或清除时)
 *
 * 探测只使用 HEAD 请求,不读取模型文件内容。
 */
export enum ModelResourceProbeState {
  /** 未探测(初始态或已 clear)。 */
  NOT_PROBED = 'NOT_PROBED',
  /** 正在探测(HEAD 请求已发出,等待响应)。 */
  PROBING = 'PROBING',
  /** 探测通过(HEAD 200 + MIME + Length + ID 全部校验通过)。 */
  VERIFIED = 'VERIFIED',
  /** 探测失败(任意校验环节失败)。 */
  FAILED = 'FAILED'
}

/**
 * 公共模型资源接口(传给 JavaScript)。
 *
 * 安全约束:
 * - 不包含 cachePath / sourceUri / 任何文件系统路径
 * - 不包含绝对 URL
 * - JavaScript 只能通过 resourceUrl 触发 fetch,由 ArkWeb 拦截返回文件内容
 *
 * Phase 1D-2B-2 起增加 gltfDependencyState,供 JavaScript 端加载协调器
 * 判断 .gltf 文件是否允许加载(SELF_CONTAINED 才允许)。
 */
export interface WebModelResource {
  /** 不透明资源 ID(随机生成,不暴露缓存文件名)。 */
  id: string;
  /** 受控内部 URL:https://ark-tavern.local/model/<opaque-id>。 */
  resourceUrl: string;
  /** 用户可读显示名(已做安全清理,仅用于 UI 展示)。 */
  displayName: string;
  /** MIME 类型(.vrm/.glb → model/gltf-binary,.gltf → model/gltf+json)。 */
  mimeType: string;
  /** 文件大小(字节)。 */
  size: number;
  /** 小写扩展名(不含点)。 */
  extension: string;
  /** 资源注册时间戳(ms)。 */
  createdAt: number;
  /** glTF 外部依赖预检状态(Phase 1D-2B-2:供 JS 端加载协调器判断是否允许加载)。 */
  gltfDependencyState: GltfDependencyState;
}

/**
 * 内部模型资源接口(含真实路径,仅 ArkTS 内部使用)。
 *
 * 严禁传给 JavaScript 或写入日志(只记录 id 与 size)。
 */
export interface InternalModelResource {
  /** 公共资源(可安全传给 JS)。 */
  publicResource: WebModelResource;
  /** 缓存文件绝对路径(<cacheDir>/vrm-imports/<timestamp>-<gen>.<ext>)。 */
  cachePath: string;
}

/**
 * 模型资源错误码。
 */
export class ModelResourceErrorCode {
  /** Provider 已销毁。 */
  static readonly RESOURCE_PROVIDER_DISPOSED: string = 'RESOURCE_PROVIDER_DISPOSED';
  /** 资源未找到(无注册资源或 id 不匹配)。 */
  static readonly RESOURCE_NOT_FOUND: string = 'RESOURCE_NOT_FOUND';
  /** 资源 URL 无效(格式错误 / host 不匹配 / scheme 不匹配)。 */
  static readonly RESOURCE_URL_INVALID: string = 'RESOURCE_URL_INVALID';
  /** 缓存路径无效(不在 importDirectory 下 / 包含 .. / 不是普通文件)。 */
  static readonly RESOURCE_PATH_INVALID: string = 'RESOURCE_PATH_INVALID';
  /** 打开缓存文件失败(FD 申请失败)。 */
  static readonly RESOURCE_OPEN_FAILED: string = 'RESOURCE_OPEN_FAILED';
  /** 读取缓存文件失败(在读取过程中发生 IO 错误)。 */
  static readonly RESOURCE_READ_FAILED: string = 'RESOURCE_READ_FAILED';
  /** Range 请求非法(本阶段不实现 Range,收到 Range 视为非法)。 */
  static readonly RESOURCE_RANGE_INVALID: string = 'RESOURCE_RANGE_INVALID';
  /** 构造响应失败(WebResourceResponse 设置失败)。 */
  static readonly RESOURCE_RESPONSE_FAILED: string = 'RESOURCE_RESPONSE_FAILED';
  /** 资源已过期(registerFile 替换后,旧 resourceUrl 不再有效)。 */
  static readonly RESOURCE_STALE: string = 'RESOURCE_STALE';
}

/**
 * 模型资源探测错误码(Phase 1D-2B-1 + 1D-2C-2E-2A)。
 *
 * 仅用于 JavaScript 端 ViewerModelResourceProbe 的探测失败场景。
 * 错误以 JSON 字符串形式返回,不抛到全局。
 */
export class ModelResourceProbeErrorCode {
  /** 未准备资源(window.arkTavernPreparedModelResource 为 null)。 */
  static readonly RESOURCE_NOT_PREPARED: string = 'RESOURCE_NOT_PREPARED';
  /** 探测器已销毁。 */
  static readonly RESOURCE_PROBE_DISPOSED: string = 'RESOURCE_PROBE_DISPOSED';
  /** 已有探测进行中(同一资源不重复发起 HEAD 请求)。 */
  static readonly RESOURCE_PROBE_IN_PROGRESS: string = 'RESOURCE_PROBE_IN_PROGRESS';
  /** fetch 调用本身失败(网络错误 / ArkWeb 未拦截 / 抛异常)。 */
  static readonly RESOURCE_FETCH_FAILED: string = 'RESOURCE_FETCH_FAILED';
  /** HTTP 状态码非 200(如 404 / 500 / 416 等)。 */
  static readonly RESOURCE_HTTP_STATUS_INVALID: string = 'RESOURCE_HTTP_STATUS_INVALID';
  /** 响应发生重定向(redirected === true,配置 redirect: 'error' 仍可能发生)。 */
  static readonly RESOURCE_REDIRECTED: string = 'RESOURCE_REDIRECTED';
  /** Content-Type 与预期 MIME 不匹配(基础 MIME 比较忽略 charset 参数)。 */
  static readonly RESOURCE_MIME_MISMATCH: string = 'RESOURCE_MIME_MISMATCH';
  /** Content-Length header 缺失(自定义头与标准头均缺失)。 */
  static readonly RESOURCE_LENGTH_MISSING: string = 'RESOURCE_LENGTH_MISSING';
  /** Content-Length 值无法解析为安全整数(自定义头与标准头均无效)。 */
  static readonly RESOURCE_LENGTH_INVALID: string = 'RESOURCE_LENGTH_INVALID';
  /** Content-Length 与资源大小不一致(自定义头与标准头均存在但与预期不符)。 */
  static readonly RESOURCE_LENGTH_MISMATCH: string = 'RESOURCE_LENGTH_MISMATCH';
  /** X-ArkTavern-Resource-Id header 缺失。 */
  static readonly RESOURCE_ID_MISSING: string = 'RESOURCE_ID_MISSING';
  /** X-ArkTavern-Resource-Id 与 URL 中 opaque id 不一致(Phase 1D-2B-2)。 */
  static readonly RESOURCE_ID_MISMATCH: string = 'RESOURCE_ID_MISMATCH';
  /**
   * Phase 1D-2C-2E-2A: 自定义长度头 X-ArkTavern-Content-Length 存在但无法解析为安全整数。
   *
   * 当自定义头存在但值非数字时返回此错误,不静默回退到标准头。
   * 因为 Provider 给出了损坏的自定义证明,说明链路有问题。
   */
  static readonly RESOURCE_CUSTOM_LENGTH_INVALID: string = 'RESOURCE_CUSTOM_LENGTH_INVALID';
  /**
   * Phase 1D-2C-2E-2A: 长度不可用。
   *
   * 自定义头缺失,标准 Content-Length = 0,无法证明资源实际大小。
   * 与 RESOURCE_LENGTH_MISSING 的区别:
   * - LENGTH_MISSING: 两个头都缺失
   * - LENGTH_UNAVAILABLE: 标准头存在但为 0,自定义头缺失(常见于 ArkWeb HEAD 响应)
   */
  static readonly RESOURCE_LENGTH_UNAVAILABLE: string = 'RESOURCE_LENGTH_UNAVAILABLE';
}

/**
 * 模型资源探测结果(Phase 1D-2B-1 + 1D-2C-2E-2A)。
 *
 * 由 JavaScript 端 ViewerModelResourceProbe.probe() 返回,
 * 通过 Bridge 传回 ArkTS 端供页面显示。
 *
 * 安全约束:
 * - 不包含 cachePath / sourceUri / 任何文件系统路径
 * - 只含探测状态、HTTP 状态码、响应头校验结果与时间戳
 * - 不包含完整 Headers 对象(仅记录已解析的关键值)
 */
export interface ModelResourceProbeResult {
  /** 探测状态(NOT_PROBED / PROBING / VERIFIED / FAILED)。 */
  state: ModelResourceProbeState;
  /** 探测的资源 URL。 */
  resourceUrl: string;
  /** HTTP 状态码(HEAD 请求响应;fetch 失败时为 0)。 */
  statusCode: number;
  /** 响应的 Content-Type(HEAD 请求响应;失败时为空字符串)。 */
  mimeType: string;
  /**
   * 选定的 Content-Length(解析为整数;失败时为 -1)。
   *
   * Phase 1D-2C-2E-2A:此值为长度选择逻辑的最终结果,
   * 优先来自 X-ArkTavern-Content-Length,标准头作为兼容回退。
   */
  contentLength: number;
  /** 响应的 X-ArkTavern-Resource-Id(HEAD 请求响应;失败时为空字符串)。 */
  resourceId: string;
  /** 响应是否发生重定向。 */
  redirected: boolean;
  /** 失败时为错误码,成功时为空字符串。 */
  errorCode: string;
  /** 失败时为错误消息,成功时为空字符串。 */
  errorMessage: string;
  /** 探测完成时间戳(ms)。 */
  verifiedAt: number;
  /**
   * Phase 1D-2C-2E-2A: 长度来源类型。
   *
   * - 'CUSTOM': 使用 X-ArkTavern-Content-Length
   * - 'STANDARD': 使用标准 Content-Length
   * - 'UNAVAILABLE': 长度不可用(两个头均缺失或为 0)
   * - '': 探测未到达长度校验阶段(如 fetch 失败)
   */
  contentLengthSource: string;
  /**
   * Phase 1D-2C-2E-2A: 自定义长度头解析后的数值(失败时为 -1)。
   *
   * 仅记录 X-ArkTavern-Content-Length 的最终解析值,
   * 不包含原始字符串(避免泄漏完整 Headers 对象)。
   */
  customContentLength: number;
  /**
   * Phase 1D-2C-2E-2A: 标准长度头解析后的数值(失败时为 -1)。
   *
   * 仅记录标准 Content-Length 的最终解析值,
   * 用于诊断 ArkWeb 是否重写为 0。
   */
  standardContentLength: number;
}

/**
 * 资源 URL 设计常量。
 *
 * 格式:`${RESOURCE_SCHEME}://${RESOURCE_HOST}${RESOURCE_PATH_PREFIX}<opaque-id>`
 * 示例:`https://ark-tavern.local/model/a3f2c9-1l4x2z9q`
 */
export class ModelResourceUrlConfig {
  /** URL scheme(https,ArkWeb 默认允许)。 */
  public static readonly RESOURCE_SCHEME: string = 'https';

  /** URL host(固定,通过 matchesRequest 白名单匹配)。 */
  public static readonly RESOURCE_HOST: string = 'ark-tavern.local';

  /** URL 路径前缀(/model/)。 */
  public static readonly RESOURCE_PATH_PREFIX: string = '/model/';

  /** 完整 URL 前缀(用于 matchesRequest 快速判断)。 */
  public static readonly RESOURCE_URL_PREFIX: string =
    `${ModelResourceUrlConfig.RESOURCE_SCHEME}://${ModelResourceUrlConfig.RESOURCE_HOST}${ModelResourceUrlConfig.RESOURCE_PATH_PREFIX}`;

  /** opaque ID 长度(8 位 hex + 时间戳 base36,约 16-20 字符)。 */
  public static readonly OPAQUE_ID_HEX_LENGTH: number = 8;
}

/**
 * MIME 类型映射(与 ArkWebModelImportTypes 保持一致)。
 *
 * @param extension 小写扩展名(不含点)
 * @returns MIME 类型;未知扩展名返回 'application/octet-stream'
 */
export function mapModelExtensionToMime(extension: string): string {
  switch (extension) {
    case 'vrm':
    case 'glb':
      return 'model/gltf-binary';
    case 'gltf':
      return 'model/gltf+json';
    default:
      return 'application/octet-stream';
  }
}

/**
 * 构造受控资源 URL。
 *
 * @param opaqueId 不透明资源 ID(由 Provider 生成)
 * @returns 完整资源 URL,如 https://ark-tavern.local/model/<opaqueId>
 */
export function buildModelResourceUrl(opaqueId: string): string {
  return `${ModelResourceUrlConfig.RESOURCE_URL_PREFIX}${opaqueId}`;
}

/**
 * 判断 URL 是否为受控模型资源 URL(供 matchesRequest 使用)。
 *
 * 判断条件:
 * 1. 以 RESOURCE_URL_PREFIX 开头
 * 2. prefix 之后还有内容(即 opaque ID 非空)
 * 3. opaque ID 中不含路径分隔符 / 查询字符串 / fragment
 *
 * @param url 待判断的 URL
 * @returns true 表示是受控资源 URL,需要拦截;false 表示放行
 */
export function isModelResourceUrl(url: string): boolean {
  if (!url.startsWith(ModelResourceUrlConfig.RESOURCE_URL_PREFIX)) {
    return false;
  }
  const opaqueId: string = url.substring(ModelResourceUrlConfig.RESOURCE_URL_PREFIX.length);
  if (opaqueId.length === 0) {
    return false;
  }
  // opaque ID 中不应包含路径分隔符、查询、fragment
  if (opaqueId.includes('/') || opaqueId.includes('?') || opaqueId.includes('#')) {
    return false;
  }
  return true;
}

/**
 * 从受控资源 URL 提取 opaque ID。
 *
 * @param url 受控资源 URL
 * @returns opaque ID;若 URL 不合法返回 null
 */
export function extractOpaqueIdFromUrl(url: string): string | null {
  if (!isModelResourceUrl(url)) {
    return null;
  }
  return url.substring(ModelResourceUrlConfig.RESOURCE_URL_PREFIX.length);
}
