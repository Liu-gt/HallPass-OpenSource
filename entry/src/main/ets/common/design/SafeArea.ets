/*
 * SPDX-FileCopyrightText: 2026 Liugt
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

/**
 * 安全区避让值（票 23 沉浸式修补）：EntryAbility 窗口创建后注入（vp），
 * 页面组件在 aboutToAppear 同步读取。值仅随窗口创建设置一次，无需响应式订阅。
 */
export class SafeArea {
  private static topVp: number = 0;
  private static bottomVp: number = 0;

  /** EntryAbility 调用（px → vp 由调用方换算）。 */
  static update(topVp: number, bottomVp: number): void {
    SafeArea.topVp = topVp;
    SafeArea.bottomVp = bottomVp;
  }

  static top(): number {
    return SafeArea.topVp;
  }

  static bottom(): number {
    return SafeArea.bottomVp;
  }
}
