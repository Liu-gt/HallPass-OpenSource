#include "perf_probe.h"

#if GLASS_PERF_PROBE

#include <chrono>

namespace glass {

namespace {

double NowUs() {
    using namespace std::chrono;
    return static_cast<double>(
        duration_cast<microseconds>(steady_clock::now().time_since_epoch()).count());
}

}  // namespace

// 串行计时：pass 前后各一次 glFinish，取两次之间的墙钟时间（= 该 pass 的 CPU 录制 + GPU 执行）。
// 分块渲染（TBDR）的 GPU 上 TIME_ELAPSED 查询只覆盖分箱阶段、片元阶段在 render pass 解析时才执行，
// 实测每帧只有 ~20µs，不可用；glFinish 强制该 pass 执行完，代价是打断 CPU/GPU 流水 ——
// 所以只在测量包里用（延迟 / 帧节奏用不带探针的包另测）。
void GpuPassTimer::Init() {
    supported_ = true;
}

void GpuPassTimer::Destroy() {
    supported_ = false;
    active_ = -1;
}

void GpuPassTimer::BeginFrame() {
    anyIssued_ = false;
}

void GpuPassTimer::Begin(int pass) {
    if (!supported_ || active_ >= 0 || pass < 0 || pass >= kGpuPassCount) {
        return;
    }
    glFinish();
    beginUs_ = NowUs();
    active_ = pass;
}

void GpuPassTimer::End() {
    if (!supported_ || active_ < 0) {
        return;
    }
    glFinish();
    totalsUs_[active_] += NowUs() - beginUs_;
    anyIssued_ = true;
    active_ = -1;
}

void GpuPassTimer::EndFrame() {
    if (anyIssued_) {
        samples_++;
    }
}

int GpuPassTimer::TakeTotals(double totalsMs[kGpuPassCount]) {
    const int samples = samples_;
    for (int p = 0; p < kGpuPassCount; p++) {
        totalsMs[p] = totalsUs_[p] / 1000.0;
        totalsUs_[p] = 0.0;
    }
    samples_ = 0;
    return samples;
}

}  // namespace glass

#endif  // GLASS_PERF_PROBE
