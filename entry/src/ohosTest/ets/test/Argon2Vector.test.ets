/*
 * SPDX-FileCopyrightText: 2026 Liugt
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import { describe, it, expect } from '@ohos/hypium';
import argon2Native from 'libargon2.so';

/**
 * T05 设备端验收（spec §4.1 / plan D6 / R1）：
 * - Bitwarden KDF 基线：RFC 9106 Argon2id 参数（空 secret/AD 形态）经 NAPI 全链路；
 * - C++ 侧参数上限校验：超限报错不分配（plan R1）。
 * 期望值来源：RFC 9106 官方向量参数在空 secret/AD 下的派生值，
 * 由已通过 RFC 9106 三条官方向量（Argon2d/i/id）验证的实现计算（见 libargon2/README.md）。
 */
export default function argon2VectorTest() {
  describe('Argon2Vector', () => {

    it('rfc9106_argon2id_params_empty_secret_ad', 0, () => {
      const password: Uint8Array = new Uint8Array(32).fill(0x01);
      const salt: Uint8Array = new Uint8Array(16).fill(0x02);
      const tag: Uint8Array = argon2Native.deriveKdf(salt, password, 3, 32, 4, 32);
      const expected: string = '03aab965c12001c9d7d0d2de33192c0494b684bb148196d73c1df1acaf6d0c2e';
      let actual: string = '';
      for (let i = 0; i < tag.length; i++) {
        actual += (tag[i] >> 4).toString(16) + (tag[i] & 15).toString(16);
      }
      expect(actual).assertEqual(expected);
    });

    it('derive_is_deterministic', 0, () => {
      const password: Uint8Array = new Uint8Array(16).fill(0x07);
      const salt: Uint8Array = new Uint8Array(16).fill(0x09);
      const first: Uint8Array = argon2Native.deriveKdf(salt, password, 1, 64, 1, 32);
      const second: Uint8Array = argon2Native.deriveKdf(salt, password, 1, 64, 1, 32);
      expect(first.length).assertEqual(32);
      expect(second.length).assertEqual(32);
      for (let i = 0; i < 32; i++) {
        expect(first[i]).assertEqual(second[i]);
      }
    });

    it('memory_over_limit_rejected', 0, () => {
      const password: Uint8Array = new Uint8Array(16).fill(0x01);
      const salt: Uint8Array = new Uint8Array(16).fill(0x02);
      let rejected = false;
      try {
        argon2Native.deriveKdf(salt, password, 1, 8 * 1024 * 1024, 1, 32);
      } catch (e) {
        rejected = true;
      }
      expect(rejected).assertTrue();
    });

    it('parallelism_over_limit_rejected', 0, () => {
      const password: Uint8Array = new Uint8Array(16).fill(0x01);
      const salt: Uint8Array = new Uint8Array(16).fill(0x02);
      let rejected = false;
      try {
        argon2Native.deriveKdf(salt, password, 1, 1024, 65, 32);
      } catch (e) {
        rejected = true;
      }
      expect(rejected).assertTrue();
    });
  });
}
