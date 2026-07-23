/**
 * GlbContainerValidator - GLB 2.0 容器级独立校验器
 * T-3D.6C-C3
 *
 * 职责:
 * 不依赖 GltfValidator 的语义校验,仅校验 GLB 容器结构合法性。
 * 用于:
 * - 解码前对输入文件的预检;
 * - 解码后对输出文件的强校验;
 * - ArkGraphics 加载失败时的根因定位。
 *
 * 检查项(规格第七章):
 * 1. 文件长度 >= 12
 * 2. magic = 0x46546C67
 * 3. version = 2
 * 4. header.length = 实际文件大小
 * 5. 第一个 chunk 从 offset 12 开始
 * 6. 第一个 chunk type = JSON
 * 7. JSON chunkLength 为 4 的倍数
 * 8. JSON chunk 不越界
 * 9. JSON UTF-8 可解析(首字符为 '{')
 * 10. JSON 尾部仅允许空格
 * 11. 第二个 chunk 如果存在,type = BIN
 * 12. BIN chunkLength 为 4 的倍数
 * 13. BIN chunk 不越界
 * 14. 最后一个 chunk 结束位置等于 header.length
 * 15. buffers[0].byteLength <= BIN chunkLength
 * 16. 二者差值只能为 0~3
 * 17. 所有 bufferView 范围合法
 * 18. 所有 accessor 范围合法
 */

#pragma once

#include <cstdint>
#include <cstddef>
#include <string>
#include <vector>

namespace model_converter {

struct GlbContainerValidationResult {
    bool valid;
    std::string errorMessage;
    std::vector<std::string> warnings;

    // 容器元数据(用于日志)
    uint32_t magic;
    uint32_t version;
    uint32_t headerLength;
    size_t actualFileSize;
    uint32_t jsonChunkLength;
    uint32_t jsonChunkType;
    uint8_t jsonFirstByte;
    uint32_t binChunkLength;
    uint32_t binChunkType;
    bool hasBin;
    size_t jsonChunkOffset;
    size_t binChunkOffset;
};

/**
 * 校验 GLB 容器结构。
 *
 * @param data 文件数据
 * @param size 数据大小
 * @return 校验结果
 */
GlbContainerValidationResult ValidateGlbContainer(const uint8_t* data, size_t size);

/**
 * 校验 GLB 文件。
 *
 * @param filePath 文件路径
 * @return 校验结果
 */
GlbContainerValidationResult ValidateGlbContainerFile(const std::string& filePath);

} // namespace model_converter
