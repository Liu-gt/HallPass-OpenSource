#ifndef GLASS_GLES_RENDERER_H
#define GLASS_GLES_RENDERER_H

#include <EGL/egl.h>
#include <EGL/eglplatform.h>
#include <GLES3/gl3.h>
#include <native_image/native_image.h>
#include <native_vsync/native_vsync.h>

#include <atomic>
#include <condition_variable>

#include "glass_params.h"
#include "glass_scene.h"
#include "perf_probe.h"
#include "shared_backdrop.h"
#include <cstdint>
#include <mutex>
#include <string>
#include <unordered_map>
#include <vector>
#include <thread>

namespace glass {

/**
 * 极简 GLES 渲染器（Milestone 1）。
 *
 * 结构：
 *   XComponent surface -> EGL(window surface) -> [pass1: 背景进 FBO] -> [pass2: 折射/色散合成到屏幕]
 *
 * 设计要点：
 * - 渲染跑在**独立线程**（`eglSwapBuffers` 天然被 buffer queue 按 vsync 节流），
 *   不依赖 ArkUI 的帧回调语义。
 * - 所有 GL 对象只能在该线程创建/销毁；surface 生命周期回调（UI 线程）只做
 *   "置标志 + 传窗口指针 + join"。
 */

struct Rect {
    float x = 0.0f;
    float y = 0.0f;
    float width = 0.0f;
    float height = 0.0f;
};

struct RectF {
    float x = 0.0f;
    float y = 0.0f;
    float w = 0.0f;
    float h = 0.0f;
};

enum class ConsumerType { TabBar, GenericGlass };

struct GlassConsumer {
    std::string id;
    EGLSurface surface = EGL_NO_SURFACE;
    void *nativeWindow = nullptr;
    ConsumerType type = ConsumerType::TabBar;
    Rect rect;             // 屏幕像素坐标
    bool lagCompensation = true;
    std::unordered_map<int, float> params;
    bool isDead = false;
};

class GlesRenderer {
public:
    static GlesRenderer &Instance();

    /** UI 线程：surface 就绪，传入 OHNativeWindow*（以 void* 传递，避免头文件外泄）。 */
    void OnSurfaceCreated(void *nativeWindow, uint64_t width, uint64_t height, const std::string& id = "");
    void RegisterConsumer(const std::string& id, ConsumerType type, const Rect& rect, bool lagCompensation, const std::unordered_map<int, float>& params, void* nativeWindow);
    void UnregisterConsumer(const std::string& id);
    void SetScrollRegion(float left, float top, float right, float bottom);


    /** UI 线程：尺寸变化。 */
    void OnSurfaceChanged(uint64_t width, uint64_t height);

    /**
     * UI 线程：surface 销毁，等渲染线程退出。
     *
     * `timeoutMs < 0`：无限等待（页签单例，surface 生命周期与页面一致，join 必须彻底）；
     * `timeoutMs >= 0`：最多等这么久。返回 false = 线程卡在 GL 调用里没退出来，
     * 调用方**不能**销毁本对象（否则线程会用已释放内存），要转交延迟回收
     * （见 glass_napi.cpp 的 widget 僵尸队列）。内联控件的 surface 拆除会与
     * ArkUI 的销毁交错，实测有卡在 eglSwapBuffers 里 9 秒的情况。
     */
    bool OnSurfaceDestroyed(int timeoutMs = -1);

    /** 渲染线程是否已经退出（延迟回收用）。 */
    bool IsThreadExited() const { return threadExited_.load(); }

    /** 是否正在渲染（给 napi 查询用）。 */
    bool IsRunning() const { return running_.load(); }

    void SetFloat(int id, float value);
    void SetBool(int id, bool value);

    /** 切目录场景（`glass_scene.h` 的 Scene 枚举）。切场景会重置该场景的动画状态。 */
    void SetScene(int scene);
    int Scene() const { return scene_.load(); }

    /** 显示密度（vp -> px）。ArkTS 侧在页面上报，缺省 4。 */
    void SetDensity(float density) {
        params_.SetDensity(density);
        labelsDirty_.store(true);
        contentTextDirty_.store(true);
        overlayTextDirty_.store(true);
        dialogBtnLabelDirty_.store(true);
        forceRedraw_.store(true);
        RequestRedraw();
    }

    /** 深浅色模式同步（深色模式下弹窗等组件自动切换暗色通透玻璃与浅色文字）。 */
    void SetDarkMode(bool dark);
    bool IsDarkMode() const { return darkMode_.load(); }

    /** 对话框配置：按钮数量（0/1/2）、自定义高度（dp，0=默认209dp）、是否自定义文本（true=不绘制demo文本）。 */
    void SetDialogConfig(int buttonCount, float panelHeightDp, bool custom);
    /** 对话框按钮按压同步。 */
    void SetDialogPress(int index, bool pressed);

    /** 设置对话框精确几何布局（ArkTS 侧通过 onAreaChange 上报屏幕顶层像素坐标，内部转 GL 坐标）。 */
    void SetDialogGeometry(float cardX, float cardY, float cardW, float cardH,
                           const std::vector<RectF> &buttons);
    /** 对话框已带着真实背景 + 几何交出首帧（ArkTS 文字层据此淡入，避免文字先于玻璃出现）。 */
    bool IsDialogPresented() const { return dialogPresented_.load(); }
    /** 背景快照在 surface 里的矩形（px，左上原点）；不设则按 cover 居中（demo 壁纸）。 */
    void SetDialogBackdropRect(float x, float y, float w, float h);
    /**
     * 实时背景（共享镜像纹理）在本 surface 里的矩形（px，左上原点）；w <= 0 关闭、回退快照。
     * 只有建上下文时成功加入中枢 share group 的弹窗才会真正用上。
     */
    void SetDialogLiveRect(float x, float y, float w, float h);
    /**
     * 出现 / 消失动效（HallPass 嵌入式弹窗）：整体绕 pivot（surface px，左上原点）缩放 scale。
     * 由原生按变换后的真实屏幕位置画玻璃，折射全程采样真实背景（ArkUI 只缩放文字层）。
     */
    void SetDialogTransform(float scale, float pivotX, float pivotY);

    /**
     * 中枢（页签渲染器）：镜像树实际导出的上沿余量（vp，< 0 = 与条带余量相同）。
     * 有整屏消费者时 ArkTS 把镜像放开到整页，纹理比页签条带高；页签自己只从底部裁条带。
     */
    void SetContentExport(float extraTopVp);
    /** 中枢已就位且收到过内容帧：弹窗可以走实时背景。 */
    static bool SharedBackdropReady();
    /** 主树当前滚动偏移（vp，含外推）：共享背景消费者做滞后补偿用。 */
    static float SharedContentOffsetVp();

    /** 消融/调试：0=正常 1=只画背景 2=只画折射 3=不画玻璃 */
    void SetDebugMode(int mode);

    /**
     * 上层暂停/恢复绘制（功耗开关）。页面不可见（被覆盖、进后台、切到别的 tab）时调用，
     * 渲染线程会停止出帧、也不再步进动画；surface 保留最后一帧。
     *
     * 仍会继续消费 ArkTS 内容纹理的帧，避免把 ArkUI 的 BuilderNode 生产端堵住。
     * 恢复后会自动补画一帧。控件实例有自己的按需渲染（WidgetSettled / WaitWidgetIdle），
     * 这个接口只作用于页签 / 整屏实例。
     */
    void SetPaused(bool paused);

    /**
     * 触摸（屏幕坐标，y 从**顶部**起算）。由 XComponent 的 DispatchTouchEvent 调用。
     * 只关心底部的玻璃条区域；在条上按下即可拖动指示器。
     */
    void OnTouch(int action, float x, float y, int64_t timestampMs);

    /** 照片背景的裸 RGBA 数据（前 8 字节 = u32 LE 宽、u32 LE 高）。由 ArkTS 读 rawfile 后传入。 */
    void SetPhotoData(const void *data, size_t length);

    /**
     * 背景快照（HallPass 集成）：RGBA8888、行 0 = 顶部，无 8 字节头，
     * 显式给宽 / 高 / 源行跨度（byte）。数据按行拷进内部缓冲，调用后可立即释放。
     *
     * 与 SetPhotoData 的区别：快照由 `PixelMap.readPixels()` 直接给出，行间可能有
     * 对齐填充（stride > width×4），且不该再套一层 8 字节头。
     */
    void SetBackdropData(const void *data, size_t length, int width, int height, int srcRowBytes);

    /**
     * 背景位移（HallPass 集成）：内容相对上一帧的位移（vp，正 = 内容上移 / 左移）。
     * 滚动时把页面滚动增量喂进来，背景快照按同样位移平移采样 —— 玻璃里的画面
     * 与真实内容同帧，快照退化为定期纠偏。0/0 = 不做位移。
     */
    void SetBackdropShift(float dxVp, float dyVp);

    /**
     * 镜像树（BuilderNode 纹理导出）**逻辑上已经应用**的滚动偏移（vp，正 = 内容上移）。
     *
     * 只是"逻辑落点"：离屏渲染出帧要晚 1~2 帧，玻璃里当下真正装的是**出帧那一刻**
     * 的偏移。渲染线程收到 `OH_NativeImage` 帧可用回调时把它锁存为"纹理偏移"，
     * ArkTS 用 `FrameMirrorOffset()` 取它做滞后补偿（见 GlassBandModel）。
     *
     * `resync = true` 用于切页 / 重建这类**换内容**的时刻：把纹理偏移也直接置成新值。
     * 否则补偿会拿上一页的偏移去算，得到一大截假的"越界平移"。
     */
    void SetMirrorOffset(float offsetVp, bool resync = false);

    /**
     * 主树（ArkUI 直显）的视觉偏移（vp，正 = 内容上移）+ 一帧外推量（vp）。
     *
     * 每次滚动上报推一次。渲染线程用 `offset + 衰减后的 lead - 手里那帧纹理的偏移`
     * 算采样位移（`ContentShift()`），**在画这一帧时算**：
     * 补偿量因此永远对应"当下采样的那块纹理"，纹理跳变（镜像重排量化 /
     * 退帧）与补偿回落在同一帧里互相抵消 —— 在 ArkTS 侧算会差一拍，看起来就是闪。
     */
    void SetContentOffset(float offsetVp, float leadVp);

    /**
     * 内容条带镜像的**上下余量** + 采样位移预算（vp，见 GlassTabShell / GlassBandModel）。
     *
     * 镜像纹理（NodeContainer）比 GL 的条带 surface 高 `extraTop + extraBottom`：
     * 背景 pass 采样时把 surface 的 UV 映射到纹理的
     * `[extraBottom, extraBottom + surfaceH]` 区间，再把采样位移（可正可负）叠上去 ——
     * 下拉刷新 / 越界回弹的整段位移由采样直接吃掉（当帧生效），不再依赖晚 1~2 帧的
     * 镜像容器平移。预算非对称：负位移（下拉，往纹理上沿采）用 `shiftUpVp`，
     * 正位移（底部回弹，往纹理下沿采）用 `shiftDownVp`，两者必须 ≤ 对应方向的余量
     * （超出会采到纹理外，被 CLAMP_TO_EDGE 钉住）。
     *
     * 调用后按新尺寸重建内容纹理（渲染线程下一轮 EnsureTargets 生效）。
     */
    void SetContentBand(float extraTopVp, float extraBottomVp, float shiftUpVp, float shiftDownVp);

    /** 当前内容模式的采样位移（vp，正 = 内容上移；诊断用）。 */
    float ContentShift() const { return contentShiftVp_.load(); }

    /**
     * 当前这帧纹理对应的镜像逻辑偏移（vp）：最后一次出帧回调时锁存的值。
     * 补偿用的"镜像真正装在哪"就是它，而不是 SetMirrorOffset 的最新值。
     */
    float FrameMirrorOffset() const { return frameMirrorOffsetVp_.load(); }

    /** 累计消费到的内容纹理帧数（诊断：确认镜像真的在出帧）。 */
    int64_t ContentFrameCount() const { return contentFramesTotal_.load(); }

    /** `OH_NativeImage` 帧可用回调（生产端每出一帧）：锁存纹理偏移 + 唤醒渲染线程。 */
    void HandleContentFrameAvailable();

    /**
     * ArkTS 实时内容纹理的 surfaceId（BuilderNode 纹理导出）。
     *
     * 渲染线程启动时创建 `OH_NativeImage`（消费端），ArkTS 侧把这个 surfaceId 交给
     * `BuilderNode(RENDER_TYPE_TEXTURE)`，ArkUI 就会把组件树渲染进这张纹理；
     * 渲染线程每帧 `OH_NativeImage_UpdateSurfaceImage` 取最新帧（GPU 直达，不过 CPU）。
     * 返回空串表示渲染线程还没起来 / 未创建内容纹理，调用方需要稍后重试。
     */
    std::string ContentSurfaceId() const;

    /** 是否已经收到过内容纹理的帧（ArkTS 侧切换到"内容由 GL 绘制"的门槛）。 */
    bool HasContentFrame() const { return contentEverValid_.load(); }

    /**
     * 把 ArkTS 内容纹理当背景：背景 pass 按 1:1 采样内容纹理，最终成帧先整屏铺它、
     * 再把页签条叠上去（页签 / 叠加模式下）。不开时走原来的照片 / 快照背景。
     */
    void SetContentBackdrop(bool on) {
        contentBackdrop_.store(on);
        RequestRedraw();
    }

    /**
     * 叠加（island）模式：surface 保持透明，只画页签条本体。
     *
     * 页签条之外的像素 alpha = 0（只留页签条自己的投影），于是 ArkUI 应用内容原样透出；
     * 底板内部仍用背景纹理（ArkTS 回填的内容快照）做模糊 / 折射。
     * 关闭时回到 demo 的"整屏自渲染"行为。
     */
    void SetOverlayMode(bool on) {
        overlayMode_.store(on);
        RequestRedraw();
    }

    /** demo 专属件开关：false 时隐藏/禁用顶部三个玻璃按钮与可拖动浮动玻璃件、照片纵向滚动。 */
    void SetDemoChrome(bool on) {
        demoChrome_.store(on);
        RequestRedraw();
    }

    /**
     * 页签文案 / 图标（24×24 视口的绝对 M/L/Q/Z SVG path）/ 选中与未选中颜色（ARGB）。
     * labels 必须正好 3 条（页签几何写死三格）；传空 = 用内置默认值（首页/搜索/我的）。
     */
    void SetTabs(const std::vector<std::string> &labels, const std::vector<std::string> &iconPaths,
                 uint32_t selectedArgb, uint32_t unselectedArgb);

    /** 外部（ArkTS）同步选中页签：指示器弹簧移动过去，并按新选中态重渲染文字位图。 */
    void SetSelectedTab(int index);

    /** 页签被点击 / 拖动切换时回调（index 0..2）。实现见 `glass_napi.cpp`。 */
    using TabChangeFn = void (*)(int index);
    void SetTabChangeFn(TabChangeFn fn) { tabChangeFn_.store(fn); }

    /**
     * 顶部三个玻璃按钮被点击时回调（target：0=底座，1=指示器·静止，2=指示器·拖动）。
     *
     * 之所以要这条回链：菜单本身是 ArkUI 画的，而按钮画在 GL 里；原生只能把
     * "哪个按钮被点了"告诉 ArkTS。实现见 `glass_napi.cpp`（napi threadsafe function）。
     */
    using MenuRequestFn = void (*)(int target);
    void SetMenuRequestFn(MenuRequestFn fn) { menuRequestFn_.store(fn); }

    // -------------------------------------------------------------------------
    // HallPass 内联玻璃控件（开关 / 滑块）
    //
    // 与页签条不同，这里**一个渲染器实例只服务一个 XComponent**：
    // - 控件尺寸就是 XComponent 尺寸（由 ArkUI 排版决定），原生按 surface 尺寸摆轨道 / 旋钮；
    // - 背景是固定的卡片底色（只有深浅色会变），不走内容快照 —— 每帧直接用底色清屏，
    //   折射 / 模糊采样的就是这块纯色，因此可以**按需渲染**（不交互就休眠，见 RequestRender）；
    // - 触摸 / 手势由覆盖在上层的 ArkUI 控件（Toggle / Slider）处理，原生只负责画，
    //   按下 / 拖动 / 值由 ArkTS 侧同步进来（SetWidgetPress / SetWidgetState）。
    // -------------------------------------------------------------------------

    /** 控件种类：0 = 开关，1 = 滑块（在 surface 创建前设定，决定 GL 程序集与绘制路径）。 */
    enum WidgetKind : int {
        kWidgetToggle = 0,
        kWidgetSlider = 1,
    };

    /** 标记本实例为内联控件实例（帧循环 / GL 初始化 / 按需渲染都走控件分支）。 */
    void SetWidgetKind(int kind);
    bool IsWidgetMode() const { return widgetKind_.load() >= 0; }

    /** 控件显示密度（vp -> px）：控件实例独立于页签单例，必须在 surface 创建前上报。 */
    void SetWidgetDensity(float density) { params_.SetDensity(density); }

    /** 同步控件状态：开关 0/1，滑块 0..1（目标值，动画由内部弹簧追随）。 */
    void SetWidgetState(float value);

    /** 同步按按压 / 拖动状态（ArkUI 侧 Down / Up / Begin / End 上报）。 */
    void SetWidgetPress(bool pressed);

    /** 强调色（主题 primary）与背景色（所在卡片底色），均为 ARGB。 */
    void SetWidgetColors(uint32_t accentArgb, uint32_t backgroundArgb);

    /** 标记"有新内容要画"并唤醒休眠中的渲染线程（改状态 / 颜色 / 尺寸都走这里）。 */
    void RequestRender();

    /**
     * 标记"这一帧要重画"并**立刻唤醒**可能睡在节拍等待上的渲染线程。
     *
     * 页签 / 整屏实例的所有外部输入（参数 / 位移 / 内容帧 / 触摸）都走这里：
     * 睡了就等下一次节拍醒来 = 白白多 1 帧延迟，玻璃的跟随感就折在这一段上。
     */
    void RequestRedraw() {
        forceRedraw_.store(true);
        NotifyFrame();
    }

    /** 内联控件的按需渲染：无变化时阻塞等待，返回 false = 被 stop 请求叫醒（该退出）。 */
    bool WaitWidgetIdle(int timeoutMs);

    /** 创建内联控件实例（构造器私有；页签单例仍走 Instance()）。 */
    static GlesRenderer *CreateInstance();

    ~GlesRenderer() = default;

private:
    GlesRenderer() = default;
    
    std::vector<GlassConsumer> consumers_;
    std::mutex consumersMutex_;
    
    struct ConsumerCommand {
        bool isAdd;
        GlassConsumer consumer;
    };
    std::vector<ConsumerCommand> commandQueue_;
    std::mutex commandMutex_;
    void ProcessCommandQueue();

    Rect scrollRegionRect_ = {0.0f, 0.0f, 0.0f, 0.0f};
    GlassConsumer* currentConsumer_ = nullptr;

    GlesRenderer(const GlesRenderer &) = delete;
    GlesRenderer &operator=(const GlesRenderer &) = delete;

    /**
     * glGetUniformLocation 的缓存：每帧 ~170 次驱动侧字符串查找换成哈希表查找。
     * name 必须是**字符串字面量**（按指针做键）；程序重建（DestroyGl）时清空。
     */
    GLint Uniform(GLuint program, const char *name);
    struct UniformKey {
        GLuint program;
        const char *name;
        bool operator==(const UniformKey &other) const {
            return program == other.program && name == other.name;
        }
    };
    struct UniformKeyHash {
        size_t operator()(const UniformKey &key) const {
            return std::hash<const void *>()(key.name) ^ (static_cast<size_t>(key.program) * 0x9E3779B97F4A7C15ull);
        }
    };
    std::unordered_map<UniformKey, GLint, UniformKeyHash> uniformCache_;

    // ---- 渲染线程内部 ----
    void RenderLoop(void *window);
    bool InitEgl(void *window);
    bool InitGl();
    void DestroyGl();
    void DestroyEgl();
    bool EnsureTargets(int w, int h);
    void DrawFrame(float seconds);
    void LogFps();

    /**
     * 节拍等待：睡到下一个时间点（交互中 120fps，其余 60fps），
     * **但有信号（内容帧 / 位移 / 触摸）就立刻返回 true** —— 那一帧不等节拍直接画。
     * 只在拿不到 vsync（OH_NativeVSync 建不起来）时兜底用，正常走 WaitForRenderSlot。
     */
    bool PaceFrame();

    // -------------------------------------------------------------------------
    // vsync 对齐出帧（页签中枢 / 弹窗实例）
    //
    // 交出的帧在**下一个 vsync** 才被取走（SURFACE：RS 合成时；TEXTURE：UI 线程帧内 vsync + ~0.8ms），
    // 两次取走之间交出的帧只有最后一张会上屏：多画的是白白浪费 GPU，TEXTURE 下还会把 5 张的
    // buffer 队列塞满、让 RequestBuffer 阻塞（基线实测滚动时 15% 的帧被覆盖、累计阻塞 ~2s/14s）。
    // 所以每个 vsync 周期最多画一帧，出帧点放在 vsync + δ：本周期的主树偏移（+0.5ms）与
    // 大部分镜像帧（+2ms）都已到齐，离被取走还留 ~3ms。
    // -------------------------------------------------------------------------

    /** 渲染线程：建 vsync 连接（失败则退回 PaceFrame 的时间节拍）。 */
    void CreateVsync();
    void DestroyVsync();
    /** 请求下一次 vsync 回调（一次性；同一周期内重复请求只回调一次）。 */
    void RequestVsync();
    static void OnVsyncCallback(long long timestamp, void *data);
    /**
     * 本轮能否立刻画：true = 画；false = 已经按节拍等过（回顶部重新消费输入再画）。
     * 规则：本 vsync 周期已画过 / 离下个 vsync 太近 → 等下一个 vsync；否则等到 vsync + δ。
     */
    bool WaitForRenderSlot();

    /**
     * 唤醒渲染线程：置信号 + notify（可从任意线程调用，只做两件原子事）。
     *
     * 之前渲染线程全靠 `sleep_for(16ms)`，外部输入要等下一次醒来才被看见，
     * 白白多 1 帧（120Hz 上还带相位抖动）。所有"会改变画面"的入口都要带上它。
     */
    void NotifyFrame();

    /** 置停止标志并叫醒渲染线程的所有等待（空闲 / 暂停 / 节拍 / 内联控件），不丢唤醒。 */
    void SignalStop();

    /** 等在信号上（超时 timeoutMs）；返回 true = 被信号唤醒（stop 也算）。 */
    bool WaitFrame(int timeoutMs);

    // -------------------------------------------------------------------------
    // ArkTS 内容纹理（BuilderNode 纹理导出）
    //
    // 链路：ArkUI 渲染 BuilderNode -> OH_NativeImage（外纹理 GL_TEXTURE_EXTERNAL_OES）
    //       -> 每帧 blit 到 2D 的 contentBlitTex_ -> 背景 pass 按条带映射采样。
    // 之所以要 blit 成 2D：模糊链 / CopyBackgroundToScene 都只认 sampler2D。
    // contentBlitTex_ 的尺寸 = **条带 + 上下余量**（SetContentBand），比 surface 高。
    // -------------------------------------------------------------------------

    /** 渲染线程：创建外纹理 + OH_NativeImage（拿 surfaceId）。 */
    void CreateContentImage();
    /** 渲染线程：取最新帧并 blit 到 contentBlitTex_。返回 true 表示这帧有新内容。 */
    bool UpdateContentTexture(int w, int h);
    /** 渲染线程：每帧重算内容模式的采样位移（见 SetContentOffset）。 */
    void UpdateContentShift();
    /** 把外纹理当前帧（用保存的变换矩阵）blit 到刚重建的 contentBlitTex_（尺寸变化后补内容）。 */
    void ReblitContentTexture(int w, int h);
    /** 内容纹理比 surface 高出的总高（px，= extraTop + extraBottom，见 SetContentBand）。 */
    int ContentBandExtraPx() const;
    /** 内容纹理下沿相对 surface 下沿的偏移（px，= extraBottom，背景采样映射用）。 */
    int ContentBandBottomPx() const;

    // -------------------------------------------------------------------------
    // 目录场景（catalog）—— 一个 XComponent 画一个场景，见 glass_scene.h
    // -------------------------------------------------------------------------

    /** 通用玻璃件描述。`DrawGlass` 把这里的字段映射到 progGlass_ 的 uniform。 */
    struct GlassSpec {
        float x = 0.0f;          // 左下角（GL 坐标，y 从屏幕底部起算）
        float y = 0.0f;
        float w = 0.0f;
        float h = 0.0f;
        float rTL = 0.0f;
        float rTR = 0.0f;
        float rBR = 0.0f;
        float rBL = 0.0f;
        float scaleX = 1.0f;     // 形状缩放（绕中心；按压变形用）
        float scaleY = 1.0f;
        float refractionHeight = 0.0f;
        float refractionAmount = 0.0f;
        bool dispersion = false;
        bool depthEffect = false;
        float surfaceAlpha = 0.0f;
        float surfaceR = 1.0f;
        float surfaceG = 1.0f;
        float surfaceB = 1.0f;
        float vibrancy = 1.0f;
        float blurRadiusPx = 0.0f;
        float brightness = 0.0f;
        float contrast = 1.0f;
        float saturation = 1.0f;
        float effectOpacity = 1.0f;
        float highlight = 0.0f;          // 描边环亮度
        bool plainHighlight = false;
        bool ambient = false;
        float ambientIntensity = 0.38f;  // 环境光强度（开关旋钮按按压进度缩放）
        float highlightWidthPx = 2.0f;
        float highlightBlurPx = 1.0f;
        bool hasShadow = true;
        float shadowBlurPx = 0.0f;
        float shadowOffsetPx = 0.0f;
        float shadowAlpha = 0.0f;
        /** 外投影纵向渐变：0 = 均匀一圈；1 = 中线以上不投影、往下渐强（见 shader）。 */
        float shadowSpreadV = 0.0f;
        float innerRadiusPx = 0.0f;
        float innerAlpha = 0.0f;
        float g2Factor = 0.45f;          // G2 连续曲率平滑系数（0 = 标准圆弧，0.45 = 默认 G2）
        float rimClarity = 0.38f;        // 边缘清晰折射采样混入比例（0..1）
        float bevelAlphaScale = 0.68f;   // 边缘折射棱面处表面底色保留比例（0..1）
        /** 内阴影顶部掩码：0 = 沿内缘均匀；1 = 用 innerTopCut 的纵向截止掩码。 */
        float innerTopBias = 0.0f;
        /** 顶部掩码截止比例（0..1，按高度从顶往下量）：0.75 = 顶部往下 75% 内有内阴影。 */
        float innerTopCut = 0.75f;
        /** 内阴影实心度（0 = 从边缘一路柔化；1 = 前 55% 半径实心、后段柔化，贴边一圈壳沿）。 */
        float innerSharp = 0.0f;
        /** 内阴影纵向收细：顶部半径 1×，到 innerTopCut 处收到本倍率（1 = 不收细）。 */
        float innerTaper = 1.0f;
        // 采样变换（放大镜用）：samplePx = pivot + (px - pivot) / scale
        float sampleScaleX = 1.0f;
        float sampleScaleY = 1.0f;
        float samplePivotX = 0.0f;
        float samplePivotY = 0.0f;
        // 采样源用**背景**而不是 sceneTex_。用于"要画进 sceneTex_ 的底层玻璃"：
        // 目标纹理 == 采样纹理会构成 GL 的读写反馈（未定义行为），换成 bgTex_ 即可避免。
        bool useBackground = false;
        // 平滑高斯模糊（RenderBlurSmooth）：blurRadiusPx 按 sigma 解释。HallPass 嵌入式弹窗用，
        // 背景是带文字的 UI，主模糊链的大步距 9-tap 会把文字采成多份错位重影。
        bool smoothBlur = false;
        // 平滑模糊只需在这个矩形（屏幕 px，GL 坐标）内有效：各级降采样按比例裁剪（nullptr = 整屏）。
        const RectF *blurClip = nullptr;
        // 玻璃本体只需画在这个矩形内（与"形状 + 投影外扩"的裁剪盒取交集；nullptr = 不额外裁）。
        const RectF *drawClip = nullptr;
        // GPU 计时归到哪个 pass（GLASS_PERF_PROBE；< 0 = 不计，由调用方的作用域统一计）。
        int gpuPass = -1;
    };

    /** 纯色圆角矩形描述（轨道 / 填充 / 卡片 / 按钮底色）。 */
    struct SolidSpec {
        float x = 0.0f;
        float y = 0.0f;
        float w = 0.0f;
        float h = 0.0f;
        float rTL = 0.0f;
        float rTR = 0.0f;
        float rBR = 0.0f;
        float rBL = 0.0f;
        float r = 0.0f;          // 四值相等时的快捷写法（覆盖上面的独立圆角）
        float a = 1.0f;
        float colorR = 1.0f;
        float colorG = 1.0f;
        float colorB = 1.0f;
    };

    /**
     * 画一个玻璃件：采样 sceneTex_（清晰）与该半径的模糊结果。
     *
     * targetFbo = 0 时画到屏幕（正常）；非 0 时画进 sceneTex_（游乐场的叠层，
     * 让上层玻璃能采样到它）。半径相同的连续调用会复用同一张模糊结果（帧内缓存）。
     */
    void DrawGlass(const GlassSpec &spec, GLuint targetFbo, int w, int h);
    /** 画一个纯色圆角矩形（调用方负责 framebuffer 与混合状态）。 */
    void DrawSolid(const SolidSpec &spec, int w, int h);
    /** 贴一张位图到屏幕矩形（带混合；调用方负责 framebuffer）。alpha 做整体淡入淡出。 */
    void DrawSprite(GLuint tex, float x, float y, float w, float h, int screenW, int screenH,
                    float alpha = 1.0f);
    /** 背景 -> sceneTex_ 的拷贝。 */
    void CopyBackgroundToScene(int w, int h);
    /** 把一张纹理原样铺满屏幕（progCopy_，不透明）。 */
    void BlitTexture(GLuint tex, int w, int h);
    /** pass 1：背景（照片）-> bgTex_。 */
    void RenderBackground(int w, int h);
    /** 玻璃件默认材质（对齐上游 Shadow.Default + Highlight.Default）。 */
    GlassSpec DefaultGlass(float x, float y, float w, float h, float radius, float d) const;
    /** 开关 / 滑块旋钮**共用**的材质（胶囊形，半径 = 高 / 2）。 */
    GlassSpec KnobGlass(float x, float y, float w, float h, float d, float press) const;
    /** 同一采样源 + 半径的模糊结果帧内缓存。 */
    GLuint BlurFor(GLuint sourceTex, float radiusPx, int w, int h);

    // 各场景的绘制入口（DrawTabsScene 从 pass 2 开始；pass 1 在 DrawFrame 里统一画）
    void DrawTabsScene(int w, int h, int mode);
    void DrawCatalogScene(int w, int h);
    void DrawButtonsScene(int w, int h);
    void DrawToggleScene(int w, int h);
    void DrawSliderScene(int w, int h);
    void DrawDialogScene(int w, int h);
    void DrawControlCenterScene(int w, int h);
    void DrawLockScreenScene(int w, int h);
    void DrawMagnifierScene(int w, int h);
    void DrawProgressiveBlurScene(int w, int h);
    void DrawAdaptiveScene(int w, int h);
    void DrawScrollScene(int w, int h, bool lazy);
    void DrawPlaygroundScene(int w, int h);
    // HallPass 内联控件：一个 surface 只画一个开关 / 滑块（透明背景由 surface 自己铺底色）
    void DrawWidgetScene(int w, int h);
    void DrawToggleCore(int w, int h, bool widget);
    void DrawSliderCore(int w, int h, bool widget);
    /** 控件弹簧是否已经静止（按需渲染的休眠判据）。 */
    bool WidgetSettled();

    // ---- 目录场景的文字层 ----
    // 文字分两层：content 层画进 sceneTex_（会被上层玻璃折射，如锁屏钟表），
    // overlay 层画在玻璃之上（如按钮文字、对话框正文）。两层各一张位图，按需重传。
    GLuint contentTextTex_ = 0;
    GLuint overlayTextTex_ = 0;
    int contentTextW_ = 0;
    int contentTextH_ = 0;
    int overlayTextW_ = 0;
    int overlayTextH_ = 0;
    // 位图对应的屏幕矩形（GL 坐标）；文字位图不必覆盖全屏（如自适应亮度的数值）。
    float contentTextX_ = 0.0f;
    float contentTextY_ = 0.0f;
    float overlayTextX_ = 0.0f;
    float overlayTextY_ = 0.0f;
    std::atomic<bool> contentTextDirty_{true};
    std::atomic<bool> overlayTextDirty_{true};
    bool UploadContentText(int w, int h);
    bool UploadOverlayText(int w, int h);
    /** 构造文字层内容（返回 false 表示本场景不需要该层）。 */
    bool BuildContentText(int scene, int w, int h, std::vector<struct TextRun> &runs);
    bool BuildOverlayText(int scene, int w, int h, std::vector<struct TextRun> &runs);
    void DrawContentText(int w, int h);
    void DrawOverlayText(int w, int h);

    // 对话框按钮的独立文字纹理（随按钮按压缩放同步缩放）
    GLuint dialogBtnLabelTex_ = 0;
    int dialogBtnLabelW_ = 0;
    int dialogBtnLabelH_ = 0;
    std::atomic<bool> dialogBtnLabelDirty_{true};
    std::atomic<bool> darkMode_{false};
    bool UploadDialogBtnLabel(int w, int h);

    /** 控制中心 / 游乐场的飞机图标（一次性栅格化）。 */
    GLuint planeIconTex_ = 0;
    int planeIconSizePx_ = 0;

    std::atomic<int> scene_{static_cast<int>(Scene::kTabs)};

    // ---- 目录场景的动画状态（各场景独立；切场景时重置） ----
    static constexpr int kScenePressMax = 8;
    float scenePress_[kScenePressMax] = {0.0f};
    float scenePressVel_[kScenePressMax] = {0.0f};
    int sceneDown_ = -1;

    // 开关
    float toggleFraction_ = 0.0f;
    float toggleFractionVel_ = 0.0f;
    float togglePress_ = 0.0f;
    float togglePressVel_ = 0.0f;
    bool toggleOn_ = false;
    bool toggleDragging_ = false;
    float toggleDownX_ = 0.0f;              // 按下时的屏幕 x（拖动按位移换算）
    float toggleGrabStartFraction_ = 0.0f;  // 按下时的 fraction
    float toggleDragTarget_ = 0.0f;         // 拖动时手指映射出的目标 fraction（fraction 弹簧追随它）
    bool toggleDidDrag_ = false;
    float toggleScaleX_ = 1.0f;
    float toggleScaleXVel_ = 0.0f;
    float toggleScaleY_ = 1.0f;
    float toggleScaleYVel_ = 0.0f;
    // 拖动速度（fraction/s，弹簧平滑）与上一帧 fraction：按压拖动时拉长/压扁形变用
    float toggleVelocity_ = 0.0f;
    float toggleVelocityVel_ = 0.0f;
    float toggleFractionLast_ = 0.0f;

    // 滑块
    float sliderValue_ = 50.0f;      // 0..100（手指给的目标值）
    // 旋钮的动画值：弹簧追 sliderValue_ —— 拖动时旋钮**滞后**手指一点点，
    // 松手/停手时再弹回去（q 弹的来源）。轨道填充仍用目标值，读数不拖泥带水。
    float sliderValueAnim_ = 50.0f;
    float sliderValueAnimVel_ = 0.0f;
    float sliderValueAnimLast_ = 50.0f;
    // 弹簧平滑后的动画值速度（%/s）：驱动拖动时的拉长/压扁形变
    float sliderVelocity_ = 0.0f;
    float sliderVelocityVel_ = 0.0f;
    float sliderPress_ = 0.0f;
    float sliderPressVel_ = 0.0f;
    bool sliderDragging_ = false;
    float sliderGrabValue_ = 0.0f;
    float sliderGrabX_ = 0.0f;
    bool sliderDidDrag_ = false;
    float sliderScaleX_ = 1.0f;
    float sliderScaleXVel_ = 0.0f;
    float sliderScaleY_ = 1.0f;
    float sliderScaleYVel_ = 0.0f;

    // 对话框按钮按压与弹簧缩放
    float dialogPress_[2] = {0.0f, 0.0f};
    float dialogPressVel_[2] = {0.0f, 0.0f};
    int dialogDown_ = -1;
    float dialogScale_ = 1.0f;
    float dialogScaleVel_ = 0.0f;
    std::atomic<int> dialogButtonCount_{1};
    std::atomic<float> dialogPanelHeightDp_{0.0f};
    std::atomic<bool> dialogCustom_{false};
    std::atomic<bool> dialogGeoCustom_{false};
    std::atomic<bool> dialogPresented_{false};
    bool photoUploaded_ = false;
    RectF dialogPhotoRect_{0.0f, 0.0f, 0.0f, 0.0f};   // dialogGeoMutex_ 保护
    bool dialogPhotoMapped_ = false;
    RectF dialogLiveRect_{0.0f, 0.0f, 0.0f, 0.0f};    // dialogGeoMutex_ 保护
    bool dialogLiveEnabled_ = false;
    float dialogXfScale_ = 1.0f;      // dialogGeoMutex_ 保护
    float dialogXfPivotX_ = 0.0f;
    float dialogXfPivotY_ = 0.0f;
    bool liveDrawn_ = false;          // 渲染线程独占：已用实时背景画过（首帧就绪判定）

    // ---- 共享实时背景（见 shared_backdrop.h）----
    bool IsHub() const { return this == &Instance(); }
    /** 消费者：建 EGL 上下文时是否加入中枢 share group（弹窗实例）。 */
    bool WantsSharedBackdrop() const;
    /** 中枢：把外部内容纹理整幅 blit 进共享槽并发布。 */
    bool PublishSharedBackdrop();
    /** 中枢：实际导出纹理的总余量（px，上 + 下）。 */
    int ContentExportExtraPx() const;
    std::atomic<float> contentExportExtraTopVp_{-1.0f};
    /** 导出余量改了、还没收到按新尺寸渲染的帧：这期间不发布（外纹理里还是旧尺寸的帧）。 */
    std::atomic<bool> exportPending_{false};
    /** 手里这帧外纹理对应的导出余量（px，出帧时锁存；-1 = 未锁存，按当前设置算）。 */
    int frameExportExtraPx_ = -1;
    /** 上次发布因两槽都在用而跳过：下一轮重试（页面静止时不会再有新帧来触发）。 */
    bool sharedRetry_ = false;
    GLuint sharedTex_[2] = {0, 0};
    GLuint sharedFbo_[2] = {0, 0};
    int sharedW_[2] = {0, 0};
    int sharedH_[2] = {0, 0};
    uint64_t sharedGen_ = 0;          // 消费者：加入的中枢代际（0 = 未共享）
    int sharedReaderToken_ = 0;
    bool carryActive_ = false;   // 渲染线程：上一轮已判定要画、节拍被打断后带到下一轮   // 渲染线程独占：真实背景已上传（区别于 1×1 占位纹理）
    std::mutex dialogGeoMutex_;
    RectF dialogCardTopDown_{0.0f, 0.0f, 0.0f, 0.0f};
    std::vector<RectF> dialogBtnsTopDown_;

    // 控制中心：展开进度（1 = 展开）
    float ccProgress_ = 1.0f;
    float ccProgressVel_ = 0.0f;
    bool ccDragging_ = false;
    float ccDragStartProgress_ = 0.0f;
    float ccDragStartY_ = 0.0f;

    // 锁屏：钟表拖动
    float lockOffsetX_ = 0.0f;
    float lockOffsetY_ = 0.0f;
    bool lockDragging_ = false;
    float lockGrabDX_ = 0.0f;
    float lockGrabDY_ = 0.0f;

    // 放大镜：光标位置（GL 坐标）
    float magX_ = 0.0f;
    float magY_ = 0.0f;
    bool magDragging_ = false;
    float magGrabDX_ = 0.0f;
    float magGrabDY_ = 0.0f;
    bool magInited_ = false;

    // 滚动容器：列表位移（px，0 = 顶部）
    float listScroll_ = 0.0f;
    float listScrollVel_ = 0.0f;
    bool listDragging_ = false;
    float listGrabScroll_ = 0.0f;
    float listGrabY_ = 0.0f;

    // 游乐场：玻璃板变换 + 参数
    float pgX_ = 0.0f;
    float pgY_ = 0.0f;
    bool pgInited_ = false;
    bool pgDragging_ = false;
    float pgGrabDX_ = 0.0f;
    float pgGrabDY_ = 0.0f;
    bool pgSheetOpen_ = true;
    int pgSliderDown_ = -1;          // 0..4
    // 五个滑块归一化值：0 圆角 / 1 模糊 / 2 折射高 / 3 折射强 / 4 色散
    float pgSliderValue_[5] = {0.5f, 0.0f, 0.2f, 0.2f, 0.0f};
    float pgSliderGrabValue_[5] = {0.5f, 0.0f, 0.2f, 0.2f, 0.0f};
    float pgSliderGrabX_[5] = {0.0f, 0.0f, 0.0f, 0.0f, 0.0f};
    float pgSliderPress_[5] = {0.0f, 0.0f, 0.0f, 0.0f, 0.0f};
    float pgSliderPressVel_[5] = {0.0f, 0.0f, 0.0f, 0.0f, 0.0f};
    int pgButtonDown_ = -1;          // 0 = 折叠开关，1 = 重置
    float pgButtonPress_[2] = {0.0f, 0.0f};
    float pgButtonPressVel_[2] = {0.0f, 0.0f};

    // 自适应亮度：亮度弹簧 + 采样节流
    float lumValue_ = 0.25f;
    float lumTarget_ = 0.25f;
    float lumVel_ = 0.0f;
    int64_t lumSampleMs_ = 0;
    int lumShown_ = -1;          // 已显示到文字里的百分数（避免每帧重传文字位图）
    int64_t lumTextMs_ = 0;

    /** 各场景一帧内共用的弹簧步进（与参考实现的 spring 同构）。 */
    void UpdateCatalogAnim(float dt);

    /** 触摸分发（各场景自己的命中测试与拖动）。返回 true 表示事件已消费。 */
    bool OnTouchCatalog(int action, float x, float y, int surfaceW, int surfaceH);

    /** 场景切换时的动画/文本重置。 */
    void ResetCatalogState(int scene);
    /** 帧内模糊缓存（采样源 + 半径）。 */
    float blurCacheRadius_ = -1.0f;
    GLuint blurCacheTex_ = 0;
    GLuint blurCacheSrc_ = 0;
    /**
     * 平滑模糊的帧内缓存（嵌入式弹窗：面板玻璃先画进 sceneTex_、再画到屏幕，两次同源同 sigma）。
     * 降采样金字塔被别的模糊复用时失效（RenderBlur 金字塔路径 / 不同键的 RenderBlurSmooth）。
     */
    GLuint smoothCacheSrc_ = 0;
    float smoothCacheSigma_ = -1.0f;
    GLuint smoothCacheTex_ = 0;

    std::thread thread_;
    std::atomic<bool> running_{false};
    std::atomic<bool> stopRequested_{false};
    /** 渲染线程已退出（RenderLoop 出口置位；OnSurfaceDestroyed 带超时等待用）。 */
    std::atomic<bool> threadExited_{false};
    std::atomic<uint64_t> width_{0};
    std::atomic<uint64_t> height_{0};

    // -------------------------------------------------------------------------
    // 帧率节流 + 空闲跳过（功耗）
    //
    // 背景：`eglSwapBuffers` 在 XComponent 的 surface 上**不保证**按 vsync 阻塞
    // （上游实测有跑到 580fps 的机型/窗口状态），所以循环自己限速；而且"没变化就不画"
    // 比限速更省 —— 静止时整条链路（背景 / 模糊 / 玻璃 / 指示器）一次都不跑。
    // -------------------------------------------------------------------------

    /** 上层暂停标志（页面不可见时置位）。 */
    std::atomic<bool> paused_{false};
    /** 有输入/参数/场景/尺寸变化 → 下一帧必须画（消费后清零）。 */
    std::atomic<bool> forceRedraw_{true};
    /** 最近一次触摸 / 内容纹理出新帧的时刻（交互窗口内用高帧率）。 */
    std::atomic<int64_t> lastTouchMs_{0};
    /** 上一帧绘制时刻（帧率节流基准）。 */
    int64_t lastDrawMs_ = 0;
    /** 空闲跳过计数（只用于日志）。 */
    int skippedFrames_ = 0;

    EGLDisplay display_ = EGL_NO_DISPLAY;
    EGLSurface surface_ = EGL_NO_SURFACE;
    EGLContext context_ = EGL_NO_CONTEXT;
    EGLConfig config_ = nullptr;

    GLuint bgFbo_ = 0;
    GLuint bgTex_ = 0;
    GLuint blurFbo_[2] = {0, 0};
    GLuint blurTex_[2] = {0, 0};
    // 顶部按钮的**第二套**模糊链：按钮的模糊半径与底座不同（id 10 + id 1 × id 11），
    // 复用底座那张模糊结果会让按钮内部明显偏"清"。
    GLuint blurFbo2_[2] = {0, 0};
    GLuint blurTex2_[2] = {0, 0};
    // 主模糊链的**降采样金字塔**（第 0/1 级 = 1/2、1/4 分辨率）。
    // 半径大时先降采样再模糊：每级像素少 4×，9-tap 在低分辨率上相对更密，画质更稳。
    // 默认参数（底座 0.2dp / 按钮 4dp）都在阈值以下，走全分辨率旧路径。
    GLuint blurDownFbo_[2][2] = {{0, 0}, {0, 0}};
    GLuint blurDownTex_[2][2] = {{0, 0}, {0, 0}};
    int blurDownW_[2] = {0, 0};
    int blurDownH_[2] = {0, 0};
    /** 全分辨率两趟可分离高斯（按钮链与主链小半径共用）。 */
    GLuint BlurFullRes(GLuint sourceTex, float radiusPx, GLuint fboPair[2], GLuint texPair[2]);
    /** 按钮专用模糊：全分辨率 + scissor（按钮半径通常较小，裁剪比降采样更省）。 */
    GLuint RenderButtonBlur(GLuint sourceTex, float radiusPx);
    /**
     * 主模糊链：小半径全分辨率；大半径走降采样金字塔。返回可直接线性采样的纹理。
     * clip（屏幕 px，GL 坐标）只作用于全分辨率路径：结果只在该矩形内有效（外面是旧内容）。
     */
    GLuint RenderBlur(GLuint sourceTex, float radiusPx, const RectF *clip = nullptr);
    /**
     * 无重影高斯模糊：两级 2×2 盒式降采样到 1/4 分辨率，再迭代小步距可分离 pass 叠到目标 sigma。
     * clip（屏幕 px，GL 坐标）：结果只需在该矩形内有效，每级按比例裁剪（调用方保证矩形已含模糊支撑）。
     */
    GLuint RenderBlurSmooth(GLuint sourceTex, float sigmaPx, const RectF *clip = nullptr);
    GLuint sceneFbo_ = 0;  // 背景 + 底板玻璃（不含文字；指示器要采样它）
    GLuint sceneTex_ = 0;
    GLuint labelTex_ = 0;   // 文字位图（native_drawing 栅格化，整条为**常态色**）
    // 凸显色文字位图：与 labelTex_ **逐像素同布局**，只在指示器内部按同一折射 UV
    // 叠加 —— "透过指示器看到的才是凸显色"（见 kIndicatorShaderBody 的 uLabelsAccent）
    GLuint labelAccentTex_ = 0;
    GLuint iconTex_ = 0;    // 顶部三个按钮的图标（横向排列，native_drawing 栅格化）
    int iconTexSizePx_ = 0; // 当前图标位图的单格边长（px）；尺寸变了要重传
    GLuint photoTex_ = 0;   // 照片背景（裸 RGBA）
    int photoW_ = 0;
    int photoH_ = 0;
    /** 已上传到 photoTex_ 的尺寸：与 photoW_/photoH_ 相同就只做 SubImage（高频快照时省掉重分配）。 */
    int photoTexW_ = 0;
    int photoTexH_ = 0;
    std::vector<unsigned char> photoPixels_;
    std::mutex photoMutex_;
    std::atomic<bool> photoDirty_{false};

    // ---- ArkTS 内容纹理（BuilderNode 纹理导出，见 ContentSurfaceId）----
    GLuint contentTex_ = 0;       // 外纹理（GL_TEXTURE_EXTERNAL_OES）
    GLuint contentBlitTex_ = 0;   // 外纹理每帧拷进来的 2D 纹理
    GLuint contentFbo_ = 0;
    GLuint progExtCopy_ = 0;      // samplerExternalOES + 变换矩阵 -> 2D
    OH_NativeImage *contentImage_ = nullptr;
    float contentMatrix_[16] = {1.0f, 0.0f, 0.0f, 0.0f,
                                0.0f, 1.0f, 0.0f, 0.0f,
                                0.0f, 0.0f, 1.0f, 0.0f,
                                0.0f, 0.0f, 0.0f, 1.0f};
    bool contentValid_ = false;      // 当前 contentBlitTex_ 是不是一张可用的新帧
    std::atomic<bool> contentEverValid_{false};   // 至少收到过一帧（ArkTS 的切换门槛）
    int contentBlitW_ = 0;           // contentBlitTex_ 当前尺寸（= surface 宽 × 条带+余量高）
    int contentBlitH_ = 0;
    bool contentLogged_ = false;
    std::string contentSurfaceId_;
    mutable std::mutex contentMutex_;
    /** true = 背景用 ArkTS 内容纹理（见 SetContentBackdrop）。 */
    std::atomic<bool> contentBackdrop_{false};
    /** 镜像条带余量与采样位移预算（vp，见 SetContentBand）。 */
    std::atomic<float> contentBandExtraTopVp_{0.0f};
    std::atomic<float> contentBandExtraBottomVp_{0.0f};
    std::atomic<float> contentShiftUpLimitVp_{16.0f};
    std::atomic<float> contentShiftDownLimitVp_{16.0f};
    GLuint progBg_ = 0;
    GLuint progBlur_ = 0;
    GLuint progGlass_ = 0;
    GLuint progIndicator_ = 0;
    GLuint progGlow_ = 0;   // 跟手光斑（BlendMode.Plus 的加性 pass）
    GLuint progIcon_ = 0;   // 按钮图标（采样 iconTex_，叠在按钮之上）
    GLuint progSolid_ = 0;  // 目录场景：纯色圆角矩形（轨道 / 填充 / 卡片 / 对话框按钮）
    GLuint progCopy_ = 0;   // 目录场景：背景 -> sceneTex_ 的拷贝
    GLuint progSprite_ = 0; // 目录场景：文字 / 图标位图（预乘 alpha）
    GLuint progProgBlur_ = 0;  // 渐进模糊（模糊 + 着色按纵向渐变淡出）
    int targetW_ = 0;
    int targetH_ = 0;
    int labelW_ = 0;
    int labelH_ = 0;
    static constexpr int kTabCount = 3;   // 页签条固定三格（几何 / 触摸映射都按三格算）
    int selectedTab_ = 0;
    std::atomic<bool> labelsDirty_{false};
    bool UploadLabels(int w, int h);
    bool UploadIcons(int iconSizePx);

    // ---- 调试 ----
    // 注：Milestone 1 时代这里还硬编码过 refractionHeight_ / refractionAmount_ /
    // touch 用的 blurRadius_ / dispersionEnabled_，接上 ArkUI 菜单后全部改走 `params_`，
    // 那几个成员已经没人读，删掉以免和参数表混淆。
    std::atomic<int> debugMode_{0};

    // ---- 指示器动画（S3）----
    //
    // 与参考实现的 DampedDragAnimation 对应：
    //   value        连续页签位置 0..2（弹簧追赶 targetValue：始终有过渡位移动画，不瞬移）
    //   targetValue  拖动目标 = 触摸位置（绝对坐标，不累积偏移）；松手后 value 弹簧对齐最近整数
    //   speed        弹簧平滑后的速度（驱动拉伸/压扁形变）
    //   press        按压进度 0..1（驱动折射/色散/高光/阴影/内阴影增强）
    //   scaleX/Y     按压放大（pressedScale），独立弹簧（id 60..63）
    struct IndicatorAnim {
        float value = 0.0f;
        float valueVelocity = 0.0f;
        float targetValue = 0.0f;
        float speed = 0.0f;
        float speedVelocity = 0.0f;
        float press = 0.0f;
        float pressVelocity = 0.0f;
        float scaleX = 1.0f;
        float scaleXVelocity = 0.0f;
        float scaleY = 1.0f;
        float scaleYVelocity = 0.0f;
        int targetIndex = 0;
        bool dragging = false;
    };
    IndicatorAnim anim_;
    // 本帧内累积的目标（手指）位移（value 单位）。OnTouch 写、UpdateAnim 读并清零。
    // 之所以不用"每事件位移 × 60"：指针事件率不一定是 60Hz（真机实测有 120Hz），
    // 那种近似会让速度（以及形变）随事件率漂移。
    float moveAccum_ = 0.0f;

    // ---- 顶部三个玻璃按钮（对齐参考实现的 GlassIconButton）----
    // 图标自左向右：拖动 / 通知 / 更多；点击分别开出 指示器·拖动 / 指示器·静止 / 底座 菜单。
    static constexpr int kIconButtonCount = 3;
    float btnPress_[kIconButtonCount] = {0.0f, 0.0f, 0.0f};
    float btnPressVelocity_[kIconButtonCount] = {0.0f, 0.0f, 0.0f};
    int btnDownIndex_ = -1;   // 当前按下的按钮下标（-1 = 无），由 OnTouch 写、UpdateAnim 读

    // 跟手光斑（InteractiveHighlight）：按压进度有**独立**弹簧（id 31/32），
    // 与指示器的 press 弹簧（58/59）分开 —— 上游就是这么分的（glowPress* vs press*）。
    float glowPress_ = 0.0f;
    float glowPressVelocity_ = 0.0f;

    /** 按钮边长（px）= id 9。 */
    float ButtonSizePx() const;
    /** 按钮间距（px）= 12dp（参考实现: Arrangement.spacedBy(12.dp)）。 */
    float ButtonSpacingPx() const;
    /** 按钮矩形（GL 坐标：y 从**底部**起算）。index 0 = 最左。 */
    void ButtonRectPx(int index, int surfaceW, int surfaceH, float *left, float *bottom) const;
    /** 命中测试（touchX/touchY 用**屏幕坐标**，y 从顶部起算）。 */
    bool HitButton(float touchX, float touchY, int surfaceW, int surfaceH, int *index) const;

    // 浮动玻璃件（与底板同材质、同尺寸，可用手指上下左右拖）
    std::atomic<float> floatX_{0.0f};
    std::atomic<float> floatY_{0.0f};   // y 从底部起算，与 GL 一致
    bool floatInited_ = false;
    bool draggingFloat_ = false;
    float floatGrabDX_ = 0.0f;
    float floatGrabDY_ = 0.0f;

    // 照片背景的滚动（0 = 顶部，1 = 底部）
    std::atomic<float> scroll_{0.0f};
    // 底板视差（拖动时整条底板位移，松手弹簧回零）
    float parallaxAccum_ = 0.0f;     // 累积拖动位移（px）
    float parallaxVel_ = 0.0f;
    std::atomic<float> panelOffsetPx_{0.0f};

    float scrollGrabStart_ = 0.0f;
    float scrollGrabY_ = 0.0f;
    bool scrolling_ = false;   // 指针事件之间的瞬时速度（由 OnTouch 写、UpdateAnim 读）
    std::mutex animMutex_;
    int64_t lastAnimMs_ = 0;
    int64_t lastAnimNs_ = 0;   // 页签 / 弹窗实例的弹簧步长基准（纳秒，见 RenderLoop）
    void UpdateAnim(float dtSeconds);
    /** 判停时弹簧（页签 + 弹窗）的状态（见 SettleSprings）。 */
    enum class SpringSettle {
        kFar,       // 还有弹簧离目标较远（欠阻尼弹簧折返点的误判）：当它还在动
        kSnapped,   // 都贴着目标，已对齐、速度清零，有值被改动：要再画一帧
        kExact,     // 本来就在目标上
    };
    /**
     * 速率判据判停时调用：页签与弹窗的每根弹簧都贴着目标（kSettle*Tolerance）才对齐目标值、速度清零。
     * 不对齐的话静止画面停在哪一帧取决于帧时序（判停时离目标还差一点）。
     */
    SpringSettle SettleSprings();
    /** 上一轮弹簧是否还在动（落定的那一轮才对齐一次）。 */
    bool wasSpringing_ = false;

    /**
     * 页签格的内缩（px）。**所有"页签格几何"都必须走这里**：触摸映射（TabValueFromX）、
     * 视差累积用的格宽、文字排版、指示器定位 —— 几处各写一份就会各自漂移。
     *
     * 对齐参考实现的 `innerPaddingDp = max(panelInnerPadding, capInset + indicatorExpand)`：
     * 胶囊端头圆弧必须和底板端头圆弧**同心**，所以格子内缩至少要留出
     * 「同心留白 + 外扩量」，否则两端页签的胶囊会探出底板。
     * 默认值下 capInset(4) + expand(10) = 14 = panelInnerPadding，所以默认行为不变。
     */
    float TabInnerPadPx() const;

    /** 两端页签的同心留白（px）= (底板高 - 胶囊高)/2，下限 0（＝ 参考实现的 capInsetPx）。 */
    float IndicatorEndInsetPx() const;

    float TabValueFromX(float x, int surfaceW) const;

    /** 全参数表（编号与 glass_params.cpp 一致） */
    GlassParams params_;

    /** 顶部按钮点击 -> ArkTS 菜单的回链（见 SetMenuRequestFn）。 */
    std::atomic<MenuRequestFn> menuRequestFn_{nullptr};

    // ---- HallPass 集成：页签条叠加模式 + 可配置页签 ----
    std::atomic<bool> overlayMode_{false};   // true = surface 透明，只画页签条
    std::atomic<bool> demoChrome_{true};     // false = 隐藏顶部按钮 / 浮动玻璃件 / 照片滚动
    /** 诊断：叠加模式下每 ~240 帧读回一次屏幕 alpha（标定表层透明是否生效）。只在调试模式跑。 */
    int alphaProbeCounter_ = 0;
    /** 背景快照的平移量（vp，正 = 内容上移 / 左移，见 SetBackdropShift）。 */
    std::atomic<float> backdropShiftX_{0.0f};
    std::atomic<float> backdropShiftY_{0.0f};
    /** 镜像树逻辑偏移 / 出帧时的锁存值（vp，见 SetMirrorOffset）。 */
    std::atomic<float> mirrorOffsetVp_{0.0f};
    std::atomic<float> frameMirrorOffsetVp_{0.0f};
    /**
     * 采样位移（vp）的两个基准：
     * - contentOffsetVp_ = 主树视觉偏移（+ contentLeadVp_ 一帧外推，按时间衰减）；
     * - heldMirrorOffsetVp_ = **手里这帧纹理**的内容偏移（每次成功取到新帧时锁存）。
     * 每帧画之前重算 contentShiftVp_（见 SetContentOffset / UpdateContentShift）。
     */
    std::atomic<float> contentOffsetVp_{0.0f};
    std::atomic<float> contentLeadVp_{0.0f};
    std::atomic<int64_t> contentLeadMs_{0};
    std::atomic<float> heldMirrorOffsetVp_{0.0f};
    std::atomic<float> contentShiftVp_{0.0f};
    /** 累计消费到的内容纹理帧数（诊断）。 */
    std::atomic<int64_t> contentFramesTotal_{0};

    // ---- 渲染节拍：信号唤醒（内容帧 / 位移 / 触摸 / 参数），不再固定 sleep ----
    /** 有"可能改变画面"的事件时置位；WaitFrame 消费它。 */
    std::atomic<bool> frameDirty_{false};
    std::mutex frameWaitMutex_;
    std::condition_variable frameWaitCv_;

    // ---- vsync 对齐出帧（见 WaitForRenderSlot）----
    OH_NativeVSync *vsync_ = nullptr;
    /** 渲染线程：本实例的原生窗口（交 buffer 前设期望上屏时间用，见 RenderLoop）。 */
    void *nativeWindow_ = nullptr;
    /** 最近一次 vsync 的时间戳（CLOCK_MONOTONIC，ns）与周期（ns）；vsync 线程写、渲染线程读。 */
    std::atomic<int64_t> vsyncNs_{0};
    std::atomic<int64_t> vsyncPeriodNs_{0};
    /** 渲染线程：上一帧画在哪个 vsync 周期（= 当时的 vsyncNs_），同一周期不画第二帧。 */
    int64_t lastRenderVsyncNs_ = -1;
    /** 渲染线程：上次查询周期时的 vsync 时间戳（每个新回调查一次）。 */
    int64_t periodQueriedVsyncNs_ = -1;
    bool vsyncClockLogged_ = false;

    struct TabConfig {
        std::vector<std::string> labels;
        std::vector<std::string> icons;
        uint32_t selectedArgb = 0xFF007DFF;
        uint32_t unselectedArgb = 0x00000000;
        bool custom = false;
    };
    TabConfig tabConfig_;
    mutable std::mutex tabConfigMutex_;
    /** 页签切换回链（原生 -> ArkTS，见 SetTabChangeFn）。 */
    std::atomic<TabChangeFn> tabChangeFn_{nullptr};

    // ---- HallPass 内联玻璃控件（开关 / 滑块）----
    /** -1 = 非控件实例（页签 / 目录整屏）；0 / 1 = 开关 / 滑块（见 WidgetKind）。 */
    std::atomic<int> widgetKind_{-1};
    /** 目标状态：开关 0/1，滑块 0..1（手指 / ArkUI 给的值，动画弹簧追随它）。 */
    std::atomic<float> widgetState_{0.0f};
    /** 按压 / 拖动状态（ArkUI 侧上报，驱动按压缩放与玻璃化）。 */
    std::atomic<bool> widgetPressed_{false};
    std::atomic<uint32_t> widgetAccentArgb_{0xFF30D158};   // 主题 primary（默认占位）
    std::atomic<uint32_t> widgetBgArgb_{0xFFFFFFFF};       // 所在卡片底色
    /** 有变化要重画的标记（按需渲染：false 且弹簧静止时渲染线程休眠）。 */
    std::atomic<bool> widgetDirty_{true};
    /** 首帧是否已经画过：没画过时状态直接对齐（避免开关"从关到开"滑进来）。 */
    std::atomic<bool> widgetPrimed_{false};
    /** 休眠等待：RequestRender / stop 都会唤醒。 */
    std::mutex widgetWaitMutex_;
    std::condition_variable widgetWaitCv_;

    // ---- FPS 统计 ----
    /** 各 pass 的 GPU 耗时（GLASS_PERF_PROBE 打开才计，见 perf_probe.h）。 */
    GpuPassTimer gpuTimer_;
    /** 本帧采样位移用到的主树偏移 / 外推量（vp，渲染线程独占；trace 打点用）。 */
    float lastOffsetVp_ = 0.0f;
    float lastLeadVp_ = 0.0f;
    int frameCount_ = 0;
    int64_t fpsWindowStartMs_ = 0;
    /** 本统计窗口内消费到的内容纹理帧数 / 绘制耗时累计（PERF_GL 诊断用）。 */
    int contentFrameCount_ = 0;
    int drawMsTotal_ = 0;
};

}  // namespace glass

#endif  // GLASS_GLES_RENDERER_H
