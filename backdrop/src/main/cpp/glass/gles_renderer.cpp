#include "gles_renderer.h"

#include <GLES2/gl2ext.h>   // GL_TEXTURE_EXTERNAL_OES（OH_NativeImage 的外纹理）
#include <hilog/log.h>
#include <native_window/external_window.h>

#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <string>
#include <unordered_set>
#include <vector>

#include "glass_params.h"
#include "text_layer.h"

#undef LOG_TAG
#undef LOG_DOMAIN
#define LOG_TAG "GLASS"
#define LOG_DOMAIN 0x0000

#define GLOG(...) OH_LOG_Print(LOG_APP, LOG_INFO, LOG_DOMAIN, LOG_TAG, __VA_ARGS__)
#define GERR(...) OH_LOG_Print(LOG_APP, LOG_ERROR, LOG_DOMAIN, LOG_TAG, __VA_ARGS__)

namespace glass {

namespace {

/**
 * `OH_NativeImage` 帧可用回调：context = GlesRenderer*（见 CreateContentImage）。
 *
 * 不注册的话，ArkUI 每产一帧，消费端都会打一条
 * `SurfaceImage::OnBufferAvailable listener is nullptr` 的错误日志（约 30 条/秒）。
 * 帧的获取仍走渲染线程每帧的 `OH_NativeImage_UpdateSurfaceImage`；回调里只锁存
 * "这一帧装的是哪个滚动位置"并叫醒渲染线程（文档要求回调里不碰 OH_NativeImage
 * 的其它接口，锁存 + notify 是纯内存操作，安全）。
 */
void OnContentFrameAvailable(void *context) {
    if (context != nullptr) {
        static_cast<GlesRenderer *>(context)->HandleContentFrameAvailable();
    }
}

// ---------------------------------------------------------------------------
// 底板与指示器**共用**的 GLSL 前导与 SDF/透镜 helper。
// 两个 shader 都从这里拼装，避免"两套实现"漂移 —— 与上游 SkSL 用
// `$RoundedRectSDF` 模板变量拼字符串是同一个做法。
// ---------------------------------------------------------------------------
constexpr char kGlslPrelude[] = R"(#version 300 es
precision highp float;
in vec2 vUv;
)";

// 底板与指示器**共用**的 SDF / 透镜 helper。
// 两个 shader 都从这里拼装，避免"两套实现"漂移 —— 与上游 SkSL 用
// `$RoundedRectSDF` 模板变量拼字符串是同一个做法。
constexpr char kGlslSdfHelpers[] = R"(
// G2 连续曲率圆角（精确回旋线 / Clothoid 二阶连续过渡，对齐 iOS .continuous 圆角曲线）：
// 在 [-w, +w] 过渡肩区内，令距离平方项 g2CornerSq(x, w) 的二阶导数（即曲率 κ）
// 从直边的 0 严格线性爬升至圆弧的 2（无任何曲率过冲或拐点）：
//   x <= -w：g2CornerSq = 0 -> 直边处曲率恒为 0，100% 平直不鼓肚；
//   -w < x < +w：g2CornerSq = (x + w)^3 / (6w) -> 一阶、二阶导数在 -w 与 +w 两端均严格连续（G2）；
//   x >= +w（45° 圆角主弧区）：g2CornerSq = x^2 + w^2/3 -> 与标准圆弧严格同心，匹配内嵌胶囊按钮。
float g2CornerSq(float x, float w) {
    if (w <= 1e-4) {
        float m = max(x, 0.0);
        return m * m;
    }
    if (x <= -w) {
        return 0.0;
    }
    if (x < w) {
        float u = x + w;
        return (u * u * u) / (6.0 * w);
    }
    return x * x + (w * w) / 3.0;
}

float sdRoundedRectG2(vec2 coord, vec2 halfSize, float radius, float g2Factor) {
    float minHalf = min(halfSize.x, halfSize.y);
    float r = clamp(radius, 0.0, minHalf);
    vec2 cornerCoord = abs(coord) - (halfSize - vec2(r));
    // 存在直边余量时（r < minHalf，如 Dialog 面板）启用 G2 连续曲率过渡半宽 w；
    // 胶囊或正圆（r == minHalf）无直边余量，w = 0 自动保持标准半圆端头。
    float w = clamp(min(r * clamp(g2Factor, 0.0, 0.65), (minHalf - r) * 0.85), 0.0, r * 0.65);
    float d2 = g2CornerSq(cornerCoord.x, w) + g2CornerSq(cornerCoord.y, w);
    float rEff = sqrt(r * r + (w * w) / 3.0);
    float outside = sqrt(d2) - rEff;
    float inside = min(max(cornerCoord.x, cornerCoord.y), 0.0);
    return outside + inside;
}

float sdRoundedRect(vec2 coord, vec2 halfSize, float radius) {
    return sdRoundedRectG2(coord, halfSize, radius, 0.45);
}

// 距离场梯度（= 表面外法线）。**用中央差分而不是上游的解析分支式**：
// 解析式在形状中轴 / 内矩形处会 `normalize(vec2(0))` 突变，直接拿来做棱边高光
// 会出现硬边楔形（之前是靠"边缘衰减遮罩"硬压掉的，那是权宜之计）。
// 差分版本处处平滑，高光就能用上游的原始公式而不需要遮罩。
vec2 gradSdRoundedRectG2(vec2 coord, vec2 halfSize, float radius, float g2Factor) {
    float e = 1.0;
    float dx = sdRoundedRectG2(coord + vec2(e, 0.0), halfSize, radius, g2Factor)
             - sdRoundedRectG2(coord - vec2(e, 0.0), halfSize, radius, g2Factor);
    float dy = sdRoundedRectG2(coord + vec2(0.0, e), halfSize, radius, g2Factor)
             - sdRoundedRectG2(coord - vec2(0.0, e), halfSize, radius, g2Factor);
    vec2 g = vec2(dx, dy);
    float len = length(g);
    return len > 1e-4 ? g / len : vec2(0.0);
}

vec2 gradSdRoundedRect(vec2 coord, vec2 halfSize, float radius) {
    return gradSdRoundedRectG2(coord, halfSize, radius, 0.45);
}

// 透镜位移量曲线：0（折射带内缘）-> 1（形状最外缘）
float circleMap(float x) {
    return 1.0 - sqrt(1.0 - x * x);
}

// 四角独立半径（对齐上游 Shaders.kt 的 radiusAt）。
// ⚠️ 上游是在 **y 向下的 Skia 坐标** 里写的，这里换成 GL 的 y 向上，
// 所以分量顺序是：x=左上，y=右上，z=右下，w=左下。
float radiusAt(vec2 coord, vec4 radii) {
    if (coord.y >= 0.0) {
        return coord.x >= 0.0 ? radii.y : radii.x;
    }
    return coord.x >= 0.0 ? radii.z : radii.w;
}

// colorControls（对齐上游 effects/ColorFilter.kt）：亮度（-1..1）、对比度（0..2）、饱和度（0..2）。
// 上游用 4x4 颜色矩阵（偏移按 0..255 归一化）；这里按同一公式逐像素算，单位换算到 0..1。
vec3 colorControls(vec3 c, float brightness, float contrast, float saturation) {
    float invSat = 1.0 - saturation;
    float r = 0.213 * invSat;
    float g = 0.715 * invSat;
    float b = 0.072 * invSat;
    float cr = contrast * r;
    float cg = contrast * g;
    float cb = contrast * b;
    float cs = contrast * saturation;
    float t = 0.5 - contrast * 0.5 + brightness;
    return vec3(
        dot(c, vec3(cr + cs, cg, cb)) + t,
        dot(c, vec3(cr, cg + cs, cb)) + t,
        dot(c, vec3(cr, cg, cb + cs)) + t
    );
}
)";

// ---------------------------------------------------------------------------
// 顶点着色器：全屏三角形，不需要 VBO
// ---------------------------------------------------------------------------
constexpr char kVertexShader[] = R"(#version 300 es
out vec2 vUv;
void main() {
    vec2 p = vec2(float((gl_VertexID << 1) & 2), float(gl_VertexID & 2));
    // ⚠️ Y 轴约定（真机用四角标记色块标定）：GL 呈现后 vUv.y = 0 落在**物理屏幕底部**。
    //    所以"左上为原点"的布局参数要用 uResolution.y - y 换算（见背景 shader）。
    vUv = p;
    gl_Position = vec4(p * 2.0 - 1.0, 0.0, 1.0);
}
)";

// ---------------------------------------------------------------------------
// pass 1：背景。静态照片（cover 铺满 + 纵向滚动，对齐参考实现的 PhotoBackground）。
// ---------------------------------------------------------------------------
constexpr char kBackgroundShader[] = R"(#version 300 es
precision highp float;
in vec2 vUv;
uniform vec2 uResolution;
uniform sampler2D uPhoto;
uniform vec2 uPhotoSize;
uniform float uScrollRange;   // 参数 id 64
uniform float uScroll;        // 0..1
uniform vec2 uBackdropShift;  // 背景平移（px，正 = 内容上移 / 左移；HallPass 滚动跟手用）
uniform float uContentMode;   // 1 = uPhoto 已是 ArkTS 内容（条带镜像纹理）
uniform float uBandBottom;    // 内容纹理里"条带下沿"的行号（px，= 镜像下余量，见 SetContentBand）
uniform float uBandHeight;    // 内容纹理总高（px，= 条带高 + 上下余量）
uniform float uPhotoMapped;   // 1 = 按 uPhotoRect 摆放快照（HallPass 弹窗），不做 cover 居中
uniform vec4 uPhotoRect;      // 快照在 surface 里的矩形（px，左上原点）：xy = 左上角，zw = 尺寸
uniform float uPhotoFlipY;    // 1 = 纹理行 0 在底边（FBO 渲染出的共享实时纹理），0 = 行 0 在顶边（像素上传）
out vec4 outColor;

void main() {
    // ArkTS 内容纹理：blit 阶段已按屏幕方向摆正（vUv.y = 0 在物理屏幕底部）。
    // 纹理比 GL 的条带 surface 高（上下余量，见 SetContentBand）：先把 surface 的行号
    // 映射进纹理（+ uBandBottom），再叠采样位移 —— uBackdropShift（px，正 = 内容上移）
    // 表示采样点要往屏幕更下方走，纹理行号随之减小（vUv.y = 0 在底部，故取负）。
    // 位移由渲染线程每帧按"手里这帧纹理"重算（见 SetContentOffset），与纹理同帧变化。
    if (uContentMode > 0.5) {
        float row = vUv.y * uResolution.y + uBandBottom - uBackdropShift.y;
        outColor = vec4(texture(uPhoto, vec2(vUv.x, row / max(uBandHeight, 1.0))).rgb, 1.0);
        return;
    }

    // 照片还没上传时先铺一层深色，避免采样未初始化的纹理
    if (uPhotoSize.x < 1.0 || uPhotoSize.y < 1.0) {
        outColor = vec4(0.055, 0.060, 0.075, 1.0);
        return;
    }

    // Y 约定：vUv.y = 0 在物理屏幕底部。下面所有坐标按"左上为原点"书写，统一用 h - y。
    float h = uResolution.y;
    vec2 p = vec2(vUv.x * uResolution.x, h - vUv.y * h) + uBackdropShift;

    // 弹窗快照：页面快照（含状态栏 / 导航条区域）与 XComponent 尺寸不同，cover 居中会让
    // 背景整体错位半个系统栏高；按 ArkTS 量出的真实矩形 1:1 摆放（快照可降采样）。
    if (uPhotoMapped > 0.5) {
        vec2 uvm = (p - uPhotoRect.xy) / max(uPhotoRect.zw, vec2(1.0));
        uvm.y = mix(uvm.y, 1.0 - uvm.y, uPhotoFlipY);
        outColor = vec4(texture(uPhoto, uvm).rgb, 1.0);
        return;
    }

    // ---- 照片背景：cover 铺满 + 纵向滚动 ----
    float contentH = h * max(uScrollRange, 1.0);
    float s = max(uResolution.x / uPhotoSize.x, contentH / uPhotoSize.y);
    vec2 drawn = uPhotoSize * s;
    float maxScroll = max(0.0, contentH - h);
    vec2 origin = vec2((uResolution.x - drawn.x) * 0.5, (contentH - drawn.y) * 0.5);
    vec2 uv = (vec2(p.x, p.y + uScroll * maxScroll) - origin) / drawn;
    outColor = vec4(texture(uPhoto, uv).rgb, 1.0);
}
)";

// ---------------------------------------------------------------------------
// ArkTS 内容纹理：OH_NativeImage 的外纹理 -> 2D（每帧一次全屏 blit）。
//
// 外纹理只能当"采样源"，不能进模糊链 / CopyBackgroundToScene（那两处只认 sampler2D），
// 所以先按 OH_NativeImage 给的变换矩阵（含生产端的翻转）拷成 2D，后续全走原管线。
// ---------------------------------------------------------------------------
constexpr char kExternalCopyShader[] = R"(#version 300 es
#extension GL_OES_EGL_image_external_essl3 : require
precision highp float;
in vec2 vUv;
uniform samplerExternalOES uExternal;
uniform mat4 uTexMatrix;
// 只取外纹理底部这一段（0..1，1 = 整幅）：镜像为整屏消费者放开到整页时，页签仍只要底部条带
uniform float uSrcScaleY;
out vec4 outColor;

void main() {
    // 直接按 GL 约定采外纹理得到的是上下颠倒的（生产端 buffer 是 top-down），
    // 而 OH_NativeImage 的变换矩阵正好带一次翻转（实测 m5 = -1），乘上去即正立。
    vec2 uv = (uTexMatrix * vec4(vUv.x, vUv.y * uSrcScaleY, 0.0, 1.0)).xy;
    outColor = vec4(texture(uExternal, uv).rgb, 1.0);
}
)";

// ---------------------------------------------------------------------------
// pass 2/3：可分离高斯模糊（9 tap）
// ---------------------------------------------------------------------------
constexpr char kBlurShader[] = R"(#version 300 es
precision highp float;
in vec2 vUv;
uniform sampler2D uSource;
uniform vec2 uTexel;
uniform vec2 uDir;
uniform float uRadius;
out vec4 outColor;

void main() {
    vec2 step1 = uDir * uTexel * uRadius;
    vec3 sum = texture(uSource, vUv).rgb * 0.2270270270;
    sum += texture(uSource, vUv + step1 * 1.0).rgb * 0.1945945946;
    sum += texture(uSource, vUv - step1 * 1.0).rgb * 0.1945945946;
    sum += texture(uSource, vUv + step1 * 2.0).rgb * 0.1216216216;
    sum += texture(uSource, vUv - step1 * 2.0).rgb * 0.1216216216;
    sum += texture(uSource, vUv + step1 * 3.0).rgb * 0.0540540541;
    sum += texture(uSource, vUv - step1 * 3.0).rgb * 0.0540540541;
    sum += texture(uSource, vUv + step1 * 4.0).rgb * 0.0162162162;
    sum += texture(uSource, vUv - step1 * 4.0).rgb * 0.0162162162;
    outColor = vec4(sum, 1.0);
}
)";

// ---------------------------------------------------------------------------
// pass 4：底板。背景 + 玻璃(折射/色散/模糊/提饱和/棱边高光/阴影)
// （页签场景的文字不在这里画：由 pass 5 叠加，见 kIndicatorShaderBody）
// 折射/色散主体逐行移植自 upstream Shaders.kt 的
// RoundedRectRefractionWithDispersionShaderString。
// ---------------------------------------------------------------------------
constexpr char kGlassShaderBody[] = R"(
uniform sampler2D uBackdrop;     // 清晰背景
uniform sampler2D uBlurred;      // 模糊后的背景
uniform vec2 uResolution;
uniform vec2 uTexel;
uniform vec4 uGlassRect;         // xy = 左上角（屏幕坐标，y 从底部起算），zw = 尺寸
uniform vec4 uRadii;             // 四角半径（左上/右上/右下/左下，px）；四值相等即普通圆角矩形
uniform float uScaleX;           // 形状缩放（绕中心；非 1 时做按压/速度形变）
uniform float uScaleY;
uniform float uRefractionHeight;
uniform float uRefractionAmount;
uniform float uDispersion;       // 0/1
uniform float uDepthEffect;      // 0/1：折射方向叠加径向分量（上游 lens 的 depthEffect）
uniform float uSurfaceAlpha;
uniform vec3 uSurfaceColor;      // 表面填充色（默认白；tinted 按钮传 tint）
uniform float uBlurRadius;
uniform float uVibrancy;
// 采样变换（放大镜）：samplePx = uSamplePivot + (px - uSamplePivot) / uSampleScale
uniform vec2 uSampleScale;
uniform vec2 uSamplePivot;
uniform float uBrightness;       // colorControls：亮度（-1..1，0 = 原样）
uniform float uContrast;         // colorControls：对比度（0..2，1 = 原样）
uniform float uSaturation;       // colorControls：饱和度（0..2，1 = 原样）
uniform float uEffectOpacity;    // 效果不透明度（0..1，1 = 原样）
uniform float uHighlight;
uniform float uPlainHighlight;   // 0/1：纯色高光（上游 Highlight.Plain）替代描边环
uniform float uHighlightWidth;   // 环宽（px）
uniform float uHighlightBlur;    // 环外缘柔化（px）
uniform float uAmbient;          // 0/1 环境光
uniform float uAmbientIntensity; // 环境光强度（上游 Ambient.intensity 默认 0.38）
uniform float uShadow;
uniform float uInnerRadius;      // 内阴影半径（px）＝ InnerShadow.radius（底座/浮动件恒 0）
uniform float uInnerAlpha;       // 内阴影强度（已含颜色黑 alpha 0.15）
// 内阴影的"顶部掩码"（0 = 关，沿内缘均匀一圈；1 = 开，见 uInnerTopCut）。
// HallPass：玻璃壳的**上边框在壳内落影**——参考图里透过玻璃能看到顶部内缘一道细影，
// 而外投影只画在形状外、无法进到玻璃里，只能靠内阴影做（见玻璃体 shader 的内阴影段）。
uniform float uInnerTopBias;
// 顶部掩码的截止比例（0..1，按高度从顶往下量）：0.75 = 顶部往下 75% 高度以内有内阴影，
// 以下没有（边界按 8% 高度软过渡）。仅 uInnerTopBias > 0 时参与。
uniform float uInnerTopCut;
// 内阴影"实心度"（0 = 原行为：从边缘往里一路柔化；1 = 前 55% 半径实心、后段柔化）。
// 用于做"贴着轮廓一圈的壳沿"——柔化太开时看着像一片渐变，不像贴着边的圆环。
uniform float uInnerSharp;
// 内阴影的"纵向收细"：顶部半径的倍率为 1，降到 uInnerTopCut 处收到 uInnerTaper 倍
// （1 = 不收细，与原来一致）。用于"越靠上影越厚、越往下越薄"的壳沿。
uniform float uInnerTaper;
uniform float uShadowBlur;       // 投影模糊半径（px）＝上游 Shadow.radius
uniform float uShadowOffset;     // 向下偏移（px）＝radius/6
uniform float uShadowAlpha;      // 有效不透明度（uShadowSpreadV>0 时是"底部最大"值）
// 外投影纵向渐变（HallPass）：0 = 均匀一圈（原行为）；>0 = 从中线（50% 高度）往下，
// 模糊与强度线性增长到 uShadowBlur / uShadowAlpha（中线以上不投影）—— 与内阴影的
// "上厚下薄"反着来，做出玻璃件下方越远越散的自然落影。
uniform float uShadowSpreadV;
uniform sampler2D uLabels;       // 文字位图（覆盖整个底板矩形）
uniform vec2 uLabelSize;
uniform float uShowLabels;       // 0/1（页签场景改用 pass 5 的文字叠加后，这里恒 0）
// 选中胶囊（HallPass 深色模式静态纯黑底）：几何与指示器同一套（见 DrawTabsScene 的几何块）
uniform vec4 uIndicatorRect;     // 胶囊矩形（含按压缩放），与 uGlassRect 同一坐标系
uniform vec2 uIndicatorShape;    // 胶囊按压形状缩放（x = id 82 / y = id 51）
uniform vec2 uIndicatorScale;    // 胶囊速度形变（非等比坐标缩放）
uniform float uIndicatorFill;    // 胶囊底色不透明度（0 = 不画）
// 0 = 直接写屏（底板：形状外画清晰背景 + 投影，alpha 恒 1）
// 1 = 叠加混合（浮动件：形状外只输出自己的投影，形状内输出覆盖率 alpha）
uniform float uOverlayMode;
// HallPass 叠加模式：surface 透明，形状外只留投影（黑 + alpha），形状内是玻璃本体（alpha = 覆盖率）
uniform float uIsland;
uniform float uG2Factor;         // G2 圆角平滑度（0..0.65，默认 0.45）
uniform float uRimClarity;       // 边缘清晰折射采样混入比例（0..1，默认 0.38）
uniform float uBevelAlphaScale;  // 边缘折射棱面处底色保留比例（0..1，默认 0.68）
out vec4 outColor;

vec3 saturate3(vec3 c, float amount) {
    float luma = dot(c, vec3(0.2126, 0.7152, 0.0722));
    return mix(vec3(luma), c, amount);
}

void main() {
    // 屏幕坐标（y 从底部起算，与 uGlassRect 一致）
    vec2 px = vUv * uResolution;
    vec2 halfSize = uGlassRect.zw * 0.5;
    vec2 center = uGlassRect.xy + halfSize;
    // 形状缩放：把屏幕坐标映回"未缩放形状"的空间（绕中心）。scale = 1 时与原式逐像素等价。
    vec2 centeredCoord = (px - center) / vec2(uScaleX, uScaleY);
    vec2 local = centeredCoord + halfSize;           // 相对形状左上角（未缩放空间）

    // 采样变换（放大镜）：默认 scale=1 / pivot=0 时 samplePx == px
    vec2 samplePx = uSamplePivot + (px - uSamplePivot) / uSampleScale;
    vec2 sampleUv = samplePx / uResolution;

    float radius = radiusAt(centeredCoord, uRadii);
    float sd = sdRoundedRectG2(centeredCoord, halfSize, radius, uG2Factor);
    // 抗锯齿宽度：屏幕空间导数必须在任何分支之前算（下面的形状外提前退出是非一致控制流）
    float aa = max(fwidth(sd), 0.75);

    // ---- 形状外：清晰背景 + 外投影 ----
    // 对齐上游 Shadow 默认值：radius 24dp（模糊半径）、offset.y = radius/6、颜色黑 alpha 0.1。
    // 阴影形状 = 本形状**向下平移** offset；判 P 是否落在阴影里要把 P 往上移回去。
    // ⚠️ 衰减必须从**形状边缘向外**算：sdShadow=0 处最强、到 blur 距离衰减到 0。
    //    之前写的 smoothstep(-96, 0, sdShadow) 在形状外恒为 1 →
    //    等于把整屏形状外**均匀压暗 10%**，根本没有随距离衰减。
    float sdShadow = sdRoundedRectG2(centeredCoord + vec2(0.0, uShadowOffset), halfSize, radius, uG2Factor);
    // ---- 外投影的纵向渐变（见 uShadowSpreadV）----
    float shadowBlurV = uShadowBlur;
    float shadowAlphaV = uShadowAlpha;
    if (uShadowSpreadV > 0.001) {
        float tV = (halfSize.y - centeredCoord.y) / max(2.0 * halfSize.y, 1e-4);
        float bottomT = clamp((tV - 0.5) / 0.5, 0.0, 1.0);
        // 两侧收窄：取外侧法线的向下分量（底边 1 / 两侧 0 / 顶边 0），两侧只保留 35%
        // —— 影子主要落在下方，不会在左右两侧摊开一圈。
        vec2 gS = gradSdRoundedRectG2(centeredCoord + vec2(0.0, uShadowOffset), halfSize, radius, uG2Factor);
        float sideW = mix(0.35, 1.0, clamp(-gS.y / max(length(gS), 1e-4), 0.0, 1.0));
        float grow = mix(1.0, bottomT * sideW, uShadowSpreadV);
        shadowBlurV = uShadowBlur * grow;
        shadowAlphaV = uShadowAlpha * grow;
    }
    float shade = 1.0 - smoothstep(0.0, max(uShadowBlur, 1.0), sdShadow);

    // ---- 形状外提前退出（性能）----
    // 形状外像素的输出只取决于投影（叠加 / 浮动件模式）或清晰背景 + 投影（直写模式），
    // 下面整套材质（折射 / 色散 / 高光 / 文字）对它们的结果会被覆盖率丢掉 ——
    // 全屏三角形下这部分占面板 pass 的七成像素，提前输出与原式逐像素相同。
    if (uIsland > 0.5 || uOverlayMode > 0.5) {
        if (sd > 0.0) {
            float shAlphaOut = (1.0 - smoothstep(0.0, max(shadowBlurV, 1.0), sdShadow)) *
                               shadowAlphaV * uShadow;
            outColor = vec4(vec3(0.0), uIsland > 0.5 ? shAlphaOut : shAlphaOut * uEffectOpacity);
            return;
        }
    } else if (sd >= aa) {
        vec3 sharpOut = texture(uBackdrop, sampleUv).rgb;
        outColor = vec4(sharpOut * (1.0 - shade * uShadowAlpha * uShadow), 1.0);
        return;
    }

    vec3 sharp = texture(uBackdrop, sampleUv).rgb;
    vec3 blurred = texture(uBlurred, sampleUv).rgb;
    vec3 outsideCol = sharp * (1.0 - shade * uShadowAlpha * uShadow);

    // ---- 形状内 ----
    float edge = max(0.0, -sd);                      // 距边缘的距离（AA 过渡带内钳到 0）

    // 提饱和 + 模糊后的底色
    vec3 body = saturate3(blurred, uVibrancy);

    vec3 result;
    if (edge >= uRefractionHeight) {
        result = body;
    } else {
        // ===== 折射 / 色散（与 SkSL 版同结构）=====
        float d = circleMap(1.0 - edge / uRefractionHeight) * uRefractionAmount;
        // sdRoundedRectG2 已具备 G2 曲率连续性，法线差分直接使用真实圆角半径 radius，
        // 避免旧版 radius * 1.5 虚扩导致大圆角面板在直边中段产生法线内凹畸变。
        float gradRadius = min(radius, min(halfSize.x, halfSize.y));
        vec2 g = gradSdRoundedRectG2(centeredCoord, halfSize, gradRadius, uG2Factor);
        // depthEffect（上游 Shaders.kt:80）：在法线方向上再叠一层**径向**分量，
        // 做出"有厚度"的凸起折射。radial 在中轴处也要防零向量。
        if (uDepthEffect > 0.001) {
            g += uDepthEffect * centeredCoord / max(length(centeredCoord), 1e-4);
        }
        float gradLen = length(g);
        vec2 grad = gradLen > 1e-4 ? g / gradLen : vec2(0.0);

        vec2 refractedCoord = samplePx + d * grad;
        vec2 uv = refractedCoord / uResolution;

        // 边缘光学折射清晰度：在靠近外缘的曲面棱边处（bevelFrac -> 1）适度混入清晰背景折射采样，
        // 使穿过弹窗边缘的背景线条产生真实的光学弯折感，同时不过度锐化。
        float bevelFrac = clamp(1.0 - edge / max(uRefractionHeight, 1e-4), 0.0, 1.0);
        float rimClarity = (uBlurRadius > 1.0) ? (smoothstep(0.25, 0.95, bevelFrac) * uRimClarity) : 0.0;

        // 透镜采样模糊后背景（上游管线 blur() -> lens()，透镜计算以模糊图像作为输入源），
        // 确保底板主体与折射边缘均具备一致的柔化与色散质感。
        if (uDispersion <= 0.0) {
            vec3 refCol = mix(texture(uBlurred, uv).rgb, texture(uBackdrop, uv).rgb, rimClarity);
            result = saturate3(refCol, uVibrancy);
        } else {
            float dispersionIntensity =
                ((centeredCoord.x * centeredCoord.y) / (halfSize.x * halfSize.y));
            vec2 dispersedCoord = (d * grad * dispersionIntensity) / uResolution;

            vec3 col = vec3(0.0);
            vec4 c;
            c = texture(uBlurred, uv + dispersedCoord);
            col.r += c.r / 3.5;
            c = texture(uBlurred, uv + dispersedCoord * (2.0 / 3.0));
            col.r += c.r / 3.5; col.g += c.g / 7.0;
            c = texture(uBlurred, uv + dispersedCoord * (1.0 / 3.0));
            col.r += c.r / 3.5; col.g += c.g / 3.5;
            c = texture(uBlurred, uv);
            col.g += c.g / 3.5;
            c = texture(uBlurred, uv - dispersedCoord * (1.0 / 3.0));
            col.g += c.g / 3.5; col.b += c.b / 3.0;
            c = texture(uBlurred, uv - dispersedCoord * (2.0 / 3.0));
            col.b += c.b / 3.0;
            c = texture(uBlurred, uv - dispersedCoord);
            col.r += c.r / 7.0; col.b += c.b / 3.0;
            if (rimClarity > 0.001) {
                vec3 colSharp = vec3(
                    texture(uBackdrop, uv + dispersedCoord * 0.5).r,
                    texture(uBackdrop, uv).g,
                    texture(uBackdrop, uv - dispersedCoord * 0.5).b
                );
                col = mix(col, colSharp, rimClarity);
            }
            result = saturate3(col, uVibrancy);
        }
    }

    // ---- 色彩控制（对齐上游 effects/ColorFilter.kt 的 colorControls）----
    // 放在表面填充之前：效果链上它作用在"采样到的背景"上。
    result = colorControls(result, uBrightness, uContrast, uSaturation);

    // ---- 表面填充（浅色/深色偏透）：containerAlpha；tinted 按钮用 uSurfaceColor 换色 ----
    // 半透明玻璃面板在四周折射棱面处适度减薄底色，避免出现生硬暗圈的同时让边缘折射自然透出。
    float effSurfaceAlpha = uSurfaceAlpha;
    if (uRefractionHeight > 0.5 && uSurfaceAlpha < 0.85 && edge < uRefractionHeight) {
        float bevelT = clamp(edge / max(uRefractionHeight, 1e-4), 0.0, 1.0);
        effSurfaceAlpha *= mix(uBevelAlphaScale, 1.0, smoothstep(0.0, 0.75, bevelT));
    }
    result = mix(result, uSurfaceColor, effSurfaceAlpha);

    // ---- 内阴影（顶部按钮用；底座 / 浮动件把 uInnerAlpha 传 0，等价于关）----
    // 上游 InnerShadow(radius = 按钮参数 18 × press, alpha = press)，颜色黑 alpha 0.15。
    // uInnerTopBias > 0：把内阴影权重压到**上边缘**（玻璃壳的上边框落影，透过玻璃可见）。
    // 权重取**边缘法线的竖直分量**（不是屏幕 y 渐变）：上边缘 ny≈1 拉满、两侧 ny≈0 减淡、
    // 下边缘 ny≈-1 归零 —— 内阴影始终贴着圆角轮廓走，不会在顶部糊成一条横带。
    if (uInnerAlpha > 0.001) {
        // 纵向位置（0 = 顶边，1 = 底边）与纵向掩码：横向扫描线从顶边往下扫到
        // uInnerTopCut 为止；掩码只乘在"贴边圆环"上，所以圆角和两侧的影都贴着轮廓走。
        float hFrac = (halfSize.y - centeredCoord.y) / max(2.0 * halfSize.y, 1e-4);
        float vMask = 1.0 - smoothstep(uInnerTopCut - 0.12, uInnerTopCut, hFrac);
        float topWeight = mix(1.0, vMask, uInnerTopBias);
        // 半径也随纵向收细：顶部 1×，到截止处收到 uInnerTaper× —— 越靠上影越厚、越往下越薄。
        float taperT = clamp(hFrac / max(uInnerTopCut, 1e-3), 0.0, 1.0);
        float radiusV = uInnerRadius * mix(1.0, uInnerTaper, taperT);
        float innerStart = radiusV * mix(0.0, 0.55, uInnerSharp);
        float inner = 1.0 - smoothstep(innerStart, max(radiusV, 1.0), edge);
        result *= (1.0 - inner * uInnerAlpha * topWeight);
    }

    // ---- 棱边高光 ----
    // 上游沿形状**描边**：strokeWidth = ceil(width) * 2 且被形状裁掉外侧一半，
    // 所以可见的是一条**内宽 ≈ width 的环**，环内亮度 = |dot(法线, 45° 光向)| ^ falloff。
    // （之前把强度铺满整个形状，是"整条发白"的根因。）
    float dl = 0.0;
    if (uPlainHighlight > 0.5) {
        // 上游 Highlight.Plain：整块铺白（Plus 混合）。这里在形状内叠一层恒定白，
        // 不做描边环。默认 alpha 仍走 uHighlight。
        result += vec3(uHighlight);
    } else {
        // 环外 ring = 0：高光与下面的环境光都为 0，法线（4 次 SDF）只在环内算
        float ring = 1.0 - smoothstep(uHighlightWidth, uHighlightWidth + uHighlightBlur, edge);
        if (ring > 0.0) {
            float gradRadius = min(radius, min(halfSize.x, halfSize.y));
            vec2 nrm = gradSdRoundedRectG2(centeredCoord, halfSize, gradRadius, uG2Factor);
            dl = dot(nrm, vec2(0.70710678, 0.70710678));
            result += vec3(abs(dl) * uHighlight * ring);
        }
    }

    // ---- 环境光（对照上游 AmbientHighlightShaderString）----
    //   同一个环，但取"受光那一半"（step(0, dot)），并且是**普通混合**不是加法。
    if (uAmbient > 0.5) {
        float ring = 1.0 - smoothstep(uHighlightWidth, uHighlightWidth + uHighlightBlur, edge);
        float t = step(0.0, dl) * abs(dl);
        result = mix(result, vec3(1.0), ring * t * uAmbientIntensity);
    }

    // ---- 效果不透明度（对齐上游 effects/ColorFilter.kt 的 opacity()）----
    // 直写模式：朝清晰背景回退 = 整个玻璃材质变淡（形状覆盖不受影响）；
    // 叠加模式（浮动件 / 按钮）：输出 alpha 也会乘一遍，见 uOverlayMode 分支。
    result = mix(sharp, result, uEffectOpacity);

    // ---- 选中胶囊底色（HallPass 深色模式：静态纯黑）----
    // 必须画在**页签文字之前**：文字随后压在上面，黑底不会挡住选中页签的字 / 图标。
    // 按 press 插值（id 87 静止 / 88 拖动）：按住拖动时淡出 → 恢复玻璃透镜。
    if (uIndicatorFill > 0.001) {
        vec2 indHalf = uIndicatorRect.zw * 0.5;
        vec2 indCenter = uIndicatorRect.xy + indHalf;
        vec2 indCoord = (px - indCenter) / uIndicatorScale;
        vec2 indHalfScaled = indHalf * uIndicatorShape;
        float indSd = sdRoundedRect(indCoord, indHalfScaled, min(indHalfScaled.x, indHalfScaled.y));
        float fill = (1.0 - smoothstep(-1.0, 1.0, indSd)) * uIndicatorFill;
        result = mix(result, vec3(0.0), fill);
    }

    // ---- 页签文字：画在底板之上、指示器之下（指示器才能折射到它）----
    if (uShowLabels > 0.5) {
        // 位图行 0 在顶部，局部坐标 y 从底部起算 → v 要翻；
        // uv 钳到 [0,1]：AA 过渡带会采到形状外的 texel，不钳会出现一条细亮边
        vec2 labelUv = clamp(vec2(local.x / uLabelSize.x, 1.0 - local.y / uLabelSize.y), 0.0, 1.0);
        vec4 label = texture(uLabels, labelUv);
        result = mix(result, label.rgb, label.a);
    }

    // ---- 抗锯齿：屏幕空间导数得到约 1 物理像素的覆盖率过渡（aa 已在开头算好）----
    float coverage = 1.0 - smoothstep(-aa, aa, sd);

    if (uIsland > 0.5) {
        // 叠加模式（HallPass）：surface 透明，形状外只输出自己的投影，形状内是玻璃本体。
        // 与 uOverlayMode 的区别：这里的"底板"是写进 sceneTex_ 的底层（随后指示器 pass
        // 整屏合成到屏幕），所以形状外的 alpha 用**投影强度**而不是 0。
        //
        // ⚠️ 形状外 RGB 输出**黑**（不是清晰背景），这是叠加模式下投影能看见的前提：
        // 系统按预乘合成，屏幕 = rgb + 内容 × (1 − alpha)；若 rgb 拿清晰背景（≈内容），
        // 两项正好抵消（内容原样透出，投影等于没画）。rgb = 0 时压暗量 = alpha 本身。
        // 指示器透镜的采样点会按放大倍率往形状**内侧**收（叠折射位移后仍在内侧），
        // 不会采到这块黑。
        float shAlpha = (1.0 - smoothstep(0.0, max(shadowBlurV, 1.0), sdShadow)) *
                        shadowAlphaV * uShadow;
        bool outsideIsland = sd > 0.0;
        outColor = vec4(outsideIsland ? vec3(0.0) : result, outsideIsland ? shAlpha : coverage);
        return;
    }

    if (uOverlayMode > 0.5) {
        // 叠加混合（浮动件）：形状内 = 玻璃色 + 覆盖率；形状外 = 只输出自己的投影
        // （黑色 + 阴影 alpha，靠 GL 的 src-alpha 混合压暗底下）
        float shAlpha = (1.0 - smoothstep(0.0, max(shadowBlurV, 1.0), sdShadow)) *
                        shadowAlphaV * uShadow;
        bool outside = sd > 0.0;
        outColor = vec4(outside ? vec3(0.0) : result,
                        (outside ? shAlpha : coverage) * uEffectOpacity);
        return;
    }
    outColor = vec4(mix(outsideCol, result, coverage), 1.0);
}
)";


// ---------------------------------------------------------------------------
// pass 5：指示器。采样"背景 + 底板 + 文字"的合成结果，套同一套透镜（折射+色散）。
// 这就是参考图里最亮眼的细节：文字被透镜拉扯 + 分光。
// 胶囊鼓出底板的部分（按压 / 端头）改采**清晰页面内容**（uPage，不叠底板材质）：
// 叠加模式下底板外是投影用的黑，钳到面板矩形只会看到底座边缘的拉伸。
// 不叠材质是为了让按压缩微后的底座轮廓在胶囊里看得见（对齐参考实现：胶囊里
// 能看到比胶囊小一圈的底座）。
// ---------------------------------------------------------------------------
constexpr char kIndicatorShaderBody[] = R"(
uniform sampler2D uScene;
uniform vec2 uResolution;
uniform vec4 uRect;              // 指示器矩形（屏幕坐标，y 从底部起算）
uniform vec4 uRadii;             // 四角半径（左上/右上/右下/左下）；胶囊 = 四值相等
uniform float uRefractionHeight;
uniform float uRefractionAmount;
uniform float uDispersion;
uniform float uDepthEffect;      // 0/1：折射方向叠加径向分量（上游 lens 的 depthEffect）
uniform float uTint;
uniform float uSurfaceWhite;  // 表面白填充（id 36 静止 / 46 拖动，按 press 插值）
uniform float uHighlight;
uniform float uHighlightWidth;
uniform float uHighlightBlur;
// 外缘细灰线（HallPass）：按压时在最外缘描一条极淡的浅灰线增加轮廓对比度（0 = 关）
uniform float uEdgeLine;
uniform float uShadowBlur;
uniform float uShadowOffset;
uniform float uShadowAlpha;
// 外投影纵向渐变（同 progGlass_ 的 uShadowSpreadV）：0 = 均匀一圈；1 = 只落在轮廓下方
// （中线以上不投影、往下越散、两侧收窄 35%）—— 对齐滑块旋钮的"贴边阴影"。
uniform float uShadowSpreadV;
uniform float uScaleX;
uniform float uInnerRadius;   // 内阴影半径（px）＝ InnerShadow.radius
uniform float uInnerAlpha;    // 内阴影强度（已含颜色黑 alpha 0.15）
uniform float uSceneBlur;     // 指示器模糊半径（px）；0 = 关
uniform float uScaleY;
uniform float uShapeScaleX;   // 按压形状缩放（横向，id 82）
uniform float uShapeScaleY;   // 按压形状缩放（纵向，id 51）：只撑胶囊形状，不放大内容
uniform float uPressScale;    // 按压采样缩放：<1 = 透镜缩微（形状向外膨胀、内部内容往中心收）
uniform vec4 uPanelRect;      // 底板矩形（px，GL 坐标，含按压缩放）
uniform float uPanelRadius;   // 底板圆角半径（px）：形状判定用，不能只按矩形
uniform sampler2D uPage;      // 页面内容（清晰，bgTex_）：面板外采样用
uniform float uIsland;        // HallPass 叠加模式：整屏写屏时带 alpha（底板/投影透传）
// 页签文字/图标的两张位图（逐像素同布局，只有颜色不同）：
//   uLabels       = 常态色 —— 形状外按**屏幕位置**叠加，所以拖指示器时它们纹丝不动
//   uLabelsAccent = 凸显色 —— 形状内按**折射位置**叠加，于是"透过指示器看到的"才变色，
//                   并且跟指示器的透镜一起被拉扯/分光（参考实现的图层顺序）
// 关键：底板 pass 不再把文字画进场景，否则指示器的透镜会先采到常态字形，
// 再叠一层凸显色字形 = 两套文字重影。
uniform sampler2D uLabels;
uniform sampler2D uLabelsAccent;
uniform vec4 uLabelRect;        // 文字位图对应的底板矩形（屏幕坐标，y 从底部起算）
uniform vec2 uLabelSize;        // 文字位图尺寸（px）
uniform float uLabelSlots;      // 文字位图里有几个页签格
uniform float uShowTabLabels;   // 0/1
// 按压时凸显色文字的放大比例（参考实现 LocalLiquidBottomTabScale = lerp(1, 1.2, press)）。
// 缩放锚点是**各自页签格的中心**，不是胶囊中心 —— 胶囊滑动不会把字形带着走。
uniform float uLabelPressScale;
out vec4 outColor;

// 采样"背景 + 底板"的合成结果（指示器专有：用的是 uScene）
vec4 sampleScene(vec2 px) { return texture(uScene, px / uResolution); }

// 场景坐标 -> 文字位图局部坐标（相对底板左上角，y 从底部起算）
vec2 labelLocalAt(vec2 px) { return px - uLabelRect.xy; }

// 把局部坐标换算成位图 uv：行 0 在顶部，而局部 y 从底部起算，所以 v 要翻
vec2 labelUv(vec2 local) {
    return clamp(vec2(local.x / uLabelSize.x, 1.0 - local.y / uLabelSize.y), 0.0, 1.0);
}

// 按压放大：把局部坐标换算成"放大后位图"里的等价位置（绕所在页签格中心裁到 1+s 倍）
// （与上游 kIndicatorShaderBody 的 labelLocalMagnified 同式）
vec2 labelLocalMagnified(vec2 local) {
    if (uLabelPressScale < 0.0001 || uLabelSlots < 1.0) {
        return local;
    }
    float slot = uLabelSize.x / uLabelSlots;
    float index = clamp(floor(local.x / slot), 0.0, uLabelSlots - 1.0);
    vec2 center = vec2((index + 0.5) * slot, uLabelSize.y * 0.5);
    return center + (local - center) / (1.0 + uLabelPressScale);
}

// 位图是预乘 alpha：按 alpha 混合即"over"
vec3 overLabels(vec3 base, vec4 label) { return mix(base, label.rgb, label.a); }

// 按屏幕位置取凸显色位图（含按压放大）。色散要按通道各采一次，故单独抽出来。
vec4 accentLabelAt(vec2 px) {
    return texture(uLabelsAccent, labelUv(labelLocalMagnified(labelLocalAt(px))));
}

// 采样点距**底板实际形状**的有符号距离（负 = 形状内）。
// ⚠️ 不能只按矩形判定：圆角缺口 / 形状外的投影带里，叠加模式下场景纹理是
// "投影用的黑"（rgb=0 + 阴影 alpha），按矩形判定会把这些区域当成底板内，
// 于是按压鼓出的胶囊压在圆角上时采到黑块（外加一圈色散彩边）。
float panelSd(vec2 px) {
    vec2 panelHalf = uPanelRect.zw * 0.5;
    vec2 panelCenter = uPanelRect.xy + panelHalf;
    return sdRoundedRect(px - panelCenter, panelHalf, uPanelRadius);
}

// 面板外采样：清晰页面内容，**不叠**底板材质（提饱和 / 表面白）。
// 胶囊按压鼓出底盘、端头探出底板、压在圆角缺口上时，这部分必须透出页面元素；
// 与底板材质区分开，按压缩微后底座的轮廓才会在胶囊里显出来（比胶囊小一圈）。
vec3 samplePage(vec2 px) {
    vec2 uv = clamp(px / uResolution, vec2(0.0), vec2(1.0));
    return texture(uPage, uv).rgb;
}

// 底座轮廓高光带（场景 px）：缩微底座边缘这一圈按缩微坐标取场景，带出底座的亮边。
const float kShrunkRimPx = 4.0;

// 透镜的单点采样：底板形状内 = 场景合成，形状外 = 页面内容。
// 按压"底座缩微"与"画面不跟胶囊跑"解耦：
//   - **形状**按缩微坐标 q = 胶囊中心 + (px - 中心) / uPressScale 判定 → 胶囊里看到的底座
//     比胶囊小一圈；
//   - **颜色**按屏幕原位 px（1:1）取 → 拖动时背景 / 底座里的画面不随胶囊左右移动；
//   - 只有缩微底座的轮廓带（kShrunkRimPx）按 q 取场景，带出底座棱边高光；
//     棱边沿水平方向近乎均匀，跟着胶囊走也看不出位移。
// ⚠️ 面板边缘**不能二值切换**：形状外的场景纹理是"投影用的黑"，贴着轮廓硬切
// 会让面板轮廓在鼓出的胶囊里显出一圈硬接缝（纯色底上就是一圈脏边）。
// 这里只向**形状内**混（2px 过渡带），既抹掉接缝又不会把形状外的黑混进来。
// q 在 px 与胶囊中心连线的外侧，底板是凸形状：q 在底板内 ⇒ px 也在底板内，场景(px) 有效。
vec3 sampleLensPoint(vec2 px) {
    vec2 center = uRect.xy + uRect.zw * 0.5;
    vec2 q = center + (px - center) / uPressScale;
    float sd = panelSd(q);
    if (sd >= 0.0) {
        return samplePage(px);
    }
    vec3 sceneCol = texture(uScene, px / uResolution).rgb;
    vec3 rimCol = texture(uScene, q / uResolution).rgb;
    sceneCol = mix(rimCol, sceneCol, smoothstep(kShrunkRimPx, kShrunkRimPx * 2.0, -sd));
    if (sd <= -2.0) {
        return sceneCol;
    }
    return mix(sceneCol, samplePage(px), smoothstep(-2.0, 0.0, sd));
}

// 透镜采样入口。blurPx > 0：两圈 3x3（外圈 blurPx、内圈一半，权重 2:1），
// 用于折射带里被强压缩的区域（预滤半径见 main 的 bandSlope 推导）。
vec3 sampleLens(vec2 px, float blurPx) {
    if (blurPx < 0.5) {
        return sampleLensPoint(px);
    }
    vec3 acc = vec3(0.0);
    for (int i = -1; i <= 1; i++) {
        for (int j = -1; j <= 1; j++) {
            vec2 o = vec2(float(i), float(j)) * blurPx;
            acc += sampleLensPoint(px + o) * 2.0;
            acc += sampleLensPoint(px + o * 0.5);
        }
    }
    return acc / 27.0;
}

// ---- 凸显色文字的色散宽度（调参入口）----
// 通道位移 = **固定像素量级**，方向取该点的折射法线 grad：彩边宽度处处一致、
// 跟着轮廓走向。⚠️ 不能跟着带内的 d 走：图标顶边离胶囊边只有几 px（按压放大后更近），
// 那里的 d 能到 20px，三个通道直接错开 20px —— 拖出来的是一大块纯色，不是"彩边"。
// 4~5px 与 8dp 字的笔画同量级，再大就会开始出现重影。
const float kLabelCaPx = 4.5;

void main() {
    vec2 px = vUv * uResolution;
    vec2 restHalf = uRect.zw * 0.5;
    vec2 center = uRect.xy + restHalf;
    // 按压 = **形状缩放**（uShapeScaleX/Y，只撑胶囊）+ **内容缩放**（uPressScale，透镜采样）。
    // 两者分开：胶囊可以明显长大，而胶囊里看到的底座 / 文字绕中心缩微（<1）——
    // 形状往外长、内容往回收，才是液态透镜被按下去的观感（对齐上游开关 / 滑块的旋钮）。
    // 横纵分开缩放：纵向鼓得多、横向收着长（椭圆角随纵向半径走，仍是胶囊）。
    vec2 halfSize = restHalf * vec2(uShapeScaleX, uShapeScaleY);
    // 拖动速度的拉长/压扁仍走非等比缩放，与按压缩放解耦。
    vec2 centeredCoord = (px - center) / vec2(uScaleX, uScaleY);
    // 圆角半径跟纵向缩放（半径 = 半高，纵向一撑就还是胶囊端头）。
    float radius = radiusAt(centeredCoord, uRadii) * uShapeScaleY;
    float sd = sdRoundedRect(centeredCoord, halfSize, radius);
    // 抗锯齿宽度：导数必须在分支之前算（下面的胶囊外提前退出是非一致控制流）
    float aa = max(fwidth(sd), 0.75);

    // 指示器投影：鼓出底座时靠它和底座边框"断开"，做出 iOS 那种空隙/分离感。
    // 与底板同一套"贴边投影"纵向渐变（见 progGlass_ 的 uShadowSpreadV）：按压时
    // 中线以上不投影、往下越散、两侧收窄到 35%，影子只落在轮廓下方（对齐滑块旋钮）。
    float sdShadow = sdRoundedRect(centeredCoord + vec2(0.0, uShadowOffset),
                                   halfSize, radius);
    float shadowBlurV = uShadowBlur;
    float shadowAlphaV = uShadowAlpha;
    // 纵向渐变只会把模糊半径往小收（grow ≤ 1）：投影范围外（sdShadow ≥ 原半径）shade 恒为 0，
    // 不必为它算梯度（4 次 SDF；按压态下这一项原先每个像素都算）
    if (uShadowSpreadV > 0.001 && sdShadow < max(uShadowBlur, 1.0)) {
        float tV = (halfSize.y - centeredCoord.y) / max(2.0 * halfSize.y, 1e-4);
        float bottomT = clamp((tV - 0.5) / 0.5, 0.0, 1.0);
        vec2 gS = gradSdRoundedRect(centeredCoord + vec2(0.0, uShadowOffset), halfSize, radius);
        float sideW = mix(0.35, 1.0, clamp(-gS.y / max(length(gS), 1e-4), 0.0, 1.0));
        float grow = mix(1.0, bottomT * sideW, uShadowSpreadV);
        shadowBlurV = uShadowBlur * grow;
        shadowAlphaV = uShadowAlpha * grow;
    }
    float shade = 1.0 - smoothstep(0.0, max(shadowBlurV, 1.0), sdShadow);
    // 形状外：清晰场景 + 常态色页签。页签按屏幕坐标采（不含透镜位移）——
    // 指示器滑到哪儿都不会带动它们；指示器自己的投影仍压在这一层之上。
    vec4 sceneHere = sampleScene(px);
    vec3 outsideScene = sceneHere.rgb;
    if (uShowTabLabels > 0.5) {
        outsideScene = overLabels(outsideScene, texture(uLabels, labelUv(labelLocalAt(px))));
    }
    vec3 outsideCol = outsideScene * (1.0 - shade * shadowAlphaV);

    // ---- 胶囊外提前退出（性能）----
    // 覆盖率为 0（sd ≥ aa）的像素只输出上面的"场景 + 常态文字 + 指示器投影"，
    // 透镜采样（按压态每像素 3 组 × 18 次）与高光全是会被覆盖率丢掉的计算 ——
    // 写屏 pass 是全屏三角形，胶囊外占八成以上像素。提前输出与原式逐像素相同。
    if (sd >= aa) {
        if (uIsland > 0.5) {
            outColor = vec4(outsideCol, max(sceneHere.a, shade * shadowAlphaV));
        } else {
            outColor = vec4(outsideCol, 1.0);
        }
        return;
    }

    float edge = max(0.0, -sd);
    // 透镜采样点：1:1 屏幕坐标（画面不随胶囊移动）。按压缩微只作用于底座**形状**，
    // 在 sampleLensPoint 里按 uPressScale 换算，见那里的说明。
    vec2 lensCoord = px;
    // 折射带内的预滤半径：带内采样被向内压缩（circleMap 在带外缘的导数 → ∞）。
    // 按**当前压缩倍率**给，而不是"带宽 × 固定比例"——0.12×带宽 在带中间也有
    // 6px+ 的核：整圈糊成一片、色散发浊（真机走查：纯色底上一圈"脏"）。
    //   压缩倍率 ≈ 1 + |dd/dedge| = 1 + (A/H)·t/√(1−t²)，t = 1 − edge/H ∈ [0,1]
    // ⚠️ t = 带内位置：0 = 折射带内缘、1 = 形状外缘。所以 t=0（含整个胶囊内部）
    //    恒为 0 = **不滤** —— 按压时胶囊里必须是 1:1 的锐利画面（走查反馈）。
    // 外缘的极端压缩交给 sceneTex_ 的 mip 链（三线性）兜底，这里只补到 1.5px。
    float bandT = clamp(1.0 - edge / max(uRefractionHeight, 1.0), 0.0, 1.0);
    float bandSlope = (abs(uRefractionAmount) / max(uRefractionHeight, 1.0)) * bandT /
                      max(sqrt(max(1.0 - bandT * bandT, 1e-4)), 1e-4);
    float lensBlur = max(uSceneBlur, min(1.5, 0.5 * bandSlope));
    vec3 result;
    // 凸显色页签的采样位置：**只跟透镜位移，不跟"按压采样缩小"**。
    // 缩小是绕胶囊中心的整体变换，带上它文字就会绕中心缩放 —— 胶囊一动，
    // 字形就跟着胶囊跑（参考实现的指示器没有这一层，文字不随指示器移动）。
    vec2 labelPx = px;
    // 凸显色文字的三通道位移差（**屏幕空间**，px；0 = 无色散）。
    // 文字层不在场景纹理里，场景那套色散采不到它 —— 不单独做一次，
    // 指示器里的文字就是纯色一块，"色散没了"的观感就是这么来的。
    vec2 labelDisp = vec2(0.0);
    if (edge >= uRefractionHeight) {
        result = sampleLens(lensCoord, lensBlur);
    } else {
        float d = circleMap(1.0 - edge / uRefractionHeight) * uRefractionAmount;
        float gradRadius = min(radius * 1.5, min(halfSize.x, halfSize.y));
        // 退化保护：同底板 shader —— 中轴零梯度会让 normalize 出 NaN。
        vec2 g = gradSdRoundedRect(centeredCoord, halfSize, gradRadius);
        // depthEffect：与底板同式（上游 Shaders.kt:80）。
        if (uDepthEffect > 0.001) {
            g += uDepthEffect * centeredCoord / max(length(centeredCoord), 1e-4);
        }
        float gradLen = length(g);
        vec2 grad = gradLen > 1e-4 ? g / gradLen : vec2(0.0);
        vec2 refractedCoord = lensCoord + d * grad;
        // 文字的"屏幕位置"= 自然位置 + 透镜位移（不含 uPressScale：见上方注释）
        labelPx = px + d * grad;

        if (uDispersion <= 0.0) {
            result = sampleLens(refractedCoord, lensBlur);
        } else {
            // 色散 = **三通道折射位移差**（R 折得深、B 折得浅）。两个旋钮解耦：
            //   - ca  = **范围**：以折射点为基准 ±ca×位移（1.2 → 色散范围比折射带更宽；
            //           写成"基准 ± 偏移"就避免了 (1−disp) 翻号把 B 推到形状外的问题）；
            //   - mix = **强度**：与无色散结果混合（0.30 → 淡淡一层）。
            // 整圈可见：加权抬到 0.5 起步（上下左右中点也有半强度彩边）。
            // ⚠️ 彩度来自"三通道采到不同内容"，纯色区域本就无色可分 —— 色散只在有
            //    内容边缘的地方显色（要"纯色底也见到彩虹"得另加一层合成棱镜色）。
            float diag = (centeredCoord.x * centeredCoord.y) / (halfSize.x * halfSize.y);
            float intensity = 0.5 + 0.5 * diag;
            // 采样同在屏幕空间（缩微只在 sampleLensPoint 里作用于形状），位移差不用再换算。
            vec2 caScreen = d * 1.2 * intensity * grad;
            // 文字层的通道位移：固定量级（见 kLabelCaPx 的说明），不跟带内位置走。
            // 乘 bandT（带内位置 0..1）只为让彩边随折射带一起"长出来"，不是按 d 走。
            labelDisp = grad * (kLabelCaPx * bandT);
            vec2 caShift = caScreen;
            vec3 dispBase = sampleLens(refractedCoord, lensBlur);
            vec3 dispCol;
            dispCol.r = sampleLens(refractedCoord + caShift, lensBlur).r;
            dispCol.g = dispBase.g;
            dispCol.b = sampleLens(refractedCoord - caShift, lensBlur).b;
            result = mix(dispBase, dispCol, 0.30);
        }
    }
    // ---- 凸显色：指示器范围内的页签文字/图标换成强调色 ----
    // 位置用 labelPx（透镜位移，但不含按压采样缩小）→ 与形状外的常态字形在同一位置，
    // 所以静止时逐像素重合、只换了颜色；拖动时它只是被透镜的折射带轻微拉扯，
    // 不会跟着胶囊整体平移。形状外 result 会被 coverage 丢掉 —— 盖住半个字就只有半个字变色。
    // 按压时再绕**页签格中心**放大 uLabelPressScale（参考实现的 LocalLiquidBottomTabScale）：
    // 只有这一层（透过指示器看到的文字）会变大，底座里的常态文字不变。
    if (uShowTabLabels > 0.5) {
        vec4 accent = accentLabelAt(labelPx);
        if (abs(labelDisp.x) + abs(labelDisp.y) > 0.01) {
            // 色散：R / B 各按 ±labelDisp 采一次，**逐通道 over**（每个通道用自己的覆盖率）——
            // 笔画的一侧留下 R、另一侧留下 B，就是"透过玻璃看到的字有彩边"。
            // （用 mix 稀释成一层色是看不出彩边的；位移见 kLabelCaPx。）
            vec4 accentR = accentLabelAt(labelPx + labelDisp);
            vec4 accentB = accentLabelAt(labelPx - labelDisp);
            result = vec3(mix(result.r, accentR.r, accentR.a),
                          mix(result.g, accent.g, accent.a),
                          mix(result.b, accentB.b, accentB.a));
        } else {
            result = overLabels(result, accent);
        }
    }

    // 选中态底色：onDrawSurface 里的 black alpha = lerp(tintRest 0.2, tintDrag 0, press)
    result *= (1.0 - uTint);
    // 表面白：同一层 onDrawSurface 上再叠一层白（id 36 / 46）。
    // 上游是 drawRect(白 alpha=lerp(rest, drag, press))，普通混合 → mix 即等价。
    result = mix(result, vec3(1.0), uSurfaceWhite);

    // 内阴影（上游 InnerShadow(radius = lerp(2dp, 8dp, press), alpha = lerp(0.14, 1.0, press))，
    // 颜色黑 alpha 0.15）：靠近内边缘压一圈暗，做出厚度感。
    // 上游 offset = (0, radius) 偏下 → 用一点"下重上轻"近似。
    if (uInnerAlpha > 0.001) {
        float inner = 1.0 - smoothstep(0.0, max(uInnerRadius, 1.0), edge);
        float lowerBias = clamp(0.65 - centeredCoord.y / max(halfSize.y, 1.0) * 0.35, 0.0, 1.0);
        result *= (1.0 - inner * uInnerAlpha * lowerBias);
    }

    // 棱边高光：与底板**逐字同一套**（DefaultHighlight 移植）—— 细描边环。
    // 之前这里用的是遗留的"从棱边向内 max(8px, 短半轴*0.35) 的粗渐变遮罩"，
    // 所以指示器的高光又粗又靠内，和底板的细亮边对不上。改为与底板相同的
    // `1 - smoothstep(环宽, 环宽+柔化, edge)`。（法线已用中央差分，本身平滑，
    // 不再需要那层遮罩压楔形。）
    {
        // 环外 ring = 0：法线（4 次 SDF）只在高光环内算
        float ring = 1.0 - smoothstep(uHighlightWidth, uHighlightWidth + uHighlightBlur, edge);
        if (ring > 0.0 && uHighlight > 0.0) {
            float gradRadius = min(radius * 1.5, min(halfSize.x, halfSize.y));
            vec2 nrm = gradSdRoundedRect(centeredCoord, halfSize, gradRadius);
            float dl = dot(nrm, vec2(0.70710678, 0.70710678));
            result += vec3(abs(dl) * uHighlight * ring);
        }
    }

    // ---- 外缘细灰线（HallPass）----
    // 纯色（尤其白底）上玻璃轮廓容易"化开"，在**最外缘 ~1.5px** 描一条极淡的浅灰线
    // 增加对比度（叠在棱边高光之外，形成"灰线 + 白高光"的薄棱边）。
    // uEdgeLine = 0 时完全关闭（静止态由 ArkTS 传 0）。
    if (uEdgeLine > 0.001) {
        float line = 1.0 - smoothstep(0.0, 1.5, edge);
        result = mix(result, vec3(0.72, 0.73, 0.75), line * uEdgeLine);
    }

    // ---- 抗锯齿（同底板；aa 已在开头算好）----
    float coverage = 1.0 - smoothstep(-aa, aa, sd);
    if (uIsland > 0.5) {
        // 叠加模式（HallPass）：这一 pass 是写屏 pass，alpha 必须透传——
        // 形状内恒为 1；形状外取"场景 alpha（底板投影）"与"指示器自己的投影"的较大者：
        // 底板投影按压时会淡出，指示器的贴边投影得自己带 alpha，否则轮廓下方落在
        // **页面内容**上的那半圈影子会被合成器直接丢掉（该处场景 alpha = 0）。
        float outAlpha = max(sceneHere.a, shade * shadowAlphaV);
        outColor = vec4(mix(outsideCol, result, coverage), mix(outAlpha, 1.0, coverage));
        return;
    }
    outColor = vec4(mix(outsideCol, result, coverage), 1.0);
}
)";

// ---------------------------------------------------------------------------
// pass 4b：跟手光斑（对齐参考实现的 InteractiveHighlight）
//
// 上游是**独立图层 + BlendMode.Plus**：一层铺满玻璃的白（glowFlat）+ 一层以手指为中心
// 的径向白（glowRadial，半径 = 短边 × glowRadiusFactor），两者都乘以按压进度。
// 这里做成同一个 scene FBO 上的加性 pass —— 加性混合与"独立图层 + Plus"数学等价，
// 而且因为它坐在 sceneTex_ 里，指示器的透镜会把光斑一起折射（上游也是这个相对顺序）。
// ---------------------------------------------------------------------------
constexpr char kGlowShaderBody[] = R"(
uniform vec2 uResolution;
uniform vec4 uGlassRect;      // xy = 左下角（GL 坐标），zw = 尺寸
uniform vec4 uRadii;          // 四角半径；光斑跟底板的形状走
uniform float uProgress;      // 0..1，独立弹簧（参数 31/32）
uniform float uFlat;          // id 6
uniform float uRadial;        // id 7
uniform float uRadiusFactor;  // id 8
uniform vec2 uCenter;         // 光斑中心（屏幕 px，GL 坐标）
out vec4 outColor;

void main() {
    vec2 px = vUv * uResolution;
    vec2 halfSize = uGlassRect.zw * 0.5;
    vec2 centered = px - uGlassRect.xy - halfSize;
    float sd = sdRoundedRect(centered, halfSize, radiusAt(centered, uRadii));
    // 光斑被玻璃形状裁掉（上游 drawWithContent 画在自己的 layer 里，同样被形状裁）
    float aa = max(fwidth(sd), 0.75);
    float coverage = 1.0 - smoothstep(-aa, aa, sd);
    if (coverage <= 0.0) {
        outColor = vec4(0.0);
        return;
    }
    float radius = min(uGlassRect.z, uGlassRect.w) * uRadiusFactor;
    float intensity = smoothstep(radius, radius * 0.5, distance(px, uCenter));
    // 混合函数是 (ONE, ONE)，所以这里输出的是"要加多少"，alpha 不参与
    outColor = vec4(vec3((uFlat + uRadial * intensity) * uProgress * coverage), 0.0);
}
)";

// ---------------------------------------------------------------------------
// pass 7：顶部三个玻璃按钮的图标（采样 iconTex_，三格横向排列）
// ---------------------------------------------------------------------------
constexpr char kIconShaderBody[] = R"(
uniform vec2 uResolution;
uniform vec2 uFirstRect;     // 最左按钮的左下角（GL 坐标）
uniform float uBtnSize;
uniform float uSpacing;
uniform float uIconSize;
uniform sampler2D uIcons;    // 3 格横向排列、预乘 alpha 的白色图标
out vec4 outColor;

void main() {
    vec2 px = vUv * uResolution;
    for (int i = 0; i < 3; i++) {
        vec2 base = uFirstRect + vec2(float(i) * (uBtnSize + uSpacing), 0.0);
        vec2 iconBase = base + vec2((uBtnSize - uIconSize) * 0.5);
        vec2 local = px - iconBase;
        if (local.x < 0.0 || local.x > uIconSize || local.y < 0.0 || local.y > uIconSize) {
            continue;
        }
        // 位图行 0 在顶部、GL 的 y 从底部起算（同文字纹理的翻转）
        vec2 uv = vec2((local.x / uIconSize + float(i)) / 3.0, 1.0 - local.y / uIconSize);
        outColor = texture(uIcons, uv);   // 预乘：混合函数用 (ONE, ONE_MINUS_SRC_ALPHA)
        return;
    }
    outColor = vec4(0.0);
}
)";

// ---------------------------------------------------------------------------
// 目录场景 pass：纯色圆角矩形（轨道 / 填充 / 卡片 / 对话框按钮底色）
// ---------------------------------------------------------------------------
constexpr char kSolidShaderBody[] = R"(
uniform vec2 uResolution;
uniform vec4 uRect;        // xy = 左下角（GL 坐标），zw = 尺寸
uniform vec4 uRadii;       // 左上/右上/右下/左下
uniform vec4 uColor;       // 非预乘
out vec4 outColor;

void main() {
    vec2 px = vUv * uResolution;
    vec2 halfSize = uRect.zw * 0.5;
    vec2 centered = px - uRect.xy - halfSize;
    float radius = radiusAt(centered, uRadii);
    float sd = sdRoundedRect(centered, halfSize, radius);
    float aa = max(fwidth(sd), 0.75);
    float coverage = 1.0 - smoothstep(-aa, aa, sd);
    outColor = vec4(uColor.rgb, uColor.a * coverage);
}
)";

// ---------------------------------------------------------------------------
// 目录场景 pass：背景 -> sceneTex_ 的拷贝（不带模糊）
// ---------------------------------------------------------------------------
constexpr char kCopyShaderBody[] = R"(
uniform sampler2D uSource;
out vec4 outColor;
void main() {
    outColor = texture(uSource, vUv);
}
)";

// ---------------------------------------------------------------------------
// 目录场景 pass：文字 / 图标位图（预乘 alpha，位图行 0 在顶部）
// ---------------------------------------------------------------------------
constexpr char kSpriteShaderBody[] = R"(
uniform vec2 uResolution;
uniform sampler2D uSprite;
uniform vec4 uRect;        // xy = 左下角（GL 坐标），zw = 尺寸
uniform float uAlpha;      // 整体不透明度（内容层的淡入淡出）
out vec4 outColor;
void main() {
    vec2 px = vUv * uResolution;
    vec2 local = (px - uRect.xy) / uRect.zw;
    if (local.x < 0.0 || local.x > 1.0 || local.y < 0.0 || local.y > 1.0) {
        outColor = vec4(0.0);
        return;
    }
    // GL 的 vUv.y = 0 在屏幕底部；位图行 0 在顶部 → 翻 y
    outColor = texture(uSprite, vec2(local.x, 1.0 - local.y)) * uAlpha;
}
)";

// ---------------------------------------------------------------------------
// 渐进模糊（对齐上游 ProgressiveBlurContent 的 AlphaMask runtime shader）：
// 上半个band完全模糊、向下淡出；同时叠一层 tint（纵向同样渐变）。
// ---------------------------------------------------------------------------
constexpr char kProgressiveBlurShaderBody[] = R"(
uniform vec2 uResolution;
uniform sampler2D uSharp;
uniform sampler2D uBlurred;
uniform vec4 uRect;        // xy = 左下角（GL 坐标），zw = 尺寸
uniform vec3 uTint;
uniform float uTintIntensity;
out vec4 outColor;

void main() {
    vec2 px = vUv * uResolution;
    vec2 halfSize = uRect.zw * 0.5;
    vec2 centered = px - uRect.xy - halfSize;
    // 全圆角矩形（band 无圆角）
    float sd = sdRoundedRect(centered, halfSize, 0.0);
    float aa = max(fwidth(sd), 0.75);
    float coverage = 1.0 - smoothstep(-aa, aa, sd);
    if (coverage <= 0.0) {
        outColor = vec4(0.0);
        return;
    }
    // coord.y 按上游是**自上而下**：0 = band 顶部，size.y = 底部
    float y = (uRect.y + uRect.w) - px.y;
    float blurAlpha = smoothstep(uRect.w, uRect.w * 0.5, y);
    vec3 sharp = texture(uSharp, vUv).rgb;
    vec3 blurred = texture(uBlurred, vUv).rgb;
    vec3 col = mix(sharp, blurred, blurAlpha);
    col = mix(col, uTint, blurAlpha * uTintIntensity);
    outColor = vec4(col, coverage);
}
)";


GLuint CompileShader(GLenum type, const char *src) {
    GLuint shader = glCreateShader(type);
    glShaderSource(shader, 1, &src, nullptr);
    glCompileShader(shader);
    GLint ok = GL_FALSE;
    glGetShaderiv(shader, GL_COMPILE_STATUS, &ok);
    if (ok != GL_TRUE) {
        char log[2048] = {0};
        glGetShaderInfoLog(shader, sizeof(log) - 1, nullptr, log);
        GERR("shader compile failed: %{public}s", log);
        glDeleteShader(shader);
        return 0;
    }
    return shader;
}

GLuint LinkProgram(const char *vs, const char *fs) {
    GLuint v = CompileShader(GL_VERTEX_SHADER, vs);
    GLuint f = CompileShader(GL_FRAGMENT_SHADER, fs);
    if (v == 0 || f == 0) {
        return 0;
    }
    GLuint prog = glCreateProgram();
    glAttachShader(prog, v);
    glAttachShader(prog, f);
    glLinkProgram(prog);
    GLint ok = GL_FALSE;
    glGetProgramiv(prog, GL_LINK_STATUS, &ok);
    if (ok != GL_TRUE) {
        char log[1024] = {0};
        glGetProgramInfoLog(prog, sizeof(log) - 1, nullptr, log);
        GERR("program link failed: %{public}s", log);
        glDeleteProgram(prog);
        prog = 0;
    }
    glDeleteShader(v);
    glDeleteShader(f);
    return prog;
}

int64_t NowMs() {
    using namespace std::chrono;
    return duration_cast<milliseconds>(steady_clock::now().time_since_epoch()).count();
}

/** CLOCK_MONOTONIC 纳秒（与 OH_NativeVSync 回调的时间戳同一时钟）。 */
int64_t MonoNs() {
    using namespace std::chrono;
    return duration_cast<nanoseconds>(steady_clock::now().time_since_epoch()).count();
}

void SetupTexture(GLuint tex) {
    glBindTexture(GL_TEXTURE_2D, tex);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
}

/**
 * 把裁剪盒设成"某个矩形外扩 margin"（GL 坐标，y 从**底部**起算，与 glScissor 一致）。
 *
 * 为什么要它：玻璃 shader 是**全屏三角形 + 逐像素 SDF**，形状只占屏幕很小一块。
 * 新增的按钮 / 光斑 / 按钮模糊如果各来一遍全屏，帧率立刻掉到面板刷新率以下
 * （真机实测：1280×2598、60Hz 面板，从 60.2fps 掉到 54.1fps）。
 * 这些 pass 的输出只在给定矩形内非零，所以用 scissor 裁掉盒外像素**完全等价**，
 * 而 fragment 成本降到千分之几。
 *
 * 调用方负责 `glEnable/glDisable(GL_SCISSOR_TEST)`。
 */
void SetScissorRect(float left, float bottom, float width, float height, float margin, int screenW,
                    int screenH) {
    int x0 = static_cast<int>(std::floor(left - margin));
    int y0 = static_cast<int>(std::floor(bottom - margin));
    int x1 = static_cast<int>(std::ceil(left + width + margin));
    int y1 = static_cast<int>(std::ceil(bottom + height + margin));
    x0 = std::max(0, std::min(x0, screenW));
    y0 = std::max(0, std::min(y0, screenH));
    x1 = std::max(0, std::min(x1, screenW));
    y1 = std::max(0, std::min(y1, screenH));
    if (x1 <= x0 || y1 <= y0) {
        glScissor(0, 0, 0, 0);   // 空盒 = 这一段什么都不画
        return;
    }
    glScissor(x0, y0, x1 - x0, y1 - y0);
}

// ---------------------------------------------------------------------------
// 顶部三个玻璃按钮的布局常量（对齐参考实现的 Row + GlassIconButton）
// ---------------------------------------------------------------------------
constexpr float kIconButtonSpacingDp = 12.0f;  // Arrangement.spacedBy(12.dp)
constexpr float kIconButtonPaddingH = 20.0f;   // Row padding(end = 20.dp)
constexpr float kIconButtonPaddingV = 20.0f;   // Row padding(top = 20.dp)
constexpr float kIconButtonIconDp = 19.0f;     // 图标 Canvas 的 size(19.dp)

// 主模糊链的降采样阈值（px）。低于阈值走全分辨率两趟，默认参数下外观逐像素不变。
constexpr float kBlurPyramidHalfMinPx = 20.0f;
constexpr float kBlurPyramidQuarterMinPx = 64.0f;

// 嵌入式弹窗工作区相对面板的外扩（px）：≥ 两条平滑模糊迭代 pass 的累计支撑（见 DrawDialogScene）。
constexpr float kDialogWorkMarginPx = 104.0f;

// ---------------------------------------------------------------------------
// 目录场景（catalog）通用常量
// ---------------------------------------------------------------------------

/** 飞机图标（控制中心 / 游乐场）。24×24 视口，只含绝对 M/L/Q/Z（与页签图标同一解析器）。 */
constexpr char kPlaneIconPath[] =
    "M12 2 Q12.85 2 12.85 3.1 L12.85 9.3 L21 14 L21 16.1 L12.85 13.6 L12.85 18.4 "
    "L15.5 20.3 L15.5 22 L12 20.9 L8.5 22 L8.5 20.3 L11.15 18.4 L11.15 13.6 "
    "L3 16.1 L3 14 L11.15 9.3 L11.15 3.1 Q11.15 2 12 2 Z";

constexpr float kPlaneIconDp = 24.0f;

// 目录场景常用颜色（对齐上游 dark theme 值）
constexpr float kAccentR = 0.0f;
constexpr float kAccentG = 0.5686f;   // 0x91 / 255
constexpr float kAccentB = 1.0f;      // #0091FF
constexpr float kTrackR = 0.4706f;    // #787880
constexpr float kTrackG = 0.4706f;
constexpr float kTrackB = 0.5020f;
constexpr float kTrackAlpha = 0.36f;

// 按压时**玻璃内部内容**的采样缩小比例（采样缩放 = 1 - k × press，绕形状中心）。
// 与形状的按压缩放（scale > 1）方向相反：形状往外长、内容往回收，才有透镜被按下去的感觉。
// 旋钮（开关 / 滑块）与顶部玻璃按钮共用这个量级；页签指示器走参数 81（应用内可调）。
constexpr float kKnobPressSampleShrink = 0.08f;
constexpr float kButtonPressSampleShrink = 0.08f;

/** 菜单目标编号：：0=底座，1=指示器·静止，2=指示器·拖动（0=底座，1=指示器·静止，2=指示器·拖动） */
constexpr int kIconButtonMenuTargets[3] = {2, 1, 0};

/**
 * 本帧所有弹簧的位移累积（只由渲染线程读写）。
 *
 * 用途：判定"动画是不是停了" —— 低于阈值就跳过绘制（见 RenderLoop 的空闲分支）。
 * 之所以累积**位移**而不是速度：各弹簧的量纲不同（页数 / 0..1 进度 / px / %），
 * 位移是唯一能直接和"肉眼可见的移动量"挂钩的指标。
 */
float gSpringMotion = 0.0f;

// 帧率节流参数：交互中 120fps，其余 60fps；触摸后 400ms 内算"交互中"。
constexpr int64_t kInteractiveFrameMs = 8;
constexpr int64_t kNormalFrameMs = 16;
constexpr int64_t kInteractiveWindowMs = 400;
// 弹簧"还在动"的判据：本轮所有弹簧位移之和换算成**速率**（值/秒）超过它。按速率判、与本轮
// 步长无关 —— vsync 调度下每出一帧循环要醒 2~3 次（等 vsync / 等相位），单轮步长只有 ~3ms，
// 按"每轮位移 > 1e-3"判的话，页签弹簧离目标还差 ~6px 就判停（落定对齐就是一跳）。
// 取值 = 旧口径"16ms 一帧位移 1e-3"。
constexpr float kIdleMotionRate = 0.06f;
// 弹簧单步的最长步长（UpdateAnim 的夹取），换算速率用同一个值
constexpr float kMaxSpringStepSec = 0.05f;
// 落定对齐的位置容差（见 SettleSprings）：几何量（页签位置 / 缩放 / 速度形变）与强度量
// （按压进度 / 光斑 / 按钮按压）。页签宽 ~220px，0.002 ≈ 0.4px。
constexpr float kSettleGeometryTolerance = 0.002f;
constexpr float kSettleLevelTolerance = 0.01f;
// 大面积形状的缩放（弹窗卡片 ~1140px 宽）：0.0005 ≈ 0.6px
constexpr float kSettleScaleTolerance = 0.0005f;

// 内容模式（镜像纹理当背景）的一帧外推：推送后先全量保持一段（正常滚动每帧都会重推，
// 外推量就是"下一帧的位移"，不该打折），停推之后再线性衰减到 0（滚动停下自动归零）。
// 采样位移预算见 SetContentBand（非对称，由 ArkTS 按条带几何 + 镜像余量下发）。
constexpr int64_t kContentLeadHoldMs = 16;
constexpr int64_t kContentLeadDecayMs = 48;

/** 按推送后的时长衰减外推量（见 kContentLeadHoldMs）。 */
float DecayedLead(float lead, int64_t ageMs) {
    if (ageMs < 0 || ageMs >= kContentLeadHoldMs + kContentLeadDecayMs) {
        return 0.0f;
    }
    if (ageMs <= kContentLeadHoldMs) {
        return lead;
    }
    return lead * (1.0f - static_cast<float>(ageMs - kContentLeadHoldMs) /
                              static_cast<float>(kContentLeadDecayMs));
}

// vsync 对齐出帧（见 GlesRenderer::WaitForRenderSlot）：出帧点 = vsync + 0.4 周期（夹在 1.5~4ms），
// 离下个 vsync 不足 2.5ms 就顺延：一帧录制 + 交换约 1.5~2.5ms（SURFACE 的取 / 交 buffer 走 IPC），
// 赶不上下个 vsync 的取走（SURFACE：RS 合成 ≈ vsync + 0.3ms；TEXTURE：UI 线程 ≈ vsync + 0.8ms），
// 画了也只会和下一帧一起上屏。
constexpr int64_t kRenderPhaseMinNs = 1500000;
constexpr int64_t kRenderPhaseMaxNs = 4000000;
constexpr int64_t kRenderLateMarginNs = 2500000;
// 空闲等待上限：所有会改变画面的入口都会 NotifyFrame，等待只是兜底（旧版每 16ms 醒一次）。
constexpr int kIdleWaitMs = 250;

// 持有 vsync 连接的渲染器（OnVsyncCallback 只在登记表里还有它时才碰它）：弹窗实例关闭后
// 对象会被删除，迟到的 vsync 回调不能再访问它。
std::mutex gVsyncOwnersMutex;
std::unordered_set<const void *> gVsyncOwners;

/**
 * 半隐式欧拉步进一个弹簧（本文件所有弹簧共用同一套公式：c = 2√k × ratio）。
 *
 * 与参考实现的 `spring(dampingRatio, stiffness, visibilityThreshold)` 同构；
 * 这里不做 visibilityThreshold 的提前收敛（各自的调用点按需加死区），
 * 但会把本帧位移累加到 `gSpringMotion`（空闲检测用）。
 */
void SpringStep(float &value, float &velocity, float target, float stiffness, float damping,
                float dt) {
    const float k = std::max(stiffness, 0.0f);
    if (k <= 0.0f) {
        velocity = 0.0f;   // 刚度 0 = 不动（不产生 NaN）
        return;
    }
    const float c = 2.0f * std::sqrt(k) * std::max(damping, 0.0f);
    velocity += (-k * (value - target) - c * velocity) * dt;
    const float delta = velocity * dt;
    value += delta;
    gSpringMotion += std::fabs(delta);
}

}  // namespace


// ---------------------------------------------------------------------------
// 页签图标：与参考实现的 TabIconPaths 完全相同（24×24 视口，绝对 M/L/Q/Z）
// ---------------------------------------------------------------------------
const std::vector<std::string> kTabIconPaths = {
    // house
    R"(M19.99 12Q19.68 12 19.46 12.23Q19.25 12.46 19.25 12.77L19.25 19.99Q19.25 20.3 19.02 20.52Q18.79 20.74 18.48 20.74L15.72 20.74L15.72 16.44Q15.72 15.43 15.22 14.58Q14.71 13.73 13.86 13.22Q13.01 12.72 12 12.72Q10.97 12.72 10.12 13.22Q9.26 13.73 8.76 14.58Q8.26 15.43 8.26 16.44L8.26 20.74L5.47 20.74Q5.18 20.74 4.96 20.51Q4.73 20.28 4.73 19.97L4.73 12.77Q4.73 12.46 4.51 12.23Q4.3 12 3.98 12Q3.67 12 3.46 12.23Q3.24 12.46 3.24 12.77L3.24 19.97Q3.24 20.59 3.54 21.11Q3.84 21.62 4.36 21.92Q4.87 22.22 5.47 22.22L18.48 22.22Q19.08 22.22 19.6 21.92Q20.11 21.62 20.42 21.11Q20.74 20.59 20.74 19.99L20.74 12.77Q20.74 12.46 20.52 12.23Q20.3 12 19.99 12ZM9.77 16.44Q9.77 15.53 10.43 14.87Q11.09 14.21 12 14.21Q12.91 14.21 13.57 14.87Q14.23 15.53 14.23 16.44L14.23 20.74L9.77 20.74L9.77 16.44ZM22.54 11.45Q22.73 11.23 22.73 10.92Q22.73 10.61 22.51 10.39L14.45 2.76Q13.78 2.11 12.89 1.88Q12 1.66 11.11 1.88Q10.22 2.11 9.55 2.76L1.51 10.39Q1.27 10.61 1.27 10.92Q1.27 11.23 1.49 11.47Q1.68 11.66 2.02 11.68Q2.35 11.69 2.54 11.5L10.61 3.84Q11.21 3.26 12.01 3.26Q12.82 3.26 13.42 3.84L21.48 11.47Q21.7 11.69 22.01 11.69Q22.32 11.69 22.54 11.45Z)",
    // magnifyingglass
    R"(M17.18 16.08Q18.1 14.95 18.61 13.56Q19.13 12.17 19.13 10.68Q19.13 8.38 17.98 6.42Q16.82 4.46 14.87 3.32Q12.91 2.18 10.61 2.18Q8.3 2.18 6.35 3.32Q4.39 4.46 3.25 6.42Q2.11 8.38 2.11 10.68Q2.11 12.98 3.25 14.94Q4.39 16.9 6.35 18.04Q8.3 19.18 10.61 19.18Q12.17 19.18 13.57 18.65Q14.98 18.12 16.13 17.16L20.59 21.6Q20.81 21.82 21.12 21.82Q21.43 21.82 21.65 21.6Q21.86 21.38 21.86 21.07Q21.86 20.76 21.65 20.54L17.18 16.08ZM3.62 10.68Q3.62 8.78 4.57 7.18Q5.52 5.57 7.12 4.62Q8.71 3.67 10.61 3.67Q12.5 3.67 14.11 4.62Q15.72 5.57 16.67 7.18Q17.62 8.78 17.62 10.68Q17.62 12.58 16.67 14.18Q15.72 15.79 14.11 16.74Q12.5 17.69 10.61 17.69Q8.71 17.69 7.12 16.74Q5.52 15.79 4.57 14.18Q3.62 12.58 3.62 10.68Z)",
    // person
    R"(M12 10.97Q13.27 10.97 14.34 10.33Q15.41 9.7 16.04 8.62Q16.68 7.54 16.68 6.26Q16.68 4.99 16.04 3.91Q15.41 2.83 14.34 2.2Q13.27 1.56 12 1.56Q10.7 1.56 9.62 2.2Q8.54 2.83 7.92 3.91Q7.3 4.99 7.3 6.26Q7.3 7.54 7.92 8.62Q8.54 9.7 9.62 10.33Q10.7 10.97 12 10.97ZM12 3.05Q12.86 3.05 13.6 3.48Q14.33 3.91 14.76 4.66Q15.19 5.4 15.19 6.26Q15.19 7.13 14.76 7.86Q14.33 8.59 13.6 9.02Q12.86 9.46 12 9.46Q11.14 9.46 10.39 9.02Q9.65 8.59 9.22 7.86Q8.78 7.13 8.78 6.26Q8.78 5.4 9.22 4.66Q9.65 3.91 10.39 3.48Q11.14 3.05 12 3.05ZM18.74 22.06Q19.42 22.06 19.97 21.73Q20.52 21.41 20.84 20.86Q21.17 20.3 21.17 19.63Q21.17 17.59 19.92 15.88Q18.67 14.16 16.73 13.16Q14.78 12.17 12.79 12.17L11.18 12.17Q9.19 12.17 7.25 13.16Q5.3 14.16 4.07 15.88Q2.83 17.59 2.83 19.63Q2.83 20.3 3.16 20.86Q3.48 21.41 4.03 21.73Q4.58 22.06 5.23 22.06L18.74 22.06ZM12.79 13.68Q14.4 13.68 16 14.48Q17.59 15.29 18.62 16.66Q19.66 18.02 19.66 19.63Q19.66 20.02 19.39 20.29Q19.13 20.57 18.74 20.57L5.26 20.57Q4.87 20.57 4.6 20.29Q4.32 20.02 4.32 19.63Q4.32 18.02 5.35 16.66Q6.38 15.29 7.99 14.48Q9.6 13.68 11.21 13.68L12.79 13.68Z)",
};

// 页签内容颜色（对齐参考实现的 TabContentSelected / TabContentUnselected）
constexpr uint32_t kTabSelectedRgb = 0x00007DFF;    // #007DFF
constexpr uint32_t kTabUnselectedRgb = 0x00000000;  // 黑
constexpr float kTabIconGapDp = 2.0f;               // TabIconLabelGap（图标尺寸走参数 id 83）
constexpr float kTabIconBoldStroke = 0.8f;          // TabIconBoldStroke（24 视口单位）

GlesRenderer &GlesRenderer::Instance() {
    static GlesRenderer instance;
    return instance;
}

void GlesRenderer::OnSurfaceCreated(void *nativeWindow, uint64_t width, uint64_t height, const std::string& id) {
    if (!id.empty()) {
        std::lock_guard<std::mutex> lock(commandMutex_);
        ConsumerCommand cmd;
        cmd.isAdd = true;
        cmd.consumer.id = id;
        cmd.consumer.nativeWindow = nativeWindow;
        commandQueue_.push_back(cmd);
    }
    OnSurfaceDestroyed();

    width_.store(width);
    height_.store(height);
    stopRequested_.store(false);
    running_.store(true);
    RequestRedraw();
    lastDrawMs_ = 0;
    // 控件实例首帧必定要画（背景 + 当前状态），把休眠标记立起来
    RequestRender();
    thread_ = std::thread(&GlesRenderer::RenderLoop, this, nativeWindow);
    GLOG("surface created: %{public}llu x %{public}llu, render thread started",
         static_cast<unsigned long long>(width), static_cast<unsigned long long>(height));
}

void GlesRenderer::OnSurfaceChanged(uint64_t width, uint64_t height) {
    width_.store(width);
    height_.store(height);
    RequestRender();   // 尺寸变了要重画（含休眠中的控件）
}

bool GlesRenderer::OnSurfaceDestroyed(int timeoutMs) {
    if (thread_.joinable()) {
        SignalStop();
        GLOG("surface destroyed: joining render thread");
        if (timeoutMs < 0) {
            thread_.join();
            GLOG("surface destroyed: render thread joined");
        } else {
            const int64_t deadline = NowMs() + timeoutMs;
            while (!threadExited_.load() && NowMs() < deadline) {
                std::this_thread::sleep_for(std::chrono::milliseconds(5));
            }
            if (!threadExited_.load()) {
                GERR("surface destroyed: render thread still busy after %{public}dms",
                     timeoutMs);
                running_.store(false);
                return false;
            }
            thread_.join();
            GLOG("surface destroyed: render thread joined");
        }
    }
    running_.store(false);
    return true;
}

void GlesRenderer::SetFloat(int id, float value) {
    params_.SetNumber(id, value);
    RequestRedraw();   // 参数一变，空闲检测必须放行这一帧

    // 文字位图是 UploadLabels() 里**一次性栅格化**的（字号 / 字透明度 / 页签格内缩 /
    // 底板尺寸都参与），所以这几个参数一改就必须重建纹理，否则滑了完全没反应。
    // ticket 10 的全参数表真机扫描实测：旧实现下 id 24 / 25 / 26 滑到任何值，
    // 画面与默认值**逐像素完全相同**（因为它们只在栅格化时被读一次）。
    switch (id) {
        case pid::kLabelFontSize:
        case pid::kLabelSelectedAlpha:
        case pid::kLabelUnselectedAlpha:
        case pid::kOuterPaddingH:
        case pid::kBarHeight:
        case pid::kInnerPadding:
        case pid::kIndicatorExpand:
        case pid::kIndicatorHeight:
        case pid::kTabIconSize:
        case pid::kTabIconSizeAccent:
        case pid::kLabelFontSizeAccent:
            labelsDirty_.store(true);
            break;
        default:
            break;
    }
}

void GlesRenderer::SetBool(int id, bool value) {
    params_.SetBool(id, value);
    RequestRedraw();
}

void GlesRenderer::SetPhotoData(const void *data, size_t length) {
    if (data == nullptr || length < 8) {
        GERR("SetPhotoData: bad input (len=%{public}zu)", length);
        return;
    }
    const auto *bytes = static_cast<const unsigned char *>(data);
    uint32_t w = 0;
    uint32_t h = 0;
    memcpy(&w, bytes, 4);
    memcpy(&h, bytes + 4, 4);
    const size_t expected = 8 + static_cast<size_t>(w) * h * 4;
    if (w == 0 || h == 0 || length < expected) {
        GERR("SetPhotoData: size mismatch %{public}u x %{public}u, len=%{public}zu",
             w, h, length);
        return;
    }
    SetBackdropData(bytes + 8, length - 8, static_cast<int>(w), static_cast<int>(h),
                    static_cast<int>(w) * 4);
}

std::string GlesRenderer::ContentSurfaceId() const {
    std::lock_guard<std::mutex> lock(contentMutex_);
    return contentSurfaceId_;
}

void GlesRenderer::SetBackdropData(const void *data, size_t length, int width, int height,
                                   int srcRowBytes) {
    if (data == nullptr || width <= 0 || height <= 0 || srcRowBytes < width * 4) {
        GERR("SetBackdropData: bad geometry %{public}dx%{public}d stride=%{public}d",
             width, height, srcRowBytes);
        return;
    }
    const size_t needed = static_cast<size_t>(srcRowBytes) * static_cast<size_t>(height);
    if (length < needed) {
        GERR("SetBackdropData: short buffer len=%{public}zu need=%{public}zu", length, needed);
        return;
    }
    // 行间可能有对齐填充（PixelMap 的 stride），按行拷成紧凑 RGBA 再上传。
    const auto *src = static_cast<const unsigned char *>(data);
    const size_t rowBytes = static_cast<size_t>(width) * 4;
    {
        std::lock_guard<std::mutex> lock(photoMutex_);
        photoPixels_.resize(rowBytes * static_cast<size_t>(height));
        for (int y = 0; y < height; y++) {
            memcpy(photoPixels_.data() + static_cast<size_t>(y) * rowBytes,
                   src + static_cast<size_t>(y) * static_cast<size_t>(srcRowBytes), rowBytes);
        }
        photoW_ = width;
        photoH_ = height;
    }
    photoDirty_.store(true);
    RequestRedraw();
}

void GlesRenderer::SetBackdropShift(float dxVp, float dyVp) {
    backdropShiftX_.store(dxVp);
    backdropShiftY_.store(dyVp);
    // 位移是**跟手**的：推完立刻画，不能等下一次节拍醒来（那一下就是能看出来的滞后）。
    RequestRedraw();
}

void GlesRenderer::SetMirrorOffset(float offsetVp, bool resync) {
    mirrorOffsetVp_.store(offsetVp);
    TraceCount("GLASS_MIRROR_X100", static_cast<int64_t>(offsetVp * 100.0f));
    if (resync) {
        // 换内容（切页 / 重建）：纹理偏移跟着重置，否则会拿上一页的偏移去补。
        // held 一起重置：手里那张旧纹理本来就没意义了，别再拿它去算采样位移。
        frameMirrorOffsetVp_.store(offsetVp);
        heldMirrorOffsetVp_.store(offsetVp);
    }
}

void GlesRenderer::SetContentBand(float extraTopVp, float extraBottomVp, float shiftUpVp,
                                  float shiftDownVp) {
    contentBandExtraTopVp_.store(extraTopVp > 0.0f ? extraTopVp : 0.0f);
    contentBandExtraBottomVp_.store(extraBottomVp > 0.0f ? extraBottomVp : 0.0f);
    contentShiftUpLimitVp_.store(shiftUpVp > 0.0f ? shiftUpVp : 1.0f);
    contentShiftDownLimitVp_.store(shiftDownVp > 0.0f ? shiftDownVp : 1.0f);
    // 余量变了要重建内容纹理（EnsureTargets 的尺寸判断把余量算进去了），唤醒渲染线程。
    RequestRedraw();
    GLOG("content band: extraTop=%{public}.1fvp extraBottom=%{public}.1fvp up=%{public}.1f down=%{public}.1f",
         extraTopVp, extraBottomVp, shiftUpVp, shiftDownVp);
}

int GlesRenderer::ContentBandExtraPx() const {
    const float density = params_.Density();
    return static_cast<int>((contentBandExtraTopVp_.load() + contentBandExtraBottomVp_.load()) *
                                density + 0.5f);
}

int GlesRenderer::ContentBandBottomPx() const {
    return static_cast<int>(contentBandExtraBottomVp_.load() * params_.Density() + 0.5f);
}

void GlesRenderer::SetContentOffset(float offsetVp, float leadVp) {
    contentOffsetVp_.store(offsetVp);
    contentLeadVp_.store(leadVp);
    contentLeadMs_.store(NowMs());
    // UI 线程推偏移的时刻与取值（对齐误差分析：与 GL 帧里实际用到的偏移逐帧对照）
    TraceCount("GLASS_OFFSET_X100", static_cast<int64_t>(offsetVp * 100.0f));
    // 位移是**跟手**的：推完立刻画，不能等下一次节拍醒来（那一下就是能看出来的滞后）。
    RequestRedraw();
    if (IsHub()) {
        // 共享实时背景的消费者（玻璃弹窗）按同一偏移做补偿：没有新帧也要重画
        SharedBackdrop::Get().NotifyReaders();
    }
}

float GlesRenderer::SharedContentOffsetVp() {
    // 与 UpdateContentShift 同一套外推衰减（主树此刻的逻辑偏移 + 按时间衰减的外推）
    GlesRenderer &hub = Instance();
    const float lead = DecayedLead(hub.contentLeadVp_.load(), NowMs() - hub.contentLeadMs_.load());
    return hub.contentOffsetVp_.load() + lead;
}

void GlesRenderer::UpdateContentShift() {
    // 外推量按时间衰减：滚动停下后 reports 就断了，不衰减会留一个固定偏移。
    const float lead = DecayedLead(contentLeadVp_.load(), NowMs() - contentLeadMs_.load());
    lastLeadVp_ = lead;
    lastOffsetVp_ = contentOffsetVp_.load();
    float shift = lastOffsetVp_ + lead - heldMirrorOffsetVp_.load();
    // 非对称预算（vp，见 SetContentBand）：负 = 下拉（往纹理上沿采，余量在条带上方），
    // 正 = 底部回弹（往纹理下沿采，余量在条带下方）。预算与 ArkTS 侧的容器平移拆分同源。
    shift = std::max(-contentShiftUpLimitVp_.load(),
                     std::min(contentShiftDownLimitVp_.load(), shift));
    contentShiftVp_.store(shift);
}

void GlesRenderer::HandleContentFrameAvailable() {
    // 出帧回调 = "这一帧装的就是此刻的逻辑偏移"：锁存下来给补偿用。
    frameMirrorOffsetVp_.store(mirrorOffsetVp_.load());
    TraceCount("GLASS_LATCH_X100", static_cast<int64_t>(mirrorOffsetVp_.load() * 100.0f));
    forceRedraw_.store(true);
    NotifyFrame();
}

void GlesRenderer::SetTabs(const std::vector<std::string> &labels,
                           const std::vector<std::string> &iconPaths, uint32_t selectedArgb,
                           uint32_t unselectedArgb) {
    if (labels.size() != static_cast<size_t>(kTabCount)) {
        GERR("SetTabs: need %{public}d labels, got %{public}zu", kTabCount, labels.size());
        return;
    }
    {
        std::lock_guard<std::mutex> lock(tabConfigMutex_);
        tabConfig_.labels = labels;
        tabConfig_.icons = iconPaths;
        tabConfig_.selectedArgb = selectedArgb;
        tabConfig_.unselectedArgb = unselectedArgb;
        tabConfig_.custom = true;
    }
    {
        std::lock_guard<std::mutex> lock(animMutex_);
        // 首次配置时指示器直接落在当前选中页签上（避免从 0 弹过去）
        anim_.targetIndex = selectedTab_;
        anim_.value = static_cast<float>(selectedTab_);
        anim_.targetValue = static_cast<float>(selectedTab_);
    }
    labelsDirty_.store(true);
    RequestRedraw();   // 空闲等待不再按 16ms 轮询，改了要主动叫醒
    GLOG("SetTabs: labels=%{public}zu icons=%{public}zu sel=%{public}08x unsel=%{public}08x",
         labels.size(), iconPaths.size(), selectedArgb, unselectedArgb);
}

void GlesRenderer::SetSelectedTab(int index) {
    if (index < 0 || index >= kTabCount) {
        GERR("SetSelectedTab: index %{public}d out of range", index);
        return;
    }
    std::lock_guard<std::mutex> lock(animMutex_);
    if (selectedTab_ != index) {
        selectedTab_ = index;
        labelsDirty_.store(true);
    }
    // 指示器弹簧跟过去（外部切换也要有过渡动画，与手指拖动同一套状态机）
    anim_.dragging = false;
    anim_.targetIndex = index;
    anim_.targetValue = static_cast<float>(index);
    RequestRedraw();
}

void GlesRenderer::SetDebugMode(int mode) {
    debugMode_.store(mode);
    RequestRedraw();
}

void GlesRenderer::SetPaused(bool paused) {
    paused_.store(paused);
    // 恢复时补画一帧：暂停期间可能改过参数 / 场景 / 内容
    RequestRedraw();
}

void GlesRenderer::SetDarkMode(bool dark) {
    const bool prev = darkMode_.exchange(dark);
    if (prev != dark) {
        overlayTextDirty_.store(true);
        dialogBtnLabelDirty_.store(true);
        forceRedraw_.store(true);
        RequestRedraw();
        GLOG("dark mode changed: %{public}d -> %{public}d", prev ? 1 : 0, dark ? 1 : 0);
    }
}

void GlesRenderer::SetDialogConfig(int buttonCount, float panelHeightDp, bool custom) {
    dialogButtonCount_.store(buttonCount);
    dialogPanelHeightDp_.store(panelHeightDp);
    dialogCustom_.store(custom);
    forceRedraw_.store(true);
    RequestRedraw();
}

void GlesRenderer::SetDialogPress(int index, bool pressed) {
    if (index >= 0 && index < 2) {
        std::lock_guard<std::mutex> lock(animMutex_);
        if (pressed) {
            dialogDown_ = index;
        } else if (dialogDown_ == index) {
            dialogDown_ = -1;
        }
        forceRedraw_.store(true);
        RequestRedraw();
    }
}

void GlesRenderer::SetDialogGeometry(float cardX, float cardY, float cardW, float cardH,
                                     const std::vector<RectF> &buttons) {
    {
        std::lock_guard<std::mutex> lock(dialogGeoMutex_);
        dialogCardTopDown_ = RectF{cardX, cardY, cardW, cardH};
        dialogBtnsTopDown_ = buttons;
        dialogGeoCustom_.store(true);
    }
    forceRedraw_.store(true);
    RequestRedraw();
}

void GlesRenderer::SetDialogBackdropRect(float x, float y, float w, float h) {
    {
        std::lock_guard<std::mutex> lock(dialogGeoMutex_);
        dialogPhotoRect_ = RectF{x, y, w, h};
        dialogPhotoMapped_ = w > 1.0f && h > 1.0f;
    }
    forceRedraw_.store(true);
    RequestRedraw();
}

void GlesRenderer::SetDialogTransform(float scale, float pivotX, float pivotY) {
    {
        std::lock_guard<std::mutex> lock(dialogGeoMutex_);
        dialogXfScale_ = scale;
        dialogXfPivotX_ = pivotX;
        dialogXfPivotY_ = pivotY;
    }
    // 动效逐帧推送：按交互档节拍立刻画（与 ArkUI 文字层同帧）
    lastTouchMs_.store(NowMs());
    RequestRedraw();
}

void GlesRenderer::SetDialogLiveRect(float x, float y, float w, float h) {
    {
        std::lock_guard<std::mutex> lock(dialogGeoMutex_);
        dialogLiveRect_ = RectF{x, y, w, h};
        dialogLiveEnabled_ = w > 1.0f && h > 1.0f;
    }
    forceRedraw_.store(true);
    RequestRedraw();
}

GLint GlesRenderer::Uniform(GLuint program, const char *name) {
    const UniformKey key{program, name};
    const auto it = uniformCache_.find(key);
    if (it != uniformCache_.end()) {
        return it->second;
    }
    const GLint location = glGetUniformLocation(program, name);
    uniformCache_.emplace(key, location);
    return location;
}

void GlesRenderer::SignalStop() {
    // 置位放在等待方的互斥量下（不丢唤醒，见 NotifyFrame），两种等待都要叫醒：
    // 页签 / 弹窗实例睡在空闲 / 暂停 / 节拍等待上（frameWaitCv_，空闲最长 kIdleWaitMs），
    // 内联控件睡在按需渲染的等待上（widgetWaitCv_）。叫不醒的话 UI 线程的 join 要陪它睡满超时。
    {
        std::lock_guard<std::mutex> lock(frameWaitMutex_);
        stopRequested_.store(true);
    }
    frameWaitCv_.notify_all();
    {
        // 空临界区：等 WaitWidgetIdle 判完谓词挂起后再 notify
        std::lock_guard<std::mutex> lock(widgetWaitMutex_);
    }
    widgetWaitCv_.notify_all();
}

void GlesRenderer::NotifyFrame() {
    {
        // 置位放在等待方的互斥量下：WaitFrame 在锁里判谓词再挂起，置位若落在"谓词已判 false、
        // 尚未挂起"之间，这次唤醒就丢了，渲染线程要睡满超时（空闲等待 kIdleWaitMs）才看到新输入
        std::lock_guard<std::mutex> lock(frameWaitMutex_);
        frameDirty_.store(true);
    }
    frameWaitCv_.notify_all();
}

bool GlesRenderer::WaitFrame(int timeoutMs) {
    std::unique_lock<std::mutex> lock(frameWaitMutex_);
    return frameWaitCv_.wait_for(lock, std::chrono::milliseconds(timeoutMs), [this] {
        return frameDirty_.exchange(false) || stopRequested_.load();
    });
}

bool GlesRenderer::PaceFrame() {
    int64_t waitMs = 0;   // lastDrawMs_ == 0 = 被信号打断过的一帧：不节拍，立即画
    if (lastDrawMs_ != 0) {
        const int64_t now = NowMs();
        const bool interacting = (now - lastTouchMs_.load()) < kInteractiveWindowMs;
        const int64_t intervalMs = interacting ? kInteractiveFrameMs : kNormalFrameMs;
        const int64_t due = lastDrawMs_ + intervalMs;
        waitMs = due > now ? due - now : 0;
    }
    bool hot = false;
    {
        TraceScope trace("GL:pace");
        hot = WaitFrame(static_cast<int>(waitMs));
    }
    lastDrawMs_ = NowMs();   // 用睡醒后的真实时刻，避免误差累积
    return hot;
}

void GlesRenderer::CreateVsync() {
    if (vsync_ != nullptr) {
        return;
    }
    const char name[] = "glass_vsync";
    vsyncNs_.store(0);
    vsyncPeriodNs_.store(0);
    lastRenderVsyncNs_ = -1;
    periodQueriedVsyncNs_ = -1;
    {
        std::lock_guard<std::mutex> lock(gVsyncOwnersMutex);
        gVsyncOwners.insert(this);
    }
    vsync_ = OH_NativeVSync_Create(name, static_cast<unsigned int>(sizeof(name) - 1));
    if (vsync_ == nullptr) {
        GERR("OH_NativeVSync_Create failed: fall back to timer pacing");
    }
}

void GlesRenderer::DestroyVsync() {
    {
        // 先注销：此后到达的回调一律不碰本对象
        std::lock_guard<std::mutex> lock(gVsyncOwnersMutex);
        gVsyncOwners.erase(this);
    }
    if (vsync_ != nullptr) {
        OH_NativeVSync_Destroy(vsync_);
        vsync_ = nullptr;
    }
}

void GlesRenderer::RequestVsync() {
    if (vsync_ != nullptr) {
        OH_NativeVSync_RequestFrame(vsync_, &GlesRenderer::OnVsyncCallback, this);
    }
}

void GlesRenderer::OnVsyncCallback(long long timestamp, void *data) {
    // vsync 线程：只记时间戳并叫醒渲染线程（不置 frameDirty_：空闲等待不会被它唤醒）。
    // 持锁访问：渲染器注销（DestroyVsync）之后的迟到回调直接丢弃。周期由渲染线程查询。
    std::lock_guard<std::mutex> lock(gVsyncOwnersMutex);
    if (data == nullptr || gVsyncOwners.count(data) == 0) {
        return;
    }
    auto *self = static_cast<GlesRenderer *>(data);
    {
        // 与节拍等待的谓词检查互斥（不丢唤醒，见 NotifyFrame）
        std::lock_guard<std::mutex> waitLock(self->frameWaitMutex_);
        self->vsyncNs_.store(timestamp);
    }
    self->frameWaitCv_.notify_all();
}

bool GlesRenderer::WaitForRenderSlot() {
    if (vsync_ == nullptr) {
        // 没有 vsync：退回时间节拍（被信号打断时下一轮不再等节拍）
        if (PaceFrame()) {
            lastDrawMs_ = 0;
            return false;
        }
        return true;
    }
    const int64_t vs = vsyncNs_.load();
    if (vs > 0 && vs != periodQueriedVsyncNs_) {
        // 周期只在拿到新回调后才会刷新（LTPO 会在 120/90/60Hz 间切换），渲染线程自己查
        periodQueriedVsyncNs_ = vs;
        long long periodNs = 0;
        if (OH_NativeVSync_GetPeriod(vsync_, &periodNs) == 0 && periodNs > 0) {
            vsyncPeriodNs_.store(periodNs);
        }
    }
    const int64_t period = vsyncPeriodNs_.load();
    const int64_t now = MonoNs();
    if (!vsyncClockLogged_ && vs > 0) {
        vsyncClockLogged_ = true;
        GLOG("vsync: period=%{public}lldns now-vsync=%{public}lldus",
             static_cast<long long>(period), static_cast<long long>((now - vs) / 1000));
    }
    if (period <= 0 || vs <= 0 || now - vs > 2 * period) {
        // vsync 信息不新鲜（刚起步 / 空闲后的第一帧）：直接画，同时请求 vsync 把节拍接上
        RequestVsync();
        return true;
    }
    const int64_t phase = std::max(kRenderPhaseMinNs, std::min(kRenderPhaseMaxNs, period * 2 / 5));
    const bool used = lastRenderVsyncNs_ == vs;
    const bool late = now - vs > period - kRenderLateMarginNs;
    if (!used && !late) {
        const int64_t target = vs + phase;
        if (now >= target) {
            return true;
        }
        // 等到 vsync + δ：本周期的主树偏移 / 镜像帧在这之前陆续到齐（信号不打断，到点一起画）
        TraceScope trace("GL:phase");
        std::unique_lock<std::mutex> lock(frameWaitMutex_);
        frameWaitCv_.wait_for(lock, std::chrono::nanoseconds(target - now),
                              [this] { return stopRequested_.load(); });
        return false;
    }
    // 本周期已画过 / 来不及赶上这次取走：等下一个 vsync（回调会换掉 vsyncNs_）
    RequestVsync();
    TraceScope trace("GL:vsync");
    std::unique_lock<std::mutex> lock(frameWaitMutex_);
    frameWaitCv_.wait_for(lock, std::chrono::nanoseconds(2 * period), [this, vs] {
        return vsyncNs_.load() != vs || stopRequested_.load();
    });
    return false;
}

void GlesRenderer::SetScene(int scene) {
    if (scene < 0 || scene >= static_cast<int>(Scene::kCount)) {
        GERR("SetScene: id %{public}d out of range", scene);
        return;
    }
    const int previous = scene_.exchange(scene);
    if (previous == scene) {
        return;
    }
    ResetCatalogState(scene);
    RequestRedraw();
    GLOG("scene changed: %{public}d -> %{public}d", previous, scene);
}

void GlesRenderer::ResetCatalogState(int scene) {
    std::lock_guard<std::mutex> lock(animMutex_);
    for (int i = 0; i < kScenePressMax; i++) {
        scenePress_[i] = 0.0f;
        scenePressVel_[i] = 0.0f;
    }
    sceneDown_ = -1;

    toggleFraction_ = toggleOn_ ? 1.0f : 0.0f;
    toggleFractionVel_ = 0.0f;
    togglePress_ = 0.0f;
    togglePressVel_ = 0.0f;
    toggleDragging_ = false;
    toggleDidDrag_ = false;

    sliderPress_ = 0.0f;
    sliderPressVel_ = 0.0f;
    sliderDragging_ = false;
    sliderDidDrag_ = false;
    sliderValueAnim_ = sliderValue_;
    sliderValueAnimVel_ = 0.0f;
    sliderValueAnimLast_ = sliderValue_;
    sliderVelocity_ = 0.0f;
    sliderVelocityVel_ = 0.0f;

    dialogPress_[0] = dialogPress_[1] = 0.0f;
    dialogPressVel_[0] = dialogPressVel_[1] = 0.0f;
    dialogDown_ = -1;

    ccProgress_ = 1.0f;
    ccProgressVel_ = 0.0f;
    ccDragging_ = false;

    lockOffsetX_ = 0.0f;
    lockOffsetY_ = 0.0f;
    lockDragging_ = false;

    magInited_ = false;
    magDragging_ = false;

    listScroll_ = 0.0f;
    listScrollVel_ = 0.0f;
    listDragging_ = false;

    pgInited_ = false;
    pgDragging_ = false;
    pgSheetOpen_ = true;
    pgSliderDown_ = -1;
    const float sliderDefaults[5] = {0.5f, 0.0f, 0.2f, 0.2f, 0.0f};
    for (int i = 0; i < 5; i++) {
        pgSliderValue_[i] = sliderDefaults[i];
        pgSliderPress_[i] = 0.0f;
        pgSliderPressVel_[i] = 0.0f;
    }
    pgButtonDown_ = -1;
    for (int i = 0; i < 2; i++) {
        pgButtonPress_[i] = 0.0f;
        pgButtonPressVel_[i] = 0.0f;
    }

    lumValue_ = 0.25f;
    lumTarget_ = 0.25f;
    lumVel_ = 0.0f;
    lumSampleMs_ = 0;
    lumShown_ = -1;
    lumTextMs_ = 0;

    contentTextDirty_.store(true);
    overlayTextDirty_.store(true);
    GLOG("catalog state reset for scene %{public}d", scene);
}

// ---------------------------------------------------------------------------
// 指示器动画（S3）
// ---------------------------------------------------------------------------

float GlesRenderer::IndicatorEndInsetPx() const {
    // 参考实现: capInsetDp = ((panel.barHeight - indicator.indicatorHeight) / 2).coerceAtLeast(0)
    return std::max(0.0f, (params_.Px(pid::kBarHeight) - params_.Px(pid::kIndicatorHeight)) * 0.5f);
}

float GlesRenderer::TabInnerPadPx() const {
    // 参考实现: innerPaddingDp = max(panel.panelInnerPadding, capInsetDp + indicator.indicatorExpand)
    return std::max(params_.Px(pid::kInnerPadding),
                    IndicatorEndInsetPx() + params_.Px(pid::kIndicatorExpand));
}

/** 触摸 x -> 连续页签位置 0..2（屏幕坐标，与 GL 同一套 x） */
float GlesRenderer::TabValueFromX(float x, int surfaceW) const {
    const float barW = static_cast<float>(surfaceW) - params_.Px(pid::kOuterPaddingH) * 2.0f;
    const float innerPad = TabInnerPadPx();
    const float tabW = (barW - innerPad * 2.0f) / 3.0f;
    // tabW 可能被极端参数（外边距拉满 + 内缩拉满）压到 0 甚至负数，
    // 那时候这一帧不做位移，避免除零产生 NaN/Inf 污染 anim_。
    if (tabW < 1.0f) {
        return 1.0f;  // 0..2 的正中（页签数 3）；不改变指示器位置
    }
    const float local = x - (params_.Px(pid::kOuterPaddingH) + innerPad);
    return local / tabW - 0.5f;
}

// ---------------------------------------------------------------------------
// 顶部三个玻璃按钮（几何）
// ---------------------------------------------------------------------------

float GlesRenderer::ButtonSizePx() const {
    return params_.Px(pid::kIconButtonSize);
}

float GlesRenderer::ButtonSpacingPx() const {
    return kIconButtonSpacingDp * params_.Density();
}

void GlesRenderer::ButtonRectPx(int index, int surfaceW, int surfaceH, float *left,
                                float *bottom) const {
    const float size = ButtonSizePx();
    const float spacing = ButtonSpacingPx();
    const float padH = kIconButtonPaddingH * params_.Density();
    const float padV = kIconButtonPaddingV * params_.Density();
    const float w = static_cast<float>(surfaceW);
    const float h = static_cast<float>(surfaceH);
    // 从右往左排：index 2（更多）贴右上角，index 0（拖动）在最左
    const int fromRight = kIconButtonCount - 1 - index;
    if (left != nullptr) {
        *left = w - padH - static_cast<float>(fromRight) * (size + spacing) - size;
    }
    if (bottom != nullptr) {
        *bottom = h - padV - size;   // GL 坐标：y 从底部起算
    }
}

bool GlesRenderer::HitButton(float touchX, float touchY, int surfaceW, int surfaceH,
                             int *index) const {
    const float size = ButtonSizePx();
    if (size <= 0.0f) {
        return false;
    }
    const float glY = static_cast<float>(surfaceH) - touchY;   // 触摸 y 从顶部起算
    for (int i = 0; i < kIconButtonCount; i++) {
        float left = 0.0f;
        float bottom = 0.0f;
        ButtonRectPx(i, surfaceW, surfaceH, &left, &bottom);
        if (touchX >= left && touchX <= left + size && glY >= bottom && glY <= bottom + size) {
            if (index != nullptr) {
                *index = i;
            }
            return true;
        }
    }
    return false;
}

void GlesRenderer::UpdateAnim(float dt) {
    if (dt <= 0.0f) return;
    if (dt > 0.05f) dt = 0.05f;   // 夹一下，避免掉帧时弹簧炸掉

    std::lock_guard<std::mutex> lock(animMutex_);

    // ---- value：弹簧追赶目标（拖动 = 触摸位置；松手 = 最近页签）----
    // 拖动时不做瞬移：按下 / 移动都通过同一根弹簧产生过渡位移动画。
    // 目标是绝对位置（手指），所以不存在累积偏移，划出页签条再划回来也不会和手指错位。
    {
        const float target =
            anim_.dragging ? anim_.targetValue : static_cast<float>(anim_.targetIndex);
        SpringStep(anim_.value, anim_.valueVelocity, target, params_.N(pid::kDragValueStiffness),
                   params_.N(pid::kDragValueDamping), dt);
    }

    // ---- speed：弹簧平滑后的速度，驱动拉伸/压扁形变（参数 56/57）----
    // 口径对齐参考实现的 DampedDragAnimation.updateVelocity()：
    // VelocityTracker 给出的是 value 单位/秒，再除以 valueRange 的跨度（0..2）。
    // 本帧的位移在 OnTouch 里累积到 moveAccum_，这里换算成"每秒"再除以 2；
    // 松手后目标回 0（参考实现那边速度停在最后一次的值，这里取衰减到 0，
    // 否则拖动结束后形变会一直挂着）。
    {
        const float rate = dt > 0.0f ? (moveAccum_ / dt) : 0.0f;
        moveAccum_ = 0.0f;
        const float target = anim_.dragging ? (rate * 0.5f) : 0.0f;
        SpringStep(anim_.speed, anim_.speedVelocity, target,
                   params_.N(pid::kDragVelocityStiffness), params_.N(pid::kDragVelocityDamping),
                   dt);
        if (std::fabs(anim_.speed) < 0.01f && std::fabs(target) < 0.01f) {
            anim_.speed = 0.0f;
            anim_.speedVelocity = 0.0f;
        }
    }

    // ---- 底板视差：拖动时累积、松手弹簧回零（对齐参考实现的 offsetAnimation + panelOffset）----
    {
        if (anim_.dragging) {
            parallaxVel_ = 0.0f;
        } else {
            const float k = params_.N(pid::kPanelReturnStiffness);
            const float ratio = params_.N(pid::kPanelReturnDamping);
            const float c = 2.0f * std::sqrt(k) * ratio;
            const float accel = -k * parallaxAccum_ - c * parallaxVel_;
            parallaxVel_ += accel * dt;
            const float parallaxDelta = parallaxVel_ * dt;
            parallaxAccum_ += parallaxDelta;
            gSpringMotion += std::fabs(parallaxDelta);
            if (std::fabs(parallaxAccum_) < 0.5f) {
                parallaxAccum_ = 0.0f;
                parallaxVel_ = 0.0f;
            }
        }
        const float maxW = static_cast<float>(width_.load());
        float fraction = (maxW > 0.0f) ? (parallaxAccum_ / maxW) : 0.0f;
        fraction = std::max(-1.0f, std::min(1.0f, fraction));
        // 参考实现用 EaseOut.transform(|fraction|)；这里用等价的标准 ease-out cubic
        const float eased = 1.0f - std::pow(1.0f - std::fabs(fraction), 3.0f);
        const float amount = params_.Px(pid::kPanelParallax);
        panelOffsetPx_.store((fraction >= 0.0f ? 1.0f : -1.0f) * amount * eased);
    }

    // ---- press：按下 1 / 松开 0，spring（pressStiffness 1000 / pressDamping 1）----
    {
        const float k = params_.N(pid::kPressStiffness);
        const float ratio = params_.N(pid::kPressDamping);
        const float c = 2.0f * std::sqrt(k) * ratio;
        const float target = anim_.dragging ? 1.0f : 0.0f;
        const float accel = -k * (anim_.press - target) - c * anim_.pressVelocity;
        anim_.pressVelocity += accel * dt;
        const float pressDelta = anim_.pressVelocity * dt;
        anim_.press += pressDelta;
        gSpringMotion += std::fabs(pressDelta);
        if (anim_.press < 0.0f) { anim_.press = 0.0f; anim_.pressVelocity = 0.0f; }
        if (anim_.press > 1.0f) { anim_.press = 1.0f; anim_.pressVelocity = 0.0f; }
    }

    // ---- scaleX / scaleY：按压缩放的**独立弹簧**（参数 60..63）----
    // 对齐参考实现的 DampedDragAnimation：press() 里把两个 scale 弹到 pressedScale，
    // release() 里弹回 1（初始缩放）。之前 GL 侧是"press 进度 × 目标值"直接换算，
    // 少了这层弹簧 —— 观感上按下去/弹回来都会"硬"一档。
    // 横纵目标分开：id 82（横向）/ id 51（纵向），默认同值 → 等比，与旧观感一致。
    {
        const float targetX = anim_.dragging ? params_.N(pid::kPressedScaleX) : 1.0f;
        const float targetY = anim_.dragging ? params_.N(pid::kPressedScale) : 1.0f;
        SpringStep(anim_.scaleX, anim_.scaleXVelocity, targetX, params_.N(pid::kScaleXStiffness),
                   params_.N(pid::kScaleXDamping), dt);
        SpringStep(anim_.scaleY, anim_.scaleYVelocity, targetY, params_.N(pid::kScaleYStiffness),
                   params_.N(pid::kScaleYDamping), dt);
        // 防御：极端参数（pressedScale 1.8）下也不让缩放变成 0 或负
        anim_.scaleX = std::max(0.1f, anim_.scaleX);
        anim_.scaleY = std::max(0.1f, anim_.scaleY);
    }

    // ---- 跟手光斑：按压进度有独立弹簧（参数 31/32）----
    SpringStep(glowPress_, glowPressVelocity_, anim_.dragging ? 1.0f : 0.0f,
               params_.N(pid::kGlowPressStiffness), params_.N(pid::kGlowPressDamping), dt);
    if (glowPress_ < 0.0f) { glowPress_ = 0.0f; glowPressVelocity_ = 0.0f; }
    if (glowPress_ > 1.0f) { glowPress_ = 1.0f; glowPressVelocity_ = 0.0f; }

    // ---- 顶部三个玻璃按钮：按压缩放弹簧（参数 29/30）----
    for (int i = 0; i < kIconButtonCount; i++) {
        SpringStep(btnPress_[i], btnPressVelocity_[i], (btnDownIndex_ == i) ? 1.0f : 0.0f,
                   params_.N(pid::kIconPressStiffness), params_.N(pid::kIconPressDamping), dt);
        if (btnPress_[i] < 0.0f) { btnPress_[i] = 0.0f; btnPressVelocity_[i] = 0.0f; }
        if (btnPress_[i] > 1.0f) { btnPress_[i] = 1.0f; btnPressVelocity_[i] = 0.0f; }
    }
}

GlesRenderer::SpringSettle GlesRenderer::SettleSprings() {
    std::lock_guard<std::mutex> lock(animMutex_);
    const bool dragging = anim_.dragging;
    const float valueTarget = dragging ? anim_.targetValue : static_cast<float>(anim_.targetIndex);
    const float pressTarget = dragging ? 1.0f : 0.0f;
    const float scaleXTarget = dragging ? params_.N(pid::kPressedScaleX) : 1.0f;
    const float scaleYTarget = dragging ? params_.N(pid::kPressedScale) : 1.0f;
    const auto near = [](float value, float target, float tolerance) {
        return std::fabs(value - target) <= tolerance;
    };
    // 先确认每根弹簧都贴着目标：欠阻尼弹簧（缩放 / 光斑）在折返点速度过零，速率判据会在那里
    // 误判"停了"，这时离目标可能还差好几个像素，对齐就是一跳 —— 返回 kFar，循环当它还在动。
    bool allNear = near(anim_.value, valueTarget, kSettleGeometryTolerance) &&
                   near(anim_.scaleX, scaleXTarget, kSettleGeometryTolerance) &&
                   near(anim_.scaleY, scaleYTarget, kSettleGeometryTolerance) &&
                   // 拖动中速度目标跟手指走，不参与
                   (dragging || near(anim_.speed, 0.0f, kSettleGeometryTolerance)) &&
                   near(anim_.press, pressTarget, kSettleLevelTolerance) &&
                   near(glowPress_, pressTarget, kSettleLevelTolerance);
    for (int i = 0; i < kIconButtonCount; i++) {
        allNear = allNear &&
                  near(btnPress_[i], (btnDownIndex_ == i) ? 1.0f : 0.0f, kSettleLevelTolerance);
    }
    // 弹窗：按钮按压（入场缩放见下）
    for (int i = 0; i < 2; i++) {
        allNear = allNear &&
                  near(dialogPress_[i], (dialogDown_ == i) ? 1.0f : 0.0f, kSettleLevelTolerance);
    }
    allNear = allNear && near(dialogScale_, 1.0f, kSettleScaleTolerance);
    if (!allNear) {
        return SpringSettle::kFar;
    }
    bool changed = false;
    const auto snap = [&changed](float &value, float &velocity, float target) {
        if (std::fabs(value - target) > 1e-6f) {
            changed = true;
        }
        value = target;
        velocity = 0.0f;
    };
    snap(anim_.value, anim_.valueVelocity, valueTarget);
    if (!dragging) {
        snap(anim_.speed, anim_.speedVelocity, 0.0f);
    }
    snap(anim_.press, anim_.pressVelocity, pressTarget);
    snap(anim_.scaleX, anim_.scaleXVelocity, scaleXTarget);
    snap(anim_.scaleY, anim_.scaleYVelocity, scaleYTarget);
    snap(glowPress_, glowPressVelocity_, pressTarget);
    for (int i = 0; i < kIconButtonCount; i++) {
        snap(btnPress_[i], btnPressVelocity_[i], (btnDownIndex_ == i) ? 1.0f : 0.0f);
    }
    for (int i = 0; i < 2; i++) {
        snap(dialogPress_[i], dialogPressVel_[i], (dialogDown_ == i) ? 1.0f : 0.0f);
    }
    snap(dialogScale_, dialogScaleVel_, 1.0f);
    return changed ? SpringSettle::kSnapped : SpringSettle::kExact;
}

// ===========================================================================
// 目录场景：几何 / 动画 / 触摸
//
// 坐标约定：所有 RectF 都是 **GL 坐标**（y 从屏幕底部起算），与 DrawGlass 一致；
// 需要"自上而下"排版时用 `screenH - y - h` 换过来。
// ===========================================================================

namespace {

bool RectHit(const RectF &r, float x, float y, float pad = 0.0f) {
    return x >= r.x - pad && x <= r.x + r.w + pad && y >= r.y - pad && y <= r.y + r.h + pad;
}

const char *kButtonLabels[4] = {
    "Transparent Liquid Button",
    "Surface Liquid Button",
    "Tinted Liquid Button",
    "Tinted Liquid Button",
};

const char *kLoremIpsum =
    "Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod tempor incididunt ut "
    "labore et dolore magna aliqua. Ut enim ad minim veniam, quis nostrud exercitation ullamco "
    "laboris nisi ut aliquip ex ea commodo consequat. Duis aute irure dolor in reprehenderit in "
    "voluptate velit esse cillum dolore eu fugiat nulla pariatur. Excepteur sint occaecat "
    "cupidatat non proident, sunt in culpa qui officia deserunt mollit anim id est laborum.";

RectF ButtonRectAt(int screenW, int screenH, float d, int index) {
    const float btnH = 48.0f * d;
    const float gap = 16.0f * d;
    const float textW = MeasureTextWidth(kButtonLabels[index], 15.0f * d, false);
    RectF r;
    r.w = textW + 32.0f * d;
    r.h = btnH;
    r.x = (static_cast<float>(screenW) - r.w) * 0.5f;
    const float total = 4.0f * btnH + 3.0f * gap;
    const float topDown =
        (static_cast<float>(screenH) - total) * 0.5f + static_cast<float>(index) * (btnH + gap);
    r.y = static_cast<float>(screenH) - topDown - btnH;
    return r;
}

RectF ToggleTrackRect(int screenW, int screenH, float d) {
    RectF r;
    r.w = 64.0f * d;
    r.h = 28.0f * d;
    r.x = (static_cast<float>(screenW) - r.w) * 0.5f;
    r.y = (static_cast<float>(screenH) - r.h) * 0.5f;
    return r;
}

RectF ToggleKnobRect(int screenW, int screenH, float d, float fraction) {
    const RectF t = ToggleTrackRect(screenW, screenH, d);
    RectF r;
    // 比参考实现的 40dp 窄一点（按压放大 1.7 后 ≈ 61dp，与 64dp 的轨道基本齐宽）
    r.w = 36.0f * d;
    r.h = 24.0f * d;
    // 两端留 2dp 内缩（与上下 2dp 相同）：旋钮端头圆弧与轨道端头圆弧**同心**，
    // 圆角视觉一致；行程 = 轨道宽 - 2*2dp - 旋钮宽 = 24dp
    r.x = t.x + 2.0f * d + fraction * (t.w - 4.0f * d - r.w);
    r.y = t.y + (t.h - r.h) * 0.5f;
    return r;
}

RectF SliderTrackRect(int screenW, int screenH, float d) {
    RectF r;
    r.w = static_cast<float>(screenW) - 64.0f * d;
    r.h = 6.0f * d;
    r.x = 32.0f * d;
    r.y = (static_cast<float>(screenH) - r.h) * 0.5f;
    return r;
}

// ---------------------------------------------------------------------------
// HallPass 内联玻璃控件（开关 / 滑块）的几何
//
// 控件 surface 由 ArkUI 排版给定（见 GlassToggle / GlassSlider），原生只按 dp 摆件：
// - 开关：**demo 形状的等比缩小版**——轨道 44×18dp 居中、旋钮 22×14dp 沿轨道
//   内缩 2dp 滑行（宽胶囊，不是系统 Switch 的圆点）；surface 左右各留
//   kWigTogglePadX 的余量，否则按压放大 1.9 的旋钮在两端会被 surface 裁掉。
//   ⚠️ 内缩必须保持 2dp：旋钮端头圆心 = 轨道端头圆心（2 + 7 = 9 = 轨道半高），
//   两端圆弧才同心、视觉圆角统一；改轨道宽只动 kWigToggleTrackW。
// - 滑块：轨道两端内缩 kWigSliderInsetDp（给按压放大 / 速度形变的旋钮留余量），
//   旋钮 40×24dp，中心在 [x+20dp, x+w-20dp] 内钳制（旋钮本体不越出轨道）。
// ---------------------------------------------------------------------------

constexpr float kWigToggleTrackW = 44.0f;
constexpr float kWigToggleTrackH = 18.0f;
constexpr float kWigToggleKnobW = 22.0f;
constexpr float kWigToggleKnobH = 14.0f;
/** 开关 surface 的左右留白（dp）：按压放大后旋钮两端外伸 ≈ 0.35×旋钮宽 − 2dp。 */
constexpr float kWigTogglePadX = 8.0f;
/**
 * 开关旋钮按压投影的**等比缩放系数**（几何 + 强度）。
 *
 * 按压观感对齐滑块指示器（见 DrawSliderCore 的 HallPass 段）：滑块按压态的投影几何
 * 余量 = 模糊 7dp + 下移 1dp = 8dp；而开关 surface 高 30vp、按压旋钮 14 × 1.9 =
 * 26.6vp，下方只剩 (30 − 26.6) / 2 ≈ 1.7vp —— 原样照搬会在 surface 下缘裁出一条硬边。
 * 1.7 / 8 ≈ 0.21：模糊 / 下移 / 强度一起缩到放得下。
 * 想要满强度的投影：把 surface 加高（GlassWidgetCommon 的 GLASS_TOGGLE_HEIGHT 同改），
 * 系数随之上调。
 */
constexpr float kToggleShadowFit = 0.21f;
// 滑块（内联控件）：demo 尺寸（旋钮 40×24 / 轨道 6dp）整体收 ~0.85×
constexpr float kWigSliderKnobW = 34.0f;
constexpr float kWigSliderKnobH = 20.0f;
constexpr float kWigSliderTrackH = 5.0f;
/** 轨道两端内缩（dp）：≥ 按压 + 速度形变后旋钮的外伸量，避免被 surface 裁掉。 */
constexpr float kWigSliderInsetDp = 18.0f;
/** 旋钮中心钳制边距（dp）= 旋钮半宽：旋钮本体不越出轨道。 */
constexpr float kWigSliderKnobMarginDp = 17.0f;

/** 滑块旋钮：widget=true 时按内联控件几何（缩小版），目录场景仍是 demo 尺寸。 */
RectF SliderKnobRectFor(const RectF &track, int surfaceH, float d, float progress, bool widget) {
    RectF r;
    r.w = (widget ? kWigSliderKnobW : 40.0f) * d;
    r.h = (widget ? kWigSliderKnobH : 24.0f) * d;
    const float margin = (widget ? kWigSliderKnobMarginDp : 10.0f) * d;
    const float centerX = track.x + track.w * progress;
    const float clamped =
        std::max(track.x + margin, std::min(track.x + track.w - margin, centerX));
    r.x = clamped - r.w * 0.5f;
    r.y = (static_cast<float>(surfaceH) - r.h) * 0.5f;
    return r;
}

RectF DialogPanelRect(int screenW, int screenH, float d, float customH = 0.0f) {
    RectF r;
    const float padH = 20.0f * d;
    const float maxW = 380.0f * d;
    const float availW = static_cast<float>(screenW) - padH * 2.0f;
    r.w = std::min(availW, maxW);
    r.x = (static_cast<float>(screenW) - r.w) * 0.5f;
    if (customH > 0.0f) {
        r.h = customH * d;
    } else {
        // 顶部内边距 26dp + 标题2行 (~44dp) + 间距 10dp + 正文2行 (~37dp) + 间距 24dp + 按钮 50dp + 底部内边距 18dp = 209dp
        r.h = (26.0f + 44.0f + 10.0f + 37.0f + 24.0f + 50.0f + 18.0f) * d;
    }
    r.y = (static_cast<float>(screenH) - r.h) * 0.5f;
    return r;
}

void DialogButtonRects(int screenW, int screenH, float d, int buttonCount, RectF *out, float customH = 0.0f) {
    const RectF p = DialogPanelRect(screenW, screenH, d, customH);
    const float pad = 18.0f * d;
    const float btnH = 50.0f * d;
    const float btnY = p.y + 18.0f * d;
    if (buttonCount == 1) {
        out[0] = RectF{p.x + pad, btnY, p.w - pad * 2.0f, btnH};
    } else if (buttonCount >= 2) {
        const float gap = 12.0f * d;
        const float btnW = (p.w - pad * 2.0f - gap) * 0.5f;
        out[0] = RectF{p.x + pad, btnY, btnW, btnH};
        out[1] = RectF{p.x + pad + btnW + gap, btnY, btnW, btnH};
    }
}

void DialogButtonRects(int screenW, int screenH, float d, RectF *out) {
    DialogButtonRects(screenW, screenH, d, 1, out, 0.0f);
}

RectF LockPanelRect(int screenW, int screenH, float d) {
    RectF r;
    r.w = 300.0f * d;
    r.h = 170.0f * d;
    r.x = (static_cast<float>(screenW) - r.w) * 0.5f;
    const float topDown = static_cast<float>(screenH) * 0.26f;
    r.y = static_cast<float>(screenH) - topDown - r.h;
    return r;
}

RectF MagCardRect(int screenW, int screenH, float d) {
    RectF r;
    r.x = 24.0f * d;
    r.w = static_cast<float>(screenW) - 48.0f * d;
    r.h = 380.0f * d;
    r.y = static_cast<float>(screenH) - 24.0f * d - r.h;
    return r;
}

RectF MagLensRect(float magX, float magY, float d) {
    RectF r;
    r.w = 128.0f * d;
    r.h = 96.0f * d;
    r.x = magX - r.w * 0.5f;
    r.y = magY + 32.0f * d;
    return r;
}

RectF MagCursorRect(float magX, float magY, float d) {
    RectF r;
    r.w = 4.0f * d;
    r.h = 24.0f * d;
    r.x = magX - r.w * 0.5f;
    r.y = magY - r.h * 0.5f;
    return r;
}

RectF ProgBlurBandRect(int screenW, int screenH, float d) {
    RectF r;
    r.x = 0.0f;
    r.w = static_cast<float>(screenW);
    r.h = 128.0f * d;
    r.y = (static_cast<float>(screenH) - r.h) * 0.5f;
    return r;
}

RectF AdaptivePanelRect(int screenW, int screenH, float d) {
    RectF r;
    r.w = 160.0f * d;
    r.h = 160.0f * d;
    r.x = (static_cast<float>(screenW) - r.w) * 0.5f;
    r.y = (static_cast<float>(screenH) - r.h) * 0.5f;
    return r;
}

/** 滚动容器的第 i 张玻璃卡片（GL 坐标；scroll 单位 px）。 */
RectF ScrollCardRect(int index, int screenW, int screenH, float d, float scroll) {
    const float cardH = 160.0f * d;
    const float gap = 16.0f * d;
    const float pad = 16.0f * d;
    RectF r;
    r.x = pad;
    r.w = static_cast<float>(screenW) - pad * 2.0f;
    r.h = cardH;
    r.y = static_cast<float>(screenH) - (pad + static_cast<float>(index) * (cardH + gap) - scroll) -
          cardH;
    return r;
}

float ScrollContentHeight(int count, float d) {
    const float cardH = 160.0f * d;
    const float gap = 16.0f * d;
    return 16.0f * d * 2.0f + static_cast<float>(count) * cardH +
           static_cast<float>(count - 1) * gap;
}

RectF PgPanelRect(int screenW, int screenH, float d) {
    RectF r;
    r.w = 256.0f * d;
    r.h = 256.0f * d;
    r.x = (static_cast<float>(screenW) - r.w) * 0.5f;
    // 顶部留 96dp：参考实现是 48dp + statusBars；这里再让开 ArkUI 的返回按钮
    r.y = static_cast<float>(screenH) - 96.0f * d - r.h;
    return r;
}

RectF PgSheetRect(int screenW, int screenH, float d) {
    (void)screenW;
    (void)screenH;
    RectF r;
    r.x = 16.0f * d;
    r.w = (screenW > 0 ? static_cast<float>(screenW) : 0.0f) - 32.0f * d;
    r.h = 332.0f * d;
    r.y = 72.0f * d;
    return r;
}

/** 游乐场滑块的"整行"矩形（含标签下方 24dp 的交互高度）。 */
RectF PgSliderRowRect(int index, int screenW, int screenH, float d) {
    const RectF s = PgSheetRect(screenW, screenH, d);
    const float pad = 24.0f * d;
    const float labelH = 15.0f * d * 1.35f;
    const float rowH = 24.0f * d;
    const float gap = 16.0f * d;
    const float yTop = s.y + s.h - pad - static_cast<float>(index) * (labelH + rowH + gap);
    const float rowY = yTop - labelH - rowH;
    return RectF{s.x + pad, rowY, s.w - pad * 2.0f, rowH};
}

const char *PgButtonLabel(int index, bool sheetOpen) {
    if (index == 0) {
        return sheetOpen ? "Hide" : "Show";
    }
    return "Reset";
}

RectF PgButtonRect(int index, bool sheetOpen, int screenW, int screenH, float d) {
    const char *label = PgButtonLabel(index, sheetOpen);
    const float textW = MeasureTextWidth(label, 15.0f * d, false);
    RectF r;
    r.w = textW + 32.0f * d;
    r.h = 48.0f * d;
    r.y = 20.0f * d;
    r.x = (index == 0) ? 20.0f * d : static_cast<float>(screenW) - 20.0f * d - r.w;
    (void)screenH;
    return r;
}

}  // namespace

void GlesRenderer::UpdateCatalogAnim(float dt) {
    if (dt <= 0.0f) {
        return;
    }
    if (dt > 0.05f) {
        dt = 0.05f;
    }
    const int scene = scene_.load();
    if (scene == static_cast<int>(Scene::kTabs)) {
        return;
    }

    std::lock_guard<std::mutex> lock(animMutex_);
    switch (scene) {
        case static_cast<int>(Scene::kButtons): {
            // InteractiveHighlight 的按压弹簧：spring(0.5, 300)
            for (int i = 0; i < 4; i++) {
                SpringStep(scenePress_[i], scenePressVel_[i], (sceneDown_ == i) ? 1.0f : 0.0f,
                           300.0f, 0.5f, dt);
                if (scenePress_[i] < 0.0f) { scenePress_[i] = 0.0f; scenePressVel_[i] = 0.0f; }
                if (scenePress_[i] > 1.0f) { scenePress_[i] = 1.0f; scenePressVel_[i] = 0.0f; }
            }
            break;
        }
        case static_cast<int>(Scene::kToggle): {
            // fraction 始终走弹簧：拖动时追手指映射的目标（带一点延迟/阻尼），
            // 松手后追 0/1。刚度 450 + 阻尼 0.65：动画稍慢、收尾有回弹（q 弹）
            const float fractionTarget =
                toggleDragging_ ? toggleDragTarget_ : (toggleOn_ ? 1.0f : 0.0f);
            SpringStep(toggleFraction_, toggleFractionVel_, fractionTarget, 450.0f, 0.65f, dt);
            SpringStep(togglePress_, togglePressVel_, toggleDragging_ ? 1.0f : 0.0f, 1000.0f, 1.0f,
                       dt);
            if (togglePress_ < 0.0f) { togglePress_ = 0.0f; togglePressVel_ = 0.0f; }
            if (togglePress_ > 1.0f) { togglePress_ = 1.0f; togglePressVel_ = 0.0f; }
            // 旋钮缩放：比参考实现更软（刚度 200，阻尼 0.5 / 0.6）、按压缩放更大（1.9）
            const float knobTarget = toggleDragging_ ? 1.9f : 1.0f;
            SpringStep(toggleScaleX_, toggleScaleXVel_, knobTarget, 200.0f, 0.5f, dt);
            SpringStep(toggleScaleY_, toggleScaleYVel_, knobTarget, 200.0f, 0.6f, dt);
            toggleScaleX_ = std::max(0.1f, toggleScaleX_);
            toggleScaleY_ = std::max(0.1f, toggleScaleY_);
            // 拖动速度（velocityTracker 差分 -> spring(0.5, 300) 平滑）：驱动移动时的形变
            const float rawVelocity =
                toggleDragging_ ? (toggleFraction_ - toggleFractionLast_) / dt : 0.0f;
            SpringStep(toggleVelocity_, toggleVelocityVel_, rawVelocity, 300.0f, 0.5f, dt);
            toggleFractionLast_ = toggleFraction_;
            break;
        }
        case static_cast<int>(Scene::kSlider): {
            // 数值弹簧：手指写的是目标值，旋钮用弹簧追 —— 拖动时滞后一点点、停手时回弹（q 弹）。
            // 刚度/阻尼按"约 0.2s 收敛、过冲 ~6%"配：跟手但不粘手，收尾弹一下。
            SpringStep(sliderValueAnim_, sliderValueAnimVel_, sliderValue_, 700.0f, 0.68f, dt);
            // 动画值速度（%/s）再做一次弹簧平滑：直接差分噪声太大，形变会抖
            const float rawValueVelocity =
                sliderDragging_ ? (sliderValueAnim_ - sliderValueAnimLast_) / dt : 0.0f;
            SpringStep(sliderVelocity_, sliderVelocityVel_, rawValueVelocity, 300.0f, 0.5f, dt);
            sliderValueAnimLast_ = sliderValueAnim_;
            // 按压进度：刚度调软、阻尼 0.55 —— 按下/抬起都有轻微过冲，弹一下
            SpringStep(sliderPress_, sliderPressVel_, sliderDragging_ ? 1.0f : 0.0f, 700.0f, 0.55f,
                       dt);
            if (sliderPress_ < 0.0f) { sliderPress_ = 0.0f; sliderPressVel_ = 0.0f; }
            if (sliderPress_ > 1.0f) { sliderPress_ = 1.0f; sliderPressVel_ = 0.0f; }
            // 旋钮缩放：拖动目标 1.45、刚度 170 / 阻尼 0.45、0.55 —— 放大克制一点，但更弹
            const float knobTarget = sliderDragging_ ? 1.45f : 1.0f;
            SpringStep(sliderScaleX_, sliderScaleXVel_, knobTarget, 170.0f, 0.45f, dt);
            SpringStep(sliderScaleY_, sliderScaleYVel_, knobTarget, 170.0f, 0.55f, dt);
            sliderScaleX_ = std::max(0.1f, sliderScaleX_);
            sliderScaleY_ = std::max(0.1f, sliderScaleY_);
            break;
        }
        // HallPass 内联控件：动画状态机与目录场景完全一致，只是目标值来自 ArkTS
        // （SetWidgetState / SetWidgetPress），而不是 XComponent 自己的触摸事件。
        case static_cast<int>(Scene::kToggleWidget): {
            const float target = std::max(0.0f, std::min(1.0f, widgetState_.load()));
            toggleOn_ = target >= 0.5f;
            toggleDragTarget_ = target;
            toggleDragging_ = widgetPressed_.load();
            const float fractionTarget =
                toggleDragging_ ? toggleDragTarget_ : (toggleOn_ ? 1.0f : 0.0f);
            SpringStep(toggleFraction_, toggleFractionVel_, fractionTarget, 450.0f, 0.65f, dt);
            SpringStep(togglePress_, togglePressVel_, toggleDragging_ ? 1.0f : 0.0f, 1000.0f, 1.0f,
                       dt);
            if (togglePress_ < 0.0f) { togglePress_ = 0.0f; togglePressVel_ = 0.0f; }
            if (togglePress_ > 1.0f) { togglePress_ = 1.0f; togglePressVel_ = 0.0f; }
            // 旋钮缩放（内联控件：与目录场景同参数，按压缩放 1.9）
            const float knobTarget = toggleDragging_ ? 1.9f : 1.0f;
            SpringStep(toggleScaleX_, toggleScaleXVel_, knobTarget, 200.0f, 0.5f, dt);
            SpringStep(toggleScaleY_, toggleScaleYVel_, knobTarget, 200.0f, 0.6f, dt);
            toggleScaleX_ = std::max(0.1f, toggleScaleX_);
            toggleScaleY_ = std::max(0.1f, toggleScaleY_);
            const float rawVelocity =
                toggleDragging_ ? (toggleFraction_ - toggleFractionLast_) / dt : 0.0f;
            SpringStep(toggleVelocity_, toggleVelocityVel_, rawVelocity, 300.0f, 0.5f, dt);
            toggleFractionLast_ = toggleFraction_;
            break;
        }
        case static_cast<int>(Scene::kSliderWidget): {
            const float target = std::max(0.0f, std::min(1.0f, widgetState_.load()));
            sliderValue_ = target * 100.0f;
            sliderDragging_ = widgetPressed_.load();
            SpringStep(sliderValueAnim_, sliderValueAnimVel_, sliderValue_, 700.0f, 0.68f, dt);
            const float rawValueVelocity =
                sliderDragging_ ? (sliderValueAnim_ - sliderValueAnimLast_) / dt : 0.0f;
            SpringStep(sliderVelocity_, sliderVelocityVel_, rawValueVelocity, 300.0f, 0.5f, dt);
            sliderValueAnimLast_ = sliderValueAnim_;
            SpringStep(sliderPress_, sliderPressVel_, sliderDragging_ ? 1.0f : 0.0f, 700.0f, 0.55f,
                       dt);
            if (sliderPress_ < 0.0f) { sliderPress_ = 0.0f; sliderPressVel_ = 0.0f; }
            if (sliderPress_ > 1.0f) { sliderPress_ = 1.0f; sliderPressVel_ = 0.0f; }
            const float knobTarget = sliderDragging_ ? 1.45f : 1.0f;
            SpringStep(sliderScaleX_, sliderScaleXVel_, knobTarget, 170.0f, 0.45f, dt);
            SpringStep(sliderScaleY_, sliderScaleYVel_, knobTarget, 170.0f, 0.55f, dt);
            sliderScaleX_ = std::max(0.1f, sliderScaleX_);
            sliderScaleY_ = std::max(0.1f, sliderScaleY_);
            break;
        }
        case static_cast<int>(Scene::kDialog): {
            SpringStep(dialogScale_, dialogScaleVel_, 1.0f, 260.0f, 0.65f, dt);
            if (std::fabs(dialogScale_ - 1.0f) < 0.001f && std::fabs(dialogScaleVel_) < 0.005f) {
                dialogScale_ = 1.0f;
                dialogScaleVel_ = 0.0f;
            }
            for (int i = 0; i < 2; i++) {
                const bool down = (dialogDown_ == i);
                const float target = down ? 1.0f : 0.0f;
                // 按下 / 松手分开两套弹簧（对照 iOS 玻璃按钮录屏逐帧实测）：
                //   按下：快、轻微过冲 —— iOS 0.16s 到峰、过冲 8%（≈ 刚度 600 / 阻尼比 0.62）
                //   松手：软、明显回弹 —— iOS 先缩到比原尺寸小、下冲 29%、周期 ~0.43s（≈ 250 / 0.38）
                // 原先两个方向共用 340 / 0.46：按下过冲偏大、松手回弹偏小，不够"q 弹"。
                const float stiffness = down ? 600.0f : 250.0f;
                const float damping = down ? 0.62f : 0.38f;
                SpringStep(dialogPress_[i], dialogPressVel_[i], target, stiffness, damping, dt);
                if (std::fabs(dialogPress_[i] - target) < 0.001f && std::fabs(dialogPressVel_[i]) < 0.005f) {
                    dialogPress_[i] = target;
                    dialogPressVel_[i] = 0.0f;
                }
                dialogPress_[i] = std::max(-0.35f, std::min(1.45f, dialogPress_[i]));
            }
            break;
        }
        case static_cast<int>(Scene::kControlCenter): {
            if (!ccDragging_) {
                // 展开 spring(0.5, 300) / 收起 spring(1.0, 300)，与参考实现一致
                const float target = (ccProgress_ > 0.5f) ? 1.0f : 0.0f;
                const float damping = (target > 0.5f) ? 0.5f : 1.0f;
                SpringStep(ccProgress_, ccProgressVel_, target, 300.0f, damping, dt);
                if (std::fabs(ccProgress_ - target) < 0.005f && std::fabs(ccProgressVel_) < 0.01f) {
                    ccProgress_ = target;
                    ccProgressVel_ = 0.0f;
                }
            }
            break;
        }
        case static_cast<int>(Scene::kMagnifier):
        case static_cast<int>(Scene::kLockScreen):
        case static_cast<int>(Scene::kProgressiveBlur): {
            break;
        }
        case static_cast<int>(Scene::kAdaptiveLuminance): {
            // 参考实现是 1s tween；这里用时间常数为 0.35s 的指数趋近，观感接近
            const float lumDelta = (lumTarget_ - lumValue_) * std::min(1.0f, dt / 0.35f);
            lumValue_ += lumDelta;
            gSpringMotion += std::fabs(lumDelta);
            break;
        }
        case static_cast<int>(Scene::kScrollContainer):
        case static_cast<int>(Scene::kLazyScrollContainer): {
            if (!listDragging_) {
                const float scrollDelta = listScrollVel_ * dt;
                listScroll_ += scrollDelta;
                gSpringMotion += std::fabs(scrollDelta);
                listScrollVel_ *= std::pow(0.02f, dt);   // 快速衰减，避免长尾巴
                if (std::fabs(listScrollVel_) < 1.0f) {
                    listScrollVel_ = 0.0f;
                }
                const float contentH = ScrollContentHeight(
                    scene == static_cast<int>(Scene::kLazyScrollContainer) ? 100 : 20,
                    params_.Density());
                const float maxScroll = std::max(0.0f, contentH - static_cast<float>(height_.load()));
                if (listScroll_ < 0.0f) {
                    listScroll_ = 0.0f;
                    listScrollVel_ = 0.0f;
                }
                if (listScroll_ > maxScroll) {
                    listScroll_ = maxScroll;
                    listScrollVel_ = 0.0f;
                }
            }
            break;
        }
        case static_cast<int>(Scene::kPlayground): {
            for (int i = 0; i < 5; i++) {
                SpringStep(pgSliderPress_[i], pgSliderPressVel_[i],
                           (pgSliderDown_ == i) ? 1.0f : 0.0f, 1000.0f, 1.0f, dt);
                if (pgSliderPress_[i] < 0.0f) { pgSliderPress_[i] = 0.0f; pgSliderPressVel_[i] = 0.0f; }
                if (pgSliderPress_[i] > 1.0f) { pgSliderPress_[i] = 1.0f; pgSliderPressVel_[i] = 0.0f; }
            }
            for (int i = 0; i < 2; i++) {
                SpringStep(pgButtonPress_[i], pgButtonPressVel_[i], (pgButtonDown_ == i) ? 1.0f : 0.0f,
                           300.0f, 0.5f, dt);
                if (pgButtonPress_[i] < 0.0f) { pgButtonPress_[i] = 0.0f; pgButtonPressVel_[i] = 0.0f; }
                if (pgButtonPress_[i] > 1.0f) { pgButtonPress_[i] = 1.0f; pgButtonPressVel_[i] = 0.0f; }
            }
            break;
        }
        default:
            break;
    }
}

bool GlesRenderer::OnTouchCatalog(int action, float x, float y, int surfaceW, int surfaceH) {
    const float d = params_.Density();
    const int scene = scene_.load();
    const float glY = static_cast<float>(surfaceH) - y;   // 触摸 y（自上而下）-> GL y

    switch (scene) {
        case static_cast<int>(Scene::kButtons): {
            std::lock_guard<std::mutex> lock(animMutex_);
            int hit = -1;
            for (int i = 0; i < 4; i++) {
                if (RectHit(ButtonRectAt(surfaceW, surfaceH, d, i), x, glY)) {
                    hit = i;
                    break;
                }
            }
            if (action == 0) {
                sceneDown_ = hit;
            } else if (action == 2) {
                // 按在按钮上拖动：不响应（按钮没有拖动语义）
            } else if (action == 1 || action == 3) {
                sceneDown_ = -1;
            }
            return true;
        }
        case static_cast<int>(Scene::kToggle): {
            std::lock_guard<std::mutex> lock(animMutex_);
            const RectF track = ToggleTrackRect(surfaceW, surfaceH, d);
            // 与旋钮行程一致（轨道宽 - 2*2dp - 旋钮宽 = 24dp），拖动才跟手
            const float dragWidth = 24.0f * d;
            if (action == 0) {
                if (!RectHit(track, x, glY, 24.0f * d)) {
                    return true;
                }
                toggleDragging_ = true;
                toggleDidDrag_ = false;
                toggleDownX_ = x;
                toggleGrabStartFraction_ = toggleFraction_;
            } else if (action == 2) {
                if (!toggleDragging_) {
                    return true;
                }
                const float delta = x - toggleDownX_;
                if (std::fabs(delta) > 4.0f * d) {
                    toggleDidDrag_ = true;
                }
                // 相对按下点映射（避免累计漂移）；只更新目标，fraction 以弹簧追随 → 有一点延迟
                float next = toggleGrabStartFraction_ + delta / dragWidth;
                next = std::max(0.0f, std::min(1.0f, next));
                toggleDragTarget_ = next;
            } else if (action == 1 || action == 3) {
                if (!toggleDragging_) {
                    return true;
                }
                toggleDragging_ = false;
                if (toggleDidDrag_) {
                    toggleOn_ = toggleDragTarget_ >= 0.5f;
                    toggleDragTarget_ = toggleOn_ ? 1.0f : 0.0f;
                    GLOG("toggle drag -> %{public}d", toggleOn_ ? 1 : 0);
                } else {
                    toggleOn_ = !toggleOn_;
                    GLOG("toggle tap -> %{public}d", toggleOn_ ? 1 : 0);
                }
            }
            return true;
        }
        case static_cast<int>(Scene::kSlider): {
            std::lock_guard<std::mutex> lock(animMutex_);
            const RectF track = SliderTrackRect(surfaceW, surfaceH, d);
            if (action == 0) {
                if (!RectHit(track, x, glY, 30.0f * d)) {
                    return true;
                }
                sliderDragging_ = true;
                sliderDidDrag_ = false;
                sliderGrabValue_ = sliderValue_;
                sliderGrabX_ = x;
                // 点击轨道：直接跳到点击位置（参考实现的 detectTapGestures）
                const float next = (x - track.x) / std::max(track.w, 1.0f) * 100.0f;
                sliderValue_ = std::max(0.0f, std::min(100.0f, next));
            } else if (action == 2) {
                if (!sliderDragging_) {
                    return true;
                }
                const float delta = x - sliderGrabX_;
                if (std::fabs(delta) > 4.0f * d) {
                    sliderDidDrag_ = true;
                }
                float next = sliderGrabValue_ + delta / std::max(track.w, 1.0f) * 100.0f;
                next = std::max(0.0f, std::min(100.0f, next));
                sliderValue_ = next;
            } else if (action == 1 || action == 3) {
                if (!sliderDragging_) {
                    return true;
                }
                sliderDragging_ = false;
                GLOG("slider value=%{public}.1f", static_cast<double>(sliderValue_));
            }
            return true;
        }
        case static_cast<int>(Scene::kDialog): {
            std::lock_guard<std::mutex> lock(animMutex_);
            RectF btn;
            DialogButtonRects(surfaceW, surfaceH, d, &btn);
            const bool hit = RectHit(btn, x, glY);
            if (action == 0) {
                dialogDown_ = hit ? 0 : -1;
                if (!hit) {
                    const RectF p = DialogPanelRect(surfaceW, surfaceH, d);
                    if (RectHit(p, x, glY)) {
                        dialogScaleVel_ = -0.03f;
                    }
                }
            } else if (action == 1 || action == 3) {
                const bool tapped = (action == 1) && (dialogDown_ == 0) && hit;
                dialogDown_ = -1;
                if (tapped) {
                    dialogScaleVel_ = 0.06f;
                    GLOG("dialog OK button tapped");
                }
            }
            return true;
        }
        case static_cast<int>(Scene::kControlCenter): {
            std::lock_guard<std::mutex> lock(animMutex_);
            if (action == 0) {
                ccDragging_ = true;
                ccDragStartProgress_ = ccProgress_;
                ccDragStartY_ = y;
                ccProgressVel_ = 0.0f;
            } else if (action == 2 && ccDragging_) {
                // 参考实现：progress += delta / 1000（px）
                const float next = ccDragStartProgress_ + (y - ccDragStartY_) / 1000.0f;
                ccProgress_ = std::max(0.0f, std::min(1.0f, next));
            } else if (action == 1 || action == 3) {
                ccDragging_ = false;
            }
            return true;
        }
        case static_cast<int>(Scene::kLockScreen): {
            std::lock_guard<std::mutex> lock(animMutex_);
            if (action == 0) {
                lockDragging_ = true;
                lockGrabDX_ = x - lockOffsetX_;
                lockGrabDY_ = y - lockOffsetY_;
            } else if (action == 2 && lockDragging_) {
                lockOffsetX_ = x - lockGrabDX_;
                lockOffsetY_ = y - lockGrabDY_;
            } else if (action == 1 || action == 3) {
                lockDragging_ = false;
            }
            return true;
        }
        case static_cast<int>(Scene::kMagnifier): {
            std::lock_guard<std::mutex> lock(animMutex_);
            if (!magInited_) {
                magX_ = static_cast<float>(surfaceW) * 0.5f;
                magY_ = static_cast<float>(surfaceH) * 0.42f;
                magInited_ = true;
            }
            if (action == 0) {
                magDragging_ = true;
                magGrabDX_ = x - magX_;
                magGrabDY_ = glY - magY_;
            } else if (action == 2 && magDragging_) {
                magX_ = x - magGrabDX_;
                magY_ = glY - magGrabDY_;
            } else if (action == 1 || action == 3) {
                magDragging_ = false;
            }
            return true;
        }
        case static_cast<int>(Scene::kProgressiveBlur): {
            return true;
        }
        case static_cast<int>(Scene::kAdaptiveLuminance): {
            std::lock_guard<std::mutex> lock(animMutex_);
            if (action == 0) {
                const RectF panel = AdaptivePanelRect(surfaceW, surfaceH, d);
                if (!RectHit(panel, x, glY)) {
                    return true;
                }
                pgDragging_ = true;
                pgGrabDX_ = x - panel.x;
                pgGrabDY_ = glY - panel.y;
            } else if (action == 2 && pgDragging_) {
                // 用 pgX_/pgY_ 存自适应面板的位置偏移（仅此场景复用）
                pgX_ = x - pgGrabDX_ - AdaptivePanelRect(surfaceW, surfaceH, d).x;
                pgY_ = glY - pgGrabDY_ - AdaptivePanelRect(surfaceW, surfaceH, d).y;
            } else if (action == 1 || action == 3) {
                pgDragging_ = false;
            }
            return true;
        }
        case static_cast<int>(Scene::kScrollContainer):
        case static_cast<int>(Scene::kLazyScrollContainer): {
            std::lock_guard<std::mutex> lock(animMutex_);
            if (action == 0) {
                listDragging_ = true;
                listGrabScroll_ = listScroll_;
                listGrabY_ = y;
                listScrollVel_ = 0.0f;
            } else if (action == 2 && listDragging_) {
                // 手指上滑（y 变小）-> 内容上移 -> scroll 变大
                listScroll_ = listGrabScroll_ + (listGrabY_ - y);
                if (listScroll_ < -200.0f) {
                    listScroll_ = -200.0f;   // 顶部回弹余量
                }
            } else if (action == 1 || action == 3) {
                listDragging_ = false;
            }
            return true;
        }
        case static_cast<int>(Scene::kPlayground): {
            std::lock_guard<std::mutex> lock(animMutex_);
            const RectF panel = PgPanelRect(surfaceW, surfaceH, d);
            RectF button0 = PgButtonRect(0, pgSheetOpen_, surfaceW, surfaceH, d);
            RectF button1 = PgButtonRect(1, pgSheetOpen_, surfaceW, surfaceH, d);
            if (action == 0) {
                if (RectHit(panel, x, glY)) {
                    pgDragging_ = true;
                    pgGrabDX_ = x - panel.x;
                    pgGrabDY_ = glY - panel.y;
                    return true;
                }
                if (RectHit(button0, x, glY)) {
                    pgButtonDown_ = 0;
                    return true;
                }
                if (RectHit(button1, x, glY)) {
                    pgButtonDown_ = 1;
                    return true;
                }
                if (pgSheetOpen_) {
                    for (int i = 0; i < 5; i++) {
                        if (RectHit(PgSliderRowRect(i, surfaceW, surfaceH, d), x, glY)) {
                            pgSliderDown_ = i;
                            pgSliderGrabValue_[i] = pgSliderValue_[i];
                            pgSliderGrabX_[i] = x;
                            // 点击定位（与参考实现的 tap 行为一致）
                            const RectF row = PgSliderRowRect(i, surfaceW, surfaceH, d);
                            const float next = (x - row.x) / std::max(row.w, 1.0f);
                            pgSliderValue_[i] = std::max(0.0f, std::min(1.0f, next));
                            return true;
                        }
                    }
                }
            } else if (action == 2) {
                if (pgDragging_) {
                    pgX_ = x - pgGrabDX_ - panel.x;
                    pgY_ = glY - pgGrabDY_ - panel.y;
                    return true;
                }
                if (pgSliderDown_ >= 0) {
                    const RectF row = PgSliderRowRect(pgSliderDown_, surfaceW, surfaceH, d);
                    const float delta = x - pgSliderGrabX_[pgSliderDown_];
                    float next = pgSliderGrabValue_[pgSliderDown_] + delta / std::max(row.w, 1.0f);
                    next = std::max(0.0f, std::min(1.0f, next));
                    pgSliderValue_[pgSliderDown_] = next;
                    return true;
                }
            } else if (action == 1 || action == 3) {
                if (pgButtonDown_ == 0 && action == 1) {
                    pgSheetOpen_ = !pgSheetOpen_;
                    overlayTextDirty_.store(true);
                    GLOG("playground sheet %{public}s", pgSheetOpen_ ? "open" : "closed");
                } else if (pgButtonDown_ == 1 && action == 1) {
                    // Reset：与参考实现一致，回到初始值
                    pgX_ = 0.0f;
                    pgY_ = 0.0f;
                    const float sliderDefaults[5] = {0.5f, 0.0f, 0.2f, 0.2f, 0.0f};
                    for (int i = 0; i < 5; i++) {
                        pgSliderValue_[i] = sliderDefaults[i];
                    }
                    GLOG("playground reset");
                }
                pgButtonDown_ = -1;
                pgDragging_ = false;
                pgSliderDown_ = -1;
            }
            return true;
        }
        default:
            return false;
    }
}

void GlesRenderer::OnTouch(int action, float x, float y, int64_t /*timestampMs*/) {
    // 触摸是"必须立刻出帧"的信号，也是交互档帧率的触发点
    lastTouchMs_.store(NowMs());
    RequestRedraw();
    const int surfaceW = static_cast<int>(width_.load());
    const int surfaceH = static_cast<int>(height_.load());
    if (surfaceW <= 0 || surfaceH <= 0) return;

    // 目录场景不走页签场景的手势（顶部玻璃按钮 / 浮动件都没有）
    if (scene_.load() != static_cast<int>(Scene::kTabs)) {
        OnTouchCatalog(action, x, y, surfaceW, surfaceH);
        return;
    }

    // ---- 顶部三个玻璃按钮：最高优先级（demo 专属件，chrome=false 时整块不参与）----
    if (demoChrome_.load()) {
        int hit = -1;
        const bool inBtn = HitButton(x, y, surfaceW, surfaceH, &hit);
        int tapped = -1;
        {
            std::lock_guard<std::mutex> lock(animMutex_);
            if (action == 0) {                       // DOWN
                btnDownIndex_ = inBtn ? hit : -1;
            } else if (action == 2) {                // MOVE
                if (btnDownIndex_ >= 0) return;      // 按在按钮上拖动：不参与滚动/页签拖动
            } else if (action == 1 || action == 3) { // UP / CANCEL
                if (btnDownIndex_ >= 0) {
                    const int down = btnDownIndex_;
                    btnDownIndex_ = -1;
                    if (action == 1 && inBtn && hit == down) {
                        tapped = down;
                    }
                }
            }
        }
        if (inBtn && action != 2) {
            if (tapped >= 0) {
                const int target = kIconButtonMenuTargets[tapped];
                GLOG("icon button %{public}d tap -> menu target %{public}d", tapped, target);
                if (MenuRequestFn fn = menuRequestFn_.load()) {
                    fn(target);   // 交给 ArkTS 开菜单（napi threadsafe function）
                }
            }
            return;   // 按钮区域内的事件一律不再往下走
        }
    }

    // ---- 浮动玻璃件：拖动（优先于底板与背景滚动；demo 专属件，chrome=false 时不参与）----
    if (demoChrome_.load()) {
        const float touchGlY = static_cast<float>(surfaceH) - y;
        const float fW = static_cast<float>(surfaceW) - params_.Px(pid::kOuterPaddingH) * 2.0f;
        const float fH = params_.Px(pid::kBarHeight);
        const float fx = floatX_.load();
        const float fy = floatY_.load();
        const bool inFloat = (x >= fx) && (x <= fx + fW) && (touchGlY >= fy) &&
                             (touchGlY <= fy + fH);

        if (draggingFloat_) {
            if (action == 2) {
                float nx = x - floatGrabDX_;
                float ny = touchGlY - floatGrabDY_;
                nx = std::max(0.0f, std::min(nx, static_cast<float>(surfaceW) - fW));
                ny = std::max(0.0f, std::min(ny, static_cast<float>(surfaceH) - fH));
                floatX_.store(nx);
                floatY_.store(ny);
            } else if (action == 1) {
                draggingFloat_ = false;
                GLOG("float drag end: x=%{public}.0f y=%{public}.0f", floatX_.load(),
                     floatY_.load());
            }
            return;
        }
        if (action == 0 && inFloat) {
            draggingFloat_ = true;
            floatGrabDX_ = x - fx;
            floatGrabDY_ = touchGlY - fy;
            GLOG("float drag start: x=%{public}.0f y=%{public}.0f", fx, fy);
            return;
        }
    }

    // 触摸 y 从顶部起算；GL 的 y 从底部起算
    const float glY = static_cast<float>(surfaceH) - y;

    // 只在底部玻璃条附近响应。
    // 叠加模式（HallPass）：surface 只有条那么高，触摸区严格等于底板矩形 ——
    // 上方留白（投影 / 按压鼓出）不参与命中，免得点内容也会拖到指示器。
    // demo 整屏模式：上下各放宽一段（还要兼顾照片滚动的边界）。
    const float barV = params_.Px(pid::kOuterPaddingV);
    const float barHpx = params_.Px(pid::kBarHeight);
    const bool inBar = overlayMode_.load()
                           ? (glY >= barV && glY <= barV + barHpx)
                           : (glY > (barV - 160.0f) && glY < (barV + barHpx + 220.0f));

    const float value = TabValueFromX(x, surfaceW);
    // 页签格子宽度（视差累积要用；与 TabValueFromX / 指示器定位同一套几何，必须走 TabInnerPadPx）
    const float tabWidthPx_ = (static_cast<float>(surfaceW) -
                               params_.Px(pid::kOuterPaddingH) * 2.0f -
                               TabInnerPadPx() * 2.0f) / 3.0f;

    std::lock_guard<std::mutex> lock(animMutex_);

    // ---- 拖动中的事件优先于"手指在不在条上"：划出页签条再划回来也必须继续跟手 ----
    if (anim_.dragging) {
        if (action == 2) {  // MOVE：拖动目标 = 触摸位置（绝对跟手）
            static int moveCount = 0;
            static bool firstMove = true;
            if (firstMove || (moveCount % 30) == 0) {
                GLOG("touch MOVE#%{public}d x=%{public}.0f value=%{public}.2f", moveCount, x,
                     value);
                firstMove = false;
            }
            moveCount++;
            const float prev = anim_.targetValue;
            float next = value;
            if (next < 0.0f) next = 0.0f;
            if (next > 2.0f) next = 2.0f;
            anim_.targetValue = next;
            const float delta = anim_.targetValue - prev;
            // 速度不在事件里换算（事件率不一定是 60Hz）：只累积位移，UpdateAnim 里按 dt 换成"每秒"
            moveAccum_ += delta;
            // 底板视差：把本帧的横向位移累积起来（与参考实现的 offsetAnimation 同义）
            parallaxAccum_ += delta * tabWidthPx_;
            const float maxW = static_cast<float>(surfaceW);
            if (parallaxAccum_ > maxW) parallaxAccum_ = maxW;
            if (parallaxAccum_ < -maxW) parallaxAccum_ = -maxW;
            return;
        }
        if (action == 1 || action == 3) {  // UP / CANCEL
            anim_.dragging = false;
            // 目标取**手指位置**（不是被弹簧拖后的 value）：快速拖动松手也不会落错页签
            int target = static_cast<int>(std::lround(anim_.targetValue));
            if (target < 0) target = 0;
            if (target > 2) target = 2;
            anim_.targetIndex = target;
            if (selectedTab_ != target) {
                selectedTab_ = target;
                labelsDirty_.store(true);   // 选中色要重渲染文字纹理
                // 通知 ArkTS 切页面（HallPass）。回调走 napi threadsafe function，
                // 只入队不阻塞；这里持锁调用不会死锁（JS 回调在本线程之外执行）。
                if (TabChangeFn fn = tabChangeFn_.load()) {
                    fn(target);
                }
            }
            GLOG("touch UP targetValue=%{public}.2f value=%{public}.2f -> target=%{public}d",
                 anim_.targetValue, anim_.value, target);
            return;
        }
    }

    // ---- 背景滚动：不在底部玻璃条上时，纵向拖动 = 滚照片 ----
    // （对齐参考实现的 PhotoBackground 的 verticalScroll）
    // 叠加模式（HallPass）：surface 只有页签条一条，条外的事件一概不处理（照片滚动是 demo 的手势）。
    if (!inBar && !demoChrome_.load()) {
        return;
    }
    if (!inBar) {
        if (action == 0) {
            scrolling_ = true;
            scrollGrabStart_ = scroll_.load();
            scrollGrabY_ = y;
        } else if (action == 2 && scrolling_) {
            const float contentH = static_cast<float>(surfaceH) *
                                   std::max(1.0f, params_.N(pid::kBackgroundScrollRange));
            const float maxScrollPx = std::max(1.0f, contentH - static_cast<float>(surfaceH));
            // 手指上滑（y 变小）-> 内容往上走 -> scroll 变大
            float next = scrollGrabStart_ + (scrollGrabY_ - y) / maxScrollPx;
            next = std::max(0.0f, std::min(1.0f, next));
            scroll_.store(next);
        } else if (action == 1) {
            scrolling_ = false;
        }
        return;   // 背景区域不参与指示器拖动
    }

    if (action == 0) {  // DOWN：按下即开始位移（弹簧过渡到触摸位置，不瞬移）
        anim_.dragging = true;
        anim_.targetValue = std::max(0.0f, std::min(2.0f, value));
        moveAccum_ = 0.0f;
        GLOG("touch DOWN x=%{public}.0f value=%{public}.2f -> target=%{public}.2f", x, value,
             anim_.targetValue);
    }
}

bool GlesRenderer::InitEgl(void *window) {
    display_ = eglGetDisplay(EGL_DEFAULT_DISPLAY);
    if (display_ == EGL_NO_DISPLAY) {
        GERR("eglGetDisplay failed");
        return false;
    }
    EGLint major = 0;
    EGLint minor = 0;
    if (eglInitialize(display_, &major, &minor) != EGL_TRUE) {
        GERR("eglInitialize failed: 0x%{public}x", eglGetError());
        return false;
    }

    const EGLint attribs[] = {
        EGL_SURFACE_TYPE, EGL_WINDOW_BIT,
        EGL_RED_SIZE, 8,
        EGL_GREEN_SIZE, 8,
        EGL_BLUE_SIZE, 8,
        EGL_ALPHA_SIZE, 8,
        EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT,
        EGL_NONE,
    };
    EGLint numConfigs = 0;
    if (eglChooseConfig(display_, attribs, &config_, 1, &numConfigs) != EGL_TRUE || numConfigs < 1) {
        GERR("eglChooseConfig failed: 0x%{public}x", eglGetError());
        return false;
    }

    // ---- HallPass 叠加模式：surface 必须逐像素带 alpha ----
    // 否则页签条以外的透明像素会被按不透明合成（整条压成黑带）。两道保险：
    //   1) EGLConfig 的 alpha 位（下面打日志确认）；
    //   2) 原生窗口缓冲格式设成 RGBA8888（窗口默认可能是 RGBX，那样 alpha 根本写不进缓冲）。
    //     EGLSurface 创建之前设置才有效。
    const bool needsAlpha = overlayMode_.load() || IsWidgetMode() ||
                            (scene_.load() == static_cast<int>(Scene::kDialog));
    if (needsAlpha && window != nullptr) {
        EGLint alphaBits = 0;
        eglGetConfigAttrib(display_, config_, EGL_ALPHA_SIZE, &alphaBits);
        auto *nativeWindow = reinterpret_cast<OHNativeWindow *>(window);
        int32_t format = 0;
        OH_NativeWindow_NativeWindowHandleOpt(nativeWindow, GET_FORMAT, &format);
        GLOG("overlay surface: egl alphaBits=%{public}d window format=%{public}d", alphaBits,
             format);
        if (format != NATIVEBUFFER_PIXEL_FMT_RGBA_8888) {
            const int32_t ret = OH_NativeWindow_NativeWindowHandleOpt(
                nativeWindow, SET_FORMAT, NATIVEBUFFER_PIXEL_FMT_RGBA_8888);
            GLOG("overlay surface: SET_FORMAT RGBA_8888 ret=%{public}d", ret);
        }
    }

    surface_ = eglCreateWindowSurface(display_, config_,
                                      reinterpret_cast<EGLNativeWindowType>(window), nullptr);
    if (surface_ == EGL_NO_SURFACE) {
        GERR("eglCreateWindowSurface failed: 0x%{public}x", eglGetError());
        return false;
    }

    const EGLint ctxAttribs[] = {EGL_CONTEXT_CLIENT_VERSION, 3, EGL_NONE};
    // 弹窗：加入页签中枢的 share group，直接采样实时镜像纹理（见 shared_backdrop.h）。
    // 失败（无中枢 / 显示不同 / 驱动拒绝）就建独立上下文，弹窗退回快照背景。
    sharedGen_ = 0;
    if (WantsSharedBackdrop()) {
        EGLDisplay hubDisplay = EGL_NO_DISPLAY;
        uint64_t gen = 0;
        const EGLContext hub = SharedBackdrop::Get().HubContext(&hubDisplay, &gen);
        if (hub != EGL_NO_CONTEXT && hubDisplay == display_) {
            context_ = eglCreateContext(display_, config_, hub, ctxAttribs);
            if (context_ != EGL_NO_CONTEXT) {
                sharedGen_ = gen;
                GLOG("shared backdrop: context joined hub share group (gen %{public}llu)",
                     static_cast<unsigned long long>(gen));
            } else {
                GERR("shared backdrop: share context failed 0x%{public}x, fallback", eglGetError());
            }
        }
    }
    if (context_ == EGL_NO_CONTEXT) {
        context_ = eglCreateContext(display_, config_, EGL_NO_CONTEXT, ctxAttribs);
    }
    if (context_ == EGL_NO_CONTEXT) {
        GERR("eglCreateContext failed: 0x%{public}x", eglGetError());
        return false;
    }
    if (eglMakeCurrent(display_, surface_, surface_, context_) != EGL_TRUE) {
        GERR("eglMakeCurrent failed: 0x%{public}x", eglGetError());
        return false;
    }
    // swap interval = 1 只是个提示：实测 XComponent 的 surface 上不保证按 vsync 阻塞，
    // 真正的限速在 RenderLoop 的 PaceFrame()（时间基准）。
    eglSwapInterval(display_, 1);

    GLOG("EGL ready: v%{public}d.%{public}d, renderer=%{public}s",
         major, minor, reinterpret_cast<const char *>(glGetString(GL_RENDERER)));
    return true;
}

bool GlesRenderer::InitGl() {
    // 内联控件（开关 / 滑块）只需要三条程序：旋钮玻璃 / 轨道纯色 / sceneTex_ 拷贝。
    // 省掉其余七条（含 native_drawing 的图标栅格化）—— 一个页面可能同时挂 8 个控件，
    // 每个实例都全量编译会在首次绘制时明显卡顿。
    if (IsWidgetMode()) {
        const std::string commonShader = std::string(kGlslPrelude) + kGlslSdfHelpers;
        progGlass_ = LinkProgram(kVertexShader, (commonShader + kGlassShaderBody).c_str());
        progSolid_ = LinkProgram(kVertexShader, (commonShader + kSolidShaderBody).c_str());
        progCopy_ = LinkProgram(kVertexShader, (std::string(kGlslPrelude) + kCopyShaderBody).c_str());
        if (progGlass_ == 0 || progSolid_ == 0 || progCopy_ == 0) {
            return false;
        }
        glGenFramebuffers(1, &sceneFbo_);
        glGenTextures(1, &sceneTex_);
        gpuTimer_.Init();
        GLOG("GL programs ready (widget: glass/solid/copy)");
        return true;
    }

    progBg_ = LinkProgram(kVertexShader, kBackgroundShader);
    progBlur_ = LinkProgram(kVertexShader, kBlurShader);
    // 底板 / 指示器 / 光斑 **共用**前导 + SDF helper，只是 body 不同
    const std::string commonShader = std::string(kGlslPrelude) + kGlslSdfHelpers;
    progGlass_ = LinkProgram(kVertexShader, (commonShader + kGlassShaderBody).c_str());
    progIndicator_ = LinkProgram(kVertexShader, (commonShader + kIndicatorShaderBody).c_str());
    progGlow_ = LinkProgram(kVertexShader, (commonShader + kGlowShaderBody).c_str());
    progIcon_ = LinkProgram(kVertexShader, (std::string(kGlslPrelude) + kIconShaderBody).c_str());
    // 目录场景：纯色 / 拷贝 / 文字图标 / 渐进模糊
    progSolid_ = LinkProgram(kVertexShader, (commonShader + kSolidShaderBody).c_str());
    progCopy_ = LinkProgram(kVertexShader, (std::string(kGlslPrelude) + kCopyShaderBody).c_str());
    progSprite_ = LinkProgram(kVertexShader, (std::string(kGlslPrelude) + kSpriteShaderBody).c_str());
    progProgBlur_ =
        LinkProgram(kVertexShader, (commonShader + kProgressiveBlurShaderBody).c_str());
    progExtCopy_ = LinkProgram(kVertexShader, kExternalCopyShader);
    if (progBg_ == 0 || progBlur_ == 0 || progGlass_ == 0 || progIndicator_ == 0 ||
        progGlow_ == 0 || progIcon_ == 0 || progSolid_ == 0 || progCopy_ == 0 ||
        progSprite_ == 0 || progProgBlur_ == 0 || progExtCopy_ == 0) {
        return false;
    }
    glGenFramebuffers(2, blurFbo_);
    glGenTextures(2, blurTex_);
    glGenFramebuffers(2, blurFbo2_);
    glGenTextures(2, blurTex2_);
    glGenFramebuffers(4, &blurDownFbo_[0][0]);
    glGenTextures(4, &blurDownTex_[0][0]);
    glGenFramebuffers(1, &bgFbo_);
    glGenTextures(1, &bgTex_);
    glGenFramebuffers(1, &sceneFbo_);
    glGenTextures(1, &sceneTex_);
    glGenFramebuffers(1, &contentFbo_);
    glGenTextures(1, &contentBlitTex_);
    glGenTextures(1, &labelTex_);
    glGenTextures(1, &labelAccentTex_);
    glGenTextures(1, &iconTex_);
    glGenTextures(1, &photoTex_);
    {
        glBindTexture(GL_TEXTURE_2D, photoTex_);
        uint32_t defaultPixel = 0xFFF0F0F2;
        glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, 1, 1, 0, GL_RGBA, GL_UNSIGNED_BYTE, &defaultPixel);
        SetupTexture(photoTex_);
        photoW_ = 1;
        photoH_ = 1;
    }
    glGenTextures(1, &contentTextTex_);
    glGenTextures(1, &overlayTextTex_);
    glGenTextures(1, &planeIconTex_);
    glGenTextures(1, &dialogBtnLabelTex_);
    // 飞机图标（控制中心 / 游乐场）：24×24 视口的绝对 path，白色、预乘 alpha
    {
        const int iconPx = std::max(8, static_cast<int>(kPlaneIconDp * params_.Density() + 0.5f));
        LabelBitmap icon;
        if (RenderIconPath(kPlaneIconPath, 24.0f, iconPx, 0xFFFFFFFF, icon)) {
            glBindTexture(GL_TEXTURE_2D, planeIconTex_);
            glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, icon.width, icon.height, 0, GL_RGBA,
                         GL_UNSIGNED_BYTE, icon.pixels.data());
            SetupTexture(planeIconTex_);
            planeIconSizePx_ = iconPx;
        }
    }
    CreateContentImage();
    gpuTimer_.Init();
    GLOG("GL programs ready (bg/blur/glass/indicator/glow/icon/solid/copy/sprite/progblur/extcopy) "
         "gpuTimer=%{public}d", gpuTimer_.Supported() ? 1 : 0);
    return true;
}

void GlesRenderer::CreateContentImage() {
    if (contentImage_ != nullptr) {
        return;
    }
    glGenTextures(1, &contentTex_);
    glBindTexture(GL_TEXTURE_EXTERNAL_OES, contentTex_);
    // 外纹理不能 glTexImage2D（内容由生产端写入），只需过滤/环绕参数
    glTexParameteri(GL_TEXTURE_EXTERNAL_OES, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_EXTERNAL_OES, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_EXTERNAL_OES, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_EXTERNAL_OES, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);

    contentImage_ = OH_NativeImage_Create(contentTex_, GL_TEXTURE_EXTERNAL_OES);
    if (contentImage_ == nullptr) {
        GERR("OH_NativeImage_Create failed");
        return;
    }
    OH_NativeImage_AttachContext(contentImage_, contentTex_);
    // 丢帧模式（API 17+）：生产端产得快时**只留最新一帧**。
    // 不开的话 buffer 队列会积 1~2 帧 —— 消费端拿到的是旧帧（玻璃凭空多一截滞后），
    // 队列满了还会反压 ArkUI 的 BuilderNode 生产端（拖住整个 UI 线程）。
    // 必须在 Create 之后立刻开，且只对 UpdateSurfaceImage 生效（文档原话）。
    const int32_t dropRet = OH_NativeImage_SetDropBufferMode(contentImage_, true);
    if (dropRet != 0) {
        GERR("SetDropBufferMode failed: %{public}d (API < 17?)", dropRet);
    }
    OH_OnFrameAvailableListener listener{this, OnContentFrameAvailable};
    OH_NativeImage_SetOnFrameAvailableListener(contentImage_, listener);

    uint64_t surfaceId = 0;
    if (OH_NativeImage_GetSurfaceId(contentImage_, &surfaceId) != 0) {
        GERR("OH_NativeImage_GetSurfaceId failed");
        return;
    }
    {
        std::lock_guard<std::mutex> lock(contentMutex_);
        contentSurfaceId_ = std::to_string(surfaceId);
    }
    GLOG("content image ready: surfaceId=%{public}s", std::to_string(surfaceId).c_str());
}

bool GlesRenderer::UpdateContentTexture(int w, int h) {
    if (contentImage_ == nullptr || contentBlitTex_ == 0 || w <= 0 || h <= 0) {
        return false;
    }
    // 没有新帧（ArkUI 那棵树这一帧没重绘）就沿用上一张 blit 结果，不重复拷贝。
    if (OH_NativeImage_UpdateSurfaceImage(contentImage_) != 0) {
        return false;
    }
    if (OH_NativeImage_GetTransformMatrixV2(contentImage_, contentMatrix_) != 0) {
        OH_NativeImage_GetTransformMatrix(contentImage_, contentMatrix_);
    }
    contentEverValid_.store(true);
    contentFramesTotal_.fetch_add(1);
    // 手里这帧纹理的内容偏移 = 出帧回调锁存的那个值（采样位移的基准）
    heldMirrorOffsetVp_.store(frameMirrorOffsetVp_.load());
    // 导出尺寸同理：ArkTS 在镜像按新高度布局完才下发，此后到来的帧即新尺寸
    frameExportExtraPx_ = ContentExportExtraPx();
    exportPending_.store(false);
    if (!contentLogged_) {
        contentLogged_ = true;
        GLOG("content first frame: m0=%{public}.3f m5=%{public}.3f m12=%{public}.3f m13=%{public}.3f",
             contentMatrix_[0], contentMatrix_[5], contentMatrix_[12], contentMatrix_[13]);
    }
    {
        GpuPassScope gpu(gpuTimer_, kGpuContentBlit);
        ReblitContentTexture(w, h + ContentBandExtraPx());
    }
    if (IsHub() && SharedBackdrop::Get().WantFrames()) {
        PublishSharedBackdrop();
    }
    return true;
}

void GlesRenderer::ReblitContentTexture(int w, int h) {
    // 2D 落点必须已经按当前尺寸（surface + 条带余量）分配好，blit 才是 1:1 的
    if (contentImage_ == nullptr || contentBlitTex_ == 0 || w <= 0 || h <= 0 ||
        contentBlitW_ != w || contentBlitH_ != h) {
        return;
    }
    glBindFramebuffer(GL_FRAMEBUFFER, contentFbo_);
    glViewport(0, 0, w, h);
    glDisable(GL_BLEND);
    glUseProgram(progExtCopy_);
    glActiveTexture(GL_TEXTURE0);
    glBindTexture(GL_TEXTURE_EXTERNAL_OES, contentTex_);
    glUniform1i(Uniform(progExtCopy_, "uExternal"), 0);
    glUniformMatrix4fv(Uniform(progExtCopy_, "uTexMatrix"), 1, GL_FALSE,
                       contentMatrix_);
    // 纹理（导出）比条带目标高时只裁底部：条带目标高 / 导出高（两者下沿都是"条带下沿 - 下余量"）。
    // 导出高按出帧时锁存的值：放开 / 收回整屏的那一两帧里，外纹理尺寸与当前设置未必一致。
    const int exportH = targetH_ + (frameExportExtraPx_ >= 0 ? frameExportExtraPx_ : ContentExportExtraPx());
    glUniform1f(Uniform(progExtCopy_, "uSrcScaleY"),
                exportH > h ? static_cast<float>(h) / static_cast<float>(exportH) : 1.0f);
    glDrawArrays(GL_TRIANGLES, 0, 3);

    glBindFramebuffer(GL_FRAMEBUFFER, 0);
    contentValid_ = true;
}

int GlesRenderer::ContentExportExtraPx() const {
    const float top = contentExportExtraTopVp_.load();
    const float extraTop = top >= 0.0f ? top : contentBandExtraTopVp_.load();
    return static_cast<int>((extraTop + contentBandExtraBottomVp_.load()) * params_.Density() + 0.5f);
}

void GlesRenderer::SetContentExport(float extraTopVp) {
    if (std::fabs(contentExportExtraTopVp_.load() - extraTopVp) > 0.01f) {
        exportPending_.store(true);
    }
    contentExportExtraTopVp_.store(extraTopVp);
    GLOG("content export: extraTop=%{public}.1fvp", extraTopVp);
    RequestRedraw();
}

bool GlesRenderer::SharedBackdropReady() {
    EGLDisplay display = EGL_NO_DISPLAY;
    return SharedBackdrop::Get().HubContext(&display, nullptr) != EGL_NO_CONTEXT &&
           Instance().HasContentFrame();
}

bool GlesRenderer::WantsSharedBackdrop() const {
    return !IsHub() && scene_.load() == static_cast<int>(Scene::kDialog);
}

bool GlesRenderer::PublishSharedBackdrop() {
    if (contentImage_ == nullptr || !contentEverValid_.load() || targetW_ <= 0) {
        return false;
    }
    if (exportPending_.load()) {
        return true;   // 新尺寸的帧还没到：等它来了 UpdateContentTexture 会发布（不算失败，不重试）
    }
    const int w = targetW_;
    const int h = targetH_ + (frameExportExtraPx_ >= 0 ? frameExportExtraPx_ : ContentExportExtraPx());
    SharedBackdrop &shared = SharedBackdrop::Get();
    const int slot = shared.BeginWrite();
    if (slot < 0) {
        sharedRetry_ = true;   // 两张都在用：下一轮重试（消费者读完即释放）
        return false;
    }
    sharedRetry_ = false;
    if (sharedTex_[slot] == 0) {
        glGenTextures(1, &sharedTex_[slot]);
        glGenFramebuffers(1, &sharedFbo_[slot]);
    }
    if (sharedW_[slot] != w || sharedH_[slot] != h) {
        glBindTexture(GL_TEXTURE_2D, sharedTex_[slot]);
        glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, w, h, 0, GL_RGBA, GL_UNSIGNED_BYTE, nullptr);
        SetupTexture(sharedTex_[slot]);
        glBindFramebuffer(GL_FRAMEBUFFER, sharedFbo_[slot]);
        glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D,
                               sharedTex_[slot], 0);
        sharedW_[slot] = w;
        sharedH_[slot] = h;
        GLOG("shared backdrop slot %{public}d allocated %{public}dx%{public}d", slot, w, h);
    }
    GpuPassScope gpu(gpuTimer_, kGpuPublish);
    glBindFramebuffer(GL_FRAMEBUFFER, sharedFbo_[slot]);
    glViewport(0, 0, w, h);
    glDisable(GL_BLEND);
    glDisable(GL_SCISSOR_TEST);
    glUseProgram(progExtCopy_);
    glActiveTexture(GL_TEXTURE0);
    glBindTexture(GL_TEXTURE_EXTERNAL_OES, contentTex_);
    glUniform1i(Uniform(progExtCopy_, "uExternal"), 0);
    glUniformMatrix4fv(Uniform(progExtCopy_, "uTexMatrix"), 1, GL_FALSE,
                       contentMatrix_);
    glUniform1f(Uniform(progExtCopy_, "uSrcScaleY"), 1.0f);
    glDrawArrays(GL_TRIANGLES, 0, 3);
    glBindFramebuffer(GL_FRAMEBUFFER, 0);
    shared.EndWrite(slot, sharedTex_[slot], w, h, heldMirrorOffsetVp_.load());
    return true;
}


void GlesRenderer::ProcessCommandQueue() {
    std::vector<ConsumerCommand> localQueue;
    {
        std::lock_guard<std::mutex> lock(commandMutex_);
        if (commandQueue_.empty()) return;
        localQueue = std::move(commandQueue_);
        commandQueue_.clear();
    }

    std::lock_guard<std::mutex> clock(consumersMutex_);
    for (auto& cmd : localQueue) {
        if (cmd.isAdd) {
            bool found = false;
            for (auto& c : consumers_) {
                if (c.id == cmd.consumer.id) {
                    found = true;
                    if (cmd.consumer.type != ConsumerType::TabBar || c.type == ConsumerType::TabBar) {
                        if (cmd.consumer.rect.width > 0) c.rect = cmd.consumer.rect;
                        c.lagCompensation = cmd.consumer.lagCompensation || c.lagCompensation;
                        if (!cmd.consumer.params.empty()) c.params = cmd.consumer.params;
                    }
                    if (cmd.consumer.type != ConsumerType::TabBar && cmd.consumer.rect.width > 0) {
                        c.type = cmd.consumer.type;
                    }
                    if (cmd.consumer.nativeWindow) c.nativeWindow = cmd.consumer.nativeWindow;
                    if (c.surface == EGL_NO_SURFACE && c.nativeWindow) {
                        auto *nativeWindow = reinterpret_cast<OHNativeWindow *>(c.nativeWindow);
                        if (overlayMode_.load() && c.type == ConsumerType::TabBar) {
                            int32_t format = 0;
                            OH_NativeWindow_NativeWindowHandleOpt(nativeWindow, GET_FORMAT, &format);
                            if (format != NATIVEBUFFER_PIXEL_FMT_RGBA_8888) {
                                OH_NativeWindow_NativeWindowHandleOpt(nativeWindow, SET_FORMAT, NATIVEBUFFER_PIXEL_FMT_RGBA_8888);
                            }
                        }
                        c.surface = eglCreateWindowSurface(display_, config_, reinterpret_cast<EGLNativeWindowType>(nativeWindow), nullptr);
                    }
                    break;
                }
            }
            if (!found) {
                if (cmd.consumer.nativeWindow) {
                    auto *nativeWindow = reinterpret_cast<OHNativeWindow *>(cmd.consumer.nativeWindow);
                    if (overlayMode_.load() && cmd.consumer.type == ConsumerType::TabBar) {
                        int32_t format = 0;
                        OH_NativeWindow_NativeWindowHandleOpt(nativeWindow, GET_FORMAT, &format);
                        if (format != NATIVEBUFFER_PIXEL_FMT_RGBA_8888) {
                            OH_NativeWindow_NativeWindowHandleOpt(nativeWindow, SET_FORMAT, NATIVEBUFFER_PIXEL_FMT_RGBA_8888);
                        }
                    }
                    cmd.consumer.surface = eglCreateWindowSurface(display_, config_, reinterpret_cast<EGLNativeWindowType>(nativeWindow), nullptr);
                } else {
                    cmd.consumer.surface = EGL_NO_SURFACE;
                }
                consumers_.push_back(cmd.consumer);
            }
        } else {
            for (auto it = consumers_.begin(); it != consumers_.end(); ++it) {
                if (it->id == cmd.consumer.id) {
                    if (it->surface != EGL_NO_SURFACE) {
                        eglDestroySurface(display_, it->surface);
                    }
                    consumers_.erase(it);
                    break;
                }
            }
        }
    }
}

void GlesRenderer::RegisterConsumer(const std::string& id, ConsumerType type, const Rect& rect, bool lagCompensation, const std::unordered_map<int, float>& params, void* nativeWindow) {
    std::lock_guard<std::mutex> lock(commandMutex_);
    ConsumerCommand cmd;
    cmd.isAdd = true;
    cmd.consumer.id = id;
    cmd.consumer.type = type;
    cmd.consumer.rect = rect;
    cmd.consumer.lagCompensation = lagCompensation;
    cmd.consumer.params = params;
    cmd.consumer.nativeWindow = nativeWindow;
    commandQueue_.push_back(cmd);
}

void GlesRenderer::UnregisterConsumer(const std::string& id) {
    std::lock_guard<std::mutex> lock(commandMutex_);
    ConsumerCommand cmd;
    cmd.isAdd = false;
    cmd.consumer.id = id;
    commandQueue_.push_back(cmd);
}

void GlesRenderer::SetScrollRegion(float left, float top, float right, float bottom) {
    std::lock_guard<std::mutex> lock(commandMutex_);
    scrollRegionRect_ = {left, top, right, bottom};
}

void GlesRenderer::DestroyGl() {
    gpuTimer_.Destroy();
    uniformCache_.clear();   // 程序名会被复用：缓存随程序一起作废
    if (IsHub()) {
        // 先撤销发布（代际 +1）：消费者之后的 Acquire 全部失败、回退快照，再删纹理
        SharedBackdrop::Get().DetachHub();
        SharedBackdrop::Get().SetHubWake(nullptr);
    }
    if (sharedReaderToken_ != 0) {
        SharedBackdrop::Get().RemoveReader(sharedReaderToken_);
        sharedReaderToken_ = 0;
    }
    sharedGen_ = 0;
    for (int i = 0; i < 2; i++) {
        if (sharedFbo_[i] != 0) { glDeleteFramebuffers(1, &sharedFbo_[i]); sharedFbo_[i] = 0; }
        if (sharedTex_[i] != 0) { glDeleteTextures(1, &sharedTex_[i]); sharedTex_[i] = 0; }
        sharedW_[i] = 0;
        sharedH_[i] = 0;
    }
    if (bgFbo_ != 0) { glDeleteFramebuffers(1, &bgFbo_); bgFbo_ = 0; }
    if (bgTex_ != 0) { glDeleteTextures(1, &bgTex_); bgTex_ = 0; }
    if (blurFbo_[0] != 0) { glDeleteFramebuffers(2, blurFbo_); blurFbo_[0] = 0; }
    if (blurTex_[0] != 0) { glDeleteTextures(2, blurTex_); blurTex_[0] = 0; }
    if (blurFbo2_[0] != 0) { glDeleteFramebuffers(2, blurFbo2_); blurFbo2_[0] = 0; }
    if (blurTex2_[0] != 0) { glDeleteTextures(2, blurTex2_); blurTex2_[0] = 0; }
    if (blurDownFbo_[0][0] != 0) {
        glDeleteFramebuffers(4, &blurDownFbo_[0][0]);
        blurDownFbo_[0][0] = 0;
    }
    if (blurDownTex_[0][0] != 0) {
        glDeleteTextures(4, &blurDownTex_[0][0]);
        blurDownTex_[0][0] = 0;
    }
    if (progBg_ != 0) { glDeleteProgram(progBg_); progBg_ = 0; }
    if (progBlur_ != 0) { glDeleteProgram(progBlur_); progBlur_ = 0; }
    if (progGlass_ != 0) { glDeleteProgram(progGlass_); progGlass_ = 0; }
    if (progIndicator_ != 0) { glDeleteProgram(progIndicator_); progIndicator_ = 0; }
    if (progGlow_ != 0) { glDeleteProgram(progGlow_); progGlow_ = 0; }
    if (progIcon_ != 0) { glDeleteProgram(progIcon_); progIcon_ = 0; }
    if (progSolid_ != 0) { glDeleteProgram(progSolid_); progSolid_ = 0; }
    if (progCopy_ != 0) { glDeleteProgram(progCopy_); progCopy_ = 0; }
    if (progSprite_ != 0) { glDeleteProgram(progSprite_); progSprite_ = 0; }
    if (progProgBlur_ != 0) { glDeleteProgram(progProgBlur_); progProgBlur_ = 0; }
    if (progExtCopy_ != 0) { glDeleteProgram(progExtCopy_); progExtCopy_ = 0; }
    if (contentImage_ != nullptr) {
        OH_NativeImage_DetachContext(contentImage_);
        OH_NativeImage_Destroy(&contentImage_);
        contentImage_ = nullptr;
    }
    if (contentTex_ != 0) { glDeleteTextures(1, &contentTex_); contentTex_ = 0; }
    if (contentBlitTex_ != 0) { glDeleteTextures(1, &contentBlitTex_); contentBlitTex_ = 0; }
    if (contentFbo_ != 0) { glDeleteFramebuffers(1, &contentFbo_); contentFbo_ = 0; }
    {
        std::lock_guard<std::mutex> lock(contentMutex_);
        contentSurfaceId_.clear();
    }
    contentValid_ = false;
    contentEverValid_.store(false);
    contentBlitW_ = 0;
    contentBlitH_ = 0;
    contentLogged_ = false;
    contentBackdrop_.store(false);
    // 纹理没了，锁存的"纹理偏移"与采样位移也就没意义了（下次出帧会重新锁存）
    mirrorOffsetVp_.store(0.0f);
    frameMirrorOffsetVp_.store(0.0f);
    heldMirrorOffsetVp_.store(0.0f);
    contentOffsetVp_.store(0.0f);
    contentLeadVp_.store(0.0f);
    contentLeadMs_.store(0);
    contentShiftVp_.store(0.0f);
    if (sceneFbo_ != 0) { glDeleteFramebuffers(1, &sceneFbo_); sceneFbo_ = 0; }
    if (sceneTex_ != 0) { glDeleteTextures(1, &sceneTex_); sceneTex_ = 0; }
    if (labelTex_ != 0) { glDeleteTextures(1, &labelTex_); labelTex_ = 0; }
    if (labelAccentTex_ != 0) { glDeleteTextures(1, &labelAccentTex_); labelAccentTex_ = 0; }
    if (iconTex_ != 0) { glDeleteTextures(1, &iconTex_); iconTex_ = 0; }
    if (photoTex_ != 0) { glDeleteTextures(1, &photoTex_); photoTex_ = 0; }
    if (contentTextTex_ != 0) { glDeleteTextures(1, &contentTextTex_); contentTextTex_ = 0; }
    if (overlayTextTex_ != 0) { glDeleteTextures(1, &overlayTextTex_); overlayTextTex_ = 0; }
    if (planeIconTex_ != 0) { glDeleteTextures(1, &planeIconTex_); planeIconTex_ = 0; }
    if (dialogBtnLabelTex_ != 0) {
        glDeleteTextures(1, &dialogBtnLabelTex_);
        dialogBtnLabelTex_ = 0;
    }
    dialogBtnLabelW_ = 0;
    dialogBtnLabelH_ = 0;
    planeIconSizePx_ = 0;
    contentTextW_ = 0;
    contentTextH_ = 0;
    overlayTextW_ = 0;
    overlayTextH_ = 0;
    iconTexSizePx_ = 0;
    targetW_ = 0;
    targetH_ = 0;
}

void GlesRenderer::DestroyEgl() {
    if (display_ != EGL_NO_DISPLAY) {
        eglMakeCurrent(display_, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
        if (context_ != EGL_NO_CONTEXT) { eglDestroyContext(display_, context_); }
        if (surface_ != EGL_NO_SURFACE) { eglDestroySurface(display_, surface_); }
        eglTerminate(display_);
    }
    display_ = EGL_NO_DISPLAY;
    surface_ = EGL_NO_SURFACE;
    context_ = EGL_NO_CONTEXT;
    config_ = nullptr;
}

bool GlesRenderer::UploadLabels(int w, int h) {
    // 每次都按当前参数重算尺寸：底板高 / 水平外边距一变，文字位图的**尺寸**也要变。
    // 旧写法只在首次（或 resize）算一次，之后滑这两个滑杆时文字位图仍是旧尺寸，
    // 再被拉伸到新的底板矩形上（文字被拉长）。
    labelW_ = w - static_cast<int>(params_.Px(pid::kOuterPaddingH) * 2.0f);
    labelH_ = static_cast<int>(params_.Px(pid::kBarHeight));
    if (labelW_ <= 0 || labelH_ <= 0 || labelTex_ == 0 || labelAccentTex_ == 0) {
        GERR("UploadLabels: bad label size %{public}dx%{public}d tex=%{public}u/%{public}u",
             labelW_, labelH_, labelTex_, labelAccentTex_);
        return false;
    }
    static const std::vector<std::string> kDefaultLabels{"首页", "搜索", "我的"};
    const auto alphaByte = [](float a) {
        int v = static_cast<int>(a * 255.0f + 0.5f);
        if (v < 0) v = 0;
        if (v > 255) v = 255;
        return static_cast<uint32_t>(v) << 24;
    };
    // 文案 / 图标 / 颜色：ArkTS 配过就用配置的（HallPass），否则用 demo 内置值。
    std::vector<std::string> texts;
    std::vector<std::string> icons;
    uint32_t selArgb = 0;
    uint32_t unselArgb = 0;
    {
        std::lock_guard<std::mutex> lock(tabConfigMutex_);
        if (tabConfig_.custom) {
            texts = tabConfig_.labels;
            icons = tabConfig_.icons;
            selArgb = tabConfig_.selectedArgb;
            unselArgb = tabConfig_.unselectedArgb;
        }
    }
    if (texts.size() != static_cast<size_t>(kTabCount)) {
        texts = kDefaultLabels;
        icons = kTabIconPaths;
        selArgb = alphaByte(params_.N(pid::kLabelSelectedAlpha)) | kTabSelectedRgb;
        unselArgb = alphaByte(params_.N(pid::kLabelUnselectedAlpha)) | kTabUnselectedRgb;
    }
    const float iconGapPx = kTabIconGapDp * params_.Density();
    const float innerPad = TabInnerPadPx();
    // selectedIndex = -1：整条只用一种颜色。两张位图**可以**用不同的图标/字号：
    // 常态 = 槽位尺寸（id 83 / 24），凸显 = 指示器里的尺寸（id 90 / 91，HallPass 对齐
    // ArkUI 版页签条的"选中态图标收小、字放大"）。两层同值时就退化成逐像素同布局。
    const auto rasterize = [&](float iconSizePx, float fontPx, uint32_t argb, LabelBitmap &out) {
        return RenderTabStrip(labelW_, labelH_, texts, icons, -1, iconSizePx, iconGapPx,
                              kTabIconBoldStroke, fontPx, innerPad, argb, argb, out);
    };

    // ① 常态色：形状外（含未被指示器盖住的页签）都读它。
    //    整条不再烘焙选中态 —— 选中色由 ② 在指示器内部叠加，
    //    所以"底座里的选中页签"和别的一样是常态色（对齐参考实现的图层顺序）。
    LabelBitmap labels;
    if (!rasterize(params_.Px(pid::kTabIconSize), params_.Px(pid::kLabelFontSize), unselArgb,
                   labels)) {
        GERR("RenderTabStrip failed");
        return false;
    }
    glBindTexture(GL_TEXTURE_2D, labelTex_);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, labels.width, labels.height, 0, GL_RGBA,
                 GL_UNSIGNED_BYTE, labels.pixels.data());
    SetupTexture(labelTex_);

    // ② 强调色：整条都是凸显色，只有指示器透镜里才会采到它。
    //    尺寸走 id 90 / 91（HallPass = ArkUI 版指示器里的 24.4 / 9.3）。
    LabelBitmap accent;
    if (!rasterize(params_.Px(pid::kTabIconSizeAccent), params_.Px(pid::kLabelFontSizeAccent),
                   selArgb, accent)) {
        GERR("RenderTabStrip (accent) failed");
        return false;
    }
    glBindTexture(GL_TEXTURE_2D, labelAccentTex_);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, accent.width, accent.height, 0, GL_RGBA,
                 GL_UNSIGNED_BYTE, accent.pixels.data());
    SetupTexture(labelAccentTex_);

    GLOG("label textures %{public}dx%{public}d uploaded, selected=%{public}d",
         labels.width, labels.height, selectedTab_);
    return true;
}

bool GlesRenderer::UploadIcons(int iconSizePx) {
    if (iconSizePx <= 0 || iconTex_ == 0) {
        return false;
    }
    LabelBitmap icons;
    if (!RenderGlassIcons(iconSizePx, icons)) {
        GERR("RenderGlassIcons failed (size=%{public}d)", iconSizePx);
        return false;
    }
    glBindTexture(GL_TEXTURE_2D, iconTex_);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, icons.width, icons.height, 0, GL_RGBA,
                 GL_UNSIGNED_BYTE, icons.pixels.data());
    SetupTexture(iconTex_);
    iconTexSizePx_ = iconSizePx;
    GLOG("icon texture %{public}dx%{public}d uploaded", icons.width, icons.height);
    return true;
}

bool GlesRenderer::EnsureTargets(int w, int h) {
    if (w <= 0 || h <= 0) {
        return false;
    }
    // 内容纹理的尺寸还取决于镜像条带余量（SetContentBand 可能在分配之后才到），
    // 所以尺寸判断要把它算进来 —— 余量变了也要重建（其余目标尺寸不变，一并重建无妨）。
    if (w == targetW_ && h == targetH_ &&
        (IsWidgetMode() || h + ContentBandExtraPx() == contentBlitH_)) {
        return true;
    }
    targetW_ = w;
    targetH_ = h;
    forceRedraw_.store(true);   // 尺寸变了必须重画

    // 内联控件只需要一张 sceneTex_（底色 + 轨道；旋钮直接叠在屏幕上），
    // 不建模糊链 / 文字 / 照片那几套目标。
    if (IsWidgetMode()) {
        glBindTexture(GL_TEXTURE_2D, sceneTex_);
        glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, w, h, 0, GL_RGBA, GL_UNSIGNED_BYTE, nullptr);
        SetupTexture(sceneTex_);
        glBindFramebuffer(GL_FRAMEBUFFER, sceneFbo_);
        glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, sceneTex_, 0);
        const GLenum widgetStatus = glCheckFramebufferStatus(GL_FRAMEBUFFER);
        glBindFramebuffer(GL_FRAMEBUFFER, 0);
        if (widgetStatus != GL_FRAMEBUFFER_COMPLETE) {
            GERR("widget FBO incomplete: 0x%{public}x", widgetStatus);
            return false;
        }
        GLOG("widget targets resized: %{public}d x %{public}d", w, h);
        return true;
    }

    glBindTexture(GL_TEXTURE_2D, bgTex_);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, w, h, 0, GL_RGBA, GL_UNSIGNED_BYTE, nullptr);
    SetupTexture(bgTex_);
    glBindFramebuffer(GL_FRAMEBUFFER, bgFbo_);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, bgTex_, 0);

    for (int i = 0; i < 2; i++) {
        glBindTexture(GL_TEXTURE_2D, blurTex_[i]);
        glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, w, h, 0, GL_RGBA, GL_UNSIGNED_BYTE, nullptr);
        SetupTexture(blurTex_[i]);
        glBindFramebuffer(GL_FRAMEBUFFER, blurFbo_[i]);
        glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, blurTex_[i], 0);
        // 按钮专用模糊链（半径与底座不同，见 DrawFrame 的 pass 2b）
        glBindTexture(GL_TEXTURE_2D, blurTex2_[i]);
        glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, w, h, 0, GL_RGBA, GL_UNSIGNED_BYTE, nullptr);
        SetupTexture(blurTex2_[i]);
        glBindFramebuffer(GL_FRAMEBUFFER, blurFbo2_[i]);
        glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, blurTex2_[i],
                               0);
    }
    // 主模糊链的降采样金字塔：level 0 = 1/2 分辨率，level 1 = 1/4（见 RenderBlur）
    for (int level = 0; level < 2; level++) {
        const int lw = std::max(1, w >> (level + 1));
        const int lh = std::max(1, h >> (level + 1));
        blurDownW_[level] = lw;
        blurDownH_[level] = lh;
        for (int i = 0; i < 2; i++) {
            glBindTexture(GL_TEXTURE_2D, blurDownTex_[level][i]);
            glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, lw, lh, 0, GL_RGBA, GL_UNSIGNED_BYTE,
                         nullptr);
            SetupTexture(blurDownTex_[level][i]);
            glBindFramebuffer(GL_FRAMEBUFFER, blurDownFbo_[level][i]);
            glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D,
                                   blurDownTex_[level][i], 0);
        }
    }
    glBindTexture(GL_TEXTURE_2D, sceneTex_);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, w, h, 0, GL_RGBA, GL_UNSIGNED_BYTE, nullptr);
    SetupTexture(sceneTex_);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glBindFramebuffer(GL_FRAMEBUFFER, sceneFbo_);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, sceneTex_, 0);
    GLenum status = glCheckFramebufferStatus(GL_FRAMEBUFFER);
    glBindFramebuffer(GL_FRAMEBUFFER, 0);
    if (status != GL_FRAMEBUFFER_COMPLETE) {
        GERR("FBO incomplete: 0x%{public}x", status);
        return false;
    }

    // ArkTS 内容外纹理的 2D 落点（= **镜像条带**尺寸：宽与 surface 相同、高 = surface + 上下余量；
    // 导出节点铺满同一矩形）。尺寸变化后旧帧作废；若已经有过内容帧，立刻用外纹理里保留的
    // 最后一帧补一张同样尺寸的（生产端可能已经静止不再产帧，不补就会一直空着）。
    const int contentH = h + ContentBandExtraPx();
    glBindTexture(GL_TEXTURE_2D, contentBlitTex_);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, w, contentH, 0, GL_RGBA, GL_UNSIGNED_BYTE, nullptr);
    SetupTexture(contentBlitTex_);
    glBindFramebuffer(GL_FRAMEBUFFER, contentFbo_);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, contentBlitTex_,
                           0);
    GLenum contentStatus = glCheckFramebufferStatus(GL_FRAMEBUFFER);
    glBindFramebuffer(GL_FRAMEBUFFER, 0);
    if (contentStatus != GL_FRAMEBUFFER_COMPLETE) {
        GERR("content FBO incomplete: 0x%{public}x", contentStatus);
        return false;
    }
    contentBlitW_ = w;
    contentBlitH_ = contentH;
    contentValid_ = false;
    if (contentEverValid_.load()) {
        ReblitContentTexture(w, contentH);
    }

    // ---- 文字纹理：底板区域，用 native_drawing 栅格化 ----
    // 内联控件不画文字，跳过这步（labelTex_ 保持空即可，DrawWidgetScene 不采样它）。
    if (!IsWidgetMode()) {
        labelW_ = w - static_cast<int>(params_.Px(pid::kOuterPaddingH) * 2.0f);
        labelH_ = static_cast<int>(params_.Px(pid::kBarHeight));
        UploadLabels(w, h);
        // 目录场景的文字位图与屏幕尺寸相关，尺寸变了要重传
        contentTextDirty_.store(true);
        overlayTextDirty_.store(true);
        dialogBtnLabelDirty_.store(true);
    }

    GLOG("targets resized: %{public}d x %{public}d", w, h);
    return true;
}

// ---------------------------------------------------------------------------
// 高斯模糊链
// ---------------------------------------------------------------------------

GLuint GlesRenderer::BlurFullRes(GLuint sourceTex, float radiusPx, GLuint fboPair[2],
                                 GLuint texPair[2]) {
    // 剪裁状态由调用方决定：RenderButtonBlur 裁到按钮带、RenderBlur 可传底板裁剪盒。
    // （旧版这里无条件 glDisable(GL_SCISSOR_TEST)，按钮模糊的裁剪因此从未生效、两趟都是整屏。）
    GLuint src = sourceTex;
    for (int pass = 0; pass < 2; pass++) {
        glBindFramebuffer(GL_FRAMEBUFFER, fboPair[pass]);
        glViewport(0, 0, targetW_, targetH_);
        glDisable(GL_BLEND);
        glUseProgram(progBlur_);
        glActiveTexture(GL_TEXTURE0);
        glBindTexture(GL_TEXTURE_2D, src);
        glUniform1i(Uniform(progBlur_, "uSource"), 0);
        glUniform2f(Uniform(progBlur_, "uTexel"),
                    1.0f / static_cast<float>(targetW_),
                    1.0f / static_cast<float>(targetH_));
        glUniform2f(Uniform(progBlur_, "uDir"), pass == 0 ? 1.0f : 0.0f,
                    pass == 0 ? 0.0f : 1.0f);
        glUniform1f(Uniform(progBlur_, "uRadius"), radiusPx);
        glDrawArrays(GL_TRIANGLES, 0, 3);
        src = texPair[pass];
    }
    return texPair[1];
}

GLuint GlesRenderer::RenderButtonBlur(GLuint sourceTex, float radiusPx) {
    // 这张结果只有按钮会采样，所以两次模糊只算按钮那一块（外扩 4×半径覆盖 9-tap 支撑域）
    float btnRowLeft = 0.0f;
    float btnRowBottom = 0.0f;
    ButtonRectPx(0, targetW_, targetH_, &btnRowLeft, &btnRowBottom);
    const float btnRowW = static_cast<float>(kIconButtonCount) * ButtonSizePx() +
                          static_cast<float>(kIconButtonCount - 1) * ButtonSpacingPx();
    glEnable(GL_SCISSOR_TEST);
    SetScissorRect(btnRowLeft, btnRowBottom, btnRowW, ButtonSizePx(), radiusPx * 4.0f + 8.0f,
                   targetW_, targetH_);
    const GLuint result = BlurFullRes(sourceTex, radiusPx, blurFbo2_, blurTex2_);
    glDisable(GL_SCISSOR_TEST);
    return result;
}

GLuint GlesRenderer::RenderBlur(GLuint sourceTex, float radiusPx, const RectF *clip) {
    glDisable(GL_SCISSOR_TEST);
    if (radiusPx < kBlurPyramidHalfMinPx) {
        // 全分辨率两趟：可按调用方给的裁剪盒（屏幕 px，GL 坐标）只算需要的那一块
        if (clip != nullptr) {
            glEnable(GL_SCISSOR_TEST);
            SetScissorRect(clip->x, clip->y, clip->w, clip->h, 0.0f, targetW_, targetH_);
        }
        const GLuint result = BlurFullRes(sourceTex, radiusPx, blurFbo_, blurTex_);
        glDisable(GL_SCISSOR_TEST);
        return result;
    }
    // 大半径：逐级降采样后在低分辨率上做同样的两趟可分离。
    // 上一级结果直接当下一级的源，最后一级的结果交给玻璃 shader 线性采样（= 双线性上采样）。
    smoothCacheTex_ = 0;   // 金字塔纹理被复用：平滑模糊缓存作废
    const int levels = (radiusPx >= kBlurPyramidQuarterMinPx) ? 2 : 1;
    GLuint src = sourceTex;
    int srcW = targetW_;
    int srcH = targetH_;
    GLuint result = sourceTex;
    for (int level = 0; level < levels; level++) {
        const int lw = blurDownW_[level];
        const int lh = blurDownH_[level];
        if (lw <= 0 || lh <= 0) {
            break;
        }
        // 降采样：radius=0 时 9-tap 权重和恰为 1，等价一次线性采样 → 写进本级的 ping 纹理
        glBindFramebuffer(GL_FRAMEBUFFER, blurDownFbo_[level][0]);
        glViewport(0, 0, lw, lh);
        glDisable(GL_BLEND);
        glUseProgram(progBlur_);
        glActiveTexture(GL_TEXTURE0);
        glBindTexture(GL_TEXTURE_2D, src);
        glUniform1i(Uniform(progBlur_, "uSource"), 0);
        glUniform2f(Uniform(progBlur_, "uTexel"),
                    1.0f / static_cast<float>(srcW), 1.0f / static_cast<float>(srcH));
        glUniform2f(Uniform(progBlur_, "uDir"), 1.0f, 0.0f);
        glUniform1f(Uniform(progBlur_, "uRadius"), 0.0f);
        glDrawArrays(GL_TRIANGLES, 0, 3);

        // 本级两趟：0 → 1（横向）、1 → 0（纵向）；半径也按级缩放，屏幕空间跨度不变
        const float levelRadius = radiusPx / static_cast<float>(1 << (level + 1));
        for (int pass = 0; pass < 2; pass++) {
            glBindFramebuffer(GL_FRAMEBUFFER, blurDownFbo_[level][1 - pass]);
            glViewport(0, 0, lw, lh);
            glDisable(GL_BLEND);
            glUseProgram(progBlur_);
            glActiveTexture(GL_TEXTURE0);
            glBindTexture(GL_TEXTURE_2D, blurDownTex_[level][pass]);
            glUniform1i(Uniform(progBlur_, "uSource"), 0);
            glUniform2f(Uniform(progBlur_, "uTexel"),
                        1.0f / static_cast<float>(lw), 1.0f / static_cast<float>(lh));
            glUniform2f(Uniform(progBlur_, "uDir"), pass == 0 ? 1.0f : 0.0f,
                        pass == 0 ? 0.0f : 1.0f);
            glUniform1f(Uniform(progBlur_, "uRadius"), levelRadius);
            glDrawArrays(GL_TRIANGLES, 0, 3);
        }
        src = blurDownTex_[level][0];
        srcW = lw;
        srcH = lh;
        result = src;
    }
    return result;
}

GLuint GlesRenderer::RenderBlurSmooth(GLuint sourceTex, float sigmaPx, const RectF *clip) {
    // kBlurShader 的 9 tap 权重 ≈ sigma 2 个步距；步距 = uRadius 个纹素。步距一旦远大于 1 纹素，
    // 输出就不是模糊而是 9 份错开的拷贝（文字背景上表现为重复的字 / 竖纹）。
    // 这里步距固定 1.5 纹素（双线性仍连续），每轮 H+V 贡献 sigma 3 纹素，按方差叠加迭代。
    glDisable(GL_SCISSOR_TEST);
    glDisable(GL_BLEND);
    glUseProgram(progBlur_);
    glActiveTexture(GL_TEXTURE0);
    glUniform1i(Uniform(progBlur_, "uSource"), 0);
    const GLint locTexel = Uniform(progBlur_, "uTexel");
    const GLint locDir = Uniform(progBlur_, "uDir");
    const GLint locRadius = Uniform(progBlur_, "uRadius");

    // 降采样级数按 sigma 选：每级 = 2×2 盒式预过滤（radius 0 在纹素交点处一次线性采样）。
    // 级数不能固定 1/4：小 sigma 时 1/4 的 4×4 盒在模糊后仍看得出来，经透镜放大成方格纹。
    // 保证本级 sigma ≥ ~3 纹素（盒格完全被模糊盖住）：< 14px 走 1/2，否则 1/4。
    const int levels = sigmaPx >= 14.0f ? 2 : 1;
    // 裁剪：每级按该级分辨率缩放矩形（+2 纹素给双线性 / 盒式预过滤），整套 pass 只算玻璃会采样的那块
    const auto clipLevel = [this, clip](int lw, int lh) {
        if (clip == nullptr) {
            glDisable(GL_SCISSOR_TEST);
            return;
        }
        const float sx = static_cast<float>(lw) / static_cast<float>(std::max(1, targetW_));
        const float sy = static_cast<float>(lh) / static_cast<float>(std::max(1, targetH_));
        glEnable(GL_SCISSOR_TEST);
        SetScissorRect(clip->x * sx, clip->y * sy, clip->w * sx, clip->h * sy, 2.0f, lw, lh);
    };
    GLuint src = sourceTex;
    int srcW = targetW_;
    int srcH = targetH_;
    for (int level = 0; level < levels; level++) {
        if (blurDownW_[level] <= 0 || blurDownH_[level] <= 0) {
            glDisable(GL_SCISSOR_TEST);
            return RenderBlur(sourceTex, sigmaPx);
        }
        glBindFramebuffer(GL_FRAMEBUFFER, blurDownFbo_[level][0]);
        glViewport(0, 0, blurDownW_[level], blurDownH_[level]);
        clipLevel(blurDownW_[level], blurDownH_[level]);
        glBindTexture(GL_TEXTURE_2D, src);
        glUniform2f(locTexel, 1.0f / static_cast<float>(srcW), 1.0f / static_cast<float>(srcH));
        glUniform2f(locDir, 1.0f, 0.0f);
        glUniform1f(locRadius, 0.0f);
        glDrawArrays(GL_TRIANGLES, 0, 3);
        src = blurDownTex_[level][0];
        srcW = blurDownW_[level];
        srcH = blurDownH_[level];
    }

    const float scaleToLevel = static_cast<float>(srcW) / static_cast<float>(std::max(1, targetW_));
    const float sigmaTex = sigmaPx * scaleToLevel;
    constexpr float kStep = 1.5f;
    constexpr float kSigmaPerIter = 2.0f * kStep;
    const int iters = std::min(16, std::max(1, static_cast<int>(
        std::ceil((sigmaTex * sigmaTex) / (kSigmaPerIter * kSigmaPerIter)))));
    glUniform2f(locTexel, 1.0f / static_cast<float>(srcW), 1.0f / static_cast<float>(srcH));
    glUniform1f(locRadius, kStep);
    const int last = levels - 1;
    for (int i = 0; i < iters; i++) {
        for (int pass = 0; pass < 2; pass++) {
            glBindFramebuffer(GL_FRAMEBUFFER, blurDownFbo_[last][1 - pass]);
            glViewport(0, 0, srcW, srcH);
            glBindTexture(GL_TEXTURE_2D, blurDownTex_[last][pass]);
            glUniform2f(locDir, pass == 0 ? 1.0f : 0.0f, pass == 0 ? 0.0f : 1.0f);
            glDrawArrays(GL_TRIANGLES, 0, 3);
        }
    }
    glDisable(GL_SCISSOR_TEST);
    smoothCacheSrc_ = sourceTex;
    smoothCacheSigma_ = sigmaPx;
    smoothCacheTex_ = blurDownTex_[last][0];
    return blurDownTex_[last][0];
}

// ===========================================================================
// 目录场景：通用绘制原语
// ===========================================================================

void GlesRenderer::BlitTexture(GLuint tex, int w, int h) {
    glBindFramebuffer(GL_FRAMEBUFFER, 0);
    glViewport(0, 0, w, h);
    glDisable(GL_BLEND);
    glUseProgram(progCopy_);
    glActiveTexture(GL_TEXTURE0);
    glBindTexture(GL_TEXTURE_2D, tex);
    glUniform1i(Uniform(progCopy_, "uSource"), 0);
    glDrawArrays(GL_TRIANGLES, 0, 3);
}

void GlesRenderer::CopyBackgroundToScene(int w, int h) {
    glBindFramebuffer(GL_FRAMEBUFFER, sceneFbo_);
    glViewport(0, 0, w, h);
    glDisable(GL_BLEND);
    glUseProgram(progCopy_);
    glActiveTexture(GL_TEXTURE0);
    glBindTexture(GL_TEXTURE_2D, bgTex_);
    glUniform1i(Uniform(progCopy_, "uSource"), 0);
    glDrawArrays(GL_TRIANGLES, 0, 3);
}

GlesRenderer::GlassSpec GlesRenderer::DefaultGlass(float x, float y, float w, float h, float radius,
                                                   float d) const {
    GlassSpec s;
    s.x = x;
    s.y = y;
    s.w = w;
    s.h = h;
    s.rTL = radius;
    s.rTR = radius;
    s.rBR = radius;
    s.rBL = radius;
    s.highlight = 0.5f;   // Highlight.Default（白 alpha 0.5，加法混合）
    s.highlightWidthPx = std::max(1.0f, std::ceil(0.5f * d));
    s.highlightBlurPx = s.highlightWidthPx * 0.5f;
    s.hasShadow = true;
    s.shadowBlurPx = 24.0f * d;   // Shadow.Default：radius 24dp / offset radius/6 / 黑 0.1
    s.shadowOffsetPx = 4.0f * d;
    s.shadowAlpha = 0.1f;
    return s;
}

GlesRenderer::GlassSpec GlesRenderer::KnobGlass(float x, float y, float w, float h, float d,
                                                float press) const {
    // 开关（Toggle）与滑块（Slider）的旋钮**共用**这一套材质：两个场景长得一样，
    // 参数分头改很容易漂移，统一放这里（要调就一起调）。
    // - 阴影（外投影 / 内阴影 / 棱边高光）默认全关，由各自场景按按压进度补
    //   （见 DrawToggleCore / DrawSliderCore 的 HallPass 段）
    // - 静止时是纯白旋钮；按下后白面**很快**褪干净（不留选中底色 / 表面白），只留纯玻璃
    // - 折射半径稍小、强度按需：边缘的"液态"弯折
    GlassSpec s = DefaultGlass(x, y, w, h, h * 0.5f, d);
    s.hasShadow = false;
    s.shadowAlpha = 0.0f;
    s.innerAlpha = 0.0f;
    s.surfaceAlpha = std::max(0.0f, 1.0f - 1.5f * press);
    s.blurRadiusPx = 8.0f * d * (1.0f - press);
    s.refractionHeight = 4.0f * d * press;
    s.refractionAmount = 15.0f * d * press;
    s.dispersion = true;
    s.highlight = 0.0f;
    s.ambient = press > 0.001f;
    s.ambientIntensity = 0.38f * press;
    s.highlightWidthPx = std::max(1.0f, std::ceil(0.333f * d));
    s.highlightBlurPx = s.highlightWidthPx * 0.5f;
    // 按压采样缩小：绕旋钮中心（形状的按压缩放也绕中心，两者同心）
    const float sampleScale = 1.0f - kKnobPressSampleShrink * press;
    s.sampleScaleX = sampleScale;
    s.sampleScaleY = sampleScale;
    s.samplePivotX = x + w * 0.5f;
    s.samplePivotY = y + h * 0.5f;
    return s;
}

void GlesRenderer::DrawSolid(const SolidSpec &spec, int w, int h) {
    GLuint prog = progSolid_;
    if (prog == 0) return;
    // 混合状态由本函数自己保证：调用方可能刚画过文字（那边会关混合），
    // 若混着用，未乘覆盖率的 RGB 会整屏写出去（放大镜光标就踩过这个坑）。
    glEnable(GL_BLEND);
    glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
    glUseProgram(prog);
    float rTL = spec.r;
    float rTR = spec.r;
    float rBR = spec.r;
    float rBL = spec.r;
    if (spec.r <= 0.0f) {
        rTL = spec.rTL;
        rTR = spec.rTR;
        rBR = spec.rBR;
        rBL = spec.rBL;
    }
    glUniform2f(Uniform(prog, "uResolution"), static_cast<float>(w),
                static_cast<float>(h));
    glUniform4f(Uniform(prog, "uRect"), spec.x, spec.y, spec.w, spec.h);
    glUniform4f(Uniform(prog, "uRadii"), rTL, rTR, rBR, rBL);
    glUniform4f(Uniform(prog, "uColor"), spec.colorR, spec.colorG, spec.colorB,
                spec.a);
    glDrawArrays(GL_TRIANGLES, 0, 3);
}

void GlesRenderer::DrawSprite(GLuint tex, float x, float y, float w, float h, int screenW,
                              int screenH, float alpha) {
    if (tex == 0 || w <= 0.0f || h <= 0.0f) {
        return;
    }
    // 位图是**预乘 alpha**：混合函数固定 (ONE, ONE_MINUS_SRC_ALPHA)，由本函数保证
    glEnable(GL_BLEND);
    glBlendFunc(GL_ONE, GL_ONE_MINUS_SRC_ALPHA);
    glUseProgram(progSprite_);
    glActiveTexture(GL_TEXTURE0);
    glBindTexture(GL_TEXTURE_2D, tex);
    glUniform1i(Uniform(progSprite_, "uSprite"), 0);
    glUniform2f(Uniform(progSprite_, "uResolution"), static_cast<float>(screenW),
                static_cast<float>(screenH));
    glUniform4f(Uniform(progSprite_, "uRect"), x, y, w, h);
    glUniform1f(Uniform(progSprite_, "uAlpha"), alpha);
    glDrawArrays(GL_TRIANGLES, 0, 3);
}

GLuint GlesRenderer::BlurFor(GLuint sourceTex, float radiusPx, int w, int h) {
    if (radiusPx <= 0.01f) {
        return sourceTex;
    }
    if (blurCacheTex_ != 0 && blurCacheSrc_ == sourceTex &&
        std::fabs(radiusPx - blurCacheRadius_) < 0.01f) {
        return blurCacheTex_;
    }
    blurCacheTex_ = RenderBlur(sourceTex, radiusPx);
    blurCacheRadius_ = radiusPx;
    blurCacheSrc_ = sourceTex;
    return blurCacheTex_;
}

void GlesRenderer::DrawGlass(const GlassSpec &s, GLuint targetFbo, int w, int h) {
    // 形状被 scaleX/scaleY 放大时，笔刷范围要跟着外扩，否则旋钮上下会被 scissor 切平。
    const float scalePad = 0.5f * std::max(s.w * std::max(0.0f, s.scaleX - 1.0f),
                                           s.h * std::max(0.0f, s.scaleY - 1.0f));
    const float shadowPad =
        std::max(2.0f, s.shadowBlurPx + std::fabs(s.shadowOffsetPx) + 4.0f) + scalePad;
    // ⚠️ 顺序：先算模糊。RenderBlur 会切换 FBO / viewport 并画全屏三角形，
    // 必须在开启局部剪裁测试（GL_SCISSOR_TEST）之前计算，否则降采样/金字塔 FBO
    // 会被全分辨率的局部剪裁盒直接剔除所有像素，导致模糊纹理全黑（黑胶囊根因）。
    const GLuint backdropTex = s.useBackground ? bgTex_ : sceneTex_;
    GLuint blurredTex = 0;
    if (s.gpuPass >= 0) {
        gpuTimer_.Begin(kGpuBlur);
    }
    if (s.smoothBlur && s.blurRadiusPx > 0.01f) {
        // 同源同 sigma 的第二次调用（嵌入式弹窗的面板：先进 sceneTex_、再上屏）直接复用
        if (smoothCacheTex_ != 0 && smoothCacheSrc_ == backdropTex &&
            std::fabs(smoothCacheSigma_ - s.blurRadiusPx) < 0.01f) {
            blurredTex = smoothCacheTex_;
        } else {
            blurredTex = RenderBlurSmooth(backdropTex, s.blurRadiusPx, s.blurClip);
        }
        // 复用了金字塔纹理：作废主链缓存，下一个调用方重新算
        blurCacheRadius_ = -1.0f;
        blurCacheSrc_ = 0;
    } else {
        blurredTex = BlurFor(backdropTex, s.blurRadiusPx, w, h);
    }
    if (s.gpuPass >= 0) {
        gpuTimer_.End();
        gpuTimer_.Begin(s.gpuPass);
    }

    glBindFramebuffer(GL_FRAMEBUFFER, targetFbo);
    glViewport(0, 0, w, h);
    glEnable(GL_BLEND);
    glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
    glEnable(GL_SCISSOR_TEST);
    {
        float x0 = s.x - shadowPad;
        float y0 = s.y - shadowPad;
        float x1 = s.x + s.w + shadowPad;
        float y1 = s.y + s.h + shadowPad;
        if (s.drawClip != nullptr) {
            x0 = std::max(x0, s.drawClip->x);
            y0 = std::max(y0, s.drawClip->y);
            x1 = std::min(x1, s.drawClip->x + s.drawClip->w);
            y1 = std::min(y1, s.drawClip->y + s.drawClip->h);
        }
        SetScissorRect(x0, y0, std::max(0.0f, x1 - x0), std::max(0.0f, y1 - y0), 0.0f, w, h);
    }
    glUseProgram(progGlass_);
    glActiveTexture(GL_TEXTURE0);
    glBindTexture(GL_TEXTURE_2D, backdropTex);
    glUniform1i(Uniform(progGlass_, "uBackdrop"), 0);
    glActiveTexture(GL_TEXTURE1);
    glBindTexture(GL_TEXTURE_2D, blurredTex);
    glUniform1i(Uniform(progGlass_, "uBlurred"), 1);
    glActiveTexture(GL_TEXTURE2);
    glBindTexture(GL_TEXTURE_2D, labelTex_);
    glUniform1i(Uniform(progGlass_, "uLabels"), 2);
    glUniform2f(Uniform(progGlass_, "uLabelSize"), 1.0f, 1.0f);
    glUniform2f(Uniform(progGlass_, "uResolution"), static_cast<float>(w),
                static_cast<float>(h));
    glUniform2f(Uniform(progGlass_, "uTexel"), 1.0f / static_cast<float>(w),
                1.0f / static_cast<float>(h));
    glUniform4f(Uniform(progGlass_, "uGlassRect"), s.x, s.y, s.w, s.h);
    glUniform4f(Uniform(progGlass_, "uRadii"), s.rTL, s.rTR, s.rBR, s.rBL);
    glUniform1f(Uniform(progGlass_, "uScaleX"), s.scaleX);
    glUniform1f(Uniform(progGlass_, "uScaleY"), s.scaleY);
    glUniform1f(Uniform(progGlass_, "uRefractionHeight"), s.refractionHeight);
    glUniform1f(Uniform(progGlass_, "uRefractionAmount"), -s.refractionAmount);
    glUniform1f(Uniform(progGlass_, "uDispersion"), s.dispersion ? 1.0f : 0.0f);
    glUniform1f(Uniform(progGlass_, "uDepthEffect"), s.depthEffect ? 1.0f : 0.0f);
    glUniform1f(Uniform(progGlass_, "uSurfaceAlpha"), s.surfaceAlpha);
    glUniform3f(Uniform(progGlass_, "uSurfaceColor"), s.surfaceR, s.surfaceG,
                s.surfaceB);
    glUniform1f(Uniform(progGlass_, "uBlurRadius"), s.blurRadiusPx);
    glUniform1f(Uniform(progGlass_, "uVibrancy"), s.vibrancy);
    glUniform1f(Uniform(progGlass_, "uBrightness"), s.brightness);
    glUniform1f(Uniform(progGlass_, "uContrast"), s.contrast);
    glUniform1f(Uniform(progGlass_, "uSaturation"), s.saturation);
    glUniform1f(Uniform(progGlass_, "uEffectOpacity"), s.effectOpacity);
    glUniform1f(Uniform(progGlass_, "uPlainHighlight"), s.plainHighlight ? 1.0f : 0.0f);
    glUniform1f(Uniform(progGlass_, "uHighlight"), s.highlight);
    glUniform1f(Uniform(progGlass_, "uHighlightWidth"), s.highlightWidthPx);
    glUniform1f(Uniform(progGlass_, "uHighlightBlur"), s.highlightBlurPx);
    glUniform1f(Uniform(progGlass_, "uAmbient"), s.ambient ? 1.0f : 0.0f);
    glUniform1f(Uniform(progGlass_, "uAmbientIntensity"), s.ambientIntensity);
    glUniform1f(Uniform(progGlass_, "uShadowBlur"), s.shadowBlurPx);
    glUniform1f(Uniform(progGlass_, "uShadowOffset"), s.shadowOffsetPx);
    glUniform1f(Uniform(progGlass_, "uShadowAlpha"), s.shadowAlpha);
    glUniform1f(Uniform(progGlass_, "uShadowSpreadV"), s.shadowSpreadV);
    glUniform1f(Uniform(progGlass_, "uShadow"), s.hasShadow ? 1.0f : 0.0f);
    glUniform1f(Uniform(progGlass_, "uInnerRadius"), s.innerRadiusPx);
    glUniform1f(Uniform(progGlass_, "uInnerAlpha"), s.innerAlpha);
    glUniform1f(Uniform(progGlass_, "uInnerTopBias"), s.innerTopBias);
    glUniform1f(Uniform(progGlass_, "uInnerTopCut"), s.innerTopCut);
    glUniform1f(Uniform(progGlass_, "uInnerSharp"), s.innerSharp);
    glUniform1f(Uniform(progGlass_, "uInnerTaper"), s.innerTaper);
    glUniform2f(Uniform(progGlass_, "uSampleScale"), s.sampleScaleX, s.sampleScaleY);
    glUniform2f(Uniform(progGlass_, "uSamplePivot"), s.samplePivotX, s.samplePivotY);
    glUniform1f(Uniform(progGlass_, "uG2Factor"), s.g2Factor);
    glUniform1f(Uniform(progGlass_, "uRimClarity"), s.rimClarity);
    glUniform1f(Uniform(progGlass_, "uBevelAlphaScale"), s.bevelAlphaScale);
    glUniform1f(Uniform(progGlass_, "uIsland"), 0.0f);
    glUniform1f(Uniform(progGlass_, "uIndicatorFill"), 0.0f);
    glUniform1f(Uniform(progGlass_, "uShowLabels"), 0.0f);
    glUniform1f(Uniform(progGlass_, "uOverlayMode"), 1.0f);
    glDrawArrays(GL_TRIANGLES, 0, 3);
    glDisable(GL_SCISSOR_TEST);
    glDisable(GL_BLEND);
    if (s.gpuPass >= 0) {
        gpuTimer_.End();
    }
}

// ===========================================================================
// 目录场景：文字层
// ===========================================================================

bool GlesRenderer::UploadContentText(int w, int h) {
    std::vector<TextRun> runs;
    if (!BuildContentText(scene_.load(), w, h, runs) || runs.empty()) {
        contentTextW_ = 0;
        contentTextH_ = 0;
        return false;
    }
    LabelBitmap bitmap;
    if (!RenderTextOverlay(contentTextW_, contentTextH_, runs, bitmap)) {
        contentTextW_ = 0;
        contentTextH_ = 0;
        return false;
    }
    glBindTexture(GL_TEXTURE_2D, contentTextTex_);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, bitmap.width, bitmap.height, 0, GL_RGBA,
                 GL_UNSIGNED_BYTE, bitmap.pixels.data());
    SetupTexture(contentTextTex_);
    GLOG("content text texture %{public}dx%{public}d uploaded", bitmap.width, bitmap.height);
    return true;
}

bool GlesRenderer::UploadOverlayText(int w, int h) {
    std::vector<TextRun> runs;
    if (!BuildOverlayText(scene_.load(), w, h, runs) || runs.empty()) {
        overlayTextW_ = 0;
        overlayTextH_ = 0;
        return false;
    }
    LabelBitmap bitmap;
    if (!RenderTextOverlay(overlayTextW_, overlayTextH_, runs, bitmap)) {
        overlayTextW_ = 0;
        overlayTextH_ = 0;
        return false;
    }
    glBindTexture(GL_TEXTURE_2D, overlayTextTex_);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, bitmap.width, bitmap.height, 0, GL_RGBA,
                 GL_UNSIGNED_BYTE, bitmap.pixels.data());
    SetupTexture(overlayTextTex_);
    GLOG("overlay text texture %{public}dx%{public}d uploaded", bitmap.width, bitmap.height);
    return true;
}

void GlesRenderer::DrawContentText(int w, int h) {
    if (contentTextTex_ == 0 || contentTextW_ <= 0 || contentTextH_ <= 0) {
        return;
    }
    DrawSprite(contentTextTex_, contentTextX_, contentTextY_, static_cast<float>(contentTextW_),
               static_cast<float>(contentTextH_), w, h);
}

void GlesRenderer::DrawOverlayText(int w, int h) {
    if (overlayTextTex_ == 0 || overlayTextW_ <= 0 || overlayTextH_ <= 0) {
        return;
    }
    glEnable(GL_BLEND);
    glBlendFunc(GL_ONE, GL_ONE_MINUS_SRC_ALPHA);
    DrawSprite(overlayTextTex_, overlayTextX_, overlayTextY_, static_cast<float>(overlayTextW_),
               static_cast<float>(overlayTextH_), w, h);
    glDisable(GL_BLEND);
}

bool GlesRenderer::UploadDialogBtnLabel(int screenW, int screenH) {
    if (screenW <= 0 || screenH <= 0) {
        return false;
    }
    const float d = params_.Density();
    RectF btn;
    DialogButtonRects(screenW, screenH, d, &btn);
    const int bw = std::max(1, static_cast<int>(std::ceil(btn.w)));
    const int bh = std::max(1, static_cast<int>(std::ceil(btn.h)));
    dialogBtnLabelW_ = bw;
    dialogBtnLabelH_ = bh;

    const uint32_t btnTextArgb = darkMode_.load() ? 0xFFFFFFFF : 0xFF0B0B0F;
    LabelBitmap bitmap;
    if (RenderCenteredText(bw, bh, "OK", 17.5f * d, btnTextArgb, true, bitmap)) {
        if (dialogBtnLabelTex_ == 0) {
            glGenTextures(1, &dialogBtnLabelTex_);
        }
        glBindTexture(GL_TEXTURE_2D, dialogBtnLabelTex_);
        glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, bitmap.width, bitmap.height, 0, GL_RGBA,
                     GL_UNSIGNED_BYTE, bitmap.pixels.data());
        SetupTexture(dialogBtnLabelTex_);
    }
    GLOG("dialog button label %{public}dx%{public}d uploaded", bw, bh);
    return true;
}

bool GlesRenderer::BuildContentText(int scene, int w, int h, std::vector<TextRun> &runs) {
    const float d = params_.Density();
    contentTextX_ = 0.0f;
    contentTextY_ = 0.0f;
    contentTextW_ = w;
    contentTextH_ = h;
    const float sh = static_cast<float>(h);

    if (scene == static_cast<int>(Scene::kMagnifier)) {
        // 卡片上的正文（放大镜要折射它）
        const RectF card = MagCardRect(w, h, d);
        TextRun run;
        run.text = kLoremIpsum;
        run.x = card.x + 24.0f * d;
        run.y = sh - (card.y + card.h) + 24.0f * d;
        run.wrapWidth = card.w - 48.0f * d;
        run.fontSizePx = 16.0f * d;
        run.argb = 0xFFFFFFFF;
        run.align = 0;
        runs.push_back(run);
        return true;
    }
    return false;
}

bool GlesRenderer::BuildOverlayText(int scene, int w, int h, std::vector<TextRun> &runs) {
    const float d = params_.Density();
    overlayTextX_ = 0.0f;
    overlayTextY_ = 0.0f;
    overlayTextW_ = w;
    overlayTextH_ = h;
    const float sh = static_cast<float>(h);

    switch (scene) {
        case static_cast<int>(Scene::kButtons): {
            for (int i = 0; i < 4; i++) {
                const RectF r = ButtonRectAt(w, h, d, i);
                TextRun run;
                run.text = kButtonLabels[i];
                run.x = r.x + r.w * 0.5f;
                run.y = sh - (r.y + r.h) + (r.h - 15.0f * d * 1.35f) * 0.5f;
                run.fontSizePx = 15.0f * d;
                run.argb = 0xFFFFFFFF;
                run.align = 1;
                runs.push_back(run);
            }
            return true;
        }
        case static_cast<int>(Scene::kDialog): {
            const RectF p = DialogPanelRect(w, h, d);
            const float panelTop = sh - (p.y + p.h);
            const bool isDark = darkMode_.load();
            const uint32_t titleArgb = isDark ? 0xFFFFFFFF : 0xFF0B0B0F;
            const uint32_t bodyArgb = isDark ? 0xB8EBEBF5 : 0xD9282830;

            TextRun t1;
            t1.text = "Deleted notes are moved to the";
            t1.x = p.x + 24.0f * d;
            t1.y = panelTop + 26.0f * d;
            t1.fontSizePx = 18.0f * d;
            t1.argb = titleArgb;
            t1.bold = true;
            runs.push_back(t1);

            TextRun t2;
            t2.text = "Recently Deleted folder.";
            t2.x = p.x + 24.0f * d;
            t2.y = t1.y + 22.0f * d;
            t2.fontSizePx = 18.0f * d;
            t2.argb = titleArgb;
            t2.bold = true;
            runs.push_back(t2);

            TextRun b1;
            b1.text = "You can recover or remove from";
            b1.x = p.x + 24.0f * d;
            b1.y = t2.y + 30.0f * d;
            b1.fontSizePx = 14.5f * d;
            b1.argb = bodyArgb;
            b1.bold = false;
            runs.push_back(b1);

            TextRun b2;
            b2.text = "Recently Deleted within 30 days.";
            b2.x = p.x + 24.0f * d;
            b2.y = b1.y + 19.0f * d;
            b2.fontSizePx = 14.5f * d;
            b2.argb = bodyArgb;
            b2.bold = false;
            runs.push_back(b2);
            return true;
        }
        case static_cast<int>(Scene::kLockScreen): {
            const RectF p = LockPanelRect(w, h, d);
            const float panelTop = sh - (p.y + p.h);
            TextRun clock;
            clock.text = "09:41";
            clock.x = p.x + p.w * 0.5f;
            clock.y = panelTop + 12.0f * d;
            clock.fontSizePx = 88.0f * d;
            clock.argb = 0xFFFFFFFF;
            clock.align = 1;
            clock.bold = true;
            runs.push_back(clock);

            TextRun date;
            date.text = "Monday, January 1";
            date.x = p.x + p.w * 0.5f;
            date.y = clock.y + 88.0f * d * 1.35f;
            date.fontSizePx = 20.0f * d;
            date.argb = 0xCCFFFFFF;
            date.align = 1;
            runs.push_back(date);
            return true;
        }
        case static_cast<int>(Scene::kProgressiveBlur): {
            const RectF band = ProgBlurBandRect(w, h, d);
            TextRun run;
            run.text = "alpha-masked progressive blur";
            run.x = static_cast<float>(w) * 0.5f;
            run.y = sh - (band.y + band.h) + (band.h - 16.0f * d * 1.35f) * 0.5f;
            run.fontSizePx = 16.0f * d;
            run.argb = 0xFFFFFFFF;
            run.align = 1;
            runs.push_back(run);
            return true;
        }
        case static_cast<int>(Scene::kAdaptiveLuminance): {
            const RectF p = AdaptivePanelRect(w, h, d);
            overlayTextX_ = p.x;
            overlayTextY_ = p.y;
            overlayTextW_ = static_cast<int>(p.w);
            overlayTextH_ = static_cast<int>(p.h);
            const uint32_t argb = (lumValue_ > 0.5f) ? 0xFF000000 : 0xFFFFFFFF;
            TextRun first;
            first.text = "luminance:";
            first.x = p.w * 0.5f;
            first.y = p.h * 0.5f - 22.0f * d;
            first.fontSizePx = 16.0f * d;
            first.argb = argb;
            first.align = 1;
            runs.push_back(first);

            char buffer[32] = {0};
            snprintf(buffer, sizeof(buffer), "%.2f", static_cast<double>(lumValue_));
            TextRun second;
            second.text = buffer;
            second.x = p.w * 0.5f;
            second.y = p.h * 0.5f + 2.0f * d;
            second.fontSizePx = 16.0f * d;
            second.argb = argb;
            second.align = 1;
            runs.push_back(second);
            return true;
        }
        case static_cast<int>(Scene::kPlayground): {
            // 薄片收起时只画按钮文字（滑块整组都不画）
            if (pgSheetOpen_) {
                static const char *kLabels[5] = {"Corner radius", "Blur radius",
                                                 "Refraction height", "Refraction amount",
                                                 "Chromatic aberration"};
                for (int i = 0; i < 5; i++) {
                    const RectF row = PgSliderRowRect(i, w, h, d);
                    TextRun run;
                    run.text = kLabels[i];
                    run.x = row.x;
                    run.y = sh - (row.y + row.h + 15.0f * d * 1.35f);
                    run.fontSizePx = 15.0f * d;
                    // 薄片表面是 White 0.5（浅色），文字用深色才看得见
                    run.argb = 0xFF1C1C1E;
                    run.align = 0;
                    runs.push_back(run);
                }
            }
            for (int i = 0; i < 2; i++) {
                const RectF button = PgButtonRect(i, pgSheetOpen_, w, h, d);
                TextRun run;
                run.text = PgButtonLabel(i, pgSheetOpen_);
                run.x = button.x + button.w * 0.5f;
                run.y = sh - (button.y + button.h) + (button.h - 15.0f * d * 1.35f) * 0.5f;
                run.fontSizePx = 15.0f * d;
                run.argb = 0xFFFFFFFF;
                run.align = 1;
                runs.push_back(run);
            }
            return true;
        }
        default:
            return false;
    }
}

// ===========================================================================
// 目录场景：各场景绘制
// ===========================================================================

void GlesRenderer::DrawButtonsScene(int w, int h) {
    const float d = params_.Density();
    float press[4] = {0.0f, 0.0f, 0.0f, 0.0f};
    {
        std::lock_guard<std::mutex> lock(animMutex_);
        for (int i = 0; i < 4; i++) {
            press[i] = scenePress_[i];
        }
    }
    BlitTexture(bgTex_, w, h);
    for (int i = 0; i < 4; i++) {
        const RectF r = ButtonRectAt(w, h, d, i);
        GlassSpec s = DefaultGlass(r.x, r.y, r.w, r.h, r.h * 0.5f, d);
        // LiquidButton：vibrancy + blur(2dp) + lens(12dp, 24dp)
        s.vibrancy = 1.5f;
        s.blurRadiusPx = 2.0f * d;
        s.refractionHeight = 12.0f * d;
        s.refractionAmount = 24.0f * d;
        if (i == 1) {
            s.surfaceAlpha = 0.3f;   // surfaceColor = White 0.3
        } else if (i == 2) {
            s.surfaceAlpha = 0.8f;   // tint = #0088FF
            s.surfaceR = kAccentR;
            s.surfaceG = kAccentG;
            s.surfaceB = kAccentB;
        } else if (i == 3) {
            s.surfaceAlpha = 0.8f;   // tint = #FF8D28
            s.surfaceR = 1.0f;
            s.surfaceG = 0.553f;
            s.surfaceB = 0.157f;
        }
        // 按压：scale = lerp(1, 1 + 4dp / height, progress)
        const float scale = 1.0f + (4.0f * d) / r.h * press[i];
        s.scaleX = scale;
        s.scaleY = scale;
        // 按压采样缩小：形状放大 + 内容回缩，绕按钮中心（与顶部按钮 / 旋钮同量级）
        const float btnSampleScale = 1.0f - kButtonPressSampleShrink * press[i];
        s.sampleScaleX = btnSampleScale;
        s.sampleScaleY = btnSampleScale;
        s.samplePivotX = r.x + r.w * 0.5f;
        s.samplePivotY = r.y + r.h * 0.5f;
        DrawGlass(s, 0, w, h);
    }
    DrawOverlayText(w, h);
}

void GlesRenderer::DrawToggleScene(int w, int h) {
    DrawToggleCore(w, h, false);
}

/**
 * 开关绘制核心：目录整屏场景（widget=false）与内联控件（widget=true）共用。
 *
 * - 目录场景：轨道居中于整屏，强调色用 demo 的 #30D158，旋钮保留 8dp 模糊（背景是照片）；
 * - 内联控件：轨道居中于控件 surface，强调色用主题 primary，旋钮模糊置 0
 *   （控件背景是纯色卡片，模糊前后逐像素一致 —— 省掉整条模糊链）。
 */
void GlesRenderer::DrawToggleCore(int w, int h, bool widget) {
    const float d = params_.Density();
    float fraction = 0.0f;
    float press = 0.0f;
    float scaleX = 1.0f;
    float scaleY = 1.0f;
    float velocity = 0.0f;
    {
        std::lock_guard<std::mutex> lock(animMutex_);
        fraction = toggleFraction_;
        press = togglePress_;
        scaleX = toggleScaleX_;
        scaleY = toggleScaleY_;
        velocity = toggleVelocity_;
    }

    RectF track;
    RectF knob;
    float accentR = 0.188f;   // #30D158（demo）
    float accentG = 0.820f;
    float accentB = 0.345f;
    if (widget) {
        // 内联控件：surface 就是控件，轨道居中
        track.w = kWigToggleTrackW * d;
        track.h = kWigToggleTrackH * d;
        track.x = (static_cast<float>(w) - track.w) * 0.5f;
        track.y = (static_cast<float>(h) - track.h) * 0.5f;
        knob.w = kWigToggleKnobW * d;
        knob.h = kWigToggleKnobH * d;
        knob.x = track.x + 2.0f * d + fraction * (track.w - 4.0f * d - knob.w);
        knob.y = track.y + (track.h - knob.h) * 0.5f;
        const uint32_t accent = widgetAccentArgb_.load();
        accentR = static_cast<float>((accent >> 16) & 0xFF) / 255.0f;
        accentG = static_cast<float>((accent >> 8) & 0xFF) / 255.0f;
        accentB = static_cast<float>(accent & 0xFF) / 255.0f;
    } else {
        track = ToggleTrackRect(w, h, d);
        knob = ToggleKnobRect(w, h, d, fraction);
    }

    // ---- 内容层：轨道底色（选中进度插值，alpha 也一起插值）----
    // 参考实现 `lerp(trackColor, accentColor, fraction)` 把 **alpha 也一起插值**
    // （未选中 #787880@0.36 -> 选中 accent@1）。
    glBindFramebuffer(GL_FRAMEBUFFER, sceneFbo_);
    glViewport(0, 0, w, h);
    glEnable(GL_BLEND);
    glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
    SolidSpec trackSolid;
    trackSolid.x = track.x;
    trackSolid.y = track.y;
    trackSolid.w = track.w;
    trackSolid.h = track.h;
    trackSolid.r = track.h * 0.5f;
    trackSolid.a = kTrackAlpha + (1.0f - kTrackAlpha) * fraction;
    trackSolid.colorR = kTrackR + (accentR - kTrackR) * fraction;
    trackSolid.colorG = kTrackG + (accentG - kTrackG) * fraction;
    trackSolid.colorB = kTrackB + (accentB - kTrackB) * fraction;
    DrawSolid(trackSolid, w, h);
    glDisable(GL_BLEND);

    if (widget) {
        const uint32_t bg = widgetBgArgb_.load();
        const float bgR = static_cast<float>((bg >> 16) & 0xFF) / 255.0f;
        const float bgG = static_cast<float>((bg >> 8) & 0xFF) / 255.0f;
        const float bgB = static_cast<float>(bg & 0xFF) / 255.0f;

        // 窗口表面以全透明清屏：留白区域 alpha=0.0f 完全透明，直接露出底层原生卡片
        glBindFramebuffer(GL_FRAMEBUFFER, 0);
        glViewport(0, 0, w, h);
        glDisable(GL_BLEND);
        glDisable(GL_SCISSOR_TEST);
        glClearColor(0.0f, 0.0f, 0.0f, 0.0f);
        glClear(GL_COLOR_BUFFER_BIT);

        // 在窗口上绘制不透明胶囊轨道：颜色等于当前背景与轨道的精确混合色，alpha=1.0f！
        // 浅色模式下灰底清晰可见（#CFCFD4），深色模式下深灰底清晰可见！
        glEnable(GL_BLEND);
        glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
        SolidSpec windowTrack = trackSolid;
        const float curTrackA = trackSolid.a;
        windowTrack.colorR = trackSolid.colorR * curTrackA + bgR * (1.0f - curTrackA);
        windowTrack.colorG = trackSolid.colorG * curTrackA + bgG * (1.0f - curTrackA);
        windowTrack.colorB = trackSolid.colorB * curTrackA + bgB * (1.0f - curTrackA);
        windowTrack.a = 1.0f;
        DrawSolid(windowTrack, w, h);
        glDisable(GL_BLEND);
    } else {
        BlitTexture(sceneTex_, w, h);
    }

    // ---- 玻璃旋钮：材质与滑块旋钮共用（见 KnobGlass），按压/拖动表现单独调 ----
    GlassSpec s = KnobGlass(knob.x, knob.y, knob.w, knob.h, d, press);
    if (widget) {
        s.blurRadiusPx = 0.0f;   // 纯色背景：模糊无视觉效果，直接省掉
    }
    // 折射收一档：旋钮等比缩小后（14dp 高），demo 的 4dp 折射带几乎盖住整块旋钮，
    // 边缘会糊成一圈"重影"；半径与强度按旋钮尺寸等比收（≈0.6×）。
    s.refractionHeight = 2.5f * d * press;
    s.refractionAmount = 9.0f * d * press;
    // HallPass：开关指示器按压时关掉色散（纯色轨道边缘会分出不自然的彩边，用户走查反馈）。
    s.dispersion = false;
    // ---- HallPass：按压观感对齐滑块指示器（内阴影 / 棱边高光 / 外投影同一套参数）----
    // 外投影：滑块按压态的几何（模糊 7dp + 下移 1dp）按 kToggleShadowFit 等比缩 ——
    // surface 竖向只有 30vp（按压旋钮 26.6vp），照搬会在下缘裁出硬边（见该常量注释）。
    // 强度随按压渐入并同倍缩：静止仍是纯白旋钮、不投影（原观感）。
    s.hasShadow = true;
    s.shadowSpreadV = press;
    s.shadowBlurPx = kToggleShadowFit * (6.0f + 1.0f * press) * d;
    s.shadowOffsetPx = kToggleShadowFit * (1.5f - 0.5f * press) * d;
    s.shadowAlpha = kToggleShadowFit * (0.20f + 0.06f * press) * press;
    s.highlight = 0.18f * press;
    // 棱边高光（与环境光同一个环）的环宽：与滑块同一笔，但开关旋钮更小（14dp vs 20dp），
    // 同样 0.5dp 的环看着更厚（真机走查）—— 按旋钮高度等比收细（×0.7，d=4 时 2px → 1px）。
    s.highlightWidthPx = std::max(1.0f, std::ceil(0.7f * 0.333f * d));
    s.highlightBlurPx = s.highlightWidthPx * 0.5f;
    // 内阴影：与滑块指示器逐项一致（含静止分量：半径 6dp / alpha 0.02）
    s.innerRadiusPx = (6.0f + 2.5f * press) * d;
    s.innerAlpha = 0.02f + 0.06f * press;
    s.innerSharp = 0.4f;
    s.innerTopBias = 1.0f;
    s.innerTopCut = 0.75f;
    s.innerTaper = 0.35f;
    // 移动时的拉长/压扁（比参考实现更明显：系数 1.0 / 0.4，限幅 ±0.3）
    const float vel = velocity / 50.0f;
    const float deformX =
        std::max(0.1f, scaleX / (1.0f - std::max(-0.3f, std::min(0.3f, vel * 1.0f))));
    const float deformY =
        std::max(0.1f, scaleY * (1.0f - std::max(-0.3f, std::min(0.3f, vel * 0.4f))));
    s.scaleX = deformX;
    s.scaleY = deformY;
    DrawGlass(s, 0, w, h);
}

void GlesRenderer::DrawSliderScene(int w, int h) {
    DrawSliderCore(w, h, false);
}

/** 滑块绘制核心：目录整屏场景与内联控件共用，差异同 DrawToggleCore。 */
void GlesRenderer::DrawSliderCore(int w, int h, bool widget) {
    const float d = params_.Density();
    float value = 50.0f;
    float animValue = 50.0f;
    float press = 0.0f;
    float scaleX = 1.0f;
    float scaleY = 1.0f;
    float velocity = 0.0f;
    {
        std::lock_guard<std::mutex> lock(animMutex_);
        value = sliderValue_;
        animValue = sliderValueAnim_;
        press = sliderPress_;
        scaleX = sliderScaleX_;
        scaleY = sliderScaleY_;
        velocity = sliderVelocity_;
    }
    const float progress = std::max(0.0f, std::min(1.0f, value / 100.0f));
    // 旋钮位置用**动画值**（滞后 + 回弹），轨道填充用目标值（读数不滞后）
    const float knobProgress = std::max(0.0f, std::min(1.0f, animValue / 100.0f));

    RectF track;
    if (widget) {
        // 内联控件：轨道两端内缩（给按压放大 / 速度形变的旋钮留出不裁剪的余量）
        track.x = kWigSliderInsetDp * d;
        track.w = std::max(1.0f, static_cast<float>(w) - 2.0f * track.x);
        track.h = kWigSliderTrackH * d;
        track.y = (static_cast<float>(h) - track.h) * 0.5f;
    } else {
        track = SliderTrackRect(w, h, d);
    }
    const RectF knob = SliderKnobRectFor(track, h, d, knobProgress, widget);

    // ---- 内容层：轨道 + 已完成填充 ----
    glBindFramebuffer(GL_FRAMEBUFFER, sceneFbo_);
    glViewport(0, 0, w, h);
    glEnable(GL_BLEND);
    glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
    SolidSpec trackSolid;
    trackSolid.x = track.x;
    trackSolid.y = track.y;
    trackSolid.w = track.w;
    trackSolid.h = track.h;
    trackSolid.r = track.h * 0.5f;
    trackSolid.a = kTrackAlpha;
    trackSolid.colorR = kTrackR;
    trackSolid.colorG = kTrackG;
    trackSolid.colorB = kTrackB;
    DrawSolid(trackSolid, w, h);

    float accentR = kAccentR;
    float accentG = kAccentG;
    float accentB = kAccentB;
    if (widget) {
        const uint32_t accent = widgetAccentArgb_.load();
        accentR = static_cast<float>((accent >> 16) & 0xFF) / 255.0f;
        accentG = static_cast<float>((accent >> 8) & 0xFF) / 255.0f;
        accentB = static_cast<float>(accent & 0xFF) / 255.0f;
    }
    SolidSpec fillSolid = trackSolid;
    fillSolid.w = track.w * progress;
    fillSolid.a = 1.0f;
    fillSolid.colorR = accentR;
    fillSolid.colorG = accentG;
    fillSolid.colorB = accentB;
    DrawSolid(fillSolid, w, h);
    glDisable(GL_BLEND);

    if (widget) {
        const uint32_t bg = widgetBgArgb_.load();
        const float bgR = static_cast<float>((bg >> 16) & 0xFF) / 255.0f;
        const float bgG = static_cast<float>((bg >> 8) & 0xFF) / 255.0f;
        const float bgB = static_cast<float>(bg & 0xFF) / 255.0f;

        // 窗口表面以全透明清屏：留白区域 alpha=0.0f 完全透明，直接露出底层原生卡片
        glBindFramebuffer(GL_FRAMEBUFFER, 0);
        glViewport(0, 0, w, h);
        glDisable(GL_BLEND);
        glDisable(GL_SCISSOR_TEST);
        glClearColor(0.0f, 0.0f, 0.0f, 0.0f);
        glClear(GL_COLOR_BUFFER_BIT);

        // 在窗口上绘制不透明胶囊轨道与已完成填充：颜色等于当前背景与轨道的精确混合色，alpha=1.0f！
        glEnable(GL_BLEND);
        glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
        SolidSpec windowTrack = trackSolid;
        const float curTrackA = trackSolid.a;
        windowTrack.colorR = trackSolid.colorR * curTrackA + bgR * (1.0f - curTrackA);
        windowTrack.colorG = trackSolid.colorG * curTrackA + bgG * (1.0f - curTrackA);
        windowTrack.colorB = trackSolid.colorB * curTrackA + bgB * (1.0f - curTrackA);
        windowTrack.a = 1.0f;
        DrawSolid(windowTrack, w, h);
        DrawSolid(fillSolid, w, h);
        glDisable(GL_BLEND);
    } else {
        BlitTexture(sceneTex_, w, h);
    }

    // ---- 玻璃旋钮：材质与 Toggle 旋钮共用（见 KnobGlass），缩放/形变单独调 ----
    GlassSpec s = KnobGlass(knob.x, knob.y, knob.w, knob.h, d, press);
    if (widget) {
        s.blurRadiusPx = 0.0f;   // 纯色背景：模糊无视觉效果，直接省掉
    }
    // ---- HallPass：对齐 iOS 26 滑块的指示器观感（用户走查给的参考图）----
    // ⚠️ 开关旋钮的按压观感以此为基准（见 DrawToggleCore 的 HallPass 段）：内阴影与
    //    棱边高光逐项相同，外投影因开关 surface 变矮而按 kToggleShadowFit 等比缩。
    //   - 静止就有外投影：滑块"浮"在轨道 / 卡片上（原来旋钮无投影，纯色底上很平）；
    //   - 按压投影 = **贴着边框的一圈、整体下移**（模糊收小 + 偏移加大）：玻璃中间不压影子，
    //     只在轮廓下方/两侧露出一条，做出"拎起来"的分离感（参考图里就是这种贴边投影）；
    //   - 按压折射收到很小（高度 2dp / 强度 5dp）：纯色底上折射本来没内容可折，大了只会糊边；
    //   - 边框棱边：白色高光 + 内侧暗边（浅色底靠暗边勾线，深色底靠高光）；
    //   - 关掉色散：纯色轨道边缘会分出不自然的彩边。
    // ⚠️ 投影模糊 + 下移最大 ≈ 6vp（按压态），surface 上下留白 ≥ 7vp 才不会被裁
    //    （见 GlassWidgetCommon 的 GLASS_SLIDER_HEIGHT）。
    s.hasShadow = true;
    // 外投影：静止 = 均匀一圈的柔和投影（原观感）；按压 = **反向纵向渐变**（见
    // uShadowSpreadV）—— 中线以上不投影、往下越散，且两侧收窄到 35%（影子落在下方，
    // 不在左右摊开）。渐变只在按压时启用（spreadV = press），否则静止态会丢掉上半圈的影。
    s.shadowSpreadV = press;
    s.shadowBlurPx = (6.0f + 1.0f * press) * d;
    s.shadowOffsetPx = (1.5f - 0.5f * press) * d;
    s.shadowAlpha = 0.20f + 0.06f * press;
    s.highlight = 0.18f * press;
    // 内阴影 = **贴着指示器轮廓的一条壳沿**（壳内影，透过玻璃可见；外投影只在形状外，
    // 进不到玻璃里）。三段合成，对应走查定稿：
    //   1) 贴边圆环：基于 SDF 到边缘的距离（半径 6vp 静止 / 8.5vp 按压），圆角和两侧都自然贴合；
    //   2) 实心带（uInnerSharp=0.4）：只有前 ~22% 半径实心，其余柔化 —— 一条糊边的壳沿；
    //   3) 顶部掩码（uInnerTopCut=0.75）：横向扫描线从顶边往下到 75% 高度为止（12% 软过渡），
    //      以下含底边不画。
    s.innerRadiusPx = (6.0f + 2.5f * press) * d;
    s.innerAlpha = 0.02f + 0.06f * press;
    s.innerSharp = 0.4f;
    s.innerTopBias = 1.0f;
    s.innerTopCut = 0.75f;
    // 纵向收细：顶部 8.5vp → 到 75% 截止处收到 ~3vp（越靠上越厚、越往下越薄）
    s.innerTaper = 0.35f;
    s.dispersion = false;
    s.refractionHeight = 4.0f * d * press;
    s.refractionAmount = 10.0f * d * press;
    // 拖动时的拉长/压扁：速度越大越"流"，横向拉长、纵向压扁（限幅 ±0.3）
    const float vel = velocity / 450.0f;
    const float stretch = std::max(-0.3f, std::min(0.3f, vel));
    s.scaleX = std::max(0.1f, scaleX * (1.0f + stretch));
    s.scaleY = std::max(0.1f, scaleY * (1.0f - stretch * 0.4f));
    DrawGlass(s, 0, w, h);
}

// ===========================================================================
// HallPass 内联玻璃控件（开关 / 滑块）
// ===========================================================================

GlesRenderer *GlesRenderer::CreateInstance() {
    return new GlesRenderer();
}

void GlesRenderer::SetWidgetKind(int kind) {
    widgetKind_.store(kind);
    // scene_ 与 widgetKind_ 同步：动画状态机（UpdateCatalogAnim）按 scene_ 分发，
    // 内联控件走 kToggleWidget / kSliderWidget 两个专用分支。
    scene_.store(kind == kWidgetToggle ? static_cast<int>(Scene::kToggleWidget)
                                       : static_cast<int>(Scene::kSliderWidget));
    // 初始化动画状态：目录场景的初值（滑块 50%）在这里没有意义，直接对齐当前目标值。
    {
        std::lock_guard<std::mutex> lock(animMutex_);
        const float target = std::max(0.0f, std::min(1.0f, widgetState_.load()));
        toggleOn_ = target >= 0.5f;
        toggleDragTarget_ = toggleOn_ ? 1.0f : 0.0f;
        toggleFraction_ = toggleDragTarget_;
        toggleFractionVel_ = 0.0f;
        toggleFractionLast_ = toggleFraction_;
        toggleVelocity_ = 0.0f;
        toggleVelocityVel_ = 0.0f;
        sliderValue_ = target * 100.0f;
        sliderValueAnim_ = sliderValue_;
        sliderValueAnimVel_ = 0.0f;
        sliderValueAnimLast_ = sliderValue_;
        sliderVelocity_ = 0.0f;
        sliderVelocityVel_ = 0.0f;
    }
    widgetPrimed_.store(false);
    RequestRender();
}

void GlesRenderer::SetWidgetState(float value) {
    widgetState_.store(value);
    // 首帧前（surface 刚建好、还没画过）直接对齐目标，不做入场弹簧
    if (!widgetPrimed_.load()) {
        std::lock_guard<std::mutex> lock(animMutex_);
        const float target = std::max(0.0f, std::min(1.0f, value));
        toggleOn_ = target >= 0.5f;
        toggleDragTarget_ = toggleOn_ ? 1.0f : 0.0f;
        toggleFraction_ = toggleDragTarget_;
        toggleFractionVel_ = 0.0f;
        toggleFractionLast_ = toggleFraction_;
        sliderValue_ = target * 100.0f;
        sliderValueAnim_ = sliderValue_;
        sliderValueAnimVel_ = 0.0f;
        sliderValueAnimLast_ = sliderValue_;
    }
    RequestRender();
}

void GlesRenderer::SetWidgetPress(bool pressed) {
    widgetPressed_.store(pressed);
    RequestRender();
}

void GlesRenderer::SetWidgetColors(uint32_t accentArgb, uint32_t backgroundArgb) {
    widgetAccentArgb_.store(accentArgb);
    widgetBgArgb_.store(backgroundArgb);
    RequestRender();
}

void GlesRenderer::RequestRender() {
    {
        std::lock_guard<std::mutex> lock(widgetWaitMutex_);   // 不丢唤醒（见 NotifyFrame）
        widgetDirty_.store(true);
    }
    widgetWaitCv_.notify_all();
    NotifyFrame();
}

bool GlesRenderer::WaitWidgetIdle(int timeoutMs) {
    std::unique_lock<std::mutex> lock(widgetWaitMutex_);
    widgetWaitCv_.wait_for(lock, std::chrono::milliseconds(timeoutMs), [this] {
        return widgetDirty_.load() || stopRequested_.load();
    });
    return !stopRequested_.load();
}

bool GlesRenderer::WidgetSettled() {
    std::lock_guard<std::mutex> lock(animMutex_);
    const float eps = 0.002f;
    const float velEps = 0.02f;
    if (widgetKind_.load() == kWidgetToggle) {
        const float target = std::max(0.0f, std::min(1.0f, widgetState_.load()));
        return std::fabs(toggleFraction_ - target) < eps &&
               std::fabs(toggleFractionVel_) < velEps && togglePress_ < eps &&
               std::fabs(togglePressVel_) < velEps && std::fabs(toggleScaleX_ - 1.0f) < eps &&
               std::fabs(toggleScaleXVel_) < velEps && std::fabs(toggleScaleY_ - 1.0f) < eps &&
               std::fabs(toggleScaleYVel_) < velEps && std::fabs(toggleVelocity_) < velEps;
    }
    const float target = std::max(0.0f, std::min(1.0f, widgetState_.load())) * 100.0f;
    return std::fabs(sliderValueAnim_ - target) < 0.05f && std::fabs(sliderValueAnimVel_) < 0.5f &&
           sliderPress_ < eps && std::fabs(sliderPressVel_) < velEps &&
           std::fabs(sliderScaleX_ - 1.0f) < eps && std::fabs(sliderScaleXVel_) < velEps &&
           std::fabs(sliderScaleY_ - 1.0f) < eps && std::fabs(sliderScaleYVel_) < velEps &&
           std::fabs(sliderVelocity_) < velEps;
}

/**
 * 内联控件整帧：背景是固定卡片底色，不采样内容快照（这是与页签条最大的不同，
 * 也是"背景固定 → 可以省"的地方）：
 *   1. sceneTex_ 清成卡片底色（不透明，surface 自身不需要透明合成）；
 *   2. 轨道画进 sceneTex_ 后整块拷贝到屏幕（旋钮玻璃采样 sceneTex_ = 底色 + 轨道）；
 *   3. 玻璃旋钮叠在屏幕最上层。
 */
void GlesRenderer::DrawWidgetScene(int w, int h) {
    if (widgetKind_.load() < 0) {
        return;
    }
    const uint32_t bg = widgetBgArgb_.load();
    const float bgR = static_cast<float>((bg >> 16) & 0xFF) / 255.0f;
    const float bgG = static_cast<float>((bg >> 8) & 0xFF) / 255.0f;
    const float bgB = static_cast<float>(bg & 0xFF) / 255.0f;

    glBindFramebuffer(GL_FRAMEBUFFER, sceneFbo_);
    glViewport(0, 0, w, h);
    glDisable(GL_BLEND);
    glDisable(GL_SCISSOR_TEST);
    glClearColor(bgR, bgG, bgB, 1.0f);
    glClear(GL_COLOR_BUFFER_BIT);

    if (widgetKind_.load() == kWidgetToggle) {
        DrawToggleCore(w, h, true);
    } else {
        DrawSliderCore(w, h, true);
    }
    widgetPrimed_.store(true);
    glFlush();
}

void GlesRenderer::DrawDialogScene(int w, int h) {
    blurCacheRadius_ = -1.0f;
    blurCacheSrc_ = 0;
    smoothCacheTex_ = 0;   // 背景每帧都变：平滑模糊缓存只在本帧内有效
    glBindTexture(GL_TEXTURE_2D, sceneTex_);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);

    const float d = params_.Density();
    float press = 0.0f;
    float scale = 1.0f;
    {
        std::lock_guard<std::mutex> lock(animMutex_);
        press = dialogPress_[0];
        scale = dialogScale_;
    }

    RectF panel;
    std::vector<RectF> customBtns;
    bool hasCustomGeo = false;
    if (dialogGeoCustom_.load()) {
        std::lock_guard<std::mutex> lock(dialogGeoMutex_);
        if (dialogCardTopDown_.w > 1.0f && dialogCardTopDown_.h > 1.0f) {
            hasCustomGeo = true;
            panel.x = dialogCardTopDown_.x;
            panel.w = dialogCardTopDown_.w;
            panel.h = dialogCardTopDown_.h;
            panel.y = static_cast<float>(h) - (dialogCardTopDown_.y + dialogCardTopDown_.h);
            customBtns = dialogBtnsTopDown_;
        }
    }
    if (!hasCustomGeo) {
        panel = DialogPanelRect(w, h, d, dialogPanelHeightDp_.load());
    }
    // 嵌入式弹窗的出现 / 消失动效：绕 pivot 缩放整组几何后按真实位置绘制（scale 恒 1）。
    // pivot 由 ArkTS 按 surface 左上原点给出，这里换成 GL（y 从底部起算）。
    float xfK = 1.0f;
    float xfPx = 0.0f;
    float xfPy = 0.0f;
    if (dialogCustom_.load()) {
        std::lock_guard<std::mutex> lock(dialogGeoMutex_);
        xfK = dialogXfScale_;
        xfPx = dialogXfPivotX_;
        xfPy = static_cast<float>(h) - dialogXfPivotY_;
        scale = 1.0f;
    }
    auto applyXf = [xfK, xfPx, xfPy](RectF &r) {
        r.x = xfPx + (r.x - xfPx) * xfK;
        r.y = xfPy + (r.y - xfPy) * xfK;
        r.w *= xfK;
        r.h *= xfK;
    };
    applyXf(panel);
    const float panelCenterX = panel.x + panel.w * 0.5f;
    const float panelCenterY = panel.y + panel.h * 0.5f;

    const bool isDark = darkMode_.load();
    // HallPass 嵌入式弹窗：背景是 ArkUI 页面快照（白卡片 + 清晰文字），不是 demo 的平滑壁纸。
    // demo 材质直接套用会：① 亮度 +0.18 把近白底色顶成纯白；② 面板采样未压暗快照、
    // 四周却被 ArkUI scrim 压暗 → 像一块实心白板；③ 3dp 模糊 + 63.5dp 透镜把文字
    // 成倍缩小采样 → 直边竖纹 / 圆角同心弧（摩尔纹）。下面按嵌入模式单独覆盖。
    const bool embedded = dialogCustom_.load();

    // 按钮几何（面板 pass 要按它裁剪 sceneTex_ 的工作区，所以提前算）
    const int buttonCount = hasCustomGeo ? static_cast<int>(customBtns.size())
                                         : std::min(2, std::max(0, dialogButtonCount_.load()));
    RectF btns[2];
    if (hasCustomGeo) {
        for (size_t i = 0; i < customBtns.size() && i < 2; i++) {
            btns[i].x = customBtns[i].x;
            btns[i].w = customBtns[i].w;
            btns[i].h = customBtns[i].h;
            btns[i].y = static_cast<float>(h) - (customBtns[i].y + customBtns[i].h);
        }
    } else if (buttonCount > 0) {
        DialogButtonRects(w, h, d, buttonCount, btns, dialogPanelHeightDp_.load());
    }
    for (int i = 0; i < buttonCount && i < 2; i++) {
        applyXf(btns[i]);
    }
    // sceneTex_ 只给按钮采样（按钮玻璃 + 它的平滑模糊）：工作区 = 按钮外接框外扩同样的模糊支撑。
    // 面板先画进 sceneTex_ 的那一遍因此只需覆盖这一块（原先整块面板画两遍）。
    RectF btnWork{0.0f, 0.0f, 0.0f, 0.0f};
    if (buttonCount > 0) {
        float bx0 = btns[0].x;
        float by0 = btns[0].y;
        float bx1 = btns[0].x + btns[0].w;
        float by1 = btns[0].y + btns[0].h;
        for (int i = 1; i < buttonCount && i < 2; i++) {
            bx0 = std::min(bx0, btns[i].x);
            by0 = std::min(by0, btns[i].y);
            bx1 = std::max(bx1, btns[i].x + btns[i].w);
            by1 = std::max(by1, btns[i].y + btns[i].h);
        }
        btnWork = RectF{bx0 - kDialogWorkMarginPx, by0 - kDialogWorkMarginPx,
                        bx1 - bx0 + 2.0f * kDialogWorkMarginPx, by1 - by0 + 2.0f * kDialogWorkMarginPx};
    }

    // ---- 1. 背景暗化（参数 pid::kDialogDimAlpha，94）----
    SolidSpec dim;
    dim.x = 0.0f;
    dim.y = 0.0f;
    dim.w = static_cast<float>(w);
    dim.h = static_cast<float>(h);
    // 嵌入式弹窗的工作区（GL 坐标）：只有面板（含按钮）会采样背景 / sceneTex_，
    // 外扩量覆盖两条平滑模糊的支撑半径（面板 σ2.5dp → 1/2 级 3 轮、按钮 σ4dp → 1/4 级 2 轮，
    // 迭代 pass 让裁剪盒外的旧纹素最多往里渗 ~100px）。背景 / 暗化 / 拷贝 / 模糊链都裁到这里，
    // 整屏 1280×2598 的几个 pass 降到面板大小；工作区外的 bgTex_ / sceneTex_ 是旧内容，没人读。
    const RectF work{panel.x - kDialogWorkMarginPx, panel.y - kDialogWorkMarginPx,
                     panel.w + 2.0f * kDialogWorkMarginPx, panel.h + 2.0f * kDialogWorkMarginPx};
    if (embedded) {
        {
            GpuPassScope gpu(gpuTimer_, kGpuBackground);
            glEnable(GL_SCISSOR_TEST);
            SetScissorRect(work.x, work.y, work.w, work.h, 0.0f, w, h);
            RenderBackground(w, h);
        }
        GpuPassScope gpuDim(gpuTimer_, kGpuOther);
        // 四周由 ArkUI scrim 压暗（GlassDialogTokens：浅 0.34 / 深 0.50，同 demo 的 dimAlpha）；
        // 面板采样的背景压得浅一些（浅 0.20 / 深 0.40）：面板略亮于四周、白卡片不顶白。
        dim.a = isDark ? 0.40f : 0.20f;
        dim.colorR = 0.02f;
        dim.colorG = 0.03f;
        dim.colorB = 0.05f;
        glEnable(GL_SCISSOR_TEST);
        SetScissorRect(work.x, work.y, work.w, work.h, 0.0f, w, h);
        glBindFramebuffer(GL_FRAMEBUFFER, bgFbo_);
        glViewport(0, 0, w, h);
        DrawSolid(dim, w, h);
        glDisable(GL_BLEND);
        if (buttonCount > 0) {
            SetScissorRect(btnWork.x, btnWork.y, btnWork.w, btnWork.h, 0.0f, w, h);
            CopyBackgroundToScene(w, h);
        }
        glDisable(GL_SCISSOR_TEST);
    } else {
        dim.a = params_.N(pid::kDialogDimAlpha);
        dim.colorR = 0.02f;
        dim.colorG = 0.03f;
        dim.colorB = 0.05f;
        glBindFramebuffer(GL_FRAMEBUFFER, sceneFbo_);
        glViewport(0, 0, w, h);
        DrawSolid(dim, w, h);
        glDisable(GL_BLEND);
    }

    // ---- 2. 玻璃对话框底板（参数 95..116 + 开关 8..11）----
    const float panelRadiusPx = params_.Px(pid::kDialogCornerRadius) * xfK;
    GlassSpec s = DefaultGlass(panel.x, panel.y, panel.w, panel.h, panelRadiusPx, d);
    s.useBackground = true;
    s.scaleX = scale;
    s.scaleY = scale;
    s.g2Factor = params_.N(pid::kDialogG2Factor);
    s.blurRadiusPx = params_.Px(pid::kDialogBlurRadius);
    s.refractionHeight = params_.Px(pid::kDialogRefractionHeight);
    s.refractionAmount = params_.Px(pid::kDialogRefractionAmount);
    s.rimClarity = params_.N(pid::kDialogRimClarity);
    s.bevelAlphaScale = params_.N(pid::kDialogBevelAlphaScale);
    s.vibrancy = params_.N(pid::kDialogVibrancy);
    s.contrast = params_.N(pid::kDialogContrast);
    s.dispersion = params_.B(bid::kDialogDispersion);
    s.depthEffect = params_.B(bid::kDialogDepthEffect);
    s.ambient = params_.B(bid::kDialogAmbient);
    s.plainHighlight = params_.B(bid::kDialogPlainHighlight);

    if (isDark) {
        s.surfaceAlpha = 0.50f;
        s.surfaceR = 0.12f;
        s.surfaceG = 0.13f;
        s.surfaceB = 0.16f;
        s.brightness = -0.05f;
    } else {
        s.surfaceAlpha = params_.N(pid::kDialogSurfaceAlpha);
        s.surfaceR = params_.N(pid::kDialogSurfaceR);
        s.surfaceG = params_.N(pid::kDialogSurfaceG);
        s.surfaceB = params_.N(pid::kDialogSurfaceB);
        s.brightness = params_.N(pid::kDialogBrightness);
    }

    s.highlight = params_.N(pid::kDialogHighlight);
    s.highlightWidthPx = std::max(1.0f, params_.Px(pid::kDialogHighlightWidth));
    s.highlightBlurPx = s.highlightWidthPx * 0.5f;
    s.ambientIntensity = params_.N(pid::kDialogAmbientIntensity);
    s.innerRadiusPx = params_.Px(pid::kDialogInnerRadius);
    s.innerAlpha = params_.N(pid::kDialogInnerAlpha);
    s.hasShadow = params_.N(pid::kDialogShadowAlpha) > 0.001f;
    s.shadowBlurPx = params_.Px(pid::kDialogShadowBlur);
    s.shadowOffsetPx = params_.Px(pid::kDialogShadowOffset);
    s.shadowAlpha = params_.N(pid::kDialogShadowAlpha);
    if (embedded) {
        // 透镜 / 提饱和 / 棱面底色沿用 demo 定版参数（95..116）。模糊走无重影的平滑高斯：
        // 小 sigma 也足够当透镜的预过滤（旧 9-tap 大步距才会把文字采成竖纹 / 同心弧），
        // 1/4 分辨率盒式降采样另带 ~1dp，合计 ≈ demo 的 3dp。
        s.smoothBlur = true;
        s.blurClip = &work;
        s.gpuPass = kGpuPanel;
        s.blurRadiusPx = 2.5f * d;   // sigma（RenderBlurSmooth）
        if (!isDark) {
            // 压暗后的白卡片 ≈ 0.8：轻提亮 + 20% 冷白底色，比四周略亮、不顶白（demo 的 +0.18
            // 亮度在白底上会整块顶成纯白），底下内容清楚透出；高光加强到浅底上也能勾出棱边。
            s.surfaceAlpha = 0.20f;
            s.surfaceR = 0.97f;
            s.surfaceG = 0.98f;
            s.surfaceB = 1.00f;
            s.brightness = 0.05f;
            s.highlight = 0.55f;
        }
    }
    if (xfK != 1.0f) {
        // 光学尺度随形状一起缩：透镜 / 高光 / 投影都按同一比例，缩小的玻璃看起来是"同一块"
        s.refractionHeight *= xfK;
        s.refractionAmount *= xfK;
        s.highlightWidthPx = std::max(1.0f, s.highlightWidthPx * xfK);
        s.highlightBlurPx = s.highlightWidthPx * 0.5f;
        s.shadowBlurPx *= xfK;
        s.shadowOffsetPx *= xfK;
    }
    if (!embedded) {
        DrawGlass(s, sceneFbo_, w, h);
    } else if (buttonCount > 0) {
        // 嵌入式：只有按钮工作区需要"面板 + 背景"的合成（面板模糊在这里算一次，上屏那遍复用）
        GlassSpec sceneSpec = s;
        sceneSpec.drawClip = &btnWork;
        DrawGlass(sceneSpec, sceneFbo_, w, h);
    }

    // 屏幕 target 0：以全透明清屏，采用浮动玻璃件叠加混合模式绘制底板与阴影
    // （形状内输出玻璃色，形状外仅输出投影，留白区域 alpha=0 露出底层 ArkUI 原生页面与 scrim）
    glBindFramebuffer(GL_FRAMEBUFFER, 0);
    glViewport(0, 0, w, h);
    glDisable(GL_BLEND);
    glDisable(GL_SCISSOR_TEST);
    glClearColor(0.0f, 0.0f, 0.0f, 0.0f);
    glClear(GL_COLOR_BUFFER_BIT);

    DrawGlass(s, 0, w, h);

    // ---- 3. 液态玻璃胶囊按钮（参数 117..139 + 开关 12..15）：几何已在开头算好 ----
    if (buttonCount > 0) {
        for (int i = 0; i < buttonCount && i < 2; i++) {
            const RectF &btn = btns[i];
            float btnPress = 0.0f;
            {
                std::lock_guard<std::mutex> lock(animMutex_);
                btnPress = dialogPress_[i];
            }
            // 按压进度（弹簧会过冲到 [-0.35, 1.45]）：高光只取 0..1 这一段
            const float pressLevel = std::max(0.0f, std::min(1.0f, btnPress));
            const float btnCenterX = panelCenterX + (btn.x + btn.w * 0.5f - panelCenterX) * scale;
            const float btnCenterY = panelCenterY + (btn.y + btn.h * 0.5f - panelCenterY) * scale;
            const float pressGrowPx = params_.Px(pid::kDialogBtnPressGrow);
            const float btnScale = 1.0f + (btn.h > 1.0f ? pressGrowPx / btn.h : 0.0f) * btnPress;
            const float totalScale = scale * btnScale;
            const float drawBtnW = btn.w * totalScale;
            const float drawBtnH = btn.h * totalScale;

            const float btnRadiusPx = btn.h * 0.5f * scale;
            GlassSpec bs = DefaultGlass(btnCenterX - btn.w * 0.5f * scale,
                                        btnCenterY - btn.h * 0.5f * scale,
                                        btn.w * scale, btn.h * scale,
                                        btnRadiusPx, d);
            bs.useBackground = false;  // 采样 sceneTex_（包含通透底板与折射纹理）
            bs.g2Factor = params_.N(pid::kDialogBtnG2Factor);
            bs.blurRadiusPx = params_.Px(pid::kDialogBtnBlurRadius);
            bs.refractionHeight = params_.Px(pid::kDialogBtnRefractionHeight);
            bs.refractionAmount = params_.Px(pid::kDialogBtnRefractionAmount);
            bs.rimClarity = params_.N(pid::kDialogBtnRimClarity);
            bs.bevelAlphaScale = params_.N(pid::kDialogBtnBevelAlphaScale);
            bs.vibrancy = params_.N(pid::kDialogBtnVibrancy);
            bs.contrast = params_.N(pid::kDialogBtnContrast);
            bs.dispersion = params_.B(bid::kDialogBtnDispersion);
            bs.depthEffect = params_.B(bid::kDialogBtnDepthEffect);
            bs.ambient = params_.B(bid::kDialogBtnAmbient);
            bs.plainHighlight = params_.B(bid::kDialogBtnPlainHighlight);

            if (isDark) {
                bs.surfaceAlpha = 0.35f;
                bs.surfaceR = 0.25f;
                bs.surfaceG = 0.27f;
                bs.surfaceB = 0.32f;
                bs.brightness = -0.02f;
            } else {
                bs.surfaceAlpha = params_.N(pid::kDialogBtnSurfaceAlpha);
                bs.surfaceR = params_.N(pid::kDialogBtnSurfaceR);
                bs.surfaceG = params_.N(pid::kDialogBtnSurfaceG);
                bs.surfaceB = params_.N(pid::kDialogBtnSurfaceB);
                bs.brightness = params_.N(pid::kDialogBtnBrightness);
            }

            // 按压时棱边高光加上"高光·按压增量"（参数 15，与顶部玻璃按钮同一口径：静止 + 增量 × 按压）。
            // 按压态只靠放大 + 棱边变亮表达，不铺底色（ArkUI 透明按钮也关了 stateEffect）。
            bs.highlight = params_.N(pid::kDialogBtnHighlight) +
                           params_.N(pid::kIconHighlightPress) * pressLevel;
            bs.highlightWidthPx = std::max(1.0f, params_.Px(pid::kDialogBtnHighlightWidth));
            bs.highlightBlurPx = bs.highlightWidthPx * 0.5f;
            bs.ambientIntensity = params_.N(pid::kDialogBtnAmbientIntensity);
            bs.innerRadiusPx = params_.Px(pid::kDialogBtnInnerRadius);
            bs.innerAlpha = params_.N(pid::kDialogBtnInnerAlpha);
            bs.hasShadow = params_.N(pid::kDialogBtnShadowAlpha) > 0.001f;
            bs.shadowBlurPx = params_.Px(pid::kDialogBtnShadowBlur);
            bs.shadowOffsetPx = params_.Px(pid::kDialogBtnShadowOffset);
            bs.shadowAlpha = params_.N(pid::kDialogBtnShadowAlpha);
            bs.sampleScaleX = 1.0f;
            bs.sampleScaleY = 1.0f;
            bs.scaleX = btnScale;
            bs.scaleY = btnScale;
            if (embedded) {
                // 按钮距面板底边只有 18dp：demo 的 40dp 外拉采样会越过面板采到下方页面文字，
                // 折射量取 30dp（多数外拉仍落在面板内边距里），保留明显的胶囊边缘弯折。
                bs.smoothBlur = true;
                bs.blurClip = &btnWork;
                bs.gpuPass = kGpuIndicator;
                bs.blurRadiusPx = 4.0f * d;   // sigma（RenderBlurSmooth）
                bs.refractionHeight = 18.0f * d;
                bs.refractionAmount = 30.0f * d;
                if (!isDark) {
                    // 浅色面板近白：demo 的 25% 白底按钮叠上去几乎看不见，改中性灰底（iOS 系统填充
                    // #767680）把胶囊从面板上拉开层次，仍保留透镜与高光
                    bs.surfaceR = 0.463f;
                    bs.surfaceG = 0.463f;
                    bs.surfaceB = 0.502f;
                    bs.surfaceAlpha = 0.18f;
                }
            }

            if (xfK != 1.0f) {
                bs.refractionHeight *= xfK;
                bs.refractionAmount *= xfK;
                bs.highlightWidthPx = std::max(1.0f, bs.highlightWidthPx * xfK);
                bs.highlightBlurPx = bs.highlightWidthPx * 0.5f;
                bs.shadowBlurPx *= xfK;
                bs.shadowOffsetPx *= xfK;
            }
            DrawGlass(bs, 0, w, h);
        }
    }

    if (!dialogCustom_.load()) {
        // ---- 4. 对话框文字图层（标题与正文随 dialogScale 缩放）----
        if (overlayTextTex_ != 0 && overlayTextW_ > 0 && overlayTextH_ > 0) {
            glEnable(GL_BLEND);
            glBlendFunc(GL_ONE, GL_ONE_MINUS_SRC_ALPHA);
            if (std::fabs(scale - 1.0f) > 0.001f) {
                const float drawW = static_cast<float>(w) * scale;
                const float drawH = static_cast<float>(h) * scale;
                const float drawX = panelCenterX - panelCenterX * scale;
                const float drawY = panelCenterY - panelCenterY * scale;
                DrawSprite(overlayTextTex_, drawX, drawY, drawW, drawH, w, h);
            } else {
                DrawSprite(overlayTextTex_, overlayTextX_, overlayTextY_,
                           static_cast<float>(overlayTextW_), static_cast<float>(overlayTextH_), w, h);
            }
            glDisable(GL_BLEND);
        }

        // ---- 5. 按钮文字图层（随按钮按压放大与入场缩放同步放大）----
        if (buttonCount == 1) {
            const RectF &btn = btns[0];
            const float pressGrowPx = params_.Px(pid::kDialogBtnPressGrow);
            const float btnScale = 1.0f + (btn.h > 1.0f ? pressGrowPx / btn.h : 0.0f) * dialogPress_[0];
            const float totalScale = scale * btnScale;
            const float drawBtnW = btn.w * totalScale;
            const float drawBtnH = btn.h * totalScale;
            const float btnCenterX = panelCenterX + (btn.x + btn.w * 0.5f - panelCenterX) * scale;
            const float btnCenterY = panelCenterY + (btn.y + btn.h * 0.5f - panelCenterY) * scale;
            if (dialogBtnLabelTex_ == 0 || dialogBtnLabelW_ != static_cast<int>(std::ceil(btn.w))) {
                UploadDialogBtnLabel(w, h);
            }
            if (dialogBtnLabelTex_ != 0) {
                glEnable(GL_BLEND);
                glBlendFunc(GL_ONE, GL_ONE_MINUS_SRC_ALPHA);
                DrawSprite(dialogBtnLabelTex_, btnCenterX - drawBtnW * 0.5f, btnCenterY - drawBtnH * 0.5f,
                           drawBtnW, drawBtnH, w, h);
                glDisable(GL_BLEND);
            }
        }
    }
}

void GlesRenderer::DrawControlCenterScene(int w, int h) {
    const float d = params_.Density();
    float progress = 1.0f;
    {
        std::lock_guard<std::mutex> lock(animMutex_);
        progress = ccProgress_;
    }
    const float sp = 16.0f * d;
    const float item = 68.0f * d;
    const float two = 152.0f * d;
    const float gridW = two * 2.0f + sp;
    const float x0 = (static_cast<float>(w) - gridW) * 0.5f;
    const float gridTopDown = 140.0f * d;
    const float yTop = static_cast<float>(h) - gridTopDown;
    const float yShift = 48.0f * d * (1.0f - progress);

    // ---- 内容层：背景模糊 + 暗化（对齐参考实现的 renderEffect + dim）----
    glBindFramebuffer(GL_FRAMEBUFFER, sceneFbo_);
    glViewport(0, 0, w, h);
    glEnable(GL_BLEND);
    glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
    const float bgBlur = 4.0f * d * progress;
    if (bgBlur > 0.01f) {
        const GLuint blurred = RenderBlur(bgTex_, bgBlur);
        DrawSprite(blurred, 0.0f, 0.0f, static_cast<float>(w), static_cast<float>(h), w, h,
                   progress);
    }
    SolidSpec dim;
    dim.x = 0.0f;
    dim.y = 0.0f;
    dim.w = static_cast<float>(w);
    dim.h = static_cast<float>(h);
    dim.a = 0.4f * progress;
    dim.colorR = 0.0f;
    dim.colorG = 0.0f;
    dim.colorB = 0.0f;
    DrawSolid(dim, w, h);
    glDisable(GL_BLEND);
    BlitTexture(sceneTex_, w, h);

    // ---- 玻璃圆角方块（cap 形状 = 34dp 半径；无投影，Default 高光）----
    const float radius = item * 0.5f;
    auto drawTile = [&](float gx, float gy, float tw, float th) {
        GlassSpec s = DefaultGlass(x0 + gx, yTop - gy - th + yShift, tw, th, radius, d);
        s.hasShadow = false;
        s.vibrancy = 1.5f;
        s.refractionHeight = 24.0f * d * progress;
        s.refractionAmount = 48.0f * d * progress;
        s.depthEffect = true;
        // 收起进度同时驱动"材质淡出"（对齐参考实现的 alpha = EaseIn(progress)）
        s.effectOpacity = progress;
        // 参考实现的控制中心没有底色填充
        DrawGlass(s, 0, w, h);
    };
    const float row2 = two + sp;
    const float row3 = row2 + two + sp;
    // 第一行
    drawTile(0.0f, 0.0f, two, two);
    drawTile(two + sp, 0.0f, two, two);
    // 第二行
    drawTile(0.0f, row2, item, item);
    drawTile(item + sp, row2, item, item);
    drawTile(0.0f, row2 + item + sp, two, item);
    drawTile(two + sp, row2, item, two);
    drawTile(two + sp + item + sp, row2, item, two);
    // 第三行
    drawTile(0.0f, row3, two, two);
    drawTile(two + sp, row3, item, item);
    drawTile(two + sp + item + sp, row3, item, item);
    drawTile(two + sp, row3 + item + sp, item, item);

    // ---- 图标：大块内的三个内嵌胶囊 + 几个独立方块上的飞机 ----
    if (planeIconTex_ != 0 && planeIconSizePx_ > 0 && progress > 0.01f) {
        const float innerSize = 56.0f * d;
        const float innerIcon = innerSize * 0.8f;
        const float tileIcon = 40.0f * d;
        glEnable(GL_BLEND);
        glBlendFunc(GL_ONE, GL_ONE_MINUS_SRC_ALPHA);   // 位图是预乘 alpha
        auto drawIconAt = [&](float cx, float cy, float size) {
            DrawSprite(planeIconTex_, cx - size * 0.5f, cy - size * 0.5f, size, size, w, h,
                       progress);
        };
        // 大块内的三个胶囊（白 / 蓝 / 蓝）
        const float innerPad = 16.0f * d;
        const float capsuleCenters[3][2] = {
            {x0 + innerPad + innerSize * 0.5f, yTop - innerPad - innerSize * 0.5f + yShift},
            {x0 + two - innerPad - innerSize * 0.5f, yTop - innerPad - innerSize * 0.5f + yShift},
            {x0 + innerPad + innerSize * 0.5f,
             yTop - two + innerPad + innerSize * 0.5f + yShift},
        };
        const float capsuleColors[3][3] = {
            {1.0f, 1.0f, 1.0f},   // inactive White 0.2
            {kAccentR, kAccentG, kAccentB},
            {kAccentR, kAccentG, kAccentB},
        };
        glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
        for (int i = 0; i < 3; i++) {
            SolidSpec capsule;
            capsule.x = capsuleCenters[i][0] - innerSize * 0.5f;
            capsule.y = capsuleCenters[i][1] - innerSize * 0.5f;
            capsule.w = innerSize;
            capsule.h = innerSize;
            capsule.r = innerSize * 0.5f;
            // 内嵌胶囊也随收起进度淡出（否则玻璃没了、胶囊还挂在半空）
            capsule.a = ((i == 0) ? 0.2f : 1.0f) * progress;
            capsule.colorR = capsuleColors[i][0];
            capsule.colorG = capsuleColors[i][1];
            capsule.colorB = capsuleColors[i][2];
            DrawSolid(capsule, w, h);
        }
        glBlendFunc(GL_ONE, GL_ONE_MINUS_SRC_ALPHA);
        for (int i = 0; i < 3; i++) {
            drawIconAt(capsuleCenters[i][0], capsuleCenters[i][1], innerIcon);
        }
        // 独立方块上的飞机
        const float tileCenters[5][2] = {
            {x0 + item * 0.5f, yTop - row2 - item * 0.5f + yShift},
            {x0 + item + sp + item * 0.5f, yTop - row2 - item * 0.5f + yShift},
            {x0 + two + sp + item * 0.5f, yTop - row3 - item * 0.5f + yShift},
            {x0 + two + sp + item + sp + item * 0.5f, yTop - row3 - item * 0.5f + yShift},
            {x0 + two + sp + item * 0.5f, yTop - row3 - item - sp - item * 0.5f + yShift},
        };
        for (int i = 0; i < 5; i++) {
            drawIconAt(tileCenters[i][0], tileCenters[i][1], tileIcon);
        }
        glDisable(GL_BLEND);
    }
}

void GlesRenderer::DrawLockScreenScene(int w, int h) {
    const float d = params_.Density();
    float offsetX = 0.0f;
    float offsetY = 0.0f;
    {
        std::lock_guard<std::mutex> lock(animMutex_);
        offsetX = lockOffsetX_;
        offsetY = lockOffsetY_;
    }
    // ---- 内容层：黑 0.3 暗化 ----
    glBindFramebuffer(GL_FRAMEBUFFER, sceneFbo_);
    glViewport(0, 0, w, h);
    glEnable(GL_BLEND);
    glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
    SolidSpec dim;
    dim.x = 0.0f;
    dim.y = 0.0f;
    dim.w = static_cast<float>(w);
    dim.h = static_cast<float>(h);
    dim.a = 0.3f;
    dim.colorR = 0.0f;
    dim.colorG = 0.0f;
    dim.colorB = 0.0f;
    DrawSolid(dim, w, h);
    glDisable(GL_BLEND);
    BlitTexture(sceneTex_, w, h);

    // ---- 玻璃钟表底板（colorControls + blur(2dp)，SDF 时钟的等价物）----
    const RectF base = LockPanelRect(w, h, d);
    const float glOffsetY = -offsetY;   // 屏幕向下拖动 = GL 坐标减
    GlassSpec s = DefaultGlass(base.x + offsetX, base.y + glOffsetY, base.w, base.h,
                               base.h * 0.35f, d);
    s.hasShadow = false;
    s.highlight = 0.0f;
    s.brightness = -0.1f;
    s.contrast = 0.75f;
    s.saturation = 1.5f;
    s.blurRadiusPx = 2.0f * d;
    DrawGlass(s, 0, w, h);

    // ---- 钟表文字（跟着拖动位移）----
    if (overlayTextTex_ != 0) {
        glEnable(GL_BLEND);
        glBlendFunc(GL_ONE, GL_ONE_MINUS_SRC_ALPHA);
        DrawSprite(overlayTextTex_, overlayTextX_ + offsetX, overlayTextY_ + glOffsetY,
                   static_cast<float>(overlayTextW_), static_cast<float>(overlayTextH_), w, h);
        glDisable(GL_BLEND);
    }
}

void GlesRenderer::DrawMagnifierScene(int w, int h) {
    const float d = params_.Density();
    float magX = static_cast<float>(w) * 0.5f;
    float magY = static_cast<float>(h) * 0.42f;
    {
        std::lock_guard<std::mutex> lock(animMutex_);
        if (!magInited_) {
            magX_ = magX;
            magY_ = magY;
            magInited_ = true;
        }
        magX = magX_;
        magY = magY_;
    }
    const RectF card = MagCardRect(w, h, d);
    const RectF lens = MagLensRect(magX, magY, d);
    const RectF cursor = MagCursorRect(magX, magY, d);

    // ---- 内容层：卡片 + 正文 + 光标（透镜要放大它们）----
    glBindFramebuffer(GL_FRAMEBUFFER, sceneFbo_);
    glViewport(0, 0, w, h);
    glEnable(GL_BLEND);
    glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
    SolidSpec cardSolid;
    cardSolid.x = card.x;
    cardSolid.y = card.y;
    cardSolid.w = card.w;
    cardSolid.h = card.h;
    cardSolid.r = 32.0f * d;
    cardSolid.a = 0.9f;
    cardSolid.colorR = 0.0706f;
    cardSolid.colorG = 0.0706f;
    cardSolid.colorB = 0.0706f;
    DrawSolid(cardSolid, w, h);
    glBlendFunc(GL_ONE, GL_ONE_MINUS_SRC_ALPHA);
    DrawContentText(w, h);
    glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
    SolidSpec cursorSolid;
    cursorSolid.x = cursor.x;
    cursorSolid.y = cursor.y;
    cursorSolid.w = cursor.w;
    cursorSolid.h = cursor.h;
    cursorSolid.r = cursor.w * 0.5f;
    cursorSolid.a = 1.0f;
    cursorSolid.colorR = kAccentR;
    cursorSolid.colorG = kAccentG;
    cursorSolid.colorB = kAccentB;
    DrawSolid(cursorSolid, w, h);
    glDisable(GL_BLEND);
    BlitTexture(sceneTex_, w, h);

    // ---- 放大镜（lens(8dp, 24dp, depth, dispersion) + 1.5× 采样 + 内阴影）----
    GlassSpec s = DefaultGlass(lens.x, lens.y, lens.w, lens.h, lens.h * 0.5f, d);
    s.hasShadow = false;
    s.highlight = 0.0f;
    s.refractionHeight = 8.0f * d;
    s.refractionAmount = 24.0f * d;
    s.depthEffect = true;
    s.dispersion = true;
    s.innerRadiusPx = 16.0f * d;
    s.innerAlpha = 0.15f;
    s.sampleScaleX = 1.5f;
    s.sampleScaleY = 1.5f;
    s.samplePivotX = lens.x + lens.w * 0.5f;
    s.samplePivotY = lens.y + lens.h * 0.5f;
    DrawGlass(s, 0, w, h);
}

void GlesRenderer::DrawProgressiveBlurScene(int w, int h) {
    const float d = params_.Density();
    const RectF band = ProgBlurBandRect(w, h, d);
    BlitTexture(bgTex_, w, h);

    const float radius = 4.0f * d;
    const GLuint blurred = (radius > 0.01f) ? RenderBlur(bgTex_, radius) : bgTex_;
    glBindFramebuffer(GL_FRAMEBUFFER, 0);
    glViewport(0, 0, w, h);
    glDisable(GL_BLEND);
    glEnable(GL_SCISSOR_TEST);
    SetScissorRect(band.x, band.y, band.w, band.h, 1.0f, w, h);
    glUseProgram(progProgBlur_);
    glActiveTexture(GL_TEXTURE0);
    glBindTexture(GL_TEXTURE_2D, bgTex_);
    glUniform1i(Uniform(progProgBlur_, "uSharp"), 0);
    glActiveTexture(GL_TEXTURE1);
    glBindTexture(GL_TEXTURE_2D, blurred);
    glUniform1i(Uniform(progProgBlur_, "uBlurred"), 1);
    glUniform2f(Uniform(progProgBlur_, "uResolution"), static_cast<float>(w),
                static_cast<float>(h));
    glUniform4f(Uniform(progProgBlur_, "uRect"), band.x, band.y, band.w, band.h);
    glUniform3f(Uniform(progProgBlur_, "uTint"), 0.502f, 0.502f, 0.502f);
    glUniform1f(Uniform(progProgBlur_, "uTintIntensity"), 0.8f);
    glDrawArrays(GL_TRIANGLES, 0, 3);
    glDisable(GL_SCISSOR_TEST);

    glEnable(GL_BLEND);
    glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
    DrawOverlayText(w, h);
    glDisable(GL_BLEND);
}

void GlesRenderer::DrawAdaptiveScene(int w, int h) {
    const float d = params_.Density();
    float lum = 0.25f;
    float offsetX = 0.0f;
    float offsetY = 0.0f;
    {
        std::lock_guard<std::mutex> lock(animMutex_);
        lum = lumValue_;
        offsetX = pgX_;
        offsetY = pgY_;
    }
    const RectF base = AdaptivePanelRect(w, h, d);

    // ---- 亮度采样：每 250ms 读一次背景（16×16 缩略图求平均）----
    const int64_t now = NowMs();
    if (now - lumSampleMs_ > 250) {
        lumSampleMs_ = now;
        const int sampleW = 16;
        const int sampleH = 16;
        int sx = static_cast<int>(base.x + offsetX + base.w * 0.5f) - sampleW / 2;
        int sy = static_cast<int>(base.y + offsetY + base.h * 0.5f) - sampleH / 2;
        sx = std::max(0, std::min(sx, w - sampleW));
        sy = std::max(0, std::min(sy, h - sampleH));
        unsigned char pixels[sampleW * sampleH * 4] = {0};
        glBindFramebuffer(GL_FRAMEBUFFER, bgFbo_);
        glReadPixels(sx, sy, sampleW, sampleH, GL_RGBA, GL_UNSIGNED_BYTE, pixels);
        glBindFramebuffer(GL_FRAMEBUFFER, 0);
        float sum = 0.0f;
        for (int i = 0; i < sampleW * sampleH; i++) {
            const float r = static_cast<float>(pixels[i * 4 + 0]) / 255.0f;
            const float g = static_cast<float>(pixels[i * 4 + 1]) / 255.0f;
            const float b = static_cast<float>(pixels[i * 4 + 2]) / 255.0f;
            sum += 0.2126f * r + 0.7152f * g + 0.0722f * b;
        }
        std::lock_guard<std::mutex> lock(animMutex_);
        lumTarget_ = sum / static_cast<float>(sampleW * sampleH);
    }

    // 文字（数值）最多 10Hz 更新，避免整屏位图重传
    const int pct = static_cast<int>(std::lround(lum * 100.0f));
    if (pct != lumShown_ && now - lumTextMs_ > 100) {
        lumShown_ = pct;
        lumTextMs_ = now;
        overlayTextDirty_.store(true);
    }

    BlitTexture(bgTex_, w, h);

    // ---- 玻璃面板：亮度驱动的 colorControls / blur + lens(24dp, minDim/2, depth) ----
    const float v = lum * 2.0f - 1.0f;
    const float l = (v >= 0.0f ? 1.0f : -1.0f) * v * v;
    GlassSpec s = DefaultGlass(base.x + offsetX, base.y + offsetY, base.w, base.h, 24.0f * d, d);
    s.hasShadow = false;
    s.plainHighlight = true;
    s.highlight = 0.38f;
    s.saturation = 1.5f;
    if (l > 0.0f) {
        s.brightness = 0.1f + (0.5f - 0.1f) * l;
        s.contrast = 1.0f + (0.0f - 1.0f) * l;
        s.blurRadiusPx = (8.0f + (16.0f - 8.0f) * l) * d;
    } else {
        s.brightness = 0.1f + (-0.2f - 0.1f) * (-l);
        s.contrast = 1.0f;
        s.blurRadiusPx = (8.0f + (2.0f - 8.0f) * (-l)) * d;
    }
    s.refractionHeight = 24.0f * d;
    s.refractionAmount = base.w * 0.5f;
    s.depthEffect = true;
    DrawGlass(s, 0, w, h);

    if (overlayTextTex_ != 0) {
        glEnable(GL_BLEND);
        glBlendFunc(GL_ONE, GL_ONE_MINUS_SRC_ALPHA);
        DrawSprite(overlayTextTex_, overlayTextX_ + offsetX, overlayTextY_ + offsetY,
                   static_cast<float>(overlayTextW_), static_cast<float>(overlayTextH_), w, h);
        glDisable(GL_BLEND);
    }
}

void GlesRenderer::DrawScrollScene(int w, int h, bool lazy) {
    const float d = params_.Density();
    float scroll = 0.0f;
    {
        std::lock_guard<std::mutex> lock(animMutex_);
        scroll = listScroll_;
    }
    BlitTexture(bgTex_, w, h);
    const int count = lazy ? 100 : 20;
    for (int i = 0; i < count; i++) {
        const RectF r = ScrollCardRect(i, w, h, d, scroll);
        if (r.y + r.h < -8.0f || r.y > static_cast<float>(h) + 8.0f) {
            continue;
        }
        GlassSpec s = DefaultGlass(r.x, r.y, r.w, r.h, 32.0f * d, d);
        s.vibrancy = 1.5f;
        s.refractionHeight = 16.0f * d;
        s.refractionAmount = 32.0f * d;
        DrawGlass(s, 0, w, h);
    }
}

void GlesRenderer::DrawPlaygroundScene(int w, int h) {
    const float d = params_.Density();
    float px = 0.0f;
    float py = 0.0f;
    bool sheetOpen = true;
    float cornerFrac = 0.5f;
    float blurDp = 0.0f;
    float heightFrac = 0.2f;
    float amountFrac = 0.2f;
    float dispersion = 0.0f;
    float values[5] = {0.5f, 0.0f, 0.2f, 0.2f, 0.0f};
    float sliderPress[5] = {0.0f, 0.0f, 0.0f, 0.0f, 0.0f};
    float buttonPress[2] = {0.0f, 0.0f};
    {
        std::lock_guard<std::mutex> lock(animMutex_);
        px = pgX_;
        py = pgY_;
        sheetOpen = pgSheetOpen_;
        for (int i = 0; i < 5; i++) {
            values[i] = pgSliderValue_[i];
            sliderPress[i] = pgSliderPress_[i];
        }
        buttonPress[0] = pgButtonPress_[0];
        buttonPress[1] = pgButtonPress_[1];
    }

    const RectF panelBase = PgPanelRect(w, h, d);
    const RectF sheet = PgSheetRect(w, h, d);
    const float panelW = panelBase.w;
    const float panelH = panelBase.h;
    const float minDim = std::min(panelW, panelH);

    // 滑块值 -> 面板参数（参考实现的 5 个参数：圆角 / 模糊 / 折射高 / 折射强 / 色散）
    cornerFrac = values[0];
    blurDp = values[1] * 32.0f;
    heightFrac = values[2];
    amountFrac = values[3];
    dispersion = values[4];


    // ---- 底部薄片：画进 sceneTex_（采样 bg，避免读写同一纹理），
    //      这样滑块旋钮与玻璃板都能采样到它 ----
    if (sheetOpen) {
        GlassSpec ss = DefaultGlass(sheet.x, sheet.y, sheet.w, sheet.h, 32.0f * d, d);
        ss.useBackground = true;
        ss.plainHighlight = true;
        ss.highlight = 0.38f;
        ss.vibrancy = 1.5f;
        ss.blurRadiusPx = 4.0f * d;
        ss.refractionHeight = 16.0f * d;
        ss.refractionAmount = 32.0f * d;
        ss.surfaceAlpha = 0.5f;
        DrawGlass(ss, sceneFbo_, w, h);
    }
    BlitTexture(sceneTex_, w, h);

    // ---- 玻璃板（drawBackdrop: vibrancy + blur(0..32dp) + lens(..., depth[, dispersion])）----
    {
        const float radius = 128.0f * d * cornerFrac;
        GlassSpec s = DefaultGlass(panelBase.x + px, panelBase.y + py, panelW, panelH,
                                   std::min(radius, panelH * 0.5f), d);
        s.hasShadow = false;
        s.plainHighlight = true;
        s.highlight = 0.38f;
        s.vibrancy = 1.5f;
        s.blurRadiusPx = blurDp * d;
        s.refractionHeight = heightFrac * minDim * 0.5f;
        s.refractionAmount = amountFrac * minDim;
        s.depthEffect = true;
        s.dispersion = dispersion > 0.0f;
        DrawGlass(s, 0, w, h);
    }

    // ---- 薄片上的滑块（轨道纯色 + 玻璃旋钮）----
    if (sheetOpen) {
        for (int i = 0; i < 5; i++) {
            const RectF row = PgSliderRowRect(i, w, h, d);
            const float trackH = 6.0f * d;
            const float knobW = 40.0f * d;
            const float knobH = 24.0f * d;
            const float progress = std::max(0.0f, std::min(1.0f, values[i]));
            // 轨道
            glEnable(GL_BLEND);
            glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
            SolidSpec trackSolid;
            trackSolid.x = row.x;
            trackSolid.y = row.y + (row.h - trackH) * 0.5f;
            trackSolid.w = row.w;
            trackSolid.h = trackH;
            trackSolid.r = trackH * 0.5f;
            trackSolid.a = kTrackAlpha;
            trackSolid.colorR = kTrackR;
            trackSolid.colorG = kTrackG;
            trackSolid.colorB = kTrackB;
            DrawSolid(trackSolid, w, h);
            SolidSpec fillSolid = trackSolid;
            fillSolid.w = row.w * progress;
            fillSolid.a = 1.0f;
            fillSolid.colorR = kAccentR;
            fillSolid.colorG = kAccentG;
            fillSolid.colorB = kAccentB;
            DrawSolid(fillSolid, w, h);
            glDisable(GL_BLEND);

            // 玻璃旋钮（40×24，与 LiquidSlider 一致）
            float knobX = row.x + row.w * progress - knobW * 0.5f;
            knobX = std::max(row.x - knobW * 0.25f,
                             std::min(row.x + row.w - knobW * 0.75f, knobX));
            const float knobY = row.y + (row.h - knobH) * 0.5f;
            const float press = sliderPress[i];
            GlassSpec knob = DefaultGlass(knobX, knobY, knobW, knobH, knobH * 0.5f, d);
            knob.hasShadow = true;
            knob.shadowBlurPx = 4.0f * d;
            knob.shadowOffsetPx = 4.0f * d / 6.0f;
            knob.shadowAlpha = 0.05f;
            knob.surfaceAlpha = 1.0f - press;
            knob.blurRadiusPx = 8.0f * d * (1.0f - press);
            knob.refractionHeight = 10.0f * d * press;
            knob.refractionAmount = 14.0f * d * press;
            knob.dispersion = true;
            knob.highlight = 0.0f;
            knob.ambient = press > 0.001f;
            knob.ambientIntensity = 0.38f * press;
            knob.highlightWidthPx = std::max(1.0f, std::ceil(0.333f * d));
            knob.highlightBlurPx = knob.highlightWidthPx * 0.5f;
            knob.innerRadiusPx = 4.0f * d * press;
            knob.innerAlpha = 0.15f * press;
            const float knobScale = 1.0f + 0.5f * press;
            knob.scaleX = knobScale;
            knob.scaleY = knobScale;
            DrawGlass(knob, 0, w, h);
        }
    }

    // ---- 两个橙色 tinted 按钮 ----
    glEnable(GL_BLEND);
    glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
    for (int i = 0; i < 2; i++) {
        const RectF base = PgButtonRect(i, sheetOpen, w, h, d);
        const float scale = 1.0f + (4.0f * d) / base.h * buttonPress[i];
        GlassSpec s = DefaultGlass(base.x, base.y, base.w, base.h, base.h * 0.5f, d);
        s.vibrancy = 1.5f;
        s.blurRadiusPx = 2.0f * d;
        s.refractionHeight = 12.0f * d;
        s.refractionAmount = 24.0f * d;
        s.surfaceAlpha = 0.8f;
        s.surfaceR = 1.0f;
        s.surfaceG = 0.553f;
        s.surfaceB = 0.157f;
        s.scaleX = scale;
        s.scaleY = scale;
        DrawGlass(s, 0, w, h);
    }
    glBlendFunc(GL_ONE, GL_ONE_MINUS_SRC_ALPHA);
    DrawOverlayText(w, h);
    glDisable(GL_BLEND);
}

void GlesRenderer::DrawCatalogScene(int w, int h) {
    blurCacheRadius_ = -1.0f;
    blurCacheSrc_ = 0;
    smoothCacheTex_ = 0;
    // 所有目录场景的玻璃都采样 sceneTex_：这里统一先把背景拷进去，
    // 各场景再往上叠自己的内容（暗化 / 卡片 / 轨道）。
    // 之前是各场景自己拷，漏掉的场景（Buttons / Scroll / Adaptive）会采样到**上一帧/上一场景**
    // 残留的 sceneTex_ —— 滚动卡片整块发黑就是这个原因。
    CopyBackgroundToScene(w, h);
    switch (scene_.load()) {
        case static_cast<int>(Scene::kButtons):
            DrawButtonsScene(w, h);
            break;
        case static_cast<int>(Scene::kToggle):
            DrawToggleScene(w, h);
            break;
        case static_cast<int>(Scene::kSlider):
            DrawSliderScene(w, h);
            break;
        case static_cast<int>(Scene::kDialog):
            DrawDialogScene(w, h);
            break;
        case static_cast<int>(Scene::kControlCenter):
            DrawControlCenterScene(w, h);
            break;
        case static_cast<int>(Scene::kLockScreen):
            DrawLockScreenScene(w, h);
            break;
        case static_cast<int>(Scene::kMagnifier):
            DrawMagnifierScene(w, h);
            break;
        case static_cast<int>(Scene::kProgressiveBlur):
            DrawProgressiveBlurScene(w, h);
            break;
        case static_cast<int>(Scene::kAdaptiveLuminance):
            DrawAdaptiveScene(w, h);
            break;
        case static_cast<int>(Scene::kScrollContainer):
            DrawScrollScene(w, h, false);
            break;
        case static_cast<int>(Scene::kLazyScrollContainer):
            DrawScrollScene(w, h, true);
            break;
        case static_cast<int>(Scene::kPlayground):
            DrawPlaygroundScene(w, h);
            break;
        default:
            break;
    }
}

void GlesRenderer::RenderBackground(int w, int h) {
    // ---- pass 1: 背景 -> bgTex_ ----
    glBindFramebuffer(GL_FRAMEBUFFER, bgFbo_);
    glViewport(0, 0, w, h);
    glDisable(GL_BLEND);
    glUseProgram(progBg_);
    glUniform2f(Uniform(progBg_, "uResolution"), static_cast<float>(w),
                static_cast<float>(h));
    // ArkTS 内容模式：背景就是实时的 ArkUI 画面（blit 后与 surface 1:1，直接整幅采）
    const bool useContent = contentBackdrop_.load() && contentValid_;
    const bool isDialogScene = (scene_.load() == static_cast<int>(Scene::kDialog));
    // 弹窗实时背景：共享镜像纹理（中枢发布的最新一帧），拿不到就用快照
    SharedBackdrop::Frame liveFrame;
    RectF liveRect;
    bool useLive = false;
    if (isDialogScene && !useContent && sharedGen_ != 0) {
        bool liveEnabled = false;
        {
            std::lock_guard<std::mutex> lock(dialogGeoMutex_);
            liveEnabled = dialogLiveEnabled_;
            liveRect = dialogLiveRect_;
        }
        useLive = liveEnabled && SharedBackdrop::Get().Acquire(sharedGen_, &liveFrame);
    }
    glActiveTexture(GL_TEXTURE0);
    glBindTexture(GL_TEXTURE_2D, useLive ? liveFrame.tex : (useContent ? contentBlitTex_ : photoTex_));
    glUniform1i(Uniform(progBg_, "uPhoto"), 0);
    glUniform1f(Uniform(progBg_, "uContentMode"), useContent ? 1.0f : 0.0f);
    glUniform2f(Uniform(progBg_, "uPhotoSize"),
                static_cast<float>(useLive ? liveFrame.width : photoW_),
                static_cast<float>(useLive ? liveFrame.height : photoH_));
    const bool isDialog = (scene_.load() == static_cast<int>(Scene::kDialog));
    glUniform1f(Uniform(progBg_, "uScrollRange"),
                isDialog ? 1.0f : params_.N(pid::kBackgroundScrollRange));
    glUniform1f(Uniform(progBg_, "uScroll"), isDialog ? 0.0f : scroll_.load());
    // 背景平移（vp -> px）：
    // - 对话框场景：1:1 绝对对齐屏幕，位移为 0；
    // - 内容模式用渲染线程每帧重算的镜像滞后补偿（contentShiftVp_，与手里那帧纹理同帧）；
    // - 照片 / 快照模式仍用 ArkTS 推的位移（demo 从不设置，恒为 0）。
    glUniform2f(Uniform(progBg_, "uBackdropShift"),
                isDialog ? 0.0f : ((useContent ? 0.0f : backdropShiftX_.load()) * params_.Density()),
                isDialog ? 0.0f : ((useContent ? contentShiftVp_.load() : backdropShiftY_.load()) * params_.Density()));
    // 内容纹理比 surface 高（上下余量）：采样映射用（见 SetContentBand / 背景 shader）。
    glUniform1f(Uniform(progBg_, "uBandBottom"),
                static_cast<float>(ContentBandBottomPx()));
    glUniform1f(Uniform(progBg_, "uBandHeight"),
                static_cast<float>(h + ContentBandExtraPx()));
    RectF photoRect;
    bool photoMapped = false;
    if (isDialog && !useContent) {
        std::lock_guard<std::mutex> lock(dialogGeoMutex_);
        photoMapped = dialogPhotoMapped_;
        photoRect = dialogPhotoRect_;
    }
    if (useLive) {
        photoMapped = true;
        photoRect = liveRect;
    }
    glUniform1f(Uniform(progBg_, "uPhotoMapped"), photoMapped ? 1.0f : 0.0f);
    glUniform4f(Uniform(progBg_, "uPhotoRect"), photoRect.x, photoRect.y, photoRect.w,
                photoRect.h);
    glUniform1f(Uniform(progBg_, "uPhotoFlipY"), useLive ? 1.0f : 0.0f);
    if (useLive) {
        // 滞后补偿（与页签同款）：镜像帧落后主树几帧，按"主树此刻偏移 − 这帧纹理的偏移"
        // 平移采样（正 = 内容上移 → 采样点下移），玻璃与真实内容同帧。
        const float shiftVp = SharedContentOffsetVp() - liveFrame.mirrorOffsetVp;
        glUniform2f(Uniform(progBg_, "uBackdropShift"), 0.0f, shiftVp * params_.Density());
    }
    glDrawArrays(GL_TRIANGLES, 0, 3);
    if (useLive) {
        // 背景已拷进 bgTex_，共享槽本帧不再需要：交回读栅栏
        SharedBackdrop::Get().Release(liveFrame);
        liveDrawn_ = true;
    }
}

void GlesRenderer::DrawFrame(float seconds) {
    const int w = targetW_;
    const int h = targetH_;
    if (w <= 0 || h <= 0) {
        return;
    }
    // 内联控件：背景是固定的卡片底色（自己清屏），不采样内容快照 / 照片背景
    if (IsWidgetMode()) {
        DrawWidgetScene(w, h);
        return;
    }
    // 背景两种场景都要：页签场景后续用它的模糊链（在 DrawTabsScene 里按玻璃几何裁剪后画）；
    // 目录场景直接铺/采样它。
    const int scene = scene_.load();
    if (scene == static_cast<int>(Scene::kTabs)) {
        DrawTabsScene(w, h, debugMode_.load());
    } else if (scene == static_cast<int>(Scene::kDialog) && dialogCustom_.load()) {
        // HallPass 嵌入式弹窗：背景 / 暗化 / 拷贝都只算面板附近（DrawDialogScene 里按几何裁剪），
        // 不走目录场景统一的整屏背景 + 整屏拷贝
        DrawDialogScene(w, h);
    } else {
        {
            GpuPassScope gpu(gpuTimer_, kGpuBackground);
            RenderBackground(w, h);
        }
        GpuPassScope gpu(gpuTimer_, kGpuOther);
        DrawCatalogScene(w, h);
    }
    glFlush();
}

void GlesRenderer::DrawTabsScene(int w, int h, int mode) {
    const float texelX = 1.0f / static_cast<float>(w);
    const float texelY = 1.0f / static_cast<float>(h);

    // HallPass 集成（叠加模式 / demo 件开关）：整帧快照一次，后面的 pass 用同一份
    const bool island = overlayMode_.load();
    const bool chrome = demoChrome_.load();

    // ---- 动画状态快照：后面的 pass 都用这一份（避免各 pass 各自加锁）----
    float animValue = 0.0f;
    float animPress = 0.0f;
    float animSpeed = 0.0f;
    float animScaleX = 1.0f;
    float animScaleY = 1.0f;
    float animGlowPress = 0.0f;
    float btnPress[kIconButtonCount] = {0.0f, 0.0f, 0.0f};
    {
        std::lock_guard<std::mutex> lock(animMutex_);
        animValue = anim_.value;
        animPress = anim_.press;
        animSpeed = anim_.speed;
        animScaleX = anim_.scaleX;
        animScaleY = anim_.scaleY;
        animGlowPress = glowPress_;
        for (int i = 0; i < kIconButtonCount; i++) {
            btnPress[i] = btnPress_[i];
        }
    }

    const float marginH = params_.Px(pid::kOuterPaddingH);
    const float marginV = params_.Px(pid::kOuterPaddingV);
    const float barH = params_.Px(pid::kBarHeight);
    if (!floatInited_) {
        // 初始位置：与底板同宽、水平对齐，放在底板**上方**
        floatX_.store(marginH);
        floatY_.store(marginV + barH + 180.0f);
        floatInited_ = true;
    }
    const float innerPad = TabInnerPadPx();
    const float barW = static_cast<float>(w) - marginH * 2.0f;
    const float capInsetPx = IndicatorEndInsetPx();

    const float panelOffset = panelOffsetPx_.load();
    const float tabW = (barW - innerPad * 2.0f) / 3.0f;
    // 底板圆角半径（参数 68）：钳到"高度一半"上限，超过就是胶囊
    const float panelRadius = std::min(params_.Px(pid::kPanelCornerRadius), barH * 0.5f);

    // ---- 指示器几何（面板 pass 也要用：静态黑底画在页签文字**之下**，见 kGlassShaderBody）----
    //   高度恒为 id 41；按压缩放走 scaleX/scaleY 的**独立弹簧**（参数 60..63），
    //   与参考实现的 layerBlock（固定 52dp 的胶囊 + scale）一致。
    const float indH = params_.Px(pid::kIndicatorHeight);
    // 胶囊宽度 = 页签格 + 2 × (外扩 - 内缩)：对齐参考实现的
    // growthPx = (indicatorExpand - indicatorPadding)。
    const float growthPx = params_.Px(pid::kIndicatorExpand) - params_.Px(pid::kIndicatorPadding);
    const float indW = tabW + growthPx * 2.0f;
    float indX = marginH + panelOffset + innerPad + (animValue + 0.5f) * tabW - indW * 0.5f;
    // 端头钳位（对齐参考实现的 fastCoerceIn(minLeftPx, maxLeftPx)）：
    // 胶囊端头圆弧必须和底板端头圆弧同心 → 两侧至少留「同心留白」。
    {
        const float panelLeft = marginH + panelOffset;
        const float minLeft = panelLeft + capInsetPx;
        const float maxLeft = std::max(minLeft, panelLeft + barW - indW - capInsetPx);
        indX = std::max(minLeft, std::min(maxLeft, indX));
    }
    const float indY = marginV + (barH - indH) * 0.5f;
    // 速度形变（拖动才非 1）：拉长/压扁，走非等比缩放。
    // 速度口径：animSpeed 已经是参考实现的 dragVelocity（value/秒 ÷ 2），这里 /10 同上游。
    const float vel = animSpeed / 10.0f;
    const float stretch = std::max(-0.2f, std::min(0.2f, vel * params_.N(pid::kVelocityStretch)));
    const float squash = std::max(-0.2f, std::min(0.2f, vel * params_.N(pid::kVelocitySquash)));
    const float indScaleX = 1.0f / (1.0f - stretch);
    const float indScaleY = 1.0f * (1.0f - squash);
    // 按压放大 = 形状缩放（纵向 id 51 / 横向 id 82 的弹簧目标）：撑大胶囊形状。
    // 横纵分开：纵向鼓得多、横向收着长（HallPass 观感微调）。
    // 采样缩放（参数 81）与形状缩放解耦：形状向外膨胀的同时，胶囊里看到的底座 / 文字
    // 绕胶囊中心**缩微** —— 两者方向相反，合起来才是"液态透镜被按下去"的观感。
    // 下限 0.5 是防御：参数走 SetNumber 进来不设边界，极端值下别把采样缩到 0 / 负数。
    const float pressScaleX = std::max(1.0f, animScaleX);
    const float pressScaleY = std::max(1.0f, animScaleY);
    const float contentScale =
        std::max(0.5f, 1.0f - params_.N(pid::kPressSampleShrink) * animPress);
    // 静止/拖动两组值按 press 线性插值（与参考实现的 lerp(rest, drag, press) 一致）
    const auto lerpN = [this](int restId, int dragId, float t) {
        return params_.N(restId) + (params_.N(dragId) - params_.N(restId)) * t;
    };

    // 底板按压缩放（参数 5，对齐参考实现的 GlassPanel 的 layerBlock）：
    //   scale = lerp(1, 1 + pressGrowth.px / 底板宽, press)
    // 以底板中心为锚点。参考实现里这个缩放只作用于**玻璃层**（文字与指示器不跟着缩放），
    // 但缩量只有百分之几（3dp / 896px ≈ 1.3%），这里让底板矩形整体缩放、文字跟着被拉
    // 1.3% —— 视觉上等价，而且不需要给文字单独做逆变换。
    // 指示范围：极值 20dp / 896px ≈ 2.2%，仍远小于文字距底板边缘的内缩（14dp）。
    const float panelScale =
        1.0f + (barW > 1.0f ? params_.Px(pid::kPressGrowth) / barW : 0.0f) * animPress;
    const float panelW = barW * panelScale;
    const float panelH = barH * panelScale;
    const float panelCx = marginH + panelOffset + barW * 0.5f;
    const float panelCy = marginV + barH * 0.5f;

    // ---- pass 1：背景（叠加模式只算玻璃会采样到的区域）----
    // 叠加模式下底板形状外只输出投影、不读背景，bgTex_ 只被这几处采样：模糊源（底板内）、
    // 底板材质（底板内，折射往里收）、指示器透镜的面板外采样（胶囊内 + 透镜位移 ≤ ~10px）。
    // 所以裁到「按压缩放后的底板 ∪ 胶囊外接框」外扩 16px；demo 整屏模式（直写形状外背景 /
    // 浮动件 / 顶部按钮）仍画整屏。裁剪盒外的 bgTex_ 保留旧内容，但没有人读。
    const bool clipToGlass = island && !chrome;
    const float panelLeftPx = panelCx - panelW * 0.5f;
    const float panelBottomPx = panelCy - panelH * 0.5f;
    {
        GpuPassScope gpu(gpuTimer_, kGpuBackground);
        if (clipToGlass) {
            const float capHalfW = indW * 0.5f * pressScaleX * indScaleX;
            const float capHalfH = indH * 0.5f * pressScaleY * indScaleY;
            const float capCx = indX + indW * 0.5f;
            const float capCy = indY + indH * 0.5f;
            const float x0 = std::min(panelLeftPx, capCx - capHalfW);
            const float y0 = std::min(panelBottomPx, capCy - capHalfH);
            const float x1 = std::max(panelLeftPx + panelW, capCx + capHalfW);
            const float y1 = std::max(panelBottomPx + panelH, capCy + capHalfH);
            glEnable(GL_SCISSOR_TEST);
            SetScissorRect(x0, y0, x1 - x0, y1 - y0, 16.0f, w, h);
        }
        RenderBackground(w, h);
        glDisable(GL_SCISSOR_TEST);
    }

    // ---- pass 2/3: 可分离高斯模糊 ----
    // 小半径走全分辨率两趟；大半径自动改用降采样金字塔（见 RenderBlur）。
    // 结果只被底板材质采样（底板形状内、折射往里收），全分辨率路径裁到底板外扩 8px
    // （≥ 9-tap 的支撑半径 + 抗锯齿带：第二趟读到的第一趟纹素都在裁剪盒内）。
    gpuTimer_.Begin(kGpuBlur);
    const float blurRadius = (mode == 4) ? 0.0f : params_.Px(pid::kBlurRadius);
    const RectF blurClip{panelLeftPx - 8.0f, panelBottomPx - 8.0f, panelW + 16.0f, panelH + 16.0f};
    const GLuint blurResult = (blurRadius > 0.01f)
                                  ? RenderBlur(bgTex_, blurRadius, clipToGlass ? &blurClip : nullptr)
                                  : static_cast<GLuint>(bgTex_);

    // ---- pass 2b: 按钮专用模糊 ----
    // 上游 GlassIconButton 的模糊是 `blur(iconBlurBase + 底板模糊 × iconBlurScale)`
    // （id 10 + id 1 × id 11），与底板的 0.7dp 差一个量级，共用一张结果会让按钮"过清"。
    // 按钮半径通常较小、且只覆盖按钮带，所以保持全分辨率 + scissor，不用金字塔。
    // 顶部按钮是 demo 专属件（chrome），HallPass 不画它们，也就不必算这张模糊。
    const float btnBlurRadius =
        (mode == 4 || !chrome) ? 0.0f
                               : (params_.Px(pid::kIconBlurBase) +
                                  params_.Px(pid::kBlurRadius) * params_.N(pid::kIconBlurScale));
    const GLuint btnBlurResult =
        (btnBlurRadius > 0.01f) ? RenderButtonBlur(bgTex_, btnBlurRadius)
                                : static_cast<GLuint>(bgTex_);
    gpuTimer_.End();

    // ---- pass 4: 合成（背景 + 底板玻璃 + 文字）-> sceneTex_ ----
    gpuTimer_.Begin(kGpuPanel);
    glBindFramebuffer(GL_FRAMEBUFFER, sceneFbo_);
    glViewport(0, 0, w, h);
    glDisable(GL_BLEND);
    glUseProgram(progGlass_);
    glActiveTexture(GL_TEXTURE0);
    glBindTexture(GL_TEXTURE_2D, bgTex_);
    glUniform1i(Uniform(progGlass_, "uBackdrop"), 0);
    glActiveTexture(GL_TEXTURE1);
    glBindTexture(GL_TEXTURE_2D, blurResult);
    glUniform1i(Uniform(progGlass_, "uBlurred"), 1);
    glActiveTexture(GL_TEXTURE2);
    glBindTexture(GL_TEXTURE_2D, labelTex_);
    glUniform1i(Uniform(progGlass_, "uLabels"), 2);
    glUniform2f(Uniform(progGlass_, "uLabelSize"), static_cast<float>(labelW_),
                static_cast<float>(labelH_));
    glUniform2f(Uniform(progGlass_, "uResolution"), static_cast<float>(w),
                static_cast<float>(h));
    glUniform2f(Uniform(progGlass_, "uTexel"), texelX, texelY);
    glUniform4f(Uniform(progGlass_, "uGlassRect"), panelCx - panelW * 0.5f,
                panelCy - panelH * 0.5f, panelW, panelH);
    // 底板四角半径（等值）：参数 68，钳到高度一半；按压时随底板一起放大
    const float panelRadiusPx = panelRadius * panelScale;
    glUniform4f(Uniform(progGlass_, "uRadii"), panelRadiusPx, panelRadiusPx,
                panelRadiusPx, panelRadiusPx);
    glUniform1f(Uniform(progGlass_, "uRefractionHeight"),
                mode == 2 ? 0.0f : params_.Px(pid::kRefractionHeight));
    // 上游 Lens.kt 送的是 **-refractionAmount**：位移因此指向形状内侧，边缘是"压缩/内折"
    // 的液态玻璃感。直接送正值 = 采样朝形状外 → 边缘外凸成凸透镜。必须同样取负。
    glUniform1f(Uniform(progGlass_, "uRefractionAmount"),
                -params_.Px(pid::kRefractionAmount));
    glUniform1f(Uniform(progGlass_, "uDispersion"),
                (params_.B(0) && mode != 1) ? 1.0f : 0.0f);   // bool 0 = 底座色散
    // depthEffect（bool 6）：折射方向叠一层径向分量
    glUniform1f(Uniform(progGlass_, "uDepthEffect"),
                params_.B(bid::kDepthEffect) ? 1.0f : 0.0f);
    glUniform1f(Uniform(progGlass_, "uSurfaceAlpha"),
                mode == 3 ? 0.0f : params_.N(pid::kContainerAlpha));
    // 目录场景新增的 uniform 在底板 pass 上保持"恒等"值，外观与旧版逐像素一致
    glUniform1f(Uniform(progGlass_, "uScaleX"), 1.0f);
    glUniform1f(Uniform(progGlass_, "uScaleY"), 1.0f);
    // 表面填充色（参数 84..86）：缺省纯白（原行为），深色模式由 ArkTS 下发深灰
    glUniform3f(Uniform(progGlass_, "uSurfaceColor"),
                params_.N(pid::kSurfaceColorR), params_.N(pid::kSurfaceColorG),
                params_.N(pid::kSurfaceColorB));
    glUniform2f(Uniform(progGlass_, "uSampleScale"), 1.0f, 1.0f);
    glUniform2f(Uniform(progGlass_, "uSamplePivot"), 0.0f, 0.0f);
    glUniform1f(Uniform(progGlass_, "uAmbientIntensity"), 0.38f);
    glUniform1f(Uniform(progGlass_, "uBlurRadius"), blurRadius);
    glUniform1f(Uniform(progGlass_, "uVibrancy"), params_.B(1) ? 1.5f : 1.0f);  // 提饱和
    // colorControls（亮度/对比度/饱和度）+ 效果不透明度（参数 77..80）
    glUniform1f(Uniform(progGlass_, "uBrightness"), params_.N(pid::kColorBrightness));
    glUniform1f(Uniform(progGlass_, "uContrast"), params_.N(pid::kColorContrast));
    glUniform1f(Uniform(progGlass_, "uSaturation"), params_.N(pid::kColorSaturation));
    glUniform1f(Uniform(progGlass_, "uEffectOpacity"),
                params_.N(pid::kEffectOpacity));
    glUniform1f(Uniform(progGlass_, "uPlainHighlight"),
                params_.B(bid::kPlainHighlight) ? 1.0f : 0.0f);
    glUniform1f(Uniform(progGlass_, "uHighlight"), 0.5f);   // Highlight.Default alpha
    // 棱边高光：环宽 = ceil(0.5dp*4) = 2px，外缘柔化 = blurRadius 0.25dp*4 = 1px
    const float hlWidthPx = std::max(1.0f, std::ceil(params_.Px(pid::kHighlightWidth)));
    glUniform1f(Uniform(progGlass_, "uHighlightWidth"), hlWidthPx);
    glUniform1f(Uniform(progGlass_, "uHighlightBlur"), hlWidthPx * 0.5f);
    glUniform1f(Uniform(progGlass_, "uAmbient"), params_.B(5) ? 1.0f : 0.0f);
    // 外投影：模糊半径 / 向下偏移 / 有效不透明度（参数 70/71/72）。
    // 按压时换成"大范围 / 更弱 / 更散"的一圈（参数 92/93）：胶囊鼓出底板后，贴着
    // 轮廓的窄投影会紧贴鼓出的胶囊露出一圈暗边（真机走查：'指示器外围一圈黑色阴影'），
    // 大模糊 + 低强度的环境影既避开暗边，又给按压鼓出留出体积感。
    glUniform1f(Uniform(progGlass_, "uShadowBlur"),
                lerpN(pid::kShadowBlur, pid::kShadowBlurPress, animPress) * params_.Density());
    glUniform1f(Uniform(progGlass_, "uShadowOffset"), params_.Px(pid::kShadowOffset));
    glUniform1f(Uniform(progGlass_, "uShadowAlpha"),
                lerpN(pid::kShadowAlpha, pid::kShadowAlphaPress, animPress));
    glUniform1f(Uniform(progGlass_, "uShadowSpreadV"), 0.0f);
    // 页签文字**不**进场景纹理：它由 pass 5 叠加（形状外常态色 / 形状内凸显色）。
    // 若在这里画进场景，指示器的透镜会先采到常态字形，再叠凸显色字形 —— 两套重影，
    // 而且拖动时常态字形会被透镜拖着一起动（参考实现里文字是不动的）。
    glUniform1f(Uniform(progGlass_, "uShowLabels"), 0.0f);
    // 选中胶囊底色（深色模式静态纯黑）：几何 = 指示器那一套，"拖动时淡出为 0"
    glUniform4f(Uniform(progGlass_, "uIndicatorRect"), indX, indY, indW, indH);
    glUniform2f(Uniform(progGlass_, "uIndicatorShape"), pressScaleX, pressScaleY);
    glUniform2f(Uniform(progGlass_, "uIndicatorScale"), indScaleX, indScaleY);
    glUniform1f(Uniform(progGlass_, "uIndicatorFill"),
                mode == 3 ? 0.0f : lerpN(pid::kIndicatorFillRest, pid::kIndicatorFillDrag, animPress));
    glUniform1f(Uniform(progGlass_, "uOverlayMode"), 0.0f);
    glUniform1f(Uniform(progGlass_, "uIsland"), island ? 1.0f : 0.0f);
    glUniform1f(Uniform(progGlass_, "uShadow"), 1.0f);
    // 内阴影是顶部按钮才有的（参数 18）；底板与浮动件传 0 = 关
    glUniform1f(Uniform(progGlass_, "uInnerRadius"), 0.0f);
    glUniform1f(Uniform(progGlass_, "uInnerAlpha"), 0.0f);
    glUniform1f(Uniform(progGlass_, "uInnerTopBias"), 0.0f);
    glUniform1f(Uniform(progGlass_, "uInnerSharp"), 0.0f);
    glUniform1f(Uniform(progGlass_, "uInnerTaper"), 1.0f);
    glDrawArrays(GL_TRIANGLES, 0, 3);

    // ---- pass 4b: 跟手光斑（对齐参考实现的 InteractiveHighlight）----
    //   - 位置与上游的 position lambda 同式：(value + 0.5) × 页签格宽 + 底板视差，
    //     **不含**页签格内缩（上游就是这么取的），y = 底板高的一半；再钳在底板范围内
    //   - 加性混合（BlendMode.Plus），乘自己的按压进度弹簧（参数 31/32）
    //   - 写回 sceneFbo_：这样指示器的透镜会把光斑一起折射（上游也是这个图层顺序）
    if (animGlowPress > 0.001f) {
        glBindFramebuffer(GL_FRAMEBUFFER, sceneFbo_);
        glViewport(0, 0, w, h);
        glEnable(GL_BLEND);
        glBlendFunc(GL_ONE, GL_ONE);   // BlendMode.Plus
        glEnable(GL_SCISSOR_TEST);
        SetScissorRect(panelCx - panelW * 0.5f, panelCy - panelH * 0.5f, panelW, panelH, 0.0f,
                       w, h);
        glUseProgram(progGlow_);
        const float panelLeft = marginH + panelOffset;
        float glowX = panelLeft + (animValue + 0.5f) * tabW;
        glowX = std::max(panelLeft, std::min(panelLeft + barW, glowX));
        // 光斑跟底板一起缩放（绕底板中心）：形状 / 圆角 / 中心都乘 panelScale。
        // 否则底板放大后光斑仍裁在未缩放矩形里，端头会露出没被加白的月牙。
        glowX = panelCx + (glowX - panelCx) * panelScale;
        glUniform2f(Uniform(progGlow_, "uResolution"), static_cast<float>(w),
                    static_cast<float>(h));
        glUniform4f(Uniform(progGlow_, "uGlassRect"), panelCx - panelW * 0.5f,
                    panelCy - panelH * 0.5f, panelW, panelH);
        glUniform4f(Uniform(progGlow_, "uRadii"), panelRadiusPx, panelRadiusPx,
                    panelRadiusPx, panelRadiusPx);
        glUniform1f(Uniform(progGlow_, "uProgress"), animGlowPress);
        glUniform1f(Uniform(progGlow_, "uFlat"), params_.N(pid::kGlowFlat));
        glUniform1f(Uniform(progGlow_, "uRadial"), params_.N(pid::kGlowRadial));
        glUniform1f(Uniform(progGlow_, "uRadiusFactor"),
                    params_.N(pid::kGlowRadiusFactor));
        glUniform2f(Uniform(progGlow_, "uCenter"), glowX, panelCy);
        glDrawArrays(GL_TRIANGLES, 0, 3);
        glDisable(GL_SCISSOR_TEST);
        glDisable(GL_BLEND);
    }

    // 注：这里原先在按压时给 sceneTex_ 生成 mip 链，但 sceneTex_ 的缩小过滤一直是 GL_LINEAR
    // （EnsureTargets / DrawDialogScene），mip 层从未被采样 —— 每帧白算一次整链，已删除。
    gpuTimer_.End();

    // ---- pass 5: 指示器（采样 sceneTex_，同一套透镜）-> 屏幕 ----
    glBindFramebuffer(GL_FRAMEBUFFER, 0);
    glViewport(0, 0, w, h);
    // 叠加模式：整屏写屏带 alpha（底板 / 投影透传），必须开普通混合；
    // 直接写屏模式仍是整屏不透明覆盖。
    if (island) {
        // ArkTS 内容模式：内容由 ArkUI 直显（B 形态），玻璃背景纹理只覆盖条带，
        // 默认 framebuffer 每帧内容未定义（EGL 交换后不保留），透明区域必须先清成
        // 全透明，否则 alpha=0 的像素会漏出上一帧的残留。
        glClearColor(0.0f, 0.0f, 0.0f, 0.0f);
        glClear(GL_COLOR_BUFFER_BIT);
        glEnable(GL_BLEND);
        // alpha 单独用 (ONE, ONE_MINUS_SRC_ALPHA)：dst.a = src.a + dst.a×(1-src.a)，
        // 从 0 起算就是 src.a（普通混合会把 alpha 平方，投影 / 边缘会偏弱）。
        glBlendFuncSeparate(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA, GL_ONE,
                            GL_ONE_MINUS_SRC_ALPHA);
    } else {
        glDisable(GL_BLEND);
    }
    // 计时从清屏之后开始：写屏的第一个命令才触发取 buffer（可能等队列），不算进 GPU 时间
    gpuTimer_.Begin(kGpuIndicator);
    glUseProgram(progIndicator_);
    glUniform1f(Uniform(progIndicator_, "uIsland"), island ? 1.0f : 0.0f);
    glActiveTexture(GL_TEXTURE0);
    glBindTexture(GL_TEXTURE_2D, sceneTex_);
    glUniform1i(Uniform(progIndicator_, "uScene"), 0);
    // 清晰页面内容：指示器鼓出底板的部分采它 —— 否则透镜只能钳到场景纹理里
    // "投影用的黑"。不用底板的模糊 + 材质版本：那样底座轮廓在胶囊里就隐形了。
    glActiveTexture(GL_TEXTURE1);
    glBindTexture(GL_TEXTURE_2D, bgTex_);
    glUniform1i(Uniform(progIndicator_, "uPage"), 1);
    // 页签文字的两张位图：凸显色（形状内）/ 常态色（形状外），逐像素同布局
    glActiveTexture(GL_TEXTURE2);
    glBindTexture(GL_TEXTURE_2D, labelAccentTex_);
    glUniform1i(Uniform(progIndicator_, "uLabelsAccent"), 2);
    glActiveTexture(GL_TEXTURE3);
    glBindTexture(GL_TEXTURE_2D, labelTex_);
    glUniform1i(Uniform(progIndicator_, "uLabels"), 3);
    glUniform2f(Uniform(progIndicator_, "uResolution"), static_cast<float>(w),
                static_cast<float>(h));

    // 指示器几何在上方统一定义（indX / indY / indW / indH / indScaleX/Y / pressScaleX/Y）
    glUniform4f(Uniform(progIndicator_, "uRect"), indX, indY, indW, indH);
    // 胶囊 = 四角等半径
    const float indRadius = indH * 0.5f;
    glUniform4f(Uniform(progIndicator_, "uRadii"), indRadius, indRadius, indRadius,
                indRadius);
    glUniform1f(Uniform(progIndicator_, "uScaleX"), indScaleX);
    glUniform1f(Uniform(progIndicator_, "uScaleY"), indScaleY);
    glUniform1f(Uniform(progIndicator_, "uShapeScaleX"), pressScaleX);
    glUniform1f(Uniform(progIndicator_, "uShapeScaleY"), pressScaleY);
    glUniform1f(Uniform(progIndicator_, "uPressScale"), contentScale);
    // 场景有效区 = 底板**实际画出来的形状**（含按压缩放的矩形 + 圆角半径）：
    // shader 用它判断采样点该取场景合成还是页面内容（圆角缺口 / 投影带里是黑）。
    glUniform4f(Uniform(progIndicator_, "uPanelRect"), panelCx - panelW * 0.5f,
                panelCy - panelH * 0.5f, panelW, panelH);
    glUniform1f(Uniform(progIndicator_, "uPanelRadius"), panelRadiusPx);
    // 页签文字的映射：位图贴在底板矩形上（含底板视差偏移与按压缩放 —— 与底板 pass
    // 原先用 `local` 映射到缩放后矩形的方式逐像素等价，文字随底板一起放大）。
    // 形状外按屏幕坐标采常态色位图，形状内按折射坐标采凸显色位图。
    glUniform4f(Uniform(progIndicator_, "uLabelRect"), panelCx - panelW * 0.5f,
                panelCy - panelH * 0.5f, panelW, panelH);
    glUniform2f(Uniform(progIndicator_, "uLabelSize"), static_cast<float>(labelW_),
                static_cast<float>(labelH_));
    glUniform1f(Uniform(progIndicator_, "uLabelSlots"),
                static_cast<float>(kTabCount));
    glUniform1f(Uniform(progIndicator_, "uShowTabLabels"), 1.0f);
    // 按压时只有凸显色文字放大（参考实现的 LocalLiquidBottomTabScale = lerp(1, 1.2, press)）：
    // 放大比例跟着 press 弹簧走，松手自动回到 1
    glUniform1f(Uniform(progIndicator_, "uLabelPressScale"),
                params_.N(pid::kPressLabelScale) * animPress);
    // 指示器透镜：静止/拖动两组值按 press 线性插值（lerpN 见上方几何块）
    const float lensH = lerpN(pid::kRefractionHeightRest, pid::kRefractionHeightDrag, animPress);
    const float lensA = lerpN(pid::kRefractionAmountRest, pid::kRefractionAmountDrag, animPress);
    glUniform1f(Uniform(progIndicator_, "uRefractionHeight"),
                mode == 2 ? 0.0f : lensH * params_.Density());
    // 同底板：上游对 amount 取负（-refractionAmount），位移朝内才是液态玻璃的边缘压缩
    glUniform1f(Uniform(progIndicator_, "uRefractionAmount"),
                -lensA * params_.Density());
    glUniform1f(Uniform(progIndicator_, "uDispersion"),
                (params_.B(2) && mode != 1) ? 1.0f : 0.0f);   // bool 2 = 指示器色散
    // depthEffect（bool 6）与底板共用同一个开关（上游页签指示器不用，默认关）
    glUniform1f(Uniform(progIndicator_, "uDepthEffect"),
                params_.B(bid::kDepthEffect) ? 1.0f : 0.0f);
    glUniform1f(Uniform(progIndicator_, "uTint"),
                mode == 3 ? 0.0f : lerpN(pid::kTintRest, pid::kTintDrag, animPress));
    // 表面白（参数 36 / 46）：同一层 onDrawSurface 上叠一层白，默认两端都是 0（等价关闭）
    glUniform1f(Uniform(progIndicator_, "uSurfaceWhite"),
                mode == 3 ? 0.0f : lerpN(pid::kSurfaceWhiteRest, pid::kSurfaceWhiteDrag, animPress));
    glUniform1f(Uniform(progIndicator_, "uHighlight"),
                lerpN(pid::kHighlightRest, pid::kHighlightDrag, animPress));
    glUniform1f(Uniform(progIndicator_, "uHighlightWidth"), hlWidthPx);
    glUniform1f(Uniform(progIndicator_, "uHighlightBlur"), hlWidthPx * 0.5f);
    // 外缘细灰线：按压态渐入（非常微弱，只做轮廓对比用；静止态为 0）
    glUniform1f(Uniform(progIndicator_, "uEdgeLine"), 0.28f * animPress);
    // 指示器投影：对齐滑块旋钮按压态的"贴边投影"，但走"更大范围 / 更柔 / 更淡"档：
    // 模糊 9→11dp（滑块 6→7dp）、下移 2→1.5dp、强度 0.045→0.06（滑块 0.20→0.26），
    // 随 press 渐入。按压时启用反向纵向渐变（uShadowSpreadV = press）：影子只落在
    // 轮廓下方 / 两侧（顶边不投），静止态仍不投影（保持原观感）。
    const float indShadowDp = params_.Density();
    glUniform1f(Uniform(progIndicator_, "uShadowBlur"),
                (9.0f + 2.0f * animPress) * indShadowDp);
    glUniform1f(Uniform(progIndicator_, "uShadowOffset"),
                (2.0f - 0.5f * animPress) * indShadowDp);
    glUniform1f(Uniform(progIndicator_, "uShadowAlpha"),
                (0.045f + 0.015f * animPress) * animPress);
    glUniform1f(Uniform(progIndicator_, "uShadowSpreadV"), animPress);
    // 内阴影：半径/强度两组值按 press 插值；强度再乘上游 InnerShadow 的颜色黑 alpha 0.15
    glUniform1f(Uniform(progIndicator_, "uInnerRadius"),
                lerpN(pid::kInnerShadowRadiusRest, pid::kInnerShadowRadiusDrag, animPress) *
                    params_.Density());
    glUniform1f(Uniform(progIndicator_, "uInnerAlpha"),
                lerpN(pid::kInnerShadowAlphaRest, pid::kInnerShadowAlphaDrag, animPress) * 0.15f);
    // 指示器模糊（参数 65/66，默认 0）
    glUniform1f(Uniform(progIndicator_, "uSceneBlur"),
                lerpN(pid::kIndicatorBlurRest, pid::kIndicatorBlurDrag, animPress) *
                    params_.Density());
    glDrawArrays(GL_TRIANGLES, 0, 3);
    gpuTimer_.End();
    if (island) {
        glDisable(GL_BLEND);
    }

    // ---- pass 6: 浮动玻璃件（与底板**同一个 program**，换材质输入 + 叠加混合）----
    // HallPass：浮动玻璃件是 demo 专属件，正式接入时关掉（见 SetDemoChrome）
    if (chrome) {
        //   - uBackdrop 绑已合成的 sceneTex_：折射采样的是"背景 + 底板 + 文字"
        //   - uBlurred  仍绑模糊背景（在底板之外的位置是对的）
        //   - uOverlayMode=1：形状外只输出自己的投影，形状内输出覆盖率 alpha
        glUseProgram(progGlass_);          // ★ pass 5 用的是指示器 program，这里必须切回来
        glEnable(GL_BLEND);
        glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
        // 浮动件同样只占一小块：裁剪到"自己的矩形 + 外投影范围"（等价，省掉整屏的玻璃计算）
        glEnable(GL_SCISSOR_TEST);
        SetScissorRect(floatX_.load(), floatY_.load(), barW, barH,
                       params_.Px(pid::kShadowBlur) + params_.Px(pid::kShadowOffset) + 4.0f, w, h);
        glActiveTexture(GL_TEXTURE0);
        glBindTexture(GL_TEXTURE_2D, sceneTex_);
        glUniform1i(Uniform(progGlass_, "uBackdrop"), 0);
        glActiveTexture(GL_TEXTURE1);
        glBindTexture(GL_TEXTURE_2D, blurResult);
        glUniform1i(Uniform(progGlass_, "uBlurred"), 1);
        glUniform1f(Uniform(progGlass_, "uShowLabels"), 0.0f);
        glUniform1f(Uniform(progGlass_, "uOverlayMode"), 1.0f);
        glUniform1f(Uniform(progGlass_, "uIsland"), 0.0f);
        glUniform1f(Uniform(progGlass_, "uIndicatorFill"), 0.0f);   // 复位：胶囊黑底只在页签条上画
        glUniform4f(Uniform(progGlass_, "uGlassRect"), floatX_.load(), floatY_.load(),
                    barW, barH);
        // 浮动件是四角独立圆角的展示面（参数 73..76）：每角钳到高度一半，避免圆角互相吃掉。
        const float floatRadiusMax = barH * 0.5f;
        glUniform4f(Uniform(progGlass_, "uRadii"),
                    std::min(params_.Px(pid::kFloatCornerTL), floatRadiusMax),
                    std::min(params_.Px(pid::kFloatCornerTR), floatRadiusMax),
                    std::min(params_.Px(pid::kFloatCornerBR), floatRadiusMax),
                    std::min(params_.Px(pid::kFloatCornerBL), floatRadiusMax));
        // 材质与底板一致（同一个 program 且共享参数）：这里显式再写一遍，避免残留上一 pass 的状态
        glUniform1f(Uniform(progGlass_, "uShadowSpreadV"), 0.0f);
        glUniform1f(Uniform(progGlass_, "uDepthEffect"),
                    params_.B(bid::kDepthEffect) ? 1.0f : 0.0f);
        glUniform1f(Uniform(progGlass_, "uBrightness"), params_.N(pid::kColorBrightness));
        glUniform1f(Uniform(progGlass_, "uContrast"), params_.N(pid::kColorContrast));
        glUniform1f(Uniform(progGlass_, "uSaturation"), params_.N(pid::kColorSaturation));
        glUniform1f(Uniform(progGlass_, "uEffectOpacity"),
                    params_.N(pid::kEffectOpacity));
        glUniform1f(Uniform(progGlass_, "uPlainHighlight"),
                    params_.B(bid::kPlainHighlight) ? 1.0f : 0.0f);
        // 浮动件同样把新增 uniform 复位（同一个 program，避免上一 pass 的残留）
        glUniform1f(Uniform(progGlass_, "uScaleX"), 1.0f);
        glUniform1f(Uniform(progGlass_, "uScaleY"), 1.0f);
        glUniform3f(Uniform(progGlass_, "uSurfaceColor"), 1.0f, 1.0f, 1.0f);
        glUniform2f(Uniform(progGlass_, "uSampleScale"), 1.0f, 1.0f);
        glUniform2f(Uniform(progGlass_, "uSamplePivot"), 0.0f, 0.0f);
        glUniform1f(Uniform(progGlass_, "uG2Factor"), 0.45f);
        glUniform1f(Uniform(progGlass_, "uRimClarity"), 0.0f);
        glUniform1f(Uniform(progGlass_, "uBevelAlphaScale"), 1.0f);
        glUniform1f(Uniform(progGlass_, "uAmbientIntensity"), 0.38f);
        glUniform1f(Uniform(progGlass_, "uInnerTopBias"), 0.0f);   // 复位：掩码只归旋钮
        glUniform1f(Uniform(progGlass_, "uInnerSharp"), 0.0f);
        glUniform1f(Uniform(progGlass_, "uInnerTaper"), 1.0f);
        glDrawArrays(GL_TRIANGLES, 0, 3);
        glDisable(GL_SCISSOR_TEST);
        glDisable(GL_BLEND);
    }

    // ---- pass 7: 顶部三个玻璃按钮（同一个 progGlass_，圆形 = 半径取半边长）----
    //   - uBackdrop 绑**清晰背景**、uBlurred 绑按钮自己的模糊链（pass 2b）
    //   - uOverlayMode=1：形状外只输出自己的投影、形状内输出覆盖率 alpha（叠加混合）
    //   - 材质读按钮自己的参数：模糊 10/11、折射 12/13、高光 14/15、阴影 16/17、内阴影 18、
    //     按压缩放 19、按压缩放弹簧 29/30；底色填充仍用 containerAlpha（id 4，上游同式）
    //   - 放在最后画：它们在屏幕顶部，与底板 / 浮动件无重叠，画在最上层最省事
    const float btnSize = ButtonSizePx();
    if (chrome && btnSize > 1.0f) {
        const float iconLensRest = params_.Px(pid::kIconRefractionRest);
        const float iconLensPress = params_.Px(pid::kIconRefractionPress);
        const float iconHlRest = params_.N(pid::kIconHighlightRest);
        const float iconHlPress = params_.N(pid::kIconHighlightPress);
        const float iconShRest = params_.N(pid::kIconShadowRest);
        const float iconShPress = params_.N(pid::kIconShadowPress);
        const float iconInnerPx = params_.Px(pid::kIconInnerShadowRadius);
        const float iconPressScale = params_.N(pid::kIconPressScale);

        glBindFramebuffer(GL_FRAMEBUFFER, 0);
        glViewport(0, 0, w, h);
        glEnable(GL_BLEND);
        glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
        glUseProgram(progGlass_);
        glActiveTexture(GL_TEXTURE0);
        glBindTexture(GL_TEXTURE_2D, bgTex_);
        glUniform1i(Uniform(progGlass_, "uBackdrop"), 0);
        glActiveTexture(GL_TEXTURE1);
        glBindTexture(GL_TEXTURE_2D, btnBlurResult);
        glUniform1i(Uniform(progGlass_, "uBlurred"), 1);
        glUniform2f(Uniform(progGlass_, "uResolution"), static_cast<float>(w),
                    static_cast<float>(h));
        glUniform2f(Uniform(progGlass_, "uTexel"), texelX, texelY);
        glUniform1f(Uniform(progGlass_, "uShowLabels"), 0.0f);
        glUniform1f(Uniform(progGlass_, "uOverlayMode"), 1.0f);
        glUniform1f(Uniform(progGlass_, "uIsland"), 0.0f);
        glUniform1f(Uniform(progGlass_, "uIndicatorFill"), 0.0f);   // 复位：胶囊黑底只在页签条上画
        glUniform1f(Uniform(progGlass_, "uVibrancy"), params_.B(1) ? 1.5f : 1.0f);
        glUniform1f(Uniform(progGlass_, "uSurfaceAlpha"),
                    mode == 3 ? 0.0f : params_.N(pid::kContainerAlpha));
        glUniform1f(Uniform(progGlass_, "uDispersion"),
                    (params_.B(0) && mode != 1) ? 1.0f : 0.0f);
        glUniform1f(Uniform(progGlass_, "uBlurRadius"), btnBlurRadius);
        glUniform1f(Uniform(progGlass_, "uHighlightWidth"), hlWidthPx);
        glUniform1f(Uniform(progGlass_, "uHighlightBlur"), hlWidthPx * 0.5f);
        // 上游按钮只有 DefaultHighlight，不叠环境光 / 不用 depthEffect / 不做色彩控制
        glUniform1f(Uniform(progGlass_, "uAmbient"), 0.0f);
        glUniform1f(Uniform(progGlass_, "uDepthEffect"), 0.0f);
        glUniform1f(Uniform(progGlass_, "uPlainHighlight"), 0.0f);
        glUniform1f(Uniform(progGlass_, "uBrightness"), 0.0f);
        glUniform1f(Uniform(progGlass_, "uContrast"), 1.0f);
        glUniform1f(Uniform(progGlass_, "uSaturation"), 1.0f);
        glUniform1f(Uniform(progGlass_, "uEffectOpacity"), 1.0f);
        glUniform1f(Uniform(progGlass_, "uShadowBlur"), params_.Px(pid::kShadowBlur));
        glUniform1f(Uniform(progGlass_, "uShadowOffset"),
                    params_.Px(pid::kShadowOffset));
        glUniform1f(Uniform(progGlass_, "uShadow"), 1.0f);
        glUniform1f(Uniform(progGlass_, "uScaleX"), 1.0f);
        glUniform1f(Uniform(progGlass_, "uScaleY"), 1.0f);
        glUniform3f(Uniform(progGlass_, "uSurfaceColor"), 1.0f, 1.0f, 1.0f);
        glUniform1f(Uniform(progGlass_, "uG2Factor"), 0.0f);
        glUniform1f(Uniform(progGlass_, "uRimClarity"), 0.0f);
        glUniform1f(Uniform(progGlass_, "uBevelAlphaScale"), 1.0f);
        // uSampleScale / uSamplePivot 是**逐按钮**的（见下面循环），这里不再设恒等值
        glUniform1f(Uniform(progGlass_, "uAmbientIntensity"), 0.38f);

        // 每个按钮只算自己那一块（外扩覆盖它的外投影）
        const float btnShadowPad = params_.Px(pid::kShadowBlur) + params_.Px(pid::kShadowOffset) + 4.0f;
        glEnable(GL_SCISSOR_TEST);
        for (int i = 0; i < kIconButtonCount; i++) {
            const float press = btnPress[i];
            float left = 0.0f;
            float bottom = 0.0f;
            ButtonRectPx(i, w, h, &left, &bottom);
            const float scale = 1.0f + (iconPressScale - 1.0f) * press;
            const float size = btnSize * scale;
            const float cx = left + btnSize * 0.5f;
            const float cy = bottom + btnSize * 0.5f;
            SetScissorRect(cx - size * 0.5f, cy - size * 0.5f, size, size, btnShadowPad, w, h);
            glUniform4f(Uniform(progGlass_, "uGlassRect"), cx - size * 0.5f,
                        cy - size * 0.5f, size, size);
            const float btnRadius = size * 0.5f;
            glUniform4f(Uniform(progGlass_, "uRadii"), btnRadius, btnRadius,
                        btnRadius, btnRadius);
            // 按压采样缩小：与旋钮同量级，绕按钮中心（形状的按压缩放也绕中心）
            const float btnSampleScale = 1.0f - kButtonPressSampleShrink * press;
            glUniform2f(Uniform(progGlass_, "uSampleScale"), btnSampleScale,
                        btnSampleScale);
            glUniform2f(Uniform(progGlass_, "uSamplePivot"), cx, cy);
            // 上游按钮的透镜高度与强度同值：refractionRest + refractionPress × press
            const float lensPx = iconLensRest + iconLensPress * press;
            glUniform1f(Uniform(progGlass_, "uRefractionHeight"), lensPx);
            // 同底板：上游对 amount 取负（-refractionAmount）
            glUniform1f(Uniform(progGlass_, "uRefractionAmount"), -lensPx);
            glUniform1f(Uniform(progGlass_, "uHighlight"),
                        iconHlRest + iconHlPress * press);
            // 阴影 alpha = Shadow.Default 的黑 alpha 0.1 × (rest + press × press)
            glUniform1f(Uniform(progGlass_, "uShadowAlpha"),
                        (iconShRest + iconShPress * press) * 0.1f);
            // 内阴影：半径 = id 18 × press，alpha = press × InnerShadow 的黑 alpha 0.15
            glUniform1f(Uniform(progGlass_, "uInnerRadius"), iconInnerPx * press);
            glUniform1f(Uniform(progGlass_, "uInnerAlpha"), press * 0.15f);
            glUniform1f(Uniform(progGlass_, "uInnerTopBias"), 0.0f);
            glUniform1f(Uniform(progGlass_, "uInnerSharp"), 0.0f);
            glUniform1f(Uniform(progGlass_, "uInnerTaper"), 1.0f);
            glUniform1f(Uniform(progGlass_, "uShadowSpreadV"), 0.0f);
            glDrawArrays(GL_TRIANGLES, 0, 3);
        }
        glDisable(GL_SCISSOR_TEST);
        glDisable(GL_BLEND);
    }

    // ---- pass 8: 按钮图标（叠在按钮之上；图标不参与按压缩放，上游也是兄弟节点）----
    {
        const float iconPx = static_cast<float>(iconTexSizePx_);
        if (chrome && btnSize > 1.0f && iconPx > 0.0f && iconTex_ != 0) {
            float left = 0.0f;
            float bottom = 0.0f;
            ButtonRectPx(0, w, h, &left, &bottom);
            glEnable(GL_BLEND);
            glBlendFunc(GL_ONE, GL_ONE_MINUS_SRC_ALPHA);   // 图标位图是**预乘 alpha**
            glEnable(GL_SCISSOR_TEST);
            // 三个按钮的并集（图标只画在按钮里）
            SetScissorRect(left, bottom,
                           static_cast<float>(kIconButtonCount) * btnSize +
                               static_cast<float>(kIconButtonCount - 1) * ButtonSpacingPx(),
                           btnSize, 2.0f, w, h);
            glUseProgram(progIcon_);
            glActiveTexture(GL_TEXTURE0);
            glBindTexture(GL_TEXTURE_2D, iconTex_);
            glUniform1i(Uniform(progIcon_, "uIcons"), 0);
            glUniform2f(Uniform(progIcon_, "uResolution"), static_cast<float>(w),
                        static_cast<float>(h));
            glUniform2f(Uniform(progIcon_, "uFirstRect"), left, bottom);
            glUniform1f(Uniform(progIcon_, "uBtnSize"), btnSize);
            glUniform1f(Uniform(progIcon_, "uSpacing"), ButtonSpacingPx());
            glUniform1f(Uniform(progIcon_, "uIconSize"), iconPx);
            glDrawArrays(GL_TRIANGLES, 0, 3);
            glDisable(GL_SCISSOR_TEST);
            glDisable(GL_BLEND);
        }
    }

    glFlush();

    // ---- 诊断（叠加模式）：标定写屏缓冲的 alpha（透明区域是否真的 alpha=0）----
    // 每 ~240 帧读两个点：面板外（8,8）与面板正中。TEXTURE 类型下若表层 alpha 生效，
    // 面板外应为 a=0；若仍被按不透明合成，则说明平台侧不吃表层透明，需要换渲染路线。
    // 只在调试模式下跑：glReadPixels 是同步点，会把 GPU 管线拉停一帧（正常路径不能开）。
    if (island && debugMode_.load() != 0 && ++alphaProbeCounter_ >= 240) {
        alphaProbeCounter_ = 0;
        const int midY = static_cast<int>(params_.Px(pid::kOuterPaddingV) +
                                          params_.Px(pid::kBarHeight) * 0.5f);
        unsigned char outPx[4] = {0, 0, 0, 0};
        unsigned char inPx[4] = {0, 0, 0, 0};
        glReadPixels(8, 8, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, outPx);
        glReadPixels(w / 2, midY, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, inPx);
        GLOG("island alpha probe: outside=%{public}d,%{public}d,%{public}d,%{public}d "
             "panel=%{public}d,%{public}d,%{public}d,%{public}d shift=%{public}.1f,%{public}.1f",
             outPx[0], outPx[1], outPx[2], outPx[3], inPx[0], inPx[1], inPx[2], inPx[3],
             backdropShiftX_.load(), backdropShiftY_.load());
    }
}

void GlesRenderer::LogFps() {
    // 每次循环都调用（含空闲跳过的分支）：frameCount_ 只统计真正绘制的帧，
    // skippedFrames_ 统计被空闲检测跳过的次数。
    int64_t now = NowMs();
    if (fpsWindowStartMs_ == 0) {
        fpsWindowStartMs_ = now;
        return;
    }
    int64_t elapsed = now - fpsWindowStartMs_;
    if (elapsed >= 1000) {
        const float fps = frameCount_ * 1000.0f / static_cast<float>(elapsed);
        const float avgDrawMs =
            frameCount_ > 0 ? static_cast<float>(drawMsTotal_) / static_cast<float>(frameCount_)
                            : 0.0f;
        // idle = 这一秒里被空闲检测跳过的帧数：静止时应接近满值（功耗接近 0）；
        // content = 这一秒消费到的内容纹理帧数（内容产帧率，排查"内容 60 / 玻璃 120"）；
        // draw = 平均每帧绘制 + swap 的耗时（排查是节流还是画不动）。
        GLOG("PERF_GL fps=%{public}.1f frames=%{public}d idle=%{public}d content=%{public}d "
             "draw=%{public}.1fms in %{public}lldms mode=%{public}d",
             fps, frameCount_, skippedFrames_, contentFrameCount_, avgDrawMs,
             static_cast<long long>(elapsed), debugMode_.load());
        if (gpuTimer_.Supported()) {
            // 各 pass 的 GPU 毫秒（窗口累计 / 样本轮数）：blit pub bg blur panel mip ind other
            double totals[kGpuPassCount] = {};
            const int samples = gpuTimer_.TakeTotals(totals);
            double sum = 0.0;
            for (double t : totals) {
                sum += t;
            }
            const double perFrame = frameCount_ > 0 ? sum / frameCount_ : 0.0;
            GLOG("PERF_GPU busy=%{public}.2fms/s perFrame=%{public}.3fms samples=%{public}d "
                 "[blit=%{public}.2f pub=%{public}.2f bg=%{public}.2f blur=%{public}.2f "
                 "panel=%{public}.2f mip=%{public}.2f ind=%{public}.2f other=%{public}.2f]",
                 sum * 1000.0 / static_cast<double>(elapsed), perFrame, samples,
                 totals[kGpuContentBlit], totals[kGpuPublish], totals[kGpuBackground],
                 totals[kGpuBlur], totals[kGpuPanel], totals[kGpuMip], totals[kGpuIndicator],
                 totals[kGpuOther]);
        }
        frameCount_ = 0;
        skippedFrames_ = 0;
        contentFrameCount_ = 0;
        drawMsTotal_ = 0;
        fpsWindowStartMs_ = now;
    }
}

void GlesRenderer::RenderLoop(void *window) {
    nativeWindow_ = window;
    if (!InitEgl(window)) {
        GERR("EGL init failed, render loop abort");
        DestroyEgl();
        running_.store(false);
        return;
    }
    if (!InitGl()) {
        GERR("GL init failed, render loop abort");
        DestroyGl();
        DestroyEgl();
        running_.store(false);
        return;
    }
    if (IsHub()) {
        SharedBackdrop::Get().SetHubWake([this]() { RequestRedraw(); });
        SharedBackdrop::Get().AttachHub(display_, context_);
    } else if (sharedGen_ != 0) {
        // 新帧 / 偏移更新：按交互档（8ms）节拍立刻重画，弹窗表面自己收不到触摸，否则一直走 16ms 档
        sharedReaderToken_ = SharedBackdrop::Get().AddReader([this]() {
            lastTouchMs_.store(NowMs());
            RequestRedraw();
        });
    }

    if (!IsWidgetMode()) {
        CreateVsync();
    }

    const auto start = std::chrono::steady_clock::now();
    int lastW = 0;
    int lastH = 0;
    int64_t lastSizeCheck = 0;

    while (!stopRequested_.load()) {
        int64_t now = NowMs();
        // 控件实例不节流：尺寸变化只在 OnSurfaceChanged 里置脏，若错过一次读取
        // （100ms 节流窗口）就可能带着旧尺寸画完又去休眠。两个原子读，代价可忽略。
        if (IsWidgetMode() || now - lastSizeCheck >= 100) {
            lastSizeCheck = now;
            lastW = static_cast<int>(width_.load());
            lastH = static_cast<int>(height_.load());
        }
        if (lastW <= 0 || lastH <= 0) {
            std::this_thread::sleep_for(std::chrono::milliseconds(4));
            continue;
        }
        if (!EnsureTargets(lastW, lastH)) {
            std::this_thread::sleep_for(std::chrono::milliseconds(16));
            continue;
        }
        // GPU 计时：每轮开头回收旧查询、结尾前进一格（探针关闭时是空函数）
        gpuTimer_.BeginFrame();
        struct GpuFrameEnd {
            GpuPassTimer &timer;
            ~GpuFrameEnd() { timer.EndFrame(); }
        } gpuFrameEnd{gpuTimer_};

        const float seconds =
            std::chrono::duration<float>(std::chrono::steady_clock::now() - start).count();

        // ---- 内联控件：按需渲染 ----
        // 背景固定 + 状态由 ArkTS 同步，不交互时没有内容变化：弹簧静止且没有新标记
        // 就休眠（RequestRender / stop 唤醒），避免每个控件常驻一个满帧渲染线程。
        if (IsWidgetMode()) {
            if (!widgetDirty_.exchange(false) && WidgetSettled()) {
                if (!WaitWidgetIdle(250)) {
                    break;   // stop 请求
                }
                continue;
            }
            const int64_t widgetAnimNow = NowMs();
            const float widgetDt =
                (lastAnimMs_ == 0) ? 0.0f
                                   : static_cast<float>(widgetAnimNow - lastAnimMs_) / 1000.0f;
            lastAnimMs_ = widgetAnimNow;
            UpdateCatalogAnim(widgetDt);
            // 停止请求后不再画 / 不再 swap：surface 可能已经被 ArkUI 拆掉，
            // eglSwapBuffers 卡住会把 UI 线程的 join 拖死（实测 9 秒）。
            if (stopRequested_.load()) {
                break;
            }
            DrawFrame(seconds);
            if (stopRequested_.load()) {
                break;
            }
            eglSwapBuffers(display_, surface_);
            continue;
        }

        // 暂停（页面不可见）：不出帧、也不步进动画。仍要消费内容纹理的帧，
        // 否则 ArkUI 的 BuilderNode 生产端会被 buffer 队列堵住。
        if (paused_.load()) {
            if (!stopRequested_.load()) {
                UpdateContentTexture(targetW_, targetH_);
                if (IsHub() && (SharedBackdrop::Get().TakeRepublishRequest() || sharedRetry_) &&
                    SharedBackdrop::Get().WantFrames()) {
                    PublishSharedBackdrop();
                }
            }
            skippedFrames_++;
            // 暂停期也挂在信号上：恢复 / stop / 内容帧都会立刻叫醒，超时只是兜底
            TraceScope trace("GL:paused");
            WaitFrame(sharedRetry_ ? static_cast<int>(kInteractiveFrameMs) : kIdleWaitMs);
            // 睡掉的时间不是动画时间：醒来从当前画面起步。否则第一步 dt = 睡眠时长（夹到 50ms），
            // 按下即跟手的页签弹簧会一步跨过全程（指示器瞬移），按钮按压 / 松手第一帧跳一大截。
            lastAnimNs_ = MonoNs();
            LogFps();
            continue;
        }

        const int64_t animNow = NowMs();
        // 弹簧步长用纳秒时钟：按 vsync 出帧后帧间隔是 8.33ms，毫秒取整会让 dt 在 8/9ms 间跳，
        // 弹簧轨迹带上 ±12% 的步长抖动
        const int64_t animNowNs = MonoNs();
        const float dt = (lastAnimNs_ == 0) ? 0.0f
                                            : static_cast<float>(animNowNs - lastAnimNs_) / 1.0e9f;
        lastAnimNs_ = animNowNs;
        lastAnimMs_ = animNow;
        gSpringMotion = 0.0f;
        UpdateAnim(dt);
        UpdateCatalogAnim(dt);

        // 纹理重传（各自的事件驱动，静止时全是空检查）
        bool uploads = false;
        // HallPass 嵌入式弹窗：文字全由 ArkUI 画，demo 的页签 / 目录 / 弹窗文字与图标位图
        // 一张都用不上；栅格化它们要 ~120ms，正好压在首帧前面（弹窗"弹得慢"的一半）。
        const bool embeddedDialog = dialogCustom_.load() &&
                                    scene_.load() == static_cast<int>(Scene::kDialog);
        if (labelsDirty_.exchange(false) && !embeddedDialog) {
            UploadLabels(targetW_, targetH_);
            uploads = true;
        }
        // 目录场景的文字层：场景/尺寸/数值变化时重传（见各自的 Dirty 标记）
        if (contentTextDirty_.exchange(false) && !embeddedDialog) {
            UploadContentText(targetW_, targetH_);
            uploads = true;
        }
        if (overlayTextDirty_.exchange(false) && !embeddedDialog) {
            UploadOverlayText(targetW_, targetH_);
            uploads = true;
        }
        if (dialogBtnLabelDirty_.exchange(false) && !embeddedDialog) {
            UploadDialogBtnLabel(targetW_, targetH_);
            uploads = true;
        }
        // 顶部按钮的图标位图：尺寸（19dp × density）变了才需要重传
        const int wantIconPx =
            std::max(8, static_cast<int>(kIconButtonIconDp * params_.Density() + 0.5f));
        if (wantIconPx != iconTexSizePx_ && !embeddedDialog) {
            UploadIcons(wantIconPx);
            uploads = true;
        }
        if (photoDirty_.exchange(false)) {
            std::lock_guard<std::mutex> lock(photoMutex_);
            if (!photoPixels_.empty()) {
                glBindTexture(GL_TEXTURE_2D, photoTex_);
                // 尺寸没变走 SubImage：高频快照（叠加模式每几十毫秒一张）下避免每帧重建纹理
                if (photoW_ == photoTexW_ && photoH_ == photoTexH_) {
                    glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, photoW_, photoH_, GL_RGBA,
                                    GL_UNSIGNED_BYTE, photoPixels_.data());
                } else {
                    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, photoW_, photoH_, 0, GL_RGBA,
                                 GL_UNSIGNED_BYTE, photoPixels_.data());
                    photoTexW_ = photoW_;
                    photoTexH_ = photoH_;
                    GLOG("photo texture uploaded %{public}dx%{public}d", photoW_, photoH_);
                }
                glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
                glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
                glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
                glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
                uploads = true;
                photoUploaded_ = true;
            }
        }

        // ArkTS 镜像纹理：每帧取最新帧（没有新帧就沿用上一张），必须在画之前。
        // 有新内容（镜像树在动）就算"要画"；**不抬到交互档** —— 抬帧是整屏形态的
        // 遗留（B 形态条带很便宜，滚动时按 16ms 走即可，避免和 ArkUI 抢 GPU）。
        // 停止中不再碰 OH_NativeImage：surface 销毁时生产端可能正在拆除，
        // 这时候调 UpdateSurfaceImage 有卡住的风险（关闭玻璃页签卡死的另一道保护）。
        const bool contentFrame =
            !stopRequested_.load() && UpdateContentTexture(targetW_, targetH_);
        if (contentFrame) {
            contentFrameCount_++;
        }
        // 新消费者加入时页面多半静止（不会再出内容帧）：用外纹理里的最后一帧补发
        if (IsHub() && !stopRequested_.load() &&
            (SharedBackdrop::Get().TakeRepublishRequest() || sharedRetry_) &&
            SharedBackdrop::Get().WantFrames()) {
            PublishSharedBackdrop();
        }
        // 采样位移每帧重算：基准是**手里这帧纹理**（刚取到的），
        // 所以纹理换帧与补偿变化发生在同一帧里 —— 玻璃里不会出现"补多/补少"交替的闪。
        if (!stopRequested_.load()) {
            UpdateContentShift();
        }
        // 外推量停推后在衰减：衰减到 0 之前每个 vsync 都要重画，否则玻璃停在带外推的那一帧
        const bool leadDecaying = lastLeadVp_ != 0.0f;

        // ---- 空闲检测：没有任何"会改变画面"的输入就不画 ----
        // 判定依据（任一成立就要画）：
        //   ① 输入/参数/场景/尺寸变化（forceRedraw_）
        //   ② 纹理重传（uploads）
        //   ③ 弹簧还在动（位移速率超过阈值），或刚落定、对齐后要再画一帧（SettleSprings）
        //   ④ 交互窗口内（触摸后 400ms，跟手期间不判空闲）
        //   ⑤ 外推量还在衰减（见上）
        //   ⑥ ArkTS 内容纹理有新帧
        // 不画时 surface 保留最后一帧，屏幕内容不变；渲染线程挂在信号上等。
        const bool interacting = (animNow - lastTouchMs_.load()) < kInteractiveWindowMs;
        const bool carried = carryActive_;
        carryActive_ = false;
        const bool forced = forceRedraw_.exchange(false);
        // 弹簧：按位移速率判（见 kIdleMotionRate）。判停的那一轮先过 SettleSprings：都贴着目标
        // 就对齐、再画最后一帧（静止画面与帧时序无关）；还差得远（折返点误判）就当它还在动。
        const float springStepSec = std::min(dt, kMaxSpringStepSec);
        bool springing = springStepSec > 0.0f ? gSpringMotion > kIdleMotionRate * springStepSec
                                              : wasSpringing_;
        bool snapped = false;
        if (!springing && wasSpringing_) {
            const SpringSettle settle = SettleSprings();
            // 位移恰为 0（刚度 0 之类卡住的弹簧）不算在动，免得一直出帧
            springing = settle == SpringSettle::kFar && gSpringMotion > 0.0f;
            snapped = settle == SpringSettle::kSnapped;
        }
        wasSpringing_ = springing;
        const bool active = carried || forced || uploads || springing || snapped || interacting ||
                            leadDecaying || contentFrame;
        if (!active) {
            skippedFrames_++;
            // 挂在信号上：内容帧 / 位移 / 触摸一到就醒，醒来后 loop 顶部会重新消费内容帧 +
            // 重新判定 active。超时只是兜底（共享槽重试期间缩短到一帧）。
            TraceScope trace("GL:idle");
            WaitFrame(sharedRetry_ ? static_cast<int>(kInteractiveFrameMs) : kIdleWaitMs);
            // 睡掉的时间不是动画时间：醒来从当前画面起步。否则第一步 dt = 睡眠时长（夹到 50ms），
            // 按下即跟手的页签弹簧会一步跨过全程（指示器瞬移），按钮按压 / 松手第一帧跳一大截。
            lastAnimNs_ = MonoNs();
            LogFps();
            continue;
        }

        // 出帧节拍：每个 vsync 周期最多一帧，出帧点在 vsync + δ（见 WaitForRenderSlot）。
        // 等过之后回顶部重新消费输入（最新的内容帧 / 偏移 / 弹簧），"这一轮要画"的判定
        // 带到下一轮 —— forceRedraw_ 已在本轮被 exchange 掉，不带过去就会判成空闲。
        if (!WaitForRenderSlot()) {
            carryActive_ = true;
            continue;
        }
        const int64_t drawStartMs = NowMs();
        // trace：本帧为什么画（r 位：1 带入 / 2 外部输入 / 4 重传 / 8 弹簧 / 16 交互窗 / 32 内容帧）
        // 与采样位移用到的偏移（o 主树 / l 外推 / h 手里纹理 / s 位移，vp）
        char frameTrace[112] = "GLF";
        if (TraceEnabled()) {
            const int reasons = (carried ? 1 : 0) | (forced ? 2 : 0) | (uploads ? 4 : 0) |
                                (springing ? 8 : 0) | (interacting ? 16 : 0) | (contentFrame ? 32 : 0);
            snprintf(frameTrace, sizeof(frameTrace), "GLF r=%d o=%.2f l=%.2f h=%.2f s=%.2f", reasons,
                     lastOffsetVp_, lastLeadVp_, heldMirrorOffsetVp_.load(), contentShiftVp_.load());
        }
        {
            TraceScope trace(frameTrace);
            DrawFrame(seconds);
            TraceScope swap("GL:swap");
            // 期望上屏时间 = 现在（SURFACE 型由 RS 消费时生效，TEXTURE 型被忽略）：RS 合成时若有多张
            // 已到期的 buffer 只取最新、丢弃旧的。不设的话 RS 按 FIFO 一次取一张 —— 手势开始时
            // "立即出帧 + 节拍帧"落进同一个合成周期，队列里就一直多压一张，玻璃整段晚 1 帧上屏
            // （真机拖动场景实测：每次取走的都是上一帧交出的那张）。
            if (nativeWindow_ != nullptr) {
                OH_NativeWindow_NativeWindowHandleOpt(reinterpret_cast<OHNativeWindow *>(nativeWindow_),
                                                      SET_DESIRED_PRESENT_TIMESTAMP,
                                                      static_cast<int64_t>(MonoNs()));
            }
            eglSwapBuffers(display_, surface_);
        }
        // 记下这一帧所在的 vsync 周期并预约下一个 vsync（下一帧的节拍基准）
        lastRenderVsyncNs_ = vsyncNs_.load();
        RequestVsync();
        // 对话框：背景快照与卡片几何都已就位的帧交出后才算"可见"（之前的帧是占位暗底 / 默认布局）
        if ((photoUploaded_ || liveDrawn_) && dialogGeoCustom_.load() &&
            scene_.load() == static_cast<int>(Scene::kDialog)) {
            dialogPresented_.store(true);
        }
        drawMsTotal_ += static_cast<int>(NowMs() - drawStartMs);
        frameCount_++;
        LogFps();
    }

    DestroyVsync();
    DestroyGl();
    DestroyEgl();
    running_.store(false);
    threadExited_.store(true);
    GLOG("render loop exited");
}

}  // namespace glass
