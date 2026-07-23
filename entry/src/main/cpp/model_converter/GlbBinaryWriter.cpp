/**
 * GlbBinaryWriter 实现
 * T-3D.6C-C 阶段 3
 *
 * 规格修正(T-3D.6C-C3):
 * chunkLength 必须包含 padding,即 4 字节对齐后的数据长度。
 * 不再先写未填充长度再追加未计入的 padding。
 */

#include "GlbBinaryWriter.h"
#include "GlbBinaryReader.h"

#include <cstdio>
#include <cstring>
#include <fstream>
#include <sstream>

namespace model_converter {

// 写入小端 uint32
static void WriteU32LE(std::vector<uint8_t>& out, uint32_t value)
{
    out.push_back(static_cast<uint8_t>(value & 0xFF));
    out.push_back(static_cast<uint8_t>((value >> 8) & 0xFF));
    out.push_back(static_cast<uint8_t>((value >> 16) & 0xFF));
    out.push_back(static_cast<uint8_t>((value >> 24) & 0xFF));
}

// 对给定数据追加 padding 直到 4 字节对齐,返回填充后的数据
static std::vector<uint8_t> PadDataTo4(const std::vector<uint8_t>& src, uint8_t padByte)
{
    std::vector<uint8_t> out = src;
    while (out.size() % 4 != 0) {
        out.push_back(padByte);
    }
    return out;
}

GlbWriteResult WriteGlb(const std::vector<uint8_t>& jsonData,
                        const std::vector<uint8_t>& binData)
{
    GlbWriteResult result = {};
    result.success = false;

    if (jsonData.empty()) {
        result.errorMessage = "JSON 数据为空";
        return result;
    }

    // 预先填充:JSON 用 0x20,BIN 用 0x00
    // chunkLength = 填充后长度(含 padding),必须 4 字节对齐
    std::vector<uint8_t> paddedJson = PadDataTo4(jsonData, 0x20);
    std::vector<uint8_t> paddedBin;
    if (!binData.empty()) {
        paddedBin = PadDataTo4(binData, 0x00);
    }

    std::vector<uint8_t>& out = result.outputData;

    // 总长度 = 12(header) + 8(JSON chunk header) + paddedJson.size()
    //         + (binData 非空时: 8 + paddedBin.size())
    size_t totalLength = 12 + 8 + paddedJson.size();
    if (!paddedBin.empty()) {
        totalLength += 8 + paddedBin.size();
    }

    out.reserve(totalLength);

    // Header: magic + version + length
    WriteU32LE(out, GLB_MAGIC);
    WriteU32LE(out, GLB_VERSION_2);
    WriteU32LE(out, static_cast<uint32_t>(totalLength));

    // JSON chunk header: chunkLength = 填充后长度(含 padding)
    result.jsonOffset = out.size() + 8;
    WriteU32LE(out, static_cast<uint32_t>(paddedJson.size()));
    WriteU32LE(out, GLB_CHUNK_JSON);
    // JSON 数据(已填充)
    out.insert(out.end(), paddedJson.begin(), paddedJson.end());

    // BIN chunk(仅当有数据时)
    if (!paddedBin.empty()) {
        result.binOffset = out.size() + 8;
        WriteU32LE(out, static_cast<uint32_t>(paddedBin.size()));
        WriteU32LE(out, GLB_CHUNK_BIN);
        out.insert(out.end(), paddedBin.begin(), paddedBin.end());
        result.binLength = paddedBin.size();
    } else {
        result.binOffset = 0;
        result.binLength = 0;
    }

    // 校验:输出大小必须等于 totalLength
    if (out.size() != totalLength) {
        result.errorMessage = "输出大小与 totalLength 不匹配: out=" +
            std::to_string(out.size()) + " vs total=" + std::to_string(totalLength);
        return result;
    }

    // 自验证:用 Reader 读取输出
    GlbReadResult verify = ReadGlbFromMemory(out.data(), out.size());
    if (!verify.valid) {
        result.errorMessage = "输出 GLB 自验证失败: " + verify.errorMessage;
        return result;
    }

    result.success = true;
    return result;
}

bool WriteGlbFile(const std::string& outputPath,
                  const std::vector<uint8_t>& glbData,
                  std::string& errorMessage)
{
    // 写入临时文件,验证后原子替换
    std::string tmpPath = outputPath + ".tmp";

    std::ofstream file(tmpPath, std::ios::binary | std::ios::trunc);
    if (!file.is_open()) {
        errorMessage = "无法创建临时文件: " + tmpPath;
        return false;
    }

    file.write(reinterpret_cast<const char*>(glbData.data()),
               static_cast<std::streamsize>(glbData.size()));
    if (!file.good()) {
        errorMessage = "写入临时文件失败: " + tmpPath;
        file.close();
        std::remove(tmpPath.c_str());
        return false;
    }
    file.close();

    // 验证临时文件
    GlbReadResult verify = ReadGlbFile(tmpPath);
    if (!verify.valid) {
        errorMessage = "临时文件验证失败: " + verify.errorMessage;
        std::remove(tmpPath.c_str());
        return false;
    }

    // 原子替换:先删除目标,再重命名
    std::remove(outputPath.c_str());
    if (std::rename(tmpPath.c_str(), outputPath.c_str()) != 0) {
        errorMessage = "重命名临时文件失败: " + tmpPath + " -> " + outputPath;
        std::remove(tmpPath.c_str());
        return false;
    }

    return true;
}

} // namespace model_converter
