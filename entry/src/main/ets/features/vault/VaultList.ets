/*
 * SPDX-FileCopyrightText: 2026 Liugt
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import { CipherView } from '../../application/state/VaultMemoryIndex';
import { ThemeService, ThemeState } from '../../application/theme/ThemeService';
import { VaultViewModel, LetterGroup, TotpBadge } from './VaultViewModel';
import { BottomSpacer } from '../../common/design/BottomSpacer';
import { Spacing, Typography, Radius, Sizes, Shadows } from '../../common/design/Tokens';
import { Motion } from '../../common/design/Motion';
import { GlassBandModel } from '../tabs/GlassBandModel';

/**
 * 保管库分组列表（票 17，spec F6）：字母分组 + 索引条 + 双行条目行 +
 * 左滑三动作（复制密码/复制用户名/收藏）+ 长按菜单（编辑/移动文件夹/复制验证码/删除 danger）+
 * TOTP 实时徽标（ClockService tick）+ BottomSpacer 尾部避让（禁用视口 padding）。
 * 回调经 @Param 注入（VaultPage 接线：路由/WriteService/ClipboardService）。
 */
@ComponentV2
export struct VaultList {
  @Consumer('isMirrorContext') isMirrorContext: boolean = false;
  /** 品牌色响应源（T24：主题切换经 ThemeState 即时生效）。 */
  private theme: ThemeState = ThemeService.get().state;
  @Param viewModel: VaultViewModel = new VaultViewModel();
  /** 玻璃条带镜像：主树上报绝对滚动偏移，镜像树按它 scrollTo（见 GlassBandModel）。 */
  @Param band: GlassBandModel = new GlassBandModel();
  /** 镜像树标记：只渲染、滚动被动跟随（主树照常上报）。 */
  @Param passive: boolean = false;
  /**
   * 是否以列表框作为镜像视口上报（页签页：列表即页面主体）。子页面列表上方还有固定头部，
   * 视口必须是整个页面盒 —— 由页面自己上报，这里传 false。
   */
  @Param reportsViewport: boolean = true;
  @Param onOpenDetail: (cipherId: string) => void = (_id: string): void => {
  };
  @Param onEditItem: (cipherId: string) => void = (_id: string): void => {
  };
  @Param onMoveItem: (cipherId: string) => void = (_id: string): void => {
  };
  @Param onDeleteItem: (cipherId: string) => void = (_id: string): void => {
  };
  @Param onToggleFavorite: (item: CipherView) => void = (_item: CipherView): void => {
  };
  @Param onCopy: (text: string) => void = (_text: string): void => {
  };
  /** 二级页面样式（走查反馈）：条目名加粗、名称与副文本间距收窄。 */
  @Param titleBold: boolean = false;
  @Param rowTextGap: number = Spacing.xs;
  /** 复制密码（T27：成功后更新本地 last_used，"最近使用"排序依据；复制用户名/TOTP 不计）。 */
  @Param onCopyPassword: (item: CipherView) => void = (_item: CipherView): void => {
  };
  private scroller: Scroller = new Scroller();

  aboutToAppear(): void {
    if (!this.passive && !this.isMirrorContext) {
      return;
    }
    // 镜像树挂载首帧跟上主树当前偏移（滚动中进场时不是 0）
    setTimeout((): void => {
      this.applyBandOffset(true);
    }, 0);
  }

  /**
   * 镜像树：把列表滚动位置对齐到主树（无动画跳转）；夹不掉的回弹由 GlassTabMirror 平移补齐。
   * 滚动跟走量化（见 `mirrorNeedsReposition`），挂载 / 重新可见时 `force` 无条件对一次。
   */
  private applyBandOffset(force: boolean = false): void {
    if (!this.passive || this.viewModel.visibleCount === 0) {
      return;
    }
    if (!force && !this.band.mirrorNeedsReposition(this.band.offsetY)) {
      return;
    }
    this.scroller.scrollTo({ xOffset: 0, yOffset: this.band.offsetY, animation: false });
  }

  /** 镜像树：上报自己实际落到的偏移（被内容范围夹取后的值）。 */
  private reportMirrorOffset(): void {
    if (!this.passive || this.viewModel.visibleCount === 0) {
      return;
    }
    this.band.setApplied(this.scroller.currentOffset().yOffset);
  }

  /** 主树滚动 → 上报视觉偏移（镜像树的滚动同步源）。镜像树的程序化滚动不回报。 */
  private reportBandOffset(delta: number): void {
    if (this.passive) {
      return;
    }
    this.band.report(delta, this.scroller.currentOffset().yOffset);
  }

  @Monitor('band.offsetY')
  private onBandOffsetChange(): void {
    this.applyBandOffset();
  }

  /** 滚动停下后的精确对齐请求（见 GlassBandModel.requestAlign；只有镜像侧会真的滚）。 */
  @Monitor('band.alignEpoch')
  private onAlignRequest(): void {
    this.applyBandOffset(true);
  }

  private avatarText(item: CipherView): string {
    return item.name.trim().length === 0 ? '?' : item.name.trim().charAt(0).toUpperCase();
  }

  /** ForEach key 必须随数据指纹变化：upsert 用新 CipherView 实例整体替换，
   *  key 若只含 id，ForEach 复用旧组件树（builder 不重执行），左滑动作闭包捕获旧视图。 */
  private itemKey(item: CipherView): string {
    return `${item.id}-${this.viewModel.generation}`;
  }

  private groupKey(group: LetterGroup): string {
    const parts: string[] = [group.letter];
    for (let i = 0; i < group.items.length; i++) {
      parts.push(this.itemKey(group.items[i]));
    }
    return parts.join('|');
  }

  @Builder
  emptyState() {
    Column({ space: Spacing.md }) {
      SymbolGlyph($r('sys.symbol.archivebox'))
        .fontSize(Sizes.emptyIcon)
        .fontColor([$r('app.color.secondary_label')])
      Text($r('app.string.empty_title'))
        .fontSize(Typography.headline.size)
        .lineHeight(Typography.headline.lineHeight)
        .fontWeight(Typography.headline.weight)
        .fontColor($r('app.color.secondary_label'))
      Text($r('app.string.empty_hint'))
        .fontSize(Typography.footnote.size)
        .lineHeight(Typography.footnote.lineHeight)
        .fontColor($r('app.color.tertiary_label'))
    }
    .width('100%')
    .padding({ top: Spacing.xxl * 3 })
  }

  @Builder
  itemRow(item: CipherView, isGroupStart: boolean, isGroupEnd: boolean) {
    Column() {
      Row({ space: Spacing.md }) {
        Column() {
          Text(this.avatarText(item))
            .fontSize(Typography.title2.size)
            .lineHeight(Typography.title2.lineHeight)
            .fontWeight(Typography.headline.weight)
            .fontColor($r('app.color.on_tint'))
        }
        .width(Sizes.listAvatar)
        .height(Sizes.listAvatar)
        .borderRadius(Radius.sm)
        .backgroundColor($r('app.color.avatar_fill'))
        .justifyContent(FlexAlign.Center)

        Column({ space: this.rowTextGap }) {
          Text(item.name)
            .fontSize(Typography.body.size)
            .lineHeight(Typography.body.lineHeight)
            .fontWeight(this.titleBold ? FontWeight.Medium : FontWeight.Normal)
            .fontColor($r('app.color.label'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          if (item.username.length > 0) {
            Text(item.username)
              .fontSize(Typography.subhead.size)
              .lineHeight(Typography.subhead.lineHeight)
              .fontColor($r('app.color.secondary_label'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        if (this.viewModel.badgeFor(item.id) !== null) {
          Column({ space: Spacing.xs }) {
            Text(this.viewModel.badgeFor(item.id)?.code ?? '')
              .fontSize(Typography.headline.size)
              .lineHeight(Typography.headline.lineHeight)
              .fontWeight(Typography.headline.weight)
              .fontColor(this.theme.primary)
            Progress({ value: this.viewModel.badgeFor(item.id)?.remaining ?? 0, total: 30,
              type: ProgressType.Ring })
              .width(Sizes.totpRing)
              .height(Sizes.totpRing)
              .style({ strokeWidth: 2 })
              .color(this.theme.primary)
              .animation({ duration: Motion.durationTotp, curve: Motion.curveLinear })
          }
          .alignItems(HorizontalAlign.End)
          .onClick(() => {
            const badge: TotpBadge | null = this.viewModel.badgeFor(item.id);
            if (badge !== null) {
              this.onCopy(badge.code);
            }
          })
          // 环宽 20，热区横向外扩至 44（T25）
          .responseRegion({ x: -12, y: 0, width: Sizes.touchMin, height: '100%' })
          .accessibilityText($r('app.string.a11y_copy_code'))
        }

        if (item.favorite) {
          SymbolGlyph($r('sys.symbol.star_fill'))
            .fontSize(Sizes.rowIcon)
            .fontColor([this.theme.primary])
        }
        SymbolGlyph($r('sys.symbol.chevron_right'))
          .fontSize(Typography.title3.size)
          .fontWeight(FontWeight.Bold)
          .fontColor([$r('app.color.tertiary_label')])
      }
      .width('100%')
      .constraintSize({ minHeight: Sizes.touchMin })
      .padding({ top: Spacing.sm, bottom: Spacing.sm })
      .onClick(() => {
        this.onOpenDetail(item.id);
      })

      Divider()
        .color($r('app.color.separator'))
        .strokeWidth(1)
        .opacity(0.5)
        .margin({ left: Sizes.listAvatar + Spacing.md })
    }
    .bindContextMenu(this.itemMenu(item), ResponseType.LongPress)
  }

  @Builder
  menuRow(label: ResourceStr, danger: boolean, onTap: () => void) {
    Text(label)
      .fontSize(Typography.body.size)
      .lineHeight(Typography.body.lineHeight)
      .fontColor(danger ? $r('app.color.danger') : $r('app.color.label'))
      .width(Sizes.touchMin * 5)
      .constraintSize({ minHeight: Sizes.touchMin })
      .padding({ left: Spacing.lg, right: Spacing.lg })
      .textAlign(TextAlign.Center)
      .onClick(() => onTap())
  }

  @Builder
  itemMenu(item: CipherView) {
    Column() {
      this.menuRow($r('app.string.menu_edit'), false, (): void => this.onEditItem(item.id))
      this.menuRow($r('app.string.menu_move'), false, (): void => this.onMoveItem(item.id))
      if (item.totpSecret.length > 0) {
        this.menuRow($r('app.string.menu_copy_totp'), false, (): void => {
          const badge: TotpBadge | null = this.viewModel.badgeFor(item.id);
          if (badge !== null) {
            this.onCopy(badge.code);
          }
        })
      }
      this.menuRow($r('app.string.menu_delete'), true, (): void => this.onDeleteItem(item.id))
    }
    .borderRadius(Radius.lg)
    .backgroundColor($r('app.color.secondary_system_background'))
    .shadow({
      radius: Shadows.floating.radius,
      color: Shadows.floating.color,
      offsetY: Shadows.floating.offsetY
    })
  }

  @Builder
  swipeActions(item: CipherView) {
    Row({ space: Spacing.sm }) {
      Column() {
        SymbolGlyph($r('sys.symbol.doc_text'))
          .fontSize(Sizes.rowIcon)
          .fontColor([this.theme.onPrimary])
      }
      .width(Sizes.touchMin)
      .height(Sizes.touchMin)
      .borderRadius(Radius.pill(Sizes.touchMin))
      .backgroundColor(this.theme.primary)
      .justifyContent(FlexAlign.Center)
      .onClick(() => {
        this.onCopyPassword(item);
      })
      .accessibilityText($r('app.string.a11y_copy_password'))

      Column() {
        SymbolGlyph($r('sys.symbol.person_square_fill'))
          .fontSize(Sizes.rowIcon)
          .fontColor([this.theme.onPrimary])
      }
      .width(Sizes.touchMin)
      .height(Sizes.touchMin)
      .borderRadius(Radius.pill(Sizes.touchMin))
      .backgroundColor($r('app.color.secondary_label'))
      .justifyContent(FlexAlign.Center)
      .onClick(() => {
        this.onCopy(item.username);
      })
      .accessibilityText($r('app.string.a11y_copy_username'))

      Column() {
        SymbolGlyph($r('sys.symbol.star'))
          .fontSize(Sizes.rowIcon)
          .fontColor([this.theme.onPrimary])
      }
      .width(Sizes.touchMin)
      .height(Sizes.touchMin)
      .borderRadius(Radius.pill(Sizes.touchMin))
      .backgroundColor($r('app.color.secondary_label'))
      .justifyContent(FlexAlign.Center)
      .onClick(() => {
        this.onToggleFavorite(item);
      })
      .accessibilityText($r('app.string.a11y_favorite'))
    }
    .padding({ right: Spacing.md })
  }

  build() {
    if (this.viewModel.visibleCount === 0) {
      Column() {
        this.emptyState()
      }
      .width('100%')
      .height('100%')
    } else {
      Stack() {
        List({ scroller: this.scroller, space: 0 }) {
          ForEach(this.viewModel.groups, (group: LetterGroup, groupIndex: number) => {
            ListItem() {
              Column() {
                Text(group.letter)
                  .fontSize(Typography.footnote.size)
                  .lineHeight(Typography.footnote.lineHeight)
                  .fontWeight(Typography.headline.weight)
                  .fontColor($r('app.color.secondary_label'))
                  .width('100%')
                  .margin({ top: groupIndex === 0 ? 0 : Spacing.md + 20 })
                Divider()
                  .color($r('app.color.separator'))
                  .strokeWidth(1)
                  .opacity(0.5)
                  .margin({ left: Sizes.listAvatar + Spacing.md })
              }
            }
              .padding({ left: Spacing.page, right: Spacing.page })
            ForEach(group.items, (item: CipherView, itemIndex: number) => {
              ListItem() {
                this.itemRow(item, itemIndex === 0, itemIndex === group.items.length - 1)
              }
                // 条目卡片内缩在 ListItem 上做（走查反馈）：行 width 100% + margin 会右侧超宽；
                // ListItem 外沿不变，左滑动作区仍在屏幕外、滚到底部从悬浮页签下方穿过
                .padding({ left: Spacing.page, right: Spacing.page })
                .swipeAction({ end: this.swipeActions(item) })
            }, (item: CipherView) => this.itemKey(item))
          }, (group: LetterGroup) => this.groupKey(group))
          ListItem() {
            BottomSpacer()
          }
        }
        .width('100%')
        .height('100%')
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
        // 滚动位移上报：玻璃条带镜像据此同帧跟随（主树上报视觉偏移 + 边界增量；镜像树只回自己的落点）
        .onDidScroll((scrollOffset: number, scrollState: ScrollState) => {
          this.reportBandOffset(scrollOffset);
          this.reportMirrorOffset();
          // 停下时请求一次精确对齐：滚动中量化留下的偏差在这里收敛（见 mirrorNeedsReposition）。
          // 主树侧感知得到 Idle，但只有镜像侧能 scrollTo —— 走模型的信号量转发（对齐由 @Monitor 执行）。
          if (scrollState === ScrollState.Idle) {
            this.band.requestAlign();
          }
        })
        // 挂载 / 重新可见时上报一次（列表模式切换、页签切回都靠它对齐镜像）
        .onAppear(() => {
          this.reportBandOffset(0);
          this.applyBandOffset(true);
        })
        // 视口高度上报：镜像按同一高度布局（主树在 Tabs 里会被安全区再收一档）
        .onAreaChange((_oldValue: Area, newValue: Area): void => {
          if (!this.passive && !this.isMirrorContext && this.reportsViewport) {
            this.band.reportViewportHeight(Number(newValue.height), Number(newValue.globalPosition.y));
          }
        })
      }
      .width('100%')
      .height('100%')
    }
  }
}
