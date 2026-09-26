/*
 * SPDX-FileCopyrightText: 2026 Liugt
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import { AppButton } from '../../common/components/AppButton';
import { ThemeService, ThemeState } from '../../application/theme/ThemeService';
import { AppInput } from '../../common/components/AppInput';
import { Spacing, Typography, Sizes } from '../../common/design/Tokens';
import { SafeArea } from '../../common/design/SafeArea';

/**
 * 新设备验证步骤（官方云 new device verification）：未知设备首次登录时，服务器已向邮箱
 * 发送验证码（token 请求被拒，error="device_error"），本步收集验证码后由父组件携带
 * NewDeviceOtp 重提交同一 token 请求。验证码错误留在本步重试；不涉及"记住此设备"
 * （验证通过即设备入库，后续登录由持久化的 deviceIdentifier 识别）。错误与主密码
 * 保留由父组件（LoginStep）裁决，本组件纯展示 + 事件上报。
 * 布局与登录页对齐：固定 Column（不滚动）、大标题、限宽 520、按钮同一底部位置。
 */
@ComponentV2
export struct NewDeviceVerificationStep {
  /** 品牌色响应源（T24：主题切换经 ThemeState 即时生效）。 */
  private theme: ThemeState = ThemeService.get().state;
  @Param busy: boolean = false;
  @Param email: string = '';
  @Event onVerify: (code: string) => Promise<ResourceStr | null> =
    (_code: string): Promise<ResourceStr | null> => Promise.resolve(null);
  @Event onBack: () => void = (): void => {
  };
  @Local private code: string = '';
  @Local private errorText: ResourceStr | null = null;
  private safeTop: number = 0;
  private safeBottom: number = 0;

  aboutToAppear(): void {
    this.safeTop = SafeArea.top();
    this.safeBottom = SafeArea.bottom();
  }

  private async verify(): Promise<void> {
    if (this.code.length === 0 || this.busy) {
      return;
    }
    const error: ResourceStr | null = await this.onVerify(this.code);
    if (error !== null) {
      this.errorText = error;
    }
  }

  build() {
    Stack() {
      // 背景必须全不透明：半透明会让下层登录表单文字透出（重影）
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor($r('app.color.system_background'))
      Column() {
        Column() {
          Text($r('app.string.newdevice_title'))
            .fontSize(Typography.largeTitle.size)
            .lineHeight(Typography.largeTitle.lineHeight)
            .fontWeight(Typography.largeTitle.weight)
            .fontColor($r('app.color.label'))
            .margin({ top: this.safeTop + Spacing.xl })

          Text($r('app.string.newdevice_hint'))
            .fontSize(Typography.subhead.size)
            .lineHeight(Typography.subhead.lineHeight)
            .fontColor($r('app.color.secondary_label'))
            .width('100%')
            .textAlign(TextAlign.Start)
            .margin({ top: Spacing.md })

          if (this.email.length > 0) {
            Text(this.email)
              .fontSize(Typography.footnote.size)
              .lineHeight(Typography.footnote.lineHeight)
              .fontColor(this.theme.primary)
              .width('100%')
              .textAlign(TextAlign.Start)
              .margin({ top: Spacing.xs })
          }

          AppInput({
            placeholder: $r('app.string.newdevice_code_hint'),
            text: this.code,
            inputType: InputType.Number,
            onChange: (value: string): void => {
              this.code = value;
              this.errorText = null;
            }
          })
            .margin({ top: Spacing.md })

          if (this.errorText !== null) {
            Text(this.errorText)
              .fontSize(Typography.footnote.size)
              .lineHeight(Typography.footnote.lineHeight)
              .fontColor($r('app.color.danger'))
              .width('100%')
              .textAlign(TextAlign.Start)
          }

          Blank().layoutWeight(1)

          Text($r('app.string.previous_step'))
            .fontSize(Typography.subhead.size)
            .lineHeight(Typography.subhead.lineHeight)
            .fontColor(this.theme.primary)
            .constraintSize({ minHeight: Sizes.touchMin })
            .onClick(() => this.onBack())

          AppButton({
            label: $r('app.string.newdevice_verify'),
            isEnabled: this.code.length > 0 && !this.busy,
            onTap: (): void => {
              this.verify();
            }
          })
            .margin({ top: Spacing.sm })
        }
        .constraintSize({ maxWidth: 520 })
        .width('100%')
        .height('100%')
        .padding({
          left: Spacing.page,
          right: Spacing.page,
          bottom: this.safeBottom + Spacing.xl
        })
      }
      .width('100%')
      .height('100%')
      .alignItems(HorizontalAlign.Center)
    }
    .width('100%')
    .height('100%')
  }
}
