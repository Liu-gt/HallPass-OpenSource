/*
 * SPDX-FileCopyrightText: 2026 Liugt
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

/**
 * 保管库同步游标。lastSyncAt 为 epoch 毫秒值。
 */
export class SyncState {
  readonly vaultId: string;
  readonly lastSyncAt: number;

  constructor(vaultId: string, lastSyncAt: number) {
    this.vaultId = vaultId;
    this.lastSyncAt = lastSyncAt;
  }
}
