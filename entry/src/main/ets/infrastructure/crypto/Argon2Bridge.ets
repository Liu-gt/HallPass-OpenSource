/*
 * SPDX-FileCopyrightText: 2026 Liugt
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import { taskpool } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';
import argon2Native from 'libargon2.so';

const DOMAIN: number = 0x0000;
const TAG: string = 'HallPassArgon2';

/**
 * TaskPool 线程执行的派生任务（plan D6/R1）：native 同步计算只发生在 TaskPool，
 * 主线程不阻塞。参数经 ArrayBuffer 传递（TaskPool 可转移类型）。
 */
@Concurrent
function argon2DeriveTask(saltBuffer: ArrayBuffer, passwordBuffer: ArrayBuffer,
  iterations: number, memoryKb: number, parallelism: number, hashLen: number): ArrayBuffer {
  const salt: Uint8Array = new Uint8Array(saltBuffer);
  const password: Uint8Array = new Uint8Array(passwordBuffer);
  const out: Uint8Array =
    argon2Native.deriveKdf(salt, password, iterations, memoryKb, parallelism, hashLen);
  const copy: Uint8Array = out.slice();
  return copy.buffer as ArrayBuffer;
}

/**
 * Argon2 桥（票 05）：`derive(params): Promise<Uint8Array>`。
 * Argon2id 为 Bitwarden 默认 KDF（spec F2）；C++ 侧对参数设上限，超限抛错不分配。
 */
export class Argon2Bridge {
  /** 派生（Bitwarden 用法：salt = 小写邮箱 UTF-8，hashLen = 32） */
  static derive(salt: Uint8Array, password: Uint8Array, iterations: number,
    memoryKb: number, parallelism: number, hashLen: number): Promise<Uint8Array> {
    const task: taskpool.Task = new taskpool.Task(argon2DeriveTask,
      salt.slice().buffer as ArrayBuffer, password.slice().buffer as ArrayBuffer,
      iterations, memoryKb, parallelism, hashLen);
    return taskpool.execute(task).then((value: Object): Uint8Array => {
      const buffer: ArrayBuffer = value as ArrayBuffer;
      return new Uint8Array(buffer);
    }).catch((error: Object): Uint8Array => {
      hilog.error(DOMAIN, TAG, 'argon2 derive failed: %{public}s', JSON.stringify(error));
      throw error as Error;
    });
  }
}
