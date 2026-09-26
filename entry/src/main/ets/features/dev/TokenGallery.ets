/*
 * SPDX-FileCopyrightText: 2026 Liugt
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import { Spacing, Radius, Typography, Sizes, TypeStyle } from '../../common/design/Tokens';
import { AppTheme, ThemeOption } from '../../common/design/AppTheme';
import { PageScaffold } from '../../common/design/PageScaffold';
import { AppButton } from '../../common/components/AppButton';
import { AppCard } from '../../common/components/AppCard';
import { AppListRow } from '../../common/components/AppListRow';
import { AppInput } from '../../common/components/AppInput';
import { ColorModePreference, ThemeService, ThemeState } from '../../application/theme/ThemeService';

interface ThemeModeItem {
  mode: ColorModePreference;
  label: Resource;
}

interface NeutralColorItem {
  /** Token 标识符（代码名，非用户文案） */
  name: string;
  color: Resource;
}

interface TypeSampleItem {
  /** Token 标识符（代码名，非用户文案） */
  name: string;
  style: TypeStyle;
}

/**
 * 样式基准页（票 01）：Token 与基础组件的可视化基准 + ThemeService 主题/深浅色切换演示。
 * 仅供预览器（@Preview）与开发验收，不进路由（main_pages.json 不注册）。
 */
@Preview
@ComponentV2
export struct TokenGallery {
  @Provider('ThemeState') themeState: ThemeState = ThemeService.get().state;
  private themeService: ThemeService = ThemeService.get();
  @Local private inputText: string = '';

  private themeModes: ThemeModeItem[] = [
    { mode: 'system', label: $r('app.string.mode_system') },
    { mode: 'light', label: $r('app.string.mode_light') },
    { mode: 'dark', label: $r('app.string.mode_dark') }
  ];

  private neutralColors: NeutralColorItem[] = [
    { name: 'label', color: $r('app.color.label') },
    { name: 'secondary_label', color: $r('app.color.secondary_label') },
    { name: 'tertiary_label', color: $r('app.color.tertiary_label') },
    { name: 'system_background', color: $r('app.color.system_background') },
    { name: 'secondary_system_background', color: $r('app.color.secondary_system_background') },
    { name: 'separator', color: $r('app.color.separator') },
    { name: 'danger', color: $r('app.color.danger') },
    { name: 'success', color: $r('app.color.success') }
  ];

  private themeLabel(theme: ThemeOption): Resource {
    switch (theme.id) {
      case 'waterlily':
        return $r('app.string.theme_waterlily');
      case 'cathedral':
        return $r('app.string.theme_cathedral');
      case 'rose':
        return $r('app.string.theme_rose');
      case 'haystack':
        return $r('app.string.theme_haystack');
      default:
        return $r('app.string.theme_default');
    }
  }

  private typeSamples: TypeSampleItem[] = [
    { name: 'largeTitle', style: Typography.largeTitle },
    { name: 'title1', style: Typography.title1 },
    { name: 'title2', style: Typography.title2 },
    { name: 'title3', style: Typography.title3 },
    { name: 'headline', style: Typography.headline },
    { name: 'body', style: Typography.body },
    { name: 'callout', style: Typography.callout },
    { name: 'subhead', style: Typography.subhead },
    { name: 'footnote', style: Typography.footnote },
    { name: 'caption1', style: Typography.caption1 },
    { name: 'caption2', style: Typography.caption2 }
  ];

  @Builder
  sectionTitle(title: ResourceStr) {
    Text(title)
      .fontSize(Typography.footnote.size)
      .lineHeight(Typography.footnote.lineHeight)
      .fontWeight(Typography.footnote.weight)
      .fontColor($r('app.color.secondary_label'))
  }

  build() {
    PageScaffold({ title: $r('app.string.gallery_title') }) {
      Column({ space: Spacing.xl }) {
        this.sectionTitle($r('app.string.settings_theme'))
        AppCard() {
          Column() {
            ForEach(AppTheme.all, (theme: ThemeOption, index: number) => {
              Column() {
                Row({ space: Spacing.md }) {
                  Column()
                    .width(Sizes.themeDot)
                    .height(Sizes.themeDot)
                    .borderRadius(Radius.pill(Sizes.themeDot))
                    .backgroundColor(this.themeState.isDark ? theme.dark : theme.light)
                  Text(this.themeLabel(theme))
                    .fontSize(Typography.body.size)
                    .lineHeight(Typography.body.lineHeight)
                    .fontColor($r('app.color.label'))
                    .layoutWeight(1)
                  if (this.themeState.themeId === theme.id) {
                    SymbolGlyph($r('sys.symbol.checkmark'))
                      .fontSize(Sizes.rowIcon)
                      .fontColor([this.themeState.primary])
                  }
                }
                .width('100%')
                .constraintSize({ minHeight: Sizes.touchMin })
                .onClick(() => {
                  this.themeService.setTheme(theme.id);
                })
                if (index < AppTheme.all.length - 1) {
                  Divider()
                    .color($r('app.color.separator'))
                    .strokeWidth(Sizes.hairline)
                }
              }
              .width('100%')
            }, (theme: ThemeOption) => theme.id)
          }
          .width('100%')
        }

        this.sectionTitle($r('app.string.settings_mode'))
        Row({ space: Spacing.sm }) {
          ForEach(this.themeModes, (item: ThemeModeItem) => {
            Row() {
              Text(item.label)
                .fontSize(Typography.subhead.size)
                .lineHeight(Typography.subhead.lineHeight)
                .fontColor(this.themeState.colorMode === item.mode
                  ? this.themeState.onPrimary : $r('app.color.label'))
                .height(Sizes.chip)
                .padding({ left: Spacing.md, right: Spacing.md })
                .borderRadius(Radius.pill(Sizes.chip))
                .backgroundColor(this.themeState.colorMode === item.mode
                  ? this.themeState.primary : $r('app.color.secondary_system_background'))
            }
            .constraintSize({ minHeight: Sizes.touchMin })
            .justifyContent(FlexAlign.Center)
            .onClick(() => {
              this.themeService.setColorMode(item.mode);
            })
          }, (item: ThemeModeItem) => item.mode)
        }
        .width('100%')

        this.sectionTitle($r('app.string.gallery_brand'))
        AppCard() {
          Column({ space: Spacing.sm }) {
            Row({ space: Spacing.md }) {
              Column()
                .width(Sizes.themeDot)
                .height(Sizes.themeDot)
                .borderRadius(Radius.pill(Sizes.themeDot))
                .backgroundColor(this.themeState.primary)
              Text('primary')
                .fontSize(Typography.body.size)
                .fontColor($r('app.color.label'))
                .layoutWeight(1)
              Text(this.themeState.primary)
                .fontSize(Typography.callout.size)
                .fontColor($r('app.color.secondary_label'))
            }
            .width('100%')

            Row({ space: Spacing.md }) {
              Column()
                .width(Sizes.themeDot)
                .height(Sizes.themeDot)
                .borderRadius(Radius.pill(Sizes.themeDot))
                .backgroundColor(this.themeState.onPrimary)
                .borderWidth(Sizes.hairline)
                .borderColor($r('app.color.separator'))
              Text('on_primary')
                .fontSize(Typography.body.size)
                .fontColor($r('app.color.label'))
                .layoutWeight(1)
              Text(this.themeState.onPrimary)
                .fontSize(Typography.callout.size)
                .fontColor($r('app.color.secondary_label'))
            }
            .width('100%')
          }
          .width('100%')
        }

        this.sectionTitle($r('app.string.gallery_neutral'))
        AppCard() {
          Column() {
            ForEach(this.neutralColors, (item: NeutralColorItem) => {
              Row({ space: Spacing.md }) {
                Column()
                  .width(Sizes.themeDot)
                  .height(Sizes.themeDot)
                  .borderRadius(Radius.pill(Sizes.themeDot))
                  .backgroundColor(item.color)
                  .borderWidth(Sizes.hairline)
                  .borderColor($r('app.color.separator'))
                Text(item.name)
                  .fontSize(Typography.body.size)
                  .fontColor($r('app.color.label'))
              }
              .width('100%')
              .constraintSize({ minHeight: Sizes.touchMin })
            }, (item: NeutralColorItem) => item.name)
          }
          .width('100%')
        }

        this.sectionTitle($r('app.string.gallery_typography'))
        AppCard() {
          Column({ space: Spacing.sm }) {
            ForEach(this.typeSamples, (sample: TypeSampleItem) => {
              Column({ space: Spacing.xs }) {
                Text(sample.name)
                  .fontSize(sample.style.size)
                  .lineHeight(sample.style.lineHeight)
                  .fontWeight(sample.style.weight)
                  .fontColor($r('app.color.label'))
                Text(`${sample.style.size}/${sample.style.lineHeight}`)
                  .fontSize(Typography.caption2.size)
                  .fontColor($r('app.color.tertiary_label'))
              }
              .width('100%')
              .alignItems(HorizontalAlign.Start)
            }, (sample: TypeSampleItem) => sample.name)
          }
          .width('100%')
        }

        this.sectionTitle($r('app.string.gallery_components'))
        Column({ space: Spacing.md }) {
          AppButton({ label: $r('app.string.gallery_button') })

          AppButton({
            label: $r('app.string.gallery_button'),
            isEnabled: false
          })

          AppCard() {
            Column({ space: Spacing.md }) {
              this.sectionTitle($r('app.string.gallery_input'))
              AppInput({
                placeholder: $r('app.string.gallery_input_hint'),
                text: this.inputText,
                onChange: (value: string) => {
                  this.inputText = value;
                }
              })
              if (this.inputText.length > 0) {
                Text(this.inputText)
                  .fontSize(Typography.footnote.size)
                  .fontColor($r('app.color.secondary_label'))
              }
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
          }

          AppCard() {
            Column() {
              AppListRow({
                title: $r('app.string.gallery_row'),
                value: $r('app.string.field_value'),
                showChevron: true
              })
              AppListRow({
                title: $r('app.string.gallery_card'),
                showDivider: false
              })
            }
            .width('100%')
          }

          AppCard() {
            Column() {
              AppListRow({
                title: $r('app.string.menu_delete'),
                danger: true,
                showDivider: false
              })
            }
            .width('100%')
          }
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .padding({ left: Spacing.page, right: Spacing.page })
    }
  }
}
