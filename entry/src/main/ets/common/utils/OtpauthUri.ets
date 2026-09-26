/*
 * SPDX-FileCopyrightText: 2026 Liugt
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import { TotpConfig, TotpAlgorithm, base32Decode } from './Totp';

/**
 * otpauth:// URI 解析（票 12，spec F8/F10）：
 * `otpauth://totp/[Issuer:]Account?secret=&issuer=&algorithm=&digits=&period=`；
 * 兼容纯 Base32 裸密钥（按 SHA1/6 位/30 秒默认，Bitwarden 语义）。
 * 非法输入返回 null（保存前校验，spec F8 边界情况）。
 */
export class OtpauthUri {
  static parse(text: string): TotpConfig | null {
    const trimmed: string = text.trim();
    if (trimmed.length === 0) {
      return null;
    }
    if (!trimmed.toLowerCase().startsWith('otpauth://')) {
      const raw: Uint8Array | null = base32Decode(trimmed);
      if (raw === null || raw.length === 0) {
        return null;
      }
      return new TotpConfig(raw, 'SHA1', 6, 30);
    }
    const withoutScheme: string = trimmed.substring('otpauth://'.length);
    const slashIndex: number = withoutScheme.indexOf('/');
    if (slashIndex < 0) {
      return null;
    }
    const type: string = withoutScheme.substring(0, slashIndex).toLowerCase();
    if (type !== 'totp') {
      return null; // hotp 不支持（MVP）
    }
    const query: string = withoutScheme.substring(slashIndex + 1);
    const questionIndex: number = query.indexOf('?');
    const paramText: string = questionIndex >= 0 ? query.substring(questionIndex + 1) : query;
    const params: Map<string, string> = new Map();
    const pairs: string[] = paramText.split('&');
    for (let i = 0; i < pairs.length; i++) {
      if (pairs[i].length === 0) {
        continue;
      }
      const eq: number = pairs[i].indexOf('=');
      if (eq < 0) {
        params.set(pairs[i].toLowerCase(), '');
      } else {
        params.set(pairs[i].substring(0, eq).toLowerCase(),
          OtpauthUri.decodeComponent(pairs[i].substring(eq + 1)));
      }
    }
    const secretText: string | undefined = params.get('secret');
    if (secretText === undefined || secretText.length === 0) {
      return null;
    }
    const secret: Uint8Array | null = base32Decode(secretText);
    if (secret === null || secret.length === 0) {
      return null;
    }
    const algorithm: TotpAlgorithm = OtpauthUri.normalizeAlgorithm(params.get('algorithm'));
    const digits: number = OtpauthUri.intOrDefault(params.get('digits'), 6, [6, 8]);
    const period: number = OtpauthUri.periodOrDefault(params.get('period'));
    return new TotpConfig(secret, algorithm, digits, period);
  }

  private static periodOrDefault(raw: string | undefined): number {
    if (raw === undefined) {
      return 30;
    }
    const value: number = Number.parseInt(raw, 10);
    if (Number.isNaN(value) || value < 1 || value > 3600) {
      return 30;
    }
    return value;
  }

  private static normalizeAlgorithm(raw: string | undefined): TotpAlgorithm {
    if (raw === undefined) {
      return 'SHA1';
    }
    const cleaned: string = raw.toUpperCase().replace(/-/g, '');
    if (cleaned === 'SHA256') {
      return 'SHA256';
    }
    if (cleaned === 'SHA512') {
      return 'SHA512';
    }
    return 'SHA1';
  }

  private static intOrDefault(raw: string | undefined, fallback: number,
    allowed: number[]): number {
    if (raw === undefined) {
      return fallback;
    }
    const value: number = Number.parseInt(raw, 10);
    if (Number.isNaN(value)) {
      return fallback;
    }
    return allowed.indexOf(value) >= 0 ? value : fallback;
  }

  private static decodeComponent(raw: string): string {
    try {
      return decodeURIComponent(raw);
    } catch (e) {
      return raw;
    }
  }
}
