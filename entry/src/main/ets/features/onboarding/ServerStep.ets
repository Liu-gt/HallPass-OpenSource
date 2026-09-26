/*
 * SPDX-FileCopyrightText: 2026 Liugt
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import { AppButton } from '../../common/components/AppButton';
import { ThemeService, ThemeState } from '../../application/theme/ThemeService';
import { Spacing, Typography, Radius, Shadows, Sizes } from '../../common/design/Tokens';
import { SafeArea } from '../../common/design/SafeArea';

/** 官方云默认地址（spec F1）。 */
const OFFICIAL_SERVER_URL: string = 'https://vault.bitwarden.com';

/**
 * 单选服务器卡片（独立子组件）：选中态经 @Param 传入，保证切换即时刷新
 * （@Builder 传参在 V2 中不响应，票 14 走查缺陷修复）。
 */
@ComponentV2
struct ServerCard {
  /** 品牌色响应源（T24：主题切换经 ThemeState 即时生效）。 */
  private theme: ThemeState = ThemeService.get().state;
  @Param title: ResourceStr = '';
  @Param selected: boolean = false;
  @Event onSelect: () => void = (): void => {
  };

  build() {
    Row({ space: Spacing.md }) {
      Text(this.title)
        .fontSize(Typography.body.size)
        .lineHeight(Typography.body.lineHeight)
        .fontWeight(Typography.body.weight)
        .fontColor($r('app.color.label'))
        .layoutWeight(1)
      if (this.selected) {
        SymbolGlyph($r('sys.symbol.checkmark'))
          .fontSize(Sizes.rowIcon)
          .fontColor([this.theme.primary])
      }
    }
    .width('100%')
    .constraintSize({ minHeight: Sizes.touchMin })
    .padding(Spacing.lg)
    .borderRadius(Radius.lg)
    .backgroundColor($r('app.color.secondary_system_background'))
    .borderWidth(2)
    .borderColor(this.selected ? this.theme.primary : Color.Transparent)
    .shadow({
      radius: Shadows.card.radius,
      color: Shadows.card.color,
      offsetY: Shadows.card.offsetY
    })
    .onClick(() => this.onSelect())
  }
}

/**
 * 服务器选择页（spec F1 步骤②）：官方云 / 第三方服务器二选一单选卡片
 * （Radius.lg + Shadows.card，选中 primary 描边）。
 * 第三方服务器的地址输入移至登录页（登录表单下方的服务器地址选项），本页不做校验。
 */
@ComponentV2
export struct ServerStep {
  /** 品牌色响应源（T24：主题切换经 ThemeState 即时生效）。 */
  private theme: ThemeState = ThemeService.get().state;
  /** onNext 传回所选地址；选择第三方服务器时传空串（地址由登录页输入）。 */
  @Event onNext: (serverUrl: string) => void = (serverUrl: string): void => {
  };
  @Event onBack: () => void = (): void => {
  };
  @Local private thirdParty: boolean = false;
  private safeTop: number = 0;
  private safeBottom: number = 0;

  aboutToAppear(): void {
    this.safeTop = SafeArea.top();
    this.safeBottom = SafeArea.bottom();
  }

  private submit(): void {
    this.onNext(this.thirdParty ? '' : OFFICIAL_SERVER_URL);
  }

  build() {
    Column() {
      // 固定布局（不滚动）：内容区限宽居中，适配折叠屏展开等宽屏比例。
      Column() {
        Text($r('app.string.server_title'))
          .fontSize(Typography.largeTitle.size)
          .lineHeight(Typography.largeTitle.lineHeight)
          .fontWeight(Typography.largeTitle.weight)
          .fontColor($r('app.color.label'))
          .margin({ top: this.safeTop + Spacing.xl })

        Text($r('app.string.server_desc'))
          .fontSize(Typography.subhead.size)
          .lineHeight(Typography.subhead.lineHeight)
          .fontColor($r('app.color.secondary_label'))
          .margin({ top: Spacing.md })

        Column({ space: Spacing.md }) {
          ServerCard({
            title: $r('app.string.server_official'),
            selected: !this.thirdParty,
            onSelect: (): void => {
              this.thirdParty = false;
            }
          })
          ServerCard({
            title: $r('app.string.server_selfhosted'),
            selected: this.thirdParty,
            onSelect: (): void => {
              this.thirdParty = true;
            }
          })
        }
        .width('100%')
        .margin({ top: Spacing.xl })

        Blank().layoutWeight(1)

        Text($r('app.string.previous_step'))
          .fontSize(Typography.subhead.size)
          .lineHeight(Typography.subhead.lineHeight)
          .fontColor(this.theme.primary)
          .constraintSize({ minHeight: Sizes.touchMin })
          .onClick(() => this.onBack())

        AppButton({ label: $r('app.string.continue'), onTap: (): void => this.submit() })
          .margin({ top: Spacing.sm })
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
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.system_background'))
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    .alignItems(HorizontalAlign.Center)
  }
}
