/*
 * SPDX-FileCopyrightText: 2026 Liugt
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import { Radius, Shadows, Spacing } from '../design/Tokens';

/**
 * 卡片（spec §5.5 / F7）：secondary_system_background 背景 + Radius.lg + Shadows.card，
 * 内边距 Spacing.lg。禁止 .clip(true)（圆角由背景呈现，见 docs/ui-design-tokens.md）。
 */
@ComponentV2
export struct AppCard {
  @Param contentPadding: number = Spacing.lg;
  @BuilderParam content: () => void = this.empty;

  @Builder
  empty() {
  }

  build() {
    Column() {
      this.content()
    }
    .width('100%')
    .padding(this.contentPadding)
    .borderRadius(Radius.lg)
    .backgroundColor($r('app.color.secondary_system_background'))
    .shadow({
      radius: Shadows.card.radius,
      color: Shadows.card.color,
      offsetY: Shadows.card.offsetY
    })
  }
}
