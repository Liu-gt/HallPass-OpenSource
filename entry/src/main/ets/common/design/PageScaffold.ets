/*
 * SPDX-FileCopyrightText: 2026 Liugt
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import { Spacing, Typography, Sizes } from './Tokens';
import { Motion } from './Motion';
import { SafeArea } from './SafeArea';
import { BottomSpacer } from './BottomSpacer';

/**
 * 页面骨架：大标题（28fp Bold）随滚动收缩为顶部紧凑标题（17fp Semibold）。
 * 约束见 docs/ui-design-tokens.md 第 7 节"标题栏"。
 * V2 定版（plan D9）：滚动态 @Local；@BuilderParam 体系保留（D9 明确豁免）。
 * 沉浸式：仅由实际顶部栏向上扩展至状态栏，避免根容器扩展后再以 safeTop
 * 撑开标题，从而产生额外空白。
 */
@ComponentV2
export struct PageScaffold {
  @Param title: ResourceStr = '';
  /** 标题最大显示宽度；超出时单行省略。 */
  @Param titleMaxWidth: string = '100%';
  /** 大标题是否自行避让状态栏（嵌套在已避让容器内时置 false，避免双重内边距）。 */
  @Param avoidTop: boolean = true;
  @BuilderParam content: () => void = this.empty;
  @Local private scrolled: boolean = false;
  @Local private safeTop: number = 0;

  aboutToAppear(): void {
    this.safeTop = SafeArea.top();
  }
  @Builder
  empty() {
  }

  build() {
    Stack({ alignContent: Alignment.Top }) {
      Scroll() {
        Column() {
          Column() {
            Text(this.title)
              .fontSize(Typography.largeTitle.size)
              .lineHeight(Typography.largeTitle.lineHeight)
              .fontWeight(Typography.largeTitle.weight)
              .fontColor($r('app.color.label'))
              .width(this.titleMaxWidth)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .padding({
                // 顶部栏自身向状态栏扩展；内容仍从状态栏下方的统一标题基线开始。
                top: this.avoidTop ? this.safeTop + Spacing.sm : Spacing.sm,
                bottom: Spacing.md
              })
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
          .padding({ left: Spacing.page, right: Spacing.page })
          .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP])
          this.content()
          BottomSpacer()
        }
        .alignItems(HorizontalAlign.Start)
        .width('100%')
      }
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)
      .width('100%')
      .height('100%')
      .onScroll((xOffset: number, yOffset: number) => {
        this.scrolled = yOffset > Spacing.md;
      })

      Row() {
        Text(this.title)
          .fontSize(Typography.headline.size)
          .lineHeight(Typography.headline.lineHeight)
          .fontWeight(Typography.headline.weight)
          .fontColor($r('app.color.label'))
          .width(this.titleMaxWidth)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .justifyContent(FlexAlign.Center)
      .width('100%')
      .height(Sizes.navBar)
      .backgroundColor($r('app.color.system_background'))
      .borderWidth({ bottom: Sizes.hairline })
      .borderColor($r('app.color.separator'))
      .opacity(this.scrolled ? 1 : 0)
      .animation({ duration: Motion.durationQuick, curve: Motion.curve })
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP])
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.system_background'))
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])
  }
}
