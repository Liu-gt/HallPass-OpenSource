/*
 * SPDX-FileCopyrightText: 2026 Liugt
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import { PreferencesStore, PrefKeys } from '../domain/repository/PreferencesStore';

/**
 * 剪贴板注入口（application 禁 import @kit 的可测性约定）；
 * infrastructure/clipboard/PasteboardAdapter 实现之（系统 pasteboard）。
 */
export interface ClipboardSink {
  setContent(text: string): Promise<void>;
  getContent(): Promise<string | null>;
  clear(): Promise<void>;
}

/**
 * 剪贴板服务（票 12，spec F12）：统一复制入口 + 30 秒自动清除。
 * - 每次复制重置计时；开启"自动清除"（默认开）后 30 秒清空；
 * - 清除前比对当前内容：期间用户复制了其他内容则不覆盖（spec F12 验收）；
 * - 计时随进程在后台继续（setTimeout 语义）。
 * 可注入 sink + 延迟，本地单测无真机依赖。
 */
export class ClipboardService {
  private readonly sink: ClipboardSink;
  private readonly prefs: PreferencesStore;
  private readonly clearDelayMs: number;
  private clearTimerId: number = -1;
  private lastCopied: string | null = null;

  constructor(sink: ClipboardSink, prefs: PreferencesStore, clearDelayMs: number = 30000) {
    this.sink = sink;
    this.prefs = prefs;
    this.clearDelayMs = clearDelayMs;
  }

  /** 复制入口（列表滑动手势/TOTP 徽标/详情复制按钮/生成器统一调用）；轻提示由 UI 层负责。 */
  async copy(text: string): Promise<void> {
    await this.sink.setContent(text);
    this.lastCopied = text;
    this.cancelTimer();
    const enabled: boolean = (await this.prefs.getBoolean(PrefKeys.CLIPBOARD_AUTO_CLEAR)) ?? true;
    if (!enabled) {
      return;
    }
    this.clearTimerId = setTimeout((): void => {
      this.clearTimerId = -1;
      void this.clearIfUntouched();
    }, this.clearDelayMs);
  }

  /** 锁定/登出时的主动清除入口（可选调用）。 */
  async clearNow(): Promise<void> {
    this.cancelTimer();
    this.lastCopied = null;
    await this.sink.clear();
  }

  private cancelTimer(): void {
    if (this.clearTimerId !== -1) {
      clearTimeout(this.clearTimerId);
      this.clearTimerId = -1;
    }
  }

  private async clearIfUntouched(): Promise<void> {
    try {
      const current: string | null = await this.sink.getContent();
      if (this.lastCopied !== null && current === this.lastCopied) {
        await this.sink.clear();
      }
    } finally {
      this.lastCopied = null;
    }
  }
}
