#ifndef GLASS_SHARED_BACKDROP_H
#define GLASS_SHARED_BACKDROP_H

#include <EGL/egl.h>
#include <GLES3/gl3.h>

#include <cstdint>
#include <functional>
#include <mutex>
#include <vector>

namespace glass {

/**
 * 共享实时背景（HallPass）：页签渲染器（中枢）独占镜像树的 OH_NativeImage，
 * 有整屏消费者（弹窗 / 以后的悬浮玻璃按钮）时，把每帧内容另 blit 进两张共享纹理（乒乓）发布出来；
 * 消费者渲染器在**同一 share group** 里建 EGL 上下文，直接采样，不再截快照。
 *
 * 同步（GL sync 对象在 share group 内共享）：
 *   - 中枢写完一张发布 writeFence；消费者采样前在持锁状态下 glWaitSync（服务端等待，不阻塞 CPU）。
 *   - 消费者采样后交回 readFence；中枢下次覆盖这张前先 glWaitSync 它。
 *   - 消费者 Acquire 到 Release 之间该槽"在用"，中枢跳过不写（下一帧再说），不会覆盖正在读的纹理。
 *
 * 纹理名由中枢创建 / 删除；中枢销毁时先 DetachHub（代际 +1），消费者发现代际不符即停用、回退快照。
 */
class SharedBackdrop {
public:
    static SharedBackdrop &Get();

    struct Frame {
        GLuint tex = 0;
        int width = 0;    // px
        int height = 0;   // px（纹理行 0 = 内容底边，GL 约定）
        int slot = -1;
        uint64_t seq = 0;
        uint64_t generation = 0;
        /** 这帧纹理里装的镜像滚动偏移（vp）：消费者据此做与页签同款的滞后补偿。 */
        float mirrorOffsetVp = 0.0f;
    };

    // ---- 中枢（页签渲染线程）----
    void AttachHub(EGLDisplay display, EGLContext context);
    /** 中枢 GL 销毁前调用：撤销发布、代际 +1，返回仍归中枢删除的纹理名（调用方负责 glDelete）。 */
    void DetachHub();
    /** 有消费者在等帧（中枢据此决定要不要额外做整屏 blit）。 */
    bool WantFrames();
    /** 消费者刚加入、还没拿到过帧：中枢应当用手里的最后一帧补发一次。 */
    bool TakeRepublishRequest();
    /**
     * 开始写一帧：返回可写槽（-1 = 两张都不可写，跳过本帧）。若该槽有消费者的 readFence，
     * 已在持锁时让当前上下文 glWaitSync 并删除。
     */
    int BeginWrite();
    /** 写完：登记纹理 / 尺寸，插 writeFence 并发布；唤醒所有消费者。 */
    void EndWrite(int slot, GLuint tex, int width, int height, float mirrorOffsetVp);
    /** 主树滚动偏移更新（没有新帧也要按新偏移重画补偿位移）：唤醒所有消费者。 */
    void NotifyReaders();
    void SetHubWake(std::function<void()> wake);

    // ---- 消费者（各自渲染线程）----
    /** 中枢的上下文（建共享上下文用）；无中枢返回 EGL_NO_CONTEXT。 */
    EGLContext HubContext(EGLDisplay *display, uint64_t *generation);
    uint64_t Generation();
    /** 登记消费者（onFrame 在中枢线程回调，只应做唤醒）；返回令牌。 */
    int AddReader(std::function<void()> onFrame);
    void RemoveReader(int token);
    /**
     * 取最新发布的帧（generation 不符 / 无帧返回 false）。成功时已在持锁状态下 glWaitSync 写栅栏，
     * 并把槽标记为在用 —— 用完必须 Release。
     */
    bool Acquire(uint64_t generation, Frame *out);
    /** 采样命令已提交：插 readFence 交给中枢，解除在用。 */
    void Release(const Frame &frame);

private:
    struct Slot {
        GLuint tex = 0;
        int width = 0;
        int height = 0;
        GLsync writeFence = nullptr;
        GLsync readFence = nullptr;
        int inUse = 0;
        float mirrorOffsetVp = 0.0f;
    };

    std::mutex mutex_;
    EGLDisplay display_ = EGL_NO_DISPLAY;
    EGLContext hubContext_ = EGL_NO_CONTEXT;
    uint64_t generation_ = 1;
    Slot slots_[2];
    int published_ = -1;
    uint64_t seq_ = 0;
    bool republish_ = false;
    int nextToken_ = 1;
    struct Reader {
        int token;
        std::function<void()> onFrame;
    };
    std::vector<Reader> readers_;
    std::function<void()> hubWake_;
};

}  // namespace glass

#endif  // GLASS_SHARED_BACKDROP_H
