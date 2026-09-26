/*
 * SPDX-FileCopyrightText: 2026 Liugt
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import { EncString } from './EncString';

/**
 * 条目附件元数据。key 为附件加密密钥（随条目加密存储）；fileName/url 为协议层解密后的明文元数据。
 */
export class Attachment {
  readonly id: string;
  readonly cipherId: string;
  readonly fileName: string;
  readonly size: number;
  readonly key: EncString;
  readonly url: string;

  constructor(id: string, cipherId: string, fileName: string, size: number, key: EncString, url: string) {
    this.id = id;
    this.cipherId = cipherId;
    this.fileName = fileName;
    this.size = size;
    this.key = key;
    this.url = url;
  }
}
