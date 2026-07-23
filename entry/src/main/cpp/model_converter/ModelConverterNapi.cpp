/**
 * ModelConverterNapi 实现
 * T-3D.6C-C 阶段 3
 *
 * 使用 napi_create_async_work 在子线程执行解码,避免阻塞 UI 线程。
 */

#include "ModelConverterNapi.h"
#include "MeshoptGlbDecoder.h"

#include <algorithm>
#include <cstring>
#include <errno.h>
#include <fstream>
#include <memory>
#include <string>
#include <unistd.h>
#include <vector>

namespace model_converter {

// 异步工作数据
struct AsyncWorkData {
    napi_async_work work;
    napi_deferred deferred;

    // 输入
    std::string inputPath;
    std::string outputPath;

    // 输出(在 worker 线程填充)
    MeshoptDecodeResult decodeResult;
};

// 创建字符串 napi_value
static napi_value CreateString(napi_env env, const std::string& str)
{
    napi_value value;
    napi_create_string_utf8(env, str.c_str(), str.size(), &value);
    return value;
}

// 创建字符串数组 napi_value
static napi_value CreateStringArray(napi_env env, const std::vector<std::string>& arr)
{
    napi_value array;
    napi_create_array_with_length(env, arr.size(), &array);
    for (size_t i = 0; i < arr.size(); i++) {
        napi_value elem = CreateString(env, arr[i]);
        napi_set_element(env, array, static_cast<uint32_t>(i), elem);
    }
    return array;
}

// 将 MeshoptDecodeResult 转换为 JS 对象
static napi_value CreateResultObject(napi_env env, const MeshoptDecodeResult& result)
{
    napi_value obj;
    napi_create_object(env, &obj);

    // success: boolean
    napi_value success;
    napi_get_boolean(env, result.success, &success);
    napi_set_named_property(env, obj, "success", success);

    // outputPath: string
    napi_set_named_property(env, obj, "outputPath", CreateString(env, result.outputPath.empty() ? "" : result.outputPath));

    // decodedBufferViewCount: number
    napi_value count;
    napi_create_int32(env, result.decodedBufferViewCount, &count);
    napi_set_named_property(env, obj, "decodedBufferViewCount", count);

    // sourceExtensions: string[]
    napi_set_named_property(env, obj, "sourceExtensions",
        CreateStringArray(env, result.sourceExtensions));

    // remainingExtensions: string[]
    napi_set_named_property(env, obj, "remainingExtensions",
        CreateStringArray(env, result.remainingExtensions));

    // warnings: string[]
    napi_set_named_property(env, obj, "warnings",
        CreateStringArray(env, result.warnings));

    // errorCode: string
    napi_set_named_property(env, obj, "errorCode", CreateString(env, result.errorCode));

    // errorMessage: string
    napi_set_named_property(env, obj, "errorMessage", CreateString(env, result.errorMessage));

    return obj;
}

// 异步执行函数(在 worker 线程运行)
static void ExecuteAsync(napi_env env, void* data)
{
    AsyncWorkData* workData = static_cast<AsyncWorkData*>(data);
    workData->decodeResult = DecodeMeshoptGlb(workData->inputPath, workData->outputPath);
    // 填充 outputPath 用于返回(即使失败也可能有部分路径信息)
    if (workData->decodeResult.success) {
        workData->decodeResult.outputPath = workData->outputPath;
    }
}

// 异步完成函数(在主线程运行)
static void CompleteAsync(napi_env env, napi_status status, void* data)
{
    AsyncWorkData* workData = static_cast<AsyncWorkData*>(data);

    // 始终 resolve:ArkTS 侧通过 result.success 判断成败,
    // 避免 reject 非 Error 对象导致 errorMessage 丢失
    napi_value resultObj = CreateResultObject(env, workData->decodeResult);
    napi_resolve_deferred(env, workData->deferred, resultObj);

    napi_delete_async_work(env, workData->work);
    delete workData;
}

napi_value ModelConverterNapi::DecodeMeshoptGlb(napi_env env, napi_callback_info info)
{
    size_t argc = 2;
    napi_value args[2];
    napi_value thisArg;
    napi_get_cb_info(env, info, &argc, args, &thisArg, nullptr);

    if (argc < 2) {
        napi_throw_type_error(env, nullptr, "需要 2 个参数: inputPath, outputPath");
        return nullptr;
    }

    // 读取 inputPath
    size_t pathLen = 0;
    napi_get_value_string_utf8(env, args[0], nullptr, 0, &pathLen);
    std::string inputPath(pathLen, '\0');
    napi_get_value_string_utf8(env, args[0], &inputPath[0], pathLen + 1, &pathLen);

    // 读取 outputPath
    size_t outLen = 0;
    napi_get_value_string_utf8(env, args[1], nullptr, 0, &outLen);
    std::string outputPath(outLen, '\0');
    napi_get_value_string_utf8(env, args[1], &outputPath[0], outLen + 1, &outLen);

    // 创建 Promise
    napi_value promise;
    napi_deferred deferred;
    napi_create_promise(env, &deferred, &promise);

    // 创建异步工作数据
    auto workData = new AsyncWorkData();
    workData->work = nullptr;
    workData->deferred = deferred;
    workData->inputPath = std::move(inputPath);
    workData->outputPath = std::move(outputPath);

    // 创建异步工作
    napi_value resourceName;
    napi_create_string_utf8(env, "decodeMeshoptGlb", NAPI_AUTO_LENGTH, &resourceName);

    napi_status status = napi_create_async_work(env, nullptr, resourceName,
        ExecuteAsync, CompleteAsync, workData, &workData->work);
    if (status != napi_ok) {
        delete workData;
        napi_throw_error(env, "CREATE_WORK_FAILED", "创建异步工作失败");
        return nullptr;
    }

    napi_queue_async_work(env, workData->work);

    return promise;
}

// T-3D.6C-C3 Debug: 同步复制文件
napi_value ModelConverterNapi::CopyFile(napi_env env, napi_callback_info info)
{
    size_t argc = 2;
    napi_value args[2];
    napi_value thisArg;
    napi_get_cb_info(env, info, &argc, args, &thisArg, nullptr);

    napi_value resultObj;
    napi_create_object(env, &resultObj);

    auto setResult = [&](bool success, const std::string& errorMsg, int64_t bytesCopied) {
        napi_value successVal;
        napi_get_boolean(env, success, &successVal);
        napi_set_named_property(env, resultObj, "success", successVal);

        napi_value errMsgVal;
        napi_create_string_utf8(env, errorMsg.c_str(), errorMsg.size(), &errMsgVal);
        napi_set_named_property(env, resultObj, "errorMessage", errMsgVal);

        napi_value bytesVal;
        napi_create_int64(env, bytesCopied, &bytesVal);
        napi_set_named_property(env, resultObj, "bytesCopied", bytesVal);
    };

    if (argc < 2) {
        setResult(false, "需要 2 个参数: srcPath, dstPath", 0);
        return resultObj;
    }

    // 读取 srcPath
    size_t srcLen = 0;
    napi_get_value_string_utf8(env, args[0], nullptr, 0, &srcLen);
    std::string srcPath(srcLen, '\0');
    napi_get_value_string_utf8(env, args[0], &srcPath[0], srcLen + 1, &srcLen);

    // 读取 dstPath
    size_t dstLen = 0;
    napi_get_value_string_utf8(env, args[1], nullptr, 0, &dstLen);
    std::string dstPath(dstLen, '\0');
    napi_get_value_string_utf8(env, args[1], &dstPath[0], dstLen + 1, &dstLen);

    // 使用 C++ 文件流复制(绕过 ArkTS 文件访问限制)
    std::ifstream srcFile(srcPath, std::ios::binary);
    if (!srcFile.is_open()) {
        setResult(false, "无法打开源文件: " + srcPath, 0);
        return resultObj;
    }

    std::ofstream dstFile(dstPath, std::ios::binary | std::ios::trunc);
    if (!dstFile.is_open()) {
        setResult(false, "无法创建目标文件: " + dstPath, 0);
        srcFile.close();
        return resultObj;
    }

    // 获取源文件大小
    srcFile.seekg(0, std::ios::end);
    std::streamsize fileSize = srcFile.tellg();
    srcFile.seekg(0, std::ios::beg);

    if (fileSize <= 0) {
        setResult(false, "源文件为空或读取大小失败: " + srcPath, 0);
        srcFile.close();
        dstFile.close();
        return resultObj;
    }

    // 分块复制(避免一次性分配大内存)
    const size_t bufferSize = 4 * 1024 * 1024; // 4MB
    std::vector<char> buffer(bufferSize);
    int64_t totalCopied = 0;

    while (totalCopied < fileSize) {
        std::streamsize toRead = static_cast<std::streamsize>(
            std::min(static_cast<size_t>(fileSize - totalCopied), bufferSize));
        srcFile.read(buffer.data(), toRead);
        std::streamsize readBytes = srcFile.gcount();
        if (readBytes <= 0) {
            setResult(false, "读取源文件失败,已复制 " + std::to_string(totalCopied) + " 字节", totalCopied);
            srcFile.close();
            dstFile.close();
            return resultObj;
        }
        dstFile.write(buffer.data(), readBytes);
        if (!dstFile.good()) {
            setResult(false, "写入目标文件失败,已复制 " + std::to_string(totalCopied) + " 字节", totalCopied);
            srcFile.close();
            dstFile.close();
            return resultObj;
        }
        totalCopied += readBytes;
    }

    srcFile.close();
    dstFile.close();

    setResult(true, "", totalCopied);
    return resultObj;
}

// T-3D.6C-C3 Debug: 异步从 rawfile fd 复制到目标路径(避免阻塞 UI 线程)
struct CopyFileFromFdWorkData {
    napi_async_work work;
    napi_deferred deferred;

    // 输入
    int32_t fd;
    int64_t offset;
    int64_t length;
    std::string dstPath;

    // 输出
    bool success;
    std::string errorMessage;
    int64_t bytesCopied;
};

// 异步执行(子线程)
static void ExecuteCopyFileFromFd(napi_env env, void* data)
{
    CopyFileFromFdWorkData* workData = static_cast<CopyFileFromFdWorkData*>(data);
    workData->success = false;
    workData->errorMessage = "";
    workData->bytesCopied = 0;

    if (workData->length <= 0) {
        workData->errorMessage = "length 必须 > 0";
        return;
    }

    std::ofstream dstFile(workData->dstPath, std::ios::binary | std::ios::trunc);
    if (!dstFile.is_open()) {
        workData->errorMessage = "无法创建目标文件: " + workData->dstPath;
        return;
    }

    const size_t bufferSize = 4 * 1024 * 1024; // 4MB
    std::vector<char> buffer(bufferSize);

    while (workData->bytesCopied < workData->length) {
        size_t toRead = static_cast<size_t>(
            std::min(static_cast<int64_t>(bufferSize), workData->length - workData->bytesCopied));
        ssize_t readBytes = pread64(workData->fd, buffer.data(), toRead,
            workData->offset + workData->bytesCopied);
        if (readBytes <= 0) {
            workData->errorMessage = "读取 fd 失败,已复制 " + std::to_string(workData->bytesCopied)
                + " 字节, errno=" + std::to_string(errno);
            dstFile.close();
            return;
        }
        dstFile.write(buffer.data(), static_cast<std::streamsize>(readBytes));
        if (!dstFile.good()) {
            workData->errorMessage = "写入目标文件失败,已复制 " + std::to_string(workData->bytesCopied) + " 字节";
            dstFile.close();
            return;
        }
        workData->bytesCopied += readBytes;
    }

    dstFile.close();
    workData->success = true;
}

// 异步完成(主线程)
static void CompleteCopyFileFromFd(napi_env env, napi_status status, void* data)
{
    CopyFileFromFdWorkData* workData = static_cast<CopyFileFromFdWorkData*>(data);

    napi_value resultObj;
    napi_create_object(env, &resultObj);

    napi_value successVal;
    napi_get_boolean(env, workData->success, &successVal);
    napi_set_named_property(env, resultObj, "success", successVal);

    napi_value errMsgVal;
    napi_create_string_utf8(env, workData->errorMessage.c_str(),
        workData->errorMessage.size(), &errMsgVal);
    napi_set_named_property(env, resultObj, "errorMessage", errMsgVal);

    napi_value bytesVal;
    napi_create_int64(env, workData->bytesCopied, &bytesVal);
    napi_set_named_property(env, resultObj, "bytesCopied", bytesVal);

    napi_resolve_deferred(env, workData->deferred, resultObj);

    napi_delete_async_work(env, workData->work);
    delete workData;
}

napi_value ModelConverterNapi::CopyFileFromFd(napi_env env, napi_callback_info info)
{
    size_t argc = 4;
    napi_value args[4];
    napi_value thisArg;
    napi_get_cb_info(env, info, &argc, args, &thisArg, nullptr);

    if (argc < 4) {
        napi_throw_type_error(env, nullptr, "需要 4 个参数: fd, offset, length, dstPath");
        return nullptr;
    }

    // 读取 fd
    int32_t fd = 0;
    napi_get_value_int32(env, args[0], &fd);

    // 读取 offset
    int64_t offset = 0;
    napi_get_value_int64(env, args[1], &offset);

    // 读取 length
    int64_t length = 0;
    napi_get_value_int64(env, args[2], &length);

    // 读取 dstPath
    size_t dstLen = 0;
    napi_get_value_string_utf8(env, args[3], nullptr, 0, &dstLen);
    std::string dstPath(dstLen, '\0');
    napi_get_value_string_utf8(env, args[3], &dstPath[0], dstLen + 1, &dstLen);

    // 创建 Promise
    napi_value promise;
    napi_deferred deferred;
    napi_create_promise(env, &deferred, &promise);

    auto workData = new CopyFileFromFdWorkData();
    workData->work = nullptr;
    workData->deferred = deferred;
    workData->fd = fd;
    workData->offset = offset;
    workData->length = length;
    workData->dstPath = std::move(dstPath);
    workData->success = false;
    workData->errorMessage = "";
    workData->bytesCopied = 0;

    napi_value resourceName;
    napi_create_string_utf8(env, "copyFileFromFd", NAPI_AUTO_LENGTH, &resourceName);

    napi_status status = napi_create_async_work(env, nullptr, resourceName,
        ExecuteCopyFileFromFd, CompleteCopyFileFromFd, workData, &workData->work);
    if (status != napi_ok) {
        delete workData;
        napi_throw_error(env, "CREATE_WORK_FAILED", "创建异步工作失败");
        return nullptr;
    }

    napi_queue_async_work(env, workData->work);
    return promise;
}

} // namespace model_converter
