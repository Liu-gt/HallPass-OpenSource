/*
 * SPDX-FileCopyrightText: 2026 Liugt
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import { VaultViewModel, VaultChip } from './VaultViewModel';
import { ThemeService, ThemeState } from '../../application/theme/ThemeService';
import { VaultList } from './VaultList';
import { AppInput } from '../../common/components/AppInput';
import { Spacing, Typography, Radius, Sizes, Opacity } from '../../common/design/Tokens';
import { SafeArea } from '../../common/design/SafeArea';
import { CipherView, FolderView } from '../../application/state/VaultMemoryIndex';
import { ItemDetailParam } from './ItemDetailPage';
import { ItemEditParam } from './ItemEditPage';
import { ServiceLocator } from '../../application/ServiceLocator';
import { ConfirmDialogService } from '../../application/ConfirmDialogService';
import { TypeSelectDialogService } from '../../application/TypeSelectDialogService';
import { ItemType } from '../../domain/model/ItemType';
import { SystemBar } from '../../common/design/SystemBar';
import { GlassBandModel } from '../tabs/GlassBandModel';
import { MirrorRouter, MirrorPageEntry } from '../mirror/MirrorRouter';

/** 二级分类页路由参数：chip 二选一，folderId/folderName 二选一。 */
export interface CategoryListParam {
  chip: VaultChip | null;
  folderId: string | null;
  folderName: string;
  backTitle: string;
}

function copyViaClipboard(text: string): void {
  ServiceLocator.clipboard().copy(text);
}

/**
 * 二级分类列表页的全部可见状态（外壳持有，主树与镜像树同一实例，见 features/mirror/MirrorRouter）。
 */
@ObservedV2
export class CategoryListState {
  readonly viewModel: VaultViewModel = new VaultViewModel();
  @Trace pageTitle: string = '';
  @Trace backTitle: string = '';
  @Trace chip: VaultChip | null = null;
  @Trace folderId: string | null = null;
  @Trace showMovePanel: boolean = false;
  @Trace pendingDeleteId: string | null = null;
  @Trace toastText: string | null = null;
  @Trace headerH: number = 0;
}

/**
 * 二级分类列表页内容（iOS 风格，主树 / 镜像树共用）：自绘头部 = 返回行（chevron + 主页标题）+
 * 大标题（分类/文件夹名）+ 搜索，下方 VaultList。passive = true（镜像树）只渲染、滚动跟随主树。
 */
@ComponentV2
export struct CategoryListContent {
  private theme: ThemeState = ThemeService.get().state;
  @Consumer('navStack') navStack: NavPathStack = new NavPathStack();
  @Require @Param state: CategoryListState;
  @Require @Param band: GlassBandModel;
  @Param passive: boolean = false;
  @Local private safeBottom: number = 0;
  private toastTimer: number = -1;
  private static readonly NAV_THROTTLE_MS: number = 500;
  private lastNavTime: number = 0;

  aboutToAppear(): void {
    this.safeBottom = SafeArea.bottom();
  }

  aboutToDisappear(): void {
    if (this.toastTimer !== -1) {
      clearTimeout(this.toastTimer);
      this.toastTimer = -1;
    }
  }

  private currentTitle(): string {
    if (this.state.chip === null && this.state.folderId !== null) {
      const folder: FolderView | undefined = this.state.viewModel.folders.find(
        (item: FolderView): boolean => item.id === this.state.folderId);
      return folder?.name ?? this.state.pageTitle;
    }
    return this.state.pageTitle;
  }

  private showToast(text: ResourceStr): void {
    this.state.toastText = typeof text === 'string' ? text as string
      : getContext(this).resourceManager.getStringSync(text as Resource);
    if (this.toastTimer !== -1) {
      clearTimeout(this.toastTimer);
    }
    this.toastTimer = setTimeout((): void => {
      this.state.toastText = null;
      this.toastTimer = -1;
    }, 1800);
  }

  private copyText(text: string): void {
    if (this.passive || text.length === 0) {
      return;
    }
    copyViaClipboard(text);
    this.showToast($r('app.string.toast_copied'));
  }

  private openDetail(cipherId: string): void {
    if (this.passive) {
      return;
    }
    const param: ItemDetailParam = { cipherId: cipherId, backTitle: this.currentTitle() };
    this.navStack.pushPathByName('ItemDetail', param);
  }

  private openEdit(cipherId: string | null, type?: number, folderId?: string | null): void {
    if (this.passive) {
      return;
    }
    const now: number = Date.now();
    if (now - this.lastNavTime < CategoryListContent.NAV_THROTTLE_MS) {
      return; // F-01: 防连点截流，杜绝直接分类导航栈竞态
    }
    this.lastNavTime = now;

    const param: ItemEditParam = cipherId === null
      ? {
          type: type === undefined ? undefined : String(type),
          backTitle: this.currentTitle(),
          folderId: folderId ?? undefined
        }
      : { cipherId: cipherId, backTitle: this.currentTitle() };
    this.navStack.pushPathByName('ItemEdit', param);
  }

  private async toggleFavorite(item: CipherView): Promise<void> {
    if (this.passive) {
      return;
    }
    await this.state.viewModel.toggleFavorite(item);
  }

  private async confirmDelete(): Promise<void> {
    const id: string | null = this.state.pendingDeleteId;
    this.state.pendingDeleteId = null;
    if (id === null) {
      return;
    }
    await this.state.viewModel.softDelete(id);
    this.state.viewModel.refresh();
  }

  /** 删除二次确认：根级弹窗（覆盖页签栏与状态栏，选择前阻断交互）。 */
  private requestDelete(cipherId: string): void {
    if (this.passive) {
      return;
    }
    this.state.pendingDeleteId = cipherId;
    ConfirmDialogService.get().show({
      title: $r('app.string.menu_delete'),
      body: $r('app.string.delete_confirm_body'),
      cancelLabel: $r('app.string.cancel'),
      confirmLabel: $r('app.string.menu_delete'),
      onCancel: (): void => {
        this.state.pendingDeleteId = null;
      },
      onConfirm: (): void => {
        this.confirmDelete();
      }
    });
  }

  private handleAddClick(): void {
    if (this.passive) {
      return;
    }
    this.state.showMovePanel = false; // F2-05: 打开新建前重置移动面板
    if (this.state.chip === 'trash') {
      return;
    }
    if (this.state.chip === 'login') {
      this.openEdit(null, ItemType.Login);
      return;
    }
    if (this.state.chip === 'card') {
      this.openEdit(null, ItemType.Card);
      return;
    }
    if (this.state.chip === 'identity') {
      this.openEdit(null, ItemType.Identity);
      return;
    }
    if (this.state.chip === 'note') {
      this.openEdit(null, ItemType.SecureNote);
      return;
    }
    TypeSelectDialogService.get().show({
      onSelect: (selectedType: ItemType): void => {
        this.openEdit(null, selectedType, this.state.folderId);
      }
    });
  }

  @Builder
  movePanel() {
    Column() {
      Column({ space: Spacing.xs }) {
        Text($r('app.string.menu_move'))
          .fontSize(Typography.footnote.size)
          .lineHeight(Typography.footnote.lineHeight)
          .fontWeight(Typography.headline.weight)
          .fontColor($r('app.color.secondary_label'))
        this.moveRow($r('app.string.folder_none'), null)
        ForEach(this.state.viewModel.folders, (folder: FolderView) => {
          this.moveRow(folder.name, folder.id)
        }, (folder: FolderView) => folder.id)
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
        if (this.passive) {
          return;
        }
        this.state.viewModel.applyMove(folderId).then((): void => {
          this.state.showMovePanel = false;
        });
      })
  }

  build() {
    Stack({ alignContent: Alignment.Top }) {
      Column() {
        // 固定头部（iOS 风格）：返回行 → 大标题 → 搜索
        Column() {
          Row() {
            Row({ space: Spacing.xs }) {
              SymbolGlyph($r('sys.symbol.chevron_left'))
                .fontSize(Sizes.rowIcon)
                .fontColor([this.theme.primary])
              Text(this.state.backTitle)
                .fontSize(Typography.subhead.size)
                .lineHeight(Typography.subhead.lineHeight)
                .fontColor(this.theme.primary)
            }
            .layoutWeight(1)
            .constraintSize({ minHeight: Sizes.touchMin })
            .onClick(() => {
              if (this.passive) {
                return;
              }
              this.navStack.pop();
            })

            if (this.state.chip !== 'trash') {
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
              .onClick(() => {
                this.handleAddClick();
              })
            }
          }
          .width('100%')
          .constraintSize({ minHeight: Sizes.touchMin })
          .padding({ left: Spacing.page, right: Spacing.page })

          Text(this.currentTitle())
            .fontSize(Typography.largeTitle.size)
            .lineHeight(Typography.largeTitle.lineHeight)
            .fontWeight(Typography.largeTitle.weight)
            .fontColor($r('app.color.label'))
            .padding({ left: Spacing.page, right: Spacing.page })
            .margin({ top: 0 })

          Row() {
            AppInput({
              placeholder: $r('app.string.search_hint'),
              text: this.state.viewModel.searchText,
              fieldBg: $r('app.color.search_field_secondary'),
              onChange: (value: string): void => {
                if (this.passive) {
                  return;
                }
                this.state.viewModel.setSearchText(value);
              }
            })
          }
          .width('100%')
          .padding({ left: Spacing.page, right: Spacing.page })
          .margin({ top: Spacing.sm })
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .padding({ top: 0, bottom: 20 })
         .backgroundColor($r('app.color.detail_background'))
         .onAreaChange((_oldArea: Area, newArea: Area): void => {
          if (!this.passive) {
            this.state.headerH = newArea.height as number;
          }
        })
        .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP])

        VaultList({
          viewModel: this.state.viewModel,
          band: this.band,
          passive: this.passive,
          reportsViewport: false,
          titleBold: true,
          rowTextGap: 2,
          onOpenDetail: (cipherId: string): void => this.openDetail(cipherId),
          onEditItem: (cipherId: string): void => this.openEdit(cipherId),
          onMoveItem: (cipherId: string): void => {
            if (this.passive) {
              return;
            }
            this.state.viewModel.beginMove(cipherId);
            this.state.showMovePanel = true;
          },
          onDeleteItem: (cipherId: string): void => {
            this.requestDelete(cipherId);
          },
          onToggleFavorite: (item: CipherView): void => {
            this.toggleFavorite(item);
          },
          onCopy: (text: string): void => this.copyText(text),
          onCopyPassword: (item: CipherView): void => {
            if (this.passive || item.password.length === 0) {
              return;
            }
            copyViaClipboard(item.password);
            this.showToast($r('app.string.toast_copied'));
            this.state.viewModel.touchLastUsed(item.id);
          }
        })
        .layoutWeight(1)
        .width('100%')
      }
      .width('100%')
      .height('100%')
      .backgroundColor($r('app.color.detail_background'))

      if (this.state.showMovePanel) {
        Column() {
          this.movePanel()
        }
        .width('100%')
        .height('100%')
        .padding({ top: this.state.headerH })
        .backgroundColor($r('app.color.system_background'))
        .opacity(0.98)
        .onClick(() => {
          if (this.passive) {
            return;
          }
          this.state.showMovePanel = false;
        })
      }

      if (this.state.toastText !== null) {
        Text(this.state.toastText)
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
    // 镜像视口 = 整个页面盒（固定头部 + 列表；VaultList 不再自报，见 reportsViewport）
    .onAreaChange((_oldValue: Area, newValue: Area): void => {
      if (!this.passive) {
        this.band.reportViewportHeight(Number(newValue.height), Number(newValue.globalPosition.y));
      }
    })
  }
}

@Builder
function categoryListMirrorBuilder(entry: MirrorPageEntry) {
  CategoryListContent({ state: entry.state as CategoryListState, band: entry.band, passive: true })
}

const CATEGORY_LIST_MIRROR: WrappedBuilder<[MirrorPageEntry]> = wrapBuilder(categoryListMirrorBuilder);

/**
 * 二级分类列表页外壳（NavDestination 全屏覆盖页签，返回经 navStack.pop()）：
 * 路由参数、VM 生命周期、镜像登记；内容见 CategoryListContent。
 */
@ComponentV2
export struct CategoryListPage {
  private theme: ThemeState = ThemeService.get().state;
  private state: CategoryListState = new CategoryListState();
  private band: GlassBandModel = new GlassBandModel();
  private mirrorEntry: MirrorPageEntry | null = null;

  aboutToAppear(): void {
    this.setStatusBarContentColor();
    this.mirrorEntry = new MirrorPageEntry('CategoryList', this.state, this.band, CATEGORY_LIST_MIRROR);
  }

  aboutToDisappear(): void {
    this.state.viewModel.aboutToDetach();
    if (this.mirrorEntry !== null) {
      MirrorRouter.get().hide(this.mirrorEntry);
    }
  }

  private setStatusBarContentColor(): void {
    SystemBar.apply(this.theme.isDark);
  }

  private applyParam(param: CategoryListParam): void {
    this.state.chip = param.chip;
    this.state.folderId = param.folderId;
    this.state.pageTitle = param.chip !== null ? this.chipTitle(param.chip) : param.folderName;
    this.state.backTitle = param.backTitle;
    if (param.chip !== null) {
      this.state.viewModel.setChip(param.chip);
    } else {
      this.state.viewModel.setFolder(param.folderId, false);
    }
  }

  private resText(res: Resource): string {
    return getContext(this).resourceManager.getStringSync(res);
  }

  private chipTitle(chip: VaultChip): string {
    if (chip === 'all') {
      return this.resText($r('app.string.filter_all'));
    }
    if (chip === 'favorites') {
      return this.resText($r('app.string.filter_favorites'));
    }
    if (chip === 'login') {
      return this.resText($r('app.string.filter_login'));
    }
    if (chip === 'note') {
      return this.resText($r('app.string.filter_note'));
    }
    if (chip === 'card') {
      return this.resText($r('app.string.filter_card'));
    }
    if (chip === 'identity') {
      return this.resText($r('app.string.filter_identity'));
    }
    return this.resText($r('app.string.trash_title'));
  }

  build() {
    NavDestination() {
      CategoryListContent({ state: this.state, band: this.band })
    }
    .hideTitleBar(true)
    .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.BOTTOM])
    .onReady((context: NavDestinationContext): void => {
      this.applyParam(context.pathInfo.param as CategoryListParam);
    })
    .onShown(() => {
      this.setStatusBarContentColor();
      this.state.viewModel.attachIndexListener();
      this.state.viewModel.init();
      this.state.viewModel.startTicking();
      if (this.mirrorEntry !== null) {
        MirrorRouter.get().show(this.mirrorEntry);
      }
    })
    .onHidden(() => {
      this.state.viewModel.aboutToDetach();
      if (this.mirrorEntry !== null) {
        MirrorRouter.get().hide(this.mirrorEntry);
      }
    })
    // 确认弹窗可见时吞掉返回手势/返回键（视为取消），避免弹窗悬在已弹出的页面上
    .onBackPressed((): boolean => {
      if (TypeSelectDialogService.get().handleBack()) {
        return true;
      }
      return ConfirmDialogService.get().handleBack();
    })
  }
}
