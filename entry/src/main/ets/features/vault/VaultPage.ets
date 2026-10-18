/*
 * SPDX-FileCopyrightText: 2026 Liugt
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import { VaultViewModel, VaultChip, VaultCounts } from './VaultViewModel';
import { ThemeService, ThemeState } from '../../application/theme/ThemeService';
import { VaultList } from './VaultList';
import { CategoryListParam } from './CategoryListPage';
import { GlassBandModel } from '../tabs/GlassBandModel';
import { AppInput } from '../../common/components/AppInput';
import { AppGroup } from '../../common/components/AppGroup';
import { Spacing, Typography, Radius, Sizes, GroupedList, Opacity } from '../../common/design/Tokens';
import { SafeArea } from '../../common/design/SafeArea';
import { CipherView, FolderView } from '../../application/state/VaultMemoryIndex';
import { ItemDetailParam } from './ItemDetailPage';
import { ItemEditParam } from './ItemEditPage';
import { ServiceLocator } from '../../application/ServiceLocator';
import { FastUnlockPromptService } from '../../application/FastUnlockPromptService';
import { ConfirmDialogService } from '../../application/ConfirmDialogService';
import { TypeSelectDialogService } from '../../application/TypeSelectDialogService';
import { ItemType } from '../../domain/model/ItemType';

type FolderRowAlias = FolderView;

function copyViaClipboard(text: string): void {
  ServiceLocator.clipboard().copy(text);
}

/** 分类卡数据（主页 category grid）。 */
interface CategoryItem {
  key: string;
  label: ResourceStr;
  icon: Resource;
  color: string;
  count: number;
  onTap: () => void;
}

/** 分类卡一行两张；奇数行 second 为 null。 */
interface CategoryPair {
  first: CategoryItem;
  second: CategoryItem | null;
}

/**
 * 保管库主页（spec F6 分类网格重构）：大标题 + 搜索 + 分类卡两列网格（全部/收藏/登录/
 * 笔记/银行卡/身份/回收站，含计数）+ 文件夹分组列表（点击进入该文件夹筛选列表）+
 * 选中分类进入列表模式（返回 + VaultList）；下拉刷新触发同步；路由/复制/删除确认同前。
 */
@ComponentV2
export struct VaultPage {
  @Consumer('isMirrorContext') isMirrorContext: boolean = false;
  /** 品牌色响应源（T24：主题切换经 ThemeState 即时生效）。 */
  private theme: ThemeState = ThemeService.get().state;
  @Consumer('navStack') navStack: NavPathStack = new NavPathStack();
  /**
   * 数据 / 交互状态（B 形态）：由 `GlassTabContent` 注入（主树与镜像树同一实例）；
   * 非玻璃路径不传时退回页内自建（默认值），行为与旧版一致。
   */
  @Param viewModel: VaultViewModel = new VaultViewModel();
  /** 玻璃条带镜像：主树上报绝对滚动偏移，镜像树按它 scrollTo（见 GlassBandModel）。 */
  @Param band: GlassBandModel = new GlassBandModel();
  /** 镜像树标记：只渲染、不跑副作用、滚动被动跟随。 */
  @Param passive: boolean = false;
  @Local private showMovePanel: boolean = false;
  @Local private pendingDeleteId: string | null = null;
  @Local private refreshing: boolean = false;
  @Local private toastText: string | null = null;
  private toastTimer: number = -1;
  @Local private safeTop: number = 0;
  @Local private safeBottom: number = 0;
  /** 悬浮头部实测高度（onAreaChange）→ 内容视口顶部内距。 */
  @Local private headerH: number = 0;
  /** 数据变更纪元（fix-05 同款：真机 V2 对 @ObservedV2 嵌套 @Trace 的重渲染不稳定，
   *  显式 @Local 镜像驱动 ForEach 重建）。 */
  @Local private dataEpoch: number = 0;
  private indexListener: (() => void) | null = null;
  /** 网格 Scroll 的控制器：主树用它上报绝对偏移，镜像树用它 scrollTo。 */
  private gridScroller: Scroller = new Scroller();

  aboutToAppear(): void {
    // 镜像树（passive）：只量算自己的安全区 / 头部高度，不 init / 不刷新 / 不消费一次性信号
    this.safeTop = SafeArea.top();
    this.safeBottom = SafeArea.bottom();
    // 首帧精确估值（状态栏 + 返回栏行 + 大标题行 + 搜索栏 + 边距）；消解镜像树抖动。
    const HEADER_BOTTOM_PADDING: number = 20;
    const headerContentH: number = Sizes.touchMin + Typography.largeTitle.lineHeight + Spacing.sm + Sizes.control + HEADER_BOTTOM_PADDING;
    this.headerH = this.passive ? headerContentH : (this.safeTop + headerContentH);
    if (this.passive) {
      // 挂载首帧跟上主树当前偏移（滚动中进场时不是 0）
      setTimeout((): void => {
        this.applyBandOffset(true);
      }, 0);
      return;
    }
    this.viewModel.attachIndexListener();
    this.viewModel.startTicking();
    this.indexListener = (): void => {
      this.dataEpoch++;
    };
    this.viewModel.index.addListener(this.indexListener);
    this.viewModel.init().then((): void => {
      this.viewModel.refresh();
      this.dataEpoch++;
    });
    // 同步刷新提前到首帧前：数据已 hydration 时首帧即有计数，避免 0→N 闪变
    this.viewModel.refresh();
    this.dataEpoch++;
    // 页面（重）建时位置必然在顶部：修正该页签的镜像偏移
    this.band.resetOffset();
    // 登录成功后的快速解锁开启确认（一次性信号；冷启动/解锁不触发；卡片由根级模态渲染）
    const prompt: FastUnlockPromptService = FastUnlockPromptService.get();
    if (prompt.consumeRequest()) {
      prompt.show();
    }
  }

  /**
   * 内容视口顶部内距（vp）= 头部浮层在状态栏之下的可见高度。
   *
   * 两棵树量到的 `headerH` 含义不同：主树量到的是**含 expandSafeArea 扩展**的绘制
   * 高度（扩展只影响绘制区、不占排版空间），离屏镜像树里没有状态栏、扩展不生效，
   * 量到的本来就是排版高度。所以主树减 safeTop 还原排版高度，镜像直接用 ——
   * 之前两棵树都减，镜像就少了一个状态栏高度，玻璃里的内容整体上移。
   */
  private get contentInsetTop(): number {
    return this.passive ? this.headerH : Math.max(0, this.headerH - this.safeTop);
  }

  /** 头部浮层占的整块高度（含扩进状态栏那一段）：浮层（移动面板）从它下面开始。 */
  private get headerBoxHeight(): number {
    return this.passive ? this.headerH + this.safeTop : this.headerH;
  }

  /**
   * 镜像树：把滚动位置对齐到主树（无动画跳转）；夹不掉的回弹由 GlassTabMirror 平移补齐。
   *
   * 滚动跟随走量化（`mirrorNeedsReposition`）：小于阈值的滞后由 GL 采样位移补，
   * 镜像不必每帧 relayout 整页。挂载 / 重新可见时必须 `force` —— 那一刻镜像的实际
   * 位置可能与模型缓存不一致，必须无条件对一次。
   */
  private applyBandOffset(force: boolean = false): void {
    if (!this.passive || !this.showGrid) {
      return;
    }
    if (!force && !this.band.mirrorNeedsReposition(this.band.mirrorTargetY())) {
      return;
    }
    this.gridScroller.scrollTo({ xOffset: 0, yOffset: this.band.mirrorTargetY(), animation: false });
  }

  /** 镜像树：上报自己实际落到的偏移（被内容范围夹取后的值）。 */
  private reportMirrorOffset(): void {
    if (!this.passive && !this.isMirrorContext) {
      return;
    }
    this.band.setApplied(this.gridScroller.currentOffset().yOffset);
  }

  /** 主树滚动 → 上报视觉偏移（镜像树的滚动同步源）。镜像树的程序化滚动不回报。 */
  private reportBandOffset(delta: number): void {
    if (this.passive) {
      return;
    }
    this.band.report(delta, this.gridScroller.currentOffset().yOffset);
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

  aboutToDisappear(): void {
    if (this.passive) {
      return;
    }
    if (this.indexListener !== null) {
      this.viewModel.index.removeListener(this.indexListener);
      this.indexListener = null;
    }
    this.viewModel.aboutToDetach();
    if (this.toastTimer !== -1) {
      clearTimeout(this.toastTimer);
      this.toastTimer = -1;
    }
  }

  private get showGrid(): boolean {
    return this.viewModel.searchText.length === 0;
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

  private copyText(text: string): void {
    if (text.length === 0) {
      return;
    }
    copyViaClipboard(text);
    this.showToast($r('app.string.toast_copied'));
  }

  private openDetail(cipherId: string): void {
    const param: ItemDetailParam = {
      cipherId: cipherId, backTitle: this.resText($r('app.string.vault_title'))
    };
    this.navStack.pushPathByName('ItemDetail', param);
  }

  private openEdit(cipherId: string | null, type?: number): void {
    const param: ItemEditParam = cipherId === null
      ? { type: type === undefined ? undefined : String(type) }
      : { cipherId: cipherId };
    this.navStack.pushPathByName('ItemEdit', param);
  }

  private async toggleFavorite(item: CipherView): Promise<void> {
    await this.viewModel.toggleFavorite(item);
  }

  private async confirmDelete(): Promise<void> {
    const id: string | null = this.pendingDeleteId;
    this.pendingDeleteId = null;
    if (id === null) {
      return;
    }
    await this.viewModel.softDelete(id);
    this.viewModel.refresh();
  }

  /** 删除二次确认：根级弹窗（覆盖页签栏与状态栏，选择前阻断交互）。 */
  private requestDelete(cipherId: string): void {
    this.pendingDeleteId = cipherId;
    ConfirmDialogService.get().show({
      title: $r('app.string.menu_delete'),
      body: $r('app.string.delete_confirm_body'),
      cancelLabel: $r('app.string.cancel'),
      confirmLabel: $r('app.string.menu_delete'),
      onCancel: (): void => {
        this.pendingDeleteId = null;
      },
      onConfirm: (): void => {
        this.confirmDelete();
      }
    });
  }

  private resText(res: Resource): string {
    return getContext(this).resourceManager.getStringSync(res);
  }

  /** 路由到二级分类页（chip / 文件夹）。 */
  private openCategory(chip: VaultChip | null, folderId: string | null,
    folderName: string): void {
    const param: CategoryListParam = {
      chip: chip, folderId: folderId, folderName: folderName,
      backTitle: this.resText($r('app.string.vault_title'))
    };
    this.navStack.pushPathByName('CategoryList', param);
  }

  /** 返回主页网格：复位搜索。 */
  private backToGrid(): void {
    this.viewModel.setFolder(null, false);
    this.viewModel.setChip('all');
    this.viewModel.setSearchText('');
  }

  private handleAddClick(): void {
    if (this.passive) {
      return;
    }
    this.showMovePanel = false;
    TypeSelectDialogService.get().show({
      onSelect: (selectedType: ItemType): void => {
        this.openEdit(null, selectedType);
      }
    });
  }

  private categories(): CategoryItem[] {
    const c: VaultCounts = this.viewModel.counts;
    return [
      {
        key: 'all', label: $r('app.string.filter_all'),
        icon: $r('sys.symbol.key_fill'), color: '#0A84FF', count: c.all,
        onTap: (): void => this.openCategory('all', null, '')
      },
      {
        key: 'favorites', label: $r('app.string.filter_favorites'),
        icon: $r('sys.symbol.star_fill'), color: '#F2B01E', count: c.favorites,
        onTap: (): void => this.openCategory('favorites', null, '')
      },
      {
        key: 'login', label: $r('app.string.filter_login'),
        icon: $r('sys.symbol.person_crop_circle_fill_1'), color: '#34C759', count: c.login,
        onTap: (): void => this.openCategory('login', null, '')
      },
      {
        key: 'note', label: $r('app.string.filter_note'),
        icon: $r('sys.symbol.doc_text'), color: '#FF9500', count: c.note,
        onTap: (): void => this.openCategory('note', null, '')
      },
      {
        key: 'card', label: $r('app.string.filter_card'),
        icon: $r('sys.symbol.creditcard_fill'), color: '#3478F6', count: c.card,
        onTap: (): void => this.openCategory('card', null, '')
      },
      {
        key: 'identity', label: $r('app.string.filter_identity'),
        icon: $r('sys.symbol.person_text_rectangle_fill'), color: '#5E5CE6',
        count: c.identity,
        onTap: (): void => this.openCategory('identity', null, '')
      },
      {
        key: 'trash', label: $r('app.string.trash_title'),
        icon: $r('sys.symbol.trash_fill'), color: '#FF6B22', count: c.trash,
        onTap: (): void => this.openCategory('trash', null, '')
      }
    ];
  }

  private categoryRows(): CategoryPair[] {
    const cats: CategoryItem[] = this.categories();
    const rows: CategoryPair[] = [];
    for (let i = 0; i < cats.length; i += 2) {
      rows.push({
        first: cats[i],
        second: i + 1 < cats.length ? cats[i + 1] : null
      });
    }
    return rows;
  }

  private folderCount(folderId: string): number {
    return this.viewModel.counts.folderCounts.get(folderId) ?? 0;
  }

  @Builder
  categoryCard(cat: CategoryItem) {
    Column({ space: Spacing.xs }) {
      Row({ space: Spacing.xs }) {
        Column() {
          SymbolGlyph(cat.icon)
            .fontSize(18)
            .fontColor([$r('app.color.on_tint')])
        }
        .width(30)
        .height(30)
        .borderRadius(Radius.pill(30))
        .backgroundColor(cat.color)
        .justifyContent(FlexAlign.Center)

        Blank()

        Text(String(cat.count))
          .fontSize(Typography.subhead.size)
          .lineHeight(Typography.subhead.lineHeight)
          .fontColor($r('app.color.avatar_fill'))
          .contentTransition(new NumericTextTransition({ flipDirection: FlipDirection.UP }))
        SymbolGlyph($r('sys.symbol.chevron_right'))
          .fontSize(Typography.body.size)
          .fontWeight(FontWeight.Bold)
          .fontColor([$r('app.color.tertiary_label')])
      }
      .width('100%')
      .justifyContent(FlexAlign.SpaceBetween)

      Text(cat.label)
        .fontSize(GroupedList.primaryText.size)
        .lineHeight(GroupedList.primaryText.lineHeight)
        .fontColor($r('app.color.label'))
        .maxLines(1)
        .width('100%')
    }
    .alignItems(HorizontalAlign.Start)
    .padding(GroupedList.cardPadding)
    .constraintSize({ minHeight: GroupedList.cardMinHeight })
    .layoutWeight(1)
    .borderRadius(Radius.lg)
    .backgroundColor($r('app.color.secondary_system_background'))
    .onClick(() => cat.onTap())
  }

  @Builder
  categoryGrid() {
    Column({ space: Spacing.md }) {
      ForEach(this.categoryRows(), (row: CategoryPair) => {
        Row({ space: Spacing.md }) {
          this.categoryCard(row.first)
          if (row.second !== null) {
            this.categoryCard(row.second)
          } else {
            Column()
              .layoutWeight(1)
          }
        }
        .width('100%')
      }, (row: CategoryPair) => `${row.first.key}-${String(this.dataEpoch)}`)
    }
    .width('100%')
    .padding({ left: Spacing.page, right: Spacing.page, top: 0 })
  }

  @Builder
  folderRow(folder: FolderRowAlias, withSeparator: boolean) {
    Row({ space: Spacing.md }) {
      Column() {
        SymbolGlyph($r('sys.symbol.folder_fill'))
          .fontSize(18)
          .fontColor([$r('app.color.on_tint')])
      }
      .width(30)
      .height(30)
      .borderRadius(Radius.pill(30))
      .backgroundColor($r('app.color.avatar_fill'))
      .justifyContent(FlexAlign.Center)

      Text(folder.name)
        .fontSize(GroupedList.primaryText.size)
        .lineHeight(GroupedList.primaryText.lineHeight)
        .fontColor($r('app.color.label'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)

      Text(String(this.folderCount(folder.id)))
        .fontSize(GroupedList.secondaryText.size)
        .lineHeight(GroupedList.secondaryText.lineHeight)
        .fontColor($r('app.color.avatar_fill'))
      SymbolGlyph($r('sys.symbol.chevron_right'))
        .fontSize(GroupedList.chevronText.size)
        .fontWeight(FontWeight.Bold)
        .fontColor([$r('app.color.tertiary_label')])
    }
    .width('100%')
    .constraintSize({ minHeight: GroupedList.rowMinHeight })
    .padding({ left: GroupedList.rowHorizontal, right: GroupedList.rowHorizontal,
      top: GroupedList.rowVertical, bottom: GroupedList.rowVertical })
    .borderWidth({ top: withSeparator ? Sizes.hairline : 0 })
    .borderColor($r('app.color.separator'))
    .onClick(() => {
      this.openCategory(null, folder.id, folder.name);
    })
  }

  @Builder
  folderSection() {
    if (this.viewModel.folders.length > 0) {
      Column() {
        AppGroup({ title: $r('app.string.filter_folder') }) {
          Column() {
            ForEach(this.viewModel.folders, (folder: FolderRowAlias, index: number) => {
              this.folderRow(folder, index > 0)
            }, (folder: FolderRowAlias) => `${folder.id}-${String(this.dataEpoch)}`)
          }
          .width('100%')
        }
      }
      .width('100%')
      .padding({ left: Spacing.page, right: Spacing.page })
    }
  }

  @Builder
  gridContent() {
    Scroll(this.gridScroller) {
      Column() {
        this.categoryGrid()
        this.folderSection()
        Column()
          .height(Sizes.tabBar + Spacing.xl + this.safeBottom)
      }
      .width('100%')
    }
    .width('100%')
    .height('100%')
    .align(Alignment.Top)
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring)
    .backgroundColor($r('app.color.system_background'))
    // 滚动位移上报：玻璃条带镜像据此同帧跟随（主树上报视觉偏移 + 边界增量）
    // Scroll 的回调是 (xOffset, yOffset, scrollState)（List 才是 (scrollOffset, scrollState)）：
    // 按 List 的签名写会把恒为 0 的 xOffset 当位移（一帧外推 / 越界增量全丢）、把位移当状态
    .onDidScroll((_xOffset: number, yOffset: number, scrollState: ScrollState) => {
      this.reportBandOffset(yOffset)
      this.reportMirrorOffset()
      // 停下时请求一次精确对齐：滚动中量化留下的偏差在这里收敛（见 mirrorNeedsReposition）。
      // 主树侧感知得到 Idle，但只有镜像侧能 scrollTo —— 走模型的信号量转发（对齐由 @Monitor 执行）。
      if (scrollState === ScrollState.Idle) {
        this.band.requestAlign()
      }
    })
    // 挂载 / 重新可见时上报一次（网格模式切换、页签切回都靠它对齐镜像）；无条件对一次
    .onAppear(() => {
      this.reportBandOffset(0)
      this.applyBandOffset(true)
    })
  }

  @Builder
  movePanel() {
    // 内缩包装在容器上做（走查反馈）：面板自身 width 100% + margin 会右侧超宽
    Column() {
      Column({ space: Spacing.xs }) {
        Text($r('app.string.menu_move'))
          .fontSize(Typography.footnote.size)
          .lineHeight(Typography.footnote.lineHeight)
          .fontWeight(Typography.headline.weight)
          .fontColor($r('app.color.secondary_label'))
        this.moveRow($r('app.string.folder_none'), null)
        ForEach(this.viewModel.folders, (folder: FolderRowAlias) => {
          this.moveRow(folder.name, folder.id)
        }, (folder: FolderRowAlias) => folder.id)
      }
      .width('100%')
      .padding(Spacing.md)
      .borderRadius(Radius.lg)
      .backgroundColor($r('app.color.secondary_system_background'))
    }
    .width('100%')
    .padding({ left: Spacing.page, right: Spacing.page })
  }

  @Builder
  moveRow(label: ResourceStr, folderId: string | null) {
    Text(label)
      .fontSize(Typography.body.size)
      .lineHeight(Typography.body.lineHeight)
      .fontColor($r('app.color.label'))
      .width('100%')
      .constraintSize({ minHeight: Sizes.touchMin })
      .padding({ left: Spacing.lg, right: Spacing.lg })
      .onClick(() => {
        this.viewModel.applyMove(folderId).then((): void => {
          this.showMovePanel = false;
        });
      })
  }

  build() {
    Stack({ alignContent: Alignment.Top }) {
      // 内容只让出可见头部高度：状态栏由头部的 expandSafeArea 覆盖，不重复留白。
      Column() {
        Refresh({ refreshing: this.refreshing!! }) {
          if (this.showGrid) {
            this.gridContent()
          } else {
            VaultList({
              viewModel: this.viewModel,
              band: this.band,
              passive: this.passive,
              onOpenDetail: (cipherId: string): void => this.openDetail(cipherId),
              onEditItem: (cipherId: string): void => this.openEdit(cipherId),
              onMoveItem: (cipherId: string): void => {
                this.viewModel.beginMove(cipherId);
                this.showMovePanel = true;
              },
              onDeleteItem: (cipherId: string): void => {
                this.requestDelete(cipherId);
              },
              onToggleFavorite: (item: CipherView): void => {
                this.toggleFavorite(item);
              },
              onCopy: (text: string): void => this.copyText(text),
              onCopyPassword: (item: CipherView): void => {
                if (item.password.length === 0) {
                  return;
                }
                copyViaClipboard(item.password);
                this.showToast($r('app.string.toast_copied'));
                this.viewModel.touchLastUsed(item.id);
              }
            })
          }
        }
        .layoutWeight(1)
        .width('100%')
        // 下拉刷新：手势被 Refresh 吃掉，内部 Scroll 不会滚动 → 玻璃要单独知道
        // 这段下拉量（内容整体被拉下），否则下拉过程中玻璃里的画面完全不跟手。
        // 下拉距离不设上限（maxPullDownDistance）：超过采样预算的部分落容器平移，
        // 锁存已含平移、采样会补掉它的纹理滞后，延迟不回退（见 GlassBandModel）。
        .onOffsetChange((value: number): void => {
          if (!this.passive && !this.isMirrorContext) {
            this.band.reportPull(value)
          }
        })
        .onRefreshing(() => {
          this.viewModel.syncNow().then((): void => {
            this.refreshing = false;
          }).catch((_e: Object): void => {
            // 同步失败不再卡转圈（E2E-01 偏差 3 收口）：复位刷新态 + 错误提示
            this.refreshing = false;
            this.showToast($r('app.string.sync_failed'));
          });
        })
      }
      .width('100%')
      .height('100%')
      .padding({ top: this.contentInsetTop })

      // 悬浮头部：返回栏/工具栏行 + 大标题 + 搜索（无语音按钮）
      Column() {
        // 返回栏/工具栏行：对齐 ItemDetailPage 与 CategoryListPage 返回栏位置
        Row() {
          if (!this.showGrid) {
            Row({ space: Spacing.xs }) {
              SymbolGlyph($r('sys.symbol.chevron_left'))
                .fontSize(Sizes.rowIcon)
                .fontColor([this.theme.primary])
              Text($r('app.string.previous_step'))
                .fontSize(Typography.subhead.size)
                .lineHeight(Typography.subhead.lineHeight)
                .fontColor(this.theme.primary)
            }
            .layoutWeight(1)
            .constraintSize({ minHeight: Sizes.touchMin })
            .onClick(() => {
              this.backToGrid();
            })
          } else {
            Blank()
          }

          Button() {
            SymbolGlyph($r('sys.symbol.plus'))
              .fontSize(Sizes.rowIcon)
              .fontColor([this.theme.primary])
          }
          .type(ButtonType.Normal)
          .width(Sizes.touchMin)
          .height(Sizes.touchMin)
          .padding(0)
          .backgroundColor(Color.Transparent)
          .border({ width: 0 })
          .stateEffect(false)
          .stateStyles({
            pressed: { .opacity(Opacity.pressed) },
            normal: { .opacity(1.0) }
          })
          .accessibilityText($r('app.string.a11y_add_item'))
          .enabled(!this.passive)
          .onClick(() => {
            this.handleAddClick();
          })
        }
        .width('100%')
        .constraintSize({ minHeight: Sizes.touchMin })
        .padding({ left: Spacing.page, right: Spacing.page })

        Text($r('app.string.vault_title'))
          .fontSize(Typography.largeTitle.size)
          .lineHeight(Typography.largeTitle.lineHeight)
          .fontWeight(Typography.largeTitle.weight)
          .fontColor($r('app.color.label'))
          .padding({ left: Spacing.page, right: Spacing.page })

        Row() {
          AppInput({
            placeholder: $r('app.string.search_hint'),
            text: this.viewModel.searchText,
            onChange: (value: string): void => {
              this.viewModel.setSearchText(value);
            }
          })
        }
        .width('100%')
        .padding({ left: Spacing.page, right: Spacing.page })
        .margin({ top: Spacing.sm })
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      // 与二级页与详情页一致：返回栏行贴着状态栏底边开始；扩展只负责绘制背景。
      .padding({ top: 0, bottom: 20 })
      .backgroundColor($r('app.color.system_background'))
      .onAreaChange((_oldArea: Area, newArea: Area): void => {
        this.headerH = newArea.height as number;
      })
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP])

      if (this.showMovePanel) {
        // 悬浮于内容之上、头部之下：顶部让位 headerH + 半透明遮罩（点击关闭）
        Column() {
          this.movePanel()
        }
        .width('100%')
        .height('100%')
        .padding({ top: this.headerBoxHeight })
        .backgroundColor($r('app.color.system_background'))
        .opacity(0.98)
        .onClick(() => {
          this.showMovePanel = false;
        })
      }

      if (this.toastText !== null) {
        Text(this.toastText)
          .fontSize(Typography.footnote.size)
          .lineHeight(Typography.footnote.lineHeight)
          .fontColor(this.theme.onPrimary)
          .padding({ left: Spacing.lg, right: Spacing.lg, top: Spacing.sm, bottom: Spacing.sm })
          .borderRadius(Radius.xs)
          .backgroundColor($r('app.color.secondary_label'))
          .margin({ bottom: Sizes.tabBar + Spacing.xl + this.safeBottom })
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.system_background'))
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])
    // 镜像布局基准 = **页面盒**高度，不是滚动容器高度：本页头部是浮层、内容由
    // Refresh 顶部内距让位（headerH - safeTop），镜像按整页布局才能与主树逐像素
    // 对齐；拿滚动容器高度当盒子会把镜像内容整体上移一个内距（玻璃里映射到
    // 错误的一行）。页面盒底边贴屏幕底，镜像用"底边对齐"反推原点。
    .onAreaChange((_oldValue: Area, newValue: Area): void => {
      if (!this.passive && !this.isMirrorContext) {
        this.band.reportViewportHeight(Number(newValue.height), Number(newValue.globalPosition.y))
      }
    })
  }
}
