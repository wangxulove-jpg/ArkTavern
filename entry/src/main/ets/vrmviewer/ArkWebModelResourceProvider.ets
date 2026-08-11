import { Logger } from '../utils/Logger';
/**
 * ArkWebModelResourceProvider — 缓存模型资源提供者(Phase 1D-2A + 1D-2B-1)
 *
 * 职责:
 * - 接收 ArkWebFileImportController 产出的 ImportedModelFile,注册为受控资源
 * - 生成不透明资源 ID 与受控 URL(https://ark-tavern.local/model/<opaque-id>)
 * - 验证缓存路径安全性(目录穿越防护)
 * - 响应 ArkWeb onInterceptRequest 回调
 *   - GET:通过 FD 流式返回缓存文件
 *   - HEAD:只返回响应头,不打开文件,不创建 FD(Phase 1D-2B-1)
 *   - 其他方法:返回 405 Method Not Allowed
 * - 资源生命周期管理(注册 / 替换 / 注销 / 销毁)
 *
 * 本阶段范围:
 * - 证明 ArkWeb 可通过受控 URL 获取缓存文件
 * - setResponseData(number) 传 FD,避免 9MB+ 文件全量加载到内存
 * - 单一活动资源(新注册替换旧资源,旧 URL 失效)
 * - HEAD 请求支持(资源探测,不打开文件)
 *
 * 本阶段不实现:
 * - Range 请求(SDK 未明确支持,统一返回 200 完整文件或 416 错误)
 * - loadModel Bridge(Phase 1D-2B-2)
 * - 模型实际加载与替换
 *
 * SDK 依据(来自 web.d.ts,API 23):
 * - Web(...).onInterceptRequest(callback: Callback<OnInterceptRequestEvent, WebResourceResponse>)
 * - WebResourceResponse.setResponseData(data: string | number | Resource | ArrayBuffer)
 *   - number 类型表示 file handle,本实现使用此类型(GET 路径)
 * - WebResourceRequest.getRequestMethod(): string — 返回 HTTP method
 *
 * Reference:
 * - AGENTS.md Phase 1D-2A / 1D-2B-1 规范
 * - ITEM-006 / ITEM-007 SDK 核查记录(ARKWEB_FIGURE_PORT_LOG.md)
 *
 * 安全约束:
 * - WebModelResource 不包含 cachePath / sourceUri
 * - URL 中不包含任何路径信息
 * - matchesRequest 拒绝非法 host / scheme / 含路径穿越的 URL
 * - 缓存路径必须位于 importDirectory 之下,且不含 '..'
 * - dispose 后所有请求返回 null(放行,不返回错误响应避免干扰其他资源)
 * - HEAD 请求不打开文件描述符,仅返回元数据响应头
 */

import { fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { ImportedModelFile, CACHE_SUBDIR, GltfDependencyState } from './ArkWebModelImportTypes';
import {
  ModelResourceState,
  WebModelResource,
  InternalModelResource,
  ModelResourceErrorCode,
  ModelResourceUrlConfig,
  buildModelResourceUrl,
  isModelResourceUrl,
  extractOpaqueIdFromUrl
} from './ArkWebModelResourceTypes';
import {
  VrmRuntimeDiagnostic,
  VrmRuntimeStage
} from './ArkWebVrmRuntimeDiagnosticsTypes';
import { ArkWebAvatarModelAsset } from './ArkWebAvatarAssetTypes';

/**
 * 资源响应构造结果(内部使用)。
 *
 * handleRequest 成功时返回 WebResourceResponse,失败时返回 ResourceError。
 */
interface ResourceHandleResult {
  /** 成功时为 WebResourceResponse,失败时为 null。 */
  response: WebResourceResponse | null;
  /** 失败时为错误码,成功时为空字符串。 */
  errorCode: string;
  /** 失败时为错误消息,成功时为空字符串。 */
  errorMessage: string;
}

/**
 * 缓存模型资源提供者。
 *
 * 使用方式:
 * 1. 页面 aboutToAppear 创建实例,传入 context.cacheDir
 * 2. ArkWebFileImportController.pickModelFile() 成功后调用 registerFile(file)
 * 3. Web 组件 onInterceptRequest 回调中调用 matchesRequest / handleRequest
 * 4. 页面 aboutToDisappear 调用 dispose()
 *
 * 状态机:
 *   EMPTY → READY        (registerFile 成功)
 *   READY → READY        (registerFile 替换,旧 URL 失效)
 *   READY → EMPTY        (unregisterCurrent)
 *   任意 → DISPOSED      (dispose,不可恢复)
 */
export class ArkWebModelResourceProvider {
  /** 当前资源状态。 */
  private state: ModelResourceState = ModelResourceState.EMPTY;
  /** 当前注册的资源(含 cachePath,仅内部使用)。 */
  private currentResource: InternalModelResource | null = null;
  /** 是否已销毁。 */
  private disposed: boolean = false;
  /** 受控缓存目录(规范化后的绝对路径)。 */
  private readonly importDirectory: string;
  /** Phase 3B: 持久化模型根目录 (规范化后的绝对路径,如 <filesDir>/avatar-assets)。 */
  private persistentRootDir: string = '';
  /**
   * Phase 1D-2C-1: 诊断回调。
   *
   * 由 VrmViewerPage 注入,用于把 Provider 处理 HEAD/GET 请求的过程上报到页面,
   * 在运行诊断区域显示真实失败阶段、错误码和错误信息。
   *
   * 安全约束:
   * - 回调收到的 VrmRuntimeDiagnostic 不含 cachePath / sourceUri / fd / stack
   * - 仅包含 stage / code / message / resourceId / requestMethod / httpStatus / mimeType / contentLength / timestamp
   */
  private onDiagnostic: ((diagnostic: VrmRuntimeDiagnostic) => void) | null = null;

  /**
   * 构造函数。
   *
   * @param cacheDir 应用 cacheDir(通常为 context.cacheDir)
   */
  constructor(cacheDir: string) {
    // 拼接并规范化 importDirectory
    // cacheDir 形如 /data/storage/el2/cache
    // importDirectory 形如 /data/storage/el2/cache/vrm-imports
    const rawDir: string = `${cacheDir}/${CACHE_SUBDIR}`;
    this.importDirectory = normalizePath(rawDir);
  }

  /**
   * Phase 3B: 配置持久化模型根目录。
   *
   * 启用 registerPersistentAsset 方法,允许注册 filesDir 下的模型文件。
   *
   * @param persistentRoot 持久化根目录绝对路径 (如 <filesDir>/avatar-assets)
   */
  setPersistentRootDir(persistentRoot: string): void {
    this.persistentRootDir = normalizePath(persistentRoot);
  }

  /**
   * Phase 1D-2C-1: 设置诊断回调。
   *
   * @param callback 诊断回调函数(可空,传 null 取消)
   */
  setDiagnosticCallback(callback: ((diagnostic: VrmRuntimeDiagnostic) => void) | null): void {
    this.onDiagnostic = callback;
  }

  /**
   * Phase 1D-2C-1: 上报诊断(内部方法)。
   *
   * 仅 stage / code / message / resourceId / requestMethod / httpStatus / mimeType / contentLength / timestamp,
   * 不上报 cachePath / sourceUri / fd / stack / 用户目录。
   */
  private emitDiagnostic(
    stage: VrmRuntimeStage,
    code: string,
    message: string,
    requestMethod: string,
    httpStatus: number,
    mimeType: string,
    contentLength: number
  ): void {
    if (this.onDiagnostic === null) {
      return;
    }
    // 截断错误消息,避免完整堆栈泄漏
    const truncatedMessage: string = message.length > 256 ? message.substring(0, 256) : message;
    const resourceId: string = this.currentResource !== null
      ? this.currentResource.publicResource.id
      : '';
    const diagnostic: VrmRuntimeDiagnostic = {
      stage: stage,
      code: code,
      message: truncatedMessage,
      resourceId: resourceId,
      requestMethod: requestMethod,
      httpStatus: httpStatus,
      mimeType: mimeType,
      contentLength: contentLength,
      timestamp: Date.now()
    };
    try {
      this.onDiagnostic(diagnostic);
    } catch (e) {
      // 回调失败仅日志,不影响 Provider 主流程
      const msg: string = e instanceof Error ? e.message : String(e);
      Logger.warn(`[ArkWebModelResourceProvider] onDiagnostic callback failed: ${msg}`);
    }
  }

  /**
   * 注册模型文件为受控资源。
   *
   * 步骤:
   * 1. 检查 Provider 未销毁
   * 2. 验证 file 非空
   * 3. 验证 cachePath 位于 importDirectory 下(目录穿越防护)
   * 4. 验证文件存在且为普通文件
   * 5. 验证文件大小与 file.size 一致
   * 6. 生成不透明资源 ID
   * 7. 构造 WebModelResource(不含 cachePath)
   * 8. 原子替换 currentResource
   *
   * @param file ArkWebFileImportController 产出的导入文件
   * @returns 公共资源接口(可安全传给 JavaScript);失败抛出 Error
   */
  registerFile(file: ImportedModelFile): WebModelResource {
    if (this.disposed || this.state === ModelResourceState.DISPOSED) {
      throw new Error(ModelResourceErrorCode.RESOURCE_PROVIDER_DISPOSED);
    }

    if (!file) {
      throw new Error(ModelResourceErrorCode.RESOURCE_NOT_FOUND);
    }

    // 路径安全验证
    const normalizedCachePath: string = normalizePath(file.cachePath);
    if (!isPathUnderDirectory(normalizedCachePath, this.importDirectory)) {
      throw new Error(`${ModelResourceErrorCode.RESOURCE_PATH_INVALID}: cachePath not under importDirectory`);
    }
    if (containsTraversalSegments(normalizedCachePath)) {
      throw new Error(`${ModelResourceErrorCode.RESOURCE_PATH_INVALID}: cachePath contains '..' segment`);
    }

    // 文件存在性 + 大小校验(同步 stat)
    let stat: fileIo.Stat;
    try {
      stat = fileIo.statSync(normalizedCachePath);
    } catch (e) {
      const msg: string = e instanceof Error ? e.message : String(e);
      throw new Error(`${ModelResourceErrorCode.RESOURCE_OPEN_FAILED}: stat failed: ${msg}`);
    }
    if (!stat.isFile) {
      throw new Error(`${ModelResourceErrorCode.RESOURCE_PATH_INVALID}: not a regular file`);
    }
    if (stat.size !== file.size) {
      throw new Error(
        `${ModelResourceErrorCode.RESOURCE_PATH_INVALID}: size mismatch (expected ${file.size}, actual ${stat.size})`
      );
    }

    // 生成不透明资源 ID
    const opaqueId: string = generateOpaqueId();
    const resourceUrl: string = buildModelResourceUrl(opaqueId);

    // 构造公共资源(不含 cachePath / sourceUri)
    const publicResource: WebModelResource = {
      id: opaqueId,
      resourceUrl: resourceUrl,
      displayName: file.displayName,
      mimeType: file.mimeType,
      size: file.size,
      extension: file.extension,
      createdAt: Date.now(),
      gltfDependencyState: file.gltfDependencyState
    };

    // 原子替换当前资源(旧 URL 立即失效)
    const internalResource: InternalModelResource = {
      publicResource: publicResource,
      cachePath: normalizedCachePath
    };
    this.currentResource = internalResource;
    this.state = ModelResourceState.READY;

    Logger.debug(
      `[ArkWebModelResourceProvider] registerFile: id=${opaqueId}, size=${file.size}, mimeType=${file.mimeType}`
    );

    return publicResource;
  }

  /**
   * Phase 3B: 注册持久化模型资产为受控资源。
   *
   * 与 registerFile 不同:
   * - 接受 filesDir 下的绝对路径 (而非 cacheDir/vrm-imports)
   * - 使用 asset.resourceId 作为 opaqueId (稳定,重启后 URL 不变)
   * - 路径校验针对 persistentRootDir (构造时传入)
   *
   * 步骤:
   * 1. 检查 Provider 未销毁
   * 2. 验证 absolutePath 位于 persistentRootDir 下
   * 3. 验证文件存在且为普通文件
   * 4. 验证文件大小与 asset.byteLength 一致
   * 5. 使用 asset.resourceId 作为 opaqueId 构造 URL
   * 6. 构造 WebModelResource (不含 cachePath)
   * 7. 原子替换 currentResource
   *
   * @param absolutePath filesDir 下的绝对路径
   * @param asset 持久化模型资产记录
   * @param gltfDependencyState glTF 依赖预检状态 (持久化时不保存,运行时由调用方提供)
   * @returns 公共资源接口 (可安全传给 JavaScript);失败抛出 Error
   */
  registerPersistentAsset(
    absolutePath: string,
    asset: ArkWebAvatarModelAsset,
    gltfDependencyState: GltfDependencyState
  ): WebModelResource {
    if (this.disposed || this.state === ModelResourceState.DISPOSED) {
      throw new Error(ModelResourceErrorCode.RESOURCE_PROVIDER_DISPOSED);
    }
    if (this.persistentRootDir.length === 0) {
      throw new Error(`${ModelResourceErrorCode.RESOURCE_PATH_INVALID}: persistentRootDir not configured`);
    }

    // 路径安全验证 (针对 persistentRootDir)
    const normalizedPath: string = normalizePath(absolutePath);
    if (!isPathUnderDirectory(normalizedPath, this.persistentRootDir)) {
      throw new Error(`${ModelResourceErrorCode.RESOURCE_PATH_INVALID}: path not under persistentRootDir`);
    }
    if (containsTraversalSegments(normalizedPath)) {
      throw new Error(`${ModelResourceErrorCode.RESOURCE_PATH_INVALID}: path contains '..' segment`);
    }

    // 文件存在性 + 大小校验
    let stat: fileIo.Stat;
    try {
      stat = fileIo.statSync(normalizedPath);
    } catch (e) {
      const msg: string = e instanceof Error ? e.message : String(e);
      throw new Error(`${ModelResourceErrorCode.RESOURCE_OPEN_FAILED}: stat failed: ${msg}`);
    }
    if (!stat.isFile) {
      throw new Error(`${ModelResourceErrorCode.RESOURCE_PATH_INVALID}: not a regular file`);
    }
    if (stat.size !== asset.byteLength) {
      throw new Error(
        `${ModelResourceErrorCode.RESOURCE_PATH_INVALID}: size mismatch (expected ${asset.byteLength}, actual ${stat.size})`
      );
    }

    // 使用 asset.resourceId 作为 opaqueId (稳定)
    const opaqueId: string = asset.resourceId;
    const resourceUrl: string = buildModelResourceUrl(opaqueId);

    // 从 relativePath 提取扩展名 (models/<modelId>.<ext>)
    const extension: string = this.extractExtensionFromRelativePath(asset.relativePath);

    // 构造公共资源 (不含 cachePath / sourceUri)
    const publicResource: WebModelResource = {
      id: opaqueId,
      resourceUrl: resourceUrl,
      displayName: asset.displayName,
      mimeType: asset.mimeType,
      size: asset.byteLength,
      extension: extension,
      createdAt: asset.createdAt,
      gltfDependencyState: gltfDependencyState
    };

    // 原子替换当前资源
    const internalResource: InternalModelResource = {
      publicResource: publicResource,
      cachePath: normalizedPath
    };
    this.currentResource = internalResource;
    this.state = ModelResourceState.READY;

    Logger.debug(
      `[ArkWebModelResourceProvider] registerPersistentAsset: id=${opaqueId}, size=${asset.byteLength}, mimeType=${asset.mimeType}`
    );

    return publicResource;
  }

  /**
   * Phase 3B: 从 relativePath 提取小写扩展名。
   * relativePath 格式: models/<modelId>.<ext>
   * @returns 小写扩展名 (如 'vrm');失败返回 'vrm' (默认)
   */
  private extractExtensionFromRelativePath(relativePath: string): string {
    const lastDot: number = relativePath.lastIndexOf('.');
    if (lastDot < 0 || lastDot === relativePath.length - 1) {
      return 'vrm'; // 默认
    }
    const ext: string = relativePath.substring(lastDot + 1).toLowerCase();
    if (ext === 'vrm' || ext === 'glb' || ext === 'gltf') {
      return ext;
    }
    return 'vrm';
  }

  /**
   * 注销当前资源(不删除缓存文件)。
   *
   * 之后 matchesRequest 返回 false,handleRequest 返回 null。
   * 缓存文件删除仍由 ArkWebFileImportController.clearCurrentFile() 负责。
   */
  unregisterCurrent(): void {
    if (this.disposed) {
      return;
    }
    if (this.currentResource !== null) {
      Logger.debug(
        `[ArkWebModelResourceProvider] unregister: id=${this.currentResource.publicResource.id}`
      );
    }
    this.currentResource = null;
    this.state = ModelResourceState.EMPTY;
  }

  /**
   * 获取当前公共资源(可安全传给 JavaScript)。
   *
   * @returns 当前资源;无资源或已销毁返回 null
   */
  getCurrentResource(): WebModelResource | null {
    if (this.disposed || this.state !== ModelResourceState.READY) {
      return null;
    }
    if (this.currentResource === null) {
      return null;
    }
    return this.currentResource.publicResource;
  }

  /**
   * 判断 URL 是否为当前注册资源的 URL(供 onInterceptRequest 使用)。
   *
   * 仅匹配当前活动资源的 opaque ID,旧资源 URL 一律返回 false。
   *
   * @param url 待判断的 URL
   * @returns true 表示需要拦截;false 表示放行(交由 Web 默认处理)
   */
  matchesRequest(url: string): boolean {
    if (this.disposed || this.state !== ModelResourceState.READY) {
      return false;
    }
    if (this.currentResource === null) {
      return false;
    }
    if (!isModelResourceUrl(url)) {
      return false;
    }
    const requestOpaqueId: string | null = extractOpaqueIdFromUrl(url);
    if (requestOpaqueId === null) {
      return false;
    }
    // 仅匹配当前资源 ID,旧 ID 视为过期
    return requestOpaqueId === this.currentResource.publicResource.id;
  }

  /**
   * 处理资源请求,构造 WebResourceResponse。
   *
   * Phase 1D-2B-1 起支持 HTTP method 区分:
   * - GET:打开文件,FD 传输(原 Phase 1D-2A 行为)
   * - HEAD:不打开文件,只返回响应头(资源探测)
   * - 其他:405 Method Not Allowed
   *
   * 流程:
   * 1. 状态检查
   * 2. URL 匹配检查
   * 3. method 判断(GET / HEAD / 其他)
   * 4. GET 路径:打开缓存文件,FD 传输
   * 5. HEAD 路径:验证文件存在与大小一致性,只构造响应头,不打开文件
   *
   * FD 生命周期(GET 路径):
   * - 成功:setResponseData(fd) 后,FD 由 ArkWeb 负责关闭(应用不主动关闭)
   * - 失败(setResponseData 之前):应用负责关闭 FD
   * - 本阶段不支持 Range:GET 收到 Range header 视为非法,返回 416
   *
   * HEAD 路径:
   * - 不调用 fileIo.openSync
   * - 不调用 setResponseData(fd)
   * - 不创建任何文件描述符
   * - 通过 statSync 验证文件仍存在且大小一致(失败返回 500)
   *
   * @param url 请求 URL
   * @param method HTTP 方法(GET / HEAD / POST 等,大小写不敏感)
   * @param requestHeaders 请求头数组(来自 WebResourceRequest.getRequestHeader())
   * @returns 处理结果(response 或 error)
   */
  handleRequest(
    url: string,
    method: string,
    requestHeaders: Array<Header>
  ): ResourceHandleResult {
    if (this.disposed || this.state === ModelResourceState.DISPOSED) {
      return {
        response: null,
        errorCode: ModelResourceErrorCode.RESOURCE_PROVIDER_DISPOSED,
        errorMessage: 'Provider disposed'
      };
    }
    if (this.state !== ModelResourceState.READY || this.currentResource === null) {
      return {
        response: null,
        errorCode: ModelResourceErrorCode.RESOURCE_NOT_FOUND,
        errorMessage: 'No active resource'
      };
    }
    if (!this.matchesRequest(url)) {
      return {
        response: null,
        errorCode: ModelResourceErrorCode.RESOURCE_STALE,
        errorMessage: 'URL does not match current resource'
      };
    }

    const upperMethod: string = method.toUpperCase();

    // HEAD 路径:不打开文件,只返回响应头
    if (upperMethod === 'HEAD') {
      return this.handleHeadRequest(this.currentResource);
    }

    // 非 GET 方法:405 Method Not Allowed
    if (upperMethod !== 'GET') {
      const response: WebResourceResponse = this.createErrorResponse(
        405,
        'Method Not Allowed',
        `Method ${method} not allowed`
      );
      // 覆盖为含 Allow 的完整响应头(保留 CORS,Phase 1D-2B-2 + 1D-2C-2E-2A 自定义长度头)
      response.setResponseHeader([
        { headerKey: 'Content-Type', headerValue: 'text/plain' },
        { headerKey: 'Cache-Control', headerValue: 'no-store' },
        { headerKey: 'Allow', headerValue: 'GET, HEAD' },
        { headerKey: 'Access-Control-Allow-Origin', headerValue: '*' },
        { headerKey: 'Access-Control-Expose-Headers',
          headerValue: 'Content-Length, X-ArkTavern-Content-Length, X-ArkTavern-Resource-Id' },
        { headerKey: 'X-Content-Type-Options', headerValue: 'nosniff' }
      ]);
      return {
        response: response,
        errorCode: ModelResourceErrorCode.RESOURCE_URL_INVALID,
        errorMessage: `Method ${method} not allowed`
      };
    }

    // GET 路径:Range 请求检查(本阶段不支持 Range)
    if (hasRangeHeader(requestHeaders)) {
      const response: WebResourceResponse = this.createErrorResponse(
        416,
        'Range Not Satisfiable',
        'Range requests are not supported'
      );
      return {
        response: response,
        errorCode: ModelResourceErrorCode.RESOURCE_RANGE_INVALID,
        errorMessage: 'Range requests not supported'
      };
    }

    return this.handleGetRequest(this.currentResource);
  }

  /**
   * 处理 HEAD 请求(Phase 1D-2B-1)。
   *
   * - 不打开文件,不创建 FD
   * - 通过 statSync 验证文件存在与大小一致
   * - 构造 200 响应,只含响应头
   * - setResponseData 设置为空字符串(HEAD 响应无 body)
   *
   * 失败时返回 500 错误响应(文件不存在 / stat 失败 / 大小不一致)。
   */
  private handleHeadRequest(resource: InternalModelResource): ResourceHandleResult {
    const publicResource: WebModelResource = resource.publicResource;
    const cachePath: string = resource.cachePath;

    // Phase 1D-2C-1: 上报 PROVIDER_HEAD 阶段
    this.emitDiagnostic(
      VrmRuntimeStage.PROVIDER_HEAD,
      '',
      'HEAD request received',
      'HEAD',
      0,
      publicResource.mimeType,
      publicResource.size
    );

    try {
      // 验证文件仍存在且大小一致(不打开文件)
      const stat: fileIo.Stat = fileIo.statSync(cachePath);
      if (!stat.isFile) {
        const response: WebResourceResponse = this.createErrorResponse(
          500,
          'Internal Server Error',
          'Cache path is not a regular file'
        );
        this.emitDiagnostic(
          VrmRuntimeStage.PROVIDER_RESPONSE,
          ModelResourceErrorCode.RESOURCE_PATH_INVALID,
          'Cache path is not a regular file',
          'HEAD',
          500,
          '',
          0
        );
        return {
          response: response,
          errorCode: ModelResourceErrorCode.RESOURCE_PATH_INVALID,
          errorMessage: 'Cache path is not a regular file'
        };
      }
      if (stat.size !== publicResource.size) {
        const response: WebResourceResponse = this.createErrorResponse(
          500,
          'Internal Server Error',
          `Size mismatch (expected ${publicResource.size}, actual ${stat.size})`
        );
        this.emitDiagnostic(
          VrmRuntimeStage.PROVIDER_RESPONSE,
          'RESOURCE_SIZE_CHANGED',
          `Size mismatch (expected ${publicResource.size}, actual ${stat.size})`,
          'HEAD',
          500,
          '',
          0
        );
        return {
          response: response,
          errorCode: ModelResourceErrorCode.RESOURCE_PATH_INVALID,
          errorMessage: `Size mismatch (expected ${publicResource.size}, actual ${stat.size})`
        };
      }

      // 构造 HEAD 响应(无 body)
      const response: WebResourceResponse = this.createHeadResponse(resource);
      Logger.debug(
        `[ArkWebModelResourceProvider] HEAD: id=${publicResource.id}, size=${publicResource.size}`
      );
      // Phase 1D-2C-1: 上报 PROVIDER_RESPONSE 200
      this.emitDiagnostic(
        VrmRuntimeStage.PROVIDER_RESPONSE,
        '',
        'HEAD 200 OK',
        'HEAD',
        200,
        publicResource.mimeType,
        publicResource.size
      );
      return {
        response: response,
        errorCode: '',
        errorMessage: ''
      };
    } catch (e) {
      const msg: string = e instanceof Error ? e.message : String(e);
      Logger.error(`[ArkWebModelResourceProvider] HEAD stat failed: ${msg}`);
      const response: WebResourceResponse = this.createErrorResponse(
        500,
        'Internal Server Error',
        `HEAD stat failed: ${msg}`
      );
      this.emitDiagnostic(
        VrmRuntimeStage.PROVIDER_RESPONSE,
        ModelResourceErrorCode.RESOURCE_OPEN_FAILED,
        `HEAD stat failed: ${msg}`,
        'HEAD',
        500,
        '',
        0
      );
      return {
        response: response,
        errorCode: ModelResourceErrorCode.RESOURCE_OPEN_FAILED,
        errorMessage: `HEAD stat failed: ${msg}`
      };
    }
  }

  /**
   * 处理 GET 请求(原 Phase 1D-2A 行为,FD 传输)。
   *
   * - 打开缓存文件(只读),获取 FD
   * - 构造 200 响应,设置响应头
   * - setResponseData(fd) — FD 所有权转移给 ArkWeb
   *
   * 失败时构造 500 错误响应,finally 关闭未转交的 FD。
   */
  private handleGetRequest(resource: InternalModelResource): ResourceHandleResult {
    const cachePath: string = resource.cachePath;
    const publicResource: WebModelResource = resource.publicResource;

    let file: fileIo.File | null = null;
    let fdTransferred: boolean = false;

    // Phase 1D-2C-1: 上报 PROVIDER_GET 阶段
    this.emitDiagnostic(
      VrmRuntimeStage.PROVIDER_GET,
      '',
      'GET request received',
      'GET',
      0,
      publicResource.mimeType,
      publicResource.size
    );

    try {
      // 打开缓存文件(只读),获取 FD
      file = fileIo.openSync(cachePath, fileIo.OpenMode.READ_ONLY);

      const response: WebResourceResponse = this.createGetResponse(resource);
      // 关键:setResponseData(number) 传 FD,FD 所有权转移给 ArkWeb
      // 应用侧不主动关闭此 FD(避免 double-close)
      response.setResponseData(file.fd);
      fdTransferred = true;

      Logger.debug(
        `[ArkWebModelResourceProvider] GET: id=${publicResource.id}, fd=${file.fd}, size=${publicResource.size}`
      );
      // Phase 1D-2C-1: 上报 PROVIDER_RESPONSE 200
      this.emitDiagnostic(
        VrmRuntimeStage.PROVIDER_RESPONSE,
        '',
        'GET 200 OK',
        'GET',
        200,
        publicResource.mimeType,
        publicResource.size
      );

      return {
        response: response,
        errorCode: '',
        errorMessage: ''
      };
    } catch (e) {
      const msg: string = e instanceof Error ? e.message : String(e);
      Logger.error(`[ArkWebModelResourceProvider] GET failed: ${msg}`);

      // 构造 500 错误响应(避免 Web 端无响应)
      const errorResponse: WebResourceResponse = this.createErrorResponse(
        500,
        'Internal Server Error',
        `Resource load failed: ${msg}`
      );
      // Phase 1D-2C-1: 上报 PROVIDER_RESPONSE 失败
      this.emitDiagnostic(
        VrmRuntimeStage.PROVIDER_RESPONSE,
        ModelResourceErrorCode.RESOURCE_OPEN_FAILED,
        `GET open file failed: ${msg}`,
        'GET',
        500,
        '',
        0
      );

      return {
        response: errorResponse,
        errorCode: ModelResourceErrorCode.RESOURCE_RESPONSE_FAILED,
        errorMessage: msg
      };
    } finally {
      // 仅在 FD 未转交时关闭(失败路径)
      // 成功路径下 FD 已交给 ArkWeb,不能关闭
      if (file !== null && !fdTransferred) {
        try {
          fileIo.closeSync(file);
        } catch (_e) {
          // 忽略关闭错误
        }
      }
    }
  }

  /**
   * 构造成功响应的公共 Header 数组(Phase 1D-2B-1 统一化,1D-2B-2 增加 CORS,1D-2C-2E-2A 增加自定义长度头)。
   *
   * 包含:
   * - Content-Type:资源 MIME
   * - Content-Length:资源大小(标准头,ArkWeb 实机可能重写为 0)
   * - X-ArkTavern-Content-Length:资源大小(Phase 1D-2C-2E-2A 自定义头,绕过标准头被重写)
   * - Cache-Control: no-store
   * - Accept-Ranges: none
   * - X-ArkTavern-Resource-Id:资源 opaque ID
   * - Access-Control-Allow-Origin: *(Phase 1D-2B-2,跨源读取)
   * - Access-Control-Expose-Headers: Content-Length, X-ArkTavern-Content-Length, X-ArkTavern-Resource-Id
   *   (Phase 1D-2B-2 + 1D-2C-2E-2A:Expose-Headers 必须包含自定义长度头,否则 fetch 不可读)
   * - X-Content-Type-Options: nosniff(Phase 1D-2B-2,安全)
   *
   * HEAD 与 GET 必须使用同一组成功响应头。
   * 标准 Content-Length 与自定义 X-ArkTavern-Content-Length 必须使用同一资源大小来源
   * (String(publicResource.size)),保证两端一致。
   *
   * 本阶段不新增 OPTIONS 请求处理(GET / HEAD 均为简单方法,请求不携带自定义头)。
   * 不设置 Access-Control-Allow-Credentials: true。
   *
   * @param resource 当前内部资源
   * @returns Header 数组(使用 SDK 实际字段 headerKey / headerValue)
   */
  private createSuccessHeaders(resource: InternalModelResource): Array<Header> {
    const publicResource: WebModelResource = resource.publicResource;
    const sizeString: string = String(publicResource.size);
    return [
      { headerKey: 'Content-Type', headerValue: publicResource.mimeType },
      { headerKey: 'Content-Length', headerValue: sizeString },
      { headerKey: 'X-ArkTavern-Content-Length', headerValue: sizeString },
      { headerKey: 'Cache-Control', headerValue: 'no-store' },
      { headerKey: 'Accept-Ranges', headerValue: 'none' },
      { headerKey: 'X-ArkTavern-Resource-Id', headerValue: publicResource.id },
      { headerKey: 'Access-Control-Allow-Origin', headerValue: '*' },
      { headerKey: 'Access-Control-Expose-Headers',
        headerValue: 'Content-Length, X-ArkTavern-Content-Length, X-ArkTavern-Resource-Id' },
      { headerKey: 'X-Content-Type-Options', headerValue: 'nosniff' }
    ];
  }

  /**
   * 构造 HEAD 成功响应(Phase 1D-2B-1)。
   *
   * - 200 OK
   * - MimeType 设置为资源 MIME
   * - 响应头通过 createSuccessHeaders 统一构造
   * - setResponseData 设置为空字符串(HEAD 响应无 body,但 SDK 要求设置 data)
   */
  private createHeadResponse(resource: InternalModelResource): WebResourceResponse {
    const response: WebResourceResponse = new WebResourceResponse();
    response.setResponseCode(200);
    response.setReasonMessage('OK');
    response.setResponseMimeType(resource.publicResource.mimeType);
    response.setResponseHeader(this.createSuccessHeaders(resource));
    // HEAD 响应无 body,设置空字符串(不打开文件,不传 FD)
    response.setResponseData('');
    return response;
  }

  /**
   * 构造 GET 成功响应(原 Phase 1D-2A 行为)。
   *
   * - 200 OK
   * - MimeType 设置为资源 MIME
   * - 响应头通过 createSuccessHeaders 统一构造
   * - 注意:本方法不调用 setResponseData,FD 由调用方设置
   */
  private createGetResponse(resource: InternalModelResource): WebResourceResponse {
    const response: WebResourceResponse = new WebResourceResponse();
    response.setResponseCode(200);
    response.setReasonMessage('OK');
    response.setResponseMimeType(resource.publicResource.mimeType);
    response.setResponseHeader(this.createSuccessHeaders(resource));
    // 注意:FD 由 handleGetRequest 调用 setResponseData(file.fd) 设置
    return response;
  }

  /**
   * 构造错误响应(Phase 1D-2B-1 统一化,1D-2B-2 增加 CORS,1D-2C-2E-2A 同步 Expose-Headers)。
   *
   * 错误响应同样需要 CORS 头,以便 JavaScript 端 fetch 能读取错误响应信息。
   * Expose-Headers 必须与成功响应保持一致(包含 X-ArkTavern-Content-Length),
   * 否则 fetch 在某些场景下无法读取自定义头。
   *
   * @param statusCode HTTP 状态码(如 405 / 416 / 500)
   * @param reason HTTP reason phrase(如 'Method Not Allowed')
   * @param message 错误消息(作为响应 body)
   * @returns WebResourceResponse(已设置状态码、MimeType、Header、Body)
   */
  private createErrorResponse(
    statusCode: number,
    reason: string,
    message: string
  ): WebResourceResponse {
    const response: WebResourceResponse = new WebResourceResponse();
    response.setResponseCode(statusCode);
    response.setReasonMessage(reason);
    response.setResponseMimeType('text/plain');
    response.setResponseData(message);
    response.setResponseHeader([
      { headerKey: 'Content-Type', headerValue: 'text/plain' },
      { headerKey: 'Cache-Control', headerValue: 'no-store' },
      { headerKey: 'Access-Control-Allow-Origin', headerValue: '*' },
      { headerKey: 'Access-Control-Expose-Headers',
        headerValue: 'Content-Length, X-ArkTavern-Content-Length, X-ArkTavern-Resource-Id' },
      { headerKey: 'X-Content-Type-Options', headerValue: 'nosniff' }
    ]);
    return response;
  }

  /**
   * 销毁 Provider。
   *
   * 之后所有 matchesRequest 返回 false,handleRequest 返回 null。
   * 不删除缓存文件(由 ArkWebFileImportController 负责)。
   * 不可恢复。
   */
  dispose(): void {
    if (this.disposed) {
      return;
    }
    this.disposed = true;
    this.state = ModelResourceState.DISPOSED;
    if (this.currentResource !== null) {
      Logger.debug(
        `[ArkWebModelResourceProvider] dispose: id=${this.currentResource.publicResource.id}`
      );
    }
    this.currentResource = null;
  }

  /** 获取当前状态(用于 UI 显示)。 */
  getState(): ModelResourceState {
    return this.state;
  }
}

// ============================================================================
// 内部工具函数
// ============================================================================

/**
 * 规范化路径(统一分隔符为 /,去除末尾分隔符)。
 *
 * @param path 原始路径
 * @returns 规范化后的路径
 */
function normalizePath(path: string): string {
  let normalized: string = path.replace(/\\/g, '/');
  // 合并连续分隔符
  normalized = normalized.replace(/\/+/g, '/');
  // 去除末尾分隔符
  if (normalized.length > 1 && normalized.endsWith('/')) {
    normalized = normalized.substring(0, normalized.length - 1);
  }
  return normalized;
}

/**
 * 判断 cachePath 是否位于 importDirectory 之下(目录穿越防护)。
 *
 * 检查规则:
 * - cachePath 必须以 importDirectory + '/' 开头(确保是子项,不是相似前缀目录)
 * - 不允许 cachePath === importDirectory(模型文件不能等于目录本身)
 *
 * @param cachePath 已规范化的缓存文件路径
 * @param importDirectory 已规范化的导入目录路径
 * @returns true 表示路径合法
 */
function isPathUnderDirectory(cachePath: string, importDirectory: string): boolean {
  if (cachePath === importDirectory) {
    return false;
  }
  const prefix: string = importDirectory + '/';
  return cachePath.startsWith(prefix);
}

/**
 * 检查路径中是否包含 '..' 路径段(目录穿越攻击防护)。
 *
 * @param path 已规范化的路径
 * @returns true 表示包含 '..' 段
 */
function containsTraversalSegments(path: string): boolean {
  // 检查 /../、/..、../、.. 等形式
  // 由于路径已规范化(分隔符统一为 /),只需检查 /.. 边界
  if (path.includes('/../')) {
    return true;
  }
  if (path.startsWith('../')) {
    return true;
  }
  if (path.endsWith('/..')) {
    return true;
  }
  if (path === '..') {
    return true;
  }
  return false;
}

/**
 * 生成不透明资源 ID。
 *
 * 格式:8 位 hex + '-' + 时间戳 base36
 * 示例:a3f2c9d1-l4x2z9q
 *
 * @returns 不透明 ID 字符串
 */
function generateOpaqueId(): string {
  // 使用 util.generateRandomUUID 生成 UUID,取前 8 位 hex
  const uuid: string = util.generateRandomUUID(false);
  const hexPart: string = uuid.replace(/-/g, '').substring(0, ModelResourceUrlConfig.OPAQUE_ID_HEX_LENGTH);
  const timestampPart: string = Date.now().toString(36);
  return `${hexPart}-${timestampPart}`;
}

/**
 * 检查请求头中是否包含 Range header。
 *
 * @param headers 请求头数组
 * @returns true 表示包含 Range header
 */
function hasRangeHeader(headers: Array<Header>): boolean {
  for (let i = 0; i < headers.length; i++) {
    if (headers[i].headerKey.toLowerCase() === 'range') {
      return true;
    }
  }
  return false;
}
