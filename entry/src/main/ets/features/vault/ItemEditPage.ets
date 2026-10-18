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
import { GlassBandModel } from '../tabs/GlassBandModel';
import { MirrorRouter, MirrorPageEntry } from '../mirror/MirrorRouter';
import { MirroredScroll } from '../mirror/MirroredScroll';

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
 * 条目编辑页的全部可见状态（外壳持有，主树与镜像树同一实例，见 features/mirror/MirrorRouter）。
 */
@ObservedV2
export class ItemEditState {
  // F-02: 初始使用瞬态空实例，避免组件构建期提前 acquire 注入僵尸 "new-1" 缓存（onReady 再换成真实例）
  @Trace viewModel: ItemEditViewModel = ItemEditViewModel.createTransient();
  @Trace toastText: string | null = null;
  @Trace backTitle: string = '';
  @Trace showValidationErrors: boolean = false;
}

/**
 * 条目新建/编辑页内容（票 19，spec F8，主树 / 镜像树共用）：四类型表单（编辑态锁定类型）、名称必填、
 * 登录/银行卡/身份子表单、备注多行、自定义字段增删、TOTP 保存前校验、
 * 文件夹选择菜单、收藏开关、附件添加（编辑态）、保存（离线入队保留表单）。
 * passive = true（镜像树）：只渲染、滚动跟随主树，输入不回写、不响应任何操作。
 */
@ComponentV2
export struct ItemEditContent {
  /** 品牌色响应源（T24：主题切换经 ThemeState 即时生效）。 */
  private theme: ThemeState = ThemeService.get().state;
  @Consumer('navStack') navStack: NavPathStack = new NavPathStack();
  @Require @Param state: ItemEditState;
  @Require @Param band: GlassBandModel;
  @Param passive: boolean = false;
  private toastTimer: number = -1;

  aboutToDisappear(): void {
    if (this.toastTimer !== -1) {
      clearTimeout(this.toastTimer);
      this.toastTimer = -1;
    }
  }

  private showToast(text: ResourceStr): void {
    // Resource 不能直接 toString（产物为 [object Object]）；字符串直用，$r 经资源管理器解析
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

  private async save(): Promise<void> {
    if (this.passive) {
      return;
    }
    this.state.showValidationErrors = true;
    let result: 'saved' | 'queued' | 'invalid';
    try {
      result = await this.state.viewModel.save();
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
    if (this.state.viewModel.hasMissingRequiredFields()) {
      // 缺失必填项的提示已内联在对应输入行右侧（红色 hint），不再弹 toast
      return;
    }
    this.showToast($r('app.string.totp_invalid'));
  }

  private pageTitle(): ResourceStr {
    if (!this.state.viewModel.isNew) {
      return $r('app.string.item_edit_title');
    }
    switch (this.state.viewModel.draft.type) {
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
            // 镜像树里 text 随共享 draft 更新：不得回写（只有主树的输入才写 draft）
            .onChange((next: string): void => {
              if (!this.passive) {
                onChange(next);
              }
            })
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
          Text(this.state.viewModel.folderName.length > 0 ? this.state.viewModel.folderName
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
        isOn: this.state.viewModel.draft.favorite,
        passive: this.passive,
        onChange: (isOn: boolean): void => {
          if (!this.passive) {
            this.state.viewModel.draft.favorite = isOn;
          }
        }
      })
    }
    .width('100%')
    .height(GroupedList.rowMinHeight)
    .padding({ left: GroupedList.rowHorizontal, right: GroupedList.rowHorizontal })
  }

  private folderMenu(): Array<MenuElement> {
    const folders: FolderOption[] = this.state.viewModel.foldersForPicker();
    const menu: Array<MenuElement> = [];
    for (let index = 0; index < folders.length; index++) {
      const folder: FolderOption = folders[index];
      menu.push({
        value: folder.id.length > 0 ? folder.name : $r('app.string.folder_none'),
        action: (): void => {
          this.state.viewModel.draft.folderId = folder.id.length > 0 ? folder.id : null;
          this.state.viewModel.folderName = folder.id.length > 0 ? folder.name : '';
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
        Text(this.state.backTitle.length > 0 ? this.state.backTitle : $r('app.string.vault_title'))
          .fontSize(Typography.subhead.size)
          .lineHeight(Typography.subhead.lineHeight)
          .fontColor(this.theme.primary)
      }
      .constraintSize({ minHeight: Sizes.touchMin })
      .padding({ left: Spacing.page, right: Spacing.page })
      .onClick(() => {
        if (this.passive) {
          return;
        }
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
      ForEach(this.state.viewModel.draft.fields, (field: DraftFieldAlias, index: number) => {
        Column() {
          this.editFieldRow($r('app.string.field_key'), field.name,
            (value: string): void => { this.state.viewModel.draft.fields[index].name = value; },
            InputType.Normal, true,
            this.state.showValidationErrors && field.name.trim().length === 0
              ? $r('app.string.field_name_required') : null)
          if (field.type === FIELD_TYPE_BOOLEAN) {
            this.booleanFieldValueRow(index)
          } else if (field.type === FIELD_TYPE_LINKED) {
            this.linkedFieldValueRow(index)
          } else {
            this.editFieldRow($r('app.string.field_value'), field.value,
              (value: string): void => { this.state.viewModel.draft.fields[index].value = value; },
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
              .onClick((): void => {
                if (!this.passive) {
                  this.state.viewModel.removeField(index);
                }
              })
          }
          .width('100%')
        }
        .width('100%')
        .backgroundColor($r('app.color.secondary_system_background'))
        .borderRadius(Radius.md)
      }, (field: DraftFieldAlias, index: number) =>
        `${index}-${field.name}-${this.state.showValidationErrors ? 'e' : 'n'}`)
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
        isOn: this.state.viewModel.draft.fields[index].value === 'true',
        passive: this.passive,
        onChange: (isOn: boolean): void => {
          if (!this.passive) {
            this.state.viewModel.draft.fields[index].value = isOn ? 'true' : 'false';
          }
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
        Text(this.state.viewModel.draft.fields[index].linkedId === 101
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
      { value: $r('app.string.field_type_text'), action: (): void => this.state.viewModel.addField(FIELD_TYPE_TEXT) },
      { value: $r('app.string.field_type_hidden'), action: (): void => this.state.viewModel.addField(FIELD_TYPE_HIDDEN) },
      { value: $r('app.string.field_type_boolean'), action: (): void => this.state.viewModel.addField(FIELD_TYPE_BOOLEAN) },
      { value: $r('app.string.field_type_linked'), action: (): void => this.state.viewModel.addField(FIELD_TYPE_LINKED) }
    ];
  }

  private linkedValueMenu(index: number): Array<MenuElement> {
    return [
      { value: $r('app.string.detail_username'), action: (): void => {
        this.state.viewModel.draft.fields[index].linkedId = 100;
      } },
      { value: $r('app.string.detail_password'), action: (): void => {
        this.state.viewModel.draft.fields[index].linkedId = 101;
      } }
    ];
  }

  build() {
    Stack({ alignContent: Alignment.Top }) {
      Column() {
        this.editTitleBar(this.pageTitle())
        // 自定义组件尾随闭包后不能再挂属性：外包一层承载 layoutWeight
        Column() {
        MirroredScroll({ band: this.band, passive: this.passive }) {
        Column() {
          AppGroup({ title: $r('app.string.item_info'), first: true }) {
            this.editFieldRow($r('app.string.item_name'), this.state.viewModel.draft.name,
              (value: string): void => { this.state.viewModel.draft.name = value; })
            if (this.state.showValidationErrors && this.state.viewModel.draft.name.trim().length === 0) {
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

          if (this.state.viewModel.draft.type === ItemType.Login) {
            AppGroup({ title: $r('app.string.detail_login') }) {
              this.editFieldRow($r('app.string.detail_username'), this.state.viewModel.draft.username,
                (value: string): void => { this.state.viewModel.draft.username = value; })
              this.editFieldRow($r('app.string.detail_password'), this.state.viewModel.draft.password,
                (value: string): void => { this.state.viewModel.draft.password = value; })
              this.editFieldRow($r('app.string.detail_totp'), this.state.viewModel.draft.totp,
                (value: string): void => {
                  this.state.viewModel.draft.totp = value;
                  this.state.viewModel.validateTotp();
                })
              if (this.state.viewModel.totpError) {
                Text($r('app.string.totp_invalid'))
                  .fontSize(Typography.footnote.size)
                  .lineHeight(Typography.footnote.lineHeight)
                  .fontColor($r('app.color.danger'))
                  .padding({ left: GroupedList.rowHorizontal, right: GroupedList.rowHorizontal,
                    top: Spacing.xs, bottom: Spacing.sm })
              }
              this.editFieldRow($r('app.string.detail_uri'),
                this.state.viewModel.draft.uris.length > 0 ? this.state.viewModel.draft.uris[0] : '',
                (value: string): void => {
                  if (this.state.viewModel.draft.uris.length > 0) {
                    this.state.viewModel.draft.uris[0] = value;
                  } else if (value.length > 0) {
                    this.state.viewModel.draft.uris = [value];
                  }
                }, InputType.Normal, false)
            }
          }

          if (this.state.viewModel.draft.type === ItemType.Card) {
            AppGroup({ title: $r('app.string.filter_card') }) {
              this.editFieldRow($r('app.string.detail_card_holder'), this.state.viewModel.draft.cardholderName,
                (value: string): void => { this.state.viewModel.draft.cardholderName = value; })
              this.editFieldRow($r('app.string.detail_card_number'), this.state.viewModel.draft.cardNumber,
                (value: string): void => { this.state.viewModel.draft.cardNumber = value; },
                InputType.Number)
              this.editFieldRow($r('app.string.detail_card_brand'), this.state.viewModel.draft.brand,
                (value: string): void => { this.state.viewModel.draft.brand = value; })
              this.editFieldRow($r('app.string.detail_card_exp_month'), this.state.viewModel.draft.expMonth,
                (value: string): void => { this.state.viewModel.draft.expMonth = value; },
                InputType.Number)
              this.editFieldRow($r('app.string.detail_card_exp_year'), this.state.viewModel.draft.expYear,
                (value: string): void => { this.state.viewModel.draft.expYear = value; },
                InputType.Number)
              this.editFieldRow($r('app.string.detail_card_code'), this.state.viewModel.draft.cardCode,
                (value: string): void => { this.state.viewModel.draft.cardCode = value; },
                InputType.Number, false)
            }
          }

          if (this.state.viewModel.draft.type === ItemType.Identity) {
            AppGroup({ title: $r('app.string.filter_identity') }) {
              this.editFieldRow($r('app.string.detail_id_first_name'), this.state.viewModel.draft.firstName,
                (value: string): void => { this.state.viewModel.draft.firstName = value; })
              this.editFieldRow($r('app.string.detail_id_middle_name'), this.state.viewModel.draft.middleName,
                (value: string): void => { this.state.viewModel.draft.middleName = value; })
              this.editFieldRow($r('app.string.detail_id_last_name'), this.state.viewModel.draft.lastName,
                (value: string): void => { this.state.viewModel.draft.lastName = value; })
              this.editFieldRow($r('app.string.detail_id_company'), this.state.viewModel.draft.company,
                (value: string): void => { this.state.viewModel.draft.company = value; })
              this.editFieldRow($r('app.string.detail_id_email'), this.state.viewModel.draft.identityEmail,
                (value: string): void => { this.state.viewModel.draft.identityEmail = value; },
                InputType.Email)
              this.editFieldRow($r('app.string.detail_id_phone'), this.state.viewModel.draft.phone,
                (value: string): void => { this.state.viewModel.draft.phone = value; },
                InputType.PhoneNumber)
              this.editFieldRow($r('app.string.detail_id_ssn'), this.state.viewModel.draft.ssn,
                (value: string): void => { this.state.viewModel.draft.ssn = value; })
              this.editFieldRow($r('app.string.detail_id_passport'), this.state.viewModel.draft.passportNumber,
                (value: string): void => { this.state.viewModel.draft.passportNumber = value; })
              this.editFieldRow($r('app.string.detail_id_license'), this.state.viewModel.draft.licenseNumber,
                (value: string): void => { this.state.viewModel.draft.licenseNumber = value; })
              this.editFieldRow($r('app.string.detail_id_address'), this.state.viewModel.draft.address1,
                (value: string): void => { this.state.viewModel.draft.address1 = value; })
              this.editFieldRow($r('app.string.detail_id_city'), this.state.viewModel.draft.city,
                (value: string): void => { this.state.viewModel.draft.city = value; })
              this.editFieldRow($r('app.string.detail_id_state'), this.state.viewModel.draft.state,
                (value: string): void => { this.state.viewModel.draft.state = value; })
              this.editFieldRow($r('app.string.detail_id_postal'), this.state.viewModel.draft.postalCode,
                (value: string): void => { this.state.viewModel.draft.postalCode = value; })
              this.editFieldRow($r('app.string.detail_id_country'), this.state.viewModel.draft.country,
                (value: string): void => { this.state.viewModel.draft.country = value; },
                InputType.Normal, false)
            }
          }

          this.sectionTitle($r('app.string.detail_note'))
          TextArea({ text: this.state.viewModel.draft.notes,
            placeholder: this.state.viewModel.draft.notes.length === 0 ? $r('app.string.detail_note') : undefined })
            .placeholderFont({ size: Typography.subhead.size })
            .fontSize(Typography.body.size)
            .borderRadius(Radius.sm)
            .backgroundColor($r('app.color.secondary_system_background'))
            .constraintSize({ minHeight: Sizes.touchMin * 3 })
            .width('100%')
            .onChange((value: string): void => {
              if (!this.passive) {
                this.state.viewModel.draft.notes = value;
              }
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
            isEnabled: !this.state.viewModel.saving,
            onTap: (): void => {
              this.save();
            }
          })
          Blank().height(Spacing.xxl * 2)
        }
        .width('100%')
        .padding({ left: Spacing.page, right: Spacing.page, top: Spacing.sm })
      }
      }
      .width('100%')
      .layoutWeight(1)
      }
      .width('100%')
      .height('100%')

    if (this.state.toastText !== null) {
      Text(this.state.toastText)
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
    // 镜像布局基准 = 页面盒高度（底边贴屏幕底，见 GlassTabMirror）
    .onAreaChange((_oldValue: Area, newValue: Area): void => {
      if (!this.passive) {
        this.band.reportViewportHeight(Number(newValue.height), Number(newValue.globalPosition.y));
      }
    })
  }
}

@Builder
function itemEditMirrorBuilder(entry: MirrorPageEntry) {
  ItemEditContent({ state: entry.state as ItemEditState, band: entry.band, passive: true })
}

const ITEM_EDIT_MIRROR: WrappedBuilder<[MirrorPageEntry]> = wrapBuilder(itemEditMirrorBuilder);

/**
 * 条目新建/编辑页外壳（NavDestination）：路由参数、VM 获取、镜像登记；内容见 ItemEditContent。
 */
@ComponentV2
export struct ItemEditPage {
  private theme: ThemeState = ThemeService.get().state;
  private state: ItemEditState = new ItemEditState();
  private band: GlassBandModel = new GlassBandModel();
  private mirrorEntry: MirrorPageEntry | null = null;

  aboutToAppear(): void {
    this.setStatusBarContentColor();
    this.mirrorEntry = new MirrorPageEntry('ItemEdit', this.state, this.band, ITEM_EDIT_MIRROR);
  }

  aboutToDisappear(): void {
    if (this.mirrorEntry !== null) {
      MirrorRouter.get().hide(this.mirrorEntry);
    }
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
    this.state.backTitle = typeof backTitleRaw === 'string' ? backTitleRaw as string : '';
    this.state.viewModel = ItemEditViewModel.acquire(cipherId, type, folderId);
  }

  build() {
    NavDestination() {
      ItemEditContent({ state: this.state, band: this.band })
    }
    .hideTitleBar(true)
    .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.BOTTOM])
    .onReady((context: NavDestinationContext): void => {
      this.onReady(context.pathInfo.param as object);
    })
    .onShown(() => {
      this.setStatusBarContentColor();
      if (this.mirrorEntry !== null) {
        MirrorRouter.get().show(this.mirrorEntry);
      }
    })
    .onHidden(() => {
      if (this.mirrorEntry !== null) {
        MirrorRouter.get().hide(this.mirrorEntry);
      }
    })
  }
}

interface FolderOption {
  id: string;
  name: string;
}
