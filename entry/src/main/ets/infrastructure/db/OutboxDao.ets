/*
 * SPDX-FileCopyrightText: 2026 Liugt
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import { relationalStore } from '@kit.ArkData';
import { OutboxOp, OutboxOpType } from '../../domain/model/OutboxOp';

/**
 * outbox 表 DAO（票 07）：离线写队列 enqueue/peek/ack（spec F9 边界情况：
 * 离线操作入队，解锁且联网后按序重放）。seq 为 AUTOINCREMENT，保证按序取出。
 */
export class OutboxDao {
  private readonly store: relationalStore.RdbStore;

  constructor(store: relationalStore.RdbStore) {
    this.store = store;
  }

  async enqueue(cipherId: string, op: OutboxOpType, payload: string | null): Promise<void> {
    const bucket: relationalStore.ValuesBucket = {
      'cipher_id': cipherId,
      'op': op,
      'payload': payload,
      'created_at': Date.now()
    };
    await this.store.insert('outbox', bucket);
  }

  async peekAll(): Promise<OutboxOp[]> {
    const predicates = new relationalStore.RdbPredicates('outbox');
    predicates.orderByAsc('seq');
    const resultSet: relationalStore.ResultSet = await this.store.query(predicates);
    const ops: OutboxOp[] = [];
    while (resultSet.goToNextRow()) {
      const payloadIndex: number = resultSet.getColumnIndex('payload');
      ops.push(new OutboxOp(
        resultSet.getLong(resultSet.getColumnIndex('seq')),
        resultSet.getString(resultSet.getColumnIndex('cipher_id')),
        resultSet.getString(resultSet.getColumnIndex('op')) as OutboxOpType,
        resultSet.isColumnNull(payloadIndex) ? null : resultSet.getString(payloadIndex),
        resultSet.getLong(resultSet.getColumnIndex('created_at'))));
    }
    resultSet.close();
    return ops;
  }

  async ack(seq: number): Promise<void> {
    const predicates = new relationalStore.RdbPredicates('outbox');
    predicates.equalTo('seq', seq);
    await this.store.delete(predicates);
  }
}
