/*
 * SPDX-FileCopyrightText: 2026 Liugt
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

/**
 * 标准 Base64（含 padding）纯逻辑实现（票 13 新增）：application 层拼装附件二进制需要，
 * 禁 import @kit（可测性铁律），落 domain 纯工具。
 */
const ALPHABET: string = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';

export class B64 {
  static encode(bytes: Uint8Array): string {
    let out: string = '';
    let i: number = 0;
    for (; i + 2 < bytes.length; i += 3) {
      const n: number = (bytes[i] << 16) | (bytes[i + 1] << 8) | bytes[i + 2];
      out += ALPHABET[(n >> 18) & 63] + ALPHABET[(n >> 12) & 63]
        + ALPHABET[(n >> 6) & 63] + ALPHABET[n & 63];
    }
    const rem: number = bytes.length - i;
    if (rem === 1) {
      const n: number = bytes[i] << 16;
      out += ALPHABET[(n >> 18) & 63] + ALPHABET[(n >> 12) & 63] + '==';
    } else if (rem === 2) {
      const n: number = (bytes[i] << 16) | (bytes[i + 1] << 8);
      out += ALPHABET[(n >> 18) & 63] + ALPHABET[(n >> 12) & 63] + ALPHABET[(n >> 6) & 63] + '=';
    }
    return out;
  }

  static decode(text: string): Uint8Array {
    const clean: string = text.replace(/[\s]/g, '');
    const padding: number = clean.endsWith('==') ? 2 : (clean.endsWith('=') ? 1 : 0);
    const cleanBody: string = padding > 0 ? clean.substring(0, clean.length - padding) : clean;
    const byteLen: number = Math.floor((clean.length * 3) / 4) - padding;
    const out: Uint8Array = new Uint8Array(byteLen);
    let buffer: number = 0;
    let bits: number = 0;
    let outIndex: number = 0;
    for (let i = 0; i < cleanBody.length; i++) {
      const v: number = ALPHABET.indexOf(cleanBody.charAt(i));
      if (v < 0) {
        throw new Error('B64: invalid character');
      }
      buffer = (buffer << 6) | v;
      bits += 6;
      if (bits >= 8) {
        bits -= 8;
        out[outIndex++] = (buffer >> bits) & 0xff;
      }
    }
    return out;
  }
}
