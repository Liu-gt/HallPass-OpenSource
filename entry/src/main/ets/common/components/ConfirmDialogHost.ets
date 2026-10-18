/*
 * SPDX-FileCopyrightText: 2026 Liugt
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import { ConfirmDialogService } from '../../application/ConfirmDialogService';
import { ConfirmDialog } from './ConfirmDialog';

/**
 * 通用确认弹窗的根级宿主：由 Index 渲染在 Navigation 之上，
 * 使 ConfirmDialog 的 scrim 覆盖状态栏与页签栏（含玻璃条带），并阻断选择前的所有交互。
 * 页面不再自行渲染 ConfirmDialog，统一经 ConfirmDialogService.show() 登记。
 */
@ComponentV2
export struct ConfirmDialogHost {
  private service: ConfirmDialogService = ConfirmDialogService.get();

  build() {
    if (this.service.visible) {
      ConfirmDialog({
        title: this.service.title,
        body: this.service.body,
        cancelLabel: this.service.cancelLabel,
        confirmLabel: this.service.confirmLabel,
        onCancel: (): void => {
          this.service.cancel();
        },
        onConfirm: (): void => {
          this.service.confirm();
        }
      })
        .width('100%')
        .height('100%')
        .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    }
  }
}
