/*
 * SPDX-FileCopyrightText: 2026 Liugt
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import { ThemeService, ThemeState } from '../../application/theme/ThemeService';
import { Spacing, Typography, Radius, Shadows, Sizes, Opacity, GroupedList } from '../../common/design/Tokens';
import { Motion } from '../../common/design/Motion';
import { ItemDetailViewModel, strengthSegments, strengthColorToken, maskPassword,
  formatTimestamp, formatFileSize } from './ItemDetailViewModel';
import { CipherView, AttachmentView, FieldView, FieldType2 }
  from '../../application/state/VaultMemoryIndex';
import { AppGroup } from '../../common/components/AppGroup';
import { ConfirmDialogService } from '../../application/ConfirmDialogService';
import { GlassToggle } from '../../common/components/glass/GlassToggle';
import { ServiceLocator } from '../../application/ServiceLocator';
import { SystemBar } from '../../common/design/SystemBar';
import { ItemEditParam } from './ItemEditPage';
import { PasswordHistoryParam } from './PasswordHistoryPage';

type FieldRowAlias = FieldView;

/** 条目详情路由参数（plan §1.2 路由表）：只传条目 ID，数据经 ViewModel 从会话态取。 */
export interface ItemDetailParam {
  cipherId: string;
  backTitle: string;
}

/**
 * 条目详情页（票 18，spec F7/F15/F9）：分区卡片（登录信息/备注/自定义字段/附件/更多），
 * 密码遮蔽/眼睛切换/4 段强度条、TOTP 实时行、附件下载（下载中/离线反馈）、
 * 更多卡（文件夹/更新时间/删除 danger）；安全笔记不渲染登录信息卡，空卡不渲染。
 */
@ComponentV2
export struct ItemDetailPage {
  /** 品牌色响应源（T24：主题切换经 ThemeState 即时生效）。 */
  private theme: ThemeState = ThemeService.get().state;
  @Consumer('navStack') navStack: NavPathStack = new NavPathStack();
  @Local private viewModel: ItemDetailViewModel = new ItemDetailViewModel();
  @Local private cipherId: string = '';
  @Local private backTitle: string = '';
  @Local private toastText: string | null = null;
  @Local private visibleCustomFieldIndexes: number[] = [];
  private toastTimer: number = -1;

  aboutToAppear(): void {
    this.setStatusBarContentColor();
    // navDestination 参数在 onReady 回调注入（Index.PagesMap push 传参，plan §1.2）
  }

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
    if (this.toastTimer !== -1) {
      clearTimeout(this.toastTimer);
      this.toastTimer = -1;
    }
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

  private copy(text: string): void {
    if (text.length === 0) {
      return;
    }
    ServiceLocator.clipboard().copy(text);
    this.showToast($r('app.string.toast_copied'));
  }

  /** 删除二次确认：根级弹窗（覆盖页签栏与状态栏，选择前阻断交互）。 */
  private requestDelete(): void {
    ConfirmDialogService.get().show({
      title: $r('app.string.menu_delete'),
      body: $r('app.string.delete_confirm_body'),
      cancelLabel: $r('app.string.cancel'),
      confirmLabel: $r('app.string.menu_delete'),
      onCancel: (): void => {
      },
      onConfirm: (): void => {
        this.viewModel.softDelete().then((): void => {
          this.navStack.pop();
        });
      }
    });
  }

  /** 从详情页直接进入对应条目的编辑表单。 */
  private openEdit(): void {
    if (this.cipherId.length === 0) {
      return;
    }
    const param: ItemEditParam = {
      cipherId: this.cipherId,
      backTitle: this.viewModel.view?.name ?? this.backTitle
    };
    this.navStack.pushPathByName('ItemEdit', param);
  }

  /** 内容文本的操作菜单；避免常驻复制图标干扰信息层级。 */
  private copyMenu(label: ResourceStr, onCopy: () => void): Array<MenuElement> {
    return [{
      value: label,
      action: (): void => onCopy()
    }];
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

  /** 字段行：图标 + 标签 + 值（layoutWeight 右对齐省略）+ 可选复制按钮。 */
  /** 密码历史入口行（T27，spec F7 更多卡）：仅登录类型且有历史时渲染。 */
  @Builder
  historyEntryRow() {
    Column() {
      Row({ space: Spacing.md }) {
      Text($r('app.string.detail_history'))
        .fontSize(GroupedList.primaryText.size)
        .lineHeight(GroupedList.primaryText.lineHeight)
        .fontColor($r('app.color.label'))
        .layoutWeight(1)
      SymbolGlyph($r('sys.symbol.chevron_right'))
        .fontSize(GroupedList.chevronText.size)
        .fontWeight(FontWeight.Bold)
        .fontColor([$r('app.color.tertiary_label')])
    }
    .width('100%')
    .constraintSize({ minHeight: GroupedList.rowMinHeight })
    .padding({ left: GroupedList.rowHorizontal, right: GroupedList.rowHorizontal,
      top: GroupedList.rowVertical, bottom: GroupedList.rowVertical })
      .onClick(() => {
        if (this.cipherId.length === 0) {
          return;
        }
        const param: PasswordHistoryParam = {
          cipherId: this.cipherId,
          backTitle: this.viewModel.view?.name ?? this.backTitle
        };
        this.navStack.pushPathByName('PasswordHistory', param);
      })
      this.rowDivider()
    }
    .width('100%')
  }

  @Builder
  folderIconRow(label: ResourceStr, value: string) {
    Column() {
      Row({ space: Spacing.md }) {
      Text(label)
        .fontSize(GroupedList.primaryText.size)
        .lineHeight(GroupedList.primaryText.lineHeight)
        .fontColor($r('app.color.label'))
        .flexShrink(0)
      Text(value)
        .fontSize(GroupedList.secondaryText.size)
        .lineHeight(GroupedList.secondaryText.lineHeight)
        .fontColor($r('app.color.secondary_label'))
        .layoutWeight(1)
        .textAlign(TextAlign.End)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
    .constraintSize({ minHeight: GroupedList.rowMinHeight })
    .padding({ left: GroupedList.rowHorizontal, right: GroupedList.rowHorizontal,
      top: GroupedList.rowVertical, bottom: GroupedList.rowVertical })
      this.rowDivider()
    }
    .width('100%')
  }

  @Builder
  fieldRow(label: ResourceStr | string, value: string,
    showCopy: boolean, onCopy: () => void, copyLabel: ResourceStr = $r('app.string.a11y_copy'),
    showDivider: boolean = true) {
    Column() {
      Row({ space: Spacing.md }) {
        Text(label)
          .fontSize(GroupedList.primaryText.size)
          .lineHeight(GroupedList.primaryText.lineHeight)
          .fontColor($r('app.color.label'))
          .flexShrink(0)
        Column() {
          Text(value)
            .fontSize(GroupedList.secondaryText.size)
            .lineHeight(GroupedList.secondaryText.lineHeight)
            .fontColor($r('app.color.secondary_label'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .constraintSize({ maxWidth: '100%' })
            .bindMenu(showCopy && value.length > 0 ? this.copyMenu(copyLabel, onCopy) : [])
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.End)
      }
      .width('100%')
      .constraintSize({ minHeight: GroupedList.rowMinHeight })
      .padding({ left: GroupedList.rowHorizontal, right: GroupedList.rowHorizontal,
        top: GroupedList.rowVertical, bottom: GroupedList.rowVertical })
      if (showDivider) {
        this.rowDivider()
      }
    }
    .width('100%')
  }

  @Builder
  customFieldRow(field: FieldRowAlias, index: number, showDivider: boolean) {
    if (field.type === FieldType2.Text) {
      this.fieldRow(field.name, field.value, field.value.length > 0,
        (): void => this.copy(field.value), $r('app.string.a11y_copy'), showDivider)
    } else if (field.type === FieldType2.Boolean) {
      Column() {
        Row({ space: Spacing.md }) {
          Text(field.name)
            .fontSize(GroupedList.primaryText.size)
            .lineHeight(GroupedList.primaryText.lineHeight)
            .fontColor($r('app.color.label'))
          Blank()
          // 详情页布尔字段只读展示（与 ArkUI 开关的 enabled(false) 语义一致）
          GlassToggle({
            isOn: field.value === 'true',
            isEnabled: false
          })
        }
        .width('100%')
        .constraintSize({ minHeight: GroupedList.rowMinHeight })
        .padding({ left: GroupedList.rowHorizontal, right: GroupedList.rowHorizontal,
          top: GroupedList.rowVertical, bottom: GroupedList.rowVertical })
        if (showDivider) {
          this.rowDivider()
        }
      }
      .width('100%')
    } else if (field.type === FieldType2.Linked) {
      this.fieldRow(field.name, field.linkedId === 101
        ? getContext(this).resourceManager.getStringSync($r('app.string.detail_password'))
        : getContext(this).resourceManager.getStringSync($r('app.string.detail_username')),
      false, (): void => {}, $r('app.string.a11y_copy'), showDivider)
    } else {
      this.hiddenCustomFieldRow(field, index, showDivider)
    }
  }

  @Builder
  hiddenCustomFieldRow(field: FieldRowAlias, index: number, showDivider: boolean) {
    Column() {
      Row({ space: Spacing.md }) {
        Text(field.name)
          .fontSize(GroupedList.primaryText.size)
          .lineHeight(GroupedList.primaryText.lineHeight)
          .fontColor($r('app.color.label'))
          .flexShrink(0)
        Text(this.isCustomFieldVisible(index) ? field.value : maskPassword(field.value))
          .fontSize(GroupedList.secondaryText.size)
          .lineHeight(GroupedList.secondaryText.lineHeight)
          .fontColor($r('app.color.secondary_label'))
          .textAlign(TextAlign.End)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        SymbolGlyph(this.isCustomFieldVisible(index) ? $r('sys.symbol.eye_slash') : $r('sys.symbol.eye'))
          .fontSize(Sizes.rowIcon)
          .fontColor([$r('app.color.secondary_label')])
          .width(Sizes.touchMin)
          .height(Sizes.touchMin)
          .onClick((): void => this.toggleCustomFieldVisibility(index))
          .accessibilityText(this.isCustomFieldVisible(index) ? $r('app.string.a11y_hide_password')
            : $r('app.string.a11y_show_password'))
      }
      .width('100%')
      .constraintSize({ minHeight: GroupedList.rowMinHeight })
      .padding({ left: GroupedList.rowHorizontal, right: GroupedList.rowHorizontal,
        top: GroupedList.rowVertical, bottom: GroupedList.rowVertical })
      if (showDivider) {
        this.rowDivider()
      }
    }
    .width('100%')
  }

  private toggleCustomFieldVisibility(index: number): void {
    if (this.visibleCustomFieldIndexes.indexOf(index) >= 0) {
      this.visibleCustomFieldIndexes = this.visibleCustomFieldIndexes.filter(
        (visibleIndex: number): boolean => visibleIndex !== index);
      return;
    }
    this.visibleCustomFieldIndexes = [...this.visibleCustomFieldIndexes, index];
  }

  private isCustomFieldVisible(index: number): boolean {
    return this.visibleCustomFieldIndexes.indexOf(index) >= 0;
  }

  @Builder
  passwordRow(value: string, showDivider: boolean = true) {
    Column() {
    Row({ space: Spacing.md }) {
      Text($r('app.string.detail_password'))
        .fontSize(GroupedList.primaryText.size)
        .lineHeight(GroupedList.primaryText.lineHeight)
        .fontColor($r('app.color.label'))
      Column() {
        Text(this.viewModel.passwordVisible ? value : maskPassword(value))
          .fontSize(GroupedList.secondaryText.size)
          .lineHeight(GroupedList.secondaryText.lineHeight)
          .fontColor($r('app.color.secondary_label'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .constraintSize({ maxWidth: '100%' })
          .bindMenu(this.copyMenu($r('app.string.swipe_copy_password'), (): void => {
            this.copy(value);
            this.viewModel.touchPasswordUsed();
          }))
          .onTouch((event: TouchEvent) => {
            if (event.type === TouchType.Up && !this.viewModel.passwordVisible) {
              // 先让系统完成 bindMenu 的手势处理；同步重绘会取消首击的菜单弹出。
              setTimeout(() => {
                this.viewModel.revealPassword();
              }, 50);
            }
          })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.End)
    }
    .width('100%')
    .constraintSize({ minHeight: GroupedList.rowMinHeight })
    .padding({ left: GroupedList.rowHorizontal, right: GroupedList.rowHorizontal,
      top: GroupedList.rowVertical, bottom: GroupedList.rowVertical })

    if (showDivider) {
      this.rowDivider()
    }
    }
    .width('100%')
  }

  /** 密码强度作为独立信息项展示，避免与密码文本混在同一行。 */
  @Builder
  passwordStrengthRow(value: string, showDivider: boolean = true) {
    Row({ space: Spacing.md }) {
      Text($r('app.string.detail_password_strength'))
        .fontSize(GroupedList.primaryText.size)
        .lineHeight(GroupedList.primaryText.lineHeight)
        .fontColor($r('app.color.label'))
        .layoutWeight(1)

      // 4 段强度条（段高 Spacing.xs、圆角 Radius.xs）
      Row({ space: Spacing.xs }) {
        ForEach([0, 1, 2, 3], (segment: number) => {
          Column()
            .height(Spacing.xs)
            .layoutWeight(1)
            .borderRadius(Radius.xs)
            .backgroundColor(segment < strengthSegments(value)
              ? strengthColorToken(value) : $r('app.color.separator'))
        }, (segment: number) => segment.toString())
      }
      .width(Sizes.passwordStrengthBar)
    }
    .width('100%')
    .constraintSize({ minHeight: GroupedList.rowMinHeight })
    .padding({ left: GroupedList.rowHorizontal, right: GroupedList.rowHorizontal,
      top: GroupedList.rowVertical, bottom: GroupedList.rowVertical })
    if (showDivider) {
      this.rowDivider()
    }
  }

  /** 仅在当前项之后仍有内容时保留分割线，避免与卡片圆角底边重叠。 */
  private hasFollowingCardValue(item: CipherView, currentIndex: number): boolean {
    const values: string[] = [
      item.card?.cardholderName ?? '',
      item.card?.number ?? '',
      item.card?.brand ?? '',
      `${item.card?.expMonth ?? ''}${item.card?.expYear ?? ''}`,
      item.card?.code ?? ''
    ];
    for (let index = currentIndex + 1; index < values.length; index++) {
      if (values[index].length > 0) {
        return true;
      }
    }
    return false;
  }

  private hasFollowingIdentityValue(item: CipherView, currentIndex: number): boolean {
    const values: string[] = [
      item.identity?.firstName ?? '', item.identity?.middleName ?? '', item.identity?.lastName ?? '',
      item.identity?.company ?? '', item.identity?.email ?? '', item.identity?.phone ?? '',
      item.identity?.ssn ?? '', item.identity?.passportNumber ?? '', item.identity?.licenseNumber ?? '',
      `${item.identity?.address1 ?? ''}${item.identity?.address2 ?? ''}${item.identity?.address3 ?? ''}`,
      item.identity?.city ?? '', item.identity?.state ?? '', item.identity?.postalCode ?? '',
      item.identity?.country ?? ''
    ];
    for (let index = currentIndex + 1; index < values.length; index++) {
      if (values[index].length > 0) {
        return true;
      }
    }
    return false;
  }

  /** 银行卡（type 3）详情区块：非空字段逐行展示（DIAG-02 收口）。 */
  @Builder
  cardSection(item: CipherView) {
    AppGroup({ title: $r('app.string.filter_card') }) {
      if (item.card !== null) {
        if ((item.card?.cardholderName ?? '').length > 0) {
          this.fieldRow($r('app.string.detail_card_holder'), item.card?.cardholderName ?? '', true,
            (): void => this.copy(item.card?.cardholderName ?? ''), $r('app.string.a11y_copy'),
            this.hasFollowingCardValue(item, 0))
        }
        if ((item.card?.number ?? '').length > 0) {
          this.fieldRow($r('app.string.detail_card_number'), item.card?.number ?? '', true,
            (): void => this.copy(item.card?.number ?? ''), $r('app.string.a11y_copy'),
            this.hasFollowingCardValue(item, 1))
        }
        if ((item.card?.brand ?? '').length > 0) {
          this.fieldRow($r('app.string.detail_card_brand'), item.card?.brand ?? '', false,
            (): void => undefined, $r('app.string.a11y_copy'), this.hasFollowingCardValue(item, 2))
        }
        if ((item.card?.expMonth ?? '').length > 0 || (item.card?.expYear ?? '').length > 0) {
          this.fieldRow($r('app.string.detail_card_expiry'),
            `${item.card?.expMonth ?? ''}/${item.card?.expYear ?? ''}`, false,
            (): void => undefined, $r('app.string.a11y_copy'), this.hasFollowingCardValue(item, 3))
        }
        if ((item.card?.code ?? '').length > 0) {
          this.fieldRow($r('app.string.detail_card_code'), item.card?.code ?? '', true,
            (): void => this.copy(item.card?.code ?? ''), $r('app.string.a11y_copy'),
            this.hasFollowingCardValue(item, 4))
        }
      }
    }
  }

  /** 身份（type 4）详情区块：非空字段逐行展示；地址行合并 address1-3。 */
  @Builder
  identitySection(item: CipherView) {
    AppGroup({ title: $r('app.string.filter_identity') }) {
      if (item.identity !== null) {
        if ((item.identity?.firstName ?? '').length > 0) {
          this.fieldRow($r('app.string.detail_id_first_name'), item.identity?.firstName ?? '', false,
            (): void => undefined, $r('app.string.a11y_copy'), this.hasFollowingIdentityValue(item, 0))
        }
        if ((item.identity?.middleName ?? '').length > 0) {
          this.fieldRow($r('app.string.detail_id_middle_name'), item.identity?.middleName ?? '', false,
            (): void => undefined, $r('app.string.a11y_copy'), this.hasFollowingIdentityValue(item, 1))
        }
        if ((item.identity?.lastName ?? '').length > 0) {
          this.fieldRow($r('app.string.detail_id_last_name'), item.identity?.lastName ?? '', false,
            (): void => undefined, $r('app.string.a11y_copy'), this.hasFollowingIdentityValue(item, 2))
        }
        if ((item.identity?.company ?? '').length > 0) {
          this.fieldRow($r('app.string.detail_id_company'), item.identity?.company ?? '', false,
            (): void => undefined, $r('app.string.a11y_copy'), this.hasFollowingIdentityValue(item, 3))
        }
        if ((item.identity?.email ?? '').length > 0) {
          this.fieldRow($r('app.string.detail_id_email'), item.identity?.email ?? '', true,
            (): void => this.copy(item.identity?.email ?? ''), $r('app.string.a11y_copy'),
            this.hasFollowingIdentityValue(item, 4))
        }
        if ((item.identity?.phone ?? '').length > 0) {
          this.fieldRow($r('app.string.detail_id_phone'), item.identity?.phone ?? '', true,
            (): void => this.copy(item.identity?.phone ?? ''), $r('app.string.a11y_copy'),
            this.hasFollowingIdentityValue(item, 5))
        }
        if ((item.identity?.ssn ?? '').length > 0) {
          this.fieldRow($r('app.string.detail_id_ssn'), item.identity?.ssn ?? '', true,
            (): void => this.copy(item.identity?.ssn ?? ''), $r('app.string.a11y_copy'),
            this.hasFollowingIdentityValue(item, 6))
        }
        if ((item.identity?.passportNumber ?? '').length > 0) {
          this.fieldRow($r('app.string.detail_id_passport'), item.identity?.passportNumber ?? '', true,
            (): void => this.copy(item.identity?.passportNumber ?? ''), $r('app.string.a11y_copy'),
            this.hasFollowingIdentityValue(item, 7))
        }
        if ((item.identity?.licenseNumber ?? '').length > 0) {
          this.fieldRow($r('app.string.detail_id_license'), item.identity?.licenseNumber ?? '', true,
            (): void => this.copy(item.identity?.licenseNumber ?? ''), $r('app.string.a11y_copy'),
            this.hasFollowingIdentityValue(item, 8))
        }
        if ((item.identity?.address1 ?? '').length > 0 || (item.identity?.address2 ?? '').length > 0
          || (item.identity?.address3 ?? '').length > 0) {
          this.fieldRow($r('app.string.detail_id_address'),
            `${item.identity?.address1 ?? ''} ${item.identity?.address2 ?? ''} ${item.identity?.address3 ?? ''}`
              .trim(), false, (): void => undefined, $r('app.string.a11y_copy'),
              this.hasFollowingIdentityValue(item, 9))
        }
        if ((item.identity?.city ?? '').length > 0) {
          this.fieldRow($r('app.string.detail_id_city'), item.identity?.city ?? '', false,
            (): void => undefined, $r('app.string.a11y_copy'), this.hasFollowingIdentityValue(item, 10))
        }
        if ((item.identity?.state ?? '').length > 0) {
          this.fieldRow($r('app.string.detail_id_state'), item.identity?.state ?? '', false,
            (): void => undefined, $r('app.string.a11y_copy'), this.hasFollowingIdentityValue(item, 11))
        }
        if ((item.identity?.postalCode ?? '').length > 0) {
          this.fieldRow($r('app.string.detail_id_postal'), item.identity?.postalCode ?? '', false,
            (): void => undefined, $r('app.string.a11y_copy'), this.hasFollowingIdentityValue(item, 12))
        }
        if ((item.identity?.country ?? '').length > 0) {
          this.fieldRow($r('app.string.detail_id_country'), item.identity?.country ?? '', false,
            (): void => undefined, $r('app.string.a11y_copy'), this.hasFollowingIdentityValue(item, 13))
        }
      }
    }
  }

  @Builder
  totpRow(item: CipherView, showDivider: boolean = true) {
    Column() {
    Row({ space: Spacing.md }) {
      Text($r('app.string.detail_totp'))
        .fontSize(GroupedList.primaryText.size)
        .lineHeight(GroupedList.primaryText.lineHeight)
        .fontColor($r('app.color.label'))
      Blank()
      Text(this.viewModel.totpCode)
        .fontSize(Typography.headline.size)
        .lineHeight(Typography.headline.lineHeight)
        .fontWeight(Typography.headline.weight)
        .fontColor(this.theme.primary)
        .bindMenu(this.copyMenu($r('app.string.a11y_copy_code'), (): void => {
          this.copy(this.viewModel.totpCode);
        }))
      Progress({ value: this.viewModel.totpRemaining, total: 30, type: ProgressType.Ring })
        .width(Sizes.totpRing)
        .height(Sizes.totpRing)
        .style({ strokeWidth: 2 })
        .color(this.theme.primary)
        .animation({ duration: Motion.durationTotp, curve: Motion.curveLinear })
    }
    .width('100%')
    .constraintSize({ minHeight: GroupedList.rowMinHeight })
    .padding({ left: GroupedList.rowHorizontal, right: GroupedList.rowHorizontal,
      top: GroupedList.rowVertical, bottom: GroupedList.rowVertical })
    if (showDivider) {
      this.rowDivider()
    }
    }
    .width('100%')
  }

  @Builder
  attachmentRow(attachment: AttachmentView, showDivider: boolean = true) {
    Column() {
    Row({ space: Spacing.md }) {
      Column({ space: Spacing.xs }) {
        Text(attachment.fileName)
          .fontSize(GroupedList.primaryText.size)
          .lineHeight(GroupedList.primaryText.lineHeight)
          .fontColor($r('app.color.label'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(formatFileSize(attachment.size))
          .fontSize(Typography.caption1.size)
          .lineHeight(Typography.caption1.lineHeight)
          .fontColor($r('app.color.tertiary_label'))
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Column() {
        SymbolGlyph($r('sys.symbol.arrow_down'))
          .fontSize(Sizes.rowIcon)
          .fontColor([this.theme.primary])
      }
      .width(Sizes.touchMin)
      .height(Sizes.touchMin)
      .justifyContent(FlexAlign.Center)
      .opacity(this.viewModel.downloadingIds.indexOf(attachment.id) >= 0
        ? Opacity.disabled : 1)
      .onClick(() => {
        this.viewModel.downloadAttachment(attachment).then((result: string): void => {
          if (result === 'network') {
            this.showToast($r('app.string.login_error_network'));
          } else if (result === 'ok') {
            this.showToast($r('app.string.detail_download_saved'));
          }
        });
      })
      .accessibilityText($r('app.string.a11y_download'))
    }
    .width('100%')
    .constraintSize({ minHeight: GroupedList.rowMinHeight })
    .padding({ left: GroupedList.rowHorizontal, right: GroupedList.rowHorizontal,
      top: GroupedList.rowVertical, bottom: GroupedList.rowVertical })
    if (showDivider) {
      this.rowDivider()
    }
    }
    .width('100%')
  }

  @Builder
  headerBlock(item: CipherView) {
    Column({ space: Spacing.sm }) {
      Column() {
        Text(item.name.trim().length === 0 ? '?' : item.name.trim().charAt(0).toUpperCase())
          .fontSize(Typography.avatarMonogram.size)
          .lineHeight(Typography.avatarMonogram.lineHeight)
          .fontWeight(Typography.headline.weight)
          .fontColor($r('app.color.on_tint'))
      }
      .width(Sizes.headerAvatar)
      .height(Sizes.headerAvatar)
      .borderRadius(Radius.sm)
      .backgroundColor($r('app.color.avatar_fill'))
      .justifyContent(FlexAlign.Center)
      .margin({ top: Spacing.lg })
      if (item.username.length > 0) {
        Text(item.username)
          .fontSize(Typography.title3.size)
          .lineHeight(Typography.title3.lineHeight)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.label'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Center)
  }

  /** 与二级列表页同款固定头部：返回行 + 大标题（详情页不含搜索栏）。 */
  @Builder
  detailTitleBar() {
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

        // 仅保留 SymbolGlyph；透明无边框热区保证 44vp 点击面积。
        Row({ space: Spacing.xs }) {
          Button() {
            SymbolGlyph(this.viewModel.view?.favorite
              ? $r('sys.symbol.star_fill') : $r('sys.symbol.star'))
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
          .accessibilityText(this.viewModel.view?.favorite
            ? $r('app.string.unfavorite') : $r('app.string.a11y_favorite'))
          .onClick(() => {
            this.viewModel.toggleFavorite();
          })

          Button() {
            SymbolGlyph($r('sys.symbol.highlighter_line'))
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
          .accessibilityText($r('app.string.menu_edit'))
          .onClick(() => {
            this.openEdit();
          })
        }
      }
      .constraintSize({ minHeight: Sizes.touchMin })
      .padding({ left: Spacing.page, right: Spacing.page })

      Column() {
        Text(this.viewModel.view?.name ?? '')
          .fontSize(Typography.largeTitle.size)
          .lineHeight(Typography.largeTitle.lineHeight)
          .fontWeight(Typography.largeTitle.weight)
          .fontColor($r('app.color.label'))
          .width('50%')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
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

  build() {
    NavDestination() {
      Stack() {
        if (this.viewModel.view !== null) {
          Column() {
            this.detailTitleBar()
            Scroll() {
              Column() {
              // Refresh cached builder values on every projection update, not only navigation.
              ForEach([this.viewModel.renderEpoch], (_epoch: number) => {
              Column() {
              if (this.viewModel.view !== null) {
                this.headerBlock(this.viewModel.view)

                if (this.viewModel.view.type === 1) {
                  AppGroup({ title: $r('app.string.detail_login') }) {
                    if ((this.viewModel.view?.username ?? '').length > 0) {
                      this.fieldRow($r('app.string.detail_username'), this.viewModel.view?.username ?? '',
                        true, (): void => this.copy(this.viewModel.view?.username ?? ''),
                        $r('app.string.swipe_copy_username'),
                        (this.viewModel.view?.password.length ?? 0) > 0
                          || (this.viewModel.view?.totpSecret.length ?? 0) > 0
                          || (this.viewModel.view?.uris.length ?? 0) > 0)
                    }
                    if ((this.viewModel.view?.password ?? '').length > 0) {
                      this.passwordRow(this.viewModel.view?.password ?? '', true)
                      this.passwordStrengthRow(this.viewModel.view?.password ?? '',
                        (this.viewModel.view?.totpSecret.length ?? 0) > 0
                          || (this.viewModel.view?.uris.length ?? 0) > 0)
                    }
                    if ((this.viewModel.view?.totpSecret ?? '').length > 0) {
                      this.totpRow(this.viewModel.view as CipherView,
                        (this.viewModel.view?.uris.length ?? 0) > 0)
                    }
                    ForEach(this.viewModel.view?.uris ?? [], (uri: string, index: number) => {
                      this.fieldRow($r('app.string.detail_uri'), uri, true,
                        (): void => this.copy(uri), $r('app.string.a11y_copy'),
                        index < (this.viewModel.view?.uris.length ?? 0) - 1)
                    }, (uri: string) => uri)
                  }
                }

                if (this.viewModel.view.type === 3) {
                  this.cardSection(this.viewModel.view)
                }

                if (this.viewModel.view.type === 4) {
                  this.identitySection(this.viewModel.view)
                }

                if ((this.viewModel.view?.notes ?? '').length > 0) {
                  AppGroup({ title: $r('app.string.detail_note'),
                    contentPadding: GroupedList.cardPadding }) {
                    Text(this.viewModel.view?.notes ?? '')
                      .fontSize(Typography.callout.size)
                      .lineHeight(Typography.callout.lineHeight)
                      .fontColor($r('app.color.secondary_label'))
                      .width('100%')
                  }
                }

                if ((this.viewModel.view?.fields.length ?? 0) > 0) {
                  AppGroup({ title: $r('app.string.detail_fields') }) {
                    ForEach(this.viewModel.view?.fields ?? [], (field: FieldRowAlias,
                      index: number) => {
                      this.customFieldRow(field, index,
                        index < (this.viewModel.view?.fields.length ?? 0) - 1)
                    }, (_field: FieldRowAlias, index: number) => `${index}`)
                  }
                }

                if ((this.viewModel.view?.attachments.length ?? 0) > 0) {
                  AppGroup({ title: $r('app.string.detail_attachments') }) {
                    ForEach(this.viewModel.view?.attachments ?? [],
                      (attachment: AttachmentView, index: number) => {
                        this.attachmentRow(attachment,
                          index < (this.viewModel.view?.attachments.length ?? 0) - 1)
                      }, (attachment: AttachmentView) => attachment.id)
                  }
                }

                AppGroup({ title: $r('app.string.detail_meta') }) {
                  if (this.viewModel.folderName.length > 0) {
                    this.folderIconRow($r('app.string.detail_folder'), this.viewModel.folderName)
                  }
                  this.fieldRow($r('app.string.detail_updated'),
                    formatTimestamp(this.viewModel.view?.revisionDate ?? 0), false,
                    (): void => {
                    })
                  if (this.viewModel.view?.type === 1
                    && (this.viewModel.view?.passwordHistory.length ?? 0) > 0) {
                    this.historyEntryRow()
                  }
                  Text($r('app.string.menu_delete'))
                    .fontSize(Typography.body.size)
                    .lineHeight(Typography.body.lineHeight)
                    .fontColor($r('app.color.danger'))
                    .width('100%')
                    .textAlign(TextAlign.Center)
                    .constraintSize({ minHeight: Sizes.touchMin })
                    .onClick(() => {
                      this.requestDelete();
                    })
                }
              }
              }
              .width('100%')
              .padding({ left: Spacing.page, right: Spacing.page, bottom: Spacing.xxl * 2 })
              }, (_epoch: number) => _epoch.toString())
              }
              .width('100%')
            }
            .scrollBar(BarState.Off)
            .edgeEffect(EdgeEffect.Spring)
            .width('100%')
            .align(Alignment.Top)
            .layoutWeight(1)
          }
          .width('100%')
          .height('100%')
        }

        if (this.toastText !== null) {
          Text(this.toastText)
            .fontSize(Typography.footnote.size)
            .lineHeight(Typography.footnote.lineHeight)
            .fontColor(this.theme.onPrimary)
            .padding({ left: Spacing.lg, right: Spacing.lg, top: Spacing.sm, bottom: Spacing.sm })
            .borderRadius(Radius.xs)
            .backgroundColor($r('app.color.secondary_label'))
        }
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
      // 返回本页即重取投影（fix-07）：遮盖期间（编辑页保存）V2 细粒度更新可能不重绘
      // 遮盖页下的 NavDestination 内容，onShown 强制以最新索引重建视图
      if (this.cipherId.length > 0) {
        this.viewModel.init(this.cipherId);
      }
    })
    .onHidden(() => {
      this.viewModel.passwordVisible = false;
      this.visibleCustomFieldIndexes = [];
    })
    // 确认弹窗可见时吞掉返回手势/返回键（视为取消），避免弹窗悬在已弹出的页面上
    .onBackPressed((): boolean => {
      return ConfirmDialogService.get().handleBack();
    })
  }
}
