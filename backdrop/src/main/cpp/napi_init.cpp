#include "napi/native_api.h"
#include "hilog/log.h"
#include "glass/glass_napi.h"

// 避免工程侧未定义 LOG_DOMAIN 时编译失败
#ifndef LOG_DOMAIN
#define LOG_DOMAIN 0x0000
#endif

EXTERN_C_START
static napi_value Init(napi_env env, napi_value exports) {
    napi_property_descriptor desc[] = {
        // ---- GLES 自渲染（pages/GlassPage.ets 用）----
        {"GlassGLBindNode", nullptr, glass::BindNode, nullptr, nullptr, nullptr, napi_default, nullptr},
    {"GlassGLRegisterConsumer", nullptr, glass::GlassGLRegisterConsumer, nullptr, nullptr, nullptr, napi_default, nullptr},
    {"GlassGLUnregisterConsumer", nullptr, glass::GlassGLUnregisterConsumer, nullptr, nullptr, nullptr, napi_default, nullptr},
    {"GlassGLSetScrollRegion", nullptr, glass::GlassGLSetScrollRegion, nullptr, nullptr, nullptr, napi_default, nullptr},

        {"GlassGLUnbindNode", nullptr, glass::UnbindNode, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"GlassGLSetNumber", nullptr, glass::SetNumber, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"GlassGLSetBool", nullptr, glass::SetBool, nullptr, nullptr, nullptr, napi_default, nullptr},
        // ---- 目录场景（pages/catalog/*）----
        {"GlassGLSetScene", nullptr, glass::SetScene, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"GlassGLSetDensity", nullptr, glass::SetDensity, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"GlassGLSetDarkMode", nullptr, glass::SetDarkMode, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"GlassGLSetDebugMode", nullptr, glass::SetDebugMode, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"GlassGLSetPaused", nullptr, glass::SetPaused, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"GlassGLIsRunning", nullptr, glass::IsRunning, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"GlassGLSetPhoto", nullptr, glass::SetPhoto, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"GlassGLSetContentBackdrop", nullptr, glass::SetContentBackdrop, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"GlassGLGetContentSurfaceId", nullptr, glass::GetContentSurfaceId, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"GlassGLHasContentFrame", nullptr, glass::HasContentFrame, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"GlassGLRegisterMenuCallback", nullptr, glass::RegisterMenuCallback, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"GlassGLUnregisterMenuCallback", nullptr, glass::UnregisterMenuCallback, nullptr, nullptr, nullptr, napi_default, nullptr},
        // ---- HallPass 集成：叠加模式 / 可配置页签 / 背景快照 / 页签切换回链 ----
        {"GlassGLSetBackdrop", nullptr, glass::SetBackdrop, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"GlassGLSetBackdropShift", nullptr, glass::SetBackdropShift, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"GlassGLSetMirrorOffset", nullptr, glass::SetMirrorOffset, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"GlassGLSetContentOffset", nullptr, glass::SetContentOffset, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"GlassGLSetContentBand", nullptr, glass::SetContentBand, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"GlassGLGetContentShift", nullptr, glass::GetContentShift, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"GlassGLGetFrameMirrorOffset", nullptr, glass::GetFrameMirrorOffset, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"GlassGLGetContentFrameCount", nullptr, glass::GetContentFrameCount, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"GlassGLSetOverlayMode", nullptr, glass::SetOverlayMode, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"GlassGLSetDemoChrome", nullptr, glass::SetDemoChrome, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"GlassGLSetTabs", nullptr, glass::SetTabs, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"GlassGLSetSelectedTab", nullptr, glass::SetSelectedTab, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"GlassGLRegisterTabCallback", nullptr, glass::RegisterTabCallback, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"GlassGLUnregisterTabCallback", nullptr, glass::UnregisterTabCallback, nullptr, nullptr, nullptr, napi_default, nullptr},
        // ---- HallPass 集成：内联玻璃控件（开关 / 滑块）----
        {"GlassGLWidgetConfigure", nullptr, glass::WidgetConfigure, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"GlassGLWidgetSetState", nullptr, glass::WidgetSetState, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"GlassGLWidgetSetPress", nullptr, glass::WidgetSetPress, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"GlassGLWidgetSetColors", nullptr, glass::WidgetSetColors, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"GlassGLWidgetIsRunning", nullptr, glass::WidgetIsRunning, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"GlassGLWidgetDispose", nullptr, glass::WidgetDispose, nullptr, nullptr, nullptr, napi_default, nullptr},
        // ---- HallPass 集成：玻璃对话框（Dialog）----
        {"GlassGLDialogConfigure", nullptr, glass::DialogConfigure, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"GlassGLDialogSetBackdrop", nullptr, glass::DialogSetBackdrop, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"GlassGLDialogSetPress", nullptr, glass::DialogSetPress, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"GlassGLDialogSetGeometry", nullptr, glass::DialogSetGeometry, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"GlassGLDialogDispose", nullptr, glass::DialogDispose, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"GlassGLDialogIsReady", nullptr, glass::DialogIsReady, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"GlassGLDialogSetBackdropRect", nullptr, glass::DialogSetBackdropRect, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"GlassGLDialogSetLiveRect", nullptr, glass::DialogSetLiveRect, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"GlassGLDialogSetTransform", nullptr, glass::DialogSetTransform, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"GlassGLSetContentExport", nullptr, glass::SetContentExport, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"GlassGLSharedBackdropReady", nullptr, glass::SharedBackdropReady, nullptr, nullptr, nullptr, napi_default, nullptr},
    };
    napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
    // 若本次 Init 是 XComponent({libraryname:'backdrop'}) 触发的，注册经典 Surface 生命周期回调
    glass::RegisterNativeXComponent(env, exports);
    return exports;
}
EXTERN_C_END

static napi_module demoModule = {
    .nm_version = 1,
    .nm_flags = 0,
    .nm_filename = nullptr,
    .nm_register_func = Init,
    .nm_modname = "backdrop",
    .nm_priv = ((void*)0),
    .reserved = { 0 },
};

extern "C" __attribute__((constructor)) void RegisterBackdropModule(void)
{
    napi_module_register(&demoModule);
}
