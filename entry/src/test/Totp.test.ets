/*
 * SPDX-FileCopyrightText: 2026 Liugt
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import { describe, it, expect } from '@ohos/hypium';
import { TotpConfig, TotpAlgorithm, totpAt, secondsRemaining, base32Decode }
  from '../main/ets/common/utils/Totp';
import { OtpauthUri } from '../main/ets/common/utils/OtpauthUri';
import { ClipboardService, ClipboardSink } from '../main/ets/application/ClipboardService';
import { ClockService } from '../main/ets/application/ClockService';
import { FakePrefs } from './fakes/FakePrefs';
import { PrefKeys } from '../main/ets/domain/repository/PreferencesStore';

const SECRETS: Record<string, Uint8Array> = {
  'SHA1': asciiBytes('12345678901234567890'),
  'SHA256': asciiBytes('12345678901234567890123456789012'),
  'SHA512': asciiBytes('1234567890123456789012345678901234567890123456789012345678901234')
};

function asciiBytes(text: string): Uint8Array {
  const out: Uint8Array = new Uint8Array(text.length);
  for (let i = 0; i < text.length; i++) {
    out[i] = text.charCodeAt(i);
  }
  return out;
}

/** 等待 ms 毫秒（定时器时序用例）。 */
function delay(ms: number): Promise<void> {
  return new Promise<void>((resolve: () => void) => {
    setTimeout(resolve, ms);
  });
}

class FakeSink implements ClipboardSink {
  content: string | null = null;
  clearCount: number = 0;

  setContent(text: string): Promise<void> {
    this.content = text;
    return Promise.resolve();
  }

  getContent(): Promise<string | null> {
    return Promise.resolve(this.content);
  }

  clear(): Promise<void> {
    this.content = null;
    this.clearCount++;
    return Promise.resolve();
  }
}

/**
 * T12 本地单测：RFC 6238 官方向量（同源实现已在 Node 以 19/19 通过，见 audit/T12.md）、
 * otpauth 解析、30 秒自动清除时序（含"不覆盖他人内容"）、开关关闭保留、时钟 tick。
 */
export default function totpTest() {
  describe('Totp', () => {

    it('rfc6238_vectors_all_algorithms', 0, () => {
      const cases: string[][] = [
        ['59', 'SHA1', '94287082'],
        ['1111111109', 'SHA1', '07081804'],
        ['1111111109', 'SHA256', '68084774'],
        ['1111111109', 'SHA512', '25091201'],
        ['1111111111', 'SHA1', '14050471'],
        ['1111111111', 'SHA256', '67062674'],
        ['1111111111', 'SHA512', '99943326'],
        ['1234567890', 'SHA1', '89005924'],
        ['1234567890', 'SHA256', '91819424'],
        ['1234567890', 'SHA512', '93441116'],
        ['2000000000', 'SHA1', '69279037'],
        ['2000000000', 'SHA256', '90698825'],
        ['2000000000', 'SHA512', '38618901'],
        ['20000000000', 'SHA1', '65353130'],
        ['20000000000', 'SHA256', '77737706'],
        ['20000000000', 'SHA512', '47863826']
      ];
      for (let i = 0; i < cases.length; i++) {
        const alg: string = cases[i][1];
        const config: TotpConfig =
          new TotpConfig(SECRETS[alg], alg as TotpAlgorithm, 8, 30);
        const got: string | null = totpAt(config, Number(cases[i][0]));
        expect(got).assertEqual(cases[i][2]);
      }
    });

    it('six_digits_and_period_remaining', 0, () => {
      const got: string | null = totpAt(new TotpConfig(SECRETS['SHA1'], 'SHA1', 6, 30), 59);
      expect(got).assertEqual('287082');
      expect(secondsRemaining(30, 59)).assertEqual(1);
      expect(secondsRemaining(30, 60)).assertEqual(30);
    });

    it('base32_decode', 0, () => {
      const decoded: Uint8Array | null = base32Decode('GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ');
      expect(decoded === null).assertFalse();
      if (decoded !== null) {
        expect(decoded.length).assertEqual(20);
        expect(decoded[0]).assertEqual(asciiBytes('1')[0]);
      }
      expect(base32Decode('1!@#')).assertNull();
    });

    it('otpauth_uri_parse', 0, () => {
      const config: TotpConfig | null = OtpauthUri.parse(
        'otpauth://totp/Acme:alice@example.com?secret=GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ&issuer=Acme&algorithm=SHA256&digits=8&period=60');
      expect(config === null).assertFalse();
      if (config !== null) {
        expect(config.algorithm).assertEqual('SHA256');
        expect(config.digits).assertEqual(8);
        expect(config.period).assertEqual(60);
        expect(config.secret.length).assertEqual(20);
      }
      const defaults: TotpConfig | null = OtpauthUri.parse(
        'otpauth://totp/x?secret=GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ');
      if (defaults !== null) {
        expect(defaults.algorithm).assertEqual('SHA1');
        expect(defaults.digits).assertEqual(6);
        expect(defaults.period).assertEqual(30);
      }
      const bare: TotpConfig | null = OtpauthUri.parse('GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ');
      expect(bare === null).assertFalse();
      expect(OtpauthUri.parse('otpauth://hotp/x?secret=AAA')).assertNull();
      expect(OtpauthUri.parse('otpauth://totp/x?digits=6')).assertNull();
      expect(OtpauthUri.parse('')).assertNull();
    });

    it('clipboard_auto_clears_after_delay', 0, async () => {
      const sink: FakeSink = new FakeSink();
      const prefs: FakePrefs = new FakePrefs();
      const service: ClipboardService = new ClipboardService(sink, prefs, 80);
      await service.copy('secret-password');
      expect(sink.content).assertEqual('secret-password');
      await delay(30);
      expect(sink.content).assertEqual('secret-password');
      await delay(120);
      expect(sink.content).assertNull();
      expect(sink.clearCount).assertEqual(1);
    });

    it('clipboard_does_not_clobber_user_content', 0, async () => {
      const sink: FakeSink = new FakeSink();
      const prefs: FakePrefs = new FakePrefs();
      const service: ClipboardService = new ClipboardService(sink, prefs, 80);
      await service.copy('A');
      // 30 秒内用户复制了其他内容
      await sink.setContent('B');
      await delay(150);
      expect(sink.content).assertEqual('B');
      expect(sink.clearCount).assertEqual(0);
    });

    it('clipboard_disabled_keeps_content', 0, async () => {
      const sink: FakeSink = new FakeSink();
      const prefs: FakePrefs = new FakePrefs();
      await prefs.setBoolean(PrefKeys.CLIPBOARD_AUTO_CLEAR, false);
      const service: ClipboardService = new ClipboardService(sink, prefs, 50);
      await service.copy('keep-me');
      await delay(120);
      expect(sink.content).assertEqual('keep-me');
      expect(sink.clearCount).assertEqual(0);
    });

    it('clock_tick_updates_state_and_notifies', 0, () => {
      const clock: ClockService = new ClockService();
      let notified: number = -1;
      clock.addListener((epochSeconds: number): void => {
        notified = epochSeconds;
      });
      clock.tickOnce(1725500000);
      expect(clock.state.epochSeconds).assertEqual(1725500000);
      expect(notified).assertEqual(1725500000);
      clock.tickOnce(1725500001);
      expect(notified).assertEqual(1725500001);
    });
  });
}
