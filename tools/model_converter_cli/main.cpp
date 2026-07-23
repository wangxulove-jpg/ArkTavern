/**
 * model_converter_cli - 主机端 GLB meshopt 转换 CLI
 * T-3D.6C-C3
 *
 * 用途:
 * 在 Windows 主机端复用 Native 转换代码,独立验证 GLB 容器结构。
 * 不依赖 HarmonyOS NAPI 或设备。
 *
 * 编译(使用 DevEco SDK clang++):
 * clang++ -std=c++17 -I../../entry/src/main/cpp/model_converter \
 *         -I../../entry/src/main/cpp/third_party/meshoptimizer_src/src \
 *         main.cpp \
 *         ../../entry/src/main/cpp/model_converter/GlbBinaryReader.cpp \
 *         ../../entry/src/main/cpp/model_converter/GlbBinaryWriter.cpp \
 *         ../../entry/src/main/cpp/model_converter/GlbContainerValidator.cpp \
 *         ../../entry/src/main/cpp/model_converter/MeshoptGlbDecoder.cpp \
 *         ../../entry/src/main/cpp/third_party/meshoptimizer_src/src/allocator.cpp \
 *         ../../entry/src/main/cpp/third_party/meshoptimizer_src/src/indexcodec.cpp \
 *         ../../entry/src/main/cpp/third_party/meshoptimizer_src/src/vertexcodec.cpp \
 *         ../../entry/src/main/cpp/third_party/meshoptimizer_src/src/vertexfilter.cpp \
 *         ../../entry/src/main/cpp/third_party/meshoptimizer_src/src/quantization.cpp \
 *         -o model_converter_cli.exe
 *
 * 用法:
 * model_converter_cli.exe <input.glb> <output.glb>
 */

#include <cstdio>
#include <cstdlib>
#include <string>

#include "GlbBinaryReader.h"
#include "GlbBinaryWriter.h"
#include "GlbContainerValidator.h"
#include "MeshoptGlbDecoder.h"

static void PrintHex(const uint8_t* data, size_t offset, size_t length)
{
    size_t end = offset + length;
    for (size_t i = offset; i < end; i++) {
        printf("%02X ", data[i]);
    }
    printf("\n");
}

static void PrintContainerMetadata(const model_converter::GlbContainerValidationResult& v)
{
    printf("=== GLB Container Metadata ===\n");
    printf("magic:            0x%08X\n", v.magic);
    printf("version:          %u\n", v.version);
    printf("headerLength:     %u\n", v.headerLength);
    printf("actualFileSize:   %zu\n", v.actualFileSize);
    printf("jsonChunkOffset:  %zu\n", v.jsonChunkOffset);
    printf("jsonChunkLength:  %u (aligned: %s)\n", v.jsonChunkLength,
           (v.jsonChunkLength % 4 == 0) ? "yes" : "no");
    printf("jsonChunkType:    0x%08X\n", v.jsonChunkType);
    printf("jsonFirstByte:    0x%02X ('%c')\n", v.jsonFirstByte,
           (v.jsonFirstByte >= 0x20 && v.jsonFirstByte < 0x7F) ? v.jsonFirstByte : '?');
    printf("hasBin:           %s\n", v.hasBin ? "yes" : "no");
    if (v.hasBin) {
        printf("binChunkOffset:   %zu\n", v.binChunkOffset);
        printf("binChunkLength:   %u (aligned: %s)\n", v.binChunkLength,
               (v.binChunkLength % 4 == 0) ? "yes" : "no");
        printf("binChunkType:     0x%08X\n", v.binChunkType);
    }
    if (!v.warnings.empty()) {
        printf("warnings:\n");
        for (const std::string& w : v.warnings) {
            printf("  - %s\n", w.c_str());
        }
    }
}

int main(int argc, char** argv)
{
    if (argc < 3) {
        printf("Usage: %s <input.glb> <output.glb>\n", argv[0]);
        return 1;
    }

    std::string inputPath = argv[1];
    std::string outputPath = argv[2];

    printf("=== Input File ===\n");
    printf("path: %s\n", inputPath.c_str());

    // 1. 容器预检
    printf("\n=== Step 1: Container Pre-validation ===\n");
    auto preCheck = model_converter::ValidateGlbContainerFile(inputPath);
    PrintContainerMetadata(preCheck);
    if (!preCheck.valid) {
        printf("\nFAIL: %s\n", preCheck.errorMessage.c_str());
        return 2;
    }
    printf("Container pre-validation: PASS\n");

    // 2. 读取 GLB
    printf("\n=== Step 2: Read GLB ===\n");
    auto readResult = model_converter::ReadGlbFile(inputPath);
    if (!readResult.valid) {
        printf("FAIL: %s\n", readResult.errorMessage.c_str());
        return 3;
    }
    printf("Read GLB: PASS (totalLength=%u, hasBin=%d)\n",
           readResult.totalLength, readResult.hasBin);

    // 3. 前 32 字节十六进制
    printf("\n=== First 32 bytes ===\n");
    PrintHex(readResult.fileData.data(), 0, 32);

    // 4. 解码 meshopt
    printf("\n=== Step 3: Decode Meshopt ===\n");
    auto decodeResult = model_converter::DecodeMeshoptGlb(inputPath, outputPath);
    printf("success:                  %s\n", decodeResult.success ? "true" : "false");
    printf("errorCode:                %s\n", decodeResult.errorCode.c_str());
    printf("errorMessage:             %s\n", decodeResult.errorMessage.c_str());
    printf("decodedBufferViewCount:   %d\n", decodeResult.decodedBufferViewCount);
    printf("outputPath:               %s\n", decodeResult.outputPath.c_str());

    printf("sourceExtensions:         [");
    for (size_t i = 0; i < decodeResult.sourceExtensions.size(); i++) {
        if (i > 0) printf(", ");
        printf("%s", decodeResult.sourceExtensions[i].c_str());
    }
    printf("]\n");

    printf("remainingExtensions:      [");
    for (size_t i = 0; i < decodeResult.remainingExtensions.size(); i++) {
        if (i > 0) printf(", ");
        printf("%s", decodeResult.remainingExtensions[i].c_str());
    }
    printf("]\n");

    printf("warnings:                 [");
    for (size_t i = 0; i < decodeResult.warnings.size(); i++) {
        if (i > 0) printf(", ");
        printf("%s", decodeResult.warnings[i].c_str());
    }
    printf("]\n");

    if (!decodeResult.success) {
        printf("\nDECODE FAILED\n");
        return 4;
    }

    // 5. 输出文件容器验证
    printf("\n=== Step 4: Output Container Validation ===\n");
    auto postCheck = model_converter::ValidateGlbContainerFile(outputPath);
    PrintContainerMetadata(postCheck);
    if (!postCheck.valid) {
        printf("\nFAIL: %s\n", postCheck.errorMessage.c_str());
        return 5;
    }
    printf("Output container validation: PASS\n");

    // 6. 输出文件前 32 字节
    printf("\n=== Output first 32 bytes ===\n");
    auto outRead = model_converter::ReadGlbFile(outputPath);
    if (outRead.valid) {
        PrintHex(outRead.fileData.data(), 0, 32);
    }

    printf("\n=== ALL CHECKS PASSED ===\n");
    return 0;
}
