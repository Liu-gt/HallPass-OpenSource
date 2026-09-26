/*
 * SPDX-FileCopyrightText: 2026 Liugt
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import { BwApiClient } from '../../main/ets/domain/protocol/BwApiClient';
import { PreloginResponse, TokenRequest, TokenResponse, SyncResponse, CipherPayload,
  CipherResponse, FolderResponse, AttachmentUploadResponse, AttachmentDownloadResponse,
  ProtocolError, ProtocolErrorKind }
  from '../../main/ets/domain/protocol/Types';
import { ItemType } from '../../main/ets/domain/model/ItemType';
import { TwoFactorRequiredError } from '../../main/ets/domain/protocol/Types';

/**
 * FakeApiClient（T04 测试假实现）：内存态协议客户端，预配置响应/错误，
 * 记录方法调用序列（calls），供后续票单测驱动登录/同步/写路径并可断言交互。
 */
export class FakeApiClient implements BwApiClient {
  preloginResponse: PreloginResponse | null = null;
  tokenResponse: TokenResponse | null = null;
  syncResponse: SyncResponse | null = null;
  /** 非空 → connectToken 抛 TwoFactorRequiredError（模拟 2FA 账号） */
  twoFactorProviders: number[] | null = null;
  /** 非空 → 模拟官方云新设备验证：未携 NewDeviceOtp 的 token 请求被拒（required），
   *  携错误验证码被拒（invalid otp），携正确验证码放行 */
  newDeviceOtp: string | null = null;
  /** 非空 → 每个方法以该错误 Promise reject（配 ProtocolError 模拟网络/凭据/配额错误） */
  errorToThrow: ProtocolError | null = null;

  calls: string[] = [];
  receivedTokenRequests: TokenRequest[] = [];
  savedPayloads: CipherPayload[] = [];
  folders: FolderResponse[] = [];
  softDeletedIds: string[] = [];
  restoredIds: string[] = [];
  hardDeletedIds: string[] = [];
  savedCiphers: CipherResponse[] = [];

  private fail(): void {
    if (this.errorToThrow !== null) {
      throw this.errorToThrow;
    }
  }

  async prelogin(email: string): Promise<PreloginResponse> {
    this.calls.push('prelogin');
    this.fail();
    return Promise.resolve(this.preloginResponse as PreloginResponse);
  }

  async connectToken(request: TokenRequest): Promise<TokenResponse> {
    this.calls.push('connectToken');
    this.fail();
    this.receivedTokenRequests.push(request);
    if (this.twoFactorProviders !== null) {
      return Promise.reject(new TwoFactorRequiredError(this.twoFactorProviders));
    }
    if (this.newDeviceOtp !== null) {
      if (request.newDeviceOtp === null) {
        return Promise.reject(new ProtocolError(ProtocolErrorKind.NewDeviceVerification,
          'new device verification required', 400, 'new device verification required'));
      }
      if (request.newDeviceOtp !== this.newDeviceOtp) {
        return Promise.reject(new ProtocolError(ProtocolErrorKind.NewDeviceOtpInvalid,
          'invalid new device otp', 400, 'invalid new device otp'));
      }
    }
    return Promise.resolve(this.tokenResponse as TokenResponse);
  }

  async sync(): Promise<SyncResponse> {
    this.calls.push('sync');
    this.fail();
    return Promise.resolve(this.syncResponse as SyncResponse);
  }

  async saveCipher(payload: CipherPayload): Promise<CipherResponse> {
    this.calls.push('saveCipher');
    this.fail();
    // 模拟服务端（Bitwarden/Vaultwarden）规范守卫：SecureNote (type=2) 必须包含 secureNote 字段
    if (payload.type === ItemType.SecureNote) {
      if (payload.secureNote === null) {
        throw new ProtocolError(ProtocolErrorKind.Server, 'Data missing: secureNote required for type 2', 400);
      }
    }
    this.savedPayloads.push(payload);
    // 回显条目以载荷自身序列化作 dataJson（含 name/login/fields），供 ServerCipherCodec 解析
    const echo: CipherResponse = new CipherResponse(
      payload.id ?? `fake-saved-${this.savedPayloads.length}`,
      null, payload.folderId, payload.type, payload.favorite,
      '2026-09-05T00:00:00.000Z', null, JSON.stringify(payload));
    this.savedCiphers.push(echo);
    return Promise.resolve(echo);
  }

  async softDeleteCipher(id: string): Promise<void> {
    this.calls.push(`softDelete:${id}`);
    this.fail();
    this.softDeletedIds.push(id);
    return Promise.resolve();
  }

  async restoreCipher(id: string): Promise<CipherResponse> {
    this.calls.push(`restore:${id}`);
    this.fail();
    this.restoredIds.push(id);
    return Promise.resolve(new CipherResponse(id, null, null, 1, false,
      '2026-09-05T00:00:00.000Z', null, '{}'));
  }

  async hardDeleteCipher(id: string): Promise<void> {
    this.calls.push(`hardDelete:${id}`);
    this.fail();
    this.hardDeletedIds.push(id);
    return Promise.resolve();
  }

  async listFolders(): Promise<FolderResponse[]> {
    this.calls.push('listFolders');
    this.fail();
    return Promise.resolve(this.folders);
  }

  async requestAttachmentUpload(cipherId: string, fileName: string, fileSize: number,
    fileKey: string): Promise<AttachmentUploadResponse> {
    this.calls.push(`attachmentUpload:${cipherId}`);
    this.fail();
    const cipherEcho: CipherResponse = new CipherResponse(cipherId, null, null, 1, false,
      '2026-09-05T00:00:00.000Z', null, '{}');
    return Promise.resolve(new AttachmentUploadResponse(
      `fake-attachment-${this.calls.length}`, `https://fake.upload/${fileName}`,
      0, cipherEcho, null));
  }

  async completeAttachmentUpload(cipherId: string, attachmentId: string,
    dataJson: string): Promise<CipherResponse> {
    this.calls.push(`attachmentComplete:${cipherId}`);
    this.fail();
    return Promise.resolve(new CipherResponse(cipherId, null, null, 1, false,
      '2026-09-05T00:00:00.000Z', null, dataJson));
  }

  async requestAttachmentDownload(cipherId: string, attachmentId: string):
    Promise<AttachmentDownloadResponse> {
    this.calls.push(`attachmentDownload:${cipherId}`);
    this.fail();
    return Promise.resolve(new AttachmentDownloadResponse(`https://fake.download/${attachmentId}`));
  }

  async deleteAttachment(cipherId: string, attachmentId: string): Promise<void> {
    this.calls.push(`attachmentDelete:${cipherId}`);
    this.fail();
    return Promise.resolve();
  }
}
