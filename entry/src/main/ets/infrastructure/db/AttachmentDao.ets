/*
 * SPDX-FileCopyrightText: 2026 Liugt
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import { relationalStore } from '@kit.ArkData';
import { EncString } from '../../domain/model/EncString';
import { EncStringCodec } from '../../domain/crypto/EncStringCodec';

/** 附件元数据行：key 为附件加密密钥（EncString 串行化文本）。 */
export class AttachmentRow {
  readonly id: string;
  readonly cipherId: string;
  readonly size: number;
  readonly fileName: string;
  readonly key: string;
  readonly url: string;

  constructor(id: string, cipherId: string, size: number, fileName: string, key: string,
    url: string) {
    this.id = id;
    this.cipherId = cipherId;
    this.size = size;
    this.fileName = fileName;
    this.key = key;
    this.url = url;
  }
}

/**
 * attachments 表 DAO（票 07，plan §1.4）：附件元数据规范化存储（不内嵌 data JSON），
 * 以 cipher 为边界整组替换（写路径成功/同步替换时调用方负责触发）。
 * `data` 列存 { fileName, key, url } JSON（fileName/url 为解密后的明文元数据，
 * key 为 EncString 串行化文本——spec F15 附件密钥随条目加密存储）。
 */
export class AttachmentDao {
  private readonly store: relationalStore.RdbStore;

  constructor(store: relationalStore.RdbStore) {
    this.store = store;
  }

  async replaceForCipher(cipherId: string, rows: AttachmentRow[]): Promise<void> {
    const predicates = new relationalStore.RdbPredicates('attachments');
    predicates.equalTo('cipher_id', cipherId);
    await this.store.delete(predicates);
    for (let i = 0; i < rows.length; i++) {
      const row: AttachmentRow = rows[i];
      const payload: Record<string, Object> = {
        'fileName': row.fileName,
        'key': row.key,
        'url': row.url
      };
      const bucket: relationalStore.ValuesBucket = {
        'id': row.id,
        'cipher_id': row.cipherId,
        'size': row.size,
        'data': JSON.stringify(payload)
      };
      await this.store.insert('attachments', bucket);
    }
  }

  async getByCipher(cipherId: string): Promise<AttachmentRow[]> {
    const predicates = new relationalStore.RdbPredicates('attachments');
    predicates.equalTo('cipher_id', cipherId);
    const resultSet: relationalStore.ResultSet = await this.store.query(predicates);
    const rows: AttachmentRow[] = [];
    while (resultSet.goToNextRow()) {
      const payload: Record<string, Object> =
        JSON.parse(resultSet.getString(resultSet.getColumnIndex('data'))) as Record<string, Object>;
      rows.push(new AttachmentRow(
        resultSet.getString(resultSet.getColumnIndex('id')),
        resultSet.getString(resultSet.getColumnIndex('cipher_id')),
        resultSet.getLong(resultSet.getColumnIndex('size')),
        payload['fileName'] as string,
        payload['key'] as string,
        payload['url'] as string));
    }
    resultSet.close();
    return rows;
  }

  async deleteOrphans(): Promise<void> {
    await this.store.executeSql(
      'DELETE FROM attachments WHERE cipher_id NOT IN (SELECT id FROM ciphers)');
  }

  async decodeKey(row: AttachmentRow): Promise<EncString> {
    return EncStringCodec.decode(row.key);
  }
}
