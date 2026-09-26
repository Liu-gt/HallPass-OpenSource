/*
 * SPDX-FileCopyrightText: 2026 Liugt
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import { describe, it, expect } from '@ohos/hypium';
import { FakeCryptoEngine } from './fakes/FakeCryptoEngine';
import { FakeApiClient } from './fakes/FakeApiClient';
import { FakeRepository } from './fakes/FakeRepository';
import { FakePrefs } from './fakes/FakePrefs';
import { FakeKeyStore } from './fakes/FakeKeyStore';
import { SymmetricKey } from '../main/ets/domain/crypto/CryptoEngine';
import { KdfParams, KdfType } from '../main/ets/domain/model/VaultContext';
import { EncStringCodec } from '../main/ets/domain/crypto/EncStringCodec';
import { EncString } from '../main/ets/domain/model/EncString';
import { PreloginResponse, TokenRequest, TokenResponse, SyncResponse, ProfileResponse, FolderResponse,
  CipherResponse, ProtocolError, ProtocolErrorKind }
  from '../main/ets/domain/protocol/Types';
import { OutboxOpType } from '../main/ets/domain/model/OutboxOp';
import { PrefKeys } from '../main/ets/domain/repository/PreferencesStore';
import { Session } from '../main/ets/domain/model/Session';
import { SessionService, SessionSink } from '../main/ets/application/SessionService';
import { BwApiClientImpl } from '../main/ets/infrastructure/http/BwApiClientImpl';

/** 最小 SessionSink 假实现（SessionService 构造依赖，本测试不校验注入行为）。 */
class FakeSink implements SessionSink {
  attachSession(_session: Session): void {
  }

  detachSession(): void {
  }
}

/**
 * T04 验收自检（spec §4.5）：全部 domain 接口用 fakes 注入调用方，
 * 编译通过且登录/同步/写路径/outbox/偏好/密钥库流程可驱动。
 */
export default function fakesFlowTest() {
  describe('FakesFlow', () => {

    it('login_flow_driven_by_fakes', 0, async () => {
      const engine: FakeCryptoEngine = new FakeCryptoEngine();
      const client: FakeApiClient = new FakeApiClient();
      client.preloginResponse = new PreloginResponse(KdfType.Pbkdf2, 100000);
      client.tokenResponse = new TokenResponse('access-token', 'refresh-token', 3600);

      const pre = await client.prelogin('user@example.com');
      expect(pre.kdfType).assertEqual(0);

      const masterKey: Uint8Array =
        await engine.deriveMasterKey('user@example.com', 'password', new KdfParams(KdfType.Pbkdf2, 100000));
      expect(masterKey.length).assertEqual(32);

      const stretched: SymmetricKey = await engine.stretchKeyHkdf(masterKey);
      expect(stretched.encKey.length).assertEqual(32);
      expect(stretched.macKey.length).assertEqual(32);

      const hash: string = await engine.masterPasswordHash(masterKey, 'password');
      const token = await client.connectToken(
        new TokenRequest('user@example.com', hash, null, null, false));
      expect(token.accessToken).assertEqual('access-token');
      expect(client.calls[0]).assertEqual('prelogin');
      expect(client.calls[1]).assertEqual('connectToken');
    });

    it('crypto_roundtrip_via_fake_and_codec', 0, async () => {
      const engine: FakeCryptoEngine = new FakeCryptoEngine();
      const key: SymmetricKey = new SymmetricKey(new Uint8Array(32), new Uint8Array(32));
      // "hello" 的 UTF-8 字节
      const plain: Uint8Array = new Uint8Array([104, 101, 108, 108, 111]);
      const enc: EncString = await engine.makeEncString(plain, key);
      const decoded: EncString = EncStringCodec.decode(EncStringCodec.encode(enc));
      const back: Uint8Array = await engine.decrypt(decoded, key);
      expect(back.length).assertEqual(plain.length);

      const macMismatch: EncString = new EncString(enc.format, enc.iv, enc.ct, 'AAAA');
      let rejected = false;
      await engine.decrypt(macMismatch, key).catch((_e: Error): void => {
        rejected = true;
      });
      expect(rejected).assertTrue();
    });

    it('sync_and_write_flow_driven_by_fakes', 0, async () => {
      const client: FakeApiClient = new FakeApiClient();
      const repo: FakeRepository = new FakeRepository();
      client.syncResponse = new SyncResponse(
        new ProfileResponse('profile-1', 'user@example.com'),
        [new FolderResponse('folder-1', '2.aaa|bbb|ccc', '2026-09-05T00:00:00.000Z')],
        [new CipherResponse('cipher-1', null, 'folder-1', 1, true,
          '2026-09-05T00:00:00.000Z', null, '{}')]);

      const response: SyncResponse = await client.sync();
      expect(response.ciphers.length).assertEqual(1);
      expect(response.ciphers[0].organizationId).assertNull();

      await repo.enqueueOp('cipher-1', 'softDelete' as OutboxOpType, null);
      const ops = await repo.peekOutbox();
      expect(ops.length).assertEqual(1);
      await repo.ackOp(ops[0].seq);
      const afterAck = await repo.peekOutbox();
      expect(afterAck.length).assertEqual(0);
    });

    it('protocol_error_classification', 0, async () => {
      const client: FakeApiClient = new FakeApiClient();
      client.errorToThrow = new ProtocolError(ProtocolErrorKind.Network, 'offline');
      let kind: string = '';
      await client.sync().catch((e: Error): void => {
        if (e instanceof ProtocolError) {
          kind = e.kind;
        }
      });
      expect(kind).assertEqual('network');
    });

    it('new_device_verification_classify_and_otp_resubmit', 0, async () => {
      // 官方云 DeviceValidator 错误体形状：error_description + ErrorModel.Message 双字段
      const errorModelRequired: Record<string, Object> = {
        'Message': 'new device verification required',
        'Object': 'error'
      };
      const requiredBody: Record<string, Object> = {
        'error': 'device_error',
        'error_description': 'New device verification required',
        'ErrorModel': errorModelRequired
      };
      const required: ProtocolError = BwApiClientImpl.classify(400, JSON.stringify(requiredBody));
      expect(required.kind).assertEqual(ProtocolErrorKind.NewDeviceVerification);

      const errorModelInvalid: Record<string, Object> = {
        'Message': 'invalid new device otp',
        'Object': 'error'
      };
      const invalidBody: Record<string, Object> = {
        'error': 'device_error',
        'error_description': 'Invalid New Device OTP',
        'ErrorModel': errorModelInvalid
      };
      const invalid: ProtocolError = BwApiClientImpl.classify(400, JSON.stringify(invalidBody));
      expect(invalid.kind).assertEqual(ProtocolErrorKind.NewDeviceOtpInvalid);

      // 兼容形状：错误文本仅出现在 ErrorModel.Message（小写）也须命中
      const messageOnlyBody: Record<string, Object> = { 'ErrorModel': errorModelRequired };
      const messageOnly: ProtocolError =
        BwApiClientImpl.classify(400, JSON.stringify(messageOnlyBody));
      expect(messageOnly.kind).assertEqual(ProtocolErrorKind.NewDeviceVerification);

      // 不得误伤既有凭据错误分类
      const credentialBody: Record<string, Object> = {
        'error': 'invalid_grant',
        'error_description': 'invalid_username_or_password'
      };
      const credential: ProtocolError =
        BwApiClientImpl.classify(400, JSON.stringify(credentialBody));
      expect(credential.kind).assertEqual(ProtocolErrorKind.Credential);

      // OTP 重提交：未携带 → required；错误验证码 → invalid；正确 → 放行且请求携带验证码
      const client: FakeApiClient = new FakeApiClient();
      client.tokenResponse = new TokenResponse('access-token', 'refresh-token', 3600);
      client.newDeviceOtp = '123456';
      let first: ProtocolError | null = null;
      await client.connectToken(new TokenRequest('u@e.com', 'hash')).catch(
        (e: Object): void => {
          first = e as ProtocolError;
        });
      expect(first !== null
        && (first as ProtocolError).kind === ProtocolErrorKind.NewDeviceVerification)
        .assertTrue();

      let second: ProtocolError | null = null;
      await client.connectToken(
        new TokenRequest('u@e.com', 'hash', null, null, false, '000000')).catch(
        (e: Object): void => {
          second = e as ProtocolError;
        });
      expect(second !== null
        && (second as ProtocolError).kind === ProtocolErrorKind.NewDeviceOtpInvalid)
        .assertTrue();

      const token: TokenResponse =
        await client.connectToken(
          new TokenRequest('u@e.com', 'hash', null, null, false, '123456'));
      expect(token.accessToken).assertEqual('access-token');
      expect(client.receivedTokenRequests[2].newDeviceOtp).assertEqual('123456');
    });

    it('prefs_and_keystore_flows', 0, async () => {
      const prefs: FakePrefs = new FakePrefs();
      await prefs.setNumber(PrefKeys.AUTO_LOCK_LEVEL, 2);
      const level: number | null = await prefs.getNumber(PrefKeys.AUTO_LOCK_LEVEL);
      expect(level).assertEqual(2);

      const store: FakeKeyStore = new FakeKeyStore();
      await store.saveSession(new Session('access', 'refresh', 3600));
      const session: Session | null = await store.readSession();
      expect(session != null).assertTrue();
      await store.saveFastUnlockKey('vault-1', new Uint8Array(32));
      const key: Uint8Array | null = await store.readFastUnlockKey('vault-1');
      expect(key != null).assertTrue();
      store.biometricPass = false;
      const denied: Uint8Array | null = await store.readFastUnlockKey('vault-1');
      expect(denied).assertNull();
    });

    it('completeLogin_restores_unlock_keys_from_prefs', 0, async () => {
      const prefs: FakePrefs = new FakePrefs();
      const store: FakeKeyStore = new FakeKeyStore();
      const sessionService: SessionService =
        new SessionService(prefs, store, new FakeSink(), new FakeRepository());
      const masterKey: Uint8Array = new Uint8Array(32).fill(0x07);
      const stretched: SymmetricKey =
        new SymmetricKey(new Uint8Array(32), new Uint8Array(32));
      const session: Session = new Session('access', 'refresh', 3600);

      // 进入免解锁（entryLock=false）→ 仅写自动会话密钥；生物识别随总开关关闭（v1.4
      // 联动），即使遗留 legacy 偏好为 true 也不恢复门控密钥
      await prefs.setBoolean(PrefKeys.ENTRY_LOCK_REQUIRED, false);
      await prefs.setBoolean(PrefKeys.BIOMETRIC_UNLOCK_ENABLED, true);
      await sessionService.completeLogin('vault-1', 'user@example.com', 'https://example.org',
        session, masterKey, stretched, null);
      const autoKey: Uint8Array | null = await store.readAutoUnlockKey('vault-1');
      expect(autoKey != null).assertTrue();
      expect(await store.hasFastUnlockKey('vault-1')).assertFalse();

      // 总开关开启 + 指纹解锁开启 → 恢复门控密钥，不写自动会话密钥
      await prefs.setBoolean(PrefKeys.ENTRY_LOCK_REQUIRED, true);
      await prefs.setBoolean(PrefKeys.BIOMETRIC_FINGERPRINT_ENABLED, true);
      await sessionService.completeLogin('vault-2', 'user@example.com', 'https://example.org',
        session, masterKey, stretched, null);
      expect(await store.readAutoUnlockKey('vault-2')).assertNull();
      expect(await store.hasFastUnlockKey('vault-2')).assertTrue();

      // 两开关均关闭 → 不写任何解锁密钥（换 vault 维度隔离）
      await prefs.setBoolean(PrefKeys.BIOMETRIC_FINGERPRINT_ENABLED, false);
      await sessionService.completeLogin('vault-3', 'user@example.com', 'https://example.org',
        session, masterKey, stretched, null);
      expect(await store.readAutoUnlockKey('vault-3')).assertNull();
      expect(await store.hasFastUnlockKey('vault-3')).assertFalse();
    });
  });
}
