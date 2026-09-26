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
 * 二级分类列表页（iOS 风格）：自绘头部 = 返回行（chevron + 主页标题）+ 大标题（分类/
 * 文件夹名）+ 搜索，下方 VaultList；NavDestination 全屏覆盖页签，返回经 navStack.pop()。
 */
@ComponentV2
export struct CategoryListPage {
  private theme: ThemeState = ThemeService.get().state;
  @Consumer('navStack') navStack: NavPathStack = new NavPathStack();
  @Local private viewModel: VaultViewModel = new VaultViewModel();
  @Local private pageTitle: string = '';
  @Local private backTitle: string = '';
  @Local private chip: VaultChip | null = null;
  @Local private folderId: string | null = null;
  @Local private showMovePanel: boolean = false;
  @Local private pendingDeleteId: string | null = null;
  @Local private toastText: string | null = null;
  private toastTimer: number = -1;
  @Local private safeBottom: number = 0;
  @Local private headerH: number = 0;
  private static readonly NAV_THROTTLE_MS: number = 500;
  private lastNavTime: number = 0;

  aboutToAppear(): void {
    this.safeBottom = SafeArea.bottom();
    this.setStatusBarContentColor();
  }

  aboutToDisappear(): void {
    this.viewModel.aboutToDetach();
    if (this.toastTimer !== -1) {
      clearTimeout(this.toastTimer);
      this.toastTimer = -1;
    }
  }

  private setStatusBarContentColor(): void {
    SystemBar.apply(this.theme.isDark);
  }

  private applyParam(param: CategoryListParam): void {
    this.chip = param.chip;
    this.folderId = param.folderId;
    this.pageTitle = param.chip !== null ? this.chipTitle(param.chip) : param.folderName;
    this.backTitle = param.backTitle;
    if (param.chip !== null) {
      this.viewModel.setChip(param.chip);
    } else {
      this.viewModel.setFolder(param.folderId, false);
    }
  }

  private resText(res: Resource): string {
    return getContext(this).resourceManager.getStringSync(res);
  }

  private currentTitle(): string {
    if (this.chip === null && this.folderId !== null) {
      const folder: FolderView | undefined = this.viewModel.folders.find(
        (item: FolderView): boolean => item.id === this.folderId);
      return folder?.name ?? this.pageTitle;
    }
    return this.pageTitle;
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

  private showToast(text: ResourceStr): void {
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
    const param: ItemDetailParam = { cipherId: cipherId, backTitle: this.currentTitle() };
    this.navStack.pushPathByName('ItemDetail', param);
  }

  private openEdit(cipherId: string | null, type?: number, folderId?: string | null): void {
    const now: number = Date.now();
    if (now - this.lastNavTime < CategoryListPage.NAV_THROTTLE_MS) {
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

  private handleAddClick(): void {
    this.showMovePanel = false; // F2-05: 打开新建前重置移动面板
    if (this.chip === 'trash') {
      return;
    }
    if (this.chip === 'login') {
      this.openEdit(null, ItemType.Login);
      return;
    }
    if (this.chip === 'card') {
      this.openEdit(null, ItemType.Card);
      return;
    }
    if (this.chip === 'identity') {
      this.openEdit(null, ItemType.Identity);
      return;
    }
    if (this.chip === 'note') {
      this.openEdit(null, ItemType.SecureNote);
      return;
    }
    TypeSelectDialogService.get().show({
      onSelect: (selectedType: ItemType): void => {
        this.openEdit(null, selectedType, this.folderId);
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
        ForEach(this.viewModel.folders, (folder: FolderView) => {
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
        this.viewModel.applyMove(folderId).then((): void => {
          this.showMovePanel = false;
        });
      })
  }

  build() {
    NavDestination() {
      Stack({ alignContent: Alignment.Top }) {
        Column() {
          // 固定头部（iOS 风格）：返回行 → 大标题 → 搜索
          Column() {
            Row() {
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

              if (this.chip !== 'trash') {
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
                text: this.viewModel.searchText,
                fieldBg: $r('app.color.search_field_secondary'),
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
          .padding({ top: 0, bottom: 20 })
           .backgroundColor($r('app.color.detail_background'))
           .onAreaChange((_oldArea: Area, newArea: Area): void => {
            this.headerH = newArea.height as number;
          })
          .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP])

          VaultList({
            viewModel: this.viewModel,
            titleBold: true,
            rowTextGap: 2,
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
          .layoutWeight(1)
          .width('100%')
        }
        .width('100%')
        .height('100%')
        .backgroundColor($r('app.color.detail_background'))

        if (this.showMovePanel) {
          Column() {
            this.movePanel()
          }
          .width('100%')
          .height('100%')
          .padding({ top: this.headerH })
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
    }
    .hideTitleBar(true)
    .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.BOTTOM])
    .onReady((context: NavDestinationContext): void => {
      this.applyParam(context.pathInfo.param as CategoryListParam);
    })
    .onShown(() => {
      this.setStatusBarContentColor();
      this.viewModel.attachIndexListener();
      this.viewModel.init();
      this.viewModel.startTicking();
    })
    .onHidden(() => {
      this.viewModel.aboutToDetach();
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
