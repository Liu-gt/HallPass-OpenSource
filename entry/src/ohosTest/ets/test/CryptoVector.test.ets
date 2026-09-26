/*
 * SPDX-FileCopyrightText: 2026 Liugt
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import { describe, it, expect } from '@ohos/hypium';
import { util } from '@kit.ArkTS';
import { CryptoEngineImpl } from '../../../main/ets/infrastructure/crypto/CryptoEngineImpl';
import { SymmetricKey } from '../../../main/ets/domain/crypto/CryptoEngine';
import { EncStringCodec } from '../../../main/ets/domain/crypto/EncStringCodec';
import { EncString } from '../../../main/ets/domain/model/EncString';
import { KdfParams, KdfType } from '../../../main/ets/domain/model/VaultContext';

/**
 * T06 设备端验收（spec F2 / plan D6）：以 Python(OpenSSL/hmac) 独立实现的等价计算
 * 为期望值（masterKey b64 与 Bitwarden 官方 clients 测试向量一致，见 audit/T06.md）。
 */
export default function cryptoVectorTest() {
  describe('CryptoVector', () => {

    it('pbkdf2_master_key_official_vector', 0, async () => {
      const engine: CryptoEngineImpl = new CryptoEngineImpl();
      const key: Uint8Array = await engine.deriveMasterKey('test@bitwarden.com', 'password',
        new KdfParams(KdfType.Pbkdf2, 100000));
      let actual: string = '';
      for (let i = 0; i < key.length; i++) {
        actual += (key[i] >> 4).toString(16) + (key[i] & 15).toString(16);
      }
      expect(actual).assertEqual('7942ac0cbda7a9debe02cc5ef259a549547782e928db53b158ab919f728cac55');
    });

    it('master_password_hash_matches_oracle', 0, async () => {
      const engine: CryptoEngineImpl = new CryptoEngineImpl();
      const masterKey: Uint8Array = await engine.deriveMasterKey('test@bitwarden.com', 'password',
        new KdfParams(KdfType.Pbkdf2, 100000));
      const hash: string = await engine.masterPasswordHash(masterKey, 'password');
      expect(hash).assertEqual('IqT0IF8Y6DkBDHOvn56o18ZZvGWKnCBxDbAjdiK6ET4=');
    });

    it('stretch_key_legacy_matches_oracle', 0, async () => {
      const engine: CryptoEngineImpl = new CryptoEngineImpl();
      const masterKey: Uint8Array = await engine.deriveMasterKey('test@bitwarden.com', 'password',
        new KdfParams(KdfType.Pbkdf2, 100000));
      const key: SymmetricKey = await engine.stretchKeyLegacy(masterKey);
      const encHex: string = Array.from(key.encKey).map((b: number): string =>
        (b >> 4).toString(16) + (b & 15).toString(16)).join('');
      const macHex: string = Array.from(key.macKey).map((b: number): string =>
        (b >> 4).toString(16) + (b & 15).toString(16)).join('');
      expect(encHex).assertEqual('f65262afdfac0925232bbcdc0643a968356a58b1a6c5f538a1ac78caa5da80e1');
      expect(macHex).assertEqual('57f29f041fa7f4ed1a3cead9c509f0ba900e7b9d2ef16b0809049b5ffb383cc2');
    });

    it('stretch_key_hkdf_matches_oracle', 0, async () => {
      const engine: CryptoEngineImpl = new CryptoEngineImpl();
      const masterKey: Uint8Array = await engine.deriveMasterKey('test@bitwarden.com', 'password',
        new KdfParams(KdfType.Pbkdf2, 100000));
      const key: SymmetricKey = await engine.stretchKeyHkdf(masterKey);
      const encHex: string = Array.from(key.encKey).map((b: number): string =>
        (b >> 4).toString(16) + (b & 15).toString(16)).join('');
      const macHex: string = Array.from(key.macKey).map((b: number): string =>
        (b >> 4).toString(16) + (b & 15).toString(16)).join('');
      // fix-05：Bitwarden 规范为 HKDF-Expand only（info "enc"/"mac"，各 32 字节），
      // 期望值以 Python hmac 独立计算（输入 = 官方 PBKDF2 向量主密钥）。
      expect(encHex).assertEqual('8b3344542538523331c6184c196ff5da42cc53e05f4013a9002ea5641eb1dfea');
      expect(macHex).assertEqual('b59b85ef78a1cf5fb5834da961fc0ef3255ee0edd128acc881c1eda508e6046a');
    });

    it('make_enc_string_then_decrypt_roundtrip', 0, async () => {
      const engine: CryptoEngineImpl = new CryptoEngineImpl();
      const key: SymmetricKey = await engine.stretchKeyHkdf(new Uint8Array(32).fill(0x05));
      const enc: EncString = await engine.makeEncString(
        new util.TextEncoder().encodeInto('HallPass 测试 123'), key);
      const decoded: EncString = EncStringCodec.decode(EncStringCodec.encode(enc));
      const text: string = await engine.decryptToString(decoded, key);
      expect(text).assertEqual('HallPass 测试 123');
    });

    it('fixed_aes_vector_decrypts', 0, async () => {
      // Python(OpenSSL) 加密的固定向量：encKey=0x11*32, macKey=0x22*32, iv=0x33*16
      const engine: CryptoEngineImpl = new CryptoEngineImpl();
      const key: SymmetricKey = new SymmetricKey(new Uint8Array(32).fill(0x11),
        new Uint8Array(32).fill(0x22));
      const enc: EncString = EncStringCodec.decode(
        '2.MzMzMzMzMzMzMzMzMzMzMw==|XubkN8vnGSN2pXBy15JXk4rf161PcZBW8DDeygf12n4=|MADWgZhKktPLQYoOqAupGlue8yc9sIrp5yCXZrAaiYI=');
      const text: string = await engine.decryptToString(enc, key);
      expect(text).assertEqual('HallPass 测试 123');
    });

    it('legacy_128_format_decrypts', 0, async () => {
      // Python(OpenSSL) 加密的旧代格式向量：AES-128(encKey 前 16 字节) + HMAC(macKey)
      const engine: CryptoEngineImpl = new CryptoEngineImpl();
      const key: SymmetricKey = new SymmetricKey(new Uint8Array(32).fill(0x11),
        new Uint8Array(32).fill(0x22));
      const enc: EncString = EncStringCodec.decode(
        '0.MzMzMzMzMzMzMzMzMzMzMw==|gmSv1n+jj+oluwz199p+OelDhWmSv+A7Y7STJqNeh3w=|z8LlsN/g53PyCovw1HhSG73fyJ/QqQw/CUqhBfvcLco=');
      const text: string = await engine.decryptToString(enc, key);
      expect(text).assertEqual('HallPass 测试 123');
    });

    it('mac_tamper_rejected', 0, async () => {
      const engine: CryptoEngineImpl = new CryptoEngineImpl();
      const key: SymmetricKey = await engine.stretchKeyHkdf(new Uint8Array(32).fill(0x05));
      const enc: EncString = await engine.makeEncString(new Uint8Array([1, 2, 3]), key);
      const tampered: EncString = new EncString(enc.format, enc.iv, enc.ct, 'AAAA');
      let rejected = false;
      await engine.decrypt(tampered, key).catch((_e: Object): void => {
        rejected = true;
      });
      expect(rejected).assertTrue();
    });

    it('random_bytes_length_and_uniqueness', 0, async () => {
      const engine: CryptoEngineImpl = new CryptoEngineImpl();
      const a: Uint8Array = await engine.randomBytes(32);
      const b: Uint8Array = await engine.randomBytes(32);
      expect(a.length).assertEqual(32);
      let same = true;
      for (let i = 0; i < 32; i++) {
        if (a[i] !== b[i]) {
          same = false;
        }
      }
      expect(same).assertFalse();
    });
  });
}
