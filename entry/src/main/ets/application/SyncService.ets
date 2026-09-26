/*
 * SPDX-FileCopyrightText: 2026 Liugt
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import { VaultMemoryIndex, CipherView, FolderView, FieldView, FieldType2, AttachmentView,
  CardView, IdentityView, HistoryItemView } from './state/VaultMemoryIndex';
import { BwApiClient } from '../domain/protocol/BwApiClient';
import { CipherResponse } from '../domain/protocol/Types';
import { ProtocolError } from '../domain/protocol/Types';
import { ServerCipherCodec } from '../domain/protocol/ServerCipherCodec';
import { VaultRepository } from '../domain/repository/VaultRepository';
import { CryptoEngine, SymmetricKey } from '../domain/crypto/CryptoEngine';
import { Cipher } from '../domain/model/Cipher';
import { Folder } from '../domain/model/Folder';
import { EncString } from '../domain/model/EncString';
import { EncStringCodec } from '../domain/crypto/EncStringCodec';
import { SyncState } from '../domain/model/SyncState';
import { SessionService } from './SessionService';
import { LockService } from './LockService';
import { AppState, AppPhase, PhaseListener } from './state/AppState';
import { hilog } from '@kit.PerformanceAnalysisKit';
/** 解锁后重放离线写队列的钩子（由装配层注入，避免服务环依赖）。 */
export type ReplayHook = () => Promise<void>;

function toEpoch(iso: string): number {
  const ms: number = new Date(iso).getTime();
  return Number.isNaN(ms) ? 0 : ms;
}

/**
 * SyncService（票 11，spec F5/F9 数据语义、plan D3/R2）：
 * - 全量同步个人空间：组织条目过滤（ADR-0001）→ 密文落 RDB → 解密重建内存索引；
 * - 冲突 last-writer-wins（revisionDate，由全量替换语义保证）；
 * - 单条目解析/解密失败跳过并计数，不阻塞整库（R2）；
 * - 锁定事件 → 清空索引；解锁事件 → 从 RDB 密文重建（订阅票 10 LockService）。
 * 同步中旧索引可浏览（spec F5：不清空在途数据）。
 */
export class SyncService {
  protected readonly index: VaultMemoryIndex;
  protected readonly client: BwApiClient;
  protected readonly repository: VaultRepository;
  protected readonly crypto: CryptoEngine;
  protected readonly sessionService: SessionService;
  protected readonly lockService: LockService;
  protected replayHook: ReplayHook | null = null;
  protected viewGeneration: number = 0;
  /** 修复 HIGH-v2-03：持有着当前实例注册的监听器闭包，便于后续安全注销 */
  protected phaseListener: PhaseListener | null = null;

  constructor(index: VaultMemoryIndex, client: BwApiClient,
    repository: VaultRepository, crypto: CryptoEngine, sessionService: SessionService,
    lockService: LockService) {
    this.index = index;
    this.client = client;
    this.repository = repository;
    this.crypto = crypto;
    this.sessionService = sessionService;
    this.lockService = lockService;
    this.lockService.addListener((event: 'locked' | 'unlocked'): void => {
      if (event === 'unlocked') {
        const vaultId: string = this.sessionService.state.vaultId;
        const key: SymmetricKey | null = this.sessionService.userKey();
        const generation: number = this.viewGeneration;
        this.rebuildFromRepository().then((_v: void): Promise<void> => {
          // 解锁且联网后重放离线写队列（spec F9 边界情况；钩子由装配层注入）
          return key === null || !this.isCurrentView(vaultId, key, generation) || this.replayHook === null
            ? Promise.resolve() : this.replayHook();
        }).catch((_e: Object): void => {
          /* 重建/重放失败：下次解锁重试 */
        });
      }
    });
    // Invalidate in-flight views even if a later unlock restores the same key object.
    // 修复 HIGH-02：demo 相位豁免清退；
    // 修复 HIGH-v2-03：保存 listener 引用以支持 destroy 注销
    this.phaseListener = (phase: AppPhase): void => {
      if (phase !== 'unlocked' && phase !== 'demo') {
        this.viewGeneration++;
        this.index.clear();
        this.index.syncing = false;
      }
    };
    AppState.get().addPhaseListener(this.phaseListener);
  }

  /**
   * 修复 HIGH-v2-03：显式生命周期析构，从 AppState 中移除当前监听，彻底杜绝孤岛内存泄漏
   */
  destroy(): void {
    if (this.phaseListener !== null) {
      AppState.get().removePhaseListener(this.phaseListener);
      this.phaseListener = null;
    }
  }

  indexState(): VaultMemoryIndex {
    return this.index;
  }

  setReplayHook(hook: ReplayHook): void {
    this.replayHook = hook;
  }

  private isCurrentView(vaultId: string, key: SymmetricKey, generation: number): boolean {
    return generation === this.viewGeneration && AppState.get().phase === 'unlocked' &&
      this.sessionService.hasSession() && this.sessionService.state.vaultId === vaultId &&
      this.sessionService.userKey() === key;
  }

  async touchLastUsed(id: string): Promise<void> {
    const key: SymmetricKey | null = this.sessionService.userKey();
    if (key === null) {
      return;
    }
    const vaultId: string = this.sessionService.state.vaultId;
    const generation: number = this.viewGeneration;
    const timestamp: number = Date.now();
    await this.repository.touchLastUsed(vaultId, id, timestamp);
    if (!this.isCurrentView(vaultId, key, generation)) {
      return;
    }
    // Resolve after persistence: an edit/removal may have replaced the original view.
    const current: CipherView | undefined = this.index.entries.find(
      (entry: CipherView): boolean => entry.id === id);
    if (current !== undefined) {
      current.lastUsedAt = timestamp;
      this.index.upsert(current);
    }
  }

  /** 全量同步（登录后/解锁后/下拉刷新/写成功后触发）。 */
  async sync(): Promise<void> {
    if (this.index.syncing) {
      return;
    }
    const stretched: SymmetricKey | null = this.sessionService.userKey();
    if (stretched === null) {
      return;
    }
    const vaultId: string = this.sessionService.state.vaultId;
    const generation: number = this.viewGeneration;
    this.index.syncing = true;
    try {
      const response = await this.client.sync();
      if (!this.isCurrentView(vaultId, stretched, generation)) {
        return;
      }
      hilog.info(0x0000, 'HallPassSync',
        'sync response: ciphers=%{public}d folders=%{public}d', response.ciphers.length,
        response.folders.length);
      // ADR-0001：组织条目过滤（organizationId 非 null 即丢弃）
      const personal: CipherResponse[] = response.ciphers.filter(
        (c: CipherResponse): boolean => c.organizationId === null);
      const ciphers: Cipher[] = [];
      let skipped: number = response.ciphers.length - personal.length;
      for (let i = 0; i < personal.length; i++) {
        try {
          const parsed: Cipher = ServerCipherCodec.parse(personal[i]);
          ciphers.push(this.withVaultId(parsed, vaultId));
        } catch (e) {
          skipped++;
          this.logParseSkip(personal[i], e);
        }
      }
      const folders: Folder[] = [];
      for (let i = 0; i < response.folders.length; i++) {
        const f = response.folders[i];
        try {
          // T28：官方云 V2 账号 folders[].key（per-folder 密钥密文）原样入域模型，
          // 解密在 rebuildViews 展开；无 key 为传统用户密钥加密。
          folders.push(new Folder(f.id, vaultId, EncStringCodec.decode(f.name),
            toEpoch(f.revisionDate), f.key));
        } catch (e) {
          skipped++;
        }
      }
      await this.repository.replaceCiphers(vaultId, ciphers);
      await this.repository.replaceFolders(vaultId, folders);
      const now: number = Date.now();
      await this.repository.setSyncState(new SyncState(vaultId, now));
      const persisted: Cipher[] = await this.repository.getAllCiphers(vaultId);
      await this.rebuildViews(persisted, folders, stretched, vaultId, generation);
      if (!this.isCurrentView(vaultId, stretched, generation)) {
        return;
      }
      this.index.lastSyncAt = now;
      this.index.lastSkippedCount = skipped;
      hilog.info(0x0000, 'HallPassSync',
        'sync done: parsed=%{public}d skipped=%{public}d views=%{public}d', ciphers.length,
        skipped, this.index.entries.length);
    } catch (e) {
      const err: Error = e as Error;
      const proto: ProtocolError | null = e instanceof ProtocolError ? e as ProtocolError : null;
      hilog.error(0x0000, 'HallPassSync', 'sync fail: kind=%{public}s status=%{public}s msg=%{public}s server=%{public}s',
        proto === null ? 'unknown' : proto.kind, proto === null || proto.httpStatus === null ? '-' : `${proto.httpStatus}`,
        err.message ?? '', proto === null ? '-' : (proto.serverMessage ?? '-'));
      throw e as Error;
    } finally {
      if (this.isCurrentView(vaultId, stretched, generation)) {
        this.index.syncing = false;
      }
    }
  }

  /** 解析跳过的单条目：仅记 id 与无敏感内容的错误名/消息（fix-04 教训）。 */
  private logParseSkip(response: CipherResponse, e: Object): void {
    const err: Error = e as Error;
    hilog.error(0x0000, 'HallPassSync', 'parse skip id=%{public}s: %{public}s: %{public}s',
      response.id, err.name ?? 'unknown', err.message ?? '');
  }

  /** 解锁后从 RDB 密文重建明文索引（离线可用，spec 用户故事 23）。 */
  async rebuildFromRepository(): Promise<void> {
    const stretched: SymmetricKey | null = this.sessionService.userKey();
    if (stretched === null) {
      return;
    }
    const vaultId: string = this.sessionService.state.vaultId;
    const generation: number = this.viewGeneration;
    const ciphers: Cipher[] = await this.repository.getAllCiphers(vaultId);
    const folders: Folder[] = await this.repository.getAllFolders(vaultId);
    await this.rebuildViews(ciphers, folders, stretched, vaultId, generation);
  }

  /** 写路径成功后的单条目更新（WriteService 调用）。 */
  async upsertFromServerResponse(response: CipherResponse): Promise<void> {
    const stretched: SymmetricKey | null = this.sessionService.userKey();
    if (stretched === null) {
      return;
    }
    const vaultId: string = this.sessionService.state.vaultId;
    const generation: number = this.viewGeneration;
    const cipher: Cipher = this.withVaultId(ServerCipherCodec.parse(response), vaultId);
    await this.repository.upsertCipher(vaultId, cipher);
    const persisted: Cipher | null = await this.repository.getCipher(vaultId, cipher.id);
    if (persisted === null || !this.isCurrentView(vaultId, stretched, generation)) {
      return;
    }
    const view: CipherView | null = await this.buildView(persisted, stretched);
    if (view !== null && this.isCurrentView(vaultId, stretched, generation)) {
      this.index.upsert(view);
    }
  }

  /** 本地删除后的索引移除。 */
  removeLocally(id: string): void {
    this.index.remove(id);
  }

  /** 写路径（软删/恢复，含离线入队）后的本地条目重投影：
   *  以指定 deletedDate 重存 DB 并重建明文视图 upsert 进索引，回收站/主列表即时可见。 */
  async refreshCipherLocally(id: string, deletedDate: number | null): Promise<void> {
    const stretched: SymmetricKey | null = this.sessionService.userKey();
    if (stretched === null) {
      return;
    }
    const vaultId: string = this.sessionService.state.vaultId;
    const generation: number = this.viewGeneration;
    const cipher: Cipher | null = await this.repository.getCipher(vaultId, id);
    if (cipher === null || !this.isCurrentView(vaultId, stretched, generation)) {
      return;
    }
    const updated: Cipher = new Cipher(cipher.id, cipher.vaultId, cipher.type,
      cipher.organizationId, Date.now(), cipher.favorite, cipher.folderId, deletedDate,
      cipher.fields, cipher.login, cipher.notes, cipher.card, cipher.identity,
      cipher.attachments, cipher.name, cipher.passwordHistory, cipher.lastUsedAt,
      cipher.cipherKey);
    await this.repository.upsertCipher(vaultId, updated);
    const persisted: Cipher | null = await this.repository.getCipher(vaultId, id);
    if (persisted === null || !this.isCurrentView(vaultId, stretched, generation)) {
      return;
    }
    const view: CipherView | null = await this.buildView(persisted, stretched);
    if (view !== null && this.isCurrentView(vaultId, stretched, generation)) {
      this.index.upsert(view);
    }
  }

  private async rebuildViews(ciphers: Cipher[], folders: Folder[], stretched: SymmetricKey,
    vaultId: string, generation: number):
    Promise<void> {
    if (!this.isCurrentView(vaultId, stretched, generation)) {
      return;
    }
    const views: CipherView[] = [];
    let skipped: number = 0;
    for (let i = 0; i < ciphers.length; i++) {
      const view: CipherView | null = await this.buildView(ciphers[i], stretched);
      if (view === null) {
        skipped++;
      } else {
        views.push(view);
      }
    }
    const folderViews: FolderView[] = [];
    for (let i = 0; i < folders.length; i++) {
      try {
        // T28：per-folder key 以用户密钥解包后再解密文件夹名；无 key 直接用用户密钥
        let folderKey: SymmetricKey = stretched;
        if (folders[i].key !== null) {
          folderKey = await this.crypto.unwrapUserKey(folders[i].key as string, stretched);
        }
        folderViews.push(new FolderView(folders[i].id,
          await this.decryptText(folders[i].name, folderKey)));
      } catch (e) {
        skipped++;
      }
    }
    if (this.isCurrentView(vaultId, stretched, generation)) {
      this.index.replaceAll(views, folderViews, skipped);
    }
  }

  /** 解密投影；任何字段解密/解析失败 → 整条目跳过（R2）。
   *  V2 加密（DIAG-02）：条目带 cipherKey 时先以用户密钥解开条目密钥，
   *  再用条目密钥解密全部字段；传统条目直接用用户密钥。 */
  private async buildView(cipher: Cipher, stretched: SymmetricKey): Promise<CipherView | null> {
    try {
      let key: SymmetricKey = stretched;
      if (cipher.cipherKey !== null) {
        try {
          key = await this.crypto.unwrapUserKey(cipher.cipherKey, stretched);
        } catch (e) {
          const err: Error = e as Error;
          hilog.error(0x0000, 'HallPassSync', 'cipherKey unwrap fail id=%{public}s: %{public}s',
            cipher.id, err.message ?? '');
          return null;
        }
      }
      let username: string = '';
      let password: string = '';
      let totpSecret: string = '';
      const uris: string[] = [];
      const login = cipher.login;
      if (login !== null) {
        username = login.username === null ? '' : await this.decryptText(login.username, key);
        password = login.password === null ? '' : await this.decryptText(login.password, key);
        totpSecret = login.totp === null ? '' : await this.decryptText(login.totp, key);
        for (let i = 0; i < login.uris.length; i++) {
          uris.push(await this.decryptText(login.uris[i], key));
        }
      }
      const notes: string = cipher.notes === null ? '' : await this.decryptText(cipher.notes, key);
      const name: string = cipher.name === null ? '' : await this.decryptText(cipher.name, key);
      const fields: FieldView[] = [];
      for (let i = 0; i < cipher.fields.length; i++) {
        const f = cipher.fields[i];
        fields.push(new FieldView((f.type as number) as FieldType2,
          await this.decryptText(f.name, key),
          f.value === null ? '' : await this.decryptText(f.value, key),
          f.type === 1, f.linkedId));
      }
      const attachments: AttachmentView[] = [];
      for (let i = 0; i < cipher.attachments.length; i++) {
        const a = cipher.attachments[i];
        attachments.push(new AttachmentView(a.id, a.fileName, a.size,
          EncStringCodec.encode(a.key), a.url));
      }
      let card: CardView | null = null;
      if (cipher.card !== null) {
        card = new CardView(
          cipher.card.cardholderName === null ? '' : await this.decryptText(cipher.card.cardholderName, key),
          cipher.card.brand === null ? '' : await this.decryptText(cipher.card.brand, key),
          cipher.card.number === null ? '' : await this.decryptText(cipher.card.number, key),
          cipher.card.expMonth === null ? '' : await this.decryptText(cipher.card.expMonth, key),
          cipher.card.expYear === null ? '' : await this.decryptText(cipher.card.expYear, key),
          cipher.card.code === null ? '' : await this.decryptText(cipher.card.code, key));
      }
      let identity: IdentityView | null = null;
      if (cipher.identity !== null) {
        identity = new IdentityView(
          cipher.identity.firstName === null ? '' : await this.decryptText(cipher.identity.firstName, key),
          cipher.identity.middleName === null ? '' : await this.decryptText(cipher.identity.middleName, key),
          cipher.identity.lastName === null ? '' : await this.decryptText(cipher.identity.lastName, key),
          cipher.identity.company === null ? '' : await this.decryptText(cipher.identity.company, key),
          cipher.identity.email === null ? '' : await this.decryptText(cipher.identity.email, key),
          cipher.identity.phone === null ? '' : await this.decryptText(cipher.identity.phone, key),
          cipher.identity.ssn === null ? '' : await this.decryptText(cipher.identity.ssn, key),
          cipher.identity.passportNumber === null ? '' : await this.decryptText(cipher.identity.passportNumber, key),
          cipher.identity.licenseNumber === null ? '' : await this.decryptText(cipher.identity.licenseNumber, key),
          cipher.identity.address1 === null ? '' : await this.decryptText(cipher.identity.address1, key),
          cipher.identity.address2 === null ? '' : await this.decryptText(cipher.identity.address2, key),
          cipher.identity.address3 === null ? '' : await this.decryptText(cipher.identity.address3, key),
          cipher.identity.city === null ? '' : await this.decryptText(cipher.identity.city, key),
          cipher.identity.state === null ? '' : await this.decryptText(cipher.identity.state, key),
          cipher.identity.postalCode === null ? '' : await this.decryptText(cipher.identity.postalCode, key),
          cipher.identity.country === null ? '' : await this.decryptText(cipher.identity.country, key));
      }
      const history: HistoryItemView[] = [];
      for (let i = 0; i < cipher.passwordHistory.length; i++) {
        const h = cipher.passwordHistory[i];
        history.push(new HistoryItemView(
          await this.decryptText(h.password, key), h.lastModifiedDate));
      }
      return new CipherView(cipher.id, cipher.type, name, cipher.favorite, cipher.folderId,
        cipher.deletedDate, cipher.revisionDate, username, password, totpSecret, uris, notes,
        fields, card, identity, attachments, history, cipher.lastUsedAt);
    } catch (e) {
      // 单条目解密失败即跳过（R2）；保留一行无敏感内容的错误日志（fix-04 教训：失败不再静默）
      const err: Error = e as Error;
      hilog.error(0x0000, 'HallPassSync', 'buildView fail id=%{public}s: %{public}s: %{public}s',
        cipher.id, err.name ?? 'unknown', err.message ?? '');
      return null;
    }
  }

  private async decryptText(enc: EncString, stretched: SymmetricKey): Promise<string> {
    return this.crypto.decryptToString(enc, stretched);
  }

  private withVaultId(cipher: Cipher, vaultId: string): Cipher {
    return new Cipher(cipher.id, vaultId, cipher.type, cipher.organizationId, cipher.revisionDate,
      cipher.favorite, cipher.folderId, cipher.deletedDate, cipher.fields, cipher.login,
      cipher.notes, cipher.card, cipher.identity, cipher.attachments, cipher.name,
      cipher.passwordHistory, cipher.lastUsedAt, cipher.cipherKey);
  }
}
