/*
 * SPDX-FileCopyrightText: 2026 Liugt
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import { PageScaffold } from '../../common/design/PageScaffold';
import { ThemeService, ThemeState } from '../../application/theme/ThemeService';
import { BottomSpacer } from '../../common/design/BottomSpacer';
import { Spacing, Typography, Radius, Sizes } from '../../common/design/Tokens';
import { CipherView } from '../../application/state/VaultMemoryIndex';
import { ServiceLocator } from '../../application/ServiceLocator';
import { ConfirmDialogService } from '../../application/ConfirmDialogService';
import { formatTimestamp } from './ItemDetailViewModel';

/**
 * 回收站视图（票 20，spec F9）：数据源 = MemoryIndex 的 deleted 过滤投影
 * （其他客户端删除的条目同步后可见）；条目行禁用编辑；
 * 左滑「恢复 / 永久删除」，永久删除二次确认（Radius.xl、确认文字 danger）；
 * 恢复走 WriteService.restore（服务端恢复后条目回原文件夹并出现在常规列表）。
 */
@ComponentV2
export struct TrashBrowser {
  /** 品牌色响应源（T24：主题切换经 ThemeState 即时生效）。 */
  private theme: ThemeState = ThemeService.get().state;
  @Param onBack: () => void = (): void => {
  };
  @Local private items: CipherView[] = [];
  @Local private pendingForeverId: string | null = null;
  @Local private toastText: string | null = null;
  private indexListener: (() => void) | null = null;
  private toastTimer: number = -1;

  aboutToAppear(): void {
    this.refreshItems();
    this.indexListener = (): void => {
      this.refreshItems();
    };
    ServiceLocator.sync().indexState().addListener(this.indexListener);
  }

  aboutToDisappear(): void {
    if (this.indexListener !== null) {
      ServiceLocator.sync().indexState().removeListener(this.indexListener);
      this.indexListener = null;
    }
  }

  private refreshItems(): void {
    this.items = ServiceLocator.sync().indexState().entries.filter(
      (item: CipherView): boolean => item.deletedDate !== null);
  }

  private showToast(text: ResourceStr): void {
    // Resource 不能直接 toString（产物为 [object Object]）；字符串直用，$r 经资源管理器解析
    this.toastText = typeof text === 'string' ? text as string
      : getContext(this).resourceManager.getStringSync(text as Resource);
    if (this.toastTimer !== -1) {
      clearTimeout(this.toastTimer);
    }
    this.toastTimer = setTimeout((): void => {
      this.toastText = null;
      this.toastTimer = -1;
    }, 1800);
  }

  private async restore(id: string): Promise<void> {
    await ServiceLocator.write().restore(id);
    this.refreshItems();
  }

  private async deleteForever(id: string): Promise<void> {
    this.pendingForeverId = null;
    await ServiceLocator.write().hardDelete(id);
    this.refreshItems();
  }

  /** 永久删除二次确认：根级弹窗（覆盖页签栏与状态栏，选择前阻断交互）。 */
  private requestDeleteForever(id: string): void {
    this.pendingForeverId = id;
    ConfirmDialogService.get().show({
      title: $r('app.string.delete_forever'),
      body: $r('app.string.delete_forever_confirm'),
      cancelLabel: $r('app.string.cancel'),
      confirmLabel: $r('app.string.delete_forever'),
      onCancel: (): void => {
        this.pendingForeverId = null;
      },
      onConfirm: (): void => {
        const pendingId: string | null = this.pendingForeverId;
        if (pendingId !== null) {
          this.deleteForever(pendingId);
        }
      }
    });
  }

  @Builder
  emptyState() {
    Column({ space: Spacing.md }) {
      SymbolGlyph($r('sys.symbol.trash'))
        .fontSize(Sizes.emptyIcon)
        .fontColor([$r('app.color.secondary_label')])
      Text($r('app.string.trash_empty'))
        .fontSize(Typography.headline.size)
        .lineHeight(Typography.headline.lineHeight)
        .fontWeight(Typography.headline.weight)
        .fontColor($r('app.color.secondary_label'))
    }
    .width('100%')
    .padding({ top: Spacing.xxl * 3 })
  }

  @Builder
  trashRow(item: CipherView) {
    Row({ space: Spacing.md }) {
      Column({ space: 2 }) {
        Text(item.name)
          .fontSize(Typography.body.size)
          .lineHeight(Typography.body.lineHeight)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.secondary_label'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(formatTimestamp(item.deletedDate ?? 0))
          .fontSize(Typography.caption1.size)
          .lineHeight(Typography.caption1.lineHeight)
          .fontColor($r('app.color.tertiary_label'))
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
    }
    .width('100%')
    .constraintSize({ minHeight: Sizes.touchMin })
    .padding({ left: Spacing.lg, right: Spacing.lg, top: Spacing.sm, bottom: Spacing.sm })
    .borderRadius(Radius.lg)
    .backgroundColor($r('app.color.secondary_system_background'))
    // 禁用编辑：无点击进详情、无长按菜单（spec F9 边界情况）
  }

  @Builder
  trashSwipe(item: CipherView) {
    Row({ space: Spacing.sm }) {
      Column() {
        Text($r('app.string.restore'))
          .fontSize(Typography.footnote.size)
          .lineHeight(Typography.footnote.lineHeight)
          .fontColor(this.theme.onPrimary)
      }
      .width(Sizes.touchMin * 2)
      .height(Sizes.touchMin)
      .borderRadius(Radius.lg)
      .backgroundColor(this.theme.primary)
      .justifyContent(FlexAlign.Center)
      .onClick(() => {
        this.restore(item.id);
      })

      Column() {
        Text($r('app.string.delete_forever'))
          .fontSize(Typography.footnote.size)
          .lineHeight(Typography.footnote.lineHeight)
          .fontColor(this.theme.onPrimary)
      }
      .width(Sizes.touchMin * 2)
      .height(Sizes.touchMin)
      .borderRadius(Radius.lg)
      .backgroundColor($r('app.color.danger'))
      .justifyContent(FlexAlign.Center)
      .onClick(() => {
        this.requestDeleteForever(item.id);
      })
    }
    .padding({ right: Spacing.md })
  }

  build() {
    Stack() {
      Column() {
        Text($r('app.string.trash_title'))
          .fontSize(Typography.headline.size)
          .lineHeight(Typography.headline.lineHeight)
          .fontWeight(Typography.headline.weight)
          .fontColor($r('app.color.label'))
          .width('100%')
          .padding({ left: Spacing.page, right: Spacing.page, top: Spacing.lg })

        if (this.items.length === 0) {
          this.emptyState()
        } else {
          List() {
            ForEach(this.items, (item: CipherView) => {
              ListItem() {
                this.trashRow(item)
              }
                // 条目卡片内缩在 ListItem 上做（走查反馈）：行 width 100% + margin 会右侧超宽
                .padding({ left: Spacing.page, right: Spacing.page })
                .swipeAction({ end: this.trashSwipe(item) })
            }, (item: CipherView) => `${item.id}-${item.revisionDate}-${item.deletedDate ?? 0}`)
            ListItem() {
              BottomSpacer()
            }
          }
          .width('100%')
          .layoutWeight(1)
          .scrollBar(BarState.Off)
          .edgeEffect(EdgeEffect.Spring)
        }
      }
      .width('100%')
      .height('100%')

      if (this.toastText !== null) {
        Text(this.toastText)
          .fontSize(Typography.footnote.size)
          .lineHeight(Typography.footnote.lineHeight)
          .fontColor(this.theme.onPrimary)
          .padding({ left: Spacing.lg, right: Spacing.lg, top: Spacing.sm, bottom: Spacing.sm })
          .borderRadius(Radius.xs)
          .backgroundColor($r('app.color.secondary_label'))
          .margin({ bottom: Sizes.tabBar + Spacing.xl })
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.system_background'))
  }
}
