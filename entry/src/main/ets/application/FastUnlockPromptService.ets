/*
 * SPDX-FileCopyrightText: 2026 Liugt
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import { ServiceLocator } from './ServiceLocator';
import { ShieldEffectService } from './ShieldEffectService';

/** 快速解锁开启失败的类别（UI 层映射文案，application 层不直接引资源）。 */
export type FastUnlockError = 'unavailable' | 'verifyFailed';

/**
 * 登录后快速解锁开启确认（一次性提示 → 根级模态卡片）：
 * LoginStep 提交登录前登记 pending（失败撤销），VaultPage 挂载后消费并 show()；
 * 卡片由根组件 Index 渲染（覆盖页签栏与所有页面，选择前阻断其他交互）；
 * 启用逻辑：写门控密钥后当场弹系统认证框验证，通过按设备支持情况落偏好，
 * 未通过清密钥并保留卡片内错误提示（可重试或稍后在设置开启）。
 */
@ObservedV2
export class FastUnlockPromptService {
  private static ref: FastUnlockPromptService | null = null;

  static get(): FastUnlockPromptService {
    if (FastUnlockPromptService.ref === null) {
      FastUnlockPromptService.ref = new FastUnlockPromptService();
    }
    return FastUnlockPromptService.ref;
  }

  /** 卡片可见（根级模态渲染依据）。 */
  @Trace visible: boolean = false;
  /** 验证进行中：按钮禁用，防重复提交。 */
  @Trace busy: boolean = false;
  /** 失败类别（null=无错误）；UI 映射为对应文案。 */
  @Trace error: FastUnlockError | null = null;
  /** 一次性登录信号（仅内存，不落盘）。 */
  private pending: boolean = false;

  /** 登录提交前登记（登录失败由 LoginStep 撤销，避免下次解锁误弹）。 */
  request(): void {
    this.pending = true;
  }

  clearRequest(): void {
    this.pending = false;
  }

  /** 主页挂载时消费登记：消费即清，只有紧随登录后的首次主页挂载拿到 true。 */
  consumeRequest(): boolean {
    const pending: boolean = this.pending;
    this.pending = false;
    return pending;
  }

  show(): void {
    this.error = null;
    this.busy = false;
    this.visible = true;
  }

  dismiss(): void {
    this.visible = false;
    this.error = null;
  }

  /** 开启：写门控密钥 + 当场认证验证；失败保留卡片可重试。 */
  async enable(): Promise<void> {
    const session = ServiceLocator.session();
    const vaultId: string = session.state.vaultId;
    const masterKey: Uint8Array | null = session.masterKey();
    if (masterKey === null || vaultId.length === 0) {
      this.error = 'unavailable';
      return;
    }
    this.busy = true;
    let verified: boolean = false;
    try {
      const keyStore = ServiceLocator.keyStore();
      await keyStore.saveFastUnlockKey(vaultId, masterKey);
      verified = await keyStore.readFastUnlockKey(vaultId) !== null;
    } catch (e) {
      verified = false;
    }
    this.busy = false;
    // 开关状态源=偏好（v1.4 与设置页一致）：验证通过 → 按设备支持情况落"开启"
    // （单模态设备不给不支持的方式留开启值）；未通过清密钥并落"关闭"
    const settings = ServiceLocator.settings();
    const capability = ServiceLocator.biometric();
    settings.setFingerprintEnabled(verified && capability.isSupported('fingerprint'));
    settings.setFaceEnabled(verified && capability.isSupported('face'));
    if (!verified) {
      try {
        await ServiceLocator.keyStore().clearFastUnlockKey(vaultId);
      } catch (e) {
        /* 忽略 */
      }
      this.error = 'verifyFailed';
      return;
    }
    this.dismiss();
    // 引导开启生物认证并验证通过：触发盾牌动效
    ShieldEffectService.get().play();
  }
}
