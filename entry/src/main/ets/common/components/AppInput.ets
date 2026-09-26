/*
 * SPDX-FileCopyrightText: 2026 Liugt
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import { Radius, Typography, Sizes } from '../design/Tokens';

/**
 * 输入框（spec F1/F8）：高 Sizes.control、圆角 Radius.sm、背景 secondary_system_background、
 * 无边框、文字 Typography.body/label、占位 Typography.subhead/tertiary_label。
 */
@ComponentV2
export struct AppInput {
  @Param placeholder: ResourceStr = '';
  @Param text: string = '';
  @Param inputType: InputType = InputType.Normal;
  @Param fieldBg: ResourceStr = $r('app.color.search_field');
  @Event onChange: (value: string) => void = (value: string) => {
  };

  build() {
    TextInput({ text: this.text, placeholder: this.placeholder })
      .type(this.inputType)
      .height(Sizes.control)
      .borderRadius(Radius.sm)
      .backgroundColor(this.fieldBg)
      .fontColor($r('app.color.label'))
      .fontSize(Typography.body.size)
      .fontWeight(Typography.body.weight)
      .placeholderColor($r('app.color.secondary_label'))
      .placeholderFont({ size: Typography.subhead.size, weight: Typography.subhead.weight })
      .showUnderline(false)
      .onChange((value: string) => {
        this.onChange(value);
      })
  }
}
