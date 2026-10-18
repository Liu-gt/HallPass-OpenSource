/*
 * SPDX-FileCopyrightText: 2026 Liugt
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import { UIContext, UIObserver } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';

/** 点击之后多久内弹出的弹窗算"由这次点击唤起"（超时 = 定时器 / 相位迁移等非点击来源）。 */
const ORIGIN_FRESH_MS: number = 1000;

/** 弹窗缩放锚点（窗口坐标，vp）。 */
export interface DialogOriginPoint {
  x: number;
  y: number;
}

/**
 * 玻璃弹窗的"出生点"：记录最近一次点击的窗口坐标，弹窗以它为缩放中心长出 / 缩回
 * （iOS 26 风格：从触发按钮处长出并移向最终位置，关闭时缩回去）。
 *
 * 全局只挂一个 willClick 观察者（Index 根页面安装），不侵入各页面的点击回调。
 */
export class DialogOrigin {
  private static observer: UIObserver | null = null;
  private static lastX: number = 0;
  private static lastY: number = 0;
  private static lastMs: number = 0;
  private static readonly onWillClick = (event: ClickEvent): void => {
    DialogOrigin.lastX = event.windowX;
    DialogOrigin.lastY = event.windowY;
    DialogOrigin.lastMs = Date.now();
  };

  static install(uiContext: UIContext): void {
    if (DialogOrigin.observer !== null) {
      return;
    }
    try {
      const observer: UIObserver = uiContext.getUIObserver();
      observer.on('willClick', DialogOrigin.onWillClick);
      DialogOrigin.observer = observer;
    } catch (err) {
      hilog.warn(0x0000, 'DialogOrigin', 'willClick observe failed: %{public}s', String(err));
    }
  }

  static uninstall(): void {
    if (DialogOrigin.observer === null) {
      return;
    }
    try {
      DialogOrigin.observer.off('willClick', DialogOrigin.onWillClick);
    } catch (err) {
      hilog.warn(0x0000, 'DialogOrigin', 'willClick unobserve failed: %{public}s', String(err));
    }
    DialogOrigin.observer = null;
  }

  /** 最近一次点击的窗口坐标（vp）；不够新鲜返回 null（调用方退回屏幕中心）。 */
  static recent(): DialogOriginPoint | null {
    if (DialogOrigin.lastMs === 0 || Date.now() - DialogOrigin.lastMs > ORIGIN_FRESH_MS) {
      return null;
    }
    return { x: DialogOrigin.lastX, y: DialogOrigin.lastY };
  }
}
