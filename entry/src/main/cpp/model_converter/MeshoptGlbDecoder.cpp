/**
 * MeshoptGlbDecoder 实现
 * T-3D.6C-C 阶段 3
 *
 * 流程:
 * 1. 读取 GLB 文件
 * 2. 解析 JSON chunk
 * 3. 遍历 bufferViews,定位 EXT_meshopt_compression 扩展
 * 4. 对每个压缩 bufferView,调用 meshopt 解码函数
 * 5. 将解码数据追加到新 BIN
 * 6. 更新 bufferView 的 buffer/byteOffset/byteLength
 * 7. 删除 bufferView 的 EXT_meshopt_compression 扩展
 * 8. 从 extensionsUsed/extensionsRequired 移除 EXT_meshopt_compression
 * 9. 重建标准 GLB
 * 10. 写入临时文件,验证后原子替换
 */

#include "MeshoptGlbDecoder.h"
#include "GlbBinaryReader.h"
#include "GlbBinaryWriter.h"
#include "GlbContainerValidator.h"

#include "meshoptimizer.h"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <sstream>

#ifdef __OHOS__
#include "hilog/log.h"
#define LOG_DOMAIN 0x3200B
#define LOG_TAG "ModelConverter"
#define MC_LOG_INFO(fmt, ...) OH_LOG_INFO(LOG_APP, fmt, ##__VA_ARGS__)
#define MC_LOG_ERROR(fmt, ...) OH_LOG_ERROR(LOG_APP, fmt, ##__VA_ARGS__)
#else
#define MC_LOG_INFO(fmt, ...) printf("[INFO] " fmt "\n", ##__VA_ARGS__)
#define MC_LOG_ERROR(fmt, ...) printf("[ERROR] " fmt "\n", ##__VA_ARGS__)
#endif

namespace model_converter {

// ============ 轻量 JSON 解析器 ============
// 仅支持 glTF JSON 子集:对象、数组、字符串、数字、布尔、null
// 目的:解析、修改 bufferViews 和 extensionsUsed/Required,然后重新序列化

enum class JsonType {
    Null,
    Bool,
    Number,
    String,
    Array,
    Object
};

struct JsonValue {
    JsonType type;
    bool boolValue;
    double numberValue;
    std::string stringValue;
    std::vector<JsonValue> arrayValue;
    std::vector<std::pair<std::string, JsonValue>> objectValue;

    JsonValue() : type(JsonType::Null), boolValue(false), numberValue(0) {}
};

// JSON 解析错误
struct JsonParseError {
    std::string message;
    size_t position;
};

// 跳过空白
static size_t SkipWhitespace(const std::string& json, size_t pos)
{
    while (pos < json.size()) {
        char c = json[pos];
        if (c == ' ' || c == '\t' || c == '\n' || c == '\r') {
            pos++;
        } else {
            break;
        }
    }
    return pos;
}

// 前向声明
static bool ParseValue(const std::string& json, size_t& pos, JsonValue& out, std::string& error);

// 解析字符串
static bool ParseString(const std::string& json, size_t& pos, std::string& out, std::string& error)
{
    if (pos >= json.size() || json[pos] != '"') {
        error = "期望 '\"' 开始字符串";
        return false;
    }
    pos++;
    out.clear();
    while (pos < json.size()) {
        char c = json[pos];
        if (c == '"') {
            pos++;
            return true;
        }
        if (c == '\\') {
            pos++;
            if (pos >= json.size()) {
                error = "字符串转义不完整";
                return false;
            }
            char esc = json[pos];
            switch (esc) {
                case '"': out.push_back('"'); break;
                case '\\': out.push_back('\\'); break;
                case '/': out.push_back('/'); break;
                case 'b': out.push_back('\b'); break;
                case 'f': out.push_back('\f'); break;
                case 'n': out.push_back('\n'); break;
                case 'r': out.push_back('\r'); break;
                case 't': out.push_back('\t'); break;
                case 'u': {
                    if (pos + 4 >= json.size()) {
                        error = "\\u 转义不完整";
                        return false;
                    }
                    // 简化:只处理 BMP 字符
                    unsigned int code = 0;
                    for (int i = 0; i < 4; i++) {
                        char hc = json[pos + 1 + i];
                        code <<= 4;
                        if (hc >= '0' && hc <= '9') code |= (hc - '0');
                        else if (hc >= 'a' && hc <= 'f') code |= (hc - 'a' + 10);
                        else if (hc >= 'A' && hc <= 'F') code |= (hc - 'A' + 10);
                        else { error = "\\u 转义含非法字符"; return false; }
                    }
                    pos += 4;
                    if (code < 0x80) {
                        out.push_back(static_cast<char>(code));
                    } else if (code < 0x800) {
                        out.push_back(static_cast<char>(0xC0 | (code >> 6)));
                        out.push_back(static_cast<char>(0x80 | (code & 0x3F)));
                    } else {
                        out.push_back(static_cast<char>(0xE0 | (code >> 12)));
                        out.push_back(static_cast<char>(0x80 | ((code >> 6) & 0x3F)));
                        out.push_back(static_cast<char>(0x80 | (code & 0x3F)));
                    }
                    break;
                }
                default:
                    error = "未知转义字符: \\";
                    error += esc;
                    return false;
            }
            pos++;
        } else {
            out.push_back(c);
            pos++;
        }
    }
    error = "字符串未闭合";
    return false;
}

// 解析数字
static bool ParseNumber(const std::string& json, size_t& pos, double& out, std::string& error)
{
    size_t start = pos;
    if (pos < json.size() && (json[pos] == '-' || json[pos] == '+')) {
        pos++;
    }
    while (pos < json.size()) {
        char c = json[pos];
        if ((c >= '0' && c <= '9') || c == '.' || c == 'e' || c == 'E' || c == '+' || c == '-') {
            pos++;
        } else {
            break;
        }
    }
    if (pos == start) {
        error = "无效数字";
        return false;
    }
    std::string numStr = json.substr(start, pos - start);
    try {
        out = std::stod(numStr);
    } catch (...) {
        error = "数字解析失败: " + numStr;
        return false;
    }
    return true;
}

// 解析字面量(true/false/null)
static bool ParseLiteral(const std::string& json, size_t& pos, JsonValue& out, std::string& error)
{
    if (json.compare(pos, 4, "true") == 0) {
        out.type = JsonType::Bool;
        out.boolValue = true;
        pos += 4;
        return true;
    }
    if (json.compare(pos, 5, "false") == 0) {
        out.type = JsonType::Bool;
        out.boolValue = false;
        pos += 5;
        return true;
    }
    if (json.compare(pos, 4, "null") == 0) {
        out.type = JsonType::Null;
        pos += 4;
        return true;
    }
    error = "未知字面量";
    return false;
}

// 解析数组
static bool ParseArray(const std::string& json, size_t& pos, JsonValue& out, std::string& error)
{
    out.type = JsonType::Array;
    out.arrayValue.clear();
    pos++; // 跳过 '['
    pos = SkipWhitespace(json, pos);
    if (pos < json.size() && json[pos] == ']') {
        pos++;
        return true;
    }
    while (pos < json.size()) {
        JsonValue elem;
        if (!ParseValue(json, pos, elem, error)) {
            return false;
        }
        out.arrayValue.push_back(std::move(elem));
        pos = SkipWhitespace(json, pos);
        if (pos >= json.size()) {
            error = "数组未闭合";
            return false;
        }
        if (json[pos] == ',') {
            pos++;
            pos = SkipWhitespace(json, pos);
        } else if (json[pos] == ']') {
            pos++;
            return true;
        } else {
            error = "数组元素后期望 ',' 或 ']'";
            return false;
        }
    }
    error = "数组未闭合";
    return false;
}

// 解析对象
static bool ParseObject(const std::string& json, size_t& pos, JsonValue& out, std::string& error)
{
    out.type = JsonType::Object;
    out.objectValue.clear();
    pos++; // 跳过 '{'
    pos = SkipWhitespace(json, pos);
    if (pos < json.size() && json[pos] == '}') {
        pos++;
        return true;
    }
    while (pos < json.size()) {
        pos = SkipWhitespace(json, pos);
        if (pos >= json.size() || json[pos] != '"') {
            error = "对象键期望字符串";
            return false;
        }
        std::string key;
        if (!ParseString(json, pos, key, error)) {
            return false;
        }
        pos = SkipWhitespace(json, pos);
        if (pos >= json.size() || json[pos] != ':') {
            error = "对象键后期望 ':'";
            return false;
        }
        pos++;
        pos = SkipWhitespace(json, pos);
        JsonValue value;
        if (!ParseValue(json, pos, value, error)) {
            return false;
        }
        out.objectValue.emplace_back(std::move(key), std::move(value));
        pos = SkipWhitespace(json, pos);
        if (pos >= json.size()) {
            error = "对象未闭合";
            return false;
        }
        if (json[pos] == ',') {
            pos++;
        } else if (json[pos] == '}') {
            pos++;
            return true;
        } else {
            error = "对象成员后期望 ',' 或 '}'";
            return false;
        }
    }
    error = "对象未闭合";
    return false;
}

static bool ParseValue(const std::string& json, size_t& pos, JsonValue& out, std::string& error)
{
    pos = SkipWhitespace(json, pos);
    if (pos >= json.size()) {
        error = "JSON 意外结束";
        return false;
    }
    char c = json[pos];
    if (c == '{') {
        return ParseObject(json, pos, out, error);
    }
    if (c == '[') {
        return ParseArray(json, pos, out, error);
    }
    if (c == '"') {
        out.type = JsonType::String;
        return ParseString(json, pos, out.stringValue, error);
    }
    if (c == '-' || (c >= '0' && c <= '9')) {
        out.type = JsonType::Number;
        return ParseNumber(json, pos, out.numberValue, error);
    }
    if (c == 't' || c == 'f' || c == 'n') {
        return ParseLiteral(json, pos, out, error);
    }
    error = "未知 JSON 字符: '";
    error += c;
    error += "'";
    return false;
}

// ============ JSON 序列化 ============

static void SerializeString(std::string& out, const std::string& str)
{
    out.push_back('"');
    for (size_t i = 0; i < str.size(); i++) {
        char c = str[i];
        switch (c) {
            case '"': out += "\\\""; break;
            case '\\': out += "\\\\"; break;
            case '\b': out += "\\b"; break;
            case '\f': out += "\\f"; break;
            case '\n': out += "\\n"; break;
            case '\r': out += "\\r"; break;
            case '\t': out += "\\t"; break;
            default:
                if (static_cast<unsigned char>(c) < 0x20) {
                    char buf[8];
                    snprintf(buf, sizeof(buf), "\\u%04x", c);
                    out += buf;
                } else {
                    out.push_back(c);
                }
                break;
        }
    }
    out.push_back('"');
}

static void SerializeValue(std::string& out, const JsonValue& value)
{
    switch (value.type) {
        case JsonType::Null:
            out += "null";
            break;
        case JsonType::Bool:
            out += value.boolValue ? "true" : "false";
            break;
        case JsonType::Number: {
            // 整数优化:如果是整数则输出整数形式
            double intPart;
            if (std::modf(value.numberValue, &intPart) == 0.0 &&
                value.numberValue >= -1e15 && value.numberValue <= 1e15) {
                long long iv = static_cast<long long>(value.numberValue);
                out += std::to_string(iv);
            } else {
                std::ostringstream oss;
                oss.precision(15);
                oss << value.numberValue;
                out += oss.str();
            }
            break;
        }
        case JsonType::String:
            SerializeString(out, value.stringValue);
            break;
        case JsonType::Array:
            out.push_back('[');
            for (size_t i = 0; i < value.arrayValue.size(); i++) {
                if (i > 0) out.push_back(',');
                SerializeValue(out, value.arrayValue[i]);
            }
            out.push_back(']');
            break;
        case JsonType::Object:
            out.push_back('{');
            for (size_t i = 0; i < value.objectValue.size(); i++) {
                if (i > 0) out.push_back(',');
                SerializeString(out, value.objectValue[i].first);
                out.push_back(':');
                SerializeValue(out, value.objectValue[i].second);
            }
            out.push_back('}');
            break;
    }
}

// ============ 辅助函数 ============

// 在对象中查找字段
static JsonValue* FindField(JsonValue& obj, const std::string& key)
{
    if (obj.type != JsonType::Object) return nullptr;
    for (auto& kv : obj.objectValue) {
        if (kv.first == key) {
            return &kv.second;
        }
    }
    return nullptr;
}

// 获取数值字段的整数值
static bool GetIntField(const JsonValue& obj, const std::string& key, int& out)
{
    if (obj.type != JsonType::Object) return false;
    for (const auto& kv : obj.objectValue) {
        if (kv.first == key && kv.second.type == JsonType::Number) {
            out = static_cast<int>(kv.second.numberValue);
            return true;
        }
    }
    return false;
}

// 从字符串数组获取扩展列表
static void GetStringArray(const JsonValue& arr, std::vector<std::string>& out)
{
    out.clear();
    if (arr.type != JsonType::Array) return;
    for (const auto& v : arr.arrayValue) {
        if (v.type == JsonType::String) {
            out.push_back(v.stringValue);
        }
    }
}

// ============ meshopt 解码核心 ============

// 解析 mode 字符串
static MeshoptMode ParseMode(const std::string& mode)
{
    if (mode == "ATTRIBUTES") return MeshoptMode::Attributes;
    if (mode == "TRIANGLES") return MeshoptMode::Triangles;
    if (mode == "INDICES") return MeshoptMode::Indices;
    return MeshoptMode::Unknown;
}

// 解析 filter 字符串
static MeshoptFilter ParseFilter(const std::string& filter)
{
    if (filter == "NONE") return MeshoptFilter::None;
    if (filter == "OCTAHEDRAL") return MeshoptFilter::Octahedral;
    if (filter == "QUATERNION") return MeshoptFilter::Quaternion;
    if (filter == "EXPONENTIAL") return MeshoptFilter::Exponential;
    return MeshoptFilter::Unknown;
}

// 执行 meshopt 解码
static bool DecodeMeshoptBufferView(const MeshoptBufferViewInfo& info,
                                    const uint8_t* binData, size_t binSize,
                                    std::vector<uint8_t>& output,
                                    std::string& error)
{
    // 校验源数据范围
    if (info.byteOffset > binSize) {
        error = "bufferView " + std::to_string(info.bufferViewIndex) +
            " 的 byteOffset 超出 BIN 范围";
        return false;
    }
    size_t srcEnd;
    if (info.byteOffset > SIZE_MAX - info.byteLength) {
        error = "bufferView " + std::to_string(info.bufferViewIndex) +
            " 的 byteOffset+byteLength 溢出";
        return false;
    }
    srcEnd = info.byteOffset + info.byteLength;
    if (srcEnd > binSize) {
        error = "bufferView " + std::to_string(info.bufferViewIndex) +
            " 的压缩数据超出 BIN 范围(byteOffset=" + std::to_string(info.byteOffset) +
            ", byteLength=" + std::to_string(info.byteLength) +
            ", binSize=" + std::to_string(binSize) + ")";
        return false;
    }

    const unsigned char* srcPtr = binData + info.byteOffset;
    size_t srcSize = info.byteLength;

    // 计算解码后大小
    // vertex/index buffer: count * stride
    // index sequence: count * index_size (stride 决定 index_size)
    size_t dstSize = info.count * info.byteStride;
    if (info.count > 0 && dstSize / info.count != info.byteStride) {
        error = "bufferView " + std::to_string(info.bufferViewIndex) +
            " 的解码大小计算溢出";
        return false;
    }

    output.resize(dstSize);

    int decodeResult = 0;
    switch (info.mode) {
        case MeshoptMode::Attributes:
            decodeResult = meshopt_decodeVertexBuffer(output.data(),
                info.count, info.byteStride, srcPtr, srcSize);
            break;
        case MeshoptMode::Triangles:
            decodeResult = meshopt_decodeIndexBuffer(output.data(),
                info.count, info.byteStride, srcPtr, srcSize);
            break;
        case MeshoptMode::Indices:
            decodeResult = meshopt_decodeIndexSequence(output.data(),
                info.count, info.byteStride, srcPtr, srcSize);
            break;
        default:
            error = "bufferView " + std::to_string(info.bufferViewIndex) +
                " 使用了不支持的 mode";
            return false;
    }

    if (decodeResult != 0) {
        error = "bufferView " + std::to_string(info.bufferViewIndex) +
            " 解码失败(meshopt 返回 " + std::to_string(decodeResult) + ")";
        return false;
    }

    // 应用 filter
    switch (info.filter) {
        case MeshoptFilter::None:
            // 无后处理
            break;
        case MeshoptFilter::Octahedral:
            meshopt_decodeFilterOct(output.data(), info.count, info.byteStride);
            break;
        case MeshoptFilter::Quaternion:
            meshopt_decodeFilterQuat(output.data(), info.count, info.byteStride);
            break;
        case MeshoptFilter::Exponential:
            meshopt_decodeFilterExp(output.data(), info.count, info.byteStride);
            break;
        default:
            error = "bufferView " + std::to_string(info.bufferViewIndex) +
                " 使用了不支持的 filter";
            return false;
    }

    return true;
}

// ============ 主解码流程 ============

MeshoptDecodeResult DecodeMeshoptGlb(const std::string& inputPath,
                                      const std::string& outputPath)
{
    MeshoptDecodeResult result = {};
    result.success = false;
    result.decodedBufferViewCount = 0;
    result.outputPath = outputPath;

    // 0. 容器预检(规格第七章)
    GlbContainerValidationResult preCheck = ValidateGlbContainerFile(inputPath);
    if (!preCheck.valid) {
        result.errorMessage = "输入 GLB 容器预检失败: " + preCheck.errorMessage;
        result.errorCode = "CONTAINER_PRECHECK_FAILED";
        MC_LOG_ERROR("Input container precheck failed: %{public}s",
                     result.errorMessage.c_str());
        return result;
    }
    MC_LOG_INFO("Input container OK: magic=0x%{public}08X version=%{public}u "
                "headerLen=%{public}u fileSize=%{public}zu "
                "jsonLen=%{public}u binLen=%{public}u",
                preCheck.magic, preCheck.version, preCheck.headerLength,
                preCheck.actualFileSize, preCheck.jsonChunkLength,
                preCheck.binChunkLength);

    // 1. 读取 GLB
    GlbReadResult glb = ReadGlbFile(inputPath);
    if (!glb.valid) {
        result.errorMessage = "读取 GLB 失败: " + glb.errorMessage;
        result.errorCode = "READ_FAILED";
        return result;
    }

    // 2. 解析 JSON
    std::string jsonStr(reinterpret_cast<const char*>(glb.jsonChunk.data),
                        glb.jsonChunk.chunkLength);
    // 移除尾部空格/null
    while (!jsonStr.empty() && (jsonStr.back() == 0 || jsonStr.back() == ' ')) {
        jsonStr.pop_back();
    }

    JsonValue root;
    std::string parseError;
    size_t pos = 0;
    if (!ParseValue(jsonStr, pos, root, parseError)) {
        result.errorMessage = "JSON 解析失败: " + parseError;
        result.errorCode = "JSON_PARSE_FAILED";
        return result;
    }

    // 3. 检查扩展使用情况
    JsonValue* extUsed = FindField(root, "extensionsUsed");
    JsonValue* extRequired = FindField(root, "extensionsRequired");

    std::vector<std::string> usedList;
    std::vector<std::string> requiredList;
    if (extUsed != nullptr) {
        GetStringArray(*extUsed, usedList);
    }
    if (extRequired != nullptr) {
        GetStringArray(*extRequired, requiredList);
    }

    // 记录源扩展
    result.sourceExtensions = usedList;

    // 检查是否使用 EXT_meshopt_compression
    bool hasMeshopt = false;
    for (const auto& ext : usedList) {
        if (ext == "EXT_meshopt_compression") {
            hasMeshopt = true;
            break;
        }
    }
    if (!hasMeshopt) {
        result.errorMessage = "GLB 未使用 EXT_meshopt_compression 扩展";
        result.errorCode = "NO_MESHOPT_EXTENSION";
        return result;
    }

    // 4. 检查 buffers
    JsonValue* buffers = FindField(root, "buffers");
    if (buffers == nullptr || buffers->type != JsonType::Array ||
        buffers->arrayValue.empty()) {
        result.errorMessage = "GLB 缺少 buffers 或 buffers 为空";
        result.errorCode = "NO_BUFFERS";
        return result;
    }

    // 检查 buffer 0 是否有 byteLength
    JsonValue& buffer0 = buffers->arrayValue[0];
    int binBufferLength = 0;
    if (!GetIntField(buffer0, "byteLength", binBufferLength) || binBufferLength < 0) {
        result.errorMessage = "buffers[0] 缺少有效的 byteLength";
        result.errorCode = "INVALID_BUFFER_LENGTH";
        return result;
    }

    // 检查 BIN chunk 是否存在
    if (!glb.hasBin) {
        result.errorMessage = "GLB 缺少 BIN chunk,但使用了 EXT_meshopt_compression";
        result.errorCode = "NO_BIN_CHUNK";
        return result;
    }

    // 校验 BIN chunk 长度与 buffer byteLength
    size_t actualBinSize = glb.binChunk.chunkLength;
    if (static_cast<size_t>(binBufferLength) > actualBinSize) {
        result.warnings.push_back("buffers[0].byteLength=" +
            std::to_string(binBufferLength) + " 超过 BIN chunk 长度 " +
            std::to_string(actualBinSize) + ",使用 BIN chunk 长度");
    }

    const uint8_t* binData = glb.binChunk.data;
    size_t binSize = actualBinSize;

    // 5. 遍历 bufferViews,定位 EXT_meshopt_compression
    JsonValue* bufferViews = FindField(root, "bufferViews");
    if (bufferViews == nullptr || bufferViews->type != JsonType::Array) {
        result.errorMessage = "GLB 缺少 bufferViews";
        result.errorCode = "NO_BUFFER_VIEWS";
        return result;
    }

    std::vector<MeshoptBufferViewInfo> meshoptViews;
    for (size_t i = 0; i < bufferViews->arrayValue.size(); i++) {
        JsonValue& bv = bufferViews->arrayValue[i];
        if (bv.type != JsonType::Object) continue;

        JsonValue* ext = FindField(bv, "extensions");
        if (ext == nullptr || ext->type != JsonType::Object) continue;

        JsonValue* meshoptExt = FindField(*ext, "EXT_meshopt_compression");
        if (meshoptExt == nullptr || meshoptExt->type != JsonType::Object) continue;

        MeshoptBufferViewInfo info = {};
        info.bufferViewIndex = i;
        info.decoded = false;

        int bufferIdx = 0;
        int byteOffset = 0;
        int byteLength = 0;
        int byteStride = 0;
        int count = 0;
        std::string modeStr;
        std::string filterStr = "NONE";

        if (!GetIntField(*meshoptExt, "buffer", bufferIdx)) {
            result.errorMessage = "bufferView " + std::to_string(i) +
                " 的 EXT_meshopt_compression 缺少 buffer 字段";
            result.errorCode = "INVALID_MESHOPT_FIELD";
            return result;
        }
        if (!GetIntField(*meshoptExt, "byteOffset", byteOffset) || byteOffset < 0) {
            result.errorMessage = "bufferView " + std::to_string(i) +
                " 的 EXT_meshopt_compression 缺少有效 byteOffset";
            result.errorCode = "INVALID_MESHOPT_FIELD";
            return result;
        }
        if (!GetIntField(*meshoptExt, "byteLength", byteLength) || byteLength < 0) {
            result.errorMessage = "bufferView " + std::to_string(i) +
                " 的 EXT_meshopt_compression 缺少有效 byteLength";
            result.errorCode = "INVALID_MESHOPT_FIELD";
            return result;
        }
        if (!GetIntField(*meshoptExt, "byteStride", byteStride) || byteStride <= 0) {
            result.errorMessage = "bufferView " + std::to_string(i) +
                " 的 EXT_meshopt_compression 缺少有效 byteStride";
            result.errorCode = "INVALID_MESHOPT_FIELD";
            return result;
        }
        if (!GetIntField(*meshoptExt, "count", count) || count < 0) {
            result.errorMessage = "bufferView " + std::to_string(i) +
                " 的 EXT_meshopt_compression 缺少有效 count";
            result.errorCode = "INVALID_MESHOPT_FIELD";
            return result;
        }

        // mode
        JsonValue* modeField = FindField(*meshoptExt, "mode");
        if (modeField == nullptr || modeField->type != JsonType::String) {
            result.errorMessage = "bufferView " + std::to_string(i) +
                " 的 EXT_meshopt_compression 缺少 mode 字段";
            result.errorCode = "INVALID_MESHOPT_FIELD";
            return result;
        }
        modeStr = modeField->stringValue;
        info.mode = ParseMode(modeStr);
        if (info.mode == MeshoptMode::Unknown) {
            result.errorMessage = "bufferView " + std::to_string(i) +
                " 使用了不支持的 mode: " + modeStr;
            result.errorCode = "UNSUPPORTED_MODE";
            return result;
        }

        // filter(可选,默认 NONE)
        JsonValue* filterField = FindField(*meshoptExt, "filter");
        if (filterField != nullptr && filterField->type == JsonType::String) {
            filterStr = filterField->stringValue;
        }
        info.filter = ParseFilter(filterStr);
        if (info.filter == MeshoptFilter::Unknown) {
            result.errorMessage = "bufferView " + std::to_string(i) +
                " 使用了不支持的 filter: " + filterStr;
            result.errorCode = "UNSUPPORTED_FILTER";
            return result;
        }

        info.buffer = bufferIdx;
        info.byteOffset = static_cast<size_t>(byteOffset);
        info.byteLength = static_cast<size_t>(byteLength);
        info.byteStride = static_cast<size_t>(byteStride);
        info.count = static_cast<size_t>(count);

        // 源 buffer 必须是 0(BIN chunk)
        // meshopt 扩展的 buffer 字段引用的是包含压缩数据的 buffer
        // 通常为 0(BIN),但也可能有外部 buffer
        if (bufferIdx != 0) {
            result.errorMessage = "bufferView " + std::to_string(i) +
                " 的 EXT_meshopt_compression.buffer=" + std::to_string(bufferIdx) +
                " 不支持(仅支持 buffer 0/BIN chunk)";
            result.errorCode = "UNSUPPORTED_BUFFER";
            return result;
        }

        meshoptViews.push_back(info);
    }

    if (meshoptViews.empty()) {
        result.errorMessage = "GLB 声明了 EXT_meshopt_compression 但无实际 bufferView 引用";
        result.errorCode = "NO_MESHOPT_REFERENCES";
        return result;
    }

    // 6. 解码每个 meshopt bufferView
    for (auto& info : meshoptViews) {
        std::string decodeError;
        if (!DecodeMeshoptBufferView(info, binData, binSize,
                                     info.decodedData, decodeError)) {
            result.errorMessage = decodeError;
            result.errorCode = "DECODE_FAILED";
            return result;
        }
        info.decoded = true;
    }

    // 7. 重建 BIN 数据
    // 策略:保留原 BIN 数据,将解码后的数据追加到末尾
    // 然后更新 bufferView 的 byteOffset 指向新位置
    std::vector<uint8_t> newBinData;
    newBinData.insert(newBinData.end(), binData, binData + binSize);

    // 对齐当前 BIN 到 4 字节
    while (newBinData.size() % 4 != 0) {
        newBinData.push_back(0);
    }

    // 追加解码数据并更新 bufferView
    for (const auto& info : meshoptViews) {
        size_t newOffset = newBinData.size();

        // 追加解码数据
        newBinData.insert(newBinData.end(), info.decodedData.begin(),
                          info.decodedData.end());

        // 对齐到 4 字节
        while (newBinData.size() % 4 != 0) {
            newBinData.push_back(0);
        }

        // 更新 bufferView JSON
        JsonValue& bv = bufferViews->arrayValue[info.bufferViewIndex];

        // 更新 buffer(应为 0)
        // 更新 byteOffset
        bool foundOffset = false;
        for (auto& kv : bv.objectValue) {
            if (kv.first == "byteOffset") {
                kv.second.type = JsonType::Number;
                kv.second.numberValue = static_cast<double>(newOffset);
                foundOffset = true;
                break;
            }
        }
        if (!foundOffset) {
            // 如果原来没有 byteOffset(意味着 0),添加
            bv.objectValue.emplace_back("byteOffset", JsonValue());
            bv.objectValue.back().second.type = JsonType::Number;
            bv.objectValue.back().second.numberValue = static_cast<double>(newOffset);
        }

        // 更新 byteLength
        bool foundLength = false;
        size_t decodedLen = info.decodedData.size();
        for (auto& kv : bv.objectValue) {
            if (kv.first == "byteLength") {
                kv.second.type = JsonType::Number;
                kv.second.numberValue = static_cast<double>(decodedLen);
                foundLength = true;
                break;
            }
        }
        if (!foundLength) {
            bv.objectValue.emplace_back("byteLength", JsonValue());
            bv.objectValue.back().second.type = JsonType::Number;
            bv.objectValue.back().second.numberValue = static_cast<double>(decodedLen);
        }

        // 确保 buffer 字段为 0
        bool foundBuffer = false;
        for (auto& kv : bv.objectValue) {
            if (kv.first == "buffer") {
                kv.second.type = JsonType::Number;
                kv.second.numberValue = 0;
                foundBuffer = true;
                break;
            }
        }
        if (!foundBuffer) {
            bv.objectValue.emplace_back("buffer", JsonValue());
            bv.objectValue.back().second.type = JsonType::Number;
            bv.objectValue.back().second.numberValue = 0;
        }

        // 删除 EXT_meshopt_compression 扩展
        JsonValue* ext = FindField(bv, "extensions");
        if (ext != nullptr && ext->type == JsonType::Object) {
            for (auto it = ext->objectValue.begin(); it != ext->objectValue.end(); ) {
                if (it->first == "EXT_meshopt_compression") {
                    it = ext->objectValue.erase(it);
                } else {
                    ++it;
                }
            }
            // 如果 extensions 为空,删除整个 extensions 字段
            if (ext->objectValue.empty()) {
                for (auto it = bv.objectValue.begin(); it != bv.objectValue.end(); ) {
                    if (it->first == "extensions") {
                        it = bv.objectValue.erase(it);
                    } else {
                        ++it;
                    }
                }
            }
        }
    }

    // 8. 更新 buffers[0].byteLength
    for (auto& kv : buffer0.objectValue) {
        if (kv.first == "byteLength") {
            kv.second.type = JsonType::Number;
            kv.second.numberValue = static_cast<double>(newBinData.size());
            break;
        }
    }

    // 9. 从 extensionsUsed 和 extensionsRequired 移除 EXT_meshopt_compression
    if (extUsed != nullptr && extUsed->type == JsonType::Array) {
        for (auto it = extUsed->arrayValue.begin(); it != extUsed->arrayValue.end(); ) {
            if (it->type == JsonType::String && it->stringValue == "EXT_meshopt_compression") {
                it = extUsed->arrayValue.erase(it);
            } else {
                ++it;
            }
        }
        // 如果为空,删除整个字段
        if (extUsed->arrayValue.empty()) {
            for (auto it = root.objectValue.begin(); it != root.objectValue.end(); ) {
                if (it->first == "extensionsUsed") {
                    it = root.objectValue.erase(it);
                } else {
                    ++it;
                }
            }
        }
    }
    if (extRequired != nullptr && extRequired->type == JsonType::Array) {
        for (auto it = extRequired->arrayValue.begin(); it != extRequired->arrayValue.end(); ) {
            if (it->type == JsonType::String && it->stringValue == "EXT_meshopt_compression") {
                it = extRequired->arrayValue.erase(it);
            } else {
                ++it;
            }
        }
        if (extRequired->arrayValue.empty()) {
            for (auto it = root.objectValue.begin(); it != root.objectValue.end(); ) {
                if (it->first == "extensionsRequired") {
                    it = root.objectValue.erase(it);
                } else {
                    ++it;
                }
            }
        }
    }

    // 10. 序列化新 JSON
    std::string newJsonStr;
    SerializeValue(newJsonStr, root);

    std::vector<uint8_t> newJsonData(newJsonStr.begin(), newJsonStr.end());

    // 11. 重建 GLB
    GlbWriteResult writeResult = WriteGlb(newJsonData, newBinData);
    if (!writeResult.success) {
        result.errorMessage = "重建 GLB 失败: " + writeResult.errorMessage;
        result.errorCode = "REBUILD_FAILED";
        return result;
    }

    // 12. 写入临时文件并原子替换
    std::string writeError;
    if (!WriteGlbFile(outputPath, writeResult.outputData, writeError)) {
        result.errorMessage = "写入输出文件失败: " + writeError;
        result.errorCode = "WRITE_FAILED";
        return result;
    }

    // 12.5 输出容器后验证(规格第七章)
    GlbContainerValidationResult postCheck = ValidateGlbContainerFile(outputPath);
    if (!postCheck.valid) {
        result.errorMessage = "输出 GLB 容器后验证失败: " + postCheck.errorMessage;
        result.errorCode = "CONTAINER_POSTCHECK_FAILED";
        MC_LOG_ERROR("Output container postcheck failed: %{public}s",
                     result.errorMessage.c_str());
        // 删除无效输出
        std::remove(outputPath.c_str());
        return result;
    }
    MC_LOG_INFO("Output container OK: magic=0x%{public}08X version=%{public}u "
                "headerLen=%{public}u fileSize=%{public}zu "
                "jsonLen=%{public}u binLen=%{public}u "
                "decoded=%{public}d",
                postCheck.magic, postCheck.version, postCheck.headerLength,
                postCheck.actualFileSize, postCheck.jsonChunkLength,
                postCheck.binChunkLength, static_cast<int>(meshoptViews.size()));

    // 13. 填充结果
    result.success = true;
    result.decodedBufferViewCount = static_cast<int>(meshoptViews.size());
    result.outputGlbData = std::move(writeResult.outputData);

    // 计算 remainingExtensions
    if (extUsed != nullptr) {
        GetStringArray(*extUsed, result.remainingExtensions);
    }

    return result;
}

} // namespace model_converter
