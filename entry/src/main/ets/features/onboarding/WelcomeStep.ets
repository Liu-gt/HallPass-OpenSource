/*
 * SPDX-FileCopyrightText: 2026 Liugt
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import { AppButton } from '../../common/components/AppButton';
import { ThemeService, ThemeState } from '../../application/theme/ThemeService';
import { Spacing, Typography, Sizes } from '../../common/design/Tokens';
import { SafeArea } from '../../common/design/SafeArea';
import { DemoModeManager } from '../../application/demo/DemoModeManager';

/**
 * 欢迎/隐私承诺页（票 14，spec F1 步骤①）：端到端加密说明
 * （文案 i18n，零硬编码）；主按钮胶囊（AppButton）进入服务器选择。
 */
@ComponentV2
export struct WelcomeStep {
  /** 品牌色响应源（T24：主题切换经 ThemeState 即时生效）。 */
  private theme: ThemeState = ThemeService.get().state;
  @Event onNext: () => void = (): void => {
  };
  private safeBottom: number = 0;

  aboutToAppear(): void {
    this.safeBottom = SafeArea.bottom();
  }

  build() {
    Column() {
      Blank().layoutWeight(1)

      Column() {
        SymbolGlyph($r('sys.symbol.lock_shield'))
          .fontSize(Sizes.emptyIcon)
          .fontColor([this.theme.primary])

        Text($r('app.string.EntryAbility_label'))
          .fontSize(Typography.largeTitle.size)
          .lineHeight(Typography.largeTitle.lineHeight)
          .fontWeight(Typography.largeTitle.weight)
          .fontColor($r('app.color.label'))
          .margin({ top: Spacing.md })

        Text($r('app.string.welcome_body'))
          .fontSize(Typography.body.size)
          .lineHeight(Typography.body.lineHeight)
          .fontColor($r('app.color.secondary_label'))
          .textAlign(TextAlign.Center)
          .margin({ top: Spacing.lg })
      }
      .constraintSize({ maxWidth: 480 })
      .alignItems(HorizontalAlign.Center)

      Blank().layoutWeight(1.2)

      // === 仅体验 UI 次级按钮 ===
      Button({ type: ButtonType.Capsule, stateEffect: true }) {
        Row({ space: Spacing.xs }) {
          SymbolGlyph($r('sys.symbol.star_animation'))
            .fontSize(16)
            .fontColor([this.theme.primary])
          Text($r('app.string.onboarding_demo_mode_cta'))
            .fontSize(Typography.subhead.size)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.theme.primary)
        }
        .padding({ left: Spacing.lg, right: Spacing.lg, top: Spacing.sm, bottom: Spacing.sm })
      }
      .backgroundColor($r('app.color.secondary_system_background'))
      .borderWidth(1)
      .borderColor(this.theme.primary)
      .opacity(0.9)
      .margin({ bottom: Spacing.md })
      .onClick((): void => {
        DemoModeManager.get().enterDemoMode();
      })

      AppButton({ label: $r('app.string.welcome_cta'), onTap: (): void => this.onNext() })
    }
    .constraintSize({ maxWidth: 520 })
    .width('100%')
    .height('100%')
    .padding({
      left: Spacing.page,
      right: Spacing.page,
      bottom: this.safeBottom + Spacing.xl
    })
  }
}
