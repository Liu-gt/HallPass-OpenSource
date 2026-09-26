/*
 * SPDX-FileCopyrightText: 2026 Liugt
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import { AppButton } from '../../common/components/AppButton';
import { ThemeService, ThemeState } from '../../application/theme/ThemeService';
import { AppInput } from '../../common/components/AppInput';
import { Spacing, Typography, Radius, Sizes } from '../../common/design/Tokens';
import { Motion } from '../../common/design/Motion';
import { SafeArea } from '../../common/design/SafeArea';
import { TWO_FACTOR_AUTHENTICATOR, TWO_FACTOR_EMAIL } from '../../domain/protocol/Types';

/**
 * 两步验证子流程（票 15，spec F2）：验证器 TOTP / 邮箱验证码两种提供方选择 + 验证码输入 +
 * 可信设备复选；其余提供方（WebAuthn/Duo/YubiKey，spec §6 不支持）提示到其他客户端处理。
 * 错误与失败计数由父组件（LoginStep）裁决，本组件纯展示 + 事件上报。
 * 布局与登录页对齐：固定 Column（不滚动）、大标题、限宽 520、按钮同一底部位置。
 */
@ComponentV2
export struct TwoFactorStep {
  /** 品牌色响应源（T24：主题切换经 ThemeState 即时生效）。 */
  private theme: ThemeState = ThemeService.get().state;
  @Param providers: number[] = [];
  @Param busy: boolean = false;
  @Event onVerify: (provider: number, code: string, remember: boolean) =>
    Promise<ResourceStr | null> = (_provider: number, _code: string, _remember: boolean):
    Promise<ResourceStr | null> => Promise.resolve(null);
  @Event onBack: () => void = (): void => {
  };
  @Local private selected: number = TWO_FACTOR_AUTHENTICATOR;
  @Local private code: string = '';
  @Local private remember: boolean = false;
  @Local private errorText: ResourceStr | null = null;
  @Local private emailSent: boolean = false;
  private safeTop: number = 0;
  private safeBottom: number = 0;

  aboutToAppear(): void {
    this.safeTop = SafeArea.top();
    this.safeBottom = SafeArea.bottom();
    if (this.providers.indexOf(TWO_FACTOR_AUTHENTICATOR) < 0
      && this.providers.indexOf(TWO_FACTOR_EMAIL) >= 0) {
      this.selected = TWO_FACTOR_EMAIL;
    }
  }

  private has(provider: number): boolean {
    return this.providers.indexOf(provider) >= 0;
  }

  private unsupportedOnly(): boolean {
    return !this.has(TWO_FACTOR_AUTHENTICATOR) && !this.has(TWO_FACTOR_EMAIL);
  }

  private async verify(): Promise<void> {
    if (this.code.length === 0 || this.busy) {
      return;
    }
    const error: ResourceStr | null =
      await this.onVerify(this.selected, this.code, this.remember);
    if (error !== null) {
      this.errorText = error;
    }
  }

  @Builder
  providerChip(title: ResourceStr, provider: number) {
    Row() {
      Text(title)
        .fontSize(Typography.subhead.size)
        .lineHeight(Typography.subhead.lineHeight)
        .fontColor(this.selected === provider ? this.theme.onPrimary
          : $r('app.color.label'))
    }
    .constraintSize({ minHeight: Sizes.chip })
    .padding({ left: Spacing.lg, right: Spacing.lg, top: Spacing.xs, bottom: Spacing.xs })
    .borderRadius(Radius.pill(Sizes.chip))
    .backgroundColor(this.selected === provider ? this.theme.primary
      : $r('app.color.secondary_system_background'))
    .onClick(() => {
      // 切换提供方会增/减「发送验证码」按钮：整段布局位移与选中色一并过渡
      // （不包 animateTo 时下方「记住此设备」直接跳位）
      this.getUIContext().animateTo({ duration: Motion.durationQuick, curve: Motion.curve }, () => {
        this.selected = provider;
        this.errorText = null;
      });
    })
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
          Text($r('app.string.twofactor_title'))
            .fontSize(Typography.largeTitle.size)
            .lineHeight(Typography.largeTitle.lineHeight)
            .fontWeight(Typography.largeTitle.weight)
            .fontColor($r('app.color.label'))
            .margin({ top: this.safeTop + Spacing.xl })

          Text($r('app.string.twofactor_hint'))
            .fontSize(Typography.subhead.size)
            .lineHeight(Typography.subhead.lineHeight)
            .fontColor($r('app.color.secondary_label'))
            .width('100%')
            .textAlign(TextAlign.Start)
            .margin({ top: Spacing.md })

          if (this.unsupportedOnly()) {
            Text($r('app.string.twofactor_other'))
              .fontSize(Typography.footnote.size)
              .lineHeight(Typography.footnote.lineHeight)
              .fontColor($r('app.color.danger'))
              .width('100%')
              .textAlign(TextAlign.Start)
          } else {
            Row({ space: Spacing.sm }) {
              if (this.has(TWO_FACTOR_AUTHENTICATOR)) {
                this.providerChip($r('app.string.twofactor_totp'), TWO_FACTOR_AUTHENTICATOR)
              }
              if (this.has(TWO_FACTOR_EMAIL)) {
                this.providerChip($r('app.string.twofactor_email'), TWO_FACTOR_EMAIL)
              }
            }
            .margin({ top: Spacing.lg })

            AppInput({
              placeholder: $r('app.string.twofactor_code_hint'),
              text: this.code,
              inputType: InputType.Number,
              onChange: (value: string): void => {
                this.code = value;
                this.errorText = null;
              }
            })
              .margin({ top: Spacing.md })

            if (this.selected === TWO_FACTOR_EMAIL) {
              Text(this.emailSent ? $r('app.string.twofactor_email')
                : $r('app.string.twofactor_send_email'))
                .fontSize(Typography.footnote.size)
                .lineHeight(Typography.footnote.lineHeight)
                .fontColor(this.theme.primary)
                .constraintSize({ minHeight: Sizes.touchMin })
                // 随提供方切换渐显/渐隐（与下方布局位移同一时长）
                .transition(TransitionEffect.opacity(0)
                  .animation({ duration: Motion.durationQuick, curve: Motion.curve }))
                .onClick(() => {
                  // 空令牌提交触发服务端发送邮件（Bitwarden 语义）；结果由父组件反馈
                  this.emailSent = true;
                  this.onVerify(TWO_FACTOR_EMAIL, '', false);
                })
            }

            Row({ space: Spacing.sm }) {
              Toggle({ type: ToggleType.Checkbox, isOn: this.remember })
                .selectedColor(this.theme.primary)
                .onChange((isOn: boolean) => {
                  this.remember = isOn;
                })
              Text($r('app.string.twofactor_remember'))
                .fontSize(Typography.subhead.size)
                .lineHeight(Typography.subhead.lineHeight)
                .fontColor($r('app.color.label'))
            }
            .constraintSize({ minHeight: Sizes.touchMin })
            .margin({ top: Spacing.sm })

            if (this.errorText !== null) {
              Text(this.errorText)
                .fontSize(Typography.footnote.size)
                .lineHeight(Typography.footnote.lineHeight)
                .fontColor($r('app.color.danger'))
                .width('100%')
                .textAlign(TextAlign.Start)
            }
          }

          Blank().layoutWeight(1)

          Text($r('app.string.previous_step'))
            .fontSize(Typography.subhead.size)
            .lineHeight(Typography.subhead.lineHeight)
            .fontColor(this.theme.primary)
            .constraintSize({ minHeight: Sizes.touchMin })
            .onClick(() => this.onBack())

          AppButton({
            label: $r('app.string.twofactor_verify'),
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
