#ifndef GLASS_TEXT_LAYER_H
#define GLASS_TEXT_LAYER_H

#include <cstdint>
#include <string>
#include <vector>

namespace glass {

/**
 * 页签条位图（RGBA8888，**预乘 alpha**，行 0 = 位图顶部）。
 *
 * 之所以要把"图标 + 文字"画成纹理再进 GL 场景，而不是用 ArkUI 浮在上层：
 * 指示器的透镜必须**采样到它们**才能做出拉扯/分光 —— 这是参考图里最亮眼的细节。
 */
struct LabelBitmap {
    int width = 0;
    int height = 0;
    std::vector<uint32_t> pixels;
};

/**
 * 画顶部三个玻璃按钮的图标（白色，预乘 alpha），横向排成一张位图。
 *
 * 形状逐条对齐参考实现的 DragIcon / NotificationIcon / MoreIcon
 * （那三个是 Canvas 手绘的，不是 24×24 的 SVG path，所以不能走 `RenderTabStrip` 的
 * `ParseSvgPath`）。顺序与按钮一致：**0 = 拖动图标（最左），1 = 铃铛，2 = 更多圆点**。
 *
 * @param iconSizePx 单个图标的边长（px）；输出位图尺寸 = (3 × iconSizePx) × iconSizePx。
 */
bool RenderGlassIcons(int iconSizePx, LabelBitmap &out);

/**
 * 画一条"图标 + 文字"的页签条。
 *
 * - [iconPaths] 是 24×24 视口的 SVG path（只含绝对 M/L/Q/Z），与参考实现的
 *   `TabIconPaths` 相同；用 [iconBoldStroke] 加粗描边。
 * - 每个标签居中在自己的格子里，图标在上、文字在下。
 * - [selectedArgb] / [unselectedArgb] 已经包含 alpha 通道。
 */
bool RenderTabStrip(int width, int height, const std::vector<std::string> &labels,
                    const std::vector<std::string> &iconPaths, int selectedIndex,
                    float iconSizePx, float iconGapPx, float iconBoldStroke, float fontSizePx,
                    float innerPaddingPx, uint32_t selectedArgb, uint32_t unselectedArgb,
                    LabelBitmap &out);

// ---------------------------------------------------------------------------
// 目录（catalog）场景用的通用文字 / 图标栅格化
// ---------------------------------------------------------------------------

/** 一段文字。坐标以位图**左上角**为原点（与 native_drawing 的行 0 一致）。 */
struct TextRun {
    std::string text;
    float x = 0.0f;           // 左对齐时是左边缘；居中对齐时是中心；右对齐时是右边缘
    float y = 0.0f;           // 文本块顶部
    float wrapWidth = 0.0f;   // > 0 时按词换行，块宽不超过它
    float fontSizePx = 16.0f;
    uint32_t argb = 0xFFFFFFFF;
    /** 0 = 左对齐，1 = 居中，2 = 右对齐（相对 wrapWidth；无 wrap 时居中/右对齐以 x 为基准） */
    int align = 0;
    bool bold = false;
    int maxLines = 0;         // 0 = 不限
};

/** 量一段文字在当前字号下的宽度（px）。 */
float MeasureTextWidth(const std::string &text, float fontSizePx, bool bold);

/**
 * 把若干段文字栅格化到一张位图（覆盖 [width] × [height] 的矩形，透明底、预乘 alpha）。
 *
 * 之所以要"一次栅格化多段文字"：目录场景的文字是静态布局，按场景缓存一张位图后，
 * 每帧只需一次带贴图的四边形绘制；逐帧用 CPU 排版文字会拖垮渲染线程。
 */
bool RenderTextOverlay(int width, int height, const std::vector<TextRun> &runs, LabelBitmap &out);

/**
 * 专用于按钮等单行文本的精准居中绘制（水平与垂直双向像素级视觉居中）。
 */
bool RenderCenteredText(int width, int height, const std::string &text, float fontSizePx,
                       uint32_t argb, bool bold, LabelBitmap &out);

/**
 * 把一条 24×24 视口的 SVG path（只含绝对 M/L/Q/Z）栅格化成正方形图标位图。
 *
 * 用途：控制中心的飞机图标等（参考实现里是 ImageVector，这里等价成同视口的 path）。
 */
bool RenderIconPath(const std::string &svgPath, float viewport, int sizePx, uint32_t argb,
                    LabelBitmap &out);

}  // namespace glass

#endif  // GLASS_TEXT_LAYER_H
