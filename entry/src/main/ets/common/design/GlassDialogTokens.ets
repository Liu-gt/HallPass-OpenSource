/*
 * SPDX-FileCopyrightText: 2026 Liugt
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

/**
 * 液态玻璃弹窗设计令牌（1:1 复用 HarmonyOSLiquidGlass demo 中的 dialog 样式）
 * 对应 upstream commit b855b9d9 与 PARAMS_DUMP (2026-10-16 12:21)。
 */
export class GlassDialogTokens {
  /** 背景暗化 Scrim (id 94: dimAlpha 0.34, rgba(5, 8, 13, 0.34)) */
  static readonly scrimColor: string = 'rgba(5, 8, 13, 0.34)';
  /** 深色模式背景暗化（页面本身已暗，压得更深才拉得开层次）。 */
  static readonly scrimColorDark: string = 'rgba(0, 0, 0, 0.50)';

  /** 弹窗底板几何与同心圆约束 (id 95, 96: radius 43dp, 与按钮 radius 25 + padding 18 严格同心) */
  static readonly panelCornerRadius: number = 43.0; // vp
  static readonly panelMaxWidth: number = 360.0; // vp
  static readonly panelG2Factor: number = 0.45;

  /** 弹窗底板材质 (id 97, 105..111) */
  static readonly panelBlur: number = 3.0; // vp
  /** 浅色模式底色 (surfaceAlpha 0.17 on #F5F7FF backdrop blur) */
  static readonly panelSurfaceLight: string = 'rgba(245, 247, 255, 0.70)';
  /** 深色模式底色 (surfaceAlpha 0.55 on #1E2026) */
  static readonly panelSurfaceDark: string = 'rgba(30, 32, 38, 0.75)';

  /** 弹窗棱边高光 (id 109, 110) */
  static readonly panelBorderWidth: number = 0.65; // vp
  static readonly panelBorderLight: string = 'rgba(255, 255, 255, 0.40)';
  static readonly panelBorderDark: string = 'rgba(255, 255, 255, 0.22)';

  /** 弹窗外投影 (id 114..116) */
  static readonly panelShadowRadius: number = 45.0; // vp
  static readonly panelShadowOffsetY: number = 5.0; // vp
  static readonly panelShadowColor: string = 'rgba(0, 0, 0, 0.14)';

  /** 间距布局 */
  static readonly paddingHorizontal: number = 24.0; // vp
  static readonly paddingLateral: number = 18.0; // vp (按钮到两边)
  static readonly paddingTop: number = 26.0; // vp
  static readonly paddingBottom: number = 18.0; // vp
  static readonly spacingTitleBody: number = 10.0; // vp
  static readonly spacingBodyButtons: number = 24.0; // vp
  static readonly spacingBetweenButtons: number = 12.0; // vp

  /** 胶囊按钮几何 (id 117) */
  static readonly buttonHeight: number = 50.0; // vp
  static readonly buttonCornerRadius: number = 25.0; // vp
  static readonly buttonPressScale: number = 1.03; // pressGrow 1.5dp / 50dp
  static readonly buttonFontSize: number = 17.5; // fp

  /** 次要 / 取消按钮玻璃材质 (id 119, 127..138) */
  static readonly secondaryBgLight: string = 'rgba(255, 255, 255, 0.25)';
  static readonly secondaryBgDark: string = 'rgba(255, 255, 255, 0.12)';
  static readonly secondaryBorderWidth: number = 0.45; // vp
  static readonly secondaryBorderLight: string = 'rgba(255, 255, 255, 0.22)';
  static readonly secondaryBorderDark: string = 'rgba(255, 255, 255, 0.14)';
  static readonly secondaryShadowRadius: number = 19.0; // vp
  static readonly secondaryShadowOffsetY: number = 3.0; // vp
  static readonly secondaryShadowColor: string = 'rgba(0, 0, 0, 0.05)';
  static readonly secondaryTextLight: string = '#0B0B0F';
  static readonly secondaryTextDark: string = '#FFFFFF';

  /** 主要 / 确认按钮材质 (id 131..138) */
  static readonly primaryBorderWidth: number = 0.45; // vp
  static readonly primaryBorderColor: string = 'rgba(255, 255, 255, 0.35)';
  static readonly primaryShadowRadius: number = 19.0; // vp
  static readonly primaryShadowOffsetY: number = 3.0; // vp
  static readonly primaryShadowColor: string = 'rgba(0, 0, 0, 0.12)';

  /** 文字排版 */
  static readonly titleFontSize: number = 18.0; // fp
  static readonly titleTextLight: string = '#0B0B0F';
  static readonly titleTextDark: string = '#FFFFFF';

  static readonly bodyFontSize: number = 14.5; // fp
  static readonly bodyLineHeight: number = 20.0; // fp
  static readonly bodyTextLight: string = '#D9282830';
  static readonly bodyTextDark: string = '#B8EBEBF5';
}
