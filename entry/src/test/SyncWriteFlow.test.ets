/*
 * SPDX-FileCopyrightText: 2026 Liugt
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import { describe, it, expect } from '@ohos/hypium';
import { SyncService } from '../main/ets/application/SyncService';
import { WriteService, CipherDraft, WriteResult } from '../main/ets/application/WriteService';
import { VaultMemoryIndex } from '../main/ets/application/state/VaultMemoryIndex';
import { AppState } from '../main/ets/application/state/AppState';
import { SessionService, SessionSink } from '../main/ets/application/SessionService';
import { LockService } from '../main/ets/application/LockService';
import { FakeCryptoEngine } from './fakes/FakeCryptoEngine';
import { FakeApiClient } from './fakes/FakeApiClient';
import { BwApiClientImpl } from '../main/ets/infrastructure/http/BwApiClientImpl';
import { FakeRepository } from './fakes/FakeRepository';
import { FakePrefs } from './fakes/FakePrefs';
import { FakeKeyStore } from './fakes/FakeKeyStore';
import { SymmetricKey } from '../main/ets/domain/crypto/CryptoEngine';
import { FakeCryptoEngine as FakeEngine } from './fakes/FakeCryptoEngine';
import { EncStringCodec } from '../main/ets/domain/crypto/EncStringCodec';
import { ProfileResponse, FolderResponse, CipherResponse, SyncResponse, ProtocolError,
  ProtocolErrorKind, CipherPayload } from '../main/ets/domain/protocol/Types';
import { Session } from '../main/ets/domain/model/Session';
import { Cipher } from '../main/ets/domain/model/Cipher';
import { CipherView } from '../main/ets/application/state/VaultMemoryIndex';
import { ItemType } from '../main/ets/domain/model/ItemType';

/**
 * T11 本地单测（spec F5/F9、plan R2）：组织条目过滤、破损条目跳过、锁定清索引、
 * 解锁重建 + outbox 重放、离线保存入队。
 */
function makeClientWithOrgEntry(): FakeApiClient {
  const client: FakeApiClient = new FakeApiClient();
  client.syncResponse = new SyncResponse(
    new ProfileResponse('p1', 'u@e.com'),
    [new FolderResponse('f1', FakeEngine.encodeText('Work'), '2026-09-05T00:00:00.000Z')],
    [
      personalCipher('c1', 'Bank'),
      orgCipher('c2')
    ]);
  return client;
}

/** 无操作会话注入口（SessionSink 的 ArkTS 命名实现，替代对象字面量）。 */
class NoopSessionSink implements SessionSink {
  attachSession(_s: Session): void {
  }

  detachSession(): void {
  }
}

export default function syncWriteFlowTest() {
  describe('SyncWriteFlow', () => {

    it('sync_filters_org_entries_and_rebuilds_index', 0, async () => {
      const env = makeEnv(makeClientWithOrgEntry());
      await env.session.completeLogin('v1', 'u@e.com', 'https://x', new Session('a', 'r', 60),
        new Uint8Array(32), env.stretched);
      await env.sync.sync();
      const index: VaultMemoryIndex = env.sync.indexState();
      expect(index.entries.length).assertEqual(1);
      expect(index.entries[0].id).assertEqual('c1');
      expect(index.entries[0].name).assertEqual('Bank');
      expect(index.folders.length).assertEqual(1);
      expect(index.folders[0].name).assertEqual('Work');
      expect(index.syncing).assertFalse();
    });

    it('sync_skips_corrupt_entry_without_blocking', 0, async () => {
      const client: FakeApiClient = makeClientWithOrgEntry();
      // 破损条目：dataJson 缺 name 字段 → 解析抛错 → 跳过
      client.syncResponse = new SyncResponse(
        new ProfileResponse('p1', 'u@e.com'), [],
        [brokenCipher('bad-1'), personalCipher('ok-1', 'Good')]);
      const env = makeEnv(client);
      await env.session.completeLogin('v1', 'u@e.com', 'https://x', new Session('a', 'r', 60),
        new Uint8Array(32), env.stretched);
      await env.sync.sync();
      const index: VaultMemoryIndex = env.sync.indexState();
      expect(index.entries.length).assertEqual(1);
      expect(index.entries[0].id).assertEqual('ok-1');
      expect(index.lastSkippedCount).assertEqual(1);
    });

    it('lock_clears_index_unlock_rebuilds_from_repository', 0, async () => {
      const env = makeEnv(makeClientWithOrgEntry());
      await env.session.completeLogin('v1', 'u@e.com', 'https://x', new Session('a', 'r', 60),
        new Uint8Array(32), env.stretched);
      await env.sync.sync();
      expect(env.sync.indexState().entries.length).assertEqual(1);

      env.lock.lock();
      expect(env.sync.indexState().entries.length).assertEqual(0);

      // 解锁：主密钥重新置入 + 从 RDB 重建（离线也可用）
      await env.session.completeLogin('v1', 'u@e.com', 'https://x', new Session('a2', 'r2', 60),
        new Uint8Array(32), env.stretched);
      await env.sync.rebuildFromRepository();
      expect(env.sync.indexState().entries.length).assertEqual(1);
      expect(env.sync.indexState().entries[0].username).assertEqual('user@example.com');
    });

    it('logout_clears_index_and_rebuild_notifies_subscribers', 0, async () => {
      // 换号场景（用户反馈）：登出 A → 登录 B，主页不得残留 A 的条目；
      // 登录后首次同步重建索引必须通知订阅者，列表无需手动下拉刷新即出现 B 的条目。
      const client: FakeApiClient = makeClientWithOrgEntry();
      const env = makeEnv(client);
      await env.session.completeLogin('vA', 'a@e.com', 'https://x', new Session('a', 'r', 60),
        new Uint8Array(32), env.stretched);
      await env.sync.sync();
      expect(env.sync.indexState().entries.length).assertEqual(1);

      let notified: number = 0;
      env.sync.indexState().addListener((): void => {
        notified++;
      });

      await env.session.logout();
      expect(env.sync.indexState().entries.length).assertEqual(0);
      expect(AppState.get().phase).assertEqual('onboarding');

      client.syncResponse = new SyncResponse(new ProfileResponse('p2', 'b@e.com'), [],
        [personalCipher('b1', 'B-Site')]);
      await env.session.completeLogin('vB', 'b@e.com', 'https://x', new Session('a2', 'r2', 60),
        new Uint8Array(32), env.stretched);
      // 首次同步完成前（挂载即进主页的时刻）索引不得含上一账号条目
      expect(env.sync.indexState().entries.length).assertEqual(0);
      const before: number = notified;
      await env.sync.sync();
      expect(env.sync.indexState().entries.length).assertEqual(1);
      expect(env.sync.indexState().entries[0].id).assertEqual('b1');
      expect(notified > before).assertTrue();
    });

    it('offline_save_enqueues_and_replays', 0, async () => {
      const client: FakeApiClient = makeClientWithOrgEntry();
      const env = makeEnv(client);
      await env.session.completeLogin('v1', 'u@e.com', 'https://x', new Session('a', 'r', 60),
        new Uint8Array(32), env.stretched);
      // 场景：在线同步（c1 入索引）→ 断网保存 → 恢复网络重放
      await env.sync.sync();
      client.errorToThrow = new ProtocolError(ProtocolErrorKind.Network, 'offline');

      const draft: CipherDraft = new CipherDraft();
      draft.type = ItemType.Login;
      draft.name = 'New Site';
      draft.username = 'bob';
      draft.password = 'pw';
      const write: WriteService = env.write;
      const result: WriteResult = await write.save(draft);
      expect(result).assertEqual('queued');
      const queued = await env.repo.peekOutbox();
      expect(queued.length).assertEqual(1);
      expect(queued[0].op).assertEqual('save');

      // 恢复网络：重放成功且本地状态与服务端一致
      client.errorToThrow = null;
      await write.replayOutbox();
      const afterQueue = await env.repo.peekOutbox();
      expect(afterQueue.length).assertEqual(0);
      expect(client.savedPayloads.length).assertEqual(1);
      expect(client.savedPayloads[0].name.length > 0).assertTrue();
      // 服务端确认后本地索引出现该条目
      expect(env.sync.indexState().entries.length).assertEqual(2);
    });

    it('soft_delete_offline_marks_trash_and_replays', 0, async () => {
      const client: FakeApiClient = makeClientWithOrgEntry();
      const env = makeEnv(client);
      await env.session.completeLogin('v1', 'u@e.com', 'https://x', new Session('a', 'r', 60),
        new Uint8Array(32), env.stretched);
      await env.sync.sync();
      client.errorToThrow = new ProtocolError(ProtocolErrorKind.Network, 'offline');
      const result: WriteResult = await env.write.softDelete('c1');
      expect(result).assertEqual('queued');
      const queued = await env.repo.peekOutbox();
      expect(queued.length).assertEqual(1);
      expect(queued[0].op).assertEqual('softDelete');
      expect(queued[0].cipherId).assertEqual('c1');
      expect(client.softDeletedIds.length).assertEqual(0);

      // 软删除保留索引条目，以 deletedDate 区分常规列表与回收站。
      const index: VaultMemoryIndex = env.sync.indexState();
      expect(index.entries.length).assertEqual(1);
      expect(index.entries[0].id).assertEqual('c1');
      const deletedDate: number | null = index.entries[0].deletedDate;
      expect(deletedDate !== null && deletedDate > 0).assertTrue();
      expect(index.entries.filter((item: CipherView): boolean => item.deletedDate === null).length)
        .assertEqual(0);
      expect(index.entries.filter((item: CipherView): boolean => item.deletedDate !== null).length)
        .assertEqual(1);

      const stored: Cipher | null = await env.repo.getCipher('v1', 'c1');
      expect(stored !== null).assertTrue();
      expect(stored?.deletedDate).assertEqual(deletedDate);
      await env.sync.rebuildFromRepository();
      expect(index.entries.length).assertEqual(1);
      expect(index.entries[0].id).assertEqual('c1');
      expect(index.entries[0].deletedDate).assertEqual(deletedDate);

      client.errorToThrow = null;
      await env.write.replayOutbox();
      expect((await env.repo.peekOutbox()).length).assertEqual(0);
      expect(client.softDeletedIds.length).assertEqual(1);
      expect(client.softDeletedIds[0]).assertEqual('c1');
      expect(index.entries.length).assertEqual(1);
      expect(index.entries[0].deletedDate !== null).assertTrue();
    });

    it('password_change_appends_history_and_keeps_old_entry', 0, async () => {
      const client: FakeApiClient = makeClientWithOrgEntry();
      const env = makeEnv(client);
      await env.session.completeLogin('v1', 'u@e.com', 'https://x', new Session('a', 'r', 60),
        new Uint8Array(32), env.stretched, null);
      await env.sync.sync();
      // 编辑 c1 改密：draft 由视图回填（同 WriteService.draftFromView），仅密码变更
      const index: VaultMemoryIndex = env.sync.indexState();
      let view = index.entries[0];
      for (let i = 0; i < index.entries.length; i++) {
        if (index.entries[i].id === 'c1') {
          view = index.entries[i];
        }
      }
      const draft: CipherDraft = env.write.draftFromView(view);
      draft.password = 'pw1-changed';
      await env.write.save(draft);
      // 服务器载荷携带 1 条历史（旧密码 pw1）
      expect(client.savedPayloads.length).assertEqual(1);
      expect(client.savedPayloads[0].passwordHistory.length).assertEqual(1);
      // 旧密码密文 ≠ 新密码密文，且新密码不在历史中
      const oldEntry = client.savedPayloads[0].passwordHistory[0];
      expect(oldEntry.password !== client.savedPayloads[0].login?.password).assertTrue();
      // T28 fix-08：官方云 LastUsedDate 必填——历史载荷必须携带（缺失以更改时间兜底）
      expect(oldEntry.lastUsedDate !== null && oldEntry.lastUsedDate!.length > 0).assertTrue();
    });

    it('reencode_save_merges_existing_history_without_loss', 0, async () => {      const client: FakeApiClient = makeClientWithOrgEntry();
      const env = makeEnv(client);
      await env.session.completeLogin('v1', 'u@e.com', 'https://x', new Session('a', 'r', 60),
        new Uint8Array(32), env.stretched);
      await env.sync.sync();
      const index: VaultMemoryIndex = env.sync.indexState();
      let view = index.entries[0];
      for (let i = 0; i < index.entries.length; i++) {
        if (index.entries[i].id === 'c1') {
          view = index.entries[i];
        }
      }
      // 第一次改密：历史 1 条
      const draft1: CipherDraft = env.write.draftFromView(view);
      draft1.password = 'pw1-changed';
      await env.write.save(draft1);
      // 服务器回显 → 本地缓存含历史；第二次仅改收藏（不改密）：历史仍为 1 条且保留
      const afterFirst: Cipher | null = await env.repo.getCipher('v1', 'c1');
      expect(afterFirst !== null).assertTrue();
      if (afterFirst !== null) {
        expect(afterFirst.passwordHistory.length).assertEqual(1);
      }
      const view2: VaultMemoryIndex = env.sync.indexState();
      let viewAfter = view2.entries[0];
      for (let i = 0; i < view2.entries.length; i++) {
        if (view2.entries[i].id === 'c1') {
          viewAfter = view2.entries[i];
        }
      }
      const draft2: CipherDraft = env.write.draftFromView(viewAfter);
      draft2.favorite = true; // 密码未变：不追加，但既有历史必须随载荷提交（防服务器整包覆盖丢失）
      await env.write.save(draft2);
      expect(client.savedPayloads.length).assertEqual(2);
      expect(client.savedPayloads[1].passwordHistory.length).assertEqual(1);
      const afterSecond: Cipher | null = await env.repo.getCipher('v1', 'c1');
      if (afterSecond !== null) {
        expect(afterSecond.passwordHistory.length).assertEqual(1);
      }
    });

    it('v2_edit_perkey_item_reuses_item_key_and_resubmits_key', 0, async () => {
      const client: FakeApiClient = new FakeApiClient();
      const env = makeEnv(client);
      const itemKeyBytes: Uint8Array = new Uint8Array(64);
      for (let i = 0; i < 64; i++) {
        itemKeyBytes[i] = i + 1;
      }
      const wrapped: string = EncStringCodec.encode(
        await env.engine.makeEncString(itemKeyBytes, env.stretched));
      client.syncResponse = new SyncResponse(
        new ProfileResponse('p1', 'u@e.com'), [],
        [v2Cipher('c-v2', 'V2Item', wrapped)]);
      await env.session.completeLogin('v1', 'u@e.com', 'https://x', new Session('a', 'r', 60),
        new Uint8Array(32), env.stretched);
      await env.sync.sync();
      // 读路径回归：per-key 条目以条目密钥解密后可读
      const view: CipherView | null = env.sync.indexState().entries.length > 0
        ? env.sync.indexState().entries[0] : null;
      expect(view !== null && view.id === 'c-v2').assertTrue();
      expect(view?.name).assertEqual('V2Item');
      // 编辑保存：沿用既有条目密钥，载荷携带 key 字段
      const draft: CipherDraft = env.write.draftFromView(view as CipherView);
      draft.name = 'V2Item2';
      await env.write.save(draft);
      expect(client.savedPayloads.length).assertEqual(1);
      expect(client.savedPayloads[0].key).assertEqual(wrapped);
      // 回显落库后条目密钥不丢（解锁重建仍可解密）
      const stored: Cipher | null = await env.repo.getCipher('v1', 'c-v2');
      expect(stored !== null && stored.cipherKey === wrapped).assertTrue();
      await env.sync.rebuildFromRepository();
      expect(env.sync.indexState().entries[0].name).assertEqual('V2Item2');
    });

    it('v2_new_item_official_cloud_generates_item_key', 0, async () => {
      const client: FakeApiClient = new FakeApiClient();
      const env = makeEnv(client);
      // 官方云 V2 会话：服务器 URL + 受保护用户密钥 + 已解开用户密钥
      await env.session.completeLogin('v1', 'u@e.com', 'https://vault.bitwarden.com',
        new Session('a', 'r', 60, '2.fake|wrapped|userkey'), new Uint8Array(32),
        env.stretched, env.stretched);
      const draft: CipherDraft = new CipherDraft();
      draft.type = ItemType.Login;
      draft.name = 'New V2';
      draft.username = 'bob';
      draft.password = 'pw';
      await env.write.save(draft);
      // 新建条目必须生成条目密钥并随载荷提交（官方云 V2 语义）
      expect(client.savedPayloads.length).assertEqual(1);
      expect(client.savedPayloads[0].key !== null && client.savedPayloads[0].key!.length > 0)
        .assertTrue();
      // 服务器回显 → 本地可按 per-key 解密重建
      expect(env.sync.indexState().entries.length).assertEqual(1);
      expect(env.sync.indexState().entries[0].name).assertEqual('New V2');
    });

    it('folder_with_perkey_name_decrypts_via_folder_key', 0, async () => {
      const client: FakeApiClient = new FakeApiClient();
      const env = makeEnv(client);
      const folderKeyBytes: Uint8Array = new Uint8Array(64);
      for (let i = 0; i < 64; i++) {
        folderKeyBytes[i] = 64 - i;
      }
      const wrappedFolderKey: string = EncStringCodec.encode(
        await env.engine.makeEncString(folderKeyBytes, env.stretched));
      client.syncResponse = new SyncResponse(
        new ProfileResponse('p1', 'u@e.com'),
        [new FolderResponse('f1', FakeCryptoEngine.encodeText('Work'),
          '2026-09-05T00:00:00.000Z', wrappedFolderKey)], []);
      await env.session.completeLogin('v1', 'u@e.com', 'https://x', new Session('a', 'r', 60),
        new Uint8Array(32), env.stretched);
      await env.sync.sync();
      // 文件夹名以 per-folder 密钥加密 → 经条目密钥解包后可读
      expect(env.sync.indexState().folders.length).assertEqual(1);
      expect(env.sync.indexState().folders[0].name).assertEqual('Work');
      // 离线重建（fake 仓库直存 Folder 对象，key 保留）
      await env.sync.rebuildFromRepository();
      expect(env.sync.indexState().folders[0].name).assertEqual('Work');
    });

    it('save_secure_note_carries_secure_note_payload', 0, async () => {
      const client: FakeApiClient = new FakeApiClient();
      const env = makeEnv(client);
      await env.session.completeLogin('v1', 'u@e.com', 'https://x', new Session('a', 'r', 60),
        new Uint8Array(32), env.stretched);

      const draft: CipherDraft = new CipherDraft();
      draft.type = ItemType.SecureNote;
      draft.name = 'My Secret Note';
      draft.notes = 'Confidential memo content';
      const result: WriteResult = await env.write.save(draft);
      expect(result).assertEqual('saved');
      expect(client.savedPayloads.length).assertEqual(1);
      const payload: CipherPayload = client.savedPayloads[0];
      expect(payload.type).assertEqual(ItemType.SecureNote);

      // 验证载荷与序列化 JSON 包含 secureNote: { type: 0 }（Bitwarden / Vaultwarden 契约）
      const jsonStr: string = BwApiClientImpl.payloadToJson(payload);
      const parsed: Record<string, Object> = JSON.parse(jsonStr) as Record<string, Object>;
      expect(parsed['type']).assertEqual(ItemType.SecureNote);
      const secureNoteObj = parsed['secureNote'] as Record<string, Object>;
      expect(secureNoteObj !== undefined && secureNoteObj !== null).assertTrue();
      expect(secureNoteObj['type']).assertEqual(0);
    });

    it('offline_save_secure_note_enqueues_and_replays', 0, async () => {
      const client: FakeApiClient = new FakeApiClient();
      const env = makeEnv(client);
      await env.session.completeLogin('v1', 'u@e.com', 'https://x', new Session('a', 'r', 60),
        new Uint8Array(32), env.stretched);

      client.errorToThrow = new ProtocolError(ProtocolErrorKind.Network, 'offline');
      const draft: CipherDraft = new CipherDraft();
      draft.type = ItemType.SecureNote;
      draft.name = 'Offline Note';
      draft.notes = 'Offline note content';
      const result: WriteResult = await env.write.save(draft);
      expect(result).assertEqual('queued');

      const queued = await env.repo.peekOutbox();
      expect(queued.length).assertEqual(1);
      expect(queued[0].op).assertEqual('save');

      // 恢复网络重放，验证 payloadFromJson 反序列化保留 secureNote 字段，服务端校验通过
      client.errorToThrow = null;
      await env.write.replayOutbox();
      expect((await env.repo.peekOutbox()).length).assertEqual(0);
      expect(client.savedPayloads.length).assertEqual(1);
      expect(client.savedPayloads[0].type).assertEqual(ItemType.SecureNote);
      expect(client.savedPayloads[0].secureNote !== null).assertTrue();
      expect(client.savedPayloads[0].secureNote?.type).assertEqual(0);
    });
  });
}

function personalCipher(id: string, name: string): CipherResponse {
  const uris: string[] = [];
  const login: Record<string, Object | null> = {
    'username': FakeCryptoEngine.encodeText('user@example.com'),
    'password': FakeCryptoEngine.encodeText('pw1'),
    'totp': null,
    'uris': uris
  };
  return new CipherResponse(id, null, null, 1, false, '2026-09-05T00:00:00.000Z', null,
    JSON.stringify({
      'name': FakeCryptoEngine.encodeText(name),
      'login': login,
      'fields': [],
      'attachments': []
    }));
}

function orgCipher(id: string): CipherResponse {
  return new CipherResponse(id, 'org-1', null, 1, false, '2026-09-05T00:00:00.000Z', null,
    JSON.stringify({ 'name': FakeCryptoEngine.encodeText('OrgItem') }));
}

function brokenCipher(id: string): CipherResponse {
  return new CipherResponse(id, null, null, 1, false, '2026-09-05T00:00:00.000Z', null,
    JSON.stringify({ 'login': null, 'fields': [] }));
}

interface TestEnv {
  sync: SyncService;
  write: WriteService;
  session: SessionService;
  lock: LockService;
  repo: FakeRepository;
  stretched: SymmetricKey;
  engine: FakeCryptoEngine;
}

function makeEnv(client: FakeApiClient): TestEnv {
  const repo: FakeRepository = new FakeRepository();
  const engine: FakeCryptoEngine = new FakeCryptoEngine();
  const prefs: FakePrefs = new FakePrefs();
  const keyStore: FakeKeyStore = new FakeKeyStore();
  const session: SessionService = new SessionService(prefs, keyStore, new NoopSessionSink(),
    repo);
  AppState.get().transitionTo('onboarding');
  const lock: LockService = new LockService(prefs, (): void => session.clearSecrets());
  const index: VaultMemoryIndex = new VaultMemoryIndex();
  const sync: SyncService = new SyncService(index, client, repo, engine, session, lock);
  const write: WriteService = new WriteService(client, repo, engine, session,
    (response: import('../main/ets/domain/protocol/Types').CipherResponse): Promise<void> =>
      sync.upsertFromServerResponse(response));
  // 与 ServiceLocator.write() 一致：永久删除移除索引，软删除/恢复更新本地投影。
  write.setRemovedHook((id: string): void => sync.removeLocally(id));
  write.setLocalCipherHook((id: string, deletedDate: number | null): Promise<void> =>
    sync.refreshCipherLocally(id, deletedDate));
  return { sync: sync, write: write, session: session, lock: lock, repo: repo,
    stretched: new SymmetricKey(new Uint8Array(32), new Uint8Array(32)), engine: engine };
}

/** V2 per-key 条目响应（T28）：dataJson 含顶层 key（条目密钥密文）。 */
function v2Cipher(id: string, name: string, wrappedKey: string): CipherResponse {
  const login: Record<string, Object | null> = {
    'username': FakeCryptoEngine.encodeText('user@example.com'),
    'password': FakeCryptoEngine.encodeText('pw1'),
    'totp': null,
    'uris': [] as string[]
  };
  return new CipherResponse(id, null, null, 1, false, '2026-09-05T00:00:00.000Z', null,
    JSON.stringify({
      'name': FakeCryptoEngine.encodeText(name),
      'key': wrappedKey,
      'login': login,
      'fields': []
    }));
}
