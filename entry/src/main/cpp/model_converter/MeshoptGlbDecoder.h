/**
 * MeshoptGlbDecoder - EXT_meshopt_compression GLB 解码器
 * T-3D.6C-C 阶段 3
 *
 * 职责:
 * - 解析 GLB JSON chunk 中的 meshopt 扩展引用
 * - 定位所有 bufferViews[i].extensions.EXT_meshopt_compression
 * - 调用 meshopt 解码函数解码压缩数据
 * - 重建未压缩 bufferView 数据
 * - 生成标准 GLB(移除 EXT_meshopt_compression 声明)
 *
 * 支持的 mode:
 * - ATTRIBUTES (meshopt_decodeVertexBuffer)
 * - TRIANGLES (meshopt_decodeIndexBuffer)
 * - INDICES (meshopt_decodeIndexSequence)
 *
 * 支持的 filter:
 * - NONE (无后处理)
 * - OCTAHEDRAL (meshopt_decodeFilterOct)
 * - QUATERNION (meshopt_decodeFilterQuat)
 * - EXPONENTIAL (meshopt_decodeFilterExp)
 *
 * 不修改:
 * - KHR_mesh_quantization(保留)
 * - 节点顺序、mesh primitive 顺序
 * - skin、animation、morph target
 * - material、texture、image
 */

#pragma once

#include <cstdint>
#include <cstddef>
#include <string>
#include <vector>

namespace model_converter {

/**
 * meshopt 解码模式。
 */
enum class MeshoptMode {
    Attributes = 0,
    Triangles = 1,
    Indices = 2,
    Unknown = 99
};

/**
 * meshopt 过滤器。
 */
enum class MeshoptFilter {
    None = 0,
    Octahedral = 1,
    Quaternion = 2,
    Exponential = 3,
    Unknown = 99
};

/**
 * meshopt bufferView 扩展描述。
 */
struct MeshoptBufferViewInfo {
    size_t bufferViewIndex;
    // 扩展字段
    int buffer;           // 源 buffer 索引(通常为 0,即 BIN chunk)
    size_t byteOffset;    // 在源 buffer 中的偏移
    size_t byteLength;    // 压缩数据长度
    size_t byteStride;    // 解压后每个元素的字节大小
    size_t count;         // 元素数量
    MeshoptMode mode;
    MeshoptFilter filter;
    // 解码后
    std::vector<uint8_t> decodedData;
    bool decoded;
};

/**
 * 解码结果。
 */
struct MeshoptDecodeResult {
    bool success;
    std::string errorMessage;
    std::string errorCode;

    // 统计信息
    int decodedBufferViewCount;
    std::vector<std::string> sourceExtensions;
    std::vector<std::string> remainingExtensions;
    std::vector<std::string> warnings;

    // 输出
    std::string outputPath;
    std::vector<uint8_t> outputGlbData;
};

/**
 * 解码 GLB 文件中的 EXT_meshopt_compression 扩展。
 *
 * @param inputPath 输入 GLB 文件路径
 * @param outputPath 输出标准 GLB 文件路径
 * @return MeshoptDecodeResult
 */
MeshoptDecodeResult DecodeMeshoptGlb(const std::string& inputPath,
                                      const std::string& outputPath);

} // namespace model_converter
