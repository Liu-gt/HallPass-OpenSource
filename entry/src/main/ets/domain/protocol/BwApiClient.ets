/*
 * SPDX-FileCopyrightText: 2026 Liugt
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import { PreloginResponse, TokenRequest, TokenResponse, SyncResponse, CipherPayload,
  CipherResponse, FolderResponse, AttachmentUploadResponse, AttachmentDownloadResponse }
  from './Types';

/**
 * Bitwarden 协议客户端接口（plan D5，domain 唯一测试 seam 之一）。
 * 仅覆盖个人空间端点（范围守卫：无组织/集合方法，ADR-0001 / spec §6）。
 * 令牌注入、401 刷新重放、base url 可变均为实现层职责（infrastructure/http），
 * 接口保持协议形状，可被 FakeApiClient 替换驱动测试（spec §4.5）。
 * 全部方法 Promise 异步；错误以 ProtocolError/TwoFactorRequiredError 抛出（分类见 Types）。
 */
export interface BwApiClient {
  /** 取账号 KDF 参数（登录前预检，spec F2）。 */
  prelogin(email: string): Promise<PreloginResponse>;

  /** 密码授予登录；服务器要求 2FA 时抛 TwoFactorRequiredError（携带可用提供方列表）。 */
  connectToken(request: TokenRequest): Promise<TokenResponse>;

  /** 全量同步个人空间：profile / folders / ciphers（组织条目由调用方过滤，ADR-0001）。 */
  sync(): Promise<SyncResponse>;

  /** 新建/更新条目（载荷已加密）；id 为 null 新建。返回服务器确认后的条目。 */
  saveCipher(payload: CipherPayload): Promise<CipherResponse>;

  /** 软删（移入回收站，deletedDate 置位，spec F9）。 */
  softDeleteCipher(id: string): Promise<void>;

  /** 恢复（从回收站回到原文件夹）。 */
  restoreCipher(id: string): Promise<CipherResponse>;

  /** 永久删除（服务端移除，不可恢复）。 */
  hardDeleteCipher(id: string): Promise<void>;

  /** 文件夹列表（name 为 EncString 串行化文本）。 */
  listFolders(): Promise<FolderResponse[]>;

  /** 申请附件上传（v2 直传：返回上传 URL 与登记用响应）。 */
  requestAttachmentUpload(cipherId: string, fileName: string, fileSize: number,
    fileKey: string): Promise<AttachmentUploadResponse>;

  /** 直传完成后登记（服务端确认附件元数据并返回更新后的条目）。 */
  completeAttachmentUpload(cipherId: string, attachmentId: string,
    dataJson: string): Promise<CipherResponse>;

  /** 申请附件下载（返回直传 URL；key 为附件密钥 EncString 串行化文本或 null）。 */
  requestAttachmentDownload(cipherId: string, attachmentId: string):
    Promise<AttachmentDownloadResponse>;

  /** 删除附件（服务端移除）。 */
  deleteAttachment(cipherId: string, attachmentId: string): Promise<void>;
}
