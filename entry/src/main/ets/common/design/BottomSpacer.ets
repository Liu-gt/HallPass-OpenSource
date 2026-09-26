/*
 * SPDX-FileCopyrightText: 2026 Liugt
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import { Sizes, Spacing } from './Tokens';
import { SafeArea } from './SafeArea';

/**
 * 悬浮页签尾部避让占位（plan D8）：高 Sizes.tabBar + Spacing.xl + SafeArea.bottom()。
 * Scroll 与 List 页通用——置于内容末尾，保证滚动到底时最后内容让开悬浮页签。
 * 页签沉浸（走查反馈）：列表视口不做 padding 避让、内容延伸至屏幕底部从页签下方穿过
 * （spec F6 边界情况：禁用视口 padding 方式），尾部净空全部由本占位承担。
 */
@ComponentV2
export struct BottomSpacer {
  build() {
    Column()
      .width('100%')
      .height(Sizes.tabBar + Spacing.xl + SafeArea.bottom())
      .hitTestBehavior(HitTestMode.None)
  }
}
