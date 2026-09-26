/*
 * SPDX-FileCopyrightText: 2026 Liugt
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import { FastUnlockPromptService } from '../../application/FastUnlockPromptService';
import { ConfirmDialog } from '../../common/components/ConfirmDialog';

/**
 * 登录后快速解锁开启确认（根级弹窗）：由 Index 渲染，覆盖页签栏与所有页面；
 * 卡片形态与交互统一走 ConfirmDialog（不遮暗背景、阴影区分、选择前阻断其他交互）。
 */
@ComponentV2
export struct FastUnlockPrompt {
  private service: FastUnlockPromptService = FastUnlockPromptService.get();

  build() {
    if (this.service.visible) {
      ConfirmDialog({
        title: $r('app.string.fast_unlock_title'),
        body: $r('app.string.fast_unlock_body'),
        cancelLabel: $r('app.string.fast_unlock_later'),
        confirmLabel: $r('app.string.fast_unlock_enable'),
        confirmEnabled: !this.service.busy,
        cancelEnabled: !this.service.busy,
        errorText: this.service.error === null ? null : this.errorText(),
        onCancel: (): void => {
          this.service.dismiss();
        },
        onConfirm: (): void => {
          this.service.enable();
        }
      })
    }
  }

  private errorText(): ResourceStr {
    return this.service.error === 'verifyFailed'
      ? $r('app.string.fast_unlock_verify_failed')
      : $r('app.string.fast_unlock_failed');
  }
}
