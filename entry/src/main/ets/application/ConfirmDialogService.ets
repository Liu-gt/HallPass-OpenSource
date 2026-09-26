/*
 * SPDX-FileCopyrightText: 2026 Liugt
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

/** 确认弹窗请求（页面侧发起，根级宿主渲染；回调在弹窗收起后触发）。 */
export interface ConfirmDialogRequest {
  title: ResourceStr;
  body: ResourceStr;
  cancelLabel: ResourceStr;
  confirmLabel: ResourceStr;
  onCancel: () => void;
  onConfirm: () => void;
}

/**
 * 通用确认弹窗服务（应用内唯一弹窗形态的根级宿主状态）：
 * 页面 show() 登记请求，根组件 Index 渲染的 ConfirmDialogHost 承载卡片 ——
 * scrim 覆盖状态栏与玻璃页签条，选择前阻断所有交互（页内渲染只能压暗页面，
 * 压不到页签栏，且状态栏不在页内扩展范围内）。
 * 相位迁移（锁定/登出）会强制收起：回调闭包属旧页面，解锁后不可复现。
 */
@ObservedV2
export class ConfirmDialogService {
  private static ref: ConfirmDialogService | null = null;

  static get(): ConfirmDialogService {
    if (ConfirmDialogService.ref === null) {
      ConfirmDialogService.ref = new ConfirmDialogService();
    }
    return ConfirmDialogService.ref;
  }

  /** 宿主渲染依据。 */
  @Trace visible: boolean = false;
  @Trace title: ResourceStr = '';
  @Trace body: ResourceStr = '';
  @Trace cancelLabel: ResourceStr = '';
  @Trace confirmLabel: ResourceStr = '';

  private onCancelCb: () => void = (): void => {
  };
  private onConfirmCb: () => void = (): void => {
  };

  show(request: ConfirmDialogRequest): void {
    this.title = request.title;
    this.body = request.body;
    this.cancelLabel = request.cancelLabel;
    this.confirmLabel = request.confirmLabel;
    this.onCancelCb = request.onCancel;
    this.onConfirmCb = request.onConfirm;
    this.visible = true;
  }

  /** 收起且不触发回调（相位迁移等外部原因强制关闭）。 */
  dismiss(): void {
    this.visible = false;
    this.onCancelCb = (): void => {
    };
    this.onConfirmCb = (): void => {
    };
  }

  cancel(): void {
    const callback: () => void = this.onCancelCb;
    this.dismiss();
    callback();
  }

  confirm(): void {
    const callback: () => void = this.onConfirmCb;
    this.dismiss();
    callback();
  }

  /** 返回手势/返回键：弹窗可见时吞掉并视为取消。 */
  handleBack(): boolean {
    if (!this.visible) {
      return false;
    }
    this.cancel();
    return true;
  }
}
