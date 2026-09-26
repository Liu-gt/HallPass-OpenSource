/*
 * SPDX-FileCopyrightText: 2026 Liugt
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

/**
 * 会话令牌。仅存在于内存与 Asset（plan D3 安全基线），绝不写入 RDB/Preferences。
 * expiresAt 为 epoch 毫秒值。
 */
export class Session {
  readonly accessToken: string;
  readonly refreshToken: string;
  readonly expiresAt: number;
  /** 服务器用户对称密钥（EncString 密文，由拉伸主密钥包裹）。密文可随会话入 Asset。 */
  readonly protectedUserKey: string | null;

  constructor(accessToken: string, refreshToken: string, expiresAt: number,
    protectedUserKey: string | null = null) {
    this.accessToken = accessToken;
    this.refreshToken = refreshToken;
    this.expiresAt = expiresAt;
    this.protectedUserKey = protectedUserKey;
  }
}
