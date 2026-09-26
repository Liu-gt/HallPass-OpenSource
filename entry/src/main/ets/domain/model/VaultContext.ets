/*
 * SPDX-FileCopyrightText: 2026 Liugt
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

/**
 * KDF 算法类型（Bitwarden prelogin 返回的线上数值）。
 */
export enum KdfType {
  Pbkdf2 = 0,
  Argon2id = 1
}

/**
 * KDF 参数。Pbkdf2 仅用 iterations；Argon2id 用 iterations（time cost）、memory（KiB）、parallelism。
 */
export class KdfParams {
  readonly type: KdfType;
  readonly iterations: number;
  readonly memory: number | null;
  readonly parallelism: number | null;

  constructor(type: KdfType, iterations: number, memory: number | null = null,
    parallelism: number | null = null) {
    this.type = type;
    this.iterations = iterations;
    this.memory = memory;
    this.parallelism = parallelism;
  }
}

/**
 * 保管库上下文：一次同步与解锁的完整单元。
 */
export class VaultContext {
  readonly vaultId: string;
  readonly serverUrl: string;
  readonly email: string;
  readonly accountId: string;
  readonly kdf: KdfParams;

  constructor(vaultId: string, serverUrl: string, email: string, accountId: string, kdf: KdfParams) {
    this.vaultId = vaultId;
    this.serverUrl = serverUrl;
    this.email = email;
    this.accountId = accountId;
    this.kdf = kdf;
  }
}
