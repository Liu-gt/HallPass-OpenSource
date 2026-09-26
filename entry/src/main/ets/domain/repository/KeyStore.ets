/*
 * SPDX-FileCopyrightText: 2026 Liugt
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import { Session } from '../model/Session';
import { BiometricType } from '../biometric/BiometricCapability';

/**
 * 硬件保护密钥存取接口（plan D3/D5，domain 唯一测试 seam 之一）。
 * 实现位于 infrastructure/asset（Asset Store Kit），语义：
 * - 快速解锁密钥：绑定锁屏凭据 + 生物识别门控（spec F3），读取需通过用户认证；
 *   硬件不可用/锁屏凭据被移除/认证失败 → 返回 null，调用方回退主密码（不抛错）。
 * - 会话令牌：非同步型 Asset（不随备份迁移）；锁定不清（会话与密钥生命周期分离，spec F4 边界）。
 * 绝不落盘主密码或可逆主密钥明文到 RDB/Preferences（ADR 安全基线）。
 */
export interface KeyStore {
  /** 写入快速解锁密钥（Asset：RUN_LOCK_SCREEN 类绑定 + ACCESS_BIOMETRIC 门控）。 */
  saveFastUnlockKey(vaultId: string, masterKey: Uint8Array): Promise<void>;

  /**
   * 读取快速解锁密钥：触发生物识别认证，通过则返回原值；biometricTypes 指定认证框
   * 提供的生物识别方式及优先顺序（PIN 锁屏凭据始终追加兜底，不随开关变化）；
   * 省略时提供全部已启用方式。未写入过 / 硬件不可用 / 连续失败 / 锁屏凭据失效 → null。
   */
  readFastUnlockKey(vaultId: string, biometricTypes?: BiometricType[]): Promise<Uint8Array | null>;

  /** 快速解锁密钥是否存在（不触发认证）。 */
  hasFastUnlockKey(vaultId: string): Promise<boolean>;

  /** 清除快速解锁密钥（登出/重录生物识别后失效时调用）。 */
  clearFastUnlockKey(vaultId: string): Promise<void>;

  /**
   * 写入自动会话密钥（"进入应用需解锁"开关关闭时使用）：仅设备锁屏保护、
   * 无用户认证门控，用于冷启动静默恢复密钥（用户显式关闭进入解锁的安全权衡）。
   */
  saveAutoUnlockKey(vaultId: string, masterKey: Uint8Array): Promise<void>;

  /** 读取自动会话密钥（不触发认证；未写入/不可用返回 null）。 */
  readAutoUnlockKey(vaultId: string): Promise<Uint8Array | null>;

  /** 清除自动会话密钥（开关重新开启/登出时调用）。 */
  clearAutoUnlockKey(vaultId: string): Promise<void>;

  /** 会话令牌写入（重启后恢复会话，冷启动仍按锁定态处理）。 */
  saveSession(session: Session): Promise<void>;

  /** 会话令牌读取（无则返回 null）。 */
  readSession(): Promise<Session | null>;

  /** 会话令牌清除（登出/刷新令牌失效）。 */
  clearSession(): Promise<void>;
}
