/*
 * SPDX-FileCopyrightText: 2026 Liugt
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

/**
 * 服务器地址校验/归一化（票 14，spec F1）：缺协议头自动补 `https://`；
 * 空/含空格非法。纯逻辑，本地可测。
 */
export class UrlCheck {
  static normalizeServerUrl(raw: string): string | null {
    const trimmed: string = raw.trim();
    if (trimmed.length === 0 || trimmed.indexOf(' ') >= 0) {
      return null;
    }
    const lowered: string = trimmed.toLowerCase();
    if (lowered.startsWith('https://') || lowered.startsWith('http://')) {
      return trimmed;
    }
    return `https://${trimmed}`;
  }

  static isValidHost(url: string): boolean {
    const withoutScheme: string = url.replace(/^https?:\/\//, '');
    if (withoutScheme.length === 0) {
      return false;
    }
    const host: string = withoutScheme.split('/')[0];
    return host.indexOf('.') > 0 || host === 'localhost' || host.indexOf(':') > 0;
  }
}
