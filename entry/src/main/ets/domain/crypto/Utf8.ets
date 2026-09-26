/*
 * SPDX-FileCopyrightText: 2026 Liugt
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

/**
 * UTF-8 编解码（票 11 新增，plan D1 common 纯工具的 domain 侧收口）：
 * application/infrastructure 需要字节转换但禁 import @kit（可测性铁律），故落 domain。
 */
export class Utf8 {
  static encode(text: string): Uint8Array {
    const out: number[] = [];
    for (let i = 0; i < text.length; i++) {
      let code: number = text.charCodeAt(i);
      if (code >= 0xD800 && code <= 0xDBFF && i + 1 < text.length) {
        const lo: number = text.charCodeAt(i + 1);
        if (lo >= 0xDC00 && lo <= 0xDFFF) {
          code = 0x10000 + ((code - 0xD800) << 10) + (lo - 0xDC00);
          i++;
        }
      }
      if (code < 0x80) {
        out.push(code);
      } else if (code < 0x800) {
        out.push(0xC0 | (code >> 6), 0x80 | (code & 63));
      } else if (code < 0x10000) {
        out.push(0xE0 | (code >> 12), 0x80 | ((code >> 6) & 63), 0x80 | (code & 63));
      } else {
        out.push(0xF0 | (code >> 18), 0x80 | ((code >> 12) & 63),
          0x80 | ((code >> 6) & 63), 0x80 | (code & 63));
      }
    }
    const arr: Uint8Array = new Uint8Array(out.length);
    for (let i = 0; i < out.length; i++) {
      arr[i] = out[i];
    }
    return arr;
  }

  static decode(bytes: Uint8Array): string {
    let out: string = '';
    let i: number = 0;
    while (i < bytes.length) {
      const b: number = bytes[i];
      let code: number;
      if (b < 0x80) {
        code = b;
        i += 1;
      } else if (b < 0xE0) {
        code = ((b & 31) << 6) | (bytes[i + 1] & 63);
        i += 2;
      } else if (b < 0xF0) {
        code = ((b & 15) << 12) | ((bytes[i + 1] & 63) << 6) | (bytes[i + 2] & 63);
        i += 3;
      } else {
        code = ((b & 7) << 18) | ((bytes[i + 1] & 63) << 12) | ((bytes[i + 2] & 63) << 6)
          | (bytes[i + 3] & 63);
        i += 4;
      }
      if (code >= 0x10000) {
        code -= 0x10000;
        out += String.fromCharCode(0xD800 + (code >> 10), 0xDC00 + (code & 0x3FF));
      } else {
        out += String.fromCharCode(code);
      }
    }
    return out;
  }
}
