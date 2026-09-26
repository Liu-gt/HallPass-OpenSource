/*
 * SPDX-FileCopyrightText: 2026 Liugt
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import { VaultRepository } from '../../domain/repository/VaultRepository';
import { Cipher } from '../../domain/model/Cipher';
import { Folder } from '../../domain/model/Folder';
import { Attachment } from '../../domain/model/Attachment';
import { OutboxOp, OutboxOpType } from '../../domain/model/OutboxOp';
import { SyncState } from '../../domain/model/SyncState';
import { EncStringCodec } from '../../domain/crypto/EncStringCodec';
import { CipherJsonCodec } from '../../domain/model/CipherJson';
import { relationalStore } from '@kit.ArkData';
import { CipherDao, CipherRow } from './CipherDao';
import { FolderDao, FolderRow } from './FolderDao';
import { AttachmentDao, AttachmentRow } from './AttachmentDao';
import { OutboxDao } from './OutboxDao';

/**
 * VaultRepository 实现（票 07）：RDB 密文缓存的唯一门面（plan D3）。
 * - 全量替换在事务内执行：任一步失败回滚到旧集合（票验收 2）；
 * - 附件规范化存 attachments 表，随条目写入整组替换，孤儿行清理；
 * - outbox/sync_meta 由对应 DAO/直查实现。
 */
export class VaultRepositoryImpl implements VaultRepository {
  private readonly store: relationalStore.RdbStore;
  private readonly cipherDao: CipherDao;
  private readonly folderDao: FolderDao;
  private readonly attachmentDao: AttachmentDao;
  private readonly outboxDao: OutboxDao;

  constructor(store: relationalStore.RdbStore) {
    this.store = store;
    this.cipherDao = new CipherDao(store);
    this.folderDao = new FolderDao(store);
    this.attachmentDao = new AttachmentDao(store);
    this.outboxDao = new OutboxDao(store);
  }

  async replaceCiphers(vaultId: string, ciphers: Cipher[]): Promise<void> {
    // T27：全量替换按 id 继承本地 last_used_at（服务器同步不覆盖本地行为元数据）
    const previousRows: CipherRow[] = await this.cipherDao.getAllForVault(vaultId);
    const lastUsedById: Map<string, number | null> = new Map();
    for (let i = 0; i < previousRows.length; i++) {
      lastUsedById.set(previousRows[i].id, previousRows[i].lastUsedAt);
    }
    this.store.beginTransaction();
    try {
      await this.cipherDao.deleteAllForVault(vaultId);
      for (let i = 0; i < ciphers.length; i++) {
        const inherited: number | null = lastUsedById.get(ciphers[i].id) ?? null;
        await this.writeCipher(vaultId, ciphers[i], inherited);
      }
      await this.attachmentDao.deleteOrphans();
      this.store.commit();
    } catch (e) {
      this.store.rollBack();
      throw e as Error;
    }
  }

  async upsertCipher(vaultId: string, cipher: Cipher): Promise<void> {
    this.store.beginTransaction();
    try {
      const previous: CipherRow | null = await this.cipherDao.getById(cipher.id);
      await this.writeCipher(vaultId, cipher,
        previous === null ? null : previous.lastUsedAt);
      this.store.commit();
    } catch (e) {
      this.store.rollBack();
      throw e as Error;
    }
  }

  async getCipher(vaultId: string, id: string): Promise<Cipher | null> {
    const row: CipherRow | null = await this.cipherDao.getById(id);
    if (row === null || row.vaultId !== vaultId) {
      return null;
    }
    const attachments: Attachment[] = await this.readAttachments(id);
    return CipherJsonCodec.decode(row.id, row.vaultId, row.type, null, row.revisionDate,
      row.favorite, row.folderId, row.deletedDate, row.dataJson, attachments,
      row.lastUsedAt ?? 0);
  }

  async getAllCiphers(vaultId: string): Promise<Cipher[]> {
    const rows: CipherRow[] = await this.cipherDao.getAllForVault(vaultId);
    const out: Cipher[] = [];
    for (let i = 0; i < rows.length; i++) {
      const row: CipherRow = rows[i];
      const attachments: Attachment[] = await this.readAttachments(row.id);
      out.push(CipherJsonCodec.decode(row.id, row.vaultId, row.type, null, row.revisionDate,
        row.favorite, row.folderId, row.deletedDate, row.dataJson, attachments,
        row.lastUsedAt ?? 0));
    }
    return out;
  }

  async removeCipher(vaultId: string, id: string): Promise<void> {
    this.store.beginTransaction();
    try {
      await this.cipherDao.delete(id);
      await this.attachmentDao.deleteOrphans();
      this.store.commit();
    } catch (e) {
      this.store.rollBack();
      throw e as Error;
    }
  }

  async replaceFolders(vaultId: string, folders: Folder[]): Promise<void> {
    this.store.beginTransaction();
    try {
      await this.folderDao.deleteAllForVault(vaultId);
      for (let i = 0; i < folders.length; i++) {
        const folder: Folder = folders[i];
        await this.folderDao.upsert(new FolderRow(folder.id, folder.vaultId, folder.revisionDate,
          VaultRepositoryImpl.folderDataJson(folder)));
      }
      this.store.commit();
    } catch (e) {
      this.store.rollBack();
      throw e as Error;
    }
  }

  async getAllFolders(vaultId: string): Promise<Folder[]> {
    const rows: FolderRow[] = await this.folderDao.getAllForVault(vaultId);
    const out: Folder[] = [];
    for (let i = 0; i < rows.length; i++) {
      const row: FolderRow = rows[i];
      // T28：data 列兼容两形态——裸 EncString（无 per-folder key，既有数据）或
      // {"name","key"} 信封（官方云 V2 per-folder key，无 schema 迁移）
      if (row.dataJson.startsWith('{')) {
        const obj: Record<string, Object> = JSON.parse(row.dataJson) as Record<string, Object>;
        const nameRaw: Object | undefined = obj['name'];
        const keyRaw: Object | undefined = obj['key'];
        out.push(new Folder(row.id, row.vaultId,
          EncStringCodec.decode(typeof nameRaw === 'string' ? nameRaw as string : ''),
          row.revisionDate, typeof keyRaw === 'string' ? keyRaw as string : null));
      } else {
        out.push(new Folder(row.id, row.vaultId, EncStringCodec.decode(row.dataJson),
          row.revisionDate));
      }
    }
    return out;
  }

  private static folderDataJson(folder: Folder): string {
    if (folder.key === null) {
      return EncStringCodec.encode(folder.name);
    }
    const envelope: Record<string, Object> = {
      'name': EncStringCodec.encode(folder.name) as Object,
      'key': folder.key as Object
    };
    return JSON.stringify(envelope);
  }

  async enqueueOp(cipherId: string, op: OutboxOpType, payload: string | null): Promise<void> {
    await this.outboxDao.enqueue(cipherId, op, payload);
  }

  async peekOutbox(): Promise<OutboxOp[]> {
    return this.outboxDao.peekAll();
  }

  async ackOp(seq: number): Promise<void> {
    await this.outboxDao.ack(seq);
  }

  async getSyncState(vaultId: string): Promise<SyncState | null> {
    const predicates = new relationalStore.RdbPredicates('sync_meta');
    predicates.equalTo('vault_id', vaultId);
    const resultSet: relationalStore.ResultSet = await this.store.query(predicates);
    let state: SyncState | null = null;
    if (resultSet.goToNextRow()) {
      const index: number = resultSet.getColumnIndex('last_sync_at');
      const last: number = resultSet.isColumnNull(index) ? 0 : resultSet.getLong(index);
      state = new SyncState(vaultId, last);
    }
    resultSet.close();
    return state;
  }

  async setSyncState(state: SyncState): Promise<void> {
    const predicates = new relationalStore.RdbPredicates('sync_meta');
    predicates.equalTo('vault_id', state.vaultId);
    await this.store.delete(predicates);
    const bucket: relationalStore.ValuesBucket = {
      'vault_id': state.vaultId,
      'last_sync_at': state.lastSyncAt
    };
    await this.store.insert('sync_meta', bucket);
  }

  /** 本地行为元数据：复制密码成功后更新 last_used（T27；不触发同步）。 */
  async touchLastUsed(vaultId: string, id: string, timestamp: number): Promise<void> {
    const row: CipherRow | null = await this.cipherDao.getById(id);
    if (row === null || row.vaultId !== vaultId) {
      return;
    }
    const bucket: relationalStore.ValuesBucket = {
      'last_used_at': timestamp
    };
    const predicates = new relationalStore.RdbPredicates('ciphers');
    predicates.equalTo('id', id);
    await this.store.update(bucket, predicates);
  }

  private async writeCipher(vaultId: string, cipher: Cipher,
    inheritedLastUsed: number | null = null): Promise<void> {
    const lastUsed: number | null = inheritedLastUsed !== null
      ? inheritedLastUsed : (cipher.lastUsedAt > 0 ? cipher.lastUsedAt : null);
    await this.cipherDao.upsert(new CipherRow(cipher.id, vaultId, cipher.type,
      cipher.folderId, cipher.favorite, cipher.revisionDate, cipher.deletedDate,
      CipherJsonCodec.encode(cipher), lastUsed));
    const rows: AttachmentRow[] = [];
    for (let i = 0; i < cipher.attachments.length; i++) {
      const a: Attachment = cipher.attachments[i];
      rows.push(new AttachmentRow(a.id, a.cipherId, a.size, a.fileName,
        EncStringCodec.encode(a.key), a.url));
    }
    await this.attachmentDao.replaceForCipher(cipher.id, rows);
  }

  private async readAttachments(cipherId: string): Promise<Attachment[]> {
    const rows: AttachmentRow[] = await this.attachmentDao.getByCipher(cipherId);
    const out: Attachment[] = [];
    for (let i = 0; i < rows.length; i++) {
      const row: AttachmentRow = rows[i];
      out.push(new Attachment(row.id, row.cipherId, row.fileName, row.size,
        await this.attachmentDao.decodeKey(row), row.url));
    }
    return out;
  }
}
