/*
 * SPDX-FileCopyrightText: 2026 Liugt
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

/**
 * libargon2 NAPI 桥类型声明（plan D6）：仅一个派生函数，同步阻塞，
 * 必须经 infrastructure/crypto/Argon2Bridge 的 TaskPool 封装调用。
 */
export const deriveKdf: (salt: Uint8Array, password: Uint8Array, iterations: number,
  memoryKb: number, parallelism: number, hashLen: number) => Uint8Array;
