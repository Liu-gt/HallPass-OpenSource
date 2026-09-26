/*
 * SPDX-FileCopyrightText: 2026 Liugt
 * SPDX-License-Identifier: GPL-3.0-or-later
 */


/**
 * 应用全局会话相位（plan D9 跨层服务）：根级条件渲染的唯一数据源（pages/Index.ets）。
 * - onboarding：未登录，显示三步向导；
 * - locked：已登录但锁定，显示 UnlockPage；
 * - unlocked：主界面（三页签 + 路由栈）挂载。
 * 变更约束：只有 SessionService（onboarding↔unlocked）与 LockService（locked↔unlocked）
 * 允许调用 transitionTo()；后续服务只调用、不修改本文件（票 10）。
 */
export type AppPhase = 'onboarding' | 'locked' | 'unlocked' | 'demo';

/** 相位变更监听器（E2E-01 fix-05）：根页面渲染镜像用。 */
export type PhaseListener = (phase: AppPhase) => void;

@ObservedV2
export class AppState {
  private static readonly instance: AppState = new AppState();

  static get(): AppState {
    return AppState.instance;
  }

  @Trace phase: AppPhase = 'onboarding';

  private listeners: PhaseListener[] = [];

  private constructor() {
  }

  /** 相位迁移唯一入口 */
  transitionTo(phase: AppPhase): void {
    this.phase = phase;
    for (let i = 0; i < this.listeners.length; i++) {
      this.listeners[i](phase);
    }
  }

  /** 订阅相位变更（fix-05：根页面经此驱动 @Local 镜像，绕开 @Provider 观测问题）。 */
  addPhaseListener(listener: PhaseListener): void {
    this.listeners.push(listener);
  }

  /** 
   * 修复 HIGH-v2-03：反注册相位变更监听器，消除沙箱退出后的常驻闭包与内存泄露 
   */
  removePhaseListener(listener: PhaseListener): void {
    this.listeners = this.listeners.filter((l: PhaseListener): boolean => l !== listener);
  }

  /**
   * 设置变更信号（T22）：设置页改排序等跨页生效项后广播；订阅方（VaultViewModel）
   * 据此重读偏好。轻量内存信号，不落盘。
   */
  private settingsListeners: PhaseListener[] = [];

  addSettingsListener(listener: PhaseListener): void {
    this.settingsListeners.push(listener);
  }

  removeSettingsListener(listener: PhaseListener): void {
    this.settingsListeners =
      this.settingsListeners.filter((l: PhaseListener): boolean => l !== listener);
  }

  notifySettingsChanged(): void {
    for (let i = 0; i < this.settingsListeners.length; i++) {
      try {
        this.settingsListeners[i](this.phase);
      } catch (e) {
        /* 单个监听器失败不影响其他 */
      }
    }
  }
}
