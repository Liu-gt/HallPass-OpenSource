#ifndef GLASS_NAPI_H
#define GLASS_NAPI_H

// 目录场景：一个 XComponent 画一个场景。
// 命名前缀与其它接口一致（GlassGL*），ArkTS 侧见 backdrop/Index.ets。

#include "napi/native_api.h"

namespace glass {

/** 把 XComponent 的 FrameNode 交给原生渲染器（创建 SurfaceHolder 并绑定生命周期）。 */
napi_value BindNode(napi_env env, napi_callback_info info);

/** 解绑（页面销毁时调用）。 */
napi_value UnbindNode(napi_env env, napi_callback_info info);

napi_value GlassGLRegisterConsumer(napi_env env, napi_callback_info info);
napi_value GlassGLUnregisterConsumer(napi_env env, napi_callback_info info);
napi_value GlassGLSetScrollRegion(napi_env env, napi_callback_info info);


/** 调参：id 与参考实现参数编号保持一致。 */
napi_value SetNumber(napi_env env, napi_callback_info info);
napi_value SetBool(napi_env env, napi_callback_info info);

/** 目录场景：切场景 / 上报显示密度 / 同步系统深浅色。 */
napi_value SetScene(napi_env env, napi_callback_info info);
napi_value SetDensity(napi_env env, napi_callback_info info);
napi_value SetDarkMode(napi_env env, napi_callback_info info);

/** 消融/调试模式。 */
napi_value SetDebugMode(napi_env env, napi_callback_info info);

/** 暂停/恢复绘制（页面不可见时调用，省电）。 */
napi_value SetPaused(napi_env env, napi_callback_info info);

/**
 * ArkTS 实时内容纹理（BuilderNode 纹理导出）。
 *
 * 用法：ArkTS 轮询直到 `GetContentSurfaceId` 返回非空串，然后
 * `new BuilderNode(uiContext, { type: RENDER_TYPE_TEXTURE, surfaceId })` 并挂到
 * NodeContainer；等 `HasContentFrame` 变 true 后调 `SetContentBackdrop(true)`，
 * 内容就由 GL 整屏绘制、页签条叠在其上。
 */
napi_value SetContentBackdrop(napi_env env, napi_callback_info info);
napi_value GetContentSurfaceId(napi_env env, napi_callback_info info);
napi_value HasContentFrame(napi_env env, napi_callback_info info);

/** 传照片背景的裸 RGBA（前 8 字节 = u32 LE 宽、高）。 */
napi_value SetPhoto(napi_env env, napi_callback_info info);

/** 传背景快照（RGBA8888 / 行 0 顶部 / 无头），显式带宽、高、源行跨度。 */
napi_value SetBackdrop(napi_env env, napi_callback_info info);

/** HallPass 集成：背景快照按滚动位移平移（vp，正 = 内容上移 / 左移）。 */
napi_value SetBackdropShift(napi_env env, napi_callback_info info);

/**
 * HallPass 集成：镜像树（BuilderNode 纹理导出）的滚动偏移同步。
 *
 * - `SetMirrorOffset(offsetVp, resync?)`：镜像树**逻辑上已应用**的偏移（vp）。
 *   渲染线程在出帧回调时把它锁存成"纹理偏移"；`resync=true` 用于切页 / 重建
 *   （换内容）时同步重置，避免拿上一页的偏移做补偿。
 * - `GetFrameMirrorOffset()`：当前纹理对应的偏移（锁存值）—— ArkTS 用它算滞后量。
 * - `GetContentFrameCount()`：累计消费到的内容帧数（诊断）。
 */
napi_value SetMirrorOffset(napi_env env, napi_callback_info info);
napi_value GetFrameMirrorOffset(napi_env env, napi_callback_info info);
napi_value GetContentFrameCount(napi_env env, napi_callback_info info);

/**
 * HallPass 集成：主树（ArkUI 直显）的视觉偏移（vp）+ 一帧外推量（vp）。
 *
 * 采样位移改由**渲染线程在画这一帧时**算（基准 = 手里那帧纹理的偏移），
 * 纹理换帧与补偿变化同帧发生 —— ArkTS 侧算会差一拍，量化重排落地时就是"闪"。
 * `GetContentShift` 返回当前实际使用的补偿（诊断用）。
 */
napi_value SetContentOffset(napi_env env, napi_callback_info info);
napi_value GetContentShift(napi_env env, napi_callback_info info);

/**
 * HallPass 集成：镜像条带上下余量 + 采样位移预算（vp，见 gles_renderer.h 的 SetContentBand）。
 *
 * 内容纹理比 GL 的条带 surface 高 `extraTop + extraBottom`，背景采样在纹理里平移；
 * 预算非对称（负位移用 up、正位移用 down），必须 ≤ 对应方向的余量。
 */
napi_value SetContentBand(napi_env env, napi_callback_info info);

/** HallPass 集成：叠加模式（透明 surface，只画页签条）+ demo 专属件开关。 */
napi_value SetOverlayMode(napi_env env, napi_callback_info info);
napi_value SetDemoChrome(napi_env env, napi_callback_info info);

/** HallPass 集成：配置页签文案 / 图标 path / 选中与未选中颜色，并同步选中页签。 */
napi_value SetTabs(napi_env env, napi_callback_info info);
napi_value SetSelectedTab(napi_env env, napi_callback_info info);

/** 注册/注销"页签被切换"的回调（ArkTS：`GlassGLRegisterTabCallback`），index 0..2。 */
napi_value RegisterTabCallback(napi_env env, napi_callback_info info);
napi_value UnregisterTabCallback(napi_env env, napi_callback_info info);

/** 渲染线程是否在跑（排查用）。 */
napi_value IsRunning(napi_env env, napi_callback_info info);

/**
 * HallPass 内联玻璃控件（开关 / 滑块）：一个 XComponent 一个渲染实例，按 id 寻址。
 *
 * - `WidgetConfigure(id, kind, density)`：绑定 / 配置（kind 0=开关 1=滑块）；
 * - `WidgetSetState(id, value)`：同步状态（开关 0/1，滑块 0..1）；
 * - `WidgetSetPress(id, pressed)`：同步按压 / 拖动；
 * - `WidgetSetColors(id, accentArgb, backgroundArgb)`：主题强调色 + 卡片底色；
 * - `WidgetIsRunning(id)`：渲染线程是否已起来（ArkTS 自检失败则回退原生控件）；
 * - `WidgetDispose(id)`：组件卸载时释放实例。
 */
napi_value WidgetConfigure(napi_env env, napi_callback_info info);
napi_value WidgetSetState(napi_env env, napi_callback_info info);
napi_value WidgetSetPress(napi_env env, napi_callback_info info);
napi_value WidgetSetColors(napi_env env, napi_callback_info info);
napi_value WidgetIsRunning(napi_env env, napi_callback_info info);
napi_value WidgetDispose(napi_env env, napi_callback_info info);

/**
 * 对话框（Dialog）：一个 XComponent 一个渲染实例，按 id 寻址。
 * - `DialogConfigure(id, buttonCount, panelHeightDp, density, dark)`
 * - `DialogSetBackdrop(id, data, width, height, stride)`
 * - `DialogSetPress(id, buttonIndex, pressed)`
 * - `DialogDispose(id)`
 */
napi_value DialogConfigure(napi_env env, napi_callback_info info);
napi_value DialogSetBackdrop(napi_env env, napi_callback_info info);
napi_value DialogSetPress(napi_env env, napi_callback_info info);
napi_value DialogSetGeometry(napi_env env, napi_callback_info info);
napi_value DialogDispose(napi_env env, napi_callback_info info);
napi_value DialogIsReady(napi_env env, napi_callback_info info);
napi_value DialogSetBackdropRect(napi_env env, napi_callback_info info);
napi_value DialogSetLiveRect(napi_env env, napi_callback_info info);
napi_value DialogSetTransform(napi_env env, napi_callback_info info);
napi_value SetContentExport(napi_env env, napi_callback_info info);
napi_value SharedBackdropReady(napi_env env, napi_callback_info info);

/**
 * 注册/注销"GL 里画的顶部按钮被点击"的回调（ArkTS：`GlassGLRegisterMenuCallback`）。
 *
 * `target`：0=底座，1=指示器·静止，2=指示器·拖动。
 * 触摸发生在 XComponent 上（UI 线程），但回调必须回到 JS 线程执行，所以内部用
 * `napi_threadsafe_function` 转发。
 */
napi_value RegisterMenuCallback(napi_env env, napi_callback_info info);
napi_value UnregisterMenuCallback(napi_env env, napi_callback_info info);

/**
 * 在模块 `Init` 里调用：如果 exports 里带了 XComponent 对象
 * （ArkTS 侧写了 `XComponent({ id, libraryname: 'backdrop' })`），就注册经典
 * `OH_NativeXComponent` 回调，由 ArkUI 直接驱动 Surface 生命周期。
 *
 * 这条路不依赖 `getAttachedFrameNodeById` → `OH_ArkUI_GetNodeHandleFromNapiValue`
 * 的映射（实测那条路拿到的 handle 无效：SurfaceHolder_Create 返回 null）。
 */
void RegisterNativeXComponent(napi_env env, napi_value exports);

}  // namespace glass

#endif  // GLASS_NAPI_H
