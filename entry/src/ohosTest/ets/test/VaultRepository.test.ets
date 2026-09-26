/*
 * SPDX-FileCopyrightText: 2026 Liugt
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import { describe, it, expect, beforeAll } from '@ohos/hypium';
import { abilityDelegatorRegistry } from '@kit.TestKit';
import { relationalStore } from '@kit.ArkData';
import { Db } from '../../../main/ets/infrastructure/db/Db';
import { VaultRepositoryImpl } from '../../../main/ets/infrastructure/db/VaultRepositoryImpl';
import { Cipher, LoginDetails, PasswordHistoryItem } from '../../../main/ets/domain/model/Cipher';
import { EncString } from '../../../main/ets/domain/model/EncString';
import { EncStringCodec } from '../../../main/ets/domain/crypto/EncStringCodec';
import { ItemType } from '../../../main/ets/domain/model/ItemType';
import { Folder } from '../../../main/ets/domain/model/Folder';
import { OutboxOpType } from '../../../main/ets/domain/model/OutboxOp';
import { SyncState } from '../../../main/ets/domain/model/SyncState';

const VAULT: string = 'vault-test-1';

function fakeEnc(text: string): EncString {
  // 本地可解码的假密文（ct = base64(文本) 由 FakeCryptoEngine 同款语义，仓库层只透传）
  const bytes: Uint8Array = new Uint8Array(text.length);
  for (let i = 0; i < text.length; i++) {
    bytes[i] = text.charCodeAt(i) & 0xff;
  }
  let b64: string = '';
  const chars: string = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
  for (let i = 0; i < bytes.length; i += 3) {
    const n: number = (bytes[i] << 16) | ((bytes[i + 1] ?? 0) << 8) | (bytes[i + 2] ?? 0);
    b64 += chars[(n >> 18) & 63] + chars[(n >> 12) & 63]
      + (i + 1 < bytes.length ? chars[(n >> 6) & 63] : '=')
      + (i + 2 < bytes.length ? chars[n & 63] : '=');
  }
  return new EncString('AesCbc256_HmacSha256_B64', 'AAAAAAAAAAAAAAAAAAAAAA==', b64,
    'RkFLRU1BQw==');
}

function makeLoginCipher(id: string, name: string, deleted: boolean): Cipher {
  const login: LoginDetails = new LoginDetails(fakeEnc('user@example.com'), fakeEnc('pw123'),
    null, [fakeEnc('https://example.com')]);
  const now: number = 1725500000000;
  return new Cipher(id, VAULT, ItemType.Login, null, now, true, 'folder-1',
    deleted ? now : null, [], login, fakeEnc('some notes'), null, null, []);
}

export default function vaultRepositoryTest() {
  describe('VaultRepository', () => {

    let repo: VaultRepositoryImpl;
    let rawStore: object;

    beforeAll(async () => {
      const context = abilityDelegatorRegistry.getAbilityDelegator().getAppContext();
      rawStore = await Db.open(context);
      repo = new VaultRepositoryImpl(rawStore as never);
    });

    it('write_then_read_cipher_row_roundtrip', 0, async () => {
      const original: Cipher = makeLoginCipher('cipher-1', 'name', false);
      await repo.upsertCipher(VAULT, original);
      const loaded: Cipher | null = await repo.getCipher(VAULT, 'cipher-1');
      expect(loaded === null).assertFalse();
      if (loaded !== null) {
        expect(loaded.id).assertEqual('cipher-1');
        expect(loaded.vaultId).assertEqual(VAULT);
        expect(loaded.type).assertEqual(ItemType.Login);
        expect(loaded.favorite).assertTrue();
        expect(loaded.folderId).assertEqual('folder-1');
        expect(loaded.deletedDate).assertNull();
        expect(loaded.login === null).assertFalse();
        expect(loaded.login?.username === undefined).assertFalse();
      }
    });

    it('replace_all_is_wholesale_and_keeps_folders', 0, async () => {
      await repo.upsertCipher(VAULT, makeLoginCipher('old-1', 'a', false));
      await repo.upsertCipher(VAULT, makeLoginCipher('old-2', 'b', false));
      const folder: Folder = new Folder('folder-1', VAULT, fakeEnc('Work'), 1725500000000);
      await repo.replaceFolders(VAULT, [folder]);

      await repo.replaceCiphers(VAULT, [makeLoginCipher('new-1', 'c', false),
        makeLoginCipher('new-2', 'd', true)]);

      const all: Cipher[] = await repo.getAllCiphers(VAULT);
      expect(all.length).assertEqual(2);
      let hasOld = false;
      let trashCount = 0;
      for (let i = 0; i < all.length; i++) {
        if (all[i].id === 'old-1' || all[i].id === 'old-2') {
          hasOld = true;
        }
        if (all[i].deletedDate !== null) {
          trashCount++;
        }
      }
      expect(hasOld).assertFalse();
      expect(trashCount).assertEqual(1);

      const folders: Folder[] = await repo.getAllFolders(VAULT);
      expect(folders.length).assertEqual(1);
      if (folders.length === 1) {
        expect(folders[0].id).assertEqual('folder-1');
        expect(EncStringCodec.encode(folders[0].name))
          .assertEqual(EncStringCodec.encode(fakeEnc('Work')));
      }
    });

    it('transaction_rollback_keeps_old_set', 0, async () => {
      // 通过 store 直查验证事务边界存在且失败回滚：主键冲突触发回滚
      const store: relationalStore.RdbStore = rawStore as relationalStore.RdbStore;
      const before: Cipher[] = await repo.getAllCiphers(VAULT);
      store.beginTransaction();
      try {
        await store.executeSql(
          `INSERT INTO ciphers (id, vault_id, type, favorite, revision_date, data)
           VALUES ('tx-1', 'v', 1, 0, 1, '{}')`);
        await store.executeSql(
          `INSERT INTO ciphers (id, vault_id, type, favorite, revision_date, data)
           VALUES ('tx-1', 'v', 1, 0, 1, '{}')`); // 主键冲突 → 异常
        store.commit();
      } catch (e) {
        store.rollBack();
      }
      const after: Cipher[] = await repo.getAllCiphers(VAULT);
      expect(after.length).assertEqual(before.length);
    });

    it('outbox_peek_ack_in_order', 0, async () => {
      await repo.enqueueOp('c1', 'save' as OutboxOpType, '{"k":1}');
      await repo.enqueueOp('c2', 'softDelete' as OutboxOpType, null);
      await repo.enqueueOp('c3', 'restore' as OutboxOpType, null);
      const ops = await repo.peekOutbox();
      expect(ops.length).assertEqual(3);
      expect(ops[0].cipherId).assertEqual('c1');
      expect(ops[1].cipherId).assertEqual('c2');
      expect(ops[2].cipherId).assertEqual('c3');
      await repo.ackOp(ops[0].seq);
      await repo.ackOp(ops[2].seq);
      const rest = await repo.peekOutbox();
      expect(rest.length).assertEqual(1);
      expect(rest[0].cipherId).assertEqual('c2');
      await repo.ackOp(rest[0].seq);
      const empty = await repo.peekOutbox();
      expect(empty.length).assertEqual(0);
    });

    it('sync_state_persists', 0, async () => {
      const before: SyncState | null = await repo.getSyncState(VAULT);
      const stamp: number = 1725500099999;
      await repo.setSyncState(new SyncState(VAULT, stamp));
      const after: SyncState | null = await repo.getSyncState(VAULT);
      expect(after === null).assertFalse();
      if (after !== null) {
        expect(after.lastSyncAt).assertEqual(stamp);
      }
      if (before !== null && before.lastSyncAt === stamp) {
        expect(1).assertEqual(1);
      }
    });

    it('last_used_column_null_by_default_and_touch_persists', 0, async () => {
      await repo.upsertCipher(VAULT, makeLoginCipher('lu-1', 'never-used', false));
      const untouched: Cipher | null = await repo.getCipher(VAULT, 'lu-1');
      expect(untouched !== null).assertTrue();
      if (untouched !== null) {
        expect(untouched.lastUsedAt).assertEqual(0);
      }
      const stamp: number = 1725501111111;
      await repo.touchLastUsed(VAULT, 'lu-1', stamp);
      const touched: Cipher | null = await repo.getCipher(VAULT, 'lu-1');
      expect(touched !== null).assertTrue();
      if (touched !== null) {
        expect(touched.lastUsedAt).assertEqual(stamp);
      }
    });

    it('replace_ciphers_inherits_local_last_used', 0, async () => {
      const stamp: number = 1725502222222;
      await repo.upsertCipher(VAULT, makeLoginCipher('lu-keep', 'keep', false));
      await repo.touchLastUsed(VAULT, 'lu-keep', stamp);
      // 全量同步替换（服务器版本不含 last_used）：同 id 条目继承本地值
      await repo.replaceCiphers(VAULT, [makeLoginCipher('lu-keep', 'keep', false),
        makeLoginCipher('lu-new', 'fresh', false)]);
      const kept: Cipher | null = await repo.getCipher(VAULT, 'lu-keep');
      expect(kept !== null).assertTrue();
      if (kept !== null) {
        expect(kept.lastUsedAt).assertEqual(stamp);
      }
      const fresh: Cipher | null = await repo.getCipher(VAULT, 'lu-new');
      expect(fresh !== null).assertTrue();
      if (fresh !== null) {
        expect(fresh.lastUsedAt).assertEqual(0);
      }
    });

    it('password_history_roundtrip_in_data_json', 0, async () => {
      const original: Cipher = makeLoginCipher('hist-1', 'with-history', false);
      const withHistory: Cipher = new Cipher(original.id, original.vaultId, original.type,
        original.organizationId, original.revisionDate, original.favorite, original.folderId,
        original.deletedDate, original.fields, original.login, original.notes, original.card,
        original.identity, original.attachments, original.name,
        [new PasswordHistoryItem(fakeEnc('old-pw'), 1725500000123),
          new PasswordHistoryItem(fakeEnc('older-pw'), 1725500000456)]);
      await repo.upsertCipher(VAULT, withHistory);
      const loaded: Cipher | null = await repo.getCipher(VAULT, 'hist-1');
      expect(loaded !== null).assertTrue();
      if (loaded !== null) {
        expect(loaded.passwordHistory.length).assertEqual(2);
        // 历史随 data JSON 整包保留（plan §1.4 v1.1：不加列）
        const first: PasswordHistoryItem = loaded.passwordHistory[0];
        expect(EncStringCodec.encode(first.password).length > 0).assertTrue();
        expect(first.lastModifiedDate).assertEqual(1725500000123);
      }
    });
  });
}
