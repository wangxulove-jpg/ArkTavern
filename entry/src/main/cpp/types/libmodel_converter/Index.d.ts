/**
 * meshopt GLB 解码器 NAPI 模块类型声明
 * T-3D.6C-C 阶段 3
 *
 * 模块名: model_converter (nm_modname)
 * 包名: libmodel_converter.so
 * ArkTS 通过 import { decodeMeshoptGlb } from 'libmodel_converter.so' 引用
 */

/**
 * meshopt 解码结果。
 */
export interface MeshoptDecodeResult {
  /** 是否解码成功 */
  success: boolean;
  /** 输出 GLB 文件路径(成功时非空) */
  outputPath: string;
  /** 解码的 bufferView 数量 */
  decodedBufferViewCount: number;
  /** 原始扩展列表 */
  sourceExtensions: string[];
  /** 解码后剩余的扩展列表 */
  remainingExtensions: string[];
  /** 警告信息 */
  warnings: string[];
  /** 错误代码 */
  errorCode: string;
  /** 错误信息 */
  errorMessage: string;
}

/**
 * 异步解码 GLB 文件中的 EXT_meshopt_compression 扩展。
 *
 * 始终 resolve:通过 result.success 判断成败,失败时 errorMessage/errorCode 非空。
 * 仅在 NAPI 调用本身异常(如参数类型错误)时才会 reject。
 *
 * @param inputPath 输入 GLB 文件路径
 * @param outputPath 输出标准 GLB 文件路径
 * @returns 解码结果 Promise
 */
export const decodeMeshoptGlb: (inputPath: string, outputPath: string) => Promise<MeshoptDecodeResult>;

/**
 * T-3D.6C-C3 Debug: 文件复制结果。
 */
export interface FileCopyResult {
  /** 是否复制成功 */
  success: boolean;
  /** 错误信息(成功时为空) */
  errorMessage: string;
  /** 已复制字节数 */
  bytesCopied: number;
}

/**
 * T-3D.6C-C3 Debug: 同步复制文件(C++ 文件流,绕过 ArkTS 文件访问限制)。
 *
 * 用于将 hdc 推送到 /data/local/tmp/ 的测试模型复制到应用沙箱。
 * 正式发布前必须删除调用入口。
 *
 * @param srcPath 源文件路径
 * @param dstPath 目标文件路径
 * @returns 复制结果
 */
export const copyFile: (srcPath: string, dstPath: string) => FileCopyResult;

/**
 * T-3D.6C-C3 Debug: 异步从 rawfile fd 复制到目标路径(C++ pread64,绕过 ArkTS 文件访问限制)。
 *
 * 使用 napi_async_work 在子线程执行文件复制,避免阻塞 UI 线程触发 THREAD_BLOCK_6S。
 * 始终 resolve:通过 result.success 判断成败,失败时 errorMessage 非空。
 *
 * 用于从 HAP 内打包的 rawfile 读取测试模型并写入应用沙箱。
 * 正式发布前必须删除调用入口。
 *
 * @param fd rawfile 文件描述符(来自 resourceManager.getRawFdSync)
 * @param offset rawfile 在 HAP 中的偏移
 * @param length rawfile 长度
 * @param dstPath 目标文件路径
 * @returns 复制结果 Promise
 */
export const copyFileFromFd: (fd: number, offset: number, length: number, dstPath: string) => Promise<FileCopyResult>;
