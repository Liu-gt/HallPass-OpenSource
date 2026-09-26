/*
 * SPDX-FileCopyrightText: 2026 Liugt
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import { VaultRepository } from '../../main/ets/domain/repository/VaultRepository';
import { Cipher } from '../../main/ets/domain/model/Cipher';
import { Folder } from '../../main/ets/domain/model/Folder';
import { OutboxOp, OutboxOpType } from '../../main/ets/domain/model/OutboxOp';
import { SyncState } from '../../main/ets/domain/model/SyncState';

/**
 * FakeRepository（T04 测试假实现）：内存版 VaultRepository，语义与真实 RDB 实现对齐
 * （全量替换为整体切换、outbox 按序 peek/ack），供后续票单测驱动同步与写路径。
 */
export class FakeRepository implements VaultRepository {
  private ciphers: Map<string, Cipher> = new Map();
  private folders: Map<string, Folder> = new Map();
  private outbox: OutboxOp[] = [];
  private nextSeq: number = 1;
  private syncState: SyncState | null = null;

  replaceCiphers(vaultId: string, ciphers: Cipher[]): Promise<void> {
    this.ciphers.clear();
    for (let i = 0; i < ciphers.length; i++) {
      this.ciphers.set(ciphers[i].id, ciphers[i]);
    }
    return Promise.resolve();
  }

  upsertCipher(vaultId: string, cipher: Cipher): Promise<void> {
    this.ciphers.set(cipher.id, cipher);
    return Promise.resolve();
  }

  getCipher(vaultId: string, id: string): Promise<Cipher | null> {
    const found: Cipher | undefined = this.ciphers.get(id);
    return Promise.resolve(found === undefined ? null : found);
  }

  getAllCiphers(vaultId: string): Promise<Cipher[]> {
    const out: Cipher[] = [];
    this.ciphers.forEach((value: Cipher): void => {
      out.push(value);
    });
    return Promise.resolve(out);
  }

  removeCipher(vaultId: string, id: string): Promise<void> {
    this.ciphers.delete(id);
    return Promise.resolve();
  }

  touchLastUsed(vaultId: string, id: string, timestamp: number): Promise<void> {
    const found: Cipher | undefined = this.ciphers.get(id);
    if (found !== undefined) {
      this.ciphers.set(id, new Cipher(found.id, found.vaultId, found.type, found.organizationId,
        found.revisionDate, found.favorite, found.folderId, found.deletedDate, found.fields,
        found.login, found.notes, found.card, found.identity, found.attachments, found.name,
        found.passwordHistory, timestamp, found.cipherKey));
    }
    return Promise.resolve();
  }

  replaceFolders(vaultId: string, folders: Folder[]): Promise<void> {
    this.folders.clear();
    for (let i = 0; i < folders.length; i++) {
      this.folders.set(folders[i].id, folders[i]);
    }
    return Promise.resolve();
  }

  getAllFolders(vaultId: string): Promise<Folder[]> {
    const out: Folder[] = [];
    this.folders.forEach((value: Folder): void => {
      out.push(value);
    });
    return Promise.resolve(out);
  }

  enqueueOp(cipherId: string, op: OutboxOpType, payload: string | null): Promise<void> {
    this.outbox.push(new OutboxOp(this.nextSeq++, cipherId, op, payload, Date.now()));
    return Promise.resolve();
  }

  peekOutbox(): Promise<OutboxOp[]> {
    const sorted: OutboxOp[] = this.outbox.slice(0);
    sorted.sort((a: OutboxOp, b: OutboxOp): number => a.seq - b.seq);
    return Promise.resolve(sorted);
  }

  ackOp(seq: number): Promise<void> {
    this.outbox = this.outbox.filter((value: OutboxOp): boolean => value.seq !== seq);
    return Promise.resolve();
  }

  getSyncState(vaultId: string): Promise<SyncState | null> {
    return Promise.resolve(this.syncState);
  }

  setSyncState(state: SyncState): Promise<void> {
    this.syncState = state;
    return Promise.resolve();
  }
}
