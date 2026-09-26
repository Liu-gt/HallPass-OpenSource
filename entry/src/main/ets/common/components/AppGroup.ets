/*
 * SPDX-FileCopyrightText: 2026 Liugt
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import { AppCard } from './AppCard';
import { GroupedList, Radius, Shadows, Spacing } from '../design/Tokens';

/**
 * 分组表单容器：标题、组间距与卡片表面保持一致。
 * hintText 非空时标题后渲染感叹号按钮，点击弹气泡展示提示文案（如试验性功能说明）。
 */
@ComponentV2
export struct AppGroup {
  @Param title: ResourceStr = '';
  @Param first: boolean = false;
  @Param contentPadding: number = 0;
  /** 标题旁提示文案：null 不渲染提示入口。 */
  @Param hintText: ResourceStr | null = null;
  @BuilderParam content: () => void = this.empty;
  @Local private showHint: boolean = false;

  @Builder
  empty() {
  }

  /** 气泡文案：PopupOptions.message 仅接受 string，资源值转系统字符串。 */
  private hintMessage(): string {
    const hint: ResourceStr | null = this.hintText;
    if (hint === null) {
      return '';
    }
    return typeof hint === 'string' ? hint : getContext(this).resourceManager.getStringSync(hint);
  }

  private hintPopupOptions(): PopupOptions {
    const options: PopupOptions = {
      message: this.hintMessage(),
      placement: Placement.Bottom,
      popupColor: $r('app.color.secondary_system_background'),
      backgroundBlurStyle: BlurStyle.NONE,
      enableArrow: true,
      radius: Radius.lg,
      shadow: {
        radius: Shadows.card.radius,
        color: Shadows.card.color,
        offsetY: Shadows.card.offsetY
      },
      mask: false,
      autoCancel: true,
      messageOptions: {
        textColor: $r('app.color.label'),
        font: { size: GroupedList.secondaryText.size }
      },
      onStateChange: (event: PopupStateChangeParam): void => {
        if (!event.isVisible) {
          this.showHint = false;
        }
      }
    };
    return options;
  }

  build() {
    Column() {
      Row({ space: Spacing.xs }) {
        Text(this.title)
          .fontSize(GroupedList.headerText.size)
          .lineHeight(GroupedList.headerText.lineHeight)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.secondary_label'))
        if (this.hintText !== null) {
          SymbolGlyph($r('sys.symbol.exclamationmark_circle_fill'))
            .fontSize(GroupedList.headerText.size)
            .fontColor([$r('app.color.secondary_label')])
            .padding(Spacing.xs)
            .accessibilityText($r('app.string.a11y_hint'))
            .onClick(() => {
              this.showHint = !this.showHint;
            })
            .bindPopup(this.showHint, this.hintPopupOptions())
        }
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .padding({ left: GroupedList.headerInset })
      .margin({ bottom: GroupedList.headerGap })
      AppCard({ contentPadding: this.contentPadding }) {
        this.content()
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .margin({ top: this.first ? 0 : GroupedList.sectionGap })
  }
}
