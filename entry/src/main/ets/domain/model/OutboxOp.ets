/*
 * SPDX-FileCopyrightText: 2026 Liugt
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

/**
 * 离线写队列操作类型。字符串字面量直接对应 RDB `outbox.op` TEXT 列（plan §1.4）。
 */
export type OutboxOpType = 'save' | 'softDelete' | 'restore' | 'hardDelete';

/**
 * 待重放的写操作。payload 为可选的加密载荷（EncString 结构 JSON）；createdAt 为 epoch 毫秒值。
 */
export class OutboxOp {
  readonly seq: number;
  readonly cipherId: string;
  readonly op: OutboxOpType;
  readonly payload: string | null;
  readonly createdAt: number;

  constructor(seq: number, cipherId: string, op: OutboxOpType, payload: string | null, createdAt: number) {
    this.seq = seq;
    this.cipherId = cipherId;
    this.op = op;
    this.payload = payload;
    this.createdAt = createdAt;
  }
}
