/*
 * SPDX-FileCopyrightText: 2026 Liugt
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import { Radius, Typography, Sizes, Opacity } from '../design/Tokens';
import { ThemeService, ThemeState } from '../../application/theme/ThemeService';

/**
 * 主按钮（spec §5.5 / F1）：胶囊，高 Sizes.control、圆角 Radius.pill(Sizes.control)，
 * 品牌色背景（ThemeState.primary）+ on_primary 文字；禁用态统一 opacity(0.6) 且不可点击。
 * 注：参数不得与通用属性同名（width/enabled 与 CustomComponent 基类冲突，编译错误 10505001）。
 */
@ComponentV2
export struct AppButton {
  @Consumer('ThemeState') private theme: ThemeState = ThemeService.get().state;
  @Param label: ResourceStr = '';
  @Param isEnabled: boolean = true;
  @Event onTap: () => void = () => {
  };

  build() {
    Button(this.label)
      .type(ButtonType.Normal)
      .width('100%')
      .height(Sizes.control)
      .borderRadius(Radius.pill(Sizes.control))
      .backgroundColor(this.theme.primary)
      .fontColor(this.theme.onPrimary)
      .fontSize(Typography.headline.size)
      .fontWeight(Typography.headline.weight)
      .opacity(this.isEnabled ? 1 : Opacity.disabled)
      .enabled(this.isEnabled)
      .onClick(() => {
        if (this.isEnabled) {
          this.onTap();
        }
      })
  }
}
