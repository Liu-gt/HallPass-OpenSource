/*
 * SPDX-FileCopyrightText: 2026 Liugt
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

/**
 * UI 设计 Token 常量 —— 数值唯一权威源见 docs/ui-design-tokens.md。
 * 页面代码禁止出现裸尺寸/裸色值：尺寸/字号/阴影引用本文件，颜色引用 $r('app.color.*')。
 */

/** 间距刻度（8pt 网格，4 的倍数） */
export class Spacing {
  static readonly xs: number = 4;
  static readonly sm: number = 8;
  static readonly md: number = 12;
  static readonly lg: number = 16;
  static readonly xl: number = 24;
  static readonly xxl: number = 32;
  /** 页面全局左右边距，固定 16 */
  static readonly page: number = Spacing.lg;
}

/** 圆角刻度 */
export class Radius {
  static readonly none: number = 0;
  static readonly xs: number = 6;
  static readonly sm: number = 8;
  static readonly md: number = 12;
  static readonly lg: number = 16;
  static readonly xl: number = 24;
  /** 胶囊圆角 = 高度的一半 */
  static pill(height: number): number {
    return height / 2;
  }
}

/** 字形：size(fp) / lineHeight(fp) / weight */
export class TypeStyle {
  readonly size: number;
  readonly lineHeight: number;
  readonly weight: FontWeight;

  constructor(size: number, lineHeight: number, weight: FontWeight) {
    this.size = size;
    this.lineHeight = lineHeight;
    this.weight = weight;
  }
}

/** 字号阶梯（iOS SF Pro 体系对应 HarmonyOS Sans） */
export class Typography {
  static readonly largeTitle: TypeStyle = new TypeStyle(28, 34, FontWeight.Bold);
  /** 大尺寸头像首字母 */
  static readonly avatarMonogram: TypeStyle = new TypeStyle(38, 44, FontWeight.Bold);
  static readonly title1: TypeStyle = new TypeStyle(28, 34, FontWeight.Normal);
  static readonly title2: TypeStyle = new TypeStyle(22, 28, FontWeight.Normal);
  static readonly title3: TypeStyle = new TypeStyle(20, 25, FontWeight.Normal);
  static readonly headline: TypeStyle = new TypeStyle(17, 22, FontWeight.Medium);
  static readonly body: TypeStyle = new TypeStyle(17, 22, FontWeight.Normal);
  static readonly callout: TypeStyle = new TypeStyle(16, 21, FontWeight.Normal);
  static readonly subhead: TypeStyle = new TypeStyle(15, 20, FontWeight.Normal);
  static readonly footnote: TypeStyle = new TypeStyle(13, 18, FontWeight.Normal);
  static readonly caption1: TypeStyle = new TypeStyle(12, 16, FontWeight.Normal);
  static readonly caption2: TypeStyle = new TypeStyle(11, 13, FontWeight.Normal);
  /** 组件特例：仅底部 TabBar 文字 */
  static readonly tabLabel: TypeStyle = new TypeStyle(10, 12, FontWeight.Normal);
}

/** 阴影定义（颜色为 Token 定义本身，页面只引用） */
export class ShadowToken {
  readonly radius: number;
  readonly color: string;
  readonly offsetY: number;

  constructor(radius: number, color: string, offsetY: number) {
    this.radius = radius;
    this.color = color;
    this.offsetY = offsetY;
  }
}

export class Shadows {
  static readonly card: ShadowToken = new ShadowToken(8, 'rgba(0,0,0,0.06)', 2);
  static readonly floating: ShadowToken = new ShadowToken(16, 'rgba(0,0,0,0.10)', 4);
  /** 确认弹窗卡片：无遮罩场景下靠更重的投影与背景区分（全应用统一弹窗形态）。 */
  static readonly dialog: ShadowToken = new ShadowToken(64, 'rgba(0,0,0,0.14)', 16);
}

/** 不透明度刻度（spec §5.5：按压态与禁用态统一透明度） */
export class Opacity {
  /** 按压态 */
  static readonly pressed: number = 0.6;
  /** 禁用态 */
  static readonly disabled: number = 0.6;
}

/** 组件固定尺寸（均为 4 网格倍数） */
export class Sizes {
  /** 可点击元素最小边长（HIG 硬性要求） */
  static readonly touchMin: number = 44;
  static readonly navBar: number = 44;
  static readonly tabBar: number = 56;
  static readonly control: number = 44;
  static readonly chip: number = 32;
  /** 长度滑条指示器直径 */
  static readonly sliderBlock: number = 24;
  static readonly listAvatar: number = 36;
  static readonly headerAvatar: number = 56;
  static readonly rowIcon: number = 20;
  static readonly tabBarIcon: number = 24;
  static readonly chevron: number = 16;
  static readonly totpRing: number = 20;
  /** 详情页密码强度四段指示条宽度 */
  static readonly passwordStrengthBar: number = 112;
  static readonly themeDot: number = 20;
  static readonly indexerWidth: number = 28;
  static readonly indexerHeight: number = 256;
  static readonly emptyIcon: number = 48;
  /** 细分隔线宽（spec §5.5：分隔线 0.5vp） */
  static readonly hairline: number = 0.5;
}

/**
 * 分组表单语言：设置项、生成器选项与保管库文件夹共用。
 * 概览类分类卡沿用同一字阶、圆角与内边距，但可保留网格布局。
 */
export class GroupedList {
  static readonly sectionGap: number = Spacing.xl;
  static readonly headerGap: number = Spacing.sm;
  static readonly headerInset: number = Spacing.sm;
  static readonly rowHorizontal: number = Spacing.md;
  static readonly rowVertical: number = Spacing.md;
  static readonly cardPadding: number = Spacing.md;
  static readonly cardMinHeight: number = 84;
  static readonly rowMinHeight: number = Sizes.touchMin;
  static readonly headerText: TypeStyle = Typography.footnote;
  static readonly primaryText: TypeStyle = Typography.subhead;
  static readonly secondaryText: TypeStyle = Typography.subhead;
  static readonly chevronText: TypeStyle = Typography.body;
}
