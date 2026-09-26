/*
 * SPDX-FileCopyrightText: 2026 Liugt
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import { BwApiClient } from '../domain/protocol/BwApiClient';
import { ProtocolError, ProtocolErrorKind, CipherResponse } from '../domain/protocol/Types';
import { CryptoEngine, SymmetricKey } from '../domain/crypto/CryptoEngine';
import { EncString } from '../domain/model/EncString';
import { EncStringCodec } from '../domain/crypto/EncStringCodec';
import { B64 } from '../domain/crypto/B64';
import { SessionService } from './SessionService';
import { VaultRepository } from '../domain/repository/VaultRepository';
import { ProgressListener } from '../infrastructure/http/AttachmentApi';

/**
 * 附件二进制传输注入口（可测性：application 禁 import @kit）；
 * infrastructure/http/AttachmentApi 实现之。
 */
export interface AttachmentTransport {
  upload(url: string, data: Uint8Array, onProgress: ProgressListener | null): Promise<void>;
  download(url: string, onProgress: ProgressListener | null): Promise<Uint8Array>;
}

/**
 * 附件服务（票 13，spec F15）：
 * - 上传：随机 64 字节文件密钥（enc=前 32 / mac=后 32，Bitwarden 旧代拆分语义）→
 *   文件密钥经用户密钥加密为 EncString 随登记上报 → AES-256-CBC+HMAC 加密 →
 *   v2 申请直传 URL → PUT 直传 → 服务端登记 → 索引更新；
 * - 下载：拉取密文（iv|ct|mac 二进制布局）→ 附件密钥解出 → MAC 校验解密 → 返回明文字节
 *   （落盘由 FileSaver/页面完成）；
 * - 配额错误透传（Quota）；离线抛 Network（UI 禁用/重试）。文件内容只经内存。
 */
export class AttachmentService {
  private readonly client: BwApiClient;
  private readonly transport: AttachmentTransport;
  private readonly crypto: CryptoEngine;
  private readonly sessionService: SessionService;
  private readonly repository: VaultRepository;
  private readonly onUpdated: (response: CipherResponse) => Promise<void>;

  private static instanceRef: AttachmentService | null = null;

  constructor(client: BwApiClient, transport: AttachmentTransport, crypto: CryptoEngine,
    sessionService: SessionService, repository: VaultRepository,
    onUpdated: (response: CipherResponse) => Promise<void>) {
    this.client = client;
    this.transport = transport;
    this.crypto = crypto;
    this.sessionService = sessionService;
    this.repository = repository;
    this.onUpdated = onUpdated;
  }

  static shared(): AttachmentService {
    if (AttachmentService.instanceRef === null) {
      throw new Error('AttachmentService not initialized (use ServiceLocator.attachment)');
    }
    return AttachmentService.instanceRef;
  }

  static initShared(service: AttachmentService): void {
    AttachmentService.instanceRef = service;
  }

  /**
   * 附件所属条目的加密密钥（T28）：per-key 条目（官方云 V2）附件密钥以条目密钥包裹，
   * 需先以用户密钥解包条目密钥；传统条目直接用用户密钥。
   */
  private async itemKeyFor(cipherId: string): Promise<SymmetricKey> {
    const userKey: SymmetricKey | null = this.sessionService.userKey();
    if (userKey === null) {
      throw new Error('AttachmentService: locked');
    }
    const cipher = await this.repository.getCipher(this.sessionService.state.vaultId, cipherId);
    if (cipher !== null && cipher.cipherKey !== null) {
      return this.crypto.unwrapUserKey(cipher.cipherKey, userKey);
    }
    return userKey;
  }

  /** 加密上传；返回服务器确认后的更新条目（调用方触发索引更新已在内部完成）。 */
  async upload(cipherId: string, fileName: string, plain: Uint8Array,
    onProgress: ProgressListener | null = null): Promise<CipherResponse> {
    const key: SymmetricKey = await this.itemKeyFor(cipherId);
    const fileKey: Uint8Array = await this.crypto.randomBytes(64);
    const fileKeyEnc: EncString = await this.crypto.makeEncString(fileKey, key);
    const encrypted: Uint8Array = await this.encryptFile(plain, fileKey, onProgress);
    try {
      const uploadTicket = await this.client.requestAttachmentUpload(cipherId, fileName,
        encrypted.length, EncStringCodec.encode(fileKeyEnc));
      await this.transport.upload(uploadTicket.url, encrypted, onProgress);
      const miniJson: string = JSON.stringify({
        'key': EncStringCodec.encode(fileKeyEnc),
        'fileName': fileName,
        'fileSize': encrypted.length,
        'attachmentId': uploadTicket.attachmentId
      });
      const updated: CipherResponse = await this.client.completeAttachmentUpload(cipherId,
        uploadTicket.attachmentId, miniJson);
      await this.onUpdated(updated);
      return updated;
    } catch (e) {
      if (e instanceof ProtocolError) {
        throw e;
      }
      throw new ProtocolError(ProtocolErrorKind.Network, 'attachment transfer failed');
    }
  }

  /** 下载并解密，返回明文字节。cipherId 非 null 时按所属条目密钥解附件密钥（T28）。 */
  async download(attachmentKey: string, downloadUrl: string,
    onProgress: ProgressListener | null = null,
    cipherId: string | null = null): Promise<Uint8Array> {
    const key: SymmetricKey = cipherId === null
      ? await this.requireUserKey() : await this.itemKeyFor(cipherId);
    try {
      const encrypted: Uint8Array = await this.transport.download(downloadUrl, onProgress);
      const fileKey: Uint8Array = await this.crypto.decrypt(
        EncStringCodec.decode(attachmentKey), key);
      if (fileKey.length < 64) {
        throw new ProtocolError(ProtocolErrorKind.Server, 'attachment key malformed');
      }
      return this.decryptFile(encrypted, fileKey, onProgress);
    } catch (e) {
      if (e instanceof ProtocolError) {
        throw e;
      }
      throw new ProtocolError(ProtocolErrorKind.Network, 'attachment download failed');
    }
  }

  /** 删除附件（服务端移除；本地随下次同步收敛）。 */
  async remove(cipherId: string, attachmentId: string): Promise<void> {
    await this.client.deleteAttachment(cipherId, attachmentId);
  }

  private async requireUserKey(): Promise<SymmetricKey> {
    const key: SymmetricKey | null = this.sessionService.userKey();
    if (key === null) {
      throw new Error('AttachmentService: locked');
    }
    return key;
  }

  /**
   * 文件加密为 iv|ct|mac 二进制：复用 CryptoEngine.makeEncString（内部即
   * AES-256-CBC+HMAC-SHA256），随后由 EncString 组件拼装二进制布局。
   */
  private async encryptFile(plain: Uint8Array, fileKey: Uint8Array,
    onProgress: ProgressListener | null): Promise<Uint8Array> {
    onProgress?.(10);
    const symmetric: SymmetricKey = new SymmetricKey(fileKey.slice(0, 32), fileKey.slice(32, 64));
    const enc: EncString = await this.crypto.makeEncString(plain, symmetric);
    onProgress?.(40);
    const iv: Uint8Array = B64.decode(enc.iv);
    const ct: Uint8Array = B64.decode(enc.ct);
    const mac: Uint8Array = B64.decode(enc.mac);
    const out: Uint8Array = new Uint8Array(iv.length + ct.length + mac.length);
    out.set(iv, 0);
    out.set(ct, iv.length);
    out.set(mac, iv.length + ct.length);
    return out;
  }

  /** iv|ct|mac 二进制 → EncString → decrypt（内部 MAC 校验）。 */
  private async decryptFile(encrypted: Uint8Array, fileKey: Uint8Array,
    onProgress: ProgressListener | null): Promise<Uint8Array> {
    if (encrypted.length < 16 + 16 + 32) {
      throw new ProtocolError(ProtocolErrorKind.Server, 'attachment too short');
    }
    onProgress?.(60);
    const iv: Uint8Array = encrypted.slice(0, 16);
    const mac: Uint8Array = encrypted.slice(encrypted.length - 32);
    const ct: Uint8Array = encrypted.slice(16, encrypted.length - 32);
    const symmetric: SymmetricKey = new SymmetricKey(fileKey.slice(0, 32), fileKey.slice(32, 64));
    const enc: EncString = new EncString('AesCbc256_HmacSha256_B64', B64.encode(iv),
      B64.encode(ct), B64.encode(mac));
    onProgress?.(90);
    return this.crypto.decrypt(enc, symmetric);
  }
}
