/*
 * SPDX-FileCopyrightText: 2026 Liugt
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import { common } from '@kit.AbilityKit';
import { relationalStore } from '@kit.ArkData';

/**
 * RDB 入口（票 07，plan §1.4）：建表 + 版本迁移。
 * `ciphers.data` 存整包密文 JSON，schema 冻结不迁移（plan D3/R2）；
 * 版本迁移仅限元数据类列/表（T27：v2 增 `ciphers.last_used_at`），升级路径只允许新增表/列。
 */
export class Db {
  static readonly DB_NAME: string = 'hallpass_vault.db';
  static readonly DB_VERSION: number = 2;

  private static store: relationalStore.RdbStore | null = null;

  static async open(context: common.Context): Promise<relationalStore.RdbStore> {
    if (Db.store !== null) {
      return Db.store;
    }
    const config: relationalStore.StoreConfig = {
      name: Db.DB_NAME,
      securityLevel: relationalStore.SecurityLevel.S1
    };
    const opened: relationalStore.RdbStore = await relationalStore.getRdbStore(context, config);
    const previousVersion: number = opened.version;
    await Db.ensureTables(opened);
    await Db.migrate(opened, previousVersion);
    opened.version = Db.DB_VERSION;
    Db.store = opened;
    return opened;
  }

  /** 仅测试注入使用：替换已打开的存储句柄。 */
  static attachForTest(store: relationalStore.RdbStore): void {
    Db.store = store;
  }

  private static async ensureTables(store: relationalStore.RdbStore): Promise<void> {
    await store.executeSql(
      `CREATE TABLE IF NOT EXISTS ciphers (
        id TEXT PRIMARY KEY,
        vault_id TEXT NOT NULL,
        type INTEGER NOT NULL,
        folder_id TEXT,
        favorite INTEGER NOT NULL DEFAULT 0,
        revision_date INTEGER NOT NULL,
        deleted_date INTEGER,
        last_used_at INTEGER,
        data TEXT NOT NULL
      )`);
    await store.executeSql(
      `CREATE TABLE IF NOT EXISTS folders (
        id TEXT PRIMARY KEY,
        vault_id TEXT NOT NULL,
        revision_date INTEGER NOT NULL,
        data TEXT NOT NULL
      )`);
    await store.executeSql(
      `CREATE TABLE IF NOT EXISTS attachments (
        id TEXT PRIMARY KEY,
        cipher_id TEXT NOT NULL,
        size INTEGER NOT NULL,
        data TEXT NOT NULL
      )`);
    await store.executeSql(
      `CREATE TABLE IF NOT EXISTS outbox (
        seq INTEGER PRIMARY KEY AUTOINCREMENT,
        cipher_id TEXT NOT NULL,
        op TEXT NOT NULL,
        payload TEXT,
        created_at INTEGER NOT NULL
      )`);
    await store.executeSql(
      `CREATE TABLE IF NOT EXISTS sync_meta (
        vault_id TEXT PRIMARY KEY,
        last_sync_at INTEGER
      )`);
  }

  /** 版本迁移（T27）：v1 → v2 补 ciphers.last_used_at；既有行按 NULL（从未使用）处理。 */
  private static async migrate(store: relationalStore.RdbStore,
    previousVersion: number): Promise<void> {
    if (previousVersion >= 2) {
      return;
    }
    try {
      await store.executeSql('ALTER TABLE ciphers ADD COLUMN last_used_at INTEGER');
    } catch (e) {
      // 列已存在（新装库由 CREATE 语句携带该列）时忽略
    }
  }
}
