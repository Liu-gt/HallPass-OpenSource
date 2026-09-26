/*
 * SPDX-FileCopyrightText: 2026 Liugt
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import { Spacing, Typography, Radius, Sizes, Shadows, Opacity } from '../design/Tokens';
import { Motion } from '../design/Motion';
import { ThemeService, ThemeState } from '../../application/theme/ThemeService';
import { SponsorDialogService } from '../../features/settings/sponsor/SponsorDialogService';
import { SponsorState, SponsorDisplayTier, SPONSOR_TIERS } from '../../features/settings/sponsor/SponsorModel';
import { common } from '@kit.AbilityKit';

@ComponentV2
export struct SponsorDialog {
  private theme: ThemeState = ThemeService.get().state;
  private service: SponsorDialogService = SponsorDialogService.get();

  build() {
    Column() {
      // 核心卡片容器
      Column() {
        // 1. 顶部 Header
        Row() {
          Column({ space: Spacing.xs }) {
            Text($r('app.string.sponsor_dialog_title'))
              .fontSize(Typography.title3.size)
              .lineHeight(Typography.title3.lineHeight)
              .fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.label'))

            Text($r('app.string.sponsor_dialog_subtitle'))
              .fontSize(Typography.footnote.size)
              .lineHeight(Typography.footnote.lineHeight)
              .fontColor($r('app.color.secondary_label'))
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)

          // 关闭按键
          Button({ type: ButtonType.Circle }) {
            SymbolGlyph($r('sys.symbol.xmark'))
              .fontSize(16)
              .fontColor([$r('app.color.secondary_label')])
          }
          .width(32)
          .height(32)
          .backgroundColor($r('app.color.tertiary_system_background'))
          .margin({ left: Spacing.sm })
          .enabled(this.service.sponsorState !== SponsorState.PURCHASING && this.service.sponsorState !== SponsorState.DELIVERING)
          .onClick(() => this.service.handleBack())
        }
        .width('100%')
        .padding({ bottom: Spacing.md })

        // 2. 主体状态机交互区
        if (this.service.sponsorState === SponsorState.LOADING) {
          Column({ space: Spacing.md }) {
            LoadingProgress()
              .width(40)
              .height(40)
              .color(this.theme.primary)
            Text($r('app.string.sponsor_loading'))
              .fontSize(Typography.subhead.size)
              .fontColor($r('app.color.secondary_label'))
          }
          .width('100%')
          .height(220)
          .justifyContent(FlexAlign.Center)

        } else if (this.service.sponsorState === SponsorState.UNSUPPORTED) {
          Column({ space: Spacing.md }) {
            SymbolGlyph($r('sys.symbol.exclamationmark_circle'))
              .fontSize(44)
              .fontColor([$r('app.color.secondary_label')])
            Text($r('app.string.sponsor_unsupported_region'))
              .fontSize(Typography.subhead.size)
              .fontColor($r('app.color.secondary_label'))
          }
          .width('100%')
          .height(220)
          .justifyContent(FlexAlign.Center)

        } else if (this.service.sponsorState === SponsorState.SUCCESS) {
          Column({ space: Spacing.md }) {
            SymbolGlyph($r('sys.symbol.heart_fill'))
              .fontSize(56)
              .fontColor([$r('app.color.system_orange')])
            Text($r('app.string.sponsor_success_title'))
              .fontSize(Typography.title3.size)
              .fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.label'))
            Text($r('app.string.sponsor_success_desc'))
              .fontSize(Typography.subhead.size)
              .fontColor($r('app.color.secondary_label'))

            Button($r('app.string.sponsor_confirm_btn'))
              .type(ButtonType.Normal)
              .width('80%')
              .height(Sizes.control)
              .borderRadius(Radius.pill(Sizes.control))
              .backgroundColor(this.theme.primary)
              .fontColor(this.theme.onPrimary)
              .margin({ top: Spacing.lg })
              .onClick(() => this.service.dismiss())
          }
          .width('100%')
          .height(240)
          .justifyContent(FlexAlign.Center)

        } else {
          // 3 栏网格档位卡片
          GridRow({ columns: 3, gutter: { x: Spacing.sm, y: Spacing.sm } }) {
            ForEach(this.service.sponsorTiers, (tier: SponsorDisplayTier) => {
              GridCol({ span: 1 }) {
                SponsorTierCard({ tier: tier })
              }
            }, (tier: SponsorDisplayTier) => `${tier.config.id}_${this.service.selectedTierId === tier.config.id}`)
          }
          .width('100%')

          // 错误提示 Banner（如果有）
          if (this.service.errorMessage) {
            Text(this.service.errorMessage)
              .fontSize(Typography.caption1.size)
              .lineHeight(Typography.caption1.lineHeight)
              .fontColor($r('app.color.danger'))
              .textAlign(TextAlign.Center)
              .width('100%')
              .margin({ top: Spacing.sm })
          }

          // 赞助操作主按钮
          Button({ type: ButtonType.Normal }) {
            Row({ space: Spacing.sm }) {
              if (this.service.sponsorState === SponsorState.PURCHASING ||
                  this.service.sponsorState === SponsorState.DELIVERING) {
                LoadingProgress().width(18).height(18).color(this.theme.onPrimary)
              }
              Text(this.actionButtonText())
                .fontSize(Typography.headline.size)
                .fontWeight(FontWeight.Medium)
                .fontColor(this.theme.onPrimary)
            }
          }
          .width('100%')
          .height(Sizes.control)
          .borderRadius(Radius.pill(Sizes.control))
          .backgroundColor(this.theme.primary)
          .margin({ top: Spacing.lg })
          .enabled(this.service.sponsorState === SponsorState.READY)
          .opacity(this.service.sponsorState === SponsorState.READY ? 1.0 : Opacity.disabled)
          .onClick(() => {
            const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
            this.service.executeSponsor(ctx);
          })
        }
      }
      .padding(Spacing.xl)
      .borderRadius(Radius.xl)
      .backgroundColor($r('app.color.secondary_system_background'))
      .shadow({
        radius: Shadows.dialog.radius,
        color: Shadows.dialog.color,
        offsetY: Shadows.dialog.offsetY
      })
      .margin({ left: Spacing.lg, right: Spacing.lg })
      .constraintSize({ maxWidth: 440 })
      .onClick(() => {
        // 拦截点击，防止冒泡到 scrim 触发意外收起
      })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .backgroundColor($r('app.color.scrim'))
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    .onClick(() => {
      this.service.handleBack();
    })
    .transition(TransitionEffect.opacity(0)
      .animation({ duration: Motion.durationDialog, curve: Motion.curve })
      .combine(TransitionEffect.scale({ x: 1.15, y: 1.15 })
        .animation({ duration: Motion.durationDialog, curve: Motion.curve })))
  }



  private actionButtonText(): string {
    const selected = this.service.sponsorTiers.find((t: SponsorDisplayTier) => t.config.id === this.service.selectedTierId);
    const price = selected?.priceText ?? '';
    const resMgr = this.getUIContext().getHostContext()?.resourceManager;
    if (this.service.sponsorState === SponsorState.PURCHASING) {
      try {
        return resMgr?.getStringSync($r('app.string.sponsor_btn_purchasing')) ?? '正在调起支付...';
      } catch (_e) {
        return '正在调起支付...';
      }
    } else if (this.service.sponsorState === SponsorState.DELIVERING) {
      try {
        return resMgr?.getStringSync($r('app.string.sponsor_btn_delivering')) ?? '正在确认发货...';
      } catch (_e) {
        return '正在确认发货...';
      }
    }
    try {
      return resMgr?.getStringSync($r('app.string.sponsor_btn_action'), price) ?? `赞助 ${price}`;
    } catch (_e) {
      return `赞助 ${price}`;
    }
  }
}

/** 单个档位卡片（独立 ComponentV2 精准订阅 selectedTierId 响应式更新） */
@ComponentV2
struct SponsorTierCard {
  private theme: ThemeState = ThemeService.get().state;
  private service: SponsorDialogService = SponsorDialogService.get();
  @Param @Require tier: SponsorDisplayTier = {
    config: SPONSOR_TIERS[0],
    priceText: '¥1.00',
    name: '',
    isValid: true
  };

  build() {
    Column({ space: Spacing.xs }) {
      SymbolGlyph(this.tier.config.symbolIcon)
        .fontSize(26)
        .fontColor([this.service.selectedTierId === this.tier.config.id ? this.theme.primary : $r('app.color.secondary_label')])

      Text(this.tier.config.title)
        .fontSize(Typography.subhead.size)
        .lineHeight(Typography.subhead.lineHeight)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.label'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })

      Text(this.tier.priceText)
        .fontSize(Typography.headline.size)
        .lineHeight(Typography.headline.lineHeight)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.service.selectedTierId === this.tier.config.id ? this.theme.primary : $r('app.color.label'))

      Text(this.tier.config.subtitle)
        .fontSize(Typography.caption2.size)
        .lineHeight(Typography.caption2.lineHeight)
        .fontColor($r('app.color.secondary_label'))
        .maxLines(2)
        .height(Typography.caption2.lineHeight * 2)
        .textAlign(TextAlign.Center)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
    .height(132)
    .justifyContent(FlexAlign.Center)
    .padding({ top: Spacing.sm, bottom: Spacing.sm, left: Spacing.xs, right: Spacing.xs })
    .borderRadius(Radius.md)
    .backgroundColor(this.service.selectedTierId === this.tier.config.id ?
      $r('app.color.secondary_system_background') : $r('app.color.tertiary_system_background'))
    .border({
      width: this.service.selectedTierId === this.tier.config.id ? 1.5 : Sizes.hairline,
      color: this.service.selectedTierId === this.tier.config.id ? this.theme.primary : $r('app.color.separator')
    })
    .opacity(this.tier.isValid ? 1.0 : Opacity.disabled)
    .alignItems(HorizontalAlign.Center)
    .onClick(() => {
      this.service.selectedTierId = this.tier.config.id;
      if (this.service.sponsorState === SponsorState.ERROR) {
        this.service.sponsorState = SponsorState.READY;
      }
      this.service.errorMessage = '';
    })
  }
}
