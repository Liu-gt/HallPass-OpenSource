/*
 * SPDX-FileCopyrightText: 2026 Liugt
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import { ThemeService, ThemeState } from '../../application/theme/ThemeService';
import { AppButton } from '../../common/components/AppButton';
import { AppGroup } from '../../common/components/AppGroup';
import { GlassToggle } from '../../common/components/glass/GlassToggle';
import { Spacing, Typography, Radius, Sizes, GroupedList } from '../../common/design/Tokens';
import { ItemEditViewModel } from './ItemEditViewModel';
import { DraftField } from '../../application/WriteService';
import { SystemBar } from '../../common/design/SystemBar';
import { ItemType } from '../../domain/model/ItemType';

type DraftFieldAlias = DraftField;

/**
 * 条目编辑路由参数（plan §1.2 路由表）：新建无 cipherId（type 为新建类型），编辑有。
 */
export interface ItemEditParam {
  cipherId?: string;
  type?: string;
  backTitle?: string;
  folderId?: string;
}

const FIELD_TYPE_TEXT: number = 0;
const FIELD_TYPE_HIDDEN: number = 1;
const FIELD_TYPE_BOOLEAN: number = 2;
const FIELD_TYPE_LINKED: number = 3;

/**
 * 条目新建/编辑页（票 19，spec F8）：四类型表单（编辑态锁定类型）、名称必填、
 * 登录/银行卡/身份子表单、备注多行、自定义字段增删、TOTP 保存前校验、
 * 文件夹选择菜单、收藏开关、附件添加（编辑态）、保存（离线入队保留表单）。
 */
@ComponentV2
export struct ItemEditPage {
  /** 品牌色响应源（T24：主题切换经 ThemeState 即时生效）。 */
  private theme: ThemeState = ThemeService.get().state;
  @Consumer('navStack') navStack: NavPathStack = new NavPathStack();
  // F-02: 初始使用瞬态空实例，避免组件构建期提前 acquire 注入僵尸 "new-1" 缓存
  @Local private viewModel: ItemEditViewModel = ItemEditViewModel.createTransient();
  @Local private toastText: string | null = null;
  @Local private backTitle: string = '';
  @Local private showValidationErrors: boolean = false;
  private toastTimer: number = -1;

  aboutToAppear(): void {
    this.setStatusBarContentColor();
  }

  private setStatusBarContentColor(): void {
    SystemBar.apply(this.theme.isDark);
  }

  private onReady(param: object): void {
    const record: Record<string, Object> = (param ?? {}) as Record<string, Object>;
    const cipherIdRaw: Object | undefined = record['cipherId'];
    const typeRaw: Object | undefined = record['type'];
    const backTitleRaw: Object | undefined = record['backTitle'];
    const folderIdRaw: Object | undefined = record['folderId'];
    const cipherId: string | null = typeof cipherIdRaw === 'string'
      ? cipherIdRaw as string : null;
    let type: number | null = null;
    if (typeof typeRaw === 'number') {
      type = typeRaw as number;
    } else if (typeof typeRaw === 'string') {
      type = Number.parseInt(typeRaw as string, 10) || null;
    }
    const folderId: string | null = typeof folderIdRaw === 'string'
      ? folderIdRaw as string : null;
    this.backTitle = typeof backTitleRaw === 'string' ? backTitleRaw as string : '';
    this.viewModel = ItemEditViewModel.acquire(cipherId, type, folderId);
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

  private async save(): Promise<void> {
    this.showValidationErrors = true;
    let result: 'saved' | 'queued' | 'invalid';
    try {
      result = await this.viewModel.save();
    } catch (e) {
      // 保存失败必须可见（fix-07 教训：静默未处理拒绝会让表单"看似已保存"）；
      // 详情走 toast，具体原因在日志（HallPassWrite）
      this.showToast($r('app.string.save_failed'));
      return;
    }
    if (result === 'saved') {
      this.navStack.pop();
      return;
    }
    if (result === 'queued') {
      this.showToast($r('app.string.save_queued'));
      // 表单保留（离线队列重放后收敛），并退回列表
      this.navStack.pop();
      return;
    }
    if (this.viewModel.hasMissingRequiredFields()) {
      // 缺失必填项的提示已内联在对应输入行右侧（红色 hint），不再弹 toast
      return;
    }
    this.showToast($r('app.string.totp_invalid'));
  }

  private pageTitle(): ResourceStr {
    if (!this.viewModel.isNew) {
      return $r('app.string.item_edit_title');
    }
    switch (this.viewModel.draft.type) {
      case ItemType.Login:
        return $r('app.string.item_new_login');
      case ItemType.SecureNote:
        return $r('app.string.item_new_note');
      case ItemType.Card:
        return $r('app.string.item_new_card');
      case ItemType.Identity:
        return $r('app.string.item_new_identity');
      default:
        return $r('app.string.item_new_title');
    }
  }

  @Builder
  sectionTitle(title: ResourceStr) {
    Text(title)
      .fontSize(GroupedList.headerText.size)
      .lineHeight(GroupedList.headerText.lineHeight)
      .fontWeight(FontWeight.Bold)
      .fontColor($r('app.color.secondary_label'))
      .width('100%')
      .padding({ left: GroupedList.headerInset })
      .margin({ top: GroupedList.sectionGap, bottom: GroupedList.headerGap })
  }

  /** 详情页分组容器内的编辑行：左标签、右侧直接编辑值。 */
  @Builder
  editFieldRow(label: ResourceStr, value: string, onChange: (value: string) => void,
    inputType: InputType = InputType.Normal, showDivider: boolean = true,
    placeholder: ResourceStr | null = null) {
    Column() {
      Row({ space: Spacing.md }) {
        Text(label)
          .fontSize(GroupedList.primaryText.size)
          .lineHeight(GroupedList.primaryText.lineHeight)
          .fontColor($r('app.color.secondary_label'))
          .flexShrink(0)
        TextInput({ text: value,
          placeholder: placeholder !== null ? placeholder : '' })
            .placeholderColor(placeholder !== null ? $r('app.color.danger')
              : $r('app.color.tertiary_label'))
            .type(inputType)
            .height(Sizes.touchMin)
            .fontSize(GroupedList.secondaryText.size)
            .fontColor($r('app.color.label'))
            .textAlign(TextAlign.End)
            .backgroundColor(Color.Transparent)
            .showUnderline(false)
            .layoutWeight(1)
            .onChange((next: string): void => onChange(next))
      }
      .width('100%')
      .height(GroupedList.rowMinHeight)
      .padding({ left: GroupedList.rowHorizontal, right: GroupedList.rowHorizontal })
      if (showDivider) {
        Divider()
          .color($r('app.color.separator'))
          .strokeWidth(1)
          .opacity(0.5)
          .margin({ left: GroupedList.rowHorizontal, right: GroupedList.rowHorizontal })
      }
    }
    .width('100%')
  }

  /** Info 组的所属组行：菜单仅附在右侧值和箭头，避免误触编辑名称。 */
  @Builder
  folderPickerRow() {
    Column() {
      Row({ space: Spacing.md }) {
        Text($r('app.string.item_group'))
          .fontSize(GroupedList.primaryText.size)
          .lineHeight(GroupedList.primaryText.lineHeight)
          .fontColor($r('app.color.secondary_label'))
          .flexShrink(0)
        Blank()
        Row({ space: Spacing.xs }) {
          Text(this.viewModel.folderName.length > 0 ? this.viewModel.folderName
            : $r('app.string.folder_none'))
            .fontSize(GroupedList.secondaryText.size)
            .lineHeight(GroupedList.secondaryText.lineHeight)
            .fontColor($r('app.color.secondary_label'))
            .textAlign(TextAlign.End)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          SymbolGlyph($r('sys.symbol.chevron_right'))
            .fontSize(GroupedList.chevronText.size)
            .fontWeight(FontWeight.Bold)
            .fontColor([$r('app.color.tertiary_label')])
        }
        .bindMenu(this.folderMenu())
      }
      .width('100%')
      .height(GroupedList.rowMinHeight)
      .padding({ left: GroupedList.rowHorizontal, right: GroupedList.rowHorizontal })
      Divider()
        .color($r('app.color.separator'))
        .strokeWidth(1)
        .opacity(0.5)
        .margin({ left: GroupedList.rowHorizontal, right: GroupedList.rowHorizontal })
    }
    .width('100%')
  }

  /** Info 组的收藏设置行。 */
  @Builder
  favoriteRow() {
    Row({ space: Spacing.md }) {
      Text($r('app.string.favorite'))
        .fontSize(GroupedList.primaryText.size)
        .lineHeight(GroupedList.primaryText.lineHeight)
        .fontColor($r('app.color.secondary_label'))
        .flexShrink(0)
      Blank()
      // 液态玻璃开关（试验性）：开启后自动替换为 GL 渲染的玻璃开关
      GlassToggle({
        isOn: this.viewModel.draft.favorite,
        onChange: (isOn: boolean): void => {
          this.viewModel.draft.favorite = isOn;
        }
      })
    }
    .width('100%')
    .height(GroupedList.rowMinHeight)
    .padding({ left: GroupedList.rowHorizontal, right: GroupedList.rowHorizontal })
  }

  private folderMenu(): Array<MenuElement> {
    const folders: FolderOption[] = this.viewModel.foldersForPicker();
    const menu: Array<MenuElement> = [];
    for (let index = 0; index < folders.length; index++) {
      const folder: FolderOption = folders[index];
      menu.push({
        value: folder.id.length > 0 ? folder.name : $r('app.string.folder_none'),
        action: (): void => {
          this.viewModel.draft.folderId = folder.id.length > 0 ? folder.id : null;
          this.viewModel.folderName = folder.id.length > 0 ? folder.name : '';
        }
      });
    }
    return menu;
  }

  /** 与二级列表、详情页一致：返回行与大标题共用状态栏背景。 */
  @Builder
  editTitleBar(title: ResourceStr) {
    Column() {
      Row({ space: Spacing.xs }) {
        SymbolGlyph($r('sys.symbol.chevron_left'))
          .fontSize(Sizes.rowIcon)
          .fontColor([this.theme.primary])
        Text(this.backTitle.length > 0 ? this.backTitle : $r('app.string.vault_title'))
          .fontSize(Typography.subhead.size)
          .lineHeight(Typography.subhead.lineHeight)
          .fontColor(this.theme.primary)
      }
      .constraintSize({ minHeight: Sizes.touchMin })
      .padding({ left: Spacing.page, right: Spacing.page })
      .onClick(() => {
        this.navStack.pop();
      })

      Text(title)
        .fontSize(Typography.largeTitle.size)
        .lineHeight(Typography.largeTitle.lineHeight)
        .fontWeight(Typography.largeTitle.weight)
        .fontColor($r('app.color.label'))
        .padding({ left: Spacing.page, right: Spacing.page })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ top: 0, bottom: Spacing.lg })
    .backgroundColor($r('app.color.system_background'))
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP])
  }

  @Builder
  fieldInputs() {
    Column({ space: Spacing.md }) {
      ForEach(this.viewModel.draft.fields, (field: DraftFieldAlias, index: number) => {
        Column() {
          this.editFieldRow($r('app.string.field_key'), field.name,
            (value: string): void => { this.viewModel.draft.fields[index].name = value; },
            InputType.Normal, true,
            this.showValidationErrors && field.name.trim().length === 0
              ? $r('app.string.field_name_required') : null)
          if (field.type === FIELD_TYPE_BOOLEAN) {
            this.booleanFieldValueRow(index)
          } else if (field.type === FIELD_TYPE_LINKED) {
            this.linkedFieldValueRow(index)
          } else {
            this.editFieldRow($r('app.string.field_value'), field.value,
              (value: string): void => { this.viewModel.draft.fields[index].value = value; },
              field.type === FIELD_TYPE_HIDDEN ? InputType.Password : InputType.Normal, false)
          }
          Divider()
            .color($r('app.color.separator'))
            .strokeWidth(1)
            .opacity(0.5)
            .margin({ left: GroupedList.rowHorizontal, right: GroupedList.rowHorizontal })
          Row() {
            Text($r('app.string.menu_delete'))
              .fontSize(Typography.body.size)
              .lineHeight(Typography.body.lineHeight)
              .fontColor($r('app.color.danger'))
              .width('100%')
              .textAlign(TextAlign.Center)
              .constraintSize({ minHeight: Sizes.touchMin })
              .onClick((): void => this.viewModel.removeField(index))
          }
          .width('100%')
        }
        .width('100%')
        .backgroundColor($r('app.color.secondary_system_background'))
        .borderRadius(Radius.md)
      }, (field: DraftFieldAlias, index: number) =>
        `${index}-${field.name}-${this.showValidationErrors ? 'e' : 'n'}`)
    }
    .width('100%')
  }

  @Builder
  booleanFieldValueRow(index: number) {
    Row({ space: Spacing.md }) {
      Text($r('app.string.field_value'))
        .fontSize(GroupedList.primaryText.size)
        .lineHeight(GroupedList.primaryText.lineHeight)
        .fontColor($r('app.color.secondary_label'))
      Blank()
      // 液态玻璃开关（试验性）：开启后自动替换为 GL 渲染的玻璃开关
      GlassToggle({
        isOn: this.viewModel.draft.fields[index].value === 'true',
        onChange: (isOn: boolean): void => {
          this.viewModel.draft.fields[index].value = isOn ? 'true' : 'false';
        }
      })
    }
    .width('100%')
    .height(GroupedList.rowMinHeight)
    .padding({ left: GroupedList.rowHorizontal, right: GroupedList.rowHorizontal })
  }

  @Builder
  linkedFieldValueRow(index: number) {
    Row({ space: Spacing.md }) {
      Text($r('app.string.field_value'))
        .fontSize(GroupedList.primaryText.size)
        .lineHeight(GroupedList.primaryText.lineHeight)
        .fontColor($r('app.color.secondary_label'))
      Blank()
      Row({ space: Spacing.xs }) {
        Text(this.viewModel.draft.fields[index].linkedId === 101
          ? $r('app.string.detail_password') : $r('app.string.detail_username'))
          .fontSize(GroupedList.secondaryText.size)
          .lineHeight(GroupedList.secondaryText.lineHeight)
          .fontColor($r('app.color.secondary_label'))
        SymbolGlyph($r('sys.symbol.chevron_right'))
          .fontSize(GroupedList.chevronText.size)
          .fontColor([$r('app.color.tertiary_label')])
      }
      .bindMenu(this.linkedValueMenu(index))
    }
    .width('100%')
    .height(GroupedList.rowMinHeight)
    .padding({ left: GroupedList.rowHorizontal, right: GroupedList.rowHorizontal })
  }

  private fieldTypeMenu(): Array<MenuElement> {
    return [
      { value: $r('app.string.field_type_text'), action: (): void => this.viewModel.addField(FIELD_TYPE_TEXT) },
      { value: $r('app.string.field_type_hidden'), action: (): void => this.viewModel.addField(FIELD_TYPE_HIDDEN) },
      { value: $r('app.string.field_type_boolean'), action: (): void => this.viewModel.addField(FIELD_TYPE_BOOLEAN) },
      { value: $r('app.string.field_type_linked'), action: (): void => this.viewModel.addField(FIELD_TYPE_LINKED) }
    ];
  }

  private linkedValueMenu(index: number): Array<MenuElement> {
    return [
      { value: $r('app.string.detail_username'), action: (): void => {
        this.viewModel.draft.fields[index].linkedId = 100;
      } },
      { value: $r('app.string.detail_password'), action: (): void => {
        this.viewModel.draft.fields[index].linkedId = 101;
      } }
    ];
  }

  build() {
    NavDestination() {
      Stack({ alignContent: Alignment.Top }) {
        Column() {
          this.editTitleBar(this.pageTitle())
          Scroll() {
          Column() {
            AppGroup({ title: $r('app.string.item_info'), first: true }) {
              this.editFieldRow($r('app.string.item_name'), this.viewModel.draft.name,
                (value: string): void => { this.viewModel.draft.name = value; })
              if (this.showValidationErrors && this.viewModel.draft.name.trim().length === 0) {
                Text($r('app.string.item_name_required'))
                  .fontSize(Typography.footnote.size)
                  .lineHeight(Typography.footnote.lineHeight)
                  .fontColor($r('app.color.danger'))
                  .width('100%')
                  .padding({ left: GroupedList.rowHorizontal, right: GroupedList.rowHorizontal,
                    bottom: Spacing.sm })
              }
              this.folderPickerRow()
              this.favoriteRow()
            }

            if (this.viewModel.draft.type === ItemType.Login) {
              AppGroup({ title: $r('app.string.detail_login') }) {
                this.editFieldRow($r('app.string.detail_username'), this.viewModel.draft.username,
                  (value: string): void => { this.viewModel.draft.username = value; })
                this.editFieldRow($r('app.string.detail_password'), this.viewModel.draft.password,
                  (value: string): void => { this.viewModel.draft.password = value; })
                this.editFieldRow($r('app.string.detail_totp'), this.viewModel.draft.totp,
                  (value: string): void => {
                    this.viewModel.draft.totp = value;
                    this.viewModel.validateTotp();
                  })
                if (this.viewModel.totpError) {
                  Text($r('app.string.totp_invalid'))
                    .fontSize(Typography.footnote.size)
                    .lineHeight(Typography.footnote.lineHeight)
                    .fontColor($r('app.color.danger'))
                    .padding({ left: GroupedList.rowHorizontal, right: GroupedList.rowHorizontal,
                      top: Spacing.xs, bottom: Spacing.sm })
                }
                this.editFieldRow($r('app.string.detail_uri'),
                  this.viewModel.draft.uris.length > 0 ? this.viewModel.draft.uris[0] : '',
                  (value: string): void => {
                    if (this.viewModel.draft.uris.length > 0) {
                      this.viewModel.draft.uris[0] = value;
                    } else if (value.length > 0) {
                      this.viewModel.draft.uris = [value];
                    }
                  }, InputType.Normal, false)
              }
            }

            if (this.viewModel.draft.type === ItemType.Card) {
              AppGroup({ title: $r('app.string.filter_card') }) {
                this.editFieldRow($r('app.string.detail_card_holder'), this.viewModel.draft.cardholderName,
                  (value: string): void => { this.viewModel.draft.cardholderName = value; })
                this.editFieldRow($r('app.string.detail_card_number'), this.viewModel.draft.cardNumber,
                  (value: string): void => { this.viewModel.draft.cardNumber = value; },
                  InputType.Number)
                this.editFieldRow($r('app.string.detail_card_brand'), this.viewModel.draft.brand,
                  (value: string): void => { this.viewModel.draft.brand = value; })
                this.editFieldRow($r('app.string.detail_card_exp_month'), this.viewModel.draft.expMonth,
                  (value: string): void => { this.viewModel.draft.expMonth = value; },
                  InputType.Number)
                this.editFieldRow($r('app.string.detail_card_exp_year'), this.viewModel.draft.expYear,
                  (value: string): void => { this.viewModel.draft.expYear = value; },
                  InputType.Number)
                this.editFieldRow($r('app.string.detail_card_code'), this.viewModel.draft.cardCode,
                  (value: string): void => { this.viewModel.draft.cardCode = value; },
                  InputType.Number, false)
              }
            }

            if (this.viewModel.draft.type === ItemType.Identity) {
              AppGroup({ title: $r('app.string.filter_identity') }) {
                this.editFieldRow($r('app.string.detail_id_first_name'), this.viewModel.draft.firstName,
                  (value: string): void => { this.viewModel.draft.firstName = value; })
                this.editFieldRow($r('app.string.detail_id_middle_name'), this.viewModel.draft.middleName,
                  (value: string): void => { this.viewModel.draft.middleName = value; })
                this.editFieldRow($r('app.string.detail_id_last_name'), this.viewModel.draft.lastName,
                  (value: string): void => { this.viewModel.draft.lastName = value; })
                this.editFieldRow($r('app.string.detail_id_company'), this.viewModel.draft.company,
                  (value: string): void => { this.viewModel.draft.company = value; })
                this.editFieldRow($r('app.string.detail_id_email'), this.viewModel.draft.identityEmail,
                  (value: string): void => { this.viewModel.draft.identityEmail = value; },
                  InputType.Email)
                this.editFieldRow($r('app.string.detail_id_phone'), this.viewModel.draft.phone,
                  (value: string): void => { this.viewModel.draft.phone = value; },
                  InputType.PhoneNumber)
                this.editFieldRow($r('app.string.detail_id_ssn'), this.viewModel.draft.ssn,
                  (value: string): void => { this.viewModel.draft.ssn = value; })
                this.editFieldRow($r('app.string.detail_id_passport'), this.viewModel.draft.passportNumber,
                  (value: string): void => { this.viewModel.draft.passportNumber = value; })
                this.editFieldRow($r('app.string.detail_id_license'), this.viewModel.draft.licenseNumber,
                  (value: string): void => { this.viewModel.draft.licenseNumber = value; })
                this.editFieldRow($r('app.string.detail_id_address'), this.viewModel.draft.address1,
                  (value: string): void => { this.viewModel.draft.address1 = value; })
                this.editFieldRow($r('app.string.detail_id_city'), this.viewModel.draft.city,
                  (value: string): void => { this.viewModel.draft.city = value; })
                this.editFieldRow($r('app.string.detail_id_state'), this.viewModel.draft.state,
                  (value: string): void => { this.viewModel.draft.state = value; })
                this.editFieldRow($r('app.string.detail_id_postal'), this.viewModel.draft.postalCode,
                  (value: string): void => { this.viewModel.draft.postalCode = value; })
                this.editFieldRow($r('app.string.detail_id_country'), this.viewModel.draft.country,
                  (value: string): void => { this.viewModel.draft.country = value; },
                  InputType.Normal, false)
              }
            }

            this.sectionTitle($r('app.string.detail_note'))
            TextArea({ text: this.viewModel.draft.notes,
              placeholder: this.viewModel.draft.notes.length === 0 ? $r('app.string.detail_note') : undefined })
              .placeholderFont({ size: Typography.subhead.size })
              .fontSize(Typography.body.size)
              .borderRadius(Radius.sm)
              .backgroundColor($r('app.color.secondary_system_background'))
              .constraintSize({ minHeight: Sizes.touchMin * 3 })
              .width('100%')
              .onChange((value: string): void => {
                this.viewModel.draft.notes = value;
              })

            this.sectionTitle($r('app.string.detail_fields'))
            this.fieldInputs()
            Text($r('app.string.field_add'))
              .fontSize(Typography.subhead.size)
              .lineHeight(Typography.subhead.lineHeight)
              .fontColor(this.theme.primary)
              .constraintSize({ minHeight: Sizes.touchMin })
              .bindMenu(this.fieldTypeMenu())

            Blank().height(Spacing.xxl)
            AppButton({
              label: $r('app.string.common_save'),
              isEnabled: !this.viewModel.saving,
              onTap: (): void => {
                this.save();
              }
            })
            Blank().height(Spacing.xxl * 2)
          }
          .width('100%')
          .padding({ left: Spacing.page, right: Spacing.page, top: Spacing.sm })
        }
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
        .width('100%')
        .layoutWeight(1)
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
    })
  }
}

interface FolderOption {
  id: string;
  name: string;
}
