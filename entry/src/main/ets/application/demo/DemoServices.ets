/*
 * SPDX-FileCopyrightText: 2026 Liugt
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import { VaultMemoryIndex, CipherView, FolderView, FieldView, FieldType2, CardView, IdentityView, HistoryItemView }
  from '../state/VaultMemoryIndex';
import { CipherDraft, DraftField, WriteResult, WriteService } from '../WriteService';
import { SyncService } from '../SyncService';
import { SessionService, SessionSink } from '../SessionService';
import { AttachmentService, AttachmentTransport } from '../AttachmentService';
import { SettingsService } from '../SettingsService';
import { LockService } from '../LockService';
import { PreferencesStore } from '../../domain/repository/PreferencesStore';
import { KeyStore } from '../../domain/repository/KeyStore';
import { VaultRepository } from '../../domain/repository/VaultRepository';
import { BwApiClient } from '../../domain/protocol/BwApiClient';
import { CryptoEngine, SymmetricKey } from '../../domain/crypto/CryptoEngine';
import { ItemType } from '../../domain/model/ItemType';
import { Cipher } from '../../domain/model/Cipher';
import { Folder } from '../../domain/model/Folder';
import { OutboxOp, OutboxOpType } from '../../domain/model/OutboxOp';
import { SyncState } from '../../domain/model/SyncState';
import { Session } from '../../domain/model/Session';
import { BiometricType } from '../../domain/biometric/BiometricCapability';
import { ProgressListener } from '../../infrastructure/http/AttachmentApi';
import {
  PreloginResponse, TokenRequest, TokenResponse, SyncResponse, CipherPayload,
  CipherResponse, FolderResponse, AttachmentUploadResponse, AttachmentDownloadResponse,
  ProfileResponse
} from '../../domain/protocol/Types';
import { DemoSandboxServices } from '../ServiceLocator';
import { ClipboardService } from '../ClipboardService';
import { PasteboardAdapter } from '../../infrastructure/clipboard/PasteboardAdapter';

// ==========================================
// 1. 无害 Stub / Null 实现 (满足 ArkTS 静态类型)
// ==========================================

export class NullBwApiClient implements BwApiClient {
  async prelogin(_email: string): Promise<PreloginResponse> {
    throw new Error('离线体验模式');
  }
  async connectToken(_request: TokenRequest): Promise<TokenResponse> {
    throw new Error('离线体验模式');
  }
  async sync(): Promise<SyncResponse> {
    return new SyncResponse(new ProfileResponse('mock-demo-vault', 'demo@hallpass.app'), [], []);
  }
  async saveCipher(_payload: CipherPayload): Promise<CipherResponse> {
    throw new Error('离线体验模式');
  }
  async softDeleteCipher(_id: string): Promise<void> {}
  async restoreCipher(_id: string): Promise<CipherResponse> {
    throw new Error('离线体验模式');
  }
  async hardDeleteCipher(_id: string): Promise<void> {}
  async listFolders(): Promise<FolderResponse[]> {
    return [];
  }
  async requestAttachmentUpload(_cipherId: string, _fileName: string, _fileSize: number, _fileKey: string): Promise<AttachmentUploadResponse> {
    throw new Error('体验模式不支持附件上传');
  }
  async completeAttachmentUpload(_cipherId: string, _attachmentId: string, _dataJson: string): Promise<CipherResponse> {
    throw new Error('体验模式不支持附件上传');
  }
  async requestAttachmentDownload(_cipherId: string, _attachmentId: string): Promise<AttachmentDownloadResponse> {
    throw new Error('体验模式不支持附件下载');
  }
  async deleteAttachment(_cipherId: string, _attachmentId: string): Promise<void> {}
}

export class NullVaultRepository implements VaultRepository {
  async replaceCiphers(_vaultId: string, _ciphers: Cipher[]): Promise<void> {}
  async upsertCipher(_vaultId: string, _cipher: Cipher): Promise<void> {}
  async getCipher(_vaultId: string, _id: string): Promise<Cipher | null> { return null; }
  async getAllCiphers(_vaultId: string): Promise<Cipher[]> { return []; }
  async removeCipher(_vaultId: string, _id: string): Promise<void> {}
  async touchLastUsed(_vaultId: string, _id: string, _timestamp: number): Promise<void> {}
  async replaceFolders(_vaultId: string, _folders: Folder[]): Promise<void> {}
  async getAllFolders(_vaultId: string): Promise<Folder[]> { return []; }
  async enqueueOp(_cipherId: string, _op: OutboxOpType, _payload: string | null): Promise<void> {}
  async peekOutbox(): Promise<OutboxOp[]> { return []; }
  async ackOp(_seq: number): Promise<void> {}
  async getSyncState(_vaultId: string): Promise<SyncState | null> { return null; }
  async setSyncState(_state: SyncState): Promise<void> {}
}

export class NullKeyStore implements KeyStore {
  async saveFastUnlockKey(_vaultId: string, _masterKey: Uint8Array): Promise<void> {}
  async readFastUnlockKey(_vaultId: string, _biometricTypes?: BiometricType[]): Promise<Uint8Array | null> { return null; }
  async hasFastUnlockKey(_vaultId: string): Promise<boolean> { return false; }
  async clearFastUnlockKey(_vaultId: string): Promise<void> {}
  async saveAutoUnlockKey(_vaultId: string, _masterKey: Uint8Array): Promise<void> {}
  async readAutoUnlockKey(_vaultId: string): Promise<Uint8Array | null> { return null; }
  async clearAutoUnlockKey(_vaultId: string): Promise<void> {}
  async saveSession(_session: Session): Promise<void> {}
  async readSession(): Promise<Session | null> { return null; }
  async clearSession(): Promise<void> {}
}

export class NullSessionSink implements SessionSink {
  attachSession(_session: Session): void {}
  detachSession(): void {}
}

export class NullAttachmentTransport implements AttachmentTransport {
  async upload(_url: string, _data: Uint8Array, _onProgress: ProgressListener | null): Promise<void> {}
  async download(_url: string, _onProgress: ProgressListener | null): Promise<Uint8Array> {
    return new Uint8Array(0);
  }
}

// ==========================================
// 2. 内存偏好沙箱 (InMemoryPreferencesStore)
// ==========================================

export class InMemoryPreferencesStore implements PreferencesStore {
  private readonly map: Map<string, Object> = new Map();

  async getString(key: string): Promise<string | null> {
    const val = this.map.get(key);
    return typeof val === 'string' ? val : null;
  }
  async setString(key: string, value: string): Promise<void> {
    this.map.set(key, value);
  }
  async getBoolean(key: string): Promise<boolean | null> {
    const val = this.map.get(key);
    return typeof val === 'boolean' ? val : null;
  }
  async setBoolean(key: string, value: boolean): Promise<void> {
    this.map.set(key, value);
  }
  async getNumber(key: string): Promise<number | null> {
    const val = this.map.get(key);
    return typeof val === 'number' ? val : null;
  }
  async setNumber(key: string, value: number): Promise<void> {
    this.map.set(key, value);
  }
}

// ==========================================
// 3. 沙箱安全锁服务 (DemoLockService - 修复 CRIT-v2-04)
// ==========================================

export class DemoLockService extends LockService {
  constructor(inMemoryPrefs: PreferencesStore) {
    super(inMemoryPrefs, (): void => {});
  }

  /**
   * 体验模式豁免锁屏状态：锁定时不清除内存密钥，立即锁定由 UI 统一引导退出
   */
  override lock(): void {
    // no-op: 由 SettingsViewModel.lockNow 拦截为退出体验模式确认弹窗
  }
}

// ==========================================
// 4. 沙箱会话服务 (DemoSessionService - 修复 CRIT-01/03)
// ==========================================

export class DemoSessionService extends SessionService {
  private readonly onLogoutCallback: () => void;

  constructor(prefs: PreferencesStore, keyStore: KeyStore, sink: SessionSink,
    repository: VaultRepository, onLogout: () => void) {
    super(prefs, keyStore, sink, repository);
    this.onLogoutCallback = onLogout;
    this.state.email = 'demo@hallpass.app';
    this.state.serverUrl = '本地体验模式 (离线)';
    this.state.vaultId = 'mock-demo-vault';
  }

  override hasSession(): boolean {
    return true;
  }

  override masterKey(): Uint8Array | null {
    return null;
  }

  override userKey(): SymmetricKey | null {
    return null;
  }

  /**
   * 覆写 logout()，体验模式登出绝不调用 super.logout()，绝不触碰真实 SQLite 与 KeyStore
   */
  override async logout(): Promise<void> {
    this.onLogoutCallback();
  }

  override async handleSessionExpired(): Promise<void> {
    // 体验模式无会话过期
  }
}

// ==========================================
// 5. 沙箱写服务 (DemoWriteService - 彻底废除 NullCryptoEngine，复用生产 CryptoEngine)
// ==========================================

export class DemoWriteService extends WriteService {
  private readonly index: VaultMemoryIndex;

  constructor(index: VaultMemoryIndex, sessionService: SessionService, crypto: CryptoEngine) {
    super(
      new NullBwApiClient(),
      new NullVaultRepository(),
      crypto,
      sessionService,
      async (_res: CipherResponse): Promise<void> => {}
    );
    this.index = index;
  }

  override async save(draft: CipherDraft): Promise<WriteResult> {
    const id: string = draft.id ?? `demo-item-${Date.now()}`;
    const fields: FieldView[] = [];
    for (let i = 0; i < draft.fields.length; i++) {
      const f = draft.fields[i];
      fields.push(new FieldView(f.type as FieldType2, f.name, f.value, f.type === 1, f.linkedId));
    }

    let card: CardView | null = null;
    if (draft.type === ItemType.Card) {
      card = new CardView(
        draft.cardholderName, draft.brand, draft.cardNumber,
        draft.expMonth, draft.expYear, draft.cardCode
      );
    }

    let identity: IdentityView | null = null;
    if (draft.type === ItemType.Identity) {
      identity = new IdentityView(
        draft.firstName, draft.middleName, draft.lastName,
        draft.company, draft.identityEmail, draft.phone,
        draft.ssn, draft.passportNumber, draft.licenseNumber,
        draft.address1, draft.address2, draft.address3,
        draft.city, draft.state, draft.postalCode, draft.country
      );
    }

    const existing: CipherView | undefined = this.index.entries.find((e: CipherView): boolean => e.id === id);
    const history: HistoryItemView[] = existing ? existing.passwordHistory.slice(0) : [];

    if (existing !== undefined && existing.password !== draft.password && draft.password.length > 0) {
      history.unshift(new HistoryItemView(existing.password, Date.now()));
    }

    const view = new CipherView(
      id,
      draft.type,
      draft.name,
      draft.favorite,
      draft.folderId,
      existing ? existing.deletedDate : null,
      Date.now(),
      draft.username,
      draft.password,
      draft.totp,
      draft.uris.slice(0),
      draft.notes,
      fields,
      card,
      identity,
      [],
      history,
      existing ? existing.lastUsedAt : 0
    );

    this.index.upsert(view);
    return 'saved';
  }

  override async softDelete(id: string): Promise<WriteResult> {
    const item: CipherView | undefined = this.index.entries.find((e: CipherView): boolean => e.id === id);
    if (item !== undefined) {
      const updated = new CipherView(
        item.id, item.type, item.name, item.favorite, item.folderId,
        Date.now(), // deletedDate
        Date.now(), item.username, item.password, item.totpSecret,
        item.uris.slice(0), item.notes, item.fields.slice(0), item.card, item.identity,
        item.attachments.slice(0), item.passwordHistory.slice(0), item.lastUsedAt
      );
      this.index.upsert(updated);
    }
    return 'saved';
  }

  override async restore(id: string): Promise<WriteResult> {
    const item: CipherView | undefined = this.index.entries.find((e: CipherView): boolean => e.id === id);
    if (item !== undefined) {
      const updated = new CipherView(
        item.id, item.type, item.name, item.favorite, item.folderId,
        null, // clear deletedDate
        Date.now(), item.username, item.password, item.totpSecret,
        item.uris.slice(0), item.notes, item.fields.slice(0), item.card, item.identity,
        item.attachments.slice(0), item.passwordHistory.slice(0), item.lastUsedAt
      );
      this.index.upsert(updated);
    }
    return 'saved';
  }

  override async hardDelete(id: string): Promise<WriteResult> {
    this.index.remove(id);
    return 'saved';
  }

  override async replayOutbox(): Promise<void> {
    // 纯内存沙箱，无离线重放需求
  }

  override draftFromView(view: CipherView): CipherDraft {
    const draft: CipherDraft = new CipherDraft();
    draft.id = view.id;
    draft.type = view.type;
    draft.folderId = view.folderId;
    draft.favorite = view.favorite;
    draft.name = view.name;
    draft.notes = view.notes;
    draft.username = view.username;
    draft.password = view.password;
    draft.totp = view.totpSecret;
    draft.uris = view.uris.slice(0);
    for (let i = 0; i < view.fields.length; i++) {
      const f = view.fields[i];
      draft.fields.push(new DraftField(f.name, f.value, f.type as number, f.linkedId));
    }
    if (view.card !== null) {
      draft.cardholderName = view.card.cardholderName;
      draft.brand = view.card.brand;
      draft.cardNumber = view.card.number;
      draft.expMonth = view.card.expMonth;
      draft.expYear = view.card.expYear;
      draft.cardCode = view.card.code;
    }
    if (view.identity !== null) {
      draft.firstName = view.identity.firstName;
      draft.middleName = view.identity.middleName;
      draft.lastName = view.identity.lastName;
      draft.company = view.identity.company;
      draft.identityEmail = view.identity.email;
      draft.phone = view.identity.phone;
      draft.ssn = view.identity.ssn;
      draft.passportNumber = view.identity.passportNumber;
      draft.licenseNumber = view.identity.licenseNumber;
      draft.address1 = view.identity.address1;
      draft.address2 = view.identity.address2;
      draft.address3 = view.identity.address3;
      draft.city = view.identity.city;
      draft.state = view.identity.state;
      draft.postalCode = view.identity.postalCode;
      draft.country = view.identity.country;
    }
    return draft;
  }
}

// ==========================================
// 6. 沙箱同步服务 (DemoSyncService - 修复 HIGH-v2-03)
// ==========================================

export class DemoSyncService extends SyncService {
  private readonly demoIndex: VaultMemoryIndex;

  constructor(index: VaultMemoryIndex, sessionService: SessionService,
    inMemoryPrefs: PreferencesStore, crypto: CryptoEngine) {
    super(
      index,
      new NullBwApiClient(),
      new NullVaultRepository(),
      crypto,
      sessionService,
      new DemoLockService(inMemoryPrefs) // 修复 CRIT-v2-04
    );
    this.demoIndex = index;
    // 修复 HIGH-v2-03: 立即反注册父类构造注册的 AppState 监听闭包，切断常驻内存泄漏
    this.destroy();
  }

  override indexState(): VaultMemoryIndex {
    return this.demoIndex;
  }

  override async sync(): Promise<void> {
    if (this.demoIndex.syncing) {
      return;
    }
    this.demoIndex.syncing = true;
    try {
      // 模拟纯内存同步耗时 (350ms)，提供真实的 UI 刷新微动效
      await new Promise<void>((resolve: () => void): void => {
        setTimeout(resolve, 350);
      });
      this.demoIndex.lastSyncAt = Date.now();
    } finally {
      this.demoIndex.syncing = false;
    }
  }

  override async touchLastUsed(id: string): Promise<void> {
    const current: CipherView | undefined = this.demoIndex.entries.find(
      (entry: CipherView): boolean => entry.id === id);
    if (current !== undefined) {
      current.lastUsedAt = Date.now();
      this.demoIndex.upsert(current);
    }
  }

  override removeLocally(id: string): void {
    this.demoIndex.remove(id);
  }

  override async refreshCipherLocally(id: string, deletedDate: number | null): Promise<void> {
    const current: CipherView | undefined = this.demoIndex.entries.find(
      (entry: CipherView): boolean => entry.id === id);
    if (current !== undefined) {
      const updated = new CipherView(
        current.id, current.type, current.name, current.favorite, current.folderId,
        deletedDate,
        Date.now(), current.username, current.password, current.totpSecret,
        current.uris.slice(0), current.notes, current.fields.slice(0), current.card, current.identity,
        current.attachments.slice(0), current.passwordHistory.slice(0), current.lastUsedAt
      );
      this.demoIndex.upsert(updated);
    }
  }

  override async rebuildFromRepository(): Promise<void> {
    // 体验模式无真实仓库，保持内存索引
  }

  override async upsertFromServerResponse(_response: CipherResponse): Promise<void> {
    // 体验模式无真实服务器响应
  }
}

// ==========================================
// 7. 沙箱附件服务 (NullAttachmentService)
// ==========================================

export class NullAttachmentService extends AttachmentService {
  constructor(sessionService: SessionService, repository: VaultRepository, crypto: CryptoEngine) {
    super(
      new NullBwApiClient(),
      new NullAttachmentTransport(),
      crypto,
      sessionService,
      repository,
      async (_res: CipherResponse): Promise<void> => {}
    );
  }

  override async upload(_cipherId: string, _fileName: string, _plain: Uint8Array,
    _onProgress: ProgressListener | null = null): Promise<CipherResponse> {
    throw new Error('UI 体验模式不支持附件上传');
  }

  override async download(_attachmentKey: string, _downloadUrl: string,
    _onProgress: ProgressListener | null = null,
    _cipherId: string | null = null): Promise<Uint8Array> {
    throw new Error('UI 体验模式不支持附件下载');
  }

  override async remove(_cipherId: string, _attachmentId: string): Promise<void> {
    // no-op
  }
}

// ==========================================
// 8. 沙箱设置服务 (DemoSettingsService)
// ==========================================

export class DemoSettingsService extends SettingsService {
  constructor(inMemoryPrefs: PreferencesStore) {
    super(inMemoryPrefs);
  }
}

// ==========================================
// 9. 沙箱构建工厂 (createDemoSandbox)
// ==========================================

export function createDemoSandbox(
  mockCiphers: CipherView[],
  mockFolders: FolderView[],
  crypto: CryptoEngine,
  onLogout: () => void
): DemoSandboxServices {
  const index: VaultMemoryIndex = new VaultMemoryIndex();
  index.replaceAll(mockCiphers, mockFolders, 0);

  const prefs: InMemoryPreferencesStore = new InMemoryPreferencesStore();
  const keyStore: NullKeyStore = new NullKeyStore();
  const repository: NullVaultRepository = new NullVaultRepository();
  const client: NullBwApiClient = new NullBwApiClient();
  const sink: NullSessionSink = new NullSessionSink();

  const session: DemoSessionService = new DemoSessionService(prefs, keyStore, sink, repository, onLogout);
  const lock: DemoLockService = new DemoLockService(prefs);
  const write: DemoWriteService = new DemoWriteService(index, session, crypto);
  const sync: DemoSyncService = new DemoSyncService(index, session, prefs, crypto);
  const attachment: NullAttachmentService = new NullAttachmentService(session, repository, crypto);
  const settings: DemoSettingsService = new DemoSettingsService(prefs);
  const clipboard: ClipboardService = new ClipboardService(new PasteboardAdapter(), prefs);

  return {
    index,
    write,
    sync,
    session,
    lock,
    prefs,
    keyStore,
    repository,
    attachment,
    settings,
    clipboard,
    client,
    destroySync: (): void => {
      sync.destroy();
    }
  };
}
