/*
 * SPDX-FileCopyrightText: 2026 Liugt
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import { ItemType } from '../domain/model/ItemType';

/** 条目类型选择弹窗请求 */
export interface TypeSelectDialogRequest {
  title?: ResourceStr;
  onSelect: (type: ItemType) => void;
  onCancel?: () => void;
}

/**
 * 条目类型选择弹窗服务（单例状态管理）：
 * 页面侧调用 show() 登记请求，根组件 Index 渲染的 TypeSelectDialogHost 承载卡片 ——
 * scrim 覆盖状态栏与玻璃页签条，阻断下层交互，风格与 ConfirmDialogService 严格对齐。
 */
@ObservedV2
export class TypeSelectDialogService {
  private static ref: TypeSelectDialogService | null = null;

  static get(): TypeSelectDialogService {
    if (TypeSelectDialogService.ref === null) {
      TypeSelectDialogService.ref = new TypeSelectDialogService();
    }
    return TypeSelectDialogService.ref;
  }

  @Trace visible: boolean = false;
  @Trace title: ResourceStr = $r('app.string.dialog_type_title');

  private onSelectCb: (type: ItemType) => void = (): void => {};
  private onCancelCb: () => void = (): void => {};

  /**
   * 退出动画钩子（玻璃弹窗挂载时登记）：dismiss 先交给它播完"缩回 + 淡出"，
   * 播完再真正卸载；未登记（经典弹窗）则立即卸载，走组件自己的 transition。
   */
  private exitAnimator: ((done: () => void) => void) | null = null;
  private closing: boolean = false;

  setExitAnimator(animator: ((done: () => void) => void) | null): void {
    this.exitAnimator = animator;
  }

  /** 卸载弹窗：animated=false 用于相位迁移（锁定 / 登出）等必须立即收起的场合。 */
  private hide(animated: boolean): void {
    if (!this.visible) {
      return;
    }
    const animator: ((done: () => void) => void) | null = animated ? this.exitAnimator : null;
    if (animator === null) {
      this.closing = false;
      this.visible = false;
      return;
    }
    if (this.closing) {
      return;
    }
    this.closing = true;
    animator((): void => {
      if (this.closing) {
        this.closing = false;
        this.visible = false;
      }
    });
  }

  show(request: TypeSelectDialogRequest): void {
    if (this.visible) {
      return; // 防止快速连点重复展示
    }
    // F-05: 唤起弹窗前主动移焦，收起软键盘（IME）避免遮挡弹窗
    focusControl.requestFocus('');

    this.title = request.title ?? $r('app.string.dialog_type_title');
    this.onSelectCb = request.onSelect;
    this.onCancelCb = request.onCancel ?? ((): void => {});
    this.visible = true;
  }

  dismiss(animated: boolean = true): void {
    this.hide(animated);
    this.onSelectCb = (): void => {};
    this.onCancelCb = (): void => {};
  }

  select(type: ItemType): void {
    const callback: (type: ItemType) => void = this.onSelectCb;
    this.dismiss();
    callback(type);
  }

  cancel(): void {
    const callback: () => void = this.onCancelCb;
    this.dismiss();
    callback();
  }

  /** 返回手势/返回键：弹窗可见时吞掉并视为取消 */
  handleBack(): boolean {
    if (!this.visible) {
      return false;
    }
    if (this.closing) {
      return true;
    }
    this.cancel();
    return true;
  }
}
