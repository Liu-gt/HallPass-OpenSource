#ifndef GLASS_PERF_PROBE_H
#define GLASS_PERF_PROBE_H

#include <EGL/egl.h>
#include <GLES3/gl3.h>
#include <hitrace/trace.h>

#include <cstdint>

// GPU 计时编译开关：CMake 传 -DGLASS_PERF_PROBE=ON 才编进去（见 CMakeLists.txt），正式包不带。
#ifndef GLASS_PERF_PROBE
#define GLASS_PERF_PROBE 0
#endif

namespace glass {

/**
 * 性能探针（HallPass）。
 *
 * - hitrace 打点（app 标签）常驻：没在抓 trace 时只有一次 `OH_HiTrace_IsTraceEnabled()`，
 *   抓 trace 时才格式化参数。`hitrace --trace_begin app graphic ace` 即可看到 GL 线程的
 *   帧 / 等待 / 交换，以及 UI 线程推偏移、出帧回调锁存的时刻（对齐误差分析用）。
 * - GPU 计时（pass 前后 glFinish 串行计时）只在 GLASS_PERF_PROBE 打开时编译：
 *   每秒随 PERF_GL 打印各 pass 的耗时。
 */
inline bool TraceEnabled() { return OH_HiTrace_IsTraceEnabled(); }

class TraceScope {
public:
    explicit TraceScope(const char *name) : on_(TraceEnabled()) {
        if (on_) {
            OH_HiTrace_StartTraceEx(HITRACE_LEVEL_INFO, name, "");
        }
    }
    ~TraceScope() {
        if (on_) {
            OH_HiTrace_FinishTraceEx(HITRACE_LEVEL_INFO);
        }
    }
    TraceScope(const TraceScope &) = delete;
    TraceScope &operator=(const TraceScope &) = delete;

private:
    bool on_;
};

inline void TraceCount(const char *name, int64_t value) {
    if (TraceEnabled()) {
        OH_HiTrace_CountTraceEx(HITRACE_LEVEL_INFO, name, value);
    }
}

/** GPU 计时的 pass 编号（PERF_GL 的 gpu=[...] 按这个顺序打印）。 */
enum GpuPass : int {
    kGpuContentBlit = 0,   // 外纹理 -> 2D（镜像条带）
    kGpuPublish,           // 外纹理 -> 共享槽（整屏消费者）
    kGpuBackground,        // 背景 pass
    kGpuBlur,              // 模糊链（含按钮模糊）
    kGpuPanel,             // 底板玻璃 + 光斑 -> sceneTex_
    kGpuMip,               // sceneTex_ mip 链
    kGpuIndicator,         // 指示器写屏
    kGpuOther,             // 目录 / 弹窗场景的其余绘制
    kGpuPassCount
};

#if GLASS_PERF_PROBE
/**
 * 按 pass 的 GPU 耗时（串行计时：pass 前后各 glFinish，见 perf_probe.cpp 的说明）。
 * 只能在渲染线程、当前上下文有效时调用；会打断流水，只用于测量包。
 */
class GpuPassTimer {
public:
    void Init();
    void Destroy();
    /** 每轮循环开头。 */
    void BeginFrame();
    void Begin(int pass);
    void End();
    /** 每轮循环结尾：这一轮计过 pass 就算一个样本。 */
    void EndFrame();
    /** 取走统计窗口内各 pass 的累计毫秒数与样本轮数，并清零。 */
    int TakeTotals(double totalsMs[kGpuPassCount]);
    bool Supported() const { return supported_; }

private:
    bool supported_ = false;
    bool anyIssued_ = false;
    int active_ = -1;
    double beginUs_ = 0.0;
    double totalsUs_[kGpuPassCount] = {};
    int samples_ = 0;
};
#else
class GpuPassTimer {
public:
    void Init() {}
    void Destroy() {}
    void BeginFrame() {}
    void Begin(int) {}
    void End() {}
    void EndFrame() {}
    int TakeTotals(double *) { return 0; }
    bool Supported() const { return false; }
};
#endif

/** RAII：在作用域内计一个 pass 的 GPU 时间。 */
class GpuPassScope {
public:
    GpuPassScope(GpuPassTimer &timer, int pass) : timer_(timer) { timer_.Begin(pass); }
    ~GpuPassScope() { timer_.End(); }
    GpuPassScope(const GpuPassScope &) = delete;
    GpuPassScope &operator=(const GpuPassScope &) = delete;

private:
    GpuPassTimer &timer_;
};

}  // namespace glass

#endif  // GLASS_PERF_PROBE_H
