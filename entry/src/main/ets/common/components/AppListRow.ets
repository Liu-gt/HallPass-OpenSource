/*
 * SPDX-FileCopyrightText: 2026 Liugt
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import { Sizes, Spacing, GroupedList, Opacity } from '../design/Tokens';

/**
 * 通用列表行（spec §5.5 / F13）：最小高 Sizes.touchMin、左右内距 Spacing.lg、子间距 Spacing.md；
 * 值弹性右对齐单行省略；尾部箭头可选；分隔线 0.5vp（Sizes.hairline）/ separator；
 * 危险行文字 danger；按压态透明度 0.6。
 */
@ComponentV2
export struct AppListRow {
  @Param title: ResourceStr = '';
  @Param value: ResourceStr | undefined = undefined;
  @Param showChevron: boolean = false;
  @Param danger: boolean = false;
  @Param showDivider: boolean = true;
  @Event onTap: () => void = () => {
  };
  @Local private pressed: boolean = false;

  build() {
    Row({ space: Spacing.md }) {
      Text(this.title)
        .fontSize(GroupedList.primaryText.size)
        .lineHeight(GroupedList.primaryText.lineHeight)
        .fontWeight(GroupedList.primaryText.weight)
        .fontColor(this.danger ? $r('app.color.danger') : $r('app.color.label'))
        .flexShrink(0)

      if (this.value !== undefined) {
        Text(this.value)
          .fontSize(GroupedList.secondaryText.size)
          .lineHeight(GroupedList.secondaryText.lineHeight)
          .fontWeight(GroupedList.secondaryText.weight)
          .fontColor($r('app.color.secondary_label'))
          .layoutWeight(1)
          .textAlign(TextAlign.End)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }

      if (this.showChevron) {
        SymbolGlyph($r('sys.symbol.chevron_right'))
          .fontSize(GroupedList.chevronText.size)
          .fontWeight(FontWeight.Bold)
          .fontColor([$r('app.color.tertiary_label')])
          .flexShrink(0)
      }
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .constraintSize({ minHeight: GroupedList.rowMinHeight })
    .padding({
      left: GroupedList.rowHorizontal,
      right: GroupedList.rowHorizontal,
      top: GroupedList.rowVertical,
      bottom: GroupedList.rowVertical
    })
    .borderWidth({ bottom: Sizes.hairline })
    .borderColor(this.showDivider ? $r('app.color.separator') : Color.Transparent)
    .opacity(this.pressed ? Opacity.pressed : 1)
    .onTouch((event: TouchEvent) => {
      if (event.type === TouchType.Down) {
        this.pressed = true;
      } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
        this.pressed = false;
      }
    })
    .onClick(() => {
      this.onTap();
    })
  }
}
