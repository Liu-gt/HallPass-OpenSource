/*
 * SPDX-FileCopyrightText: 2026 Liugt
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import { relationalStore } from '@kit.ArkData';

/**
 * ciphers 表 DAO（票 07）：密文缓存读写；`data` 列为整包密文 JSON（domain 编解码，plan R2）。
 * 列序与 plan §1.4 schema 一致（锁定）。
 */
export class CipherRow {
  readonly id: string;
  readonly vaultId: string;
  readonly type: number;
  readonly folderId: string | null;
  readonly favorite: boolean;
  readonly revisionDate: number;
  readonly deletedDate: number | null;
  readonly dataJson: string;
  /** 最近使用时间（T27 本地行为元数据；null = 从未使用，plan §1.4 v1.1）。 */
  readonly lastUsedAt: number | null;

  constructor(id: string, vaultId: string, type: number, folderId: string | null,
    favorite: boolean, revisionDate: number, deletedDate: number | null, dataJson: string,
    lastUsedAt: number | null = null) {
    this.id = id;
    this.vaultId = vaultId;
    this.type = type;
    this.folderId = folderId;
    this.favorite = favorite;
    this.revisionDate = revisionDate;
    this.deletedDate = deletedDate;
    this.dataJson = dataJson;
    this.lastUsedAt = lastUsedAt;
  }
}

export class CipherDao {
  private readonly store: relationalStore.RdbStore;

  constructor(store: relationalStore.RdbStore) {
    this.store = store;
  }

  /** 写入/更新一行（调用方负责事务边界）。 */
  async upsert(row: CipherRow): Promise<void> {
    const bucket: relationalStore.ValuesBucket = {
      'id': row.id,
      'vault_id': row.vaultId,
      'type': row.type,
      'folder_id': row.folderId,
      'favorite': row.favorite ? 1 : 0,
      'revision_date': row.revisionDate,
      'deleted_date': row.deletedDate,
      'last_used_at': row.lastUsedAt,
      'data': row.dataJson
    };
    // 幂等写入：先按主键删除再插入，避免 INSERT OR REPLACE 在部分版本上的静默语义差异
    const predicates = new relationalStore.RdbPredicates('ciphers');
    predicates.equalTo('id', row.id);
    await this.store.delete(predicates);
    await this.store.insert('ciphers', bucket);
  }

  async delete(id: string): Promise<void> {
    const predicates = new relationalStore.RdbPredicates('ciphers');
    predicates.equalTo('id', id);
    await this.store.delete(predicates);
  }

  async deleteAllForVault(vaultId: string): Promise<void> {
    const predicates = new relationalStore.RdbPredicates('ciphers');
    predicates.equalTo('vault_id', vaultId);
    await this.store.delete(predicates);
  }

  async getById(id: string): Promise<CipherRow | null> {
    const predicates = new relationalStore.RdbPredicates('ciphers');
    predicates.equalTo('id', id);
    const resultSet: relationalStore.ResultSet = await this.store.query(predicates);
    const row: CipherRow | null = CipherDao.firstRow(resultSet);
    resultSet.close();
    return row;
  }

  async getAllForVault(vaultId: string): Promise<CipherRow[]> {
    const predicates = new relationalStore.RdbPredicates('ciphers');
    predicates.equalTo('vault_id', vaultId);
    const resultSet: relationalStore.ResultSet = await this.store.query(predicates);
    const rows: CipherRow[] = [];
    while (resultSet.goToNextRow()) {
      rows.push(CipherDao.readRow(resultSet));
    }
    resultSet.close();
    return rows;
  }

  private static firstRow(resultSet: relationalStore.ResultSet): CipherRow | null {
    if (!resultSet.goToNextRow()) {
      return null;
    }
    return CipherDao.readRow(resultSet);
  }

  private static readRow(resultSet: relationalStore.ResultSet): CipherRow {
    // 列序：id, vault_id, type, folder_id, favorite, revision_date, deleted_date, last_used_at, data
    const folderIndex: number = resultSet.getColumnIndex('folder_id');
    const deletedIndex: number = resultSet.getColumnIndex('deleted_date');
    const lastUsedIndex: number = resultSet.getColumnIndex('last_used_at');
    const folderId: string | null =
      resultSet.isColumnNull(folderIndex) ? null : resultSet.getString(folderIndex);
    const deletedRaw: number = resultSet.getLong(deletedIndex);
    const lastUsedAt: number | null =
      resultSet.isColumnNull(lastUsedIndex) ? null : resultSet.getLong(lastUsedIndex);
    return new CipherRow(
      resultSet.getString(resultSet.getColumnIndex('id')),
      resultSet.getString(resultSet.getColumnIndex('vault_id')),
      resultSet.getLong(resultSet.getColumnIndex('type')),
      folderId,
      resultSet.getLong(resultSet.getColumnIndex('favorite')) === 1,
      resultSet.getLong(resultSet.getColumnIndex('revision_date')),
      resultSet.isColumnNull(deletedIndex) ? null : deletedRaw,
      resultSet.getString(resultSet.getColumnIndex('data')),
      lastUsedAt
    );
  }
}
