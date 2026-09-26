/*
 * SPDX-FileCopyrightText: 2026 Liugt
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import { KeyStore } from '../../main/ets/domain/repository/KeyStore';
import { BiometricType } from '../../main/ets/domain/biometric/BiometricCapability';
import { Session } from '../../main/ets/domain/model/Session';

/**
 * FakeKeyStore（T04 测试假实现）：内存版 KeyStore。
 * biometricPass 模拟生物识别认证结果（false → 读取返回 null，驱动回退主密码路径）。
 */
export class FakeKeyStore implements KeyStore {
  biometricPass: boolean = true;
  private fastUnlockKeys: Map<string, Uint8Array> = new Map();
  private autoUnlockKeys: Map<string, Uint8Array> = new Map();
  private session: Session | null = null;

  saveFastUnlockKey(vaultId: string, masterKey: Uint8Array): Promise<void> {
    this.fastUnlockKeys.set(vaultId, masterKey);
    return Promise.resolve();
  }

  readFastUnlockKey(vaultId: string, biometricTypes?: BiometricType[]):
    Promise<Uint8Array | null> {
    if (!this.biometricPass) {
      return Promise.resolve(null);
    }
    const v: Uint8Array | undefined = this.fastUnlockKeys.get(vaultId);
    return Promise.resolve(v === undefined ? null : v);
  }

  hasFastUnlockKey(vaultId: string): Promise<boolean> {
    return Promise.resolve(this.fastUnlockKeys.has(vaultId));
  }

  clearFastUnlockKey(vaultId: string): Promise<void> {
    this.fastUnlockKeys.delete(vaultId);
    return Promise.resolve();
  }

  saveAutoUnlockKey(vaultId: string, masterKey: Uint8Array): Promise<void> {
    this.autoUnlockKeys.set(vaultId, masterKey);
    return Promise.resolve();
  }

  readAutoUnlockKey(vaultId: string): Promise<Uint8Array | null> {
    const v: Uint8Array | undefined = this.autoUnlockKeys.get(vaultId);
    return Promise.resolve(v === undefined ? null : v);
  }

  clearAutoUnlockKey(vaultId: string): Promise<void> {
    this.autoUnlockKeys.delete(vaultId);
    return Promise.resolve();
  }

  saveSession(session: Session): Promise<void> {
    this.session = session;
    return Promise.resolve();
  }

  readSession(): Promise<Session | null> {
    return Promise.resolve(this.session);
  }

  clearSession(): Promise<void> {
    this.session = null;
    return Promise.resolve();
  }
}
