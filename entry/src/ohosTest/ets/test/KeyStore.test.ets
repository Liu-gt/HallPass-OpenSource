/*
 * SPDX-FileCopyrightText: 2026 Liugt
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import { describe, it, expect, beforeAll } from '@ohos/hypium';
import { abilityDelegatorRegistry } from '@kit.TestKit';
import { KeyStoreImpl } from '../../../main/ets/infrastructure/asset/KeyStoreImpl';
import { PreferencesStoreImpl } from '../../../main/ets/infrastructure/prefs/PreferencesStoreImpl';
import { Session } from '../../../main/ets/domain/model/Session';
import { PrefKeys } from '../../../main/ets/domain/repository/PreferencesStore';

/**
 * T08 设备端验收（spec F3/F13、plan §1.5）：
 * - 会话令牌 Asset 读写/清除（非门控路径，可自动化）；
 * - 快速解锁密钥存在性/未写入回退（生物识别门控路径弹系统认证框，自动化仅覆盖负路径）；
 * - 偏好读写与 PrefKeys 常量收口。
 */
export default function keyStoreTest() {
  describe('KeyStoreAndPrefs', () => {

    let keyStore: KeyStoreImpl;
    let prefs: PreferencesStoreImpl;

    beforeAll(() => {
      const context = abilityDelegatorRegistry.getAbilityDelegator().getAppContext();
      keyStore = new KeyStoreImpl();
      prefs = new PreferencesStoreImpl(context);
    });

    it('session_token_roundtrip_and_clear', 0, async () => {
      await keyStore.saveSession(new Session('access-1', 'refresh-1', 1725500000000));
      const loaded: Session | null = await keyStore.readSession();
      expect(loaded === null).assertFalse();
      if (loaded !== null) {
        expect(loaded.accessToken).assertEqual('access-1');
        expect(loaded.refreshToken).assertEqual('refresh-1');
        expect(loaded.expiresAt).assertEqual(1725500000000);
      }
      await keyStore.clearSession();
      const cleared: Session | null = await keyStore.readSession();
      expect(cleared).assertNull();
    });

    it('fast_unlock_key_absent_returns_null', 0, async () => {
      const value: Uint8Array | null = await keyStore.readFastUnlockKey('no-such-vault');
      expect(value).assertNull();
      const exists: boolean = await keyStore.hasFastUnlockKey('no-such-vault');
      expect(exists).assertFalse();
    });

    it('fast_unlock_key_save_and_metadata_visible', 0, async () => {
      await keyStore.saveFastUnlockKey('vault-ua-1', new Uint8Array(32).fill(0x0a));
      const exists: boolean = await keyStore.hasFastUnlockKey('vault-ua-1');
      expect(exists).assertTrue();
      // 清理，避免残留影响重复运行
      await keyStore.clearFastUnlockKey('vault-ua-1');
      const existsAfter: boolean = await keyStore.hasFastUnlockKey('vault-ua-1');
      expect(existsAfter).assertFalse();
    });

    it('prefs_roundtrip_all_types', 0, async () => {
      await prefs.setString(PrefKeys.LAST_EMAIL, 'user@example.com');
      await prefs.setBoolean(PrefKeys.CLIPBOARD_AUTO_CLEAR, false);
      await prefs.setNumber(PrefKeys.AUTO_LOCK_LEVEL, 2);
      const email: string | null = await prefs.getString(PrefKeys.LAST_EMAIL);
      const autoClear: boolean | null = await prefs.getBoolean(PrefKeys.CLIPBOARD_AUTO_CLEAR);
      const level: number | null = await prefs.getNumber(PrefKeys.AUTO_LOCK_LEVEL);
      expect(email).assertEqual('user@example.com');
      expect(autoClear).assertFalse();
      expect(level).assertEqual(2);
    });

    it('prefs_missing_key_returns_null', 0, async () => {
      const missing: string | null = await prefs.getString(PrefKeys.LAST_SERVER_URL + '.missing');
      expect(missing).assertNull();
    });
  });
}
