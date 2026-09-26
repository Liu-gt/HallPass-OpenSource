/*
 * SPDX-FileCopyrightText: 2026 Liugt
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import { describe, it, expect, beforeAll } from '@ohos/hypium';
import { AppState } from '../main/ets/application/state/AppState';
import { SessionService, SessionSink, VaultContextId } from '../main/ets/application/SessionService';
import { LockService, AutoLockLevel } from '../main/ets/application/LockService';
import { FakePrefs } from './fakes/FakePrefs';
import { FakeKeyStore } from './fakes/FakeKeyStore';
import { FakeRepository } from './fakes/FakeRepository';
import { SymmetricKey } from '../main/ets/domain/crypto/CryptoEngine';
import { Session } from '../main/ets/domain/model/Session';
import { PrefKeys } from '../main/ets/domain/repository/PreferencesStore';
import { KdfParams, KdfType } from '../main/ets/domain/model/VaultContext';
import { Cipher, LoginDetails } from '../main/ets/domain/model/Cipher';
import { EncString } from '../main/ets/domain/model/EncString';
import { ItemType } from '../main/ets/domain/model/ItemType';

/**
 * T10 状态机本地单测（plan R5 单一裁决）：登录→解锁、立即锁定、自动锁定 4 档、
 * 冷启动恢复、登出。窗口/防截屏等真机行为归 audit（NEED_REVIEW）。
 */
class FakeSessionSink implements SessionSink {
  attached: Session[] = [];
  detachedCount: number = 0;

  attachSession(session: Session): void {
    this.attached.push(session);
  }

  detachSession(): void {
    this.detachedCount++;
  }
}

export default function lockFlowTest() {
  describe('LockFlow', () => {

    let prefs: FakePrefs;
    let keyStore: FakeKeyStore;
    let repository: FakeRepository;
    let sink: FakeSessionSink;
    let sessionService: SessionService;
    let lockService: LockService;
    let cleanupCount: number;
    const masterKey: Uint8Array = new Uint8Array(32).fill(0x01);
    const stretched: SymmetricKey = new SymmetricKey(new Uint8Array(32), new Uint8Array(32));

    beforeAll(async () => {
      prefs = new FakePrefs();
      keyStore = new FakeKeyStore();
      repository = new FakeRepository();
      sink = new FakeSessionSink();
      sessionService = new SessionService(prefs, keyStore, sink, repository);
      cleanupCount = 0;
      lockService = new LockService(prefs, (): void => {
        cleanupCount++;
        // 与 AppContainer 生产接线一致：锁定清理含清内存密钥
        sessionService.clearSecrets();
      });
      await lockService.loadAutoLockLevel();
    });

    it('complete_login_transitions_to_unlocked', 0, async () => {
      AppState.get().transitionTo('onboarding');
      await sessionService.completeLogin('vault-1', 'user@example.com',
        'https://vault.example.com', new Session('a', 'r', 3600), masterKey, stretched);
      expect(AppState.get().phase).assertEqual('unlocked');
      expect(sessionService.masterKey() === null).assertFalse();
      expect(sink.attached.length).assertEqual(1);
      const stored: Session | null = await keyStore.readSession();
      expect(stored === null).assertFalse();
      const email: string | null = await prefs.getString(PrefKeys.LAST_EMAIL);
      expect(email).assertEqual('user@example.com');
      expect(VaultContextId.forEmail('user@example.com').length > 0).assertTrue();
    });

    it('immediate_lock_clears_secrets_and_locks', 0, () => {
      lockService.lock();
      expect(AppState.get().phase).assertEqual('locked');
      expect(cleanupCount).assertEqual(1);
      expect(sessionService.masterKey()).assertNull();
      expect(sessionService.stretchedKey()).assertNull();

      lockService.unlock();
      expect(AppState.get().phase).assertEqual('unlocked');
    });

    it('auto_lock_after_timeout_when_configured', 0, () => {
      // 默认 5 分钟：后台 6 分钟后回前台 → 锁定
      lockService.onBackground();
      lockService.onForegroundAt(Date.now() + 6 * 60 * 1000);
      expect(AppState.get().phase).assertEqual('locked');
      lockService.unlock();

      // 短于阈值：不锁定
      lockService.onBackground();
      lockService.onForegroundAt(Date.now() + 60 * 1000);
      expect(AppState.get().phase).assertEqual('unlocked');
    });

    it('auto_lock_never_exempts_background_but_not_cold_start', 0, async () => {
      await lockService.setAutoLockLevel(AutoLockLevel.NEVER);
      lockService.onBackground();
      lockService.onForegroundAt(Date.now() + 10 * 60 * 1000);
      expect(AppState.get().phase).assertEqual('unlocked');
      // 冷启动永远 locked/loggedOut（restoreOnLaunch 裁决，见下一条）
      await lockService.setAutoLockLevel(AutoLockLevel.FIVE_MINUTES);
    });

    it('restore_on_launch_locked_or_onboarding', 0, async () => {
      // 有会话 → locked
      await sessionService.restoreOnLaunch();
      expect(AppState.get().phase).assertEqual('locked');
      expect(sessionService.masterKey()).assertNull();
      // 无会话 → onboarding
      await keyStore.clearSession();
      await sessionService.restoreOnLaunch();
      expect(AppState.get().phase).assertEqual('onboarding');
    });

    it('kdf_cache_written_on_login_params_only', 0, async () => {
      AppState.get().transitionTo('onboarding');
      await sessionService.completeLogin('vault-1', 'kdf@example.com',
        'https://vault.example.com', new Session('a3', 'r3', 3600), masterKey, stretched,
        null, new KdfParams(KdfType.Argon2id, 3, 65536, 4));
      const raw: string | null = await prefs.getString(PrefKeys.LAST_KDF_JSON);
      expect(raw !== null).assertTrue();
      if (raw !== null) {
        // 仅参数、无密钥材料/主密码（T26 安全约束）
        expect(raw.indexOf('masterKey') < 0 && raw.indexOf('password') < 0).assertTrue();
      }
      const cached: KdfParams | null =
        await sessionService.kdfCacheFor('https://vault.example.com', 'kdf@example.com');
      expect(cached !== null).assertTrue();
      if (cached !== null) {
        expect(cached.type).assertEqual(KdfType.Argon2id);
        expect(cached.iterations).assertEqual(3);
        expect(cached.memory).assertEqual(65536);
        expect(cached.parallelism).assertEqual(4);
      }
    });

    it('kdf_cache_dimension_mismatch_returns_null', 0, async () => {
      const otherEmail: KdfParams | null =
        await sessionService.kdfCacheFor('https://vault.example.com', 'other@example.com');
      expect(otherEmail).assertNull();
      const otherServer: KdfParams | null =
        await sessionService.kdfCacheFor('https://other.example.com', 'kdf@example.com');
      expect(otherServer).assertNull();
    });

    it('kdf_cache_survives_lock_unlock', 0, async () => {
      lockService.lock();
      lockService.unlock();
      const cached: KdfParams | null =
        await sessionService.kdfCacheFor('https://vault.example.com', 'kdf@example.com');
      expect(cached !== null).assertTrue();
    });

    it('logout_clears_kdf_cache', 0, async () => {
      await sessionService.logout();
      const cached: KdfParams | null =
        await sessionService.kdfCacheFor('https://vault.example.com', 'kdf@example.com');
      expect(cached).assertNull();
    });

    it('logout_clears_everything', 0, async () => {
      AppState.get().transitionTo('onboarding');
      await sessionService.completeLogin('vault-1', 'user@example.com',
        'https://vault.example.com', new Session('a2', 'r2', 3600), masterKey, stretched);
      await repository.upsertCipher('vault-1', makeBareCipher());
      // sink 为 describe 级共享实例：先清零，仅统计本用例的 detach（前置用例的 restore 已计入）
      sink.detachedCount = 0;
      await sessionService.logout();
      expect(AppState.get().phase).assertEqual('onboarding');
      expect(sessionService.hasSession()).assertFalse();
      const stored: Session | null = await keyStore.readSession();
      expect(stored).assertNull();
      const ciphers = await repository.getAllCiphers('vault-1');
      expect(ciphers.length).assertEqual(0);
      expect(sink.detachedCount).assertEqual(1);
    });
  });
}

function makeBareCipher(): Cipher {
  return new Cipher('c-1', 'vault-1', ItemType.Login, null, 1725500000000, false, null, null,
    [], new LoginDetails(), null, null, null, []);
}
