/*
 * SPDX-FileCopyrightText: 2026 Liugt
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import { AppButton } from '../../common/components/AppButton';
import { ThemeService, ThemeState } from '../../application/theme/ThemeService';
import { AppInput } from '../../common/components/AppInput';
import { Spacing, Typography, Sizes } from '../../common/design/Tokens';
import { SafeArea } from '../../common/design/SafeArea';
import { UnlockViewModel } from './UnlockViewModel';

/**
 * 应用锁定页（票 16，spec F3/F4）：已登录但锁定时根级条件渲染（非路由页，plan D2）。
 * - 已开启快速解锁：生物识别主按钮（KeyStore 门控读取释放主密钥）+ "使用主密码"次入口；
 * - 连续 5 次失败 / 硬件不可用 / 未开启：仅主密码入口（附回退原因提示）；
 * - 解锁成功转 unlocked，锁定前页面栈由根条件渲染切换保留（spec F4）。
 */
@ComponentV2
export struct UnlockPage {
  /** 品牌色响应源（T24：主题切换经 ThemeState 即时生效）。 */
  private theme: ThemeState = ThemeService.get().state;
  @Local private viewModel: UnlockViewModel = new UnlockViewModel();
  @Local private password: string = '';
  @Local private safeTop: number = 0;
  @Local private safeBottom: number = 0;

  aboutToAppear(): void {
    this.safeTop = SafeArea.top();
    this.safeBottom = SafeArea.bottom();
    this.viewModel.refresh();
  }

  build() {
    Column() {
      Blank().layoutWeight(1)

      SymbolGlyph($r('sys.symbol.lock_shield'))
        .fontSize(Sizes.emptyIcon)
        .fontColor([this.theme.primary])

      Text($r('app.string.EntryAbility_label'))
        .fontSize(Typography.title2.size)
        .lineHeight(Typography.title2.lineHeight)
        .fontWeight(Typography.headline.weight)
        .fontColor($r('app.color.label'))
        .margin({ top: Spacing.md })

      if (!this.viewModel.passwordMode && this.viewModel.fastUnlockAvailable
        && !this.viewModel.fastUnlockHidden) {
        AppButton({
          label: $r('app.string.unlock_biometric'),
          isEnabled: !this.viewModel.busy,
          onTap: (): void => {
            this.viewModel.unlockWithBiometrics();
          }
        })
          .margin({ top: Spacing.xxl })
        Text($r('app.string.unlock_master_entry'))
          .fontSize(Typography.subhead.size)
          .lineHeight(Typography.subhead.lineHeight)
          .fontColor(this.theme.primary)
          .constraintSize({ minHeight: Sizes.touchMin })
          .margin({ top: Spacing.sm })
          .onClick(() => {
            this.viewModel.passwordMode = true;
          })
      } else {
        Column({ space: Spacing.md }) {
          AppInput({
            placeholder: $r('app.string.unlock_password_hint'),
            text: this.password,
            inputType: InputType.Password,
            onChange: (value: string): void => {
              this.password = value;
            }
          })
          AppButton({
            label: $r('app.string.unlock_cta'),
            isEnabled: this.password.length > 0 && !this.viewModel.busy,
            onTap: (): void => {
              this.viewModel.unlockWithMasterPassword(this.password).then((): void => {
                this.password = '';
              });
            }
          })
        }
        .width('100%')
        .margin({ top: Spacing.xxl })
      }

      if (this.viewModel.errorText !== null) {
        Text(this.viewModel.errorText)
          .fontSize(Typography.footnote.size)
          .lineHeight(Typography.footnote.lineHeight)
          .fontColor($r('app.color.danger'))
          .textAlign(TextAlign.Center)
          .margin({ top: Spacing.md })
      }

      Blank().layoutWeight(1)
    }
    .width('100%')
    .height('100%')
    .padding({ left: Spacing.page, right: Spacing.page,
      top: this.safeTop, bottom: this.safeBottom })
    .backgroundColor($r('app.color.system_background'))
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }
}
