/*
 * SPDX-FileCopyrightText: 2026 Liugt
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import { describe, it, expect } from '@ohos/hypium';
import { SyncService } from '../main/ets/application/SyncService';
import { SessionService, SessionSink } from '../main/ets/application/SessionService';
import { LockService } from '../main/ets/application/LockService';
import { AppState } from '../main/ets/application/state/AppState';
import { CipherView, VaultMemoryIndex } from '../main/ets/application/state/VaultMemoryIndex';
import { SymmetricKey } from '../main/ets/domain/crypto/CryptoEngine';
import { Cipher } from '../main/ets/domain/model/Cipher';
import { EncString } from '../main/ets/domain/model/EncString';
import { Session } from '../main/ets/domain/model/Session';
import { CipherResponse, FolderResponse, ProfileResponse, SyncResponse } from '../main/ets/domain/protocol/Types';
import { FakeApiClient } from './fakes/FakeApiClient';
import { FakeCryptoEngine } from './fakes/FakeCryptoEngine';
import { FakeRepository } from './fakes/FakeRepository';
import { FakePrefs } from './fakes/FakePrefs';
import { FakeKeyStore } from './fakes/FakeKeyStore';

class Pause {
  private signalEntered: () => void = (): void => {};
  private signalReleased: () => void = (): void => {};
  readonly entered: Promise<void> = new Promise<void>((resolve) => {
    this.signalEntered = resolve;
  });
  private readonly released: Promise<void> = new Promise<void>((resolve) => {
    this.signalReleased = resolve;
  });

  wait(): Promise<void> {
    this.signalEntered();
    return this.released;
  }

  release(): void {
    this.signalReleased();
  }
}

class PausingCrypto extends FakeCryptoEngine {
  pause: Pause | null = null;

  async decryptToString(enc: EncString, key: SymmetricKey): Promise<string> {
    const pause: Pause | null = this.pause;
    this.pause = null;
    if (pause !== null) {
      await pause.wait();
    }
    return super.decryptToString(enc, key);
  }
}

class PausingClient extends FakeApiClient {
  pause: Pause | null = null;

  async sync(): Promise<SyncResponse> {
    const response: SyncResponse = await super.sync();
    const pause: Pause | null = this.pause;
    this.pause = null;
    if (pause !== null) {
      await pause.wait();
    }
    return response;
  }
}

// Match the RDB repository's local metadata merge without changing shared fakes.
class MergingRepository extends FakeRepository {
  touchPause: Pause | null = null;
  failTouch: boolean = false;

  async upsertCipher(vaultId: string, cipher: Cipher): Promise<void> {
    const previous: Cipher | null = await this.getCipher(vaultId, cipher.id);
    await super.upsertCipher(vaultId, cipher);
    if (previous !== null && previous.lastUsedAt > 0) {
      await super.touchLastUsed(vaultId, cipher.id, previous.lastUsedAt);
    }
  }

  async replaceCiphers(vaultId: string, ciphers: Cipher[]): Promise<void> {
    const previous: Cipher[] = await this.getAllCiphers(vaultId);
    await super.replaceCiphers(vaultId, ciphers);
    for (let i = 0; i < previous.length; i++) {
      if (previous[i].lastUsedAt > 0) {
        await super.touchLastUsed(vaultId, previous[i].id, previous[i].lastUsedAt);
      }
    }
  }

  async touchLastUsed(vaultId: string, id: string, timestamp: number): Promise<void> {
    const pause: Pause | null = this.touchPause;
    this.touchPause = null;
    if (pause !== null) {
      await pause.wait();
    }
    if (this.failTouch) {
      throw new Error('touch failed');
    }
    await super.touchLastUsed(vaultId, id, timestamp);
  }
}

class NoopSink implements SessionSink {
  attachSession(_session: Session): void {}
  detachSession(): void {}
}

class ProjectionEnv {
  readonly repo: MergingRepository = new MergingRepository();
  readonly crypto: PausingCrypto = new PausingCrypto();
  readonly client: PausingClient = new PausingClient();
  readonly prefs: FakePrefs = new FakePrefs();
  readonly session: SessionService = new SessionService(this.prefs, new FakeKeyStore(),
    new NoopSink(), this.repo);
  readonly lock: LockService = new LockService(this.prefs, (): void => this.session.clearSecrets());
  readonly key: SymmetricKey = new SymmetricKey(new Uint8Array(32), new Uint8Array(32));
  readonly sync: SyncService = new SyncService(new VaultMemoryIndex(), this.client,
    this.repo, this.crypto, this.session, this.lock);

  async login(): Promise<void> {
    await this.session.completeLogin('v1', 'u@e.com', 'https://x', new Session('a', 'r', 60),
      new Uint8Array(32), this.key);
  }

  async seed(): Promise<void> {
    AppState.get().transitionTo('onboarding');
    await this.login();
    this.client.syncResponse = new SyncResponse(new ProfileResponse('p1', 'u@e.com'),
      [new FolderResponse('f1', FakeCryptoEngine.encodeText('Work'), '2026-09-05T00:00:00.000Z')],
      [item('Original')]);
    await this.sync.sync();
  }
}

function item(name: string): CipherResponse {
  return new CipherResponse('c1', null, null, 2, false, '2026-09-05T00:00:00.000Z', null,
    JSON.stringify({ 'name': FakeCryptoEngine.encodeText(name), 'fields': [], 'attachments': [] }));
}

export default function syncProjectionTest() {
  describe('SyncProjection', () => {
    it('server_upsert_projects_persisted_last_used', 0, async () => {
      const env: ProjectionEnv = new ProjectionEnv();
      await env.seed();
      await env.repo.touchLastUsed('v1', 'c1', 1234);
      await env.sync.upsertFromServerResponse(item('Edited'));
      expect(env.sync.indexState().entries[0].name).assertEqual('Edited');
      expect(env.sync.indexState().entries[0].lastUsedAt).assertEqual(1234);
    });

    it('full_sync_projects_persisted_last_used', 0, async () => {
      const env: ProjectionEnv = new ProjectionEnv();
      await env.seed();
      await env.repo.touchLastUsed('v1', 'c1', 5678);
      await env.sync.sync();
      expect(env.sync.indexState().entries[0].lastUsedAt).assertEqual(5678);
    });

    it('touch_persists_before_updating_current_entry_and_notifies_all', 0, async () => {
      const env: ProjectionEnv = new ProjectionEnv();
      await env.seed();
      const index: VaultMemoryIndex = env.sync.indexState();
      const stale: CipherView = index.entries[0];
      const pause: Pause = new Pause();
      env.repo.touchPause = pause;
      const pending: Promise<void> = env.sync.touchLastUsed('c1');
      await pause.entered;
      expect(index.entries[0].lastUsedAt).assertEqual(0);
      await env.sync.upsertFromServerResponse(item('Current'));
      const current: CipherView = index.entries[0];
      let first: number = 0;
      let second: number = 0;
      index.addListener((): void => { first++; });
      index.addListener((): void => { second++; });
      pause.release();
      await pending;
      expect(index.entries[0] === current).assertTrue();
      expect(index.entries[0].name).assertEqual('Current');
      expect(stale.lastUsedAt).assertEqual(0);
      expect(current.lastUsedAt > 0).assertTrue();
      expect((await env.repo.getCipher('v1', 'c1'))?.lastUsedAt).assertEqual(current.lastUsedAt);
      expect(first).assertEqual(1);
      expect(second).assertEqual(1);
    });

    it('failed_touch_does_not_update_or_notify', 0, async () => {
      const env: ProjectionEnv = new ProjectionEnv();
      await env.seed();
      env.repo.failTouch = true;
      let notified: number = 0;
      env.sync.indexState().addListener((): void => { notified++; });
      let failed: boolean = false;
      try {
        await env.sync.touchLastUsed('c1');
      } catch (e) {
        failed = true;
      }
      expect(failed).assertTrue();
      expect(env.sync.indexState().entries[0].lastUsedAt).assertEqual(0);
      expect(notified).assertEqual(0);
    });

    it('touch_does_not_restore_removed_entry', 0, async () => {
      const env: ProjectionEnv = new ProjectionEnv();
      await env.seed();
      const pause: Pause = new Pause();
      env.repo.touchPause = pause;
      const pending: Promise<void> = env.sync.touchLastUsed('c1');
      await pause.entered;
      env.sync.removeLocally('c1');
      pause.release();
      await pending;
      expect(env.sync.indexState().entries.length).assertEqual(0);
    });

    it('lock_during_repository_rebuild_does_not_republish_plaintext', 0, async () => {
      const env: ProjectionEnv = new ProjectionEnv();
      await env.seed();
      const pause: Pause = new Pause();
      env.crypto.pause = pause;
      const pending: Promise<void> = env.sync.rebuildFromRepository();
      await pause.entered;
      env.lock.lock();
      pause.release();
      await pending;
      expect(env.sync.indexState().entries.length).assertEqual(0);
      expect(env.sync.indexState().folders.length).assertEqual(0);
    });

    it('lock_during_full_sync_does_not_publish_views_or_metadata', 0, async () => {
      const env: ProjectionEnv = new ProjectionEnv();
      await env.seed();
      const index: VaultMemoryIndex = env.sync.indexState();
      index.lastSyncAt = 42;
      const pause: Pause = new Pause();
      env.crypto.pause = pause;
      const pending: Promise<void> = env.sync.sync();
      await pause.entered;
      env.lock.lock();
      pause.release();
      await pending;
      expect(index.entries.length).assertEqual(0);
      expect(index.folders.length).assertEqual(0);
      expect(index.lastSyncAt).assertEqual(42);
      expect(index.syncing).assertFalse();
    });

    it('logout_during_upsert_does_not_republish_plaintext', 0, async () => {
      const env: ProjectionEnv = new ProjectionEnv();
      await env.seed();
      const pause: Pause = new Pause();
      env.crypto.pause = pause;
      const pending: Promise<void> = env.sync.upsertFromServerResponse(item('Edited'));
      await pause.entered;
      await env.session.logout();
      pause.release();
      await pending;
      expect(env.sync.indexState().entries.length).assertEqual(0);
    });

    it('lock_then_same_key_login_invalidates_old_local_refresh', 0, async () => {
      const env: ProjectionEnv = new ProjectionEnv();
      await env.seed();
      const pause: Pause = new Pause();
      env.crypto.pause = pause;
      const pending: Promise<void> = env.sync.refreshCipherLocally('c1', 123);
      await pause.entered;
      env.lock.lock();
      await env.login();
      await env.sync.upsertFromServerResponse(item('New session'));
      pause.release();
      await pending;
      expect(env.sync.indexState().entries[0].name).assertEqual('New session');
      expect(env.sync.indexState().entries[0].deletedDate).assertEqual(null);
    });

    it('changed_key_identity_invalidates_repository_rebuild', 0, async () => {
      const env: ProjectionEnv = new ProjectionEnv();
      await env.seed();
      const pause: Pause = new Pause();
      env.crypto.pause = pause;
      const pending: Promise<void> = env.sync.rebuildFromRepository();
      await pause.entered;
      env.session.restoreKeys(new Uint8Array(32),
        new SymmetricKey(new Uint8Array(32), new Uint8Array(32)), null);
      await env.sync.upsertFromServerResponse(item('New key'));
      pause.release();
      await pending;
      expect(env.sync.indexState().entries[0].name).assertEqual('New key');
    });

    it('touch_from_before_lock_does_not_update_new_session_entry', 0, async () => {
      const env: ProjectionEnv = new ProjectionEnv();
      await env.seed();
      const pause: Pause = new Pause();
      env.repo.touchPause = pause;
      const pending: Promise<void> = env.sync.touchLastUsed('c1');
      await pause.entered;
      env.lock.lock();
      await env.login();
      await env.sync.upsertFromServerResponse(item('New session'));
      let notified: number = 0;
      env.sync.indexState().addListener((): void => { notified++; });
      pause.release();
      await pending;
      expect(env.sync.indexState().entries[0].lastUsedAt).assertEqual(0);
      expect(notified).assertEqual(0);
    });

    it('old_network_response_is_not_persisted_into_new_vault', 0, async () => {
      const env: ProjectionEnv = new ProjectionEnv();
      await env.seed();
      const pause: Pause = new Pause();
      env.client.pause = pause;
      const pending: Promise<void> = env.sync.sync();
      await pause.entered;
      await env.session.logout();
      await env.session.completeLogin('v2', 'other@e.com', 'https://x', new Session('b', 'r', 60),
        new Uint8Array(32), env.key);
      await env.sync.upsertFromServerResponse(item('Other vault'));
      pause.release();
      await pending;
      expect(env.sync.indexState().entries[0].name).assertEqual('Other vault');
      await env.sync.rebuildFromRepository();
      expect(env.sync.indexState().entries[0].name).assertEqual('Other vault');
    });
  });
}
