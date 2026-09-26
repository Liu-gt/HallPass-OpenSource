/*
 * SPDX-FileCopyrightText: 2026 Liugt
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import { describe, it, expect } from '@ohos/hypium';
import { UrlCheck } from '../main/ets/common/utils/UrlCheck';

/**
 * T14 本地单测（spec F1）：服务器地址归一化与校验。
 */
export default function urlCheckTest() {
  describe('UrlCheck', () => {
    it('adds_https_prefix_when_missing', 0, () => {
      expect(UrlCheck.normalizeServerUrl('vaultwarden.example.com'))
        .assertEqual('https://vaultwarden.example.com');
    });
    it('keeps_existing_scheme', 0, () => {
      expect(UrlCheck.normalizeServerUrl('http://local.vw:8222'))
        .assertEqual('http://local.vw:8222');
      expect(UrlCheck.normalizeServerUrl('HTTPS://Vault.Example'))
        .assertEqual('HTTPS://Vault.Example');
    });
    it('rejects_empty_or_space', 0, () => {
      expect(UrlCheck.normalizeServerUrl('')).assertNull();
      expect(UrlCheck.normalizeServerUrl('  ')).assertNull();
      expect(UrlCheck.normalizeServerUrl('my server.com')).assertNull();
    });
    it('trims_whitespace', 0, () => {
      expect(UrlCheck.normalizeServerUrl('  vw.example.com  '))
        .assertEqual('https://vw.example.com');
    });
    it('host_validation', 0, () => {
      expect(UrlCheck.isValidHost('https://vault.bitwarden.com')).assertTrue();
      expect(UrlCheck.isValidHost('https://localhost')).assertTrue();
      expect(UrlCheck.isValidHost('https://vw:8222')).assertTrue();
      expect(UrlCheck.isValidHost('https://')).assertFalse();
    });
  });
}
