/**
 * GlbBinaryWriter - 标准 GLB 2.0 写入器
 * T-3D.6C-C 阶段 3
 *
 * 职责:
 * - 将 JSON + BIN 数据写入标准 GLB 2.0 文件
 * - JSON 使用空格补齐至 4 字节对齐
 * - BIN 使用 0 补齐至 4 字节对齐
 * - 校验输出格式合法
 *
 * 输出格式:
 * [Header 12B][JSON chunk header 8B][JSON data padded][BIN chunk header 8B][BIN data padded]
 */

#pragma once

#include <cstdint>
#include <cstddef>
#include <string>
#include <vector>

namespace model_converter {

/**
 * GLB 写入结果。
 */
struct GlbWriteResult {
    bool success;
    std::string errorMessage;
    std::vector<uint8_t> outputData; // 完整 GLB 数据
    size_t jsonOffset;
    size_t binOffset;
    size_t binLength;
};

/**
 * 写入标准 GLB 2.0 文件。
 *
 * @param jsonData JSON chunk 数据(UTF-8,不含尾部 null)
 * @param binData BIN chunk 数据
 * @return GlbWriteResult
 */
GlbWriteResult WriteGlb(const std::vector<uint8_t>& jsonData,
                        const std::vector<uint8_t>& binData);

/**
 * 将 GLB 数据写入文件。
 * 使用临时文件 + 原子替换,确保写入失败时不破坏目标文件。
 *
 * @param outputPath 目标文件路径
 * @param glbData GLB 数据
 * @return true 成功,false 失败(errorMessage 含原因)
 */
bool WriteGlbFile(const std::string& outputPath,
                  const std::vector<uint8_t>& glbData,
                  std::string& errorMessage);

} // namespace model_converter
