/*
 * SPDX-FileCopyrightText: 2026 Liugt
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import { relationalStore } from '@kit.ArkData';

/** folders 表 DAO（票 07）：`data` 列存文件夹名密文（EncString 串行化文本）。 */
export class FolderRow {
  readonly id: string;
  readonly vaultId: string;
  readonly revisionDate: number;
  readonly dataJson: string;

  constructor(id: string, vaultId: string, revisionDate: number, dataJson: string) {
    this.id = id;
    this.vaultId = vaultId;
    this.revisionDate = revisionDate;
    this.dataJson = dataJson;
  }
}

export class FolderDao {
  private readonly store: relationalStore.RdbStore;

  constructor(store: relationalStore.RdbStore) {
    this.store = store;
  }

  async upsert(row: FolderRow): Promise<void> {
    const bucket: relationalStore.ValuesBucket = {
      'id': row.id,
      'vault_id': row.vaultId,
      'revision_date': row.revisionDate,
      'data': row.dataJson
    };
    const predicates = new relationalStore.RdbPredicates('folders');
    predicates.equalTo('id', row.id);
    await this.store.delete(predicates);
    await this.store.insert('folders', bucket);
  }

  async deleteAllForVault(vaultId: string): Promise<void> {
    const predicates = new relationalStore.RdbPredicates('folders');
    predicates.equalTo('vault_id', vaultId);
    await this.store.delete(predicates);
  }

  async getAllForVault(vaultId: string): Promise<FolderRow[]> {
    const predicates = new relationalStore.RdbPredicates('folders');
    predicates.equalTo('vault_id', vaultId);
    const resultSet: relationalStore.ResultSet = await this.store.query(predicates);
    const rows: FolderRow[] = [];
    while (resultSet.goToNextRow()) {
      rows.push(new FolderRow(
        resultSet.getString(resultSet.getColumnIndex('id')),
        resultSet.getString(resultSet.getColumnIndex('vault_id')),
        resultSet.getLong(resultSet.getColumnIndex('revision_date')),
        resultSet.getString(resultSet.getColumnIndex('data'))));
    }
    resultSet.close();
    return rows;
  }
}
