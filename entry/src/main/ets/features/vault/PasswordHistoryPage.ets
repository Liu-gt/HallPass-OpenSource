/*
 * SPDX-FileCopyrightText: 2026 Liugt
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import { ThemeService, ThemeState } from '../../application/theme/ThemeService';
import { Spacing, Typography, Sizes, GroupedList } from '../../common/design/Tokens';
import { ItemDetailViewModel } from './ItemDetailViewModel';
import { HistoryItemView } from '../../application/state/VaultMemoryIndex';
import { AppCard } from '../../common/components/AppCard';
import { ServiceLocator } from '../../application/ServiceLocator';
import { SystemBar } from '../../common/design/SystemBar';
import { i18n } from '@kit.LocalizationKit';

/** 历史行日期：英文 MM/DD/YY，中文 YY-MM-DD。 */
function formatHistoryDate(epochMs: number): string {
  if (epochMs <= 0) {
    return '';
  }
  const d: Date = new Date(epochMs);
  const pad = (n: number): string => (n < 10 ? `0${n}` : `${n}`);
  const lang: string = i18n.System.getAppPreferredLanguage().toLowerCase();
  if (lang.startsWith('zh')) {
    return `${d.getFullYear() % 100}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;
  }
  return `${pad(d.getMonth() + 1)}/${pad(d.getDate())}/${d.getFullYear() % 100}`;
}

/**
 * 历史行：左侧更改时间，右侧明文密码；点击弹"复制密码"菜单。
 */
@ComponentV2
struct HistoryRow {
  @Param item: HistoryItemView = new HistoryItemView('', 0);

  build() {
    Row({ space: Spacing.md }) {
      Text(formatHistoryDate(this.item.lastModifiedDate))
        .fontSize(GroupedList.secondaryText.size)
        .lineHeight(GroupedList.secondaryText.lineHeight)
        .fontColor($r('app.color.label'))
        .flexShrink(0)
      Blank()
      Text(this.item.password)
        .fontSize(GroupedList.secondaryText.size)
        .lineHeight(GroupedList.secondaryText.lineHeight)
        .fontColor($r('app.color.tertiary_label'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .bindMenu([{
          value: $r('app.string.swipe_copy_password'),
          action: (): void => {
            ServiceLocator.clipboard().copy(this.item.password);
          }
        }])
    }
    .width('100%')
    .constraintSize({ minHeight: GroupedList.rowMinHeight })
    .padding({ left: GroupedList.rowHorizontal, right: GroupedList.rowHorizontal,
      top: GroupedList.rowVertical, bottom: GroupedList.rowVertical })
  }
}

/** 密码历史路由参数：只传条目 ID 与返回标题，数据经 ViewModel 从会话态取。 */
export interface PasswordHistoryParam {
  cipherId: string;
  backTitle: string;
}

/**
 * 密码历史页（T27，spec F7）：与 ItemEditPage 同构的路由页（NavDestination）——
 * 返回栏 + 大标题栏，正文为单一卡片容器内分割线分隔的行；时间倒序，
 * 每行左侧更改时间、右侧明文密码，点击弹"复制密码"菜单。
 */
@ComponentV2
export struct PasswordHistoryPage {
  private theme: ThemeState = ThemeService.get().state;
  @Consumer('navStack') navStack: NavPathStack = new NavPathStack();
  @Local private viewModel: ItemDetailViewModel = new ItemDetailViewModel();
  @Local private cipherId: string = '';
  @Local private backTitle: string = '';

  private setStatusBarContentColor(): void {
    SystemBar.apply(this.theme.isDark);
  }

  private onReady(param: object): void {
    const record: Record<string, Object> = param as Record<string, Object>;
    const id: Object | undefined = record['cipherId'];
    const backTitle: Object | undefined = record['backTitle'];
    if (typeof id === 'string') {
      this.cipherId = id as string;
      this.backTitle = typeof backTitle === 'string' ? backTitle as string : '';
      this.viewModel.init(this.cipherId);
    }
  }

  aboutToDisappear(): void {
    this.viewModel.onDisappear();
  }

  /** 与详情页同款固定头部：返回行 + 大标题（无右侧操作按钮）。 */
  @Builder
  historyTitleBar() {
    Column() {
      Row({ space: Spacing.xs }) {
        Row({ space: Spacing.xs }) {
          SymbolGlyph($r('sys.symbol.chevron_left'))
            .fontSize(Sizes.rowIcon)
            .fontColor([this.theme.primary])
          Text(this.backTitle)
            .fontSize(Typography.subhead.size)
            .lineHeight(Typography.subhead.lineHeight)
            .fontColor(this.theme.primary)
        }
        .layoutWeight(1)
        .constraintSize({ minHeight: Sizes.touchMin })
        .onClick(() => {
          this.navStack.pop();
        })
      }
      .constraintSize({ minHeight: Sizes.touchMin })
      .padding({ left: Spacing.page, right: Spacing.page })

      Column() {
        Text($r('app.string.detail_history'))
          .fontSize(Typography.largeTitle.size)
          .lineHeight(Typography.largeTitle.lineHeight)
          .fontWeight(Typography.largeTitle.weight)
          .fontColor($r('app.color.label'))
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .padding({ left: Spacing.page, right: Spacing.page })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ top: 0, bottom: 20 })
    .backgroundColor($r('app.color.system_background'))
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP])
  }

  /** 与设置页一致的组内信息项分割线。 */
  @Builder
  rowDivider() {
    Divider()
      .color($r('app.color.separator'))
      .strokeWidth(1)
      .opacity(0.5)
      .margin({ left: Spacing.md, right: Spacing.md })
  }

  build() {
    NavDestination() {
      Column() {
        this.historyTitleBar()
        Scroll() {
          Column() {
            AppCard({ contentPadding: 0 }) {
              ForEach(this.viewModel.historySorted(), (item: HistoryItemView, index: number) => {
                if (index > 0) {
                  this.rowDivider()
                }
                HistoryRow({ item: item })
              }, (_item: HistoryItemView, index: number) => `${this.viewModel.renderEpoch}-${index}`)
            }
          }
          .width('100%')
          .padding({ left: Spacing.page, right: Spacing.page, bottom: Spacing.xxl * 2 })
        }
        .layoutWeight(1)
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
        .align(Alignment.Top)
      }
      .width('100%')
      .height('100%')
      .backgroundColor($r('app.color.system_background'))
    }
    .hideTitleBar(true)
    .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.BOTTOM])
    .onReady((context: NavDestinationContext): void => {
      this.onReady(context.pathInfo.param as object);
    })
    .onShown(() => {
      this.setStatusBarContentColor();
      if (this.cipherId.length > 0) {
        this.viewModel.init(this.cipherId);
      }
    })
    .onHidden(() => {
      this.viewModel.onDisappear();
    })
  }
}
