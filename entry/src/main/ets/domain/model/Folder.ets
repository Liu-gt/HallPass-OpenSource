/*
 * SPDX-FileCopyrightText: 2026 Liugt
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import { EncString } from './EncString';

/**
 * 文件夹。name 为文件夹名的密文（EncString），列表展示时经解密投影到内存索引。
 * key（T28）：per-folder 密钥密文（EncString 串行化文本，由用户密钥包裹）；
 * 官方云 V2 账号可能出现，name 以该密钥加密；null = 传统用户密钥加密。
 */
export class Folder {
  readonly id: string;
  readonly vaultId: string;
  readonly name: EncString;
  readonly revisionDate: number;
  readonly key: string | null;

  constructor(id: string, vaultId: string, name: EncString, revisionDate: number,
    key: string | null = null) {
    this.id = id;
    this.vaultId = vaultId;
    this.name = name;
    this.revisionDate = revisionDate;
    this.key = key;
  }
}
