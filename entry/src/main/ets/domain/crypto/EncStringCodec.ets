/*
 * SPDX-FileCopyrightText: 2026 Liugt
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import { EncString, EncStringFormat } from '../model/EncString';

const PREFIX_SEPARATOR = '.';
const SEGMENT_SEPARATOR = '|';
const AES_CBC128_PREFIX = '0';
const AES_CBC256_PREFIX = '2';

/**
 * 标准 Base64（含 padding）：总长为 4 的倍数、字符集合法、'=' 只能作为结尾 1–2 个填充。
 */
const BASE64_PATTERN = /^[A-Za-z0-9+/]*={0,2}$/;

function isBase64(value: string): boolean {
  if (value.length === 0 || value.length % 4 !== 0) {
    return false;
  }
  return BASE64_PATTERN.test(value);
}

function prefixOf(format: EncStringFormat): string {
  return format === 'AesCbc128_HmacSha256_B64' ? AES_CBC128_PREFIX : AES_CBC256_PREFIX;
}

/**
 * EncString 与串行化文本互转（纯逻辑，无任何系统依赖，可本地单测）。
 * 与 Bitwarden 官方客户端解析行为一致：只校验结构与 Base64 合法性；
 * iv/mac 的字节长度等密码学校验在解密时（CryptoEngine）进行。
 * 错误信息不含密文内容，避免泄露到日志。
 */
export class EncStringCodec {
  /** 解析 `0.iv|ct|mac` / `2.iv|ct|mac`；缺段、空段、非法 Base64、未知前缀一律抛 Error。 */
  static decode(raw: string): EncString {
    const prefixEnd = raw.indexOf(PREFIX_SEPARATOR);
    if (prefixEnd <= 0) {
      throw new Error('EncStringCodec: missing format prefix');
    }
    const prefix = raw.substring(0, prefixEnd);
    let format: EncStringFormat;
    if (prefix === AES_CBC128_PREFIX) {
      format = 'AesCbc128_HmacSha256_B64';
    } else if (prefix === AES_CBC256_PREFIX) {
      format = 'AesCbc256_HmacSha256_B64';
    } else {
      throw new Error(`EncStringCodec: unsupported format prefix '${prefix}'`);
    }

    const segments = raw.substring(prefixEnd + 1).split(SEGMENT_SEPARATOR);
    if (segments.length !== 3) {
      throw new Error(`EncStringCodec: expected 3 segments, got ${segments.length}`);
    }
    for (let i = 0; i < segments.length; i++) {
      if (!isBase64(segments[i])) {
        throw new Error(`EncStringCodec: invalid Base64 segment at index ${i} (length ${segments[i].length})`);
      }
    }
    return new EncString(format, segments[0], segments[1], segments[2]);
  }

  /** 序列化为 `<前缀>.<iv>|<ct>|<mac>`。 */
  static encode(enc: EncString): string {
    return `${prefixOf(enc.format)}${PREFIX_SEPARATOR}${enc.iv}${SEGMENT_SEPARATOR}${enc.ct}${SEGMENT_SEPARATOR}${enc.mac}`;
  }
}
