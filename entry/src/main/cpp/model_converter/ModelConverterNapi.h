/**
 * ModelConverterNapi - NAPI 桥接层
 * T-3D.6C-C 阶段 3
 *
 * 职责:
 * - 暴露 decodeMeshoptGlb 异步接口给 ArkTS
 * - 使用 napi_create_async_work 在子线程执行解码
 * - 将 Native 解码结果转换为 JS 对象
 *
 * 接口签名:
 *   decodeMeshoptGlb(inputPath: string, outputPath: string): Promise<MeshoptDecodeResult>
 */

#pragma once

#include "napi/native_api.h"

namespace model_converter {

class ModelConverterNapi {
public:
    /**
     * decodeMeshoptGlb NAPI 实现。
     * 参数:[inputPath: string, outputPath: string]
     * 返回:Promise<MeshoptDecodeResult>
     */
    static napi_value DecodeMeshoptGlb(napi_env env, napi_callback_info info);

    /**
     * T-3D.6C-C3 Debug: 同步复制文件(C++ ifstream/ofstream,绕过 ArkTS 文件访问限制)。
     * 参数:[srcPath: string, dstPath: string]
     * 返回:{ success: boolean, errorMessage: string, bytesCopied: number }
     */
    static napi_value CopyFile(napi_env env, napi_callback_info info);

    /**
     * T-3D.6C-C3 Debug: 从 rawfile fd 复制到目标路径。
     * 参数:[fd: number, offset: number, length: number, dstPath: string]
     * 返回:{ success: boolean, errorMessage: string, bytesCopied: number }
     */
    static napi_value CopyFileFromFd(napi_env env, napi_callback_info info);
};

} // namespace model_converter
