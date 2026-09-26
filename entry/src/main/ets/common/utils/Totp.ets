/*
 * SPDX-FileCopyrightText: 2026 Liugt
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

/**
 * TOTP 纯逻辑（票 12，spec F10）：RFC 6238（SHA1/SHA256/SHA512、6/8 位、30 秒步长）
 * + Base32（RFC 4648）。零系统依赖，可本地单测（RFC 官方向量，见 entry/src/test/Totp.test.ets）。
 * 依赖本机时间（spec F10 边界：设备时间偏差由 UI 层提示文案说明）。
 */
export type TotpAlgorithm = 'SHA1' | 'SHA256' | 'SHA512';

export class TotpConfig {
  readonly secret: Uint8Array;
  readonly algorithm: TotpAlgorithm;
  readonly digits: number;
  readonly period: number;

  constructor(secret: Uint8Array, algorithm: TotpAlgorithm, digits: number, period: number) {
    this.secret = secret;
    this.algorithm = algorithm;
    this.digits = digits;
    this.period = period;
  }
}

/* ---------------- SHA-1 ---------------- */

function sha1(message: Uint8Array): Uint8Array {
  const h: number[] = [0x67452301, 0xEFCDAB89, 0x98BADCFE, 0x10325476, 0xC3D2E1F0];
  const bitLength: number = message.length * 8;
  const padded: Uint8Array = shaPad(message, 64, bitLength, 8);
  const words: number[] = [];
  for (let i = 0; i < padded.length; i += 4) {
    words.push(((padded[i] << 24) | (padded[i + 1] << 16) | (padded[i + 2] << 8) | padded[i + 3]) >>> 0);
  }
  for (let block = 0; block < words.length; block += 16) {
    const w: number[] = new Array<number>(80);
    for (let t = 0; t < 16; t++) {
      w[t] = words[block + t];
    }
    for (let t = 16; t < 80; t++) {
      const x: number = w[t - 3] ^ w[t - 8] ^ w[t - 14] ^ w[t - 16];
      w[t] = ((x << 1) | (x >>> 31)) >>> 0;
    }
    let a: number = h[0];
    let b: number = h[1];
    let c: number = h[2];
    let d: number = h[3];
    let e: number = h[4];
    for (let t = 0; t < 80; t++) {
      let f: number;
      let k: number;
      if (t < 20) {
        f = (b & c) | ((~b & 0xFFFFFFFF) & d);
        k = 0x5A827999;
      } else if (t < 40) {
        f = b ^ c ^ d;
        k = 0x6ED9EBA1;
      } else if (t < 60) {
        f = (b & c) | (b & d) | (c & d);
        k = 0x8F1BBCDC;
      } else {
        f = b ^ c ^ d;
        k = 0xCA62C1D6;
      }
      const temp: number = (((a << 5) | (a >>> 27)) + (f >>> 0) + e + k + w[t]) >>> 0;
      e = d;
      d = c;
      c = ((b << 30) | (b >>> 2)) >>> 0;
      b = a;
      a = temp;
    }
    h[0] = (h[0] + a) >>> 0;
    h[1] = (h[1] + b) >>> 0;
    h[2] = (h[2] + c) >>> 0;
    h[3] = (h[3] + d) >>> 0;
    h[4] = (h[4] + e) >>> 0;
  }
  return wordsToBytes(h, 5);
}

/* ---------------- SHA-256 ---------------- */

const K256: number[] = [
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
  0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
  0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
  0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
  0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
  0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
];
const H256_INIT: number[] = [
  0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
  0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19
];

function sha256(message: Uint8Array): Uint8Array {
  const bitLength: number = message.length * 8;
  const padded: Uint8Array = shaPad(message, 64, bitLength, 8);
  const h: number[] = H256_INIT.slice(0);
  const w: number[] = new Array<number>(64);
  for (let block = 0; block < padded.length; block += 64) {
    for (let t = 0; t < 16; t++) {
      const i: number = block + t * 4;
      w[t] = ((padded[i] << 24) | (padded[i + 1] << 16) | (padded[i + 2] << 8) | padded[i + 3]) >>> 0;
    }
    for (let t = 16; t < 64; t++) {
      const s0: number = rotr256(w[t - 15], 7) ^ rotr256(w[t - 15], 18) ^ (w[t - 15] >>> 3);
      const s1: number = rotr256(w[t - 2], 17) ^ rotr256(w[t - 2], 19) ^ (w[t - 2] >>> 10);
      w[t] = (w[t - 16] + s0 + w[t - 7] + s1) >>> 0;
    }
    let a: number = h[0];
    let b: number = h[1];
    let c: number = h[2];
    let d: number = h[3];
    let e: number = h[4];
    let f: number = h[5];
    let g: number = h[6];
    let hh: number = h[7];
    for (let t = 0; t < 64; t++) {
      const S1: number = rotr256(e, 6) ^ rotr256(e, 11) ^ rotr256(e, 25);
      const ch: number = (e & f) ^ ((~e & 0xFFFFFFFF) & g);
      const temp1: number = (hh + S1 + ch + K256[t] + w[t]) >>> 0;
      const S0: number = rotr256(a, 2) ^ rotr256(a, 13) ^ rotr256(a, 22);
      const maj: number = (a & b) ^ (a & c) ^ (b & c);
      const temp2: number = (S0 + maj) >>> 0;
      hh = g;
      g = f;
      f = e;
      e = (d + temp1) >>> 0;
      d = c;
      c = b;
      b = a;
      a = (temp1 + temp2) >>> 0;
    }
    h[0] = (h[0] + a) >>> 0;
    h[1] = (h[1] + b) >>> 0;
    h[2] = (h[2] + c) >>> 0;
    h[3] = (h[3] + d) >>> 0;
    h[4] = (h[4] + e) >>> 0;
    h[5] = (h[5] + f) >>> 0;
    h[6] = (h[6] + g) >>> 0;
    h[7] = (h[7] + hh) >>> 0;
  }
  return wordsToBytes(h, 8);
}

function rotr256(x: number, n: number): number {
  return ((x >>> n) | (x << (32 - n))) >>> 0;
}

/* ---------------- SHA-512（BigInt 64 位运算） ---------------- */

const K512: string[] = [
  '0x428a2f98d728ae22', '0x7137449123ef65cd', '0xb5c0fbcfec4d3b2f', '0xe9b5dba58189dbbc',
  '0x3956c25bf348b538', '0x59f111f1b605d019', '0x923f82a4af194f9b', '0xab1c5ed5da6d8118',
  '0xd807aa98a3030242', '0x12835b0145706fbe', '0x243185be4ee4b28c', '0x550c7dc3d5ffb4e2',
  '0x72be5d74f27b896f', '0x80deb1fe3b1696b1', '0x9bdc06a725c71235', '0xc19bf174cf692694',
  '0xe49b69c19ef14ad2', '0xefbe4786384f25e3', '0x0fc19dc68b8cd5b5', '0x240ca1cc77ac9c65',
  '0x2de92c6f592b0275', '0x4a7484aa6ea6e483', '0x5cb0a9dcbd41fbd4', '0x76f988da831153b5',
  '0x983e5152ee66dfab', '0xa831c66d2db43210', '0xb00327c898fb213f', '0xbf597fc7beef0ee4',
  '0xc6e00bf33da88fc2', '0xd5a79147930aa725', '0x06ca6351e003826f', '0x142929670a0e6e70',
  '0x27b70a8546d22ffc', '0x2e1b21385c26c926', '0x4d2c6dfc5ac42aed', '0x53380d139d95b3df',
  '0x650a73548baf63de', '0x766a0abb3c77b2a8', '0x81c2c92e47edaee6', '0x92722c851482353b',
  '0xa2bfe8a14cf10364', '0xa81a664bbc423001', '0xc24b8b70d0f89791', '0xc76c51a30654be30',
  '0xd192e819d6ef5218', '0xd69906245565a910', '0xf40e35855771202a', '0x106aa07032bbd1b8',
  '0x19a4c116b8d2d0c8', '0x1e376c085141ab53', '0x2748774cdf8eeb99', '0x34b0bcb5e19b48a8',
  '0x391c0cb3c5c95a63', '0x4ed8aa4ae3418acb', '0x5b9cca4f7763e373', '0x682e6ff3d6b2b8a3',
  '0x748f82ee5defb2fc', '0x78a5636f43172f60', '0x84c87814a1f0ab72', '0x8cc702081a6439ec',
  '0x90befffa23631e28', '0xa4506cebde82bde9', '0xbef9a3f7b2c67915', '0xc67178f2e372532b',
  '0xca273eceea26619c', '0xd186b8c721c0c207', '0xeada7dd6cde0eb1e', '0xf57d4f7fee6ed178',
  '0x06f067aa72176fba', '0x0a637dc5a2c898a6', '0x113f9804bef90dae', '0x1b710b35131c471b',
  '0x28db77f523047d84', '0x32caab7b40c72493', '0x3c9ebe0a15c9bebc', '0x431d67c49c100d4c',
  '0x4cc5d4becb3e42b6', '0x597f299cfc657e2a', '0x5fcb6fab3ad6faec', '0x6c44198c4a475817'
];
const H512_INIT: bigint[] = [
  BigInt('0x6a09e667f3bcc908'), BigInt('0xbb67ae8584caa73b'),
  BigInt('0x3c6ef372fe94f82b'), BigInt('0xa54ff53a5f1d36f1'),
  BigInt('0x510e527fade682d1'), BigInt('0x9b05688c2b3e6c1f'),
  BigInt('0x1f83d9abfb41bd6b'), BigInt('0x5be0cd19137e2179')
];
const MASK64: bigint = BigInt('0xFFFFFFFFFFFFFFFF');

function bigRotr(x: bigint, n: number): bigint {
  return ((x >> BigInt(n)) | (x << BigInt(64 - n))) & MASK64;
}

function sha512(message: Uint8Array): Uint8Array {
  const bitLengthHi: bigint = BigInt(Math.floor(message.length / 0x20000000));
  const bitLengthLo: bigint = BigInt((message.length * 8) % 0x10000000000000000);
  const blockBytes: number = 128;
  const totalLen: number = message.length + 1 + 16;
  const paddedLen: number = Math.ceil(totalLen / blockBytes) * blockBytes;
  const padded: Uint8Array = new Uint8Array(paddedLen);
  padded.set(message, 0);
  padded[message.length] = 0x80;
  const lenBytes: Uint8Array = bigToBytes128((bitLengthHi << BigInt(64)) | bitLengthLo);
  padded.set(lenBytes, paddedLen - 16);
  const h: bigint[] = H512_INIT.slice(0);
  const w: bigint[] = new Array<bigint>(80);
  for (let block = 0; block < paddedLen; block += 128) {
    for (let t = 0; t < 16; t++) {
      w[t] = bytesToBig(padded, block + t * 8, 8);
    }
    for (let t = 16; t < 80; t++) {
      const s0: bigint = bigRotr(w[t - 15], 1) ^ bigRotr(w[t - 15], 8) ^ (w[t - 15] >> BigInt(7));
      const s1: bigint = bigRotr(w[t - 2], 19) ^ bigRotr(w[t - 2], 61) ^ (w[t - 2] >> BigInt(6));
      w[t] = (w[t - 16] + s0 + w[t - 7] + s1) & MASK64;
    }
    let a: bigint = h[0];
    let b: bigint = h[1];
    let c: bigint = h[2];
    let d: bigint = h[3];
    let e: bigint = h[4];
    let f: bigint = h[5];
    let g: bigint = h[6];
    let hh: bigint = h[7];
    for (let t = 0; t < 80; t++) {
      const S1: bigint = bigRotr(e, 14) ^ bigRotr(e, 18) ^ bigRotr(e, 41);
      const ch: bigint = (e & f) ^ ((~e & MASK64) & g);
      const t1: bigint = (hh + S1 + ch + BigInt(K512[t]) + w[t]) & MASK64;
      const S0: bigint = bigRotr(a, 28) ^ bigRotr(a, 34) ^ bigRotr(a, 39);
      const maj: bigint = (a & b) ^ (a & c) ^ (b & c);
      const t2: bigint = (S0 + maj) & MASK64;
      hh = g;
      g = f;
      f = e;
      e = (d + t1) & MASK64;
      d = c;
      c = b;
      b = a;
      a = (t1 + t2) & MASK64;
    }
    h[0] = (h[0] + a) & MASK64;
    h[1] = (h[1] + b) & MASK64;
    h[2] = (h[2] + c) & MASK64;
    h[3] = (h[3] + d) & MASK64;
    h[4] = (h[4] + e) & MASK64;
    h[5] = (h[5] + f) & MASK64;
    h[6] = (h[6] + g) & MASK64;
    h[7] = (h[7] + hh) & MASK64;
  }
  const out: Uint8Array = new Uint8Array(64);
  for (let i = 0; i < 8; i++) {
    const part: Uint8Array = bigToBytes64(h[i]);
    out.set(part, i * 8);
  }
  return out;
}

function bytesToBig(bytes: Uint8Array, offset: number, length: number): bigint {
  let value: bigint = BigInt(0);
  for (let i = 0; i < length; i++) {
    value = (value << BigInt(8)) | BigInt(bytes[offset + i]);
  }
  return value;
}

function bigToBytes64(value: bigint): Uint8Array {
  const out: Uint8Array = new Uint8Array(8);
  let v: bigint = value & MASK64;
  for (let i = 7; i >= 0; i--) {
    out[i] = Number(v & BigInt(0xff));
    v >>= BigInt(8);
  }
  return out;
}

function bigToBytes128(value: bigint): Uint8Array {
  const out: Uint8Array = new Uint8Array(16);
  let v: bigint = value;
  for (let i = 15; i >= 0; i--) {
    out[i] = Number(v & BigInt(0xff));
    v >>= BigInt(8);
  }
  return out;
}

/* ---------------- 共用填充与 HMAC ---------------- */

function shaPad(message: Uint8Array, blockSize: number, bitLength: number, lengthBytes: number):
  Uint8Array {
  const totalLen: number = message.length + 1 + lengthBytes;
  const paddedLen: number = Math.ceil(totalLen / blockSize) * blockSize;
  const padded: Uint8Array = new Uint8Array(paddedLen);
  padded.set(message, 0);
  padded[message.length] = 0x80;
  const view = new DataView(padded.buffer);
  view.setUint32(paddedLen - lengthBytes, 0);
  view.setUint32(paddedLen - 4, bitLength >>> 0);
  return padded;
}

function wordsToBytes(words: number[], count: number): Uint8Array {
  const out: Uint8Array = new Uint8Array(count * 4);
  for (let i = 0; i < count; i++) {
    out[i * 4] = (words[i] >>> 24) & 0xff;
    out[i * 4 + 1] = (words[i] >>> 16) & 0xff;
    out[i * 4 + 2] = (words[i] >>> 8) & 0xff;
    out[i * 4 + 3] = words[i] & 0xff;
  }
  return out;
}

function hash(algorithm: TotpAlgorithm, message: Uint8Array): Uint8Array {
  if (algorithm === 'SHA1') {
    return sha1(message);
  }
  if (algorithm === 'SHA256') {
    return sha256(message);
  }
  return sha512(message);
}

function hashBlockSize(algorithm: TotpAlgorithm): number {
  return algorithm === 'SHA512' ? 128 : 64;
}

/** HMAC（RFC 2104）：纯逻辑，供 TOTP 与本地单测使用。 */
export function hmac(algorithm: TotpAlgorithm, key: Uint8Array, message: Uint8Array): Uint8Array {
  const blockSize: number = hashBlockSize(algorithm);
  let keyBlock: Uint8Array = key;
  if (keyBlock.length > blockSize) {
    keyBlock = hash(algorithm, keyBlock);
  }
  const paddedKey: Uint8Array = new Uint8Array(blockSize);
  paddedKey.set(keyBlock, 0);
  const ipad: Uint8Array = new Uint8Array(blockSize);
  const opad: Uint8Array = new Uint8Array(blockSize);
  for (let i = 0; i < blockSize; i++) {
    ipad[i] = paddedKey[i] ^ 0x36;
    opad[i] = paddedKey[i] ^ 0x5c;
  }
  const inner: Uint8Array = hash(algorithm, concatBytes(ipad, message));
  return hash(algorithm, concatBytes(opad, inner));
}

function concatBytes(a: Uint8Array, b: Uint8Array): Uint8Array {
  const out: Uint8Array = new Uint8Array(a.length + b.length);
  out.set(a, 0);
  out.set(b, a.length);
  return out;
}

/* ---------------- Base32（RFC 4648，无填充，大小写不敏感，去空格） ---------------- */

const BASE32_ALPHABET: string = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';

export function base32Decode(text: string): Uint8Array | null {
  const clean: string = text.toUpperCase().replace(/[\s-]/g, '').replace(/=+$/, '');
  let bits: number = 0;
  let value: number = 0;
  const out: number[] = [];
  for (let i = 0; i < clean.length; i++) {
    const index: number = BASE32_ALPHABET.indexOf(clean.charAt(i));
    if (index < 0) {
      return null;
    }
    value = (value << 5) | index;
    bits += 5;
    if (bits >= 8) {
      out.push((value >>> (bits - 8)) & 0xff);
      bits -= 8;
    }
  }
  const bytes: Uint8Array = new Uint8Array(out.length);
  for (let i = 0; i < out.length; i++) {
    bytes[i] = out[i];
  }
  return bytes;
}

/* ---------------- RFC 6238 ---------------- */

/** 动态验证码（timeSeconds 为 epoch 秒；serverOffset 秒级预留，MVP 恒 0）。 */
export function totpAt(config: TotpConfig, timeSeconds: number, serverOffset: number = 0):
  string | null {
  if (config.secret.length === 0) {
    return null;
  }
  const counter: number = Math.floor(timeSeconds / config.period) + serverOffset;
  const counterBytes: Uint8Array = new Uint8Array(8);
  const view = new DataView(counterBytes.buffer);
  view.setUint32(0, Math.floor(counter / 0x100000000));
  view.setUint32(4, counter >>> 0);
  const digest: Uint8Array = hmac(config.algorithm, config.secret, counterBytes);
  const offset: number = digest[digest.length - 1] & 0x0f;
  const binary: number = (((digest[offset] & 0x7f) << 24) | (digest[offset + 1] << 16)
    | (digest[offset + 2] << 8) | digest[offset + 3]) >>> 0;
  const modulus: number = Math.pow(10, config.digits);
  const code: number = binary % modulus;
  let text: string = code.toString();
  while (text.length < config.digits) {
    text = '0' + text;
  }
  return text;
}

/** 当前周期剩余秒数（倒计时环用）。 */
export function secondsRemaining(period: number, timeSeconds: number): number {
  return period - (timeSeconds % period);
}
