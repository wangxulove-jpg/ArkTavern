/**
 * NAPI 模块注册入口
 * T-3D.6C-C 阶段 3: meshopt GLB 解码器
 *
 * 模块名: model_converter
 * ArkTS 通过 import('model_converter') 引用
 */

#include "napi/native_api.h"
#include "model_converter/ModelConverterNapi.h"

using model_converter::ModelConverterNapi;

static napi_value Init(napi_env env, napi_value exports)
{
    napi_property_descriptor desc[] = {
        {"decodeMeshoptGlb", nullptr, ModelConverterNapi::DecodeMeshoptGlb, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"copyFile", nullptr, ModelConverterNapi::CopyFile, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"copyFileFromFd", nullptr, ModelConverterNapi::CopyFileFromFd, nullptr, nullptr, nullptr, napi_default, nullptr},
    };
    napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
    return exports;
}

static napi_module modelConverterModule = {
    .nm_version = 1,
    .nm_flags = 0,
    .nm_filename = nullptr,
    .nm_register_func = Init,
    .nm_modname = "model_converter",
    .nm_priv = ((void *)0),
    .reserved = {0},
};

extern "C" __attribute__((constructor)) void RegisterModelConverterModule(void)
{
    napi_module_register(&modelConverterModule);
}
