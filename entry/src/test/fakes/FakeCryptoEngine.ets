/*
 * SPDX-FileCopyrightText: 2026 Liugt
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import { CryptoEngine, SymmetricKey } from '../../main/ets/domain/crypto/CryptoEngine';
import { EncStringCodec } from '../../main/ets/domain/crypto/EncStringCodec';
import { EncString, EncStringFormat } from '../../main/ets/domain/model/EncString';
import { KdfParams, KdfType } from '../../main/ets/domain/model/VaultContext';

/**
 * FakeCryptoEngine（T04 测试假实现，spec §4.5）：确定性、可逆的纯逻辑加解密，
 * 供后续票的本地单测驱动完整流程（同步/写路径/登录编排），不依赖任何系统能力。
 * - "密文" = Base64(明文字节)，iv 固定 16 字节零值，mac 固定值；MAC 不匹配时按契约抛错；
 * - 产物严格符合 EncStringCodec 两代格式，可与真实解析链路互通。
 */

const B64_CHARS = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
/** 假 MAC 固定为 32 字节（对齐真实 iv|ct|mac 二进制布局中 mac 定长 32 字节的切分假设）。 */
const FAKE_MAC: string = 'ZmFrZS1tYWNmYWtlLW1hY2Zha2UtbWFjZmFrZS1tYWM=';
const ZERO_IV: string = 'AAAAAAAAAAAAAAAAAAAAAA==';

function b64Encode(bytes: Uint8Array): string {
  let out = '';
  let i = 0;
  for (; i + 2 < bytes.length; i += 3) {
    const n: number = (bytes[i] << 16) | (bytes[i + 1] << 8) | bytes[i + 2];
    out += B64_CHARS.charAt((n >> 18) & 63) + B64_CHARS.charAt((n >> 12) & 63)
      + B64_CHARS.charAt((n >> 6) & 63) + B64_CHARS.charAt(n & 63);
  }
  const rem: number = bytes.length - i;
  if (rem === 1) {
    const n: number = bytes[i] << 16;
    out += B64_CHARS.charAt((n >> 18) & 63) + B64_CHARS.charAt((n >> 12) & 63) + '==';
  } else if (rem === 2) {
    const n: number = (bytes[i] << 16) | (bytes[i + 1] << 8);
    out += B64_CHARS.charAt((n >> 18) & 63) + B64_CHARS.charAt((n >> 12) & 63)
      + B64_CHARS.charAt((n >> 6) & 63) + '=';
  }
  return out;
}

function b64Decode(text: string): Uint8Array {
  const clean: string = text.replace(/=+$/, '');
  const out: Uint8Array = new Uint8Array(Math.floor(clean.length * 3 / 4));
  let outIdx = 0;
  let buffer = 0;
  let bits = 0;
  for (let i = 0; i < clean.length; i++) {
    const v: number = B64_CHARS.indexOf(clean.charAt(i));
    if (v < 0) {
      throw new Error('FakeCryptoEngine: invalid base64');
    }
    buffer = (buffer << 6) | v;
    bits += 6;
    if (bits >= 8) {
      bits -= 8;
      out[outIdx++] = (buffer >> bits) & 0xff;
    }
  }
  return out;
}

function utf8Encode(text: string): Uint8Array {
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

function utf8Decode(bytes: Uint8Array): string {
  let out = '';
  let i = 0;
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

/** 确定性 32 字节派生（FNV-1a 风格扩散，仅测试用，非密码学安全）。 */
function fakeHash(parts: string[], length: number): Uint8Array {
  const out: Uint8Array = new Uint8Array(length);
  let state = 0x811c9dc5;
  for (let i = 0; i < length; i++) {
    const part: string = parts[i % parts.length];
    const ch: number = part.charCodeAt(i % part.length);
    state ^= ch + i;
    state = (state * 0x01000193) >>> 0;
    out[i] = (state >> ((i % 4) * 8)) & 0xff;
  }
  return out;
}

export class FakeCryptoEngine implements CryptoEngine {
  private randomSeed: number = 0x12345678;

  deriveMasterKey(email: string, password: string, kdf: KdfParams): Promise<Uint8Array> {
    const marker: number = kdf.type === KdfType.Argon2id ? 1 : 0;
    return Promise.resolve(fakeHash([email, password, `${marker}`], 32));
  }

  masterPasswordHash(masterKey: Uint8Array, password: string): Promise<string> {
    return Promise.resolve(b64Encode(fakeHash([b64Encode(masterKey), password], 32)));
  }

  stretchKeyLegacy(masterKey: Uint8Array): Promise<SymmetricKey> {
    return Promise.resolve(new SymmetricKey(
      fakeHash([b64Encode(masterKey), 'legacy-enc'], 32),
      fakeHash([b64Encode(masterKey), 'legacy-mac'], 32)));
  }

  stretchKeyHkdf(masterKey: Uint8Array): Promise<SymmetricKey> {
    return Promise.resolve(new SymmetricKey(
      fakeHash([b64Encode(masterKey), 'hkdf-enc'], 32),
      fakeHash([b64Encode(masterKey), 'hkdf-mac'], 32)));
  }

  randomBytes(length: number): Promise<Uint8Array> {
    const out: Uint8Array = new Uint8Array(length);
    for (let i = 0; i < length; i++) {
      this.randomSeed = (this.randomSeed * 1103515245 + 12345) >>> 0;
      out[i] = (this.randomSeed >> 16) & 0xff;
    }
    return Promise.resolve(out);
  }

  makeEncString(plain: Uint8Array, key: SymmetricKey): Promise<EncString> {
    const format: EncStringFormat = 'AesCbc256_HmacSha256_B64';
    return Promise.resolve(new EncString(format, ZERO_IV, b64Encode(plain), FAKE_MAC));
  }

  makeEncStringLegacy(plain: Uint8Array, key: SymmetricKey): Promise<EncString> {
    const format: EncStringFormat = 'AesCbc128_HmacSha256_B64';
    return Promise.resolve(new EncString(format, ZERO_IV, b64Encode(plain), FAKE_MAC));
  }

  decrypt(enc: EncString, key: SymmetricKey): Promise<Uint8Array> {
    if (enc.mac !== FAKE_MAC) {
      return Promise.reject(new Error('FakeCryptoEngine: MAC verification failed'));
    }
    return Promise.resolve(b64Decode(enc.ct));
  }

  decryptToString(enc: EncString, key: SymmetricKey): Promise<string> {
    return this.decrypt(enc, key).then((bytes: Uint8Array): string => utf8Decode(bytes));
  }

  hkdfExpand(ikm: Uint8Array, info: string, length: number): Promise<Uint8Array> {
    return Promise.resolve(fakeHash([b64Encode(ikm), info], length));
  }

  unwrapUserKey(wrapped: string, stretched: SymmetricKey): Promise<SymmetricKey> {
    const enc: EncString = EncStringCodec.decode(wrapped);
    return this.decrypt(enc, stretched).then((raw: Uint8Array): SymmetricKey => {
      if (raw.length !== 64) {
        throw new Error('FakeCryptoEngine: unwrapped user key length invalid');
      }
      return new SymmetricKey(raw.slice(0, 32), raw.slice(32, 64));
    });
  }

  /** 测试辅助：直接编码文本为 fake EncString（模拟已加密字段）。 */
  static encodeText(text: string): string {
    return `2.${ZERO_IV}|${b64Encode(utf8Encode(text))}|${FAKE_MAC}`;
  }
}
