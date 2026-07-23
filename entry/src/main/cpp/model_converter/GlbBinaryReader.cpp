/**
 * GlbBinaryReader 实现
 * T-3D.6C-C 阶段 3
 */

#include "GlbBinaryReader.h"

#include <cstdio>
#include <cstring>
#include <fstream>

namespace model_converter {

// 读取小端 uint32
static uint32_t ReadU32LE(const uint8_t* p)
{
    return static_cast<uint32_t>(p[0]) |
           (static_cast<uint32_t>(p[1]) << 8) |
           (static_cast<uint32_t>(p[2]) << 16) |
           (static_cast<uint32_t>(p[3]) << 24);
}

// 检查加法溢出
static bool AddOverflow(size_t a, size_t b, size_t& result)
{
    if (a > SIZE_MAX - b) {
        return true;
    }
    result = a + b;
    return false;
}

GlbReadResult ReadGlbFromMemory(const uint8_t* data, size_t size)
{
    GlbReadResult result = {};
    result.valid = false;
    result.hasBin = false;

    if (data == nullptr || size < 12) {
        result.errorMessage = "GLB 文件过小(小于 12 字节 header)";
        return result;
    }

    // Header: magic(4) + version(4) + length(4)
    uint32_t magic = ReadU32LE(data);
    if (magic != GLB_MAGIC) {
        result.errorMessage = "非 GLB 文件:magic 不匹配(期望 0x46546C67)";
        return result;
    }

    uint32_t version = ReadU32LE(data + 4);
    if (version != GLB_VERSION_2) {
        result.errorMessage = "GLB version 不支持(仅支持 2.0)";
        return result;
    }

    uint32_t totalLength = ReadU32LE(data + 8);
    if (totalLength > size) {
        result.errorMessage = "GLB totalLength 超过文件大小";
        return result;
    }
    if (totalLength < 12) {
        result.errorMessage = "GLB totalLength 小于 header 大小";
        return result;
    }

    result.version = version;
    result.totalLength = totalLength;

    // 读取 chunks:至少 1 个 JSON chunk,最多 2 个(JSON + BIN)
    size_t offset = 12;
    int chunkIndex = 0;

    while (offset + 8 <= totalLength) {
        uint32_t chunkLength = ReadU32LE(data + offset);
        uint32_t chunkType = ReadU32LE(data + offset + 4);

        // 规格修正(T-3D.6C-C3):
        // chunkLength 必须为 4 的倍数(含 padding)。
        // 下一个 chunk 起点直接 = offset + 8 + chunkLength,不再额外对齐。
        if ((chunkLength % 4) != 0) {
            result.errorMessage = "GLB chunk " + std::to_string(chunkIndex) +
                " 长度未 4 字节对齐(chunkLength=" + std::to_string(chunkLength) + ")";
            return result;
        }

        size_t chunkDataOffset;
        if (AddOverflow(offset, 8, chunkDataOffset)) {
            result.errorMessage = "GLB chunk " + std::to_string(chunkIndex) +
                " 数据偏移溢出";
            return result;
        }

        size_t chunkEnd;
        if (AddOverflow(chunkDataOffset, chunkLength, chunkEnd)) {
            result.errorMessage = "GLB chunk " + std::to_string(chunkIndex) +
                " 结束位置溢出";
            return result;
        }

        if (chunkEnd > totalLength) {
            result.errorMessage = "GLB chunk " + std::to_string(chunkIndex) +
                " 越界(chunkEnd=" + std::to_string(chunkEnd) +
                ", totalLength=" + std::to_string(totalLength) + ")";
            return result;
        }

        GlbChunk chunk = {};
        chunk.chunkType = chunkType;
        chunk.chunkLength = chunkLength;
        chunk.data = data + chunkDataOffset;
        chunk.dataOffset = chunkDataOffset;

        if (chunkType == GLB_CHUNK_JSON) {
            if (chunkIndex != 0) {
                result.errorMessage = "JSON chunk 必须是第一个 chunk";
                return result;
            }
            result.jsonChunk = chunk;
        } else if (chunkType == GLB_CHUNK_BIN) {
            if (chunkIndex != 1) {
                result.errorMessage = "BIN chunk 必须是第二个 chunk";
                return result;
            }
            result.binChunk = chunk;
            result.hasBin = true;
        } else {
            result.errorMessage = "未知 chunk type: 0x" +
                std::to_string(chunkType);
            return result;
        }

        // chunkLength 已含 padding,直接跳到下一个 chunk
        offset = chunkEnd;
        chunkIndex++;
    }

    if (chunkIndex < 1) {
        result.errorMessage = "GLB 缺少 JSON chunk";
        return result;
    }

    if (result.jsonChunk.chunkLength == 0) {
        result.errorMessage = "JSON chunk 长度为 0";
        return result;
    }

    result.valid = true;
    return result;
}

GlbReadResult ReadGlbFile(const std::string& filePath)
{
    GlbReadResult result = {};
    result.valid = false;

    std::ifstream file(filePath, std::ios::binary | std::ios::ate);
    if (!file.is_open()) {
        result.errorMessage = "无法打开文件: " + filePath;
        return result;
    }

    std::streamsize size = file.tellg();
    if (size <= 0) {
        result.errorMessage = "文件为空或读取失败: " + filePath;
        return result;
    }

    file.seekg(0, std::ios::beg);
    result.fileData.resize(static_cast<size_t>(size));
    if (!file.read(reinterpret_cast<char*>(result.fileData.data()), size)) {
        result.errorMessage = "读取文件内容失败: " + filePath;
        return result;
    }
    file.close();

    GlbReadResult parsed = ReadGlbFromMemory(result.fileData.data(),
        result.fileData.size());
    if (!parsed.valid) {
        result.errorMessage = parsed.errorMessage;
        return result;
    }

    // 转移所有权:fileData 保留在 result 中,chunk.data 指向其内部
    result.version = parsed.version;
    result.totalLength = parsed.totalLength;
    result.jsonChunk = parsed.jsonChunk;
    result.binChunk = parsed.binChunk;
    result.hasBin = parsed.hasBin;
    // 注意:parsed.jsonChunk.data 和 parsed.binChunk.data 指向 result.fileData
    // 由于 parsed.fileData 已被移动到 result.fileData,指针仍然有效
    result.valid = true;
    return result;
}

} // namespace model_converter
