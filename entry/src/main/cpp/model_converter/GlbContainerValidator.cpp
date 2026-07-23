/**
 * GlbContainerValidator 实现
 * T-3D.6C-C3
 */

#include "GlbContainerValidator.h"
#include "GlbBinaryReader.h"

#include <cstdio>
#include <cstring>
#include <fstream>
#include <sstream>

namespace model_converter {

static uint32_t ReadU32LE(const uint8_t* p)
{
    return static_cast<uint32_t>(p[0]) |
           (static_cast<uint32_t>(p[1]) << 8) |
           (static_cast<uint32_t>(p[2]) << 16) |
           (static_cast<uint32_t>(p[3]) << 24);
}

static bool AddOverflow(size_t a, size_t b, size_t& result)
{
    if (a > SIZE_MAX - b) {
        return true;
    }
    result = a + b;
    return false;
}

GlbContainerValidationResult ValidateGlbContainer(const uint8_t* data, size_t size)
{
    GlbContainerValidationResult result = {};
    result.valid = false;
    result.hasBin = false;
    result.actualFileSize = size;

    // 1. 文件长度 >= 12
    if (data == nullptr || size < 12) {
        result.errorMessage = "文件长度 < 12(无法容纳 GLB header)";
        return result;
    }

    // 2. magic = 0x46546C67
    result.magic = ReadU32LE(data);
    if (result.magic != GLB_MAGIC) {
        std::ostringstream oss;
        oss << "magic 不匹配: 0x" << std::hex << result.magic
            << "(期望 0x" << std::hex << GLB_MAGIC << ")";
        result.errorMessage = oss.str();
        return result;
    }

    // 3. version = 2
    result.version = ReadU32LE(data + 4);
    if (result.version != GLB_VERSION_2) {
        result.errorMessage = "version 不支持: " + std::to_string(result.version) +
            "(仅支持 2)";
        return result;
    }

    // 4. header.length = 实际文件大小
    result.headerLength = ReadU32LE(data + 8);
    if (result.headerLength != size) {
        result.errorMessage = "header.length(" + std::to_string(result.headerLength) +
            ") != 实际文件大小(" + std::to_string(size) + ")";
        return result;
    }

    // 5. 第一个 chunk 从 offset 12 开始
    size_t offset = 12;
    int chunkIndex = 0;

    // JSON chunk
    if (offset + 8 > size) {
        result.errorMessage = "无法读取 JSON chunk header(文件过小)";
        return result;
    }

    result.jsonChunkOffset = offset;
    result.jsonChunkLength = ReadU32LE(data + offset);
    result.jsonChunkType = ReadU32LE(data + offset + 4);

    // 6. 第一个 chunk type = JSON
    if (result.jsonChunkType != GLB_CHUNK_JSON) {
        std::ostringstream oss;
        oss << "第一个 chunk type 不是 JSON: 0x" << std::hex << result.jsonChunkType
            << "(期望 0x" << std::hex << GLB_CHUNK_JSON << ")";
        result.errorMessage = oss.str();
        return result;
    }

    // 7. JSON chunkLength 为 4 的倍数
    if ((result.jsonChunkLength % 4) != 0) {
        result.errorMessage = "JSON chunkLength 未 4 字节对齐: " +
            std::to_string(result.jsonChunkLength);
        return result;
    }

    // 8. JSON chunk 不越界
    size_t jsonDataOffset;
    if (AddOverflow(offset, 8, jsonDataOffset)) {
        result.errorMessage = "JSON chunk 数据偏移溢出";
        return result;
    }
    size_t jsonChunkEnd;
    if (AddOverflow(jsonDataOffset, result.jsonChunkLength, jsonChunkEnd)) {
        result.errorMessage = "JSON chunk 结束位置溢出";
        return result;
    }
    if (jsonChunkEnd > size) {
        result.errorMessage = "JSON chunk 越界: end=" + std::to_string(jsonChunkEnd) +
            ", fileSize=" + std::to_string(size);
        return result;
    }

    // 9. JSON 首字符为 '{'
    result.jsonFirstByte = data[jsonDataOffset];
    if (result.jsonFirstByte != '{') {
        std::ostringstream oss;
        oss << "JSON 首字符不是 '{': 0x" << std::hex
            << static_cast<int>(result.jsonFirstByte);
        result.errorMessage = oss.str();
        return result;
    }

    // 10. JSON 尾部仅允许空格(0x20)
    for (size_t i = jsonDataOffset; i < jsonChunkEnd; i++) {
        uint8_t b = data[i];
        // 允许任意 JSON 内容字符,这里只检查最后一个非空格字符是否为 '}'
        // 实际上只要首字符是 '{' 且尾部 padding 是 0x20 即可
        if (i >= jsonChunkEnd - 4) {
            // 最后 4 字节内,允许 0x20 padding
            // 但不允许 0x00(NULL)
            if (b == 0x00) {
                result.warnings.push_back("JSON chunk 尾部发现 0x00(应为 0x20 空格)");
                break;
            }
        }
    }

    offset = jsonChunkEnd;
    chunkIndex++;

    // BIN chunk(可选)
    if (offset + 8 <= size) {
        result.binChunkOffset = offset;
        result.binChunkLength = ReadU32LE(data + offset);
        result.binChunkType = ReadU32LE(data + offset + 4);

        // 11. 第二个 chunk type = BIN
        if (result.binChunkType != GLB_CHUNK_BIN) {
            std::ostringstream oss;
            oss << "第二个 chunk type 不是 BIN: 0x" << std::hex << result.binChunkType
                << "(期望 0x" << std::hex << GLB_CHUNK_BIN << ")";
            result.errorMessage = oss.str();
            return result;
        }

        // 12. BIN chunkLength 为 4 的倍数
        if ((result.binChunkLength % 4) != 0) {
            result.errorMessage = "BIN chunkLength 未 4 字节对齐: " +
                std::to_string(result.binChunkLength);
            return result;
        }

        // 13. BIN chunk 不越界
        size_t binDataOffset;
        if (AddOverflow(offset, 8, binDataOffset)) {
            result.errorMessage = "BIN chunk 数据偏移溢出";
            return result;
        }
        size_t binChunkEnd;
        if (AddOverflow(binDataOffset, result.binChunkLength, binChunkEnd)) {
            result.errorMessage = "BIN chunk 结束位置溢出";
            return result;
        }
        if (binChunkEnd > size) {
            result.errorMessage = "BIN chunk 越界: end=" + std::to_string(binChunkEnd) +
                ", fileSize=" + std::to_string(size);
            return result;
        }

        result.hasBin = true;
        offset = binChunkEnd;
        chunkIndex++;
    }

    // 14. 最后一个 chunk 结束位置等于 header.length
    if (offset != result.headerLength) {
        result.errorMessage = "最后一个 chunk 结束位置(" + std::to_string(offset) +
            ") != header.length(" + std::to_string(result.headerLength) + ")";
        return result;
    }

    result.valid = true;
    return result;
}

GlbContainerValidationResult ValidateGlbContainerFile(const std::string& filePath)
{
    GlbContainerValidationResult result = {};
    result.valid = false;

    std::ifstream file(filePath, std::ios::binary | std::ios::ate);
    if (!file.is_open()) {
        result.errorMessage = "无法打开文件: " + filePath;
        return result;
    }

    std::streamsize size = file.tellg();
    if (size <= 0) {
        result.errorMessage = "文件为空: " + filePath;
        return result;
    }

    file.seekg(0, std::ios::beg);
    std::vector<uint8_t> data(static_cast<size_t>(size));
    if (!file.read(reinterpret_cast<char*>(data.data()), size)) {
        result.errorMessage = "读取文件失败: " + filePath;
        return result;
    }
    file.close();

    return ValidateGlbContainer(data.data(), data.size());
}

} // namespace model_converter
