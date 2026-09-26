/*
 * SPDX-FileCopyrightText: 2026 Liugt
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import { ServiceLocator } from '../../application/ServiceLocator';
import { ShieldEffectService } from '../../application/ShieldEffectService';
import { SymmetricKey } from '../../domain/crypto/CryptoEngine';
import { BiometricType } from '../../domain/biometric/BiometricCapability';
import { KdfParams, KdfType } from '../../domain/model/VaultContext';
import { ProtocolError, ProtocolErrorKind } from '../../domain/protocol/Types';
import { hilog } from '@kit.PerformanceAnalysisKit';
/** 生物识别连续失败上限（spec F3）：达到后隐藏快速解锁入口并回退主密码。 */
const MAX_BIOMETRIC_FAILURES: number = 5;

/**
 * 解锁页 ViewModel（票 16，spec F3）：
 * - 快速解锁：KeyStore 生物识别门控读取主密钥（连续 5 次失败隐藏入口；
 *   硬件不可用/锁屏凭据失效返回 null 自动回退）→ 恢复内存密钥 → 解锁相位；
 * - 主密码解锁：prelogin 取 KDF → 派生 → 恢复密钥 → 解锁相位；
 *   离线主密码解锁受"KDF 参数本地缓存缺失"限制（plan §1.5 白名单未含，
   需修订 plan 后补齐——audit/T16 已记录），离线时提示网络错误可重试。
 * 解锁后 MemoryIndex 重建与 outbox 重放由 SyncService 的解锁事件驱动（票 11）。
 */
@ObservedV2
export class UnlockViewModel {
  @Trace fastUnlockAvailable: boolean = false;
  @Trace fastUnlockHidden: boolean = false;
  @Trace busy: boolean = false;
  @Trace passwordMode: boolean = false;
  @Trace errorText: ResourceStr | null = null;
  private biometricFailures: number = 0;

  async refresh(): Promise<void> {
    const vaultId: string = ServiceLocator.session().state.vaultId;
    // 快速解锁入口由偏好开关决定（v1.4 按模态拆分）：任一方式开启且门控密钥存在才展示
    const settings = ServiceLocator.settings().state;
    if (!settings.fingerprintEnabled && !settings.faceEnabled) {
      this.fastUnlockAvailable = false;
      this.passwordMode = true;
      return;
    }
    try {
      this.fastUnlockAvailable = await ServiceLocator.keyStore().hasFastUnlockKey(vaultId);
    } catch (e) {
      this.fastUnlockAvailable = false;
    }
    this.passwordMode = !this.fastUnlockAvailable;
  }

  /** 认证框提供的生物识别方式：仅已开启的方式，优先方式排前（PIN 由 KeyStore 兜底追加）。 */
  private enabledBiometricTypes(): BiometricType[] {
    const settings = ServiceLocator.settings().state;
    const types: BiometricType[] = [];
    if (settings.preferredBiometric === 'face') {
      if (settings.faceEnabled) {
        types.push('face');
      }
      if (settings.fingerprintEnabled) {
        types.push('fingerprint');
      }
    } else {
      if (settings.fingerprintEnabled) {
        types.push('fingerprint');
      }
      if (settings.faceEnabled) {
        types.push('face');
      }
    }
    return types;
  }

  /** 生物识别快速解锁（弹系统认证框）。 */
  async unlockWithBiometrics(): Promise<void> {
    if (!this.fastUnlockAvailable || this.fastUnlockHidden || this.busy) {
      return;
    }
    this.busy = true;
    this.errorText = null;
    const vaultId: string = ServiceLocator.session().state.vaultId;
    let masterKey: Uint8Array | null = null;
    try {
      masterKey = await ServiceLocator.keyStore().readFastUnlockKey(vaultId,
        this.enabledBiometricTypes());
    } catch (e) {
      masterKey = null;
    }
    if (masterKey === null) {
      this.busy = false;
      this.biometricFailures++;
      if (this.biometricFailures >= MAX_BIOMETRIC_FAILURES) {
        this.fastUnlockHidden = true;
        this.passwordMode = true;
        this.errorText = $r('app.string.unlock_biometric_locked');
      } else {
        this.errorText = $r('app.string.unlock_biometric_fallback');
      }
      return;
    }
    const stretched: SymmetricKey =
      await ServiceLocator.crypto().stretchKeyHkdf(masterKey);
    const ok: boolean = await this.adoptAndUnlock(masterKey, stretched);
    if (!ok) {
      this.errorText = $r('app.string.unlock_biometric_fallback');
      return;
    }
    // 生物识别解锁成功：触发盾牌动效（主密码解锁路径不触发）
    ShieldEffectService.get().play();
  }

  /**
   * 主密码解锁（T26 离线优先）：先读本地 KDF 参数缓存（plan §1.5 lastKdfJson，
   * "服务器+邮箱"维度）——命中则免 prelogin 离线派生；未命中回退在线取参（成功后回写
   * 刷新缓存），离线未命中提示需联网一次（可重试）。
   */
  async unlockWithMasterPassword(password: string): Promise<void> {
    if (password.length === 0 || this.busy) {
      return;
    }
    this.busy = true;
    this.errorText = null;
    const email: string = ServiceLocator.session().state.email;
    const serverUrl: string = ServiceLocator.session().state.serverUrl;
    const cached: KdfParams | null =
      await ServiceLocator.session().kdfCacheFor(serverUrl, email);
    let kdf: KdfParams;
    if (cached !== null) {
      kdf = cached;
    } else {
      try {
        const prelogin = await ServiceLocator.client().prelogin(email);
        kdf = prelogin.kdfType === KdfType.Argon2id
          ? new KdfParams(KdfType.Argon2id, prelogin.iterations ?? 3,
            prelogin.memory ?? 65536, prelogin.parallelism ?? 4)
          : new KdfParams(KdfType.Pbkdf2, prelogin.iterations ?? 600000);
        // 在线取参成功 → 回写刷新缓存（T26，失败不阻塞解锁）
        await ServiceLocator.session().saveKdfCache(serverUrl, email, kdf);
      } catch (e) {
        this.busy = false;
        if (e instanceof ProtocolError && (e as ProtocolError).kind === ProtocolErrorKind.Network) {
          this.errorText = $r('app.string.login_error_network');
        } else {
          this.errorText = $r('app.string.login_error_credentials');
        }
        return;
      }
    }
    let masterKey: Uint8Array;
    let stretched: SymmetricKey;
    try {
      masterKey = await ServiceLocator.crypto().deriveMasterKey(email, password, kdf);
      stretched = await ServiceLocator.crypto().stretchKeyHkdf(masterKey);
    } catch (e) {
      this.busy = false;
      this.errorText = $r('app.string.login_error_credentials');
      return;
    }
    const ok: boolean = await this.adoptAndUnlock(masterKey, stretched);
    this.busy = false;
    if (!ok) {
      // 主密码不匹配（用户密钥 MAC 校验失败）：不进入主界面
      this.errorText = $r('app.string.login_error_credentials');
    }
  }

  /**
   * 恢复密钥并解锁（fix-06 + T26）：以拉伸密钥解开会话内的服务器用户密钥再恢复；
   * 有服务器密钥但解包失败（主密码不匹配/会话损坏）返回 false，调用方拒绝解锁。
   */
  private async adoptAndUnlock(masterKey: Uint8Array, stretched: SymmetricKey):
    Promise<boolean> {
    const wrapped: string | null = ServiceLocator.session().protectedUserKey();
    let userKey: SymmetricKey | null = null;
    if (wrapped !== null) {
      try {
        userKey = await ServiceLocator.crypto().unwrapUserKey(wrapped, stretched);
      } catch (e) {
        const err: Error = e as Error;
        hilog.error(0x0000, 'HallPassUnlock', 'user key unwrap fail %{public}s: %{public}s',
          err.name ?? 'unknown', err.message ?? '');
        return false;
      }
    }
    this.passwordMode = false;
    this.errorText = null;
    ServiceLocator.session().restoreKeys(masterKey, stretched, userKey);
    // 解锁相位 → 根级条件渲染回主界面（锁定前页面栈由 Navigation 保留，spec F4）
    ServiceLocator.sync();
    ServiceLocator.lock().unlock();
    return true;
  }
}
