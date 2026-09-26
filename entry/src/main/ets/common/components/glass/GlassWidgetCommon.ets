/*
 * SPDX-FileCopyrightText: 2026 Liugt
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import { common } from '@kit.AbilityKit';

/**
 * 内联液态玻璃控件（开关 / 滑块）的公共部分：
 * id 生成、颜色换算、尺寸常量。原生接口见 backdrop HAR 的 GlassGLWidget*。
 */

/** 控件种类（与原生 GlesRenderer::WidgetKind 一致）。 */
export const GLASS_WIDGET_TOGGLE: number = 0;
export const GLASS_WIDGET_SLIDER: number = 1;

/**
 * 开关控件 surface 尺寸（vp）：= 轨道 44×18 + 左右各 8 留白 + 上下留白。
 *
 * 留白不是装饰：按压放大 1.9 后旋钮（22×14 → 42×27）会在轨道两端各外伸 ≈8dp、
 * 纵向顶到 27vp，surface 贴住轨道宽 / 只按轨道高时会被画布裁掉（旧版裁切问题的根因）；
 * 纵向再留 1.5vp 给按压时的环境光晕。轨道 / 旋钮尺寸见原生 `gles_renderer.cpp`
 * 的 kWigToggle* 常量，两处同改。
 *
 * 注：这 1.5vp 撑不下滑块那套按压外投影（模糊 7 + 下移 1 = 8vp），原生按可用留白
 * 等比缩（见 gles_renderer.cpp 的 kToggleShadowFit）；要满强度投影得把高度一起加上去。
 */
export const GLASS_TOGGLE_WIDTH: number = 60;
export const GLASS_TOGGLE_HEIGHT: number = 30;

/**
 * 开关旋钮的行程（vp）= 轨道宽 44 − 2×内缩 2 − 旋钮宽 22 = 18。
 * 拖拽手势按"手指位移 / 行程"换算 fraction，与原生旋钮 1:1 跟手（原生见 kWigToggle*）。
 */
export const GLASS_TOGGLE_TRAVEL: number = 18;

/**
 * 滑块控件 surface 高度（vp）：旋钮 34×20，按压 / 速度形变后高 20×1.45 ≈ 29vp；
 * 下方还要放下"纵向渐变外投影"的完整衰减（模糊 8.5 + 下移 1 ≈ 9.5vp），故取 46。
 */
export const GLASS_SLIDER_HEIGHT: number = 46;

let widgetSeq: number = 0;

/** 每个控件实例一个唯一 id（原生按 id 建渲染实例，不能复用）。 */
export function nextGlassWidgetId(prefix: string): string {
  widgetSeq += 1;
  return `${prefix}_${widgetSeq}`;
}

/** '#RRGGBB' / '#AARRGGBB' -> 无符号 ARGB（原生要 uint32）。 */
export function hexToArgb(hex: string): number {
  const value: string = hex.startsWith('#') ? hex.substring(1) : hex;
  if (value.length === 8) {
    return parseInt(value, 16) >>> 0;
  }
  if (value.length === 6) {
    return (0xFF000000 | parseInt(value, 16)) >>> 0;
  }
  return 0xFF000000;
}

/**
 * 资源颜色 -> ARGB。玻璃的表面混合 / 折射采样都基于这个底色，
 * 所以必须与控件所在容器（卡片 / 页面）的背景一致。
 */
export function resolveColorArgb(context: common.Context | undefined, res: Resource): number {
  if (context === undefined) {
    return 0xFFFFFFFF;
  }
  try {
    return context.resourceManager.getColorSync(res.id) >>> 0;
  } catch (err) {
    return 0xFFFFFFFF;
  }
}
