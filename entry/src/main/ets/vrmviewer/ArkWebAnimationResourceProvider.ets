import { Logger } from '../utils/Logger';
/**
 * ArkWebAnimationResourceProvider — VRMA 动画缓存资源提供者 (Phase 3A)
 *
 * 职责:
 * - 接收 ArkWebAnimationImportController 产出的 ImportedAnimationFile, 注册为受控资源
 * - 生成不透明资源 ID 与受控 URL (https://ark-tavern.local/animation/<resourceId>)
 * - 验证缓存路径安全性 (目录穿越防护)
 * - 响应 ArkWeb onInterceptRequest 回调
 *   - GET: 通过 FD 流式返回缓存文件
 *   - HEAD: 只返回响应头, 不打开文件, 不创建 FD
 *   - 其他方法: 405 Method Not Allowed
 * - 资源生命周期管理 (注册 / 替换 / 注销 / 销毁)
 *
 * 独立于模型 Provider:
 * - URL 前缀: /animation/ (不复用 /model/)
 * - 错误码: ANIMATION_RESOURCE_*
 * - 状态机: AnimationResourceState (不复用 ModelResourceState)
 *
 * 安全约束 (与模型 Provider 一致):
 * - WebAnimationResource 不包含 cachePath / sourceUri
 * - URL 中只包含 resourceId (不包含 cachePath / displayName / 原始文件名 / URI)
 * - matchesRequest 拒绝非法 host / scheme / 含路径穿越的 URL
 * - 缓存路径必须位于 animationDirectory 之下, 且不含 '..'
 * - dispose 后所有请求返回 null (放行)
 * - HEAD 请求不打开文件描述符
 *
 * 响应头 (AGENTS.md Phase 3A §十三):
 * - Content-Type: model/gltf-binary
 * - Access-Control-Allow-Origin: *
 * - Access-Control-Expose-Headers: Content-Length, X-ArkTavern-Content-Length, X-ArkTavern-Animation-Resource-Id
 * - X-ArkTavern-Content-Length: <真实字节数>
 * - X-ArkTavern-Animation-Resource-Id: <resourceId>
 *
 * Provider 不得加载整个 VRMA 到 ArkTS 字符串或 Base64。
 * 使用 FD 流式传输 (与模型 Provider 一致)。
 *
 * Reference:
 * - ArkWebModelResourceProvider (Phase 1D-2A / 1D-2B-1): 复用 FD 传输 / HEAD / 路径防护模式
 * - AGENTS.md Phase 3A §十二~§十三 规范
 */

import { fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import {
  ImportedAnimationFile,
  ANIMATION_CACHE_SUBDIR,
  VRMA_MIME_TYPE
} from './ArkWebAnimationImportController';
import { ArkWebAvatarAnimationAsset } from './ArkWebAvatarAssetTypes';

/**
 * 动画资源状态机 (与 ModelResourceState 解耦)。
 */
export enum AnimationResourceState {
  EMPTY = 'EMPTY',
  READY = 'READY',
  DISPOSED = 'DISPOSED'
}

/**
 * 动画资源错误码 (AGENTS.md Phase 3A §十二)。
 */
export class AnimationResourceErrorCode {
  public static readonly RESOURCE_PROVIDER_DISPOSED: string = 'ANIMATION_RESOURCE_PROVIDER_DISPOSED';
  public static readonly RESOURCE_ID_INVALID: string = 'ANIMATION_RESOURCE_ID_INVALID';
  public static readonly RESOURCE_NOT_FOUND: string = 'ANIMATION_RESOURCE_NOT_FOUND';
  public static readonly METHOD_NOT_ALLOWED: string = 'ANIMATION_METHOD_NOT_ALLOWED';
  public static readonly RESOURCE_STALE: string = 'ANIMATION_RESOURCE_STALE';
  public static readonly RESOURCE_OPEN_FAILED: string = 'ANIMATION_RESOURCE_OPEN_FAILED';
  public static readonly RESOURCE_PATH_INVALID: string = 'ANIMATION_RESOURCE_PATH_INVALID';
  public static readonly RESOURCE_RESPONSE_FAILED: string = 'ANIMATION_RESOURCE_RESPONSE_FAILED';
}

/**
 * 资源 URL 设计常量。
 *
 * 格式: https://ark-tavern.local/animation/<resourceId>
 * 独立于模型 URL (https://ark-tavern.local/model/<opaque-id>)。
 */
export class AnimationResourceUrlConfig {
  public static readonly RESOURCE_SCHEME: string = 'https';
  public static readonly RESOURCE_HOST: string = 'ark-tavern.local';
  public static readonly RESOURCE_PATH_PREFIX: string = '/animation/';
  public static readonly RESOURCE_URL_PREFIX: string =
    `${AnimationResourceUrlConfig.RESOURCE_SCHEME}://${AnimationResourceUrlConfig.RESOURCE_HOST}${AnimationResourceUrlConfig.RESOURCE_PATH_PREFIX}`;
}

/**
 * 公共动画资源 (可安全传给 JavaScript)。
 *
 * 不包含: cachePath / sourceUri / 原始 URI。
 */
export interface WebAnimationResource {
  /** 资源 ID (与缓存文件名一致, 不透明)。 */
  resourceId: string;
  /** 受控内部 URL: https://ark-tavern.local/animation/<resourceId>。 */
  resourceUrl: string;
  /** 用户可读显示名。 */
  displayName: string;
  /** MIME 类型 (固定为 model/gltf-binary)。 */
  mimeType: string;
  /** 文件字节数。 */
  size: number;
  /** 扩展名 (固定为 'vrma')。 */
  extension: string;
  /** 创建时间戳 (ms)。 */
  createdAt: number;
}

/**
 * 内部动画资源 (含 cachePath, 仅 ArkTS 内部使用)。
 */
interface InternalAnimationResource {
  publicResource: WebAnimationResource;
  cachePath: string;
}

/**
 * 资源响应构造结果 (内部使用, 与 ModelResourceProvider 一致)。
 */
interface AnimationResourceHandleResult {
  response: WebResourceResponse | null;
  errorCode: string;
  errorMessage: string;
}

/**
 * VRMA 动画缓存资源提供者。
 *
 * 使用方式:
 * 1. 页面 aboutToAppear 创建实例, 传入 context.cacheDir
 * 2. ArkWebAnimationImportController.pickAnimationFile() 成功后调用 registerFile(file)
 * 3. Web 组件 onInterceptRequest 回调中调用 matchesRequest / handleRequest
 * 4. 页面 aboutToDisappear 调用 dispose()
 *
 * 状态机:
 *   EMPTY → READY        (registerFile 成功)
 *   READY → READY        (registerFile 替换, 旧 URL 失效)
 *   READY → EMPTY        (unregisterCurrent)
 *   任意 → DISPOSED      (dispose, 不可恢复)
 */
export class ArkWebAnimationResourceProvider {
  /** 当前资源状态。 */
  private state: AnimationResourceState = AnimationResourceState.EMPTY;
  /** 当前注册的资源 (含 cachePath, 仅内部使用)。 */
  private currentResource: InternalAnimationResource | null = null;
  /** 是否已销毁。 */
  private disposed: boolean = false;
  /** 受控缓存目录 (规范化后的绝对路径)。 */
  private readonly animationDirectory: string;
  /** 持久化根目录 (filesDir/avatar-assets, Phase 3C-1)。空字符串表示未配置。 */
  private persistentRootDir: string = '';

  /**
   * 构造函数。
   *
   * @param cacheDir 应用 cacheDir (通常为 context.cacheDir)
   */
  constructor(cacheDir: string) {
    const rawDir: string = `${cacheDir}/${ANIMATION_CACHE_SUBDIR}`;
    this.animationDirectory = normalizePath(rawDir);
  }

  /**
   * 配置持久化根目录 (filesDir/avatar-assets) (Phase 3C-1)。
   *
   * 配置后, registerPersistentAsset 可接受位于 <persistentRootDir>/animations/ 下的文件。
   * 不影响原有 registerFile 对 cacheDir 的处理。
   *
   * @param assetsRootDir 资产根目录 (来自 ArkWebAvatarAssetLibrary.getAssetsRootDir())
   */
  setPersistentRootDir(assetsRootDir: string): void {
    if (assetsRootDir.length === 0) {
      this.persistentRootDir = '';
      return;
    }
    this.persistentRootDir = normalizePath(assetsRootDir);
    Logger.debug(`[ArkWebAnimationResourceProvider] persistentRootDir=${this.persistentRootDir}`);
  }

  /**
   * 注册动画文件为受控资源。
   *
   * 步骤 (与模型 Provider 一致):
   * 1. 检查 Provider 未销毁
   * 2. 验证 file 非空
   * 3. 验证 cachePath 位于 animationDirectory 下 (目录穿越防护)
   * 4. 验证文件存在且为普通文件
   * 5. 验证文件大小与 file.size 一致
   * 6. 构造 WebAnimationResource (使用 file.resourceId, 不重新生成)
   * 7. 原子替换 currentResource
   *
   * @param file ArkWebAnimationImportController 产出的导入文件
   * @returns 公共资源接口 (可安全传给 JavaScript); 失败抛出 Error
   */
  registerFile(file: ImportedAnimationFile): WebAnimationResource {
    if (this.disposed || this.state === AnimationResourceState.DISPOSED) {
      throw new Error(AnimationResourceErrorCode.RESOURCE_PROVIDER_DISPOSED);
    }

    if (!file) {
      throw new Error(AnimationResourceErrorCode.RESOURCE_NOT_FOUND);
    }

    // 路径安全验证
    const normalizedCachePath: string = normalizePath(file.cachePath);
    if (!isPathUnderDirectory(normalizedCachePath, this.animationDirectory)) {
      throw new Error(`${AnimationResourceErrorCode.RESOURCE_PATH_INVALID}: cachePath not under animationDirectory`);
    }
    if (containsTraversalSegments(normalizedCachePath)) {
      throw new Error(`${AnimationResourceErrorCode.RESOURCE_PATH_INVALID}: cachePath contains '..' segment`);
    }

    // 文件存在性 + 大小校验 (同步 stat)
    let stat: fileIo.Stat;
    try {
      stat = fileIo.statSync(normalizedCachePath);
    } catch (e) {
      const msg: string = e instanceof Error ? e.message : String(e);
      throw new Error(`${AnimationResourceErrorCode.RESOURCE_OPEN_FAILED}: stat failed: ${msg}`);
    }
    if (!stat.isFile) {
      throw new Error(`${AnimationResourceErrorCode.RESOURCE_PATH_INVALID}: not a regular file`);
    }
    if (stat.size !== file.size) {
      throw new Error(
        `${AnimationResourceErrorCode.RESOURCE_PATH_INVALID}: size mismatch (expected ${file.size}, actual ${stat.size})`
      );
    }

    // 构造受控 URL (使用 file.resourceId, 不重新生成)
    const resourceUrl: string = buildAnimationResourceUrl(file.resourceId);

    // 构造公共资源 (不含 cachePath / sourceUri)
    const publicResource: WebAnimationResource = {
      resourceId: file.resourceId,
      resourceUrl: resourceUrl,
      displayName: file.displayName,
      mimeType: file.mimeType,
      size: file.size,
      extension: file.extension,
      createdAt: Date.now()
    };

    // 原子替换当前资源 (旧 URL 立即失效)
    const internalResource: InternalAnimationResource = {
      publicResource: publicResource,
      cachePath: normalizedCachePath
    };
    this.currentResource = internalResource;
    this.state = AnimationResourceState.READY;

    Logger.debug(
      `[ArkWebAnimationResourceProvider] registerFile: resourceId=${file.resourceId}, size=${file.size}, mimeType=${file.mimeType}`
    );

    return publicResource;
  }

  /**
   * 注册持久化动画资产为受控资源 (Phase 3C-1)。
   *
   * 与 registerFile 的区别:
   * - 输入为 ArkWebAvatarAnimationAsset (来自 library.json)
   * - 文件位于 <persistentRootDir>/animations/ 下 (filesDir)
   * - 通过 assetLibrary.resolveAbsolutePath 由调用方提供绝对路径
   * - 不依赖 ImportedAnimationFile / cachePath
   *
   * 步骤:
   * 1. 检查 Provider 未销毁
   * 2. 验证 persistentRootDir 已配置
   * 3. 验证 absolutePath 位于 <persistentRootDir>/animations/ 下 (目录穿越防护)
   * 4. 验证文件存在且为普通文件
   * 5. 验证文件大小与 asset.byteLength 一致
   * 6. 构造 WebAnimationResource (使用 asset.resourceId)
   * 7. 原子替换 currentResource
   *
   * @param asset 持久化动画资产
   * @param absolutePath 由 PersistentAnimationStore.resolveAbsolutePath 返回的绝对路径
   * @returns 公共资源接口; 失败抛出 Error
   */
  registerPersistentAsset(asset: ArkWebAvatarAnimationAsset, absolutePath: string): WebAnimationResource {
    if (this.disposed || this.state === AnimationResourceState.DISPOSED) {
      throw new Error(AnimationResourceErrorCode.RESOURCE_PROVIDER_DISPOSED);
    }
    if (this.persistentRootDir.length === 0) {
      throw new Error(`${AnimationResourceErrorCode.RESOURCE_PATH_INVALID}: persistentRootDir not configured`);
    }
    // 受控动画持久目录: <persistentRootDir>/animations
    const persistentAnimDir: string = `${this.persistentRootDir}/animations`;

    const normalizedPath: string = normalizePath(absolutePath);
    if (!isPathUnderDirectory(normalizedPath, persistentAnimDir)) {
      throw new Error(`${AnimationResourceErrorCode.RESOURCE_PATH_INVALID}: path not under persistent animations dir`);
    }
    if (containsTraversalSegments(normalizedPath)) {
      throw new Error(`${AnimationResourceErrorCode.RESOURCE_PATH_INVALID}: path contains '..' segment`);
    }

    // 文件存在性 + 大小校验
    let stat: fileIo.Stat;
    try {
      stat = fileIo.statSync(normalizedPath);
    } catch (e) {
      const msg: string = e instanceof Error ? e.message : String(e);
      throw new Error(`${AnimationResourceErrorCode.RESOURCE_OPEN_FAILED}: stat failed: ${msg}`);
    }
    if (!stat.isFile) {
      throw new Error(`${AnimationResourceErrorCode.RESOURCE_PATH_INVALID}: not a regular file`);
    }
    if (stat.size !== asset.byteLength) {
      throw new Error(
        `${AnimationResourceErrorCode.RESOURCE_PATH_INVALID}: size mismatch (expected ${asset.byteLength}, actual ${stat.size})`
      );
    }

    // 构造受控 URL (使用 asset.resourceId)
    const resourceUrl: string = buildAnimationResourceUrl(asset.resourceId);

    const publicResource: WebAnimationResource = {
      resourceId: asset.resourceId,
      resourceUrl: resourceUrl,
      displayName: asset.displayName,
      mimeType: asset.mimeType,
      size: asset.byteLength,
      extension: 'vrma',
      createdAt: asset.createdAt
    };

    const internalResource: InternalAnimationResource = {
      publicResource: publicResource,
      cachePath: normalizedPath
    };
    this.currentResource = internalResource;
    this.state = AnimationResourceState.READY;

    Logger.debug(
      `[ArkWebAnimationResourceProvider] registerPersistentAsset: resourceId=${asset.resourceId}, size=${asset.byteLength}`
    );

    return publicResource;
  }

  /**
   * 注销当前资源 (不删除缓存文件)。
   *
   * 之后 matchesRequest 返回 false, handleRequest 返回 null。
   * 缓存文件删除仍由 ArkWebAnimationImportController.clearCurrentFile() 负责。
   */
  unregisterCurrent(): void {
    if (this.disposed) {
      return;
    }
    if (this.currentResource !== null) {
      Logger.debug(
        `[ArkWebAnimationResourceProvider] unregister: resourceId=${this.currentResource.publicResource.resourceId}`
      );
    }
    this.currentResource = null;
    this.state = AnimationResourceState.EMPTY;
  }

  /**
   * 获取当前公共资源 (可安全传给 JavaScript)。
   *
   * @returns 当前资源; 无资源或已销毁返回 null
   */
  getCurrentResource(): WebAnimationResource | null {
    if (this.disposed || this.state !== AnimationResourceState.READY) {
      return null;
    }
    if (this.currentResource === null) {
      return null;
    }
    return this.currentResource.publicResource;
  }

  /**
   * 判断 URL 是否为当前注册资源的 URL (供 onInterceptRequest 使用)。
   *
   * 仅匹配当前活动资源的 resourceId, 旧资源 URL 一律返回 false。
   *
   * @param url 待判断的 URL
   * @returns true 表示需要拦截; false 表示放行
   */
  matchesRequest(url: string): boolean {
    if (this.disposed || this.state !== AnimationResourceState.READY) {
      return false;
    }
    if (this.currentResource === null) {
      return false;
    }
    if (!isAnimationResourceUrl(url)) {
      return false;
    }
    const requestResourceId: string | null = extractResourceIdFromUrl(url);
    if (requestResourceId === null) {
      return false;
    }
    return requestResourceId === this.currentResource.publicResource.resourceId;
  }

  /**
   * 处理资源请求, 构造 WebResourceResponse。
   *
   * - GET: 打开文件, FD 传输
   * - HEAD: 不打开文件, 只返回响应头
   * - 其他: 405 Method Not Allowed
   *
   * @param url 请求 URL
   * @param method HTTP 方法 (GET / HEAD / POST 等, 大小写不敏感)
   * @param requestHeaders 请求头数组
   * @returns 处理结果 (response 或 error)
   */
  handleRequest(
    url: string,
    method: string,
    requestHeaders: Array<Header>
  ): AnimationResourceHandleResult {
    if (this.disposed || this.state === AnimationResourceState.DISPOSED) {
      return {
        response: null,
        errorCode: AnimationResourceErrorCode.RESOURCE_PROVIDER_DISPOSED,
        errorMessage: 'Provider disposed'
      };
    }
    if (this.state !== AnimationResourceState.READY || this.currentResource === null) {
      return {
        response: null,
        errorCode: AnimationResourceErrorCode.RESOURCE_NOT_FOUND,
        errorMessage: 'No active animation resource'
      };
    }
    if (!this.matchesRequest(url)) {
      return {
        response: null,
        errorCode: AnimationResourceErrorCode.RESOURCE_STALE,
        errorMessage: 'URL does not match current animation resource'
      };
    }

    const upperMethod: string = method.toUpperCase();

    // HEAD 路径: 不打开文件, 只返回响应头
    if (upperMethod === 'HEAD') {
      return this.handleHeadRequest(this.currentResource);
    }

    // 非 GET 方法: 405 Method Not Allowed
    if (upperMethod !== 'GET') {
      const response: WebResourceResponse = this.createErrorResponse(
        405,
        'Method Not Allowed',
        `Method ${method} not allowed`
      );
      response.setResponseHeader([
        { headerKey: 'Content-Type', headerValue: 'text/plain' },
        { headerKey: 'Cache-Control', headerValue: 'no-store' },
        { headerKey: 'Allow', headerValue: 'GET, HEAD' },
        { headerKey: 'Access-Control-Allow-Origin', headerValue: '*' },
        { headerKey: 'Access-Control-Expose-Headers',
          headerValue: 'Content-Length, X-ArkTavern-Content-Length, X-ArkTavern-Animation-Resource-Id' },
        { headerKey: 'X-Content-Type-Options', headerValue: 'nosniff' }
      ]);
      return {
        response: response,
        errorCode: AnimationResourceErrorCode.METHOD_NOT_ALLOWED,
        errorMessage: `Method ${method} not allowed`
      };
    }

    // GET 路径: Range 请求检查 (本阶段不支持 Range, 与模型 Provider 一致)
    if (hasRangeHeader(requestHeaders)) {
      const response: WebResourceResponse = this.createErrorResponse(
        416,
        'Range Not Satisfiable',
        'Range requests are not supported'
      );
      return {
        response: response,
        errorCode: AnimationResourceErrorCode.RESOURCE_PATH_INVALID,
        errorMessage: 'Range requests not supported'
      };
    }

    return this.handleGetRequest(this.currentResource);
  }

  /**
   * 处理 HEAD 请求。
   *
   * - 不打开文件, 不创建 FD
   * - 通过 statSync 验证文件存在与大小一致
   * - 构造 200 响应, 只含响应头
   */
  private handleHeadRequest(resource: InternalAnimationResource): AnimationResourceHandleResult {
    const publicResource: WebAnimationResource = resource.publicResource;
    const cachePath: string = resource.cachePath;

    try {
      const stat: fileIo.Stat = fileIo.statSync(cachePath);
      if (!stat.isFile) {
        const response: WebResourceResponse = this.createErrorResponse(
          500,
          'Internal Server Error',
          'Cache path is not a regular file'
        );
        return {
          response: response,
          errorCode: AnimationResourceErrorCode.RESOURCE_PATH_INVALID,
          errorMessage: 'Cache path is not a regular file'
        };
      }
      if (stat.size !== publicResource.size) {
        const response: WebResourceResponse = this.createErrorResponse(
          500,
          'Internal Server Error',
          `Size mismatch (expected ${publicResource.size}, actual ${stat.size})`
        );
        return {
          response: response,
          errorCode: AnimationResourceErrorCode.RESOURCE_PATH_INVALID,
          errorMessage: `Size mismatch (expected ${publicResource.size}, actual ${stat.size})`
        };
      }

      const response: WebResourceResponse = this.createHeadResponse(resource);
      Logger.debug(
        `[ArkWebAnimationResourceProvider] HEAD: resourceId=${publicResource.resourceId}, size=${publicResource.size}`
      );
      return {
        response: response,
        errorCode: '',
        errorMessage: ''
      };
    } catch (e) {
      const msg: string = e instanceof Error ? e.message : String(e);
      Logger.error(`[ArkWebAnimationResourceProvider] HEAD stat failed: ${msg}`);
      const response: WebResourceResponse = this.createErrorResponse(
        500,
        'Internal Server Error',
        `HEAD stat failed: ${msg}`
      );
      return {
        response: response,
        errorCode: AnimationResourceErrorCode.RESOURCE_OPEN_FAILED,
        errorMessage: `HEAD stat failed: ${msg}`
      };
    }
  }

  /**
   * 处理 GET 请求 (FD 传输)。
   *
   * - 打开缓存文件 (只读), 获取 FD
   * - 构造 200 响应, 设置响应头
   * - setResponseData(fd) — FD 所有权转移给 ArkWeb
   */
  private handleGetRequest(resource: InternalAnimationResource): AnimationResourceHandleResult {
    const cachePath: string = resource.cachePath;
    const publicResource: WebAnimationResource = resource.publicResource;

    let file: fileIo.File | null = null;
    let fdTransferred: boolean = false;

    try {
      file = fileIo.openSync(cachePath, fileIo.OpenMode.READ_ONLY);

      const response: WebResourceResponse = this.createGetResponse(resource);
      response.setResponseData(file.fd);
      fdTransferred = true;

      Logger.debug(
        `[ArkWebAnimationResourceProvider] GET: resourceId=${publicResource.resourceId}, fd=${file.fd}, size=${publicResource.size}`
      );

      return {
        response: response,
        errorCode: '',
        errorMessage: ''
      };
    } catch (e) {
      const msg: string = e instanceof Error ? e.message : String(e);
      Logger.error(`[ArkWebAnimationResourceProvider] GET failed: ${msg}`);

      const errorResponse: WebResourceResponse = this.createErrorResponse(
        500,
        'Internal Server Error',
        `Animation resource load failed: ${msg}`
      );

      return {
        response: errorResponse,
        errorCode: AnimationResourceErrorCode.RESOURCE_RESPONSE_FAILED,
        errorMessage: msg
      };
    } finally {
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
   * 构造成功响应的公共 Header 数组 (AGENTS.md Phase 3A §十三)。
   *
   * 包含:
   * - Content-Type: model/gltf-binary
   * - Content-Length: 资源大小 (标准头, ArkWeb 实机可能重写为 0)
   * - X-ArkTavern-Content-Length: 资源大小 (自定义头, 绕过标准头被重写)
   * - Cache-Control: no-store
   * - Accept-Ranges: none
   * - X-ArkTavern-Animation-Resource-Id: resourceId
   * - Access-Control-Allow-Origin: *
   * - Access-Control-Expose-Headers: Content-Length, X-ArkTavern-Content-Length, X-ArkTavern-Animation-Resource-Id
   * - X-Content-Type-Options: nosniff
   */
  private createSuccessHeaders(resource: InternalAnimationResource): Array<Header> {
    const publicResource: WebAnimationResource = resource.publicResource;
    const sizeString: string = String(publicResource.size);
    return [
      { headerKey: 'Content-Type', headerValue: publicResource.mimeType },
      { headerKey: 'Content-Length', headerValue: sizeString },
      { headerKey: 'X-ArkTavern-Content-Length', headerValue: sizeString },
      { headerKey: 'Cache-Control', headerValue: 'no-store' },
      { headerKey: 'Accept-Ranges', headerValue: 'none' },
      { headerKey: 'X-ArkTavern-Animation-Resource-Id', headerValue: publicResource.resourceId },
      { headerKey: 'Access-Control-Allow-Origin', headerValue: '*' },
      { headerKey: 'Access-Control-Expose-Headers',
        headerValue: 'Content-Length, X-ArkTavern-Content-Length, X-ArkTavern-Animation-Resource-Id' },
      { headerKey: 'X-Content-Type-Options', headerValue: 'nosniff' }
    ];
  }

  /**
   * 构造 HEAD 成功响应。
   */
  private createHeadResponse(resource: InternalAnimationResource): WebResourceResponse {
    const response: WebResourceResponse = new WebResourceResponse();
    response.setResponseCode(200);
    response.setReasonMessage('OK');
    response.setResponseMimeType(resource.publicResource.mimeType);
    response.setResponseHeader(this.createSuccessHeaders(resource));
    response.setResponseData('');
    return response;
  }

  /**
   * 构造 GET 成功响应 (FD 由调用方设置)。
   */
  private createGetResponse(resource: InternalAnimationResource): WebResourceResponse {
    const response: WebResourceResponse = new WebResourceResponse();
    response.setResponseCode(200);
    response.setReasonMessage('OK');
    response.setResponseMimeType(resource.publicResource.mimeType);
    response.setResponseHeader(this.createSuccessHeaders(resource));
    return response;
  }

  /**
   * 构造错误响应。
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
        headerValue: 'Content-Length, X-ArkTavern-Content-Length, X-ArkTavern-Animation-Resource-Id' },
      { headerKey: 'X-Content-Type-Options', headerValue: 'nosniff' }
    ]);
    return response;
  }

  /**
   * 销毁 Provider。
   *
   * 之后所有 matchesRequest 返回 false, handleRequest 返回 null。
   * 不删除缓存文件 (由 ArkWebAnimationImportController 负责)。
   * 不可恢复。
   */
  dispose(): void {
    if (this.disposed) {
      return;
    }
    this.disposed = true;
    this.state = AnimationResourceState.DISPOSED;
    if (this.currentResource !== null) {
      Logger.debug(
        `[ArkWebAnimationResourceProvider] dispose: resourceId=${this.currentResource.publicResource.resourceId}`
      );
    }
    this.currentResource = null;
  }

  /** 获取当前状态 (用于 UI 显示)。 */
  getState(): AnimationResourceState {
    return this.state;
  }
}

// ============================================================================
// 内部工具函数 (与 ArkWebModelResourceProvider 保持一致)
// ============================================================================

/**
 * 规范化路径 (统一分隔符为 /, 去除末尾分隔符)。
 */
function normalizePath(path: string): string {
  let normalized: string = path.replace(/\\/g, '/');
  normalized = normalized.replace(/\/+/g, '/');
  if (normalized.length > 1 && normalized.endsWith('/')) {
    normalized = normalized.substring(0, normalized.length - 1);
  }
  return normalized;
}

/**
 * 判断 cachePath 是否位于 animationDirectory 之下 (目录穿越防护)。
 */
function isPathUnderDirectory(cachePath: string, animationDirectory: string): boolean {
  if (cachePath === animationDirectory) {
    return false;
  }
  const prefix: string = animationDirectory + '/';
  return cachePath.startsWith(prefix);
}

/**
 * 检查路径中是否包含 '..' 路径段。
 */
function containsTraversalSegments(path: string): boolean {
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
 * 构造受控动画资源 URL。
 *
 * @param resourceId 资源 ID
 * @returns 完整资源 URL, 如 https://ark-tavern.local/animation/<resourceId>
 */
export function buildAnimationResourceUrl(resourceId: string): string {
  return `${AnimationResourceUrlConfig.RESOURCE_URL_PREFIX}${resourceId}`;
}

/**
 * 判断 URL 是否为受控动画资源 URL。
 *
 * 判断条件:
 * 1. 以 RESOURCE_URL_PREFIX 开头
 * 2. prefix 之后还有内容 (即 resourceId 非空)
 * 3. resourceId 中不含路径分隔符 / 查询字符串 / fragment
 */
export function isAnimationResourceUrl(url: string): boolean {
  if (!url.startsWith(AnimationResourceUrlConfig.RESOURCE_URL_PREFIX)) {
    return false;
  }
  const resourceId: string = url.substring(AnimationResourceUrlConfig.RESOURCE_URL_PREFIX.length);
  if (resourceId.length === 0) {
    return false;
  }
  if (resourceId.includes('/') || resourceId.includes('?') || resourceId.includes('#')) {
    return false;
  }
  return true;
}

/**
 * 从受控资源 URL 提取 resourceId。
 */
export function extractResourceIdFromUrl(url: string): string | null {
  if (!isAnimationResourceUrl(url)) {
    return null;
  }
  return url.substring(AnimationResourceUrlConfig.RESOURCE_URL_PREFIX.length);
}

/**
 * 检查请求头中是否包含 Range header。
 */
function hasRangeHeader(headers: Array<Header>): boolean {
  for (let i = 0; i < headers.length; i++) {
    if (headers[i].headerKey.toLowerCase() === 'range') {
      return true;
    }
  }
  return false;
}
