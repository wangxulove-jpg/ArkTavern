/**
 * GlbBinaryReader - GLB 2.0 二进制读取器
 * T-3D.6C-C 阶段 3
 *
 * 职责:
 * - 读取 GLB Header(magic/version/length)
 * - 读取 JSON Chunk 和 BIN Chunk
 * - 校验 chunk 边界与 4 字节对齐
 * - 不解析 JSON 语义(由上层 JSON 解析器处理)
 *
 * 安全约束:
 * - 拒绝非 GLB 文件
 * - 拒绝 GLB version != 2
 * - 拒绝 chunk 越界
 * - 所有范围计算检查整数溢出
 */

#pragma once

#include <cstdint>
#include <cstddef>
#include <string>
#include <vector>

namespace model_converter {

/** GLB 文件 magic: "glTF" */
constexpr uint32_t GLB_MAGIC = 0x46546C67; // 'g','l','T','F' little-endian
/** GLB version 2.0 */
constexpr uint32_t GLB_VERSION_2 = 2;
/** JSON chunk type: 0x4E4F534A = "JSON" */
constexpr uint32_t GLB_CHUNK_JSON = 0x4E4F534A;
/** BIN chunk type: 0x004E4942 = "BIN\0" */
constexpr uint32_t GLB_CHUNK_BIN = 0x004E4942;

/**
 * GLB Chunk 描述。
 */
struct GlbChunk {
    uint32_t chunkType;   // GLB_CHUNK_JSON 或 GLB_CHUNK_BIN
    uint32_t chunkLength; // chunk 数据长度(不含 header,已 4 字节对齐)
    const uint8_t* data;  // 指向 chunk 数据起始
    size_t dataOffset;    // 在整个文件中的偏移
};

/**
 * GLB 读取结果。
 */
struct GlbReadResult {
    bool valid;
    std::string errorMessage;
    uint32_t version;
    uint32_t totalLength;
    GlbChunk jsonChunk;
    GlbChunk binChunk;
    bool hasBin;
    std::vector<uint8_t> fileData; // 持有完整文件数据
};

/**
 * 读取 GLB 文件。
 *
 * @param filePath 文件路径
 * @return GlbReadResult,valid=false 时 errorMessage 含原因
 */
GlbReadResult ReadGlbFile(const std::string& filePath);

/**
 * 从内存 buffer 读取 GLB。
 * 用于测试或已有 buffer 的场景。
 *
 * @param data 文件数据
 * @param size 数据大小
 * @return GlbReadResult
 */
GlbReadResult ReadGlbFromMemory(const uint8_t* data, size_t size);

} // namespace model_converter
