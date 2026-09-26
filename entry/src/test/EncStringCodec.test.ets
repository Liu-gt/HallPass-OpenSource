/*
 * SPDX-FileCopyrightText: 2026 Liugt
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import { describe, it, expect } from '@ohos/hypium';
import { EncString } from '../main/ets/domain/model/EncString';
import { EncStringCodec } from '../main/ets/domain/crypto/EncStringCodec';

const V2_SAMPLE = '2.tuRPPUw7rUnP6hQ3OnIq9A==|Q0lBC0+pL1HO5wJFY9bYqA==|aMwFJpF1DhJOWvVJKM2ukw==';
const V0_SAMPLE = '0.DnqPWZLcGH5EagfOvQ3JbQ==|oT5eE0bFD2MKIGRwUXc+1A==|pK6kQTvOL1QFWObFg2Esbw==';
const V2_IV = 'tuRPPUw7rUnP6hQ3OnIq9A==';
const V2_CT = 'Q0lBC0+pL1HO5wJFY9bYqA==';
const V2_MAC = 'aMwFJpF1DhJOWvVJKM2ukw==';

function assertThrows(raw: string): void {
  let threw = false;
  try {
    EncStringCodec.decode(raw);
  } catch (e) {
    threw = true;
  }
  expect(threw).assertTrue();
}

export default function encStringCodecTest() {
  describe('EncStringCodec', () => {

    it('decode_v2_yields_format_iv_ct_mac', 0, () => {
      const dec = EncStringCodec.decode(V2_SAMPLE);
      expect(dec.format).assertEqual('AesCbc256_HmacSha256_B64');
      expect(dec.iv).assertEqual(V2_IV);
      expect(dec.ct).assertEqual(V2_CT);
      expect(dec.mac).assertEqual(V2_MAC);
    });

    it('decode_v0_yields_aescbc128_format', 0, () => {
      const dec = EncStringCodec.decode(V0_SAMPLE);
      expect(dec.format).assertEqual('AesCbc128_HmacSha256_B64');
      expect(dec.iv).assertEqual('DnqPWZLcGH5EagfOvQ3JbQ==');
      expect(dec.ct).assertEqual('oT5eE0bFD2MKIGRwUXc+1A==');
      expect(dec.mac).assertEqual('pK6kQTvOL1QFWObFg2Esbw==');
    });

    it('roundtrip_encoded_string_is_stable', 0, () => {
      const dec = EncStringCodec.decode(V2_SAMPLE);
      expect(EncStringCodec.encode(dec)).assertEqual(V2_SAMPLE);
      expect(EncStringCodec.encode(EncStringCodec.decode(EncStringCodec.encode(dec)))).assertEqual(V2_SAMPLE);
    });

    it('roundtrip_object_fields_preserved', 0, () => {
      const original = new EncString('AesCbc256_HmacSha256_B64', V2_IV, V2_CT, V2_MAC);
      const back = EncStringCodec.decode(EncStringCodec.encode(original));
      expect(back.format).assertEqual(original.format);
      expect(back.iv).assertEqual(original.iv);
      expect(back.ct).assertEqual(original.ct);
      expect(back.mac).assertEqual(original.mac);
    });

    it('decode_rejects_missing_prefix', 0, () => {
      assertThrows('tuRPPUw7rUnP6hQ3OnIq9A==|Q0lBC0+pL1HO5wJFY9bYqA==|aMwFJpF1DhJOWvVJKM2ukw==');
    });

    it('decode_rejects_unknown_prefix', 0, () => {
      assertThrows('1.abcABC+/==|abcABC+/==|abcABC+/==');
      assertThrows('9.abcABC+/==|abcABC+/==|abcABC+/==');
    });

    it('decode_rejects_missing_segments', 0, () => {
      assertThrows('2.tuRPPUw7rUnP6hQ3OnIq9A==');
      assertThrows('2.tuRPPUw7rUnP6hQ3OnIq9A==|Q0lBC0+pL1HO5wJFY9bYqA==');
      assertThrows('2.tuRPPUw7rUnP6hQ3OnIq9A==|Q0lBC0+pL1HO5wJFY9bYqA==|aMwFJpF1DhJOWvVJKM2ukw==|extra==');
    });

    it('decode_rejects_empty_segment', 0, () => {
      assertThrows('2.tuRPPUw7rUnP6hQ3OnIq9A==||aMwFJpF1DhJOWvVJKM2ukw==');
    });

    it('decode_rejects_invalid_base64', 0, () => {
      assertThrows('2.not base64!|Q0lBC0+pL1HO5wJFY9bYqA==|aMwFJpF1DhJOWvVJKM2ukw==');
      assertThrows('2.ab=c|Q0lBC0+pL1HO5wJFY9bYqA==|aMwFJpF1DhJOWvVJKM2ukw==');
      assertThrows('2.abc|Q0lBC0+pL1HO5wJFY9bYqA==|aMwFJpF1DhJOWvVJKM2ukw==');
      assertThrows('2.====|Q0lBC0+pL1HO5wJFY9bYqA==|aMwFJpF1DhJOWvVJKM2ukw==');
    });
  });
}
