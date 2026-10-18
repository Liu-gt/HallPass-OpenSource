#include "shared_backdrop.h"

// 回调约定：onFrame / hubWake 都在 mutex_ 持有期间调用，只允许做"置脏 + 唤醒"
// （RequestRedraw），不得回调 SharedBackdrop，否则自锁。

namespace glass {

SharedBackdrop &SharedBackdrop::Get() {
    static SharedBackdrop instance;
    return instance;
}

void SharedBackdrop::AttachHub(EGLDisplay display, EGLContext context) {
    std::lock_guard<std::mutex> lock(mutex_);
    display_ = display;
    hubContext_ = context;
    published_ = -1;
    // 消费者可能先于中枢加入（弹窗在页签玻璃重建期间打开）：中枢一就位就补发
    republish_ = !readers_.empty();
}

void SharedBackdrop::DetachHub() {
    std::lock_guard<std::mutex> lock(mutex_);
    generation_++;
    hubContext_ = EGL_NO_CONTEXT;
    display_ = EGL_NO_DISPLAY;
    published_ = -1;
    for (Slot &slot : slots_) {
        // 栅栏随上下文一起作废；纹理由中枢在自己的 DestroyGl 里删
        slot = Slot{};
    }
}

bool SharedBackdrop::WantFrames() {
    std::lock_guard<std::mutex> lock(mutex_);
    return hubContext_ != EGL_NO_CONTEXT && !readers_.empty();
}

bool SharedBackdrop::TakeRepublishRequest() {
    std::lock_guard<std::mutex> lock(mutex_);
    const bool want = republish_;
    republish_ = false;
    return want;
}

int SharedBackdrop::BeginWrite() {
    std::lock_guard<std::mutex> lock(mutex_);
    if (hubContext_ == EGL_NO_CONTEXT) {
        return -1;
    }
    const int slot = (published_ == 0) ? 1 : 0;
    Slot &s = slots_[slot];
    if (s.inUse > 0) {
        return -1;
    }
    if (s.readFence != nullptr) {
        glWaitSync(s.readFence, 0, GL_TIMEOUT_IGNORED);
        glDeleteSync(s.readFence);
        s.readFence = nullptr;
    }
    if (s.writeFence != nullptr) {
        glDeleteSync(s.writeFence);
        s.writeFence = nullptr;
    }
    return slot;
}

void SharedBackdrop::EndWrite(int slot, GLuint tex, int width, int height, float mirrorOffsetVp) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (slot < 0 || slot > 1 || hubContext_ == EGL_NO_CONTEXT) {
        return;
    }
    Slot &s = slots_[slot];
    s.tex = tex;
    s.width = width;
    s.height = height;
    s.mirrorOffsetVp = mirrorOffsetVp;
    s.writeFence = glFenceSync(GL_SYNC_GPU_COMMANDS_COMPLETE, 0);
    // 栅栏要让别的上下文看得见：命令必须先提交出去
    glFlush();
    published_ = slot;
    seq_++;
    // 持锁回调：RemoveReader 之后不会再有回调打进已销毁的消费者（回调只做唤醒，不回调本类）
    for (const Reader &r : readers_) {
        if (r.onFrame) {
            r.onFrame();
        }
    }
}

void SharedBackdrop::NotifyReaders() {
    std::lock_guard<std::mutex> lock(mutex_);
    for (const Reader &r : readers_) {
        if (r.onFrame) {
            r.onFrame();
        }
    }
}

void SharedBackdrop::SetHubWake(std::function<void()> wake) {
    std::lock_guard<std::mutex> lock(mutex_);
    hubWake_ = std::move(wake);
}

EGLContext SharedBackdrop::HubContext(EGLDisplay *display, uint64_t *generation) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (display != nullptr) {
        *display = display_;
    }
    if (generation != nullptr) {
        *generation = generation_;
    }
    return hubContext_;
}

uint64_t SharedBackdrop::Generation() {
    std::lock_guard<std::mutex> lock(mutex_);
    return generation_;
}

int SharedBackdrop::AddReader(std::function<void()> onFrame) {
    std::lock_guard<std::mutex> lock(mutex_);
    const int token = nextToken_++;
    readers_.push_back(Reader{token, std::move(onFrame)});
    // 弹窗底下的页面通常静止，镜像不会再出新帧：让中枢用最后一帧补发
    republish_ = true;
    if (hubWake_) {
        hubWake_();
    }
    return token;
}

void SharedBackdrop::RemoveReader(int token) {
    std::lock_guard<std::mutex> lock(mutex_);
    for (auto it = readers_.begin(); it != readers_.end(); ++it) {
        if (it->token == token) {
            readers_.erase(it);
            break;
        }
    }
}

bool SharedBackdrop::Acquire(uint64_t generation, Frame *out) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (generation != generation_ || hubContext_ == EGL_NO_CONTEXT || published_ < 0) {
        return false;
    }
    Slot &s = slots_[published_];
    if (s.tex == 0 || s.width <= 0 || s.height <= 0) {
        return false;
    }
    if (s.writeFence != nullptr) {
        glWaitSync(s.writeFence, 0, GL_TIMEOUT_IGNORED);
    }
    s.inUse++;
    out->tex = s.tex;
    out->width = s.width;
    out->height = s.height;
    out->slot = published_;
    out->seq = seq_;
    out->generation = generation_;
    out->mirrorOffsetVp = s.mirrorOffsetVp;
    return true;
}

void SharedBackdrop::Release(const Frame &frame) {
    GLsync fence = glFenceSync(GL_SYNC_GPU_COMMANDS_COMPLETE, 0);
    glFlush();
    std::lock_guard<std::mutex> lock(mutex_);
    if (frame.generation != generation_ || frame.slot < 0 || frame.slot > 1) {
        glDeleteSync(fence);
        return;
    }
    Slot &s = slots_[frame.slot];
    if (s.inUse > 0) {
        s.inUse--;
    }
    if (s.readFence != nullptr) {
        glDeleteSync(s.readFence);
    }
    s.readFence = fence;
}

}  // namespace glass
