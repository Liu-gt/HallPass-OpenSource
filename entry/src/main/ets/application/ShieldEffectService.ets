/*
 * SPDX-FileCopyrightText: 2026 Liugt
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

/** 盾牌动效触发监听器（根组件 Index 订阅后挂载覆盖层）。 */
export type ShieldEffectListener = () => void;

/**
 * 盾牌动效触发总线：只在生物识别成功节点播放——
 * ① 登录后引导开启生物认证并验证通过（FastUnlockPromptService）；
 * ② 每次用生物识别快速解锁成功（UnlockViewModel）；
 * ③ 设置页开启指纹/人脸并验证通过（SettingsViewModel）。
 * 相位迁移本身不触发（主密码解锁、首次登录不播放）。
 * 三处入场一致：均自屏幕中心弹出。
 * 注：统一认证控件始终带 PIN 兜底，凭 PIN 通过同样算一次成功（系统不区分模态）。
 */
export class ShieldEffectService {
  private static ref: ShieldEffectService | null = null;

  static get(): ShieldEffectService {
    if (ShieldEffectService.ref === null) {
      ShieldEffectService.ref = new ShieldEffectService();
    }
    return ShieldEffectService.ref;
  }

  private listeners: ShieldEffectListener[] = [];

  addListener(listener: ShieldEffectListener): void {
    this.listeners.push(listener);
  }

  removeListener(listener: ShieldEffectListener): void {
    this.listeners = this.listeners.filter((l: ShieldEffectListener): boolean => l !== listener);
  }

  /** 生物识别成功节点调用（无订阅者时空操作）。 */
  play(): void {
    for (let i = 0; i < this.listeners.length; i++) {
      this.listeners[i]();
    }
  }
}
