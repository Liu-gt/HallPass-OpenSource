/*
 * SPDX-FileCopyrightText: 2026 Liugt
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import { Spacing, Typography, Radius, Sizes, Shadows } from '../design/Tokens';
import { Motion } from '../design/Motion';
import { ThemeService, ThemeState } from '../../application/theme/ThemeService';

/**
 * 通用确认弹窗（应用内唯一弹窗形态）：页面居中的纯色卡片，靠 shadow.dialog 与背景区分；
 * 全屏轻微压暗（scrim，覆盖状态栏与导航栏）+ 拦截层，选择前点击不触达下层内容；
 * 标题/正文 + 双胶囊按钮：次要按钮灰底深字，强调按钮主题强调色底白字。
 * 所有带按钮的确认/提示统一使用本组件（替代各页内联卡片与系统 showAlertDialog）。
 */
@ComponentV2
export struct ConfirmDialog {
  /** 品牌色响应源（T24：主题切换经 ThemeState 即时生效）。 */
  private theme: ThemeState = ThemeService.get().state;
  @Param title: ResourceStr = '';
  @Param body: ResourceStr = '';
  @Param cancelLabel: ResourceStr = '';
  @Param confirmLabel: ResourceStr = '';
  /** 单按钮提示场景置 false（只渲染强调按钮，占满整行）。 */
  @Param showCancel: boolean = true;
  @Param confirmEnabled: boolean = true;
  @Param cancelEnabled: boolean = true;
  /** 卡片内联错误提示（如生物识别验证未通过），null 不渲染。 */
  @Param errorText: ResourceStr | null = null;
  @Event onCancel: () => void = (): void => {
  };
  @Event onConfirm: () => void = (): void => {
  };

  build() {
    Column() {
      Column() {
        Text(this.title)
          .fontSize(Typography.headline.size)
          .lineHeight(Typography.headline.lineHeight)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.label'))
        Text(this.body)
          .fontSize(Typography.subhead.size)
          .lineHeight(Typography.subhead.lineHeight)
          .fontColor($r('app.color.secondary_label'))
          .margin({ top: Spacing.sm })
        if (this.errorText !== null) {
          Text(this.errorText)
            .fontSize(Typography.footnote.size)
            .lineHeight(Typography.footnote.lineHeight)
            .fontColor($r('app.color.danger'))
            .width('100%')
            .margin({ top: Spacing.sm })
        }
        Row({ space: Spacing.md }) {
          if (this.showCancel) {
            Button(this.cancelLabel)
              .type(ButtonType.Normal)
              .layoutWeight(1)
              .height(Sizes.control)
              .borderRadius(Radius.pill(Sizes.control))
              .backgroundColor($r('app.color.tertiary_system_background'))
              .fontColor($r('app.color.label'))
              .fontSize(Typography.body.size)
              .enabled(this.cancelEnabled)
              .onClick(() => {
                this.onCancel();
              })
          }
          Button(this.confirmLabel)
            .type(ButtonType.Normal)
            .layoutWeight(1)
            .height(Sizes.control)
            .borderRadius(Radius.pill(Sizes.control))
            .backgroundColor(this.theme.primary)
            .fontColor(this.theme.onPrimary)
            .fontSize(Typography.body.size)
            .fontWeight(FontWeight.Medium)
            .enabled(this.confirmEnabled)
            .onClick(() => {
              this.onConfirm();
            })
        }
        .width('100%')
        .margin({ top: Spacing.xl })
      }
      .width('100%')
      .constraintSize({ maxWidth: 380 })
      .padding(Spacing.xl)
      .borderRadius(Radius.xl)
      .backgroundColor($r('app.color.secondary_system_background'))
      .clip(true)
      .shadow({
        radius: Shadows.dialog.radius,
        color: Shadows.dialog.color,
        offsetY: Shadows.dialog.offsetY
      })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .padding({ left: Spacing.xl, right: Spacing.xl })
    .backgroundColor($r('app.color.scrim'))
    // 轻微全屏压暗：扩展到系统栏区域（状态栏 + 导航栏），随出现/消失一起渐显渐隐
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    .onClick(() => {
      // 拦截层：选择前点击不触达下层内容
    })
    // 出现：大→小 + 渐显；消失：小→大 + 渐隐（阴影/卡片随层一起缩放淡出）
    .transition(TransitionEffect.opacity(0)
      .animation({ duration: Motion.durationDialog, curve: Motion.curve })
      .combine(TransitionEffect.scale({ x: 1.15, y: 1.15 })
        .animation({ duration: Motion.durationDialog, curve: Motion.curve })))
  }
}
