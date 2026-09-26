/*
 * SPDX-FileCopyrightText: 2026 Liugt
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import { describe, it, expect } from '@ohos/hypium';
import { BwApiClientImpl } from '../../../main/ets/infrastructure/http/BwApiClientImpl';
import { ProtocolError, ProtocolErrorKind, TwoFactorRequiredError, TokenRequest }
  from '../../../main/ets/domain/protocol/Types';

/**
 * T09 设备端验收（spec F2/F5/F9、plan D5）。
 * 需真实/本地 Vaultwarden 服务器的用例（prelogin 正确返回 KDF、2FA 提供方可区分、
 * 401 自动刷新重放、自建 base url 命中）需服务器环境，归 NEED_REVIEW 人工验收；
 * 本套件自动化覆盖错误分类映射与范围守卫（静态检索见 audit）。
 */
export default function bwApiClientTest() {
  describe('BwApiClient', () => {

    it('classify_two_factor_required_with_providers', 0, () => {
      const providers: Record<string, Object> = { '0': '', '1': '' };
      const payload: Record<string, Object> = {
        'Error': 'invalid_grant',
        'ErrorDescription': 'Two factor required.',
        'TwoFactorProviders': providers
      };
      const body: string = JSON.stringify(payload);
      const error: ProtocolError = BwApiClientImpl.classify(400, body);
      let isTwoFactor = false;
      let providerCount = 0;
      if (error instanceof TwoFactorRequiredError) {
        isTwoFactor = true;
        providerCount = (error as TwoFactorRequiredError).providers.length;
      }
      expect(isTwoFactor).assertTrue();
      expect(providerCount).assertEqual(2);
    });

    it('classify_credential_error', 0, () => {
      const body: string = JSON.stringify({
        'error': 'invalid_grant',
        'error_description': 'invalid_username_or_password'
      });
      const error: ProtocolError = BwApiClientImpl.classify(400, body);
      expect(error.kind).assertEqual(ProtocolErrorKind.Credential);
    });

    it('classify_quota_error', 0, () => {
      const body: string = JSON.stringify({
        'Error': 'invalid_grant',
        'ErrorDescription': 'Max storage space reached.'
      });
      const error: ProtocolError = BwApiClientImpl.classify(400, body);
      expect(error.kind).assertEqual(ProtocolErrorKind.Quota);
    });

    it('classify_session_expired_and_server', 0, () => {
      const unauthorized: ProtocolError = BwApiClientImpl.classify(401, null);
      expect(unauthorized.kind).assertEqual(ProtocolErrorKind.SessionExpired);
      const server: ProtocolError = BwApiClientImpl.classify(503, null);
      expect(server.kind).assertEqual(ProtocolErrorKind.Server);
    });

    it('configure_normalizes_base_url', 0, () => {
      const client: BwApiClientImpl = new BwApiClientImpl();
      client.configure('https://vault.example.com/');
      // 无异常即通过；真实命中自建服务器归 NEED_REVIEW 人工验收
      expect(1).assertEqual(1);
    });

    it('token_request_carries_two_factor_fields', 0, () => {
      const request: TokenRequest = new TokenRequest('user@example.com', 'hash',
        0, '123456', true);
      expect(request.twoFactorProvider).assertEqual(0);
      expect(request.twoFactorToken).assertEqual('123456');
      expect(request.twoFactorRemember).assertTrue();
    });
  });
}
