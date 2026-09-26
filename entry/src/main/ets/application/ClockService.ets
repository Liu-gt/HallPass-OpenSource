/*
 * SPDX-FileCopyrightText: 2026 Liugt
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

/**
 * 全局每秒时钟（票 12，plan D9）：TOTP 倒计时/实时码的唯一 tick 源，
 * 避免多处 setInterval（页面订阅分发）。
 * 零 kit 依赖：定时器在 start() 内使用全局 setInterval；tickOnce 显式注入时钟可测。
 */
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0x0000;
const TAG: string = 'HallPassClock';

export type TickListener = (epochSeconds: number) => void;

@ObservedV2
export class ClockState {
  @Trace epochSeconds: number = 0;
}

export class ClockService {
  readonly state: ClockState = new ClockState();
  private timerId: number = -1;
  private readonly listeners: TickListener[] = [];

  start(): void {
    if (this.timerId !== -1) {
      return;
    }
    this.tickOnce(Math.floor(Date.now() / 1000));
    this.timerId = setInterval((): void => {
      this.tickOnce(Math.floor(Date.now() / 1000));
    }, 1000);
  }

  stop(): void {
    if (this.timerId !== -1) {
      clearInterval(this.timerId);
      this.timerId = -1;
    }
  }

  isRunning(): boolean {
    return this.timerId !== -1;
  }

  /** 显式时钟注入（本地单测用）；真实运行由 setInterval 驱动。 */
  tickOnce(epochSeconds: number): void {
    this.state.epochSeconds = epochSeconds;
    for (let i = 0; i < this.listeners.length; i++) {
      try {
        this.listeners[i](epochSeconds);
      } catch (e) {
        hilog.error(DOMAIN, TAG, 'tick listener failed: %{public}s', JSON.stringify(e));
      }
    }
  }

  addListener(listener: TickListener): void {
    this.listeners.push(listener);
  }

  removeListener(listener: TickListener): void {
    const index: number = this.listeners.indexOf(listener);
    if (index >= 0) {
      this.listeners.splice(index, 1);
    }
  }
}
