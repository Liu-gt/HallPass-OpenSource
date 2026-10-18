#include "glass_napi.h"

#include <ace/xcomponent/native_interface_xcomponent.h>
#include <arkui/native_node.h>
#include <arkui/native_node_napi.h>
#include <hilog/log.h>
#include <native_window/external_window.h>

#include <cstdint>
#include <cstring>
#include <mutex>
#include <string>
#include <unordered_map>
#include <vector>

#include "gles_renderer.h"

#undef LOG_TAG
#undef LOG_DOMAIN
#define LOG_TAG "GLASS"
#define LOG_DOMAIN 0x0000

#define GLOG(...) OH_LOG_Print(LOG_APP, LOG_INFO, LOG_DOMAIN, LOG_TAG, __VA_ARGS__)
#define GERR(...) OH_LOG_Print(LOG_APP, LOG_ERROR, LOG_DOMAIN, LOG_TAG, __VA_ARGS__)

namespace glass {

namespace {

constexpr uint32_t kMaxIdLen = 128;

ArkUI_NodeHandle g_node = nullptr;
OH_ArkUI_SurfaceHolder *g_holder = nullptr;
OH_ArkUI_SurfaceCallback *g_callback = nullptr;

// ---------------------------------------------------------------------------
// 内联玻璃控件（开关 / 滑块）的渲染器注册表
//
// 与页签条不同：每个控件 XComponent 一个 GlesRenderer 实例（各自 EGL 上下文 +
// 常驻但按需唤醒的渲染线程）。实例按 XComponent id 寻址，id 前缀决定控件种类：
//   glassToggle_* -> kWidgetToggle；glassSlider_* -> kWidgetSlider
// ArkTS 侧组件（GlassToggle / GlassSlider）在 aboutToAppear 里 Configure，
// 在 aboutToDisappear 里 Dispose。
// ---------------------------------------------------------------------------

struct WidgetEntry {
    GlesRenderer *renderer = nullptr;
};

std::mutex g_widgetMutex;
std::unordered_map<std::string, WidgetEntry> g_widgets;

/**
 * 僵尸实例：surface 拆除时渲染线程卡在 GL 调用里、join 超时的控件渲染器。
 *
 * 这时**不能删**（线程还会用它的成员），先挂在这里；下次建控件时若线程已退出
 * 再 join + delete。join 超时上限远小于 UI 卡死（实测有 9 秒的 eglSwapBuffers
 * 阻塞），保证拆控件不把 UI 线程拖住。
 */
constexpr int kWidgetJoinTimeoutMs = 600;
std::vector<GlesRenderer *> g_widgetZombies;

/** 回收线程已退出的僵尸实例。调用方必须持有 g_widgetMutex。 */
void ReapWidgetZombiesLocked() {
    for (auto it = g_widgetZombies.begin(); it != g_widgetZombies.end();) {
        GlesRenderer *zombie = *it;
        if (zombie != nullptr && zombie->IsThreadExited()) {
            zombie->OnSurfaceDestroyed();   // 线程已退出，join 立即返回
            delete zombie;
            it = g_widgetZombies.erase(it);
        } else {
            ++it;
        }
    }
}

bool IsWidgetId(const std::string &id) {
    return id.rfind("glassToggle", 0) == 0 || id.rfind("glassSlider", 0) == 0;
}

int WidgetKindFromId(const std::string &id) {
    return id.rfind("glassSlider", 0) == 0 ? GlesRenderer::kWidgetSlider
                                           : GlesRenderer::kWidgetToggle;
}

std::string ReadId(napi_env env, napi_value value) {
    size_t len = 0;
    if (napi_get_value_string_utf8(env, value, nullptr, 0, &len) != napi_ok) {
        return std::string();
    }
    std::vector<char> buf(len + 1, '\0');
    napi_get_value_string_utf8(env, value, buf.data(), buf.size(), &len);
    return std::string(buf.data(), len);
}

GlesRenderer *FindWidget(const std::string &id) {
    std::lock_guard<std::mutex> lock(g_widgetMutex);
    auto it = g_widgets.find(id);
    return it == g_widgets.end() ? nullptr : it->second.renderer;
}

GlesRenderer *GetOrCreateWidget(const std::string &id) {
    std::lock_guard<std::mutex> lock(g_widgetMutex);
    ReapWidgetZombiesLocked();
    auto it = g_widgets.find(id);
    if (it != g_widgets.end()) {
        return it->second.renderer;
    }
    GlesRenderer *renderer = GlesRenderer::CreateInstance();
    renderer->SetWidgetKind(WidgetKindFromId(id));
    g_widgets.emplace(id, WidgetEntry{renderer});
    GLOG("widget renderer created: id=%{public}s", id.c_str());
    return renderer;
}

/** 停掉线程并删除实例（surface 销毁 / ArkTS 卸载都会走到，重复调用安全）。 */
void DestroyWidget(const std::string &id) {
    GlesRenderer *renderer = nullptr;
    {
        std::lock_guard<std::mutex> lock(g_widgetMutex);
        auto it = g_widgets.find(id);
        if (it == g_widgets.end()) {
            return;
        }
        renderer = it->second.renderer;
        g_widgets.erase(it);
    }
    if (renderer != nullptr) {
        if (renderer->OnSurfaceDestroyed(kWidgetJoinTimeoutMs)) {
            delete renderer;
            GLOG("widget renderer destroyed: id=%{public}s", id.c_str());
        } else {
            // 线程还卡在 GL 调用里：转交僵尸队列，稍后（下次建控件）回收，
            // 绝不在这里无限 join —— 那会把 UI 线程冻住（实测 9 秒）。
            GERR("widget renderer join timeout (%{public}dms), deferred: id=%{public}s",
                 kWidgetJoinTimeoutMs, id.c_str());
            std::lock_guard<std::mutex> lock(g_widgetMutex);
            g_widgetZombies.push_back(renderer);
        }
    }
}

// ---------------------------------------------------------------------------
// 玻璃对话框（Dialog）的渲染器注册表
// ---------------------------------------------------------------------------

struct DialogEntry {
    GlesRenderer *renderer = nullptr;
};

std::mutex g_dialogMutex;
std::unordered_map<std::string, DialogEntry> g_dialogs;
constexpr int kDialogJoinTimeoutMs = 600;
std::vector<GlesRenderer *> g_dialogZombies;

void ReapDialogZombiesLocked() {
    for (auto it = g_dialogZombies.begin(); it != g_dialogZombies.end();) {
        GlesRenderer *zombie = *it;
        if (zombie != nullptr && zombie->IsThreadExited()) {
            zombie->OnSurfaceDestroyed();
            delete zombie;
            it = g_dialogZombies.erase(it);
        } else {
            ++it;
        }
    }
}

bool IsDialogId(const std::string &id) {
    return id.rfind("glassDialog", 0) == 0;
}

GlesRenderer *FindDialog(const std::string &id) {
    std::lock_guard<std::mutex> lock(g_dialogMutex);
    auto it = g_dialogs.find(id);
    return it == g_dialogs.end() ? nullptr : it->second.renderer;
}

GlesRenderer *GetOrCreateDialog(const std::string &id) {
    std::lock_guard<std::mutex> lock(g_dialogMutex);
    ReapDialogZombiesLocked();
    auto it = g_dialogs.find(id);
    if (it != g_dialogs.end()) {
        return it->second.renderer;
    }
    GlesRenderer *renderer = GlesRenderer::CreateInstance();
    renderer->SetScene(static_cast<int>(Scene::kDialog));
    g_dialogs.emplace(id, DialogEntry{renderer});
    GLOG("dialog renderer created: id=%{public}s", id.c_str());
    return renderer;
}

void DestroyDialog(const std::string &id) {
    GlesRenderer *renderer = nullptr;
    {
        std::lock_guard<std::mutex> lock(g_dialogMutex);
        auto it = g_dialogs.find(id);
        if (it == g_dialogs.end()) {
            return;
        }
        renderer = it->second.renderer;
        g_dialogs.erase(it);
    }
    if (renderer != nullptr) {
        if (renderer->OnSurfaceDestroyed(kDialogJoinTimeoutMs)) {
            delete renderer;
            GLOG("dialog renderer destroyed: id=%{public}s", id.c_str());
        } else {
            GERR("dialog renderer join timeout (%{public}dms), deferred: id=%{public}s",
                 kDialogJoinTimeoutMs, id.c_str());
            std::lock_guard<std::mutex> lock(g_dialogMutex);
            g_dialogZombies.push_back(renderer);
        }
    }
}

/** 触摸 / 尺寸回调共用的 id 读取。 */
std::string ComponentId(OH_NativeXComponent *component) {
    char id[kMaxIdLen] = {0};
    uint64_t idLen = sizeof(id);
    OH_NativeXComponent_GetXComponentId(component, id, &idLen);
    return std::string(id);
}

void OnSurfaceCreated(OH_ArkUI_SurfaceHolder *holder) {
    auto *window = OH_ArkUI_XComponent_GetNativeWindow(holder);
    if (window == nullptr) {
        GERR("OnSurfaceCreated: native window is null");
        return;
    }
    // 尺寸在 OnSurfaceChanged 里给；这里先以 0 启动，渲染线程会等尺寸。
    GlesRenderer::Instance().OnSurfaceCreated(window, 0, 0);
}

void OnSurfaceChanged(OH_ArkUI_SurfaceHolder * /*holder*/, uint64_t width, uint64_t height) {
    GlesRenderer::Instance().OnSurfaceChanged(width, height);
}

void OnSurfaceDestroyed(OH_ArkUI_SurfaceHolder * /*holder*/) {
    GlesRenderer::Instance().OnSurfaceDestroyed();
}

void ReadIdArg(napi_env env, napi_value value, char *out, size_t outSize) {
    size_t len = 0;
    napi_get_value_string_utf8(env, value, out, outSize, &len);
}

}  // namespace


napi_value GlassGLRegisterConsumer(napi_env env, napi_callback_info info) {
    size_t argc = 5;
    napi_value args[5] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 4) return nullptr;

    char id[128] = {0};
    size_t len = 0;
    napi_get_value_string_utf8(env, args[0], id, sizeof(id), &len);

    char typeStr[64] = {0};
    napi_get_value_string_utf8(env, args[1], typeStr, sizeof(typeStr), &len);
    ConsumerType type = (std::string(typeStr) == "genericGlass") ? ConsumerType::GenericGlass : ConsumerType::TabBar;

    napi_value rectVal = args[2];
    napi_value xVal, yVal, wVal, hVal;
    napi_get_named_property(env, rectVal, "x", &xVal);
    napi_get_named_property(env, rectVal, "y", &yVal);
    napi_get_named_property(env, rectVal, "width", &wVal);
    napi_get_named_property(env, rectVal, "height", &hVal);
    
    double x, y, w, h;
    napi_get_value_double(env, xVal, &x);
    napi_get_value_double(env, yVal, &y);
    napi_get_value_double(env, wVal, &w);
    napi_get_value_double(env, hVal, &h);

    bool lag = false;
    napi_get_value_bool(env, args[3], &lag);

    std::unordered_map<int, float> params;
    // skip params parsing for now

    void* window = nullptr;
    GlesRenderer::Instance().RegisterConsumer(id, type, {(float)x, (float)y, (float)w, (float)h}, lag, params, window);

    return nullptr;
}

napi_value GlassGLUnregisterConsumer(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 1) return nullptr;
    char id[128] = {0};
    size_t len = 0;
    napi_get_value_string_utf8(env, args[0], id, sizeof(id), &len);
    GlesRenderer::Instance().UnregisterConsumer(id);
    return nullptr;
}

napi_value GlassGLSetScrollRegion(napi_env env, napi_callback_info info) {
    size_t argc = 4;
    napi_value args[4] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 4) return nullptr;
    double l, t, r, b;
    napi_get_value_double(env, args[0], &l);
    napi_get_value_double(env, args[1], &t);
    napi_get_value_double(env, args[2], &r);
    napi_get_value_double(env, args[3], &b);
    GlesRenderer::Instance().SetScrollRegion(l, t, r, b);
    return nullptr;
}

napi_value BindNode(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2] = {nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 2 || args[0] == nullptr || args[1] == nullptr) {
        GERR("BindNode: need (id: string, node: FrameNode)");
        return nullptr;
    }

    char id[kMaxIdLen] = {0};
    ReadIdArg(env, args[0], id, sizeof(id));

    GLOG("BindNode step1: got args, id=%{public}s", id);

    ArkUI_NodeHandle handle = nullptr;
    int32_t ret = OH_ArkUI_GetNodeHandleFromNapiValue(env, args[1], &handle);
    GLOG("BindNode step2: getRet=%{public}d handle=%{public}llu", ret,
         static_cast<unsigned long long>(reinterpret_cast<uintptr_t>(handle)));

    if (ret != 0 || handle == nullptr) {
        GERR("BindNode: GetNodeHandleFromNapiValue failed, ret=%{public}d", ret);
        return nullptr;
    }

    // 重复绑定先清理
    UnbindNode(env, nullptr);
    GLOG("BindNode step3: cleared previous binding");

    g_node = handle;
    g_holder = OH_ArkUI_SurfaceHolder_Create(handle);
    GLOG("BindNode step4: holder=%{public}llu",
         static_cast<unsigned long long>(reinterpret_cast<uintptr_t>(g_holder)));
    if (g_holder == nullptr) {
        GERR("BindNode: SurfaceHolder_Create failed");
        return nullptr;
    }
    OH_ArkUI_SurfaceHolder_SetUserData(g_holder, &GlesRenderer::Instance());

    g_callback = OH_ArkUI_SurfaceCallback_Create();
    OH_ArkUI_SurfaceCallback_SetSurfaceCreatedEvent(g_callback, OnSurfaceCreated);
    OH_ArkUI_SurfaceCallback_SetSurfaceChangedEvent(g_callback, OnSurfaceChanged);
    OH_ArkUI_SurfaceCallback_SetSurfaceDestroyedEvent(g_callback, OnSurfaceDestroyed);
    OH_ArkUI_SurfaceHolder_AddSurfaceCallback(g_holder, g_callback);

    // 允许跑到 120Hz（面板支持 120/90/72/60/45/40/36/30）
    OH_NativeXComponent_ExpectedRateRange range{0, 120, 120};
    int32_t rateRet = OH_ArkUI_XComponent_SetExpectedFrameRateRange(handle, range);

    GLOG("BindNode ok: id=%{public}s rateRet=%{public}d", id, rateRet);
    return nullptr;
}

napi_value UnbindNode(napi_env /*env*/, napi_callback_info /*info*/) {
    GlesRenderer::Instance().OnSurfaceDestroyed();
    if (g_holder != nullptr && g_callback != nullptr) {
        OH_ArkUI_SurfaceHolder_RemoveSurfaceCallback(g_holder, g_callback);
    }
    if (g_callback != nullptr) {
        OH_ArkUI_SurfaceCallback_Dispose(g_callback);
        g_callback = nullptr;
    }
    if (g_holder != nullptr) {
        OH_ArkUI_SurfaceHolder_Dispose(g_holder);
        g_holder = nullptr;
    }
    g_node = nullptr;
    GLOG("UnbindNode done");
    return nullptr;
}

napi_value SetNumber(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2] = {nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 2) {
        return nullptr;
    }
    int32_t id = 0;
    double value = 0;
    napi_get_value_int32(env, args[0], &id);
    napi_get_value_double(env, args[1], &value);
    GlesRenderer::Instance().SetFloat(id, static_cast<float>(value));
    return nullptr;
}

napi_value SetBool(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2] = {nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 2) {
        return nullptr;
    }
    int32_t id = 0;
    bool value = false;
    napi_get_value_int32(env, args[0], &id);
    napi_get_value_bool(env, args[1], &value);
    GlesRenderer::Instance().SetBool(id, value);
    return nullptr;
}

napi_value SetScene(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 1) {
        return nullptr;
    }
    int32_t scene = 0;
    napi_get_value_int32(env, args[0], &scene);
    GlesRenderer::Instance().SetScene(scene);
    return nullptr;
}

napi_value SetDensity(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 1) {
        return nullptr;
    }
    double density = 4.0;
    napi_get_value_double(env, args[0], &density);
    GlesRenderer::Instance().SetDensity(static_cast<float>(density));
    return nullptr;
}

napi_value SetDarkMode(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 1) {
        return nullptr;
    }
    bool dark = false;
    napi_get_value_bool(env, args[0], &dark);
    GlesRenderer::Instance().SetDarkMode(dark);
    return nullptr;
}

napi_value SetDebugMode(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 1) {
        return nullptr;
    }
    int32_t mode = 0;
    napi_get_value_int32(env, args[0], &mode);
    GlesRenderer::Instance().SetDebugMode(mode);
    return nullptr;
}

napi_value SetPaused(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 1 || args[0] == nullptr) {
        return nullptr;
    }
    bool paused = false;
    napi_get_value_bool(env, args[0], &paused);
    GlesRenderer::Instance().SetPaused(paused);
    GLOG("SetPaused: %{public}d", paused ? 1 : 0);
    return nullptr;
}

napi_value SetContentBackdrop(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 1 || args[0] == nullptr) {
        return nullptr;
    }
    bool on = false;
    napi_get_value_bool(env, args[0], &on);
    GlesRenderer::Instance().SetContentBackdrop(on);
    GLOG("SetContentBackdrop: %{public}d", on ? 1 : 0);
    return nullptr;
}

napi_value GetContentSurfaceId(napi_env env, napi_callback_info /*info*/) {
    const std::string id = GlesRenderer::Instance().ContentSurfaceId();
    napi_value result = nullptr;
    napi_create_string_utf8(env, id.c_str(), id.size(), &result);
    return result;
}

napi_value HasContentFrame(napi_env env, napi_callback_info /*info*/) {
    napi_value result = nullptr;
    napi_get_boolean(env, GlesRenderer::Instance().HasContentFrame(), &result);
    return result;
}

napi_value SetPhoto(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 1 || args[0] == nullptr) {
        GERR("SetPhoto: need (data: ArrayBuffer)");
        return nullptr;
    }
    bool isBuffer = false;
    napi_is_arraybuffer(env, args[0], &isBuffer);
    if (!isBuffer) {
        GERR("SetPhoto: argument is not an ArrayBuffer");
        return nullptr;
    }
    void *data = nullptr;
    size_t length = 0;
    if (napi_get_arraybuffer_info(env, args[0], &data, &length) != napi_ok || data == nullptr) {
        GERR("SetPhoto: get_arraybuffer_info failed");
        return nullptr;
    }
    GlesRenderer::Instance().SetPhotoData(data, length);
    return nullptr;
}

napi_value IsRunning(napi_env env, napi_callback_info /*info*/) {
    napi_value result = nullptr;
    napi_get_boolean(env, GlesRenderer::Instance().IsRunning(), &result);
    return result;
}

// ---------------------------------------------------------------------------
// HallPass 集成：背景快照 / 叠加模式 / 可配置页签 / 页签切换回链
// ---------------------------------------------------------------------------

namespace {

/** 读一个字符串数组（labels / iconPaths）。 */
bool ReadStringArray(napi_env env, napi_value value, std::vector<std::string> *out) {
    bool isArray = false;
    napi_is_array(env, value, &isArray);
    if (!isArray) {
        return false;
    }
    uint32_t len = 0;
    napi_get_array_length(env, value, &len);
    out->clear();
    out->reserve(len);
    for (uint32_t i = 0; i < len; i++) {
        napi_value item = nullptr;
        if (napi_get_element(env, value, i, &item) != napi_ok || item == nullptr) {
            return false;
        }
        size_t strLen = 0;
        napi_get_value_string_utf8(env, item, nullptr, 0, &strLen);
        std::vector<char> buf(strLen + 1, '\0');
        napi_get_value_string_utf8(env, item, buf.data(), buf.size(), &strLen);
        out->emplace_back(buf.data(), strLen);
    }
    return true;
}

}  // namespace

napi_value SetBackdrop(napi_env env, napi_callback_info info) {
    size_t argc = 4;
    napi_value args[4] = {nullptr, nullptr, nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 4 || args[0] == nullptr) {
        GERR("SetBackdrop: need (data: ArrayBuffer, width: number, height: number, rowBytes: number)");
        return nullptr;
    }
    bool isBuffer = false;
    napi_is_arraybuffer(env, args[0], &isBuffer);
    if (!isBuffer) {
        GERR("SetBackdrop: argument is not an ArrayBuffer");
        return nullptr;
    }
    void *data = nullptr;
    size_t length = 0;
    if (napi_get_arraybuffer_info(env, args[0], &data, &length) != napi_ok || data == nullptr) {
        GERR("SetBackdrop: get_arraybuffer_info failed");
        return nullptr;
    }
    int32_t width = 0;
    int32_t height = 0;
    int32_t rowBytes = 0;
    napi_get_value_int32(env, args[1], &width);
    napi_get_value_int32(env, args[2], &height);
    napi_get_value_int32(env, args[3], &rowBytes);
    GlesRenderer::Instance().SetBackdropData(data, length, width, height, rowBytes);
    return nullptr;
}

napi_value SetBackdropShift(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2] = {nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 2) {
        return nullptr;
    }
    double dx = 0.0;
    double dy = 0.0;
    napi_get_value_double(env, args[0], &dx);
    napi_get_value_double(env, args[1], &dy);
    GlesRenderer::Instance().SetBackdropShift(static_cast<float>(dx), static_cast<float>(dy));
    return nullptr;
}

napi_value SetMirrorOffset(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2] = {nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 1 || args[0] == nullptr) {
        return nullptr;
    }
    double offsetVp = 0.0;
    napi_get_value_double(env, args[0], &offsetVp);
    bool resync = false;   // 默认只更新逻辑值（切页 / 重建才传 true）
    if (argc >= 2 && args[1] != nullptr) {
        napi_get_value_bool(env, args[1], &resync);
    }
    GlesRenderer::Instance().SetMirrorOffset(static_cast<float>(offsetVp), resync);
    return nullptr;
}

napi_value SetContentOffset(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2] = {nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 1 || args[0] == nullptr) {
        return nullptr;
    }
    double offsetVp = 0.0;
    napi_get_value_double(env, args[0], &offsetVp);
    double leadVp = 0.0;   // 缺省不外推
    if (argc >= 2 && args[1] != nullptr) {
        napi_get_value_double(env, args[1], &leadVp);
    }
    GlesRenderer::Instance().SetContentOffset(static_cast<float>(offsetVp),
                                              static_cast<float>(leadVp));
    return nullptr;
}

napi_value GetContentShift(napi_env env, napi_callback_info /*info*/) {
    napi_value result = nullptr;
    napi_create_double(env, static_cast<double>(GlesRenderer::Instance().ContentShift()), &result);
    return result;
}

napi_value SetContentBand(napi_env env, napi_callback_info info) {
    size_t argc = 4;
    napi_value args[4] = {nullptr, nullptr, nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 4) {
        GERR("SetContentBand: need (extraTopVp, extraBottomVp, shiftUpVp, shiftDownVp)");
        return nullptr;
    }
    double extraTop = 0.0;
    double extraBottom = 0.0;
    double shiftUp = 16.0;
    double shiftDown = 16.0;
    napi_get_value_double(env, args[0], &extraTop);
    napi_get_value_double(env, args[1], &extraBottom);
    napi_get_value_double(env, args[2], &shiftUp);
    napi_get_value_double(env, args[3], &shiftDown);
    GlesRenderer::Instance().SetContentBand(static_cast<float>(extraTop),
                                            static_cast<float>(extraBottom),
                                            static_cast<float>(shiftUp),
                                            static_cast<float>(shiftDown));
    return nullptr;
}

/** (extraTopVp: number)：镜像实际导出的上沿余量（< 0 = 与条带余量相同）。 */
napi_value SetContentExport(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 1) {
        return nullptr;
    }
    double extraTop = -1.0;
    napi_get_value_double(env, args[0], &extraTop);
    GlesRenderer::Instance().SetContentExport(static_cast<float>(extraTop));
    return nullptr;
}

/** () => boolean：页签中枢在跑且收到过镜像帧（弹窗可走实时背景）。 */
napi_value SharedBackdropReady(napi_env env, napi_callback_info /*info*/) {
    napi_value result = nullptr;
    napi_get_boolean(env, GlesRenderer::SharedBackdropReady(), &result);
    return result;
}

napi_value GetFrameMirrorOffset(napi_env env, napi_callback_info /*info*/) {
    napi_value result = nullptr;
    napi_create_double(env, static_cast<double>(GlesRenderer::Instance().FrameMirrorOffset()),
                       &result);
    return result;
}

napi_value GetContentFrameCount(napi_env env, napi_callback_info /*info*/) {
    napi_value result = nullptr;
    napi_create_int64(env, GlesRenderer::Instance().ContentFrameCount(), &result);
    return result;
}

napi_value SetOverlayMode(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 1) {
        return nullptr;
    }
    bool on = false;
    napi_get_value_bool(env, args[0], &on);
    GlesRenderer::Instance().SetOverlayMode(on);
    return nullptr;
}

napi_value SetDemoChrome(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 1) {
        return nullptr;
    }
    bool on = true;
    napi_get_value_bool(env, args[0], &on);
    GlesRenderer::Instance().SetDemoChrome(on);
    return nullptr;
}

napi_value SetTabs(napi_env env, napi_callback_info info) {
    size_t argc = 4;
    napi_value args[4] = {nullptr, nullptr, nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 4 || args[0] == nullptr || args[1] == nullptr) {
        GERR("SetTabs: need (labels: string[], icons: string[], selectedArgb, unselectedArgb)");
        return nullptr;
    }
    std::vector<std::string> labels;
    std::vector<std::string> icons;
    if (!ReadStringArray(env, args[0], &labels) || !ReadStringArray(env, args[1], &icons)) {
        GERR("SetTabs: labels / icons must be string arrays");
        return nullptr;
    }
    uint32_t selectedArgb = 0xFF007DFF;
    uint32_t unselectedArgb = 0x00000000;
    napi_get_value_uint32(env, args[2], &selectedArgb);
    napi_get_value_uint32(env, args[3], &unselectedArgb);
    GlesRenderer::Instance().SetTabs(labels, icons, selectedArgb, unselectedArgb);
    return nullptr;
}

napi_value SetSelectedTab(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 1) {
        return nullptr;
    }
    int32_t index = 0;
    napi_get_value_int32(env, args[0], &index);
    GlesRenderer::Instance().SetSelectedTab(index);
    return nullptr;
}

// ---------------------------------------------------------------------------
// 内联玻璃控件（开关 / 滑块）：配置 / 状态 / 颜色 / 存活查询 / 释放
//
// 渲染实例按 XComponent id 寻址（id 由 ArkTS 组件生成，前缀决定控件种类）。
// 交互全部由 ArkUI 侧覆盖的 Toggle / Slider 负责，这里只同步"画什么"。
// ---------------------------------------------------------------------------

namespace {

/** 读 (id: string, ...) 的第一个参数；非控件 id 返回空串。argc 回填实际参数个数。 */
std::string ReadWidgetId(napi_env env, napi_callback_info info, size_t *argc, napi_value *args) {
    napi_get_cb_info(env, info, argc, args, nullptr, nullptr);
    if (*argc < 1 || args[0] == nullptr) {
        return std::string();
    }
    const std::string id = ReadId(env, args[0]);
    return IsWidgetId(id) ? id : std::string();
}

}  // namespace

/** (id: string, kind: number, density: number) */
napi_value WidgetConfigure(napi_env env, napi_callback_info info) {
    size_t argc = 3;
    napi_value args[3] = {nullptr, nullptr, nullptr};
    const std::string id = ReadWidgetId(env, info, &argc, args);
    if (id.empty() || argc < 3) {
        return nullptr;
    }
    int32_t kind = 0;
    double density = 4.0;
    napi_get_value_int32(env, args[1], &kind);
    napi_get_value_double(env, args[2], &density);
    GlesRenderer *renderer = GetOrCreateWidget(id);
    renderer->SetWidgetDensity(static_cast<float>(density));
    renderer->SetWidgetKind(kind);
    GLOG("widget configure: id=%{public}s kind=%{public}d density=%{public}.2f", id.c_str(), kind,
         density);
    return nullptr;
}

/** (id: string, value: number)：开关 0/1，滑块 0..1。 */
napi_value WidgetSetState(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2] = {nullptr, nullptr};
    const std::string id = ReadWidgetId(env, info, &argc, args);
    if (id.empty() || argc < 2) {
        return nullptr;
    }
    double value = 0.0;
    napi_get_value_double(env, args[1], &value);
    // 只找不建：Configure 一定先于状态推送（ArkTS 组件在 onAppear 里先配置），
    // 找不到说明实例已释放（组件卸载），静默忽略，避免"复活"出一个没有 surface 的实例。
    GlesRenderer *renderer = FindWidget(id);
    if (renderer != nullptr) {
        renderer->SetWidgetState(static_cast<float>(value));
    }
    return nullptr;
}

/** (id: string, pressed: boolean) */
napi_value WidgetSetPress(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2] = {nullptr, nullptr};
    const std::string id = ReadWidgetId(env, info, &argc, args);
    if (id.empty() || argc < 2) {
        return nullptr;
    }
    bool pressed = false;
    napi_get_value_bool(env, args[1], &pressed);
    GlesRenderer *renderer = FindWidget(id);
    if (renderer != nullptr) {
        renderer->SetWidgetPress(pressed);
    }
    return nullptr;
}

/** (id: string, accentArgb: number, backgroundArgb: number) */
napi_value WidgetSetColors(napi_env env, napi_callback_info info) {
    size_t argc = 3;
    napi_value args[3] = {nullptr, nullptr, nullptr};
    const std::string id = ReadWidgetId(env, info, &argc, args);
    if (id.empty() || argc < 3) {
        return nullptr;
    }
    uint32_t accent = 0xFF30D158;
    uint32_t background = 0xFFFFFFFF;
    napi_get_value_uint32(env, args[1], &accent);
    napi_get_value_uint32(env, args[2], &background);
    GlesRenderer *renderer = FindWidget(id);
    if (renderer != nullptr) {
        renderer->SetWidgetColors(accent, background);
    }
    return nullptr;
}

/** (id: string) -> boolean：渲染线程是否在跑（ArkTS 侧自检，失败回退原生控件）。 */
napi_value WidgetIsRunning(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    const std::string id = ReadWidgetId(env, info, &argc, args);
    GlesRenderer *renderer = id.empty() ? nullptr : FindWidget(id);
    napi_value result = nullptr;
    napi_get_boolean(env, renderer != nullptr && renderer->IsRunning(), &result);
    return result;
}

/** (id: string)：组件卸载时释放渲染实例（线程 + EGL + GL 资源）。 */
napi_value WidgetDispose(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 1 || args[0] == nullptr) {
        return nullptr;
    }
    DestroyWidget(ReadId(env, args[0]));
    return nullptr;
}

// ---------------------------------------------------------------------------
// 玻璃对话框（Dialog）：配置 / 背景设置 / 按压 / 释放
// ---------------------------------------------------------------------------

/** (id: string, buttonCount: number, panelHeightDp: number, density: number, dark: boolean) */
napi_value DialogConfigure(napi_env env, napi_callback_info info) {
    size_t argc = 5;
    napi_value args[5] = {nullptr, nullptr, nullptr, nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 4 || args[0] == nullptr) {
        return nullptr;
    }
    const std::string id = ReadId(env, args[0]);
    if (!IsDialogId(id)) {
        return nullptr;
    }
    int32_t buttonCount = 1;
    double panelHeightDp = 0.0;
    double density = 4.0;
    bool dark = false;
    napi_get_value_int32(env, args[1], &buttonCount);
    napi_get_value_double(env, args[2], &panelHeightDp);
    napi_get_value_double(env, args[3], &density);
    if (argc >= 5 && args[4] != nullptr) {
        napi_get_value_bool(env, args[4], &dark);
    }
    GlesRenderer *renderer = GetOrCreateDialog(id);
    renderer->SetDensity(static_cast<float>(density));
    renderer->SetDarkMode(dark);
    renderer->SetDialogConfig(buttonCount, static_cast<float>(panelHeightDp), true /* custom text */);
    GLOG("dialog configure: id=%{public}s buttons=%{public}d heightDp=%{public}.1f density=%{public}.2f dark=%{public}d",
         id.c_str(), buttonCount, panelHeightDp, density, dark ? 1 : 0);
    return nullptr;
}

/** (id: string, data: ArrayBuffer, width: number, height: number, stride: number) */
napi_value DialogSetBackdrop(napi_env env, napi_callback_info info) {
    size_t argc = 5;
    napi_value args[5] = {nullptr, nullptr, nullptr, nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 5 || args[0] == nullptr || args[1] == nullptr) {
        return nullptr;
    }
    const std::string id = ReadId(env, args[0]);
    if (!IsDialogId(id)) {
        return nullptr;
    }
    bool isAb = false;
    napi_is_arraybuffer(env, args[1], &isAb);
    if (!isAb) {
        GERR("DialogSetBackdrop: argument is not ArrayBuffer");
        return nullptr;
    }
    void *data = nullptr;
    size_t length = 0;
    napi_get_arraybuffer_info(env, args[1], &data, &length);
    int32_t width = 0;
    int32_t height = 0;
    int32_t stride = 0;
    napi_get_value_int32(env, args[2], &width);
    napi_get_value_int32(env, args[3], &height);
    napi_get_value_int32(env, args[4], &stride);

    GlesRenderer *renderer = FindDialog(id);
    if (renderer != nullptr) {
        renderer->SetBackdropData(data, length, width, height, stride);
        GLOG("dialog set backdrop: id=%{public}s %{public}dx%{public}d stride=%{public}d",
             id.c_str(), width, height, stride);
    }
    return nullptr;
}

/** (id: string, buttonIndex: number, pressed: boolean) */
napi_value DialogSetPress(napi_env env, napi_callback_info info) {
    size_t argc = 3;
    napi_value args[3] = {nullptr, nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 3 || args[0] == nullptr) {
        return nullptr;
    }
    const std::string id = ReadId(env, args[0]);
    if (!IsDialogId(id)) {
        return nullptr;
    }
    int32_t buttonIndex = 0;
    bool pressed = false;
    napi_get_value_int32(env, args[1], &buttonIndex);
    napi_get_value_bool(env, args[2], &pressed);
    GlesRenderer *renderer = FindDialog(id);
    if (renderer != nullptr) {
        renderer->SetDialogPress(buttonIndex, pressed);
    }
    return nullptr;
}

/** (id: string, cardX: number, cardY: number, cardW: number, cardH: number, buttons?: Array<{x: number, y: number, w: number, h: number}>) */
napi_value DialogSetGeometry(napi_env env, napi_callback_info info) {
    size_t argc = 6;
    napi_value args[6] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 5 || args[0] == nullptr) {
        return nullptr;
    }
    const std::string id = ReadId(env, args[0]);
    if (!IsDialogId(id)) {
        return nullptr;
    }
    double cardX = 0, cardY = 0, cardW = 0, cardH = 0;
    napi_get_value_double(env, args[1], &cardX);
    napi_get_value_double(env, args[2], &cardY);
    napi_get_value_double(env, args[3], &cardW);
    napi_get_value_double(env, args[4], &cardH);

    std::vector<RectF> buttons;
    if (argc >= 6 && args[5] != nullptr) {
        bool isArray = false;
        napi_is_array(env, args[5], &isArray);
        if (isArray) {
            uint32_t len = 0;
            napi_get_array_length(env, args[5], &len);
            for (uint32_t i = 0; i < len; i++) {
                napi_value elem = nullptr;
                napi_get_element(env, args[5], i, &elem);
                if (elem != nullptr) {
                    napi_value nx = nullptr, ny = nullptr, nw = nullptr, nh = nullptr;
                    napi_get_named_property(env, elem, "x", &nx);
                    napi_get_named_property(env, elem, "y", &ny);
                    napi_get_named_property(env, elem, "w", &nw);
                    napi_get_named_property(env, elem, "h", &nh);
                    double bx = 0, by = 0, bw = 0, bh = 0;
                    if (nx) napi_get_value_double(env, nx, &bx);
                    if (ny) napi_get_value_double(env, ny, &by);
                    if (nw) napi_get_value_double(env, nw, &bw);
                    if (nh) napi_get_value_double(env, nh, &bh);
                    buttons.push_back(RectF{static_cast<float>(bx), static_cast<float>(by),
                                            static_cast<float>(bw), static_cast<float>(bh)});
                }
            }
        }
    }

    GlesRenderer *renderer = FindDialog(id);
    if (renderer != nullptr) {
        GLOG("dialog set geometry: id=%{public}s card=[%{public}.1f, %{public}.1f, %{public}.1f, %{public}.1f] btns=%{public}zu",
             id.c_str(), cardX, cardY, cardW, cardH, buttons.size());
        for (size_t i = 0; i < buttons.size(); i++) {
            GLOG("  btn[%{public}zu]=[%{public}.1f, %{public}.1f, %{public}.1f, %{public}.1f]", i, buttons[i].x, buttons[i].y, buttons[i].w, buttons[i].h);
        }
        renderer->SetDialogGeometry(static_cast<float>(cardX), static_cast<float>(cardY),
                                    static_cast<float>(cardW), static_cast<float>(cardH),
                                    buttons);
    }
    return nullptr;
}

/** (id: string, x: number, y: number, w: number, h: number)：快照在 surface 里的矩形（px）。 */
napi_value DialogSetBackdropRect(napi_env env, napi_callback_info info) {
    size_t argc = 5;
    napi_value args[5] = {nullptr, nullptr, nullptr, nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 5 || args[0] == nullptr) {
        return nullptr;
    }
    const std::string id = ReadId(env, args[0]);
    GlesRenderer *renderer = IsDialogId(id) ? FindDialog(id) : nullptr;
    if (renderer == nullptr) {
        return nullptr;
    }
    double v[4] = {0.0, 0.0, 0.0, 0.0};
    for (int i = 0; i < 4; i++) {
        napi_get_value_double(env, args[i + 1], &v[i]);
    }
    renderer->SetDialogBackdropRect(static_cast<float>(v[0]), static_cast<float>(v[1]),
                                    static_cast<float>(v[2]), static_cast<float>(v[3]));
    return nullptr;
}

/** (id: string, x: number, y: number, w: number, h: number)：实时背景纹理在 surface 里的矩形（px）。 */
napi_value DialogSetLiveRect(napi_env env, napi_callback_info info) {
    size_t argc = 5;
    napi_value args[5] = {nullptr, nullptr, nullptr, nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 5 || args[0] == nullptr) {
        return nullptr;
    }
    const std::string id = ReadId(env, args[0]);
    GlesRenderer *renderer = IsDialogId(id) ? FindDialog(id) : nullptr;
    if (renderer == nullptr) {
        return nullptr;
    }
    double v[4] = {0.0, 0.0, 0.0, 0.0};
    for (int i = 0; i < 4; i++) {
        napi_get_value_double(env, args[i + 1], &v[i]);
    }
    renderer->SetDialogLiveRect(static_cast<float>(v[0]), static_cast<float>(v[1]),
                                static_cast<float>(v[2]), static_cast<float>(v[3]));
    return nullptr;
}

/** (id: string, scale: number, pivotX: number, pivotY: number)：出现 / 消失动效的整体缩放（px）。 */
napi_value DialogSetTransform(napi_env env, napi_callback_info info) {
    size_t argc = 4;
    napi_value args[4] = {nullptr, nullptr, nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 4 || args[0] == nullptr) {
        return nullptr;
    }
    const std::string id = ReadId(env, args[0]);
    GlesRenderer *renderer = IsDialogId(id) ? FindDialog(id) : nullptr;
    if (renderer == nullptr) {
        return nullptr;
    }
    double v[3] = {1.0, 0.0, 0.0};
    for (int i = 0; i < 3; i++) {
        napi_get_value_double(env, args[i + 1], &v[i]);
    }
    renderer->SetDialogTransform(static_cast<float>(v[0]), static_cast<float>(v[1]),
                                 static_cast<float>(v[2]));
    return nullptr;
}

/** (id: string) => boolean：首帧（真实背景 + 卡片几何）已交给 surface。 */
napi_value DialogIsReady(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    bool ready = false;
    if (argc >= 1 && args[0] != nullptr) {
        const std::string id = ReadId(env, args[0]);
        GlesRenderer *renderer = IsDialogId(id) ? FindDialog(id) : nullptr;
        ready = renderer != nullptr && renderer->IsDialogPresented();
    }
    napi_value result = nullptr;
    napi_get_boolean(env, ready, &result);
    return result;
}

/** (id: string)：弹窗卸载时释放渲染实例（线程 + EGL + GL 资源）。 */
napi_value DialogDispose(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 1 || args[0] == nullptr) {
        return nullptr;
    }
    const std::string id = ReadId(env, args[0]);
    if (IsDialogId(id)) {
        DestroyDialog(id);
    }
    return nullptr;
}

// ---------------------------------------------------------------------------
// 页签切换回调（原生 -> JS，与菜单回调同一套 threadsafe function 机制）
// ---------------------------------------------------------------------------

namespace {

napi_threadsafe_function g_tabTsfn = nullptr;
std::mutex g_tabMutex;

void TabCallJs(napi_env env, napi_value jsCb, void * /*context*/, void *data) {
    if (env == nullptr || jsCb == nullptr) {
        return;
    }
    const int index = static_cast<int>(reinterpret_cast<intptr_t>(data));
    napi_value arg = nullptr;
    napi_create_int32(env, index, &arg);
    napi_value recv = nullptr;
    napi_get_undefined(env, &recv);
    napi_value result = nullptr;
    napi_call_function(env, recv, jsCb, 1, &arg, &result);
}

void OnTabChangeFromRenderer(int index) {
    std::lock_guard<std::mutex> lock(g_tabMutex);
    if (g_tabTsfn == nullptr) {
        return;
    }
    napi_call_threadsafe_function(g_tabTsfn, reinterpret_cast<void *>(static_cast<intptr_t>(index)),
                                  napi_tsfn_nonblocking);
}

}  // namespace

napi_value RegisterTabCallback(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 1 || args[0] == nullptr) {
        GERR("RegisterTabCallback: need (callback: (index: number) => void)");
        return nullptr;
    }
    napi_valuetype type = napi_undefined;
    napi_typeof(env, args[0], &type);
    if (type != napi_function) {
        GERR("RegisterTabCallback: argument is not a function");
        return nullptr;
    }

    std::lock_guard<std::mutex> lock(g_tabMutex);
    if (g_tabTsfn != nullptr) {   // 重复注册：先放掉旧的
        napi_release_threadsafe_function(g_tabTsfn, napi_tsfn_release);
        g_tabTsfn = nullptr;
    }
    napi_value resourceName = nullptr;
    napi_create_string_utf8(env, "GlassGLTabChange", NAPI_AUTO_LENGTH, &resourceName);
    napi_status status = napi_create_threadsafe_function(env, args[0], nullptr, resourceName, 4, 1,
                                                         nullptr, nullptr, nullptr, TabCallJs,
                                                         &g_tabTsfn);
    if (status != napi_ok || g_tabTsfn == nullptr) {
        g_tabTsfn = nullptr;
        GERR("RegisterTabCallback: create_threadsafe_function failed, status=%{public}d",
             static_cast<int>(status));
        return nullptr;
    }
    GlesRenderer::Instance().SetTabChangeFn(&OnTabChangeFromRenderer);
    GLOG("tab callback registered");
    return nullptr;
}

napi_value UnregisterTabCallback(napi_env /*env*/, napi_callback_info /*info*/) {
    std::lock_guard<std::mutex> lock(g_tabMutex);
    GlesRenderer::Instance().SetTabChangeFn(nullptr);
    if (g_tabTsfn != nullptr) {
        napi_release_threadsafe_function(g_tabTsfn, napi_tsfn_release);
        g_tabTsfn = nullptr;
    }
    GLOG("tab callback unregistered");
    return nullptr;
}

// ---------------------------------------------------------------------------
// 顶部按钮点击 -> ArkTS 菜单（原生 -> JS 的反向调用）
//
// 渲染器只持有一个 `void (*)(int)`，由这里的 trampoline 用 threadsafe function
// 把请求排队到 JS 线程（JS 回调里再去开 ArkUI 菜单）。
// ---------------------------------------------------------------------------

namespace {

napi_threadsafe_function g_menuTsfn = nullptr;
std::mutex g_menuMutex;

/** 在 JS 线程上执行 ArkTS 注册进来的回调。 */
void MenuCallJs(napi_env env, napi_value jsCb, void * /*context*/, void *data) {
    if (env == nullptr || jsCb == nullptr) {
        return;
    }
    const int target = static_cast<int>(reinterpret_cast<intptr_t>(data));
    napi_value arg = nullptr;
    napi_create_int32(env, target, &arg);
    napi_value recv = nullptr;
    napi_get_undefined(env, &recv);
    napi_value result = nullptr;
    napi_call_function(env, recv, jsCb, 1, &arg, &result);
}

/** 渲染器（任意线程）调用：把"哪个按钮被点了"排到 JS 线程。 */
void OnMenuRequestFromRenderer(int target) {
    std::lock_guard<std::mutex> lock(g_menuMutex);
    if (g_menuTsfn == nullptr) {
        return;
    }
    napi_call_threadsafe_function(g_menuTsfn,
                                  reinterpret_cast<void *>(static_cast<intptr_t>(target)),
                                  napi_tsfn_nonblocking);
}

}  // namespace

napi_value RegisterMenuCallback(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 1 || args[0] == nullptr) {
        GERR("RegisterMenuCallback: need (callback: (target: number) => void)");
        return nullptr;
    }
    napi_valuetype type = napi_undefined;
    napi_typeof(env, args[0], &type);
    if (type != napi_function) {
        GERR("RegisterMenuCallback: argument is not a function");
        return nullptr;
    }

    std::lock_guard<std::mutex> lock(g_menuMutex);
    if (g_menuTsfn != nullptr) {   // 重复注册：先放掉旧的
        napi_release_threadsafe_function(g_menuTsfn, napi_tsfn_release);
        g_menuTsfn = nullptr;
    }
    napi_value resourceName = nullptr;
    napi_create_string_utf8(env, "GlassGLMenuRequest", NAPI_AUTO_LENGTH, &resourceName);
    // 队列 4：按钮点击是稀疏事件，排不满；满了就丢（nonblocking），不会卡住触摸线程。
    napi_status status = napi_create_threadsafe_function(
        env, args[0], nullptr, resourceName, 4, 1, nullptr, nullptr, nullptr, MenuCallJs,
        &g_menuTsfn);
    if (status != napi_ok || g_menuTsfn == nullptr) {
        g_menuTsfn = nullptr;
        GERR("RegisterMenuCallback: create_threadsafe_function failed, status=%{public}d",
             static_cast<int>(status));
        return nullptr;
    }
    GlesRenderer::Instance().SetMenuRequestFn(&OnMenuRequestFromRenderer);
    GLOG("menu callback registered");
    return nullptr;
}

napi_value UnregisterMenuCallback(napi_env /*env*/, napi_callback_info /*info*/) {
    std::lock_guard<std::mutex> lock(g_menuMutex);
    GlesRenderer::Instance().SetMenuRequestFn(nullptr);
    if (g_menuTsfn != nullptr) {
        napi_release_threadsafe_function(g_menuTsfn, napi_tsfn_release);
        g_menuTsfn = nullptr;
    }
    GLOG("menu callback unregistered");
    return nullptr;
}

// ---------------------------------------------------------------------------
// 经典 OH_NativeXComponent 路线
// ---------------------------------------------------------------------------

namespace {

OH_NativeXComponent_Callback g_xcCallback;

void XcOnSurfaceCreated(OH_NativeXComponent *component, void *window) {
    uint64_t w = 0;
    uint64_t h = 0;
    OH_NativeXComponent_GetXComponentSize(component, window, &w, &h);
    const std::string id = ComponentId(component);
    GLOG("XcOnSurfaceCreated: id=%{public}s window=%{public}llu size=%{public}llux%{public}llu",
         id.c_str(), static_cast<unsigned long long>(reinterpret_cast<uintptr_t>(window)),
         static_cast<unsigned long long>(w), static_cast<unsigned long long>(h));
    if (window == nullptr) {
        GERR("XcOnSurfaceCreated: window is null");
        return;
    }
    if (IsWidgetId(id)) {
        GetOrCreateWidget(id)->OnSurfaceCreated(window, w, h);
        return;
    }
    if (IsDialogId(id)) {
        GetOrCreateDialog(id)->OnSurfaceCreated(window, w, h);
        return;
    }
    GlesRenderer::Instance().OnSurfaceCreated(window, w, h, id);
}

void XcOnSurfaceChanged(OH_NativeXComponent *component, void *window) {
    uint64_t w = 0;
    uint64_t h = 0;
    OH_NativeXComponent_GetXComponentSize(component, window, &w, &h);
    const std::string id = ComponentId(component);
    GLOG("XcOnSurfaceChanged: id=%{public}s %{public}llux%{public}llu", id.c_str(),
         static_cast<unsigned long long>(w), static_cast<unsigned long long>(h));
    if (IsWidgetId(id)) {
        GlesRenderer *renderer = FindWidget(id);
        if (renderer != nullptr) {
            renderer->OnSurfaceChanged(w, h);
        }
        return;
    }
    if (IsDialogId(id)) {
        GlesRenderer *renderer = FindDialog(id);
        if (renderer != nullptr) {
            renderer->OnSurfaceChanged(w, h);
        }
        return;
    }
    GlesRenderer::Instance().OnSurfaceChanged(w, h);
}

void XcOnSurfaceDestroyed(OH_NativeXComponent *component, void * /*window*/) {
    const std::string id = ComponentId(component);
    GLOG("XcOnSurfaceDestroyed: id=%{public}s", id.c_str());
    if (IsWidgetId(id)) {
        // surface 没了：先停线程（实例保留，等 ArkTS Dispose 再删，避免卸载顺序
        // 不同导致野指针 —— 详见 DestroyWidget 注释）。带超时：GL 调用可能卡住，
        // 这里绝不能无限 join（UI 线程），超时就留给 DestroyWidget 转僵尸队列。
        GlesRenderer *renderer = FindWidget(id);
        if (renderer != nullptr && !renderer->OnSurfaceDestroyed(kWidgetJoinTimeoutMs)) {
            GERR("widget surface destroyed: join timeout, keep instance: id=%{public}s",
                 id.c_str());
        }
        return;
    }
    if (IsDialogId(id)) {
        GlesRenderer *renderer = FindDialog(id);
        if (renderer != nullptr && !renderer->OnSurfaceDestroyed(kDialogJoinTimeoutMs)) {
            GERR("dialog surface destroyed: join timeout, keep instance: id=%{public}s",
                 id.c_str());
        }
        return;
    }
    GlesRenderer::Instance().OnSurfaceDestroyed();
}

/**
 * 触摸：直接交给渲染器按当前场景分发（页签拖动 / 按钮按压 / 滑块拖动…）。
 *
 * 注：旧版这里有一个"点屏幕中上部循环切消融模式"的调试手势；目录场景里
 * 它是误触源（点按钮会顺带切调试模式），已移除。需要消融对比时用
 * `GlassGLSetDebugMode` 显式设置。
 *
 * 内联玻璃控件与弹窗的交互由覆盖在上层的 ArkUI 处理，原生不接管触摸。
 */
void XcDispatchTouchEvent(OH_NativeXComponent *component, void *window) {
    const std::string id = ComponentId(component);
    if (IsWidgetId(id) || IsDialogId(id)) {
        return;
    }
    OH_NativeXComponent_TouchEvent touchEvent;
    if (OH_NativeXComponent_GetTouchEvent(component, window, &touchEvent) != 0) {
        return;
    }
    // OH_NativeXComponent_TouchEventType: DOWN=0, UP=1, MOVE=2, CANCEL=3
    const int action = static_cast<int>(touchEvent.type);
    GlesRenderer::Instance().OnTouch(action, touchEvent.x, touchEvent.y, 0);
}

}  // namespace

void RegisterNativeXComponent(napi_env env, napi_value exports) {
    napi_value xcObj = nullptr;
    if (napi_get_named_property(env, exports, OH_NATIVE_XCOMPONENT_OBJ, &xcObj) != napi_ok ||
        xcObj == nullptr) {
        return;  // 这次 Init 与 XComponent 无关
    }
    OH_NativeXComponent *component = nullptr;
    if (napi_unwrap(env, xcObj, reinterpret_cast<void **>(&component)) != napi_ok ||
        component == nullptr) {
        GERR("RegisterNativeXComponent: unwrap failed");
        return;
    }
    char id[kMaxIdLen] = {0};
    uint64_t idLen = sizeof(id);
    OH_NativeXComponent_GetXComponentId(component, id, &idLen);

    // 只接管 GL 页与内联控件、弹窗自己的 XComponent：其它同样以 `libraryname: 'backdrop'`
    // 注册的 XComponent 也会走到本模块的 Init，若不按 id 排除，渲染器会接管错误的 surface。
    if (strcmp(id, "glassSurface") != 0 && !IsWidgetId(id) && !IsDialogId(id)) {
        GLOG("RegisterNativeXComponent: skip non-GL surface (id=%{public}s)", id);
        return;
    }

    g_xcCallback.OnSurfaceCreated = XcOnSurfaceCreated;
    g_xcCallback.OnSurfaceChanged = XcOnSurfaceChanged;
    g_xcCallback.OnSurfaceDestroyed = XcOnSurfaceDestroyed;
    g_xcCallback.DispatchTouchEvent = XcDispatchTouchEvent;
    int32_t ret = OH_NativeXComponent_RegisterCallback(component, &g_xcCallback);
    // 经典路由（libraryname）同样要报期望帧率：不报的话系统可能把 surface 按 60Hz
    // 调度，页签交互就会锁在 60fps（BindNode 那条 FrameNode 路由本来就有）。
    OH_NativeXComponent_ExpectedRateRange range{0, 120, 120};
    const int32_t rateRet = OH_NativeXComponent_SetExpectedFrameRateRange(component, &range);
    GLOG("RegisterNativeXComponent: id=%{public}s ret=%{public}d rateRet=%{public}d", id, ret,
         rateRet);
}

}  // namespace glass
