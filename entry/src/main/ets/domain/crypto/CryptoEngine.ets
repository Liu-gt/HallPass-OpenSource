/*
 * SPDX-FileCopyrightText: 2026 Liugt
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import { KdfParams } from '../model/VaultContext';
import { EncString } from '../model/EncString';

/**
 * 对称密钥（Bitwarden 语义）：encKey（AES-256-CBC 加密键）+ macKey（HMAC-SHA256 校验键），
 * 各 32 字节。由主密钥经密钥拉伸（新旧两代，见 stretch* 方法）或解密用户密钥得到。
 * 仅存在于内存/Asset，锁定即清（ADR 安全基线）。
 */
export class SymmetricKey {
  readonly encKey: Uint8Array;
  readonly macKey: Uint8Array;

  constructor(encKey: Uint8Array, macKey: Uint8Array) {
    this.encKey = encKey;
    this.macKey = macKey;
  }
}

/**
 * 加密引擎接口（spec §4.4 / plan D6，domain 唯一测试 seam 之一）。
 * 实现位于 infrastructure/crypto（cryptoFramework + argon2napi 桥）；
 * 本接口零系统依赖，可被 FakeCryptoEngine 替换驱动全链路测试（spec §4.5）。
 * 全部方法 Promise 异步：Argon2id 计算在 TaskPool（plan R1），主线程不阻塞。
 */
export interface CryptoEngine {
  /**
   * 由主密码派生主密钥：PBKDF2-SHA256(email 小写为盐) 或 Argon2id（经 NAPI 桥）。
   * 输出长度：PBKDF2 32 字节；Argon2id 32 字节。
   */
  deriveMasterKey(email: string, password: string, kdf: KdfParams): Promise<Uint8Array>;

  /** 服务器登录口令：PBKDF2(masterKey, password 为盐, 1 次迭代, 32 字节) → Base64。 */
  masterPasswordHash(masterKey: Uint8Array, password: string): Promise<string>;

  /**
   * 旧代密钥拉伸（EncString 128 位旧格式对应）：PBKDF2(masterKey, "enc"/"mac", 1 次, 32 字节 × 2)。
   */
  stretchKeyLegacy(masterKey: Uint8Array): Promise<SymmetricKey>;

  /**
   * 新代密钥拉伸（Bitwarden 规范）：HKDF-SHA256 **Expand only**（无 extract，info
   * "enc"/"mac" 各 32 字节）。fix-06：此前误用 extract+expand 导致拉伸密钥与官方不一致，
   * 服务器用户密钥包裹体永远 MAC 校验失败。
   */
  stretchKeyHkdf(masterKey: Uint8Array): Promise<SymmetricKey>;

  /**
   * 解开服务器用户对称密钥：以拉伸主密钥解密 EncString 密文 → 64 字节
   * （前 32 encKey / 后 32 macKey）。条目/文件夹/附件加解密的真正密钥（fix-06）。
   */
  unwrapUserKey(wrapped: string, stretched: SymmetricKey): Promise<SymmetricKey>;

  /** 密码学安全随机（拒绝表法由实现内聚，plan D6）。 */
  randomBytes(length: number): Promise<Uint8Array>;

  /** 加密为 EncString（AesCbc256_HmacSha256_B64）：随机 IV，encKey 加密，macKey 对 (iv|ct) 做 HMAC。 */
  makeEncString(plain: Uint8Array, key: SymmetricKey): Promise<EncString>;

  /** 加密为 EncString（128 位旧格式 AesCbc128_HmacSha256_B64，兼容旧账号读取）。 */
  makeEncStringLegacy(plain: Uint8Array, key: SymmetricKey): Promise<EncString>;

  /** 解密 EncString（两代格式自动识别）：MAC 校验失败抛错，不返回半截明文。 */
  decrypt(enc: EncString, key: SymmetricKey): Promise<Uint8Array>;

  /** 解密并按 UTF-8 解码为文本。 */
  decryptToString(enc: EncString, key: SymmetricKey): Promise<string>;

  /** HKDF-SHA256 Expand（附件密钥等派生用，RFC 5869）。 */
  hkdfExpand(ikm: Uint8Array, info: string, length: number): Promise<Uint8Array>;
}
