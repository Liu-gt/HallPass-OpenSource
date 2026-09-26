/*
 * SPDX-FileCopyrightText: 2026 Liugt
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

/**
 * EncString 的两代格式（plan §1.3）。串行化形如 `<前缀>.<iv>|<ct>|<mac>`：
 * 前缀 `0` = AesCbc128，前缀 `2` = AesCbc256（映射见 domain/crypto/EncStringCodec）。
 */
export type EncStringFormat = 'AesCbc128_HmacSha256_B64' | 'AesCbc256_HmacSha256_B64';

/**
 * 密文字段值。纯数据类，iv/ct/mac 均为标准 Base64（含 padding）文本。
 */
export class EncString {
  readonly format: EncStringFormat;
  readonly iv: string;
  readonly ct: string;
  readonly mac: string;

  constructor(format: EncStringFormat, iv: string, ct: string, mac: string) {
    this.format = format;
    this.iv = iv;
    this.ct = ct;
    this.mac = mac;
  }
}
