/*
 * SPDX-FileCopyrightText: 2026 Liugt
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

/**
 * 主题表：默认（HandLED 绿）+ 四套莫奈主题。
 * 数值见 docs/ui-design-tokens.md 第 4 节；运行时主题切换由主题管理器落地（架构阶段实现）。
 */
export class ThemeOption {
  readonly id: string;
  readonly nameResource: string;
  /** 浅色模式主色 */
  readonly light: string;
  /** 深色模式主色 */
  readonly dark: string;

  constructor(id: string, nameResource: string, light: string, dark: string) {
    this.id = id;
    this.nameResource = nameResource;
    this.light = light;
    this.dark = dark;
  }
}

export class AppTheme {
  /** on_primary 深浅双值：五套主题共用（spec §5.4），随品牌色同源切换 */
  static readonly onPrimaryLight: string = '#FFFFFF';
  static readonly onPrimaryDark: string = '#091109';

  /** 玻璃底色规格（同 color.json 的 shield_glass_low：主题色 22% 混白、alpha 0x4D≈0.302） */
  static readonly glassLowMix: number = 0.22;
  static readonly glassLowAlpha: number = 0.302;

  static readonly defaultTheme: ThemeOption =
    new ThemeOption('default', 'theme_default', '#3D7A3D', '#8AC18A');
  static readonly waterLily: ThemeOption =
    new ThemeOption('waterlily', 'theme_waterlily', '#3E7F7A', '#7FC4BE');
  static readonly cathedral: ThemeOption =
    new ThemeOption('cathedral', 'theme_cathedral', '#7B6FA0', '#B3A8D6');
  static readonly roses: ThemeOption =
    new ThemeOption('rose', 'theme_rose', '#C26A8D', '#E39CB8');
  static readonly haystacks: ThemeOption =
    new ThemeOption('haystack', 'theme_haystack', '#C77E3D', '#E8A863');

  static readonly all: ThemeOption[] = [
    AppTheme.defaultTheme,
    AppTheme.waterLily,
    AppTheme.cathedral,
    AppTheme.roses,
    AppTheme.haystacks
  ];

  /**
   * 主题色混白：ratio 为主题色占比（如 0.22 ≈ 22% 混入白），alpha 取 0-1，输出 #AARRGGBB。
   * 供无法走资源限制词的运行时着色使用（如盾牌动效的全屏渐变层）。
   */
  static tint(primary: string, ratio: number, alpha: number): string {
    const value: number = Number.parseInt(primary.replace('#', ''), 16);
    const mixOne = (channel: number): number => Math.round(ratio * channel + (1 - ratio) * 255);
    const hex = (n: number): string => n.toString(16).padStart(2, '0').toUpperCase();
    return '#' + hex(Math.round(alpha * 255)) + hex(mixOne((value >> 16) & 0xFF))
      + hex(mixOne((value >> 8) & 0xFF)) + hex(mixOne(value & 0xFF));
  }
}
