/*
 * SPDX-FileCopyrightText: 2026 Liugt
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import { describe, it, expect } from '@ohos/hypium';
import { AttachmentService, AttachmentTransport } from '../main/ets/application/AttachmentService';
import { ProgressListener } from '../main/ets/infrastructure/http/AttachmentApi';
import { SessionService, SessionSink } from '../main/ets/application/SessionService';
import { AppState } from '../main/ets/application/state/AppState';
import { FakeCryptoEngine } from './fakes/FakeCryptoEngine';
import { FakeApiClient } from './fakes/FakeApiClient';
import { FakePrefs } from './fakes/FakePrefs';
import { FakeKeyStore } from './fakes/FakeKeyStore';
import { FakeRepository } from './fakes/FakeRepository';
import { SymmetricKey } from '../main/ets/domain/crypto/CryptoEngine';
import { Session } from '../main/ets/domain/model/Session';
import { ProtocolError, ProtocolErrorKind, AttachmentUploadResponse,
  AttachmentDownloadResponse } from '../main/ets/domain/protocol/Types';
import { CipherResponse } from '../main/ets/domain/protocol/Types';
import { EncStringCodec } from '../main/ets/domain/crypto/EncStringCodec';
import { Cipher } from '../main/ets/domain/model/Cipher';
import { ItemType } from '../main/ets/domain/model/ItemType';

/**
 * T13 本地单测（spec F15）：登录态下上传→下载逐字节一致（fake 传输 + fake 加密）；
 * 配额错误透传；锁定拒绝；离线分类 Network。
 */
class FakeTransport implements AttachmentTransport {
  store: Map<string, Uint8Array> = new Map();
  errorToThrow: Error | null = null;

  async upload(url: string, data: Uint8Array, _onProgress: ProgressListener | null):
    Promise<void> {
    if (this.errorToThrow !== null) {
      throw this.errorToThrow;
    }
    this.store.set(url, data);
  }

  async download(url: string, _onProgress: ProgressListener | null): Promise<Uint8Array> {
    const data: Uint8Array | undefined = this.store.get(url);
    if (data === undefined) {
      throw new Error('not found');
    }
    return data;
  }
}

/** 无操作会话注入口（SessionSink 的 ArkTS 命名实现，替代对象字面量）。 */
class NoopSessionSink implements SessionSink {
  attachSession(_s: Session): void {
  }

  detachSession(): void {
  }
}

interface Env {
  service: AttachmentService;
  transport: FakeTransport;
  client: FakeApiClient;
  engine: FakeCryptoEngine;
  repo: FakeRepository;
}

/** 回传文件密钥的客户端（下载路径可拿到附件密钥，完成真实往返）。 */
class RoundtripClient extends FakeApiClient {
  lastFileKey: string = '';

  requestAttachmentUpload(cipherId: string, fileName: string, fileSize: number,
    fileKey: string): Promise<AttachmentUploadResponse> {
    this.lastFileKey = fileKey;
    const echo: CipherResponse = new CipherResponse(cipherId, null, null, 1, false,
      '2026-09-05T00:00:00.000Z', null, '{}');
    return Promise.resolve(new AttachmentUploadResponse('att-1',
      `https://fake.upload/${fileName}`, 0, echo, null));
  }

  requestAttachmentDownload(_cipherId: string, attachmentId: string):
    Promise<AttachmentDownloadResponse> {
    return Promise.resolve(new AttachmentDownloadResponse(`https://fake.upload/f.bin`,
      this.lastFileKey));
  }
}

async function makeUnlockedEnv(client: FakeApiClient = new FakeApiClient()): Promise<Env> {
  const transport: FakeTransport = new FakeTransport();
  const engine: FakeCryptoEngine = new FakeCryptoEngine();
  const repo: FakeRepository = new FakeRepository();
  const session: SessionService = new SessionService(new FakePrefs(), new FakeKeyStore(),
    new NoopSessionSink(), repo);
  AppState.get().transitionTo('onboarding');
  const service: AttachmentService = new AttachmentService(client, transport, engine, session,
    repo,
    (_response: import('../main/ets/domain/protocol/Types').CipherResponse): Promise<void> =>
      Promise.resolve());
  await session.completeLogin('v1', 'u@e.com', 'https://x', new Session('a', 'r', 60),
    new Uint8Array(32), new SymmetricKey(new Uint8Array(32), new Uint8Array(32)));
  return { service: service, transport: transport, client: client, engine: engine, repo: repo };
}

export default function attachmentTest() {
  describe('Attachment', () => {

    it('upload_download_roundtrip_byte_identical', 0, async () => {
      const client: RoundtripClient = new RoundtripClient();
      const env: Env = await makeUnlockedEnv(client);
      const original: Uint8Array = new Uint8Array(1024);
      for (let i = 0; i < original.length; i++) {
        original[i] = i & 0xff;
      }
      await env.service.upload('cipher-1', 'f.bin', original, null);
      const downloaded: Uint8Array = await env.service.download(client.lastFileKey,
        'https://fake.upload/f.bin', null);
      expect(downloaded.length).assertEqual(original.length);
      let identical: boolean = true;
      for (let i = 0; i < original.length; i++) {
        if (downloaded[i] !== original[i]) {
          identical = false;
          break;
        }
      }
      expect(identical).assertTrue();
    });

    it('quota_error_passthrough', 0, async () => {
      const env: Env = await makeUnlockedEnv();
      env.client.errorToThrow = new ProtocolError(ProtocolErrorKind.Quota, 'storage full');
      let kind: string = '';
      await env.service.upload('c1', 'a.bin', new Uint8Array([1, 2, 3]), null)
        .catch((e: Object): void => {
          if (e instanceof ProtocolError) {
            kind = (e as ProtocolError).kind;
          }
        });
      expect(kind).assertEqual(ProtocolErrorKind.Quota);
    });

    it('offline_classified_network', 0, async () => {
      const env: Env = await makeUnlockedEnv();
      env.client.errorToThrow = new ProtocolError(ProtocolErrorKind.Network, 'offline');
      let kind: string = '';
      await env.service.upload('c1', 'a.bin', new Uint8Array([1]), null)
        .catch((e: Object): void => {
          if (e instanceof ProtocolError) {
            kind = (e as ProtocolError).kind;
          }
        });
      expect(kind).assertEqual(ProtocolErrorKind.Network);
    });

    it('v2_item_attachment_uses_item_key', 0, async () => {
      const client: RoundtripClient = new RoundtripClient();
      const env: Env = await makeUnlockedEnv(client);
      // 造 per-key 条目（官方云 V2 语义）入仓库：cipherKey 为用户密钥包裹的条目密钥
      const itemKeyBytes: Uint8Array = new Uint8Array(64);
      for (let i = 0; i < 64; i++) {
        itemKeyBytes[i] = i + 7;
      }
      const wrapped: string = EncStringCodec.encode(await env.engine.makeEncString(
        itemKeyBytes, new SymmetricKey(new Uint8Array(32), new Uint8Array(32))));
      await env.repo.upsertCipher('v1', new Cipher('c-v2', 'v1', ItemType.Login, null, 0,
        false, null, null, [], null, null, null, null, [], null, [], 0, wrapped));
      const original: Uint8Array = new Uint8Array(512);
      for (let i = 0; i < original.length; i++) {
        original[i] = (i * 3) & 0xff;
      }
      // 上传：文件密钥以条目密钥包裹（而非用户密钥）
      await env.service.upload('c-v2', 'v2.bin', original, null);
      // 下载：显式带 cipherId → 附件密钥经条目密钥解开，逐字节一致
      const downloaded: Uint8Array = await env.service.download(client.lastFileKey,
        'https://fake.upload/v2.bin', null, 'c-v2');
      expect(downloaded.length).assertEqual(original.length);
      let identical: boolean = true;
      for (let i = 0; i < original.length; i++) {
        if (downloaded[i] !== original[i]) {
          identical = false;
          break;
        }
      }
      expect(identical).assertTrue();
    });

    it('locked_rejected', 0, async () => {
      const service: AttachmentService = new AttachmentService(new FakeApiClient(),
        new FakeTransport(), new FakeCryptoEngine(),
        new SessionService(new FakePrefs(), new FakeKeyStore(), new NoopSessionSink(),
          new FakeRepository()), new FakeRepository(),
        (_r: import('../main/ets/domain/protocol/Types').CipherResponse):
        Promise<void> => Promise.resolve());
      let message: string = '';
      await service.upload('c1', 'a.bin', new Uint8Array([1]), null)
        .catch((e: Object): void => {
          message = (e as Error).message;
        });
      expect(message.indexOf('locked') >= 0).assertTrue();
    });
  });
}
