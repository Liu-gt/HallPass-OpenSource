/*
 * SPDX-FileCopyrightText: 2026 Liugt
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { util } from '@kit.ArkTS';
import { CryptoEngine, SymmetricKey } from '../../domain/crypto/CryptoEngine';
import { EncStringCodec } from '../../domain/crypto/EncStringCodec';
import { EncString } from '../../domain/model/EncString';
import { KdfParams, KdfType } from '../../domain/model/VaultContext';
import { Argon2Bridge } from './Argon2Bridge';

const AES_FORMAT_256: string = 'AES256|CBC|PKCS7';
const AES_FORMAT_128: string = 'AES128|CBC|PKCS7';

function utf8Bytes(text: string): Uint8Array {
  const encoder = new util.TextEncoder();
  return encoder.encodeInto(text);
}

function utf8Decode(bytes: Uint8Array): string {
  const decoder = util.TextDecoder.create('utf-8');
  return decoder.decodeWithStream(bytes);
}

function base64Encode(bytes: Uint8Array): string {
  const helper = new util.Base64Helper();
  return helper.encodeToStringSync(bytes);
}

function base64Decode(text: string): Uint8Array {
  const helper = new util.Base64Helper();
  return helper.decodeSync(text);
}

function bytesEqual(a: Uint8Array, b: Uint8Array): boolean {
  if (a.length !== b.length) {
    return false;
  }
  let diff: number = 0;
  for (let i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff === 0;
}

function concat(a: Uint8Array, b: Uint8Array): Uint8Array {
  const out: Uint8Array = new Uint8Array(a.length + b.length);
  out.set(a, 0);
  out.set(b, a.length);
  return out;
}

/**
 * CryptoEngine 实现（票 06，plan D6）：全部走 cryptoFramework——
 * PBKDF2-SHA256（createKdf，密码支持二进制输入）、HKDF-SHA256（原生
 * EXTRACT_AND_EXPAND，盐 "bitwarden"）、AES-CBC-256/128 + PKCS7（createCipher）、
 * HMAC-SHA256（createMac + HMAC256 二进制密钥）、安全随机（createRandom）。
 * Argon2id 经 05 的 Argon2Bridge（TaskPool）。
 * 对外全异步（plan D6/R1）；MAC 校验失败抛错，不返回半截明文。
 */
export class CryptoEngineImpl implements CryptoEngine {

  deriveMasterKey(email: string, password: string, kdf: KdfParams): Promise<Uint8Array> {
    if (kdf.type === KdfType.Argon2id) {
      const memory: number = kdf.memory ?? 65536;
      const parallelism: number = kdf.parallelism ?? 4;
      return Argon2Bridge.derive(utf8Bytes(email.toLowerCase()), utf8Bytes(password),
        kdf.iterations, memory, parallelism, 32);
    }
    const spec: cryptoFramework.PBKDF2Spec = {
      algName: 'PBKDF2',
      password: password,
      salt: utf8Bytes(email.toLowerCase()),
      iterations: kdf.iterations,
      keySize: 32
    };
    return cryptoFramework.createKdf('PBKDF2|SHA256').generateSecret(spec)
      .then((blob: cryptoFramework.DataBlob): Uint8Array => blob.data);
  }

  async masterPasswordHash(masterKey: Uint8Array, password: string): Promise<string> {
    // PBKDF2(key=masterKey, salt=password, 1 次, 32B)——二进制密码直接走 createKdf
    const spec: cryptoFramework.PBKDF2Spec = {
      algName: 'PBKDF2',
      password: masterKey,
      salt: utf8Bytes(password),
      iterations: 1,
      keySize: 32
    };
    const blob: cryptoFramework.DataBlob =
      await cryptoFramework.createKdf('PBKDF2|SHA256').generateSecret(spec);
    return base64Encode(blob.data);
  }

  async stretchKeyLegacy(masterKey: Uint8Array): Promise<SymmetricKey> {
    const encKey: Uint8Array = await this.pbkdf2Binary(masterKey, utf8Bytes('enc'));
    const macKey: Uint8Array = await this.pbkdf2Binary(masterKey, utf8Bytes('mac'));
    return new SymmetricKey(encKey, macKey);
  }

  async stretchKeyHkdf(masterKey: Uint8Array): Promise<SymmetricKey> {
    // Bitwarden 规范为 HKDF-Expand only（无 extract）：expand 的 HMAC 直接以 masterKey
    // 为密钥；此前 extract+expand（盐 "bitwarden"）产出错误拉伸密钥（E2E-01 fix-06）。
    const encKey: Uint8Array = await this.hkdfExpand(masterKey, 'enc', 32);
    const macKey: Uint8Array = await this.hkdfExpand(masterKey, 'mac', 32);
    return new SymmetricKey(encKey, macKey);
  }

  async unwrapUserKey(wrapped: string, stretched: SymmetricKey): Promise<SymmetricKey> {
    const raw: Uint8Array = await this.decrypt(EncStringCodec.decode(wrapped), stretched);
    if (raw.length !== 64) {
      throw new Error('CryptoEngine: unwrapped user key length invalid');
    }
    return new SymmetricKey(raw.slice(0, 32), raw.slice(32, 64));
  }

  async randomBytes(length: number): Promise<Uint8Array> {
    const random: cryptoFramework.Random = cryptoFramework.createRandom();
    const blob: cryptoFramework.DataBlob = await random.generateRandom(length);
    return blob.data;
  }

  async makeEncString(plain: Uint8Array, key: SymmetricKey): Promise<EncString> {
    const iv: Uint8Array = await this.randomBytes(16);
    const ct: Uint8Array = await this.aesCbc(true, 256, key.encKey, iv, plain);
    const mac: Uint8Array = await this.hmacSha256(key.macKey, concat(iv, ct));
    return new EncString('AesCbc256_HmacSha256_B64', base64Encode(iv), base64Encode(ct),
      base64Encode(mac));
  }

  async makeEncStringLegacy(plain: Uint8Array, key: SymmetricKey): Promise<EncString> {
    const iv: Uint8Array = await this.randomBytes(16);
    const ct: Uint8Array = await this.aesCbc(true, 128, key.encKey, iv, plain);
    const mac: Uint8Array = await this.hmacSha256(key.macKey, concat(iv, ct));
    return new EncString('AesCbc128_HmacSha256_B64', base64Encode(iv), base64Encode(ct),
      base64Encode(mac));
  }

  async decrypt(enc: EncString, key: SymmetricKey): Promise<Uint8Array> {
    const iv: Uint8Array = base64Decode(enc.iv);
    const ct: Uint8Array = base64Decode(enc.ct);
    const mac: Uint8Array = base64Decode(enc.mac);
    const expected: Uint8Array = await this.hmacSha256(key.macKey, concat(iv, ct));
    if (!bytesEqual(mac, expected)) {
      throw new Error('CryptoEngine: MAC verification failed');
    }
    const bits: number = enc.format === 'AesCbc128_HmacSha256_B64' ? 128 : 256;
    return this.aesCbc(false, bits, key.encKey, iv, ct);
  }

  async decryptToString(enc: EncString, key: SymmetricKey): Promise<string> {
    const plain: Uint8Array = await this.decrypt(enc, key);
    return utf8Decode(plain);
  }

  async hkdfExpand(ikm: Uint8Array, info: string, length: number): Promise<Uint8Array> {
    if (length < 1 || length > 255 * 32) {
      throw new Error('CryptoEngine: hkdfExpand length out of range');
    }
    const infoBytes: Uint8Array = utf8Bytes(info);
    const blocks: number = Math.ceil(length / 32);
    const out: Uint8Array = new Uint8Array(length);
    let filled: number = 0;
    let previous: Uint8Array = new Uint8Array(0);
    for (let i = 1; i <= blocks; i++) {
      const counter: Uint8Array = new Uint8Array([i]);
      previous = await this.hmacSha256(ikm, concat(concat(infoBytes, previous), counter));
      const take: number = Math.min(32, length - filled);
      out.set(previous.subarray(0, take), filled);
      filled += take;
    }
    return out;
  }

  /** PBKDF2（二进制密码输入，迭代次数任意）。 */
  private async pbkdf2Binary(password: Uint8Array, salt: Uint8Array, iterations: number = 1,
    keySize: number = 32): Promise<Uint8Array> {
    const spec: cryptoFramework.PBKDF2Spec = {
      algName: 'PBKDF2',
      password: password,
      salt: salt,
      iterations: iterations,
      keySize: keySize
    };
    const blob: cryptoFramework.DataBlob =
      await cryptoFramework.createKdf('PBKDF2|SHA256').generateSecret(spec);
    return blob.data;
  }

  /** 原生 HKDF（EXTRACT_AND_EXPAND）：Bitwarden 新代拉伸（盐 "bitwarden"）。 */
  private async hkdf(ikm: Uint8Array, salt: Uint8Array, info: Uint8Array,
    keySize: number): Promise<Uint8Array> {
    const spec: cryptoFramework.HKDFSpec = {
      algName: 'HKDF',
      key: ikm,
      salt: salt,
      info: info,
      keySize: keySize
    };
    const blob: cryptoFramework.DataBlob =
      await cryptoFramework.createKdf('HKDF|SHA256').generateSecret(spec);
    return blob.data;
  }

  /** HMAC-SHA256：任意二进制密钥（HMAC 生成器 convertKey，摘要由 createMac 指定），分块 update。 */
  private async hmacSha256(key: Uint8Array, data: Uint8Array): Promise<Uint8Array> {
    // 真机 cryptoFramework 的 HMAC 密钥生成器算法规格为 'HMAC'（密钥长度按字节，
    // 摘要算法由 createMac 指定）；'HMAC256' 会报 ParseAndSetParameter Failed（E2E-01 fix-04）。
    const generator: cryptoFramework.SymKeyGenerator =
      cryptoFramework.createSymKeyGenerator('HMAC');
    const symKey: cryptoFramework.SymKey = await generator.convertKey({ data: key });
    const mac: cryptoFramework.Mac = cryptoFramework.createMac('SHA256');
    await mac.init(symKey);
    const chunkSize: number = 4096;
    for (let offset: number = 0; offset < data.length; offset += chunkSize) {
      const end: number = Math.min(offset + chunkSize, data.length);
      await mac.update({ data: data.subarray(offset, end) });
    }
    const blob: cryptoFramework.DataBlob = await mac.doFinal();
    return blob.data;
  }

  /** AES-CBC + PKCS7（bits = 128/256；encKey 128 位取前 16 字节，兼容旧代格式）。 */
  private async aesCbc(encrypt: boolean, bits: number, encKey: Uint8Array, iv: Uint8Array,
    data: Uint8Array): Promise<Uint8Array> {
    const keyLength: number = bits === 128 ? 16 : 32;
    const generator: cryptoFramework.SymKeyGenerator =
      cryptoFramework.createSymKeyGenerator(bits === 128 ? 'AES128' : 'AES256');
    const symKey: cryptoFramework.SymKey =
      await generator.convertKey({ data: encKey.subarray(0, keyLength) });
    const cipher: cryptoFramework.Cipher =
      cryptoFramework.createCipher(bits === 128 ? AES_FORMAT_128 : AES_FORMAT_256);
    const ivSpec: cryptoFramework.IvParamsSpec = {
      algName: 'IvParamsSpec',
      iv: { data: iv }
    };
    await cipher.init(encrypt ? cryptoFramework.CryptoMode.ENCRYPT_MODE
      : cryptoFramework.CryptoMode.DECRYPT_MODE, symKey, ivSpec);
    // 空输入（如官方云空字段密文 ct 为空）doFinal 返回 null DataBlob → blob.data 抛
    // "Cannot read property data of null"，整条目被跳过（真机观测）；空输入直接返回空输出
    if (data.length === 0) {
      return new Uint8Array(0);
    }
    const blob: cryptoFramework.DataBlob = await cipher.doFinal({ data: data });
    return blob === null ? new Uint8Array(0) : blob.data;
  }
}
