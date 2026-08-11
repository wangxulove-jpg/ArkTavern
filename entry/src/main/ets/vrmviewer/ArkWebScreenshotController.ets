import { Logger } from '../utils/Logger';
/**
 * ArkWebScreenshotController — 3D 视口截图控制器(Phase 2A-3A)
 *
 * 职责:
 * - 调用 ArkWeb WebviewController.webPageSnapshot 捕获 3D 视口
 * - 使用 ImagePacker 将 PixelMap 编码为 PNG
 * - 原子写入应用缓存目录(<cacheDir>/vrm-screenshots/)
 * - 维护截图状态机(IDLE/CAPTURING/SAVING/READY/FAILED/DISPOSED)
 * - 竞态保护(captureGeneration)
 *
 * Route A — Native ArkWeb Snapshot:
 *   ArkTS → WebviewController.webPageSnapshot → PixelMap → ImagePacker.packing → PNG → 应用缓存文件
 *
 * 截图范围:
 * - 只包含 ArkWeb 渲染进程内容(Three.js Canvas / 背景 / 网格 / 模型 / 灯光 / 相机画面)
 * - 不包含 ArkUI 顶部导航栏 / 控制面板 / 右侧菜单 / 系统状态栏 / 调试文本 / Toast
 *
 * 安全约束:
 * - cachePath 只存在于 ArkTS 内部,不发送到 JavaScript,不显示在 UI
 * - 所有 PixelMap / ImagePacker / 文件描述符在 finally 中释放
 * - 截图操作不修改 Camera / Scene / Model / FrameLoop / SceneSettings
 *
 * Reference:
 * - HarmonyOS SDK API 23: @ohos.web.webview WebviewController.webPageSnapshot (API 12+)
 * - HarmonyOS SDK API 23: @ohos.multimedia.image PixelMap / ImagePacker
 * - HarmonyOS SDK API 23: @kit.CoreFileKit fileIo
 * - AGENTS.md Phase 2A-3A 规范
 *
 * 缓存生命周期策略:
 * - 页面销毁:保留已成功保存的截图文件(不主动删除)
 * - 截图失败:删除 .part 临时文件
 * - 新截图成功:保留之前成功截图(不删除历史)
 */

import { webview } from '@kit.ArkWeb';
import { image } from '@kit.ImageKit';
import { fileIo } from '@kit.CoreFileKit';
import {
  ArkWebViewerState,
  ScreenshotState,
  ScreenshotResult,
  ScreenshotErrorCode,
  createIdleScreenshotResult
} from './ArkWebVrmViewerTypes';

/** 截图缓存子目录名(位于 cacheDir 下)。 */
const SCREENSHOT_SUBDIR: string = 'vrm-screenshots';

/** PNG MIME 类型。 */
const PNG_MIME_TYPE: string = 'image/png';

/**
 * webPageSnapshot 回调响应(包装为 Promise 的返回类型)。
 *
 * 使用 interface 而非对象字面量类型,符合 ArkTS 规范(arkts-no-obj-literals-as-types)。
 * - success: 调用是否成功(回调无 err 且未抛异常)
 * - result: 成功时的 SnapshotResult(含 PixelMap)
 * - errorMessage: 失败时的错误描述
 */
interface SnapshotResponse {
  success: boolean;
  result?: webview.SnapshotResult;
  errorMessage?: string;
}

/**
 * ArkWeb 截图控制器。
 *
 * 使用方式:
 * 1. 页面 aboutToAppear 创建实例,传入 webviewController / cacheDir / viewerStateProvider
 * 2. 页面点击"截图"按钮调用 capture()
 * 3. 页面可通过 getState() / getResult() 查询状态
 * 4. 页面 aboutToDisappear 调用 dispose()
 */
export class ArkWebScreenshotController {
  /** ArkWeb WebviewController(由 ArkWebVrmViewerController 提供)。 */
  private webviewController: webview.WebviewController;
  /** 应用缓存目录(cacheDir)。 */
  private cacheDir: string;
  /** Viewer 状态查询回调(用于检查 Viewer 是否 READY)。 */
  private viewerStateProvider: () => ArkWebViewerState;

  /** 截图状态机。 */
  private state: ScreenshotState = ScreenshotState.IDLE;
  /** 最近一次截图结果。 */
  private lastResult: ScreenshotResult = createIdleScreenshotResult();

  /** 截图代次(防止过期结果提交)。 */
  private captureGeneration: number = 0;
  /** 是否正在截图(CAPTURING / SAVING 期间为 true)。 */
  private activeCapture: boolean = false;
  /** 控制器是否已销毁。 */
  private disposed: boolean = false;

  constructor(
    webviewController: webview.WebviewController,
    cacheDir: string,
    viewerStateProvider: () => ArkWebViewerState
  ) {
    this.webviewController = webviewController;
    this.cacheDir = cacheDir;
    this.viewerStateProvider = viewerStateProvider;
  }

  /** 获取当前截图状态。 */
  getState(): ScreenshotState {
    return this.state;
  }

  /** 获取最近一次截图结果(不含 cachePath 的安全副本,供 UI 显示)。 */
  getResult(): ScreenshotResult {
    return this.lastResult;
  }

  /** 检查是否可以发起新截图(IDLE 或 READY 或 FAILED 状态)。 */
  canCapture(): boolean {
    if (this.disposed) {
      return false;
    }
    return this.state === ScreenshotState.IDLE ||
           this.state === ScreenshotState.READY ||
           this.state === ScreenshotState.FAILED;
  }

  /**
   * 执行截图。
   *
   * 流程(Route A):
   * 1. 前置检查(disposed / Viewer READY / 不在忙碌状态)
   * 2. captureGeneration++,state = CAPTURING
   * 3. 调用 webPageSnapshot(回调式,包装为 Promise)
   * 4. 验证 SnapshotResult.status === true
   * 5. 验证 imagePixelMap 非空
   * 6. 获取 PixelMap.getImageInfo(width/height)
   * 7. state = SAVING
   * 8. ImagePacker.packing(pixelMap, { format: 'image/png', quality: 100 })
   * 9. 验证 PNG buffer 非空
   * 10. 生成文件名 ArkTavern-VRM-YYYYMMDD-HHmmss.png
   * 11. 创建 vrm-screenshots 目录
   * 12. 写入 .part 文件
   * 13. 验证写入字节数 > 0
   * 14. rename .part → finalPath
   * 15. state = READY
   * 16. finally: 释放 PixelMap + ImagePacker
   *
   * 失败时:
   * - state = FAILED
   * - 删除 .part 临时文件
   * - 记录 errorCode / errorMessage
   * - 不影响 ViewerState / ModelState / CameraState
   *
   * @returns 截图结果(成功返回 READY 状态,失败返回 FAILED 状态)
   */
  async capture(): Promise<ScreenshotResult> {
    // 1. 前置检查
    if (this.disposed) {
      return this.makeFailedResult(
        ScreenshotErrorCode.CONTROLLER_DISPOSED,
        'Screenshot controller disposed'
      );
    }
    if (this.activeCapture) {
      return this.makeFailedResult(
        ScreenshotErrorCode.IN_PROGRESS,
        'Screenshot already in progress'
      );
    }
    const viewerState: ArkWebViewerState = this.viewerStateProvider();
    if (viewerState !== ArkWebViewerState.READY) {
      return this.makeFailedResult(
        ScreenshotErrorCode.VIEWER_NOT_READY,
        `Viewer not ready, current state: ${viewerState}`
      );
    }

    // 2. 进入 CAPTURING
    this.captureGeneration++;
    const generation: number = this.captureGeneration;
    this.activeCapture = true;
    this.state = ScreenshotState.CAPTURING;

    let pixelMap: image.PixelMap | null = null;
    let imagePacker: image.ImagePacker | null = null;
    let partPath: string = '';

    try {
      // 3. 调用 webPageSnapshot(回调式,包装为 Promise)
      const snapshotResponse = await this.callWebPageSnapshot();

      // 检查代次是否过期(可能在异步等待期间被 dispose 或新截图覆盖)
      if (generation !== this.captureGeneration || this.disposed) {
        return this.makeFailedResult(
          ScreenshotErrorCode.STALE,
          'Screenshot generation stale during capture'
        );
      }

      // 验证 webPageSnapshot 调用成功
      if (!snapshotResponse.success || !snapshotResponse.result) {
        return this.makeFailedResult(
          ScreenshotErrorCode.SNAPSHOT_CALL_FAILED,
          snapshotResponse.errorMessage || 'webPageSnapshot returned no result'
        );
      }

      const snapshotResult: webview.SnapshotResult = snapshotResponse.result;

      // 4. 验证 SnapshotResult.status
      if (snapshotResult.status !== true) {
        return this.makeFailedResult(
          ScreenshotErrorCode.SNAPSHOT_STATUS_FALSE,
          'WebPageSnapshot returned status=false (width/height=0, map empty)'
        );
      }

      // 5. 验证 imagePixelMap 非空
      pixelMap = snapshotResult.imagePixelMap ?? null;
      if (!pixelMap) {
        return this.makeFailedResult(
          ScreenshotErrorCode.PIXELMAP_EMPTY,
          'SnapshotResult.imagePixelMap is null or undefined'
        );
      }

      // 6. 获取 PixelMap.getImageInfo(width/height)
      let imgWidth: number = 0;
      let imgHeight: number = 0;
      try {
        const imageInfo: image.ImageInfo = await pixelMap.getImageInfo();
        imgWidth = imageInfo.size.width;
        imgHeight = imageInfo.size.height;
      } catch (e) {
        const msg = e instanceof Error ? e.message : String(e);
        Logger.warn('[ArkWebScreenshotController] getImageInfo failed: ' + msg);
        // 不致命,继续用 0 作为尺寸
      }

      // 7. 进入 SAVING
      this.state = ScreenshotState.SAVING;

      // 8. ImagePacker.packing(pixelMap, { format: 'image/png', quality: 100 })
      imagePacker = image.createImagePacker();
      const packOptions: image.PackingOption = {
        format: PNG_MIME_TYPE,
        quality: 100
      };
      const pngBuffer: ArrayBuffer = await imagePacker.packing(pixelMap, packOptions);

      // 9. 验证 PNG buffer 非空
      if (!pngBuffer || pngBuffer.byteLength === 0) {
        return this.makeFailedResult(
          ScreenshotErrorCode.PNG_BUFFER_EMPTY,
          'ImagePacker.packing returned empty buffer'
        );
      }

      // 10. 生成文件名 ArkTavern-VRM-YYYYMMDD-HHmmss.png
      const fileName: string = this.generateFileName();
      const screenshotDir: string = `${this.cacheDir}/${SCREENSHOT_SUBDIR}`;
      const finalPath: string = `${screenshotDir}/${fileName}`;
      partPath = `${finalPath}.part`;

      // 11. 创建 vrm-screenshots 目录
      try {
        await fileIo.mkdir(screenshotDir, true);
      } catch (e) {
        // 目录可能已存在,忽略错误
        Logger.debug('[ArkWebScreenshotController] mkdir (may already exist): ' +
          (e instanceof Error ? e.message : String(e)));
      }

      // 12. 写入 .part 文件
      let targetFile: fileIo.File | null = null;
      try {
        targetFile = await fileIo.open(partPath, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE);
        const bytesWritten: number = await fileIo.write(targetFile.fd, pngBuffer);
        if (bytesWritten !== pngBuffer.byteLength) {
          return this.makeFailedResult(
            ScreenshotErrorCode.FILE_WRITE_FAILED,
            `File write incomplete: written=${bytesWritten}, expected=${pngBuffer.byteLength}`
          );
        }
      } finally {
        if (targetFile) {
          try {
            await fileIo.close(targetFile);
          } catch (e) {
            Logger.warn('[ArkWebScreenshotController] close .part failed: ' +
              (e instanceof Error ? e.message : String(e)));
          }
        }
      }

      // 13. 验证写入字节数 > 0(通过 stat)
      try {
        const stat: fileIo.Stat = await fileIo.stat(partPath);
        if (stat.size === 0) {
          return this.makeFailedResult(
            ScreenshotErrorCode.FILE_EMPTY,
            'Screenshot .part file is empty after write'
          );
        }
      } catch (e) {
        const msg = e instanceof Error ? e.message : String(e);
        return this.makeFailedResult(
          ScreenshotErrorCode.FILE_WRITE_FAILED,
          `Failed to stat .part file: ${msg}`
        );
      }

      // 14. rename .part → finalPath
      try {
        await fileIo.rename(partPath, finalPath);
      } catch (e) {
        const msg = e instanceof Error ? e.message : String(e);
        return this.makeFailedResult(
          ScreenshotErrorCode.FILE_RENAME_FAILED,
          `Failed to rename .part to final: ${msg}`
        );
      }

      // 15. state = READY,提交结果
      const result: ScreenshotResult = {
        state: ScreenshotState.READY,
        fileName: fileName,
        cachePath: finalPath,
        mimeType: PNG_MIME_TYPE,
        width: imgWidth,
        height: imgHeight,
        byteLength: pngBuffer.byteLength,
        createdAt: Date.now(),
        errorCode: '',
        errorMessage: ''
      };
      this.lastResult = result;
      this.state = ScreenshotState.READY;
      this.activeCapture = false;
      Logger.debug('[ArkWebScreenshotController] screenshot saved: ' + fileName +
        ` (${imgWidth}x${imgHeight}, ${pngBuffer.byteLength} bytes)`);
      return result;
    } catch (e) {
      const msg = e instanceof Error ? e.message : String(e);
      Logger.error('[ArkWebScreenshotController] capture failed: ' + msg);
      // 清理 .part 临时文件
      if (partPath) {
        try {
          await fileIo.unlink(partPath);
        } catch (unlinkErr) {
          // 忽略清理失败
        }
      }
      return this.makeFailedResult(
        ScreenshotErrorCode.EXCEPTION,
        `Screenshot capture exception: ${msg}`
      );
    } finally {
      // 16. 释放 PixelMap / ImagePacker
      if (pixelMap) {
        try {
          await pixelMap.release();
        } catch (e) {
          Logger.warn('[ArkWebScreenshotController] pixelMap.release failed: ' +
            (e instanceof Error ? e.message : String(e)));
        }
      }
      if (imagePacker) {
        try {
          imagePacker.release();
        } catch (e) {
          Logger.warn('[ArkWebScreenshotController] imagePacker.release failed: ' +
            (e instanceof Error ? e.message : String(e)));
        }
      }
      // 确保 activeCapture 被清除(即使异常路径)
      this.activeCapture = false;
    }
  }

  /**
   * 调用 WebviewController.webPageSnapshot(回调式,包装为 Promise)。
   *
   * webPageSnapshot 签名:
   *   webPageSnapshot(info: SnapshotInfo, callback: AsyncCallback<SnapshotResult>): void
   *
   * SnapshotInfo:
   *   - id?: string (可选,用于多 Web 组件场景)
   *   - size?: SizeOptions (可选,最大 16000x16000,默认使用 Web 组件实际大小)
   *
   * 本实现不传 id 和 size,使用默认 Web 组件实际大小。
   *
   * 返回 SnapshotResponse 而非 reject,避免 BusinessError 类型兼容性问题。
   */
  private callWebPageSnapshot(): Promise<SnapshotResponse> {
    return new Promise<SnapshotResponse>((resolve) => {
      try {
        const info: webview.SnapshotInfo = {};
        this.webviewController.webPageSnapshot(info, (err: BusinessError, result: webview.SnapshotResult) => {
          if (err) {
            const failResponse: SnapshotResponse = {
              success: false,
              errorMessage: err.message
            };
            resolve(failResponse);
            return;
          }
          const okResponse: SnapshotResponse = {
            success: true,
            result: result
          };
          resolve(okResponse);
        });
      } catch (e) {
        const msg: string = e instanceof Error ? e.message : String(e);
        const failResponse: SnapshotResponse = {
          success: false,
          errorMessage: `webPageSnapshot call failed: ${msg}`
        };
        resolve(failResponse);
      }
    });
  }

  /**
   * 生成截图文件名: ArkTavern-VRM-YYYYMMDD-HHmmss.png
   */
  private generateFileName(): string {
    const now: Date = new Date();
    const yyyy: string = String(now.getFullYear());
    const mm: string = String(now.getMonth() + 1).padStart(2, '0');
    const dd: string = String(now.getDate()).padStart(2, '0');
    const hh: string = String(now.getHours()).padStart(2, '0');
    const mi: string = String(now.getMinutes()).padStart(2, '0');
    const ss: string = String(now.getSeconds()).padStart(2, '0');
    return `ArkTavern-VRM-${yyyy}${mm}${dd}-${hh}${mi}${ss}.png`;
  }

  /**
   * 构造失败结果并更新状态。
   */
  private makeFailedResult(errorCode: string, errorMessage: string): ScreenshotResult {
    const result: ScreenshotResult = {
      state: ScreenshotState.FAILED,
      fileName: '',
      cachePath: '',
      mimeType: PNG_MIME_TYPE,
      width: 0,
      height: 0,
      byteLength: 0,
      createdAt: Date.now(),
      errorCode: errorCode,
      errorMessage: errorMessage
    };
    this.lastResult = result;
    this.state = ScreenshotState.FAILED;
    this.activeCapture = false;
    Logger.warn(`[ArkWebScreenshotController] screenshot failed: ${errorCode} - ${errorMessage}`);
    return result;
  }

  /**
   * 销毁控制器。
   *
   * - 使 captureGeneration 失效
   * - 标记 disposed
   * - 不删除已保存的截图文件
   */
  dispose(): void {
    if (this.disposed) {
      return;
    }
    Logger.debug('[ArkWebScreenshotController] dispose() called');
    this.disposed = true;
    this.captureGeneration++;
    this.activeCapture = false;
    this.state = ScreenshotState.DISPOSED;
  }
}

/**
 * BusinessError 类型(与 @ohos.base.BusinessError 一致)。
 * 用于 webPageSnapshot 回调的 err 参数。
 */
interface BusinessError {
  code: number;
  message: string;
}
