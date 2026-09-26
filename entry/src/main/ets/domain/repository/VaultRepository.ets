/*
 * SPDX-FileCopyrightText: 2026 Liugt
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import { Cipher } from '../model/Cipher';
import { Folder } from '../model/Folder';
import { OutboxOp, OutboxOpType } from '../model/OutboxOp';
import { SyncState } from '../model/SyncState';

/**
 * 保管库仓库接口（plan D3/D5，domain 唯一测试 seam 之一）：RDB 密文缓存的唯一门面。
 * 实现位于 infrastructure/db（relationalStore，schema 按 plan §1.4 冻结）。
 * 语义约定：
 * - 仓库只存密文与元数据；明文投影由 MemoryIndex（application 层）负责（ADR 安全基线）；
 * - replaceCiphers/replaceFolders 为全量同步替换，事务执行、失败回滚到旧集合（T07 验收）；
 * - outbox 提供 enqueue/peek/ack 语义（离线写操作按序重放，spec F9 边界情况）。
 */
export interface VaultRepository {
  /** 全量替换（事务）。ciphers 为 domain 模型（实现层负责序列化整包密文 JSON）。 */
  replaceCiphers(vaultId: string, ciphers: Cipher[]): Promise<void>;

  /** 单条写入（写路径成功后更新本地缓存）。 */
  upsertCipher(vaultId: string, cipher: Cipher): Promise<void>;

  /** 按 id 读取（无则返回 null，不区分是否在回收站）。 */
  getCipher(vaultId: string, id: string): Promise<Cipher | null>;

  /** 全量读取（含回收站条目，调用方按 deletedDate 过滤）。 */
  getAllCiphers(vaultId: string): Promise<Cipher[]>;

  /** 永久删除（硬删，本地与服务端语义一致）。 */
  removeCipher(vaultId: string, id: string): Promise<void>;

  /** 本地行为元数据（T27）：复制密码成功后更新最近使用时间；不触发同步。 */
  touchLastUsed(vaultId: string, id: string, timestamp: number): Promise<void>;

  /** 全量替换文件夹（事务）。 */
  replaceFolders(vaultId: string, folders: Folder[]): Promise<void>;

  /** 全量读取文件夹。 */
  getAllFolders(vaultId: string): Promise<Folder[]>;

  /** 离线写操作入队。 */
  enqueueOp(cipherId: string, op: OutboxOpType, payload: string | null): Promise<void>;

  /** 按序取出待重放操作（seq 升序，不消费）。 */
  peekOutbox(): Promise<OutboxOp[]>;

  /** 确认完成（重放成功后移除该条）。 */
  ackOp(seq: number): Promise<void>;

  /** 读取同步游标（无则返回 null）。 */
  getSyncState(vaultId: string): Promise<SyncState | null>;

  /** 写入同步游标。 */
  setSyncState(state: SyncState): Promise<void>;
}
