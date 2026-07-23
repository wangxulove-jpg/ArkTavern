# ArkTavern Native: meshopt GLB 解码器
# T-3D.6C-C 阶段 3: EXT_meshopt_compression 解码 + 标准 GLB 重建
#
# 输出模块: libmodel_converter.so
# ArkTS 通过 import('model_converter') 引用

cmake_minimum_required(VERSION 3.16)

project(model_converter)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# 覆盖 hvigor 设置的 CMAKE_LIBRARY_OUTPUT_DIRECTORY
# 原因:hvigor 将输出目录设为 intermediates 路径(正斜杠),
# syncLibOutputs 在 Windows 上因正/反斜杠不匹配无法识别源=目标,
# 导致 linkFile 先 unlink 目标(即源本身)再 link 失败,最终 copyFile 报 ENOENT。
# 输出到 .cxx 构建目录后,syncLibOutputs 可正常从构建目录复制到 intermediates。
set(CMAKE_LIBRARY_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/libs)

# NAPI 头文件位于 sysroot/usr/include/napi/
# sysroot 已由 OHOS 工具链默认包含,无需额外 include_directories

# meshoptimizer 源码(仅解码相关)
set(MESHOPT_SRC
    ${CMAKE_CURRENT_SOURCE_DIR}/third_party/meshoptimizer_src/src/allocator.cpp
    ${CMAKE_CURRENT_SOURCE_DIR}/third_party/meshoptimizer_src/src/indexcodec.cpp
    ${CMAKE_CURRENT_SOURCE_DIR}/third_party/meshoptimizer_src/src/vertexcodec.cpp
    ${CMAKE_CURRENT_SOURCE_DIR}/third_party/meshoptimizer_src/src/vertexfilter.cpp
    ${CMAKE_CURRENT_SOURCE_DIR}/third_party/meshoptimizer_src/src/quantization.cpp
)

# model_converter 源码
set(MODEL_CONVERTER_SRC
    ${CMAKE_CURRENT_SOURCE_DIR}/model_converter/GlbBinaryReader.cpp
    ${CMAKE_CURRENT_SOURCE_DIR}/model_converter/GlbBinaryWriter.cpp
    ${CMAKE_CURRENT_SOURCE_DIR}/model_converter/GlbContainerValidator.cpp
    ${CMAKE_CURRENT_SOURCE_DIR}/model_converter/MeshoptGlbDecoder.cpp
    ${CMAKE_CURRENT_SOURCE_DIR}/model_converter/ModelConverterNapi.cpp
    ${CMAKE_CURRENT_SOURCE_DIR}/napi_init.cpp
)

add_library(model_converter SHARED
    ${MESHOPT_SRC}
    ${MODEL_CONVERTER_SRC}
)

target_compile_definitions(model_converter PRIVATE __OHOS__=1)

target_include_directories(model_converter PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/third_party/meshoptimizer_src/src
    ${CMAKE_CURRENT_SOURCE_DIR}/model_converter
)

# 链接 NAPI 运行时与 OHOS 基础库
target_link_libraries(model_converter PUBLIC
    libace_napi.z.so
    libhilog_ndk.z.so
)
