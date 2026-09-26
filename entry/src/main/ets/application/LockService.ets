/*
 * SPDX-FileCopyrightText: 2026 Liugt
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import { AppState, AppPhase } from './state/AppState';
import { PreferencesStore, PrefKeys } from '../domain/repository/PreferencesStore';

/** 锁定/解锁事件（SyncService 订阅：中止写队列 / 重建索引，票 11）。 */
export type LockEvent = 'locked' | 'unlocked';
export type LockListener = (event: LockEvent) => void;

/** 进入应用需解锁默认值（plan §1.5 v1.3：默认开启，安全基线）。 */
const ENTRY_LOCK_DEFAULT: boolean = true;

/** 自动锁定档位（spec F4）：0 从不 / 1 一分钟 / 2 五分钟（默认）/ 3 一小时。 */
export class AutoLockLevel {
  static readonly NEVER: number = 0;
  static readonly ONE_MINUTE: number = 1;
  static readonly FIVE_MINUTES: number = 2;
  static readonly ONE_HOUR: number = 3;

  static minutes(level: number): number | null {
    if (level === AutoLockLevel.ONE_MINUTE) {
      return 1;
    }
    if (level === AutoLockLevel.FIVE_MINUTES) {
      return 5;
    }
    if (level === AutoLockLevel.ONE_HOUR) {
      return 60;
    }
    return null;
  }
}

/**
 * LockService（票 10，plan R5）：locked↔unlocked 的唯一裁决者。
 * - 锁定动作：清内存密钥（经清理钩子）→ AppState → 广播事件；
 * - 自动锁定：切后台计时、回前台判定（后台 timer 不可靠，语义等价 spec F4）；
 *   "从不"仅豁免后台计时，冷启动仍按锁定态（restoreOnLaunch 保证）。
 * 零 kit 依赖，可本地单测（onForegroundAt 显式注入时钟）。
 */
export class LockService {
  private readonly prefs: PreferencesStore;
  private readonly onLockCleanup: () => void;
  private readonly listeners: LockListener[] = [];
  private backgroundedAt: number | null = null;
  private autoLockLevel: number = AutoLockLevel.FIVE_MINUTES;
  /** 进入应用需解锁开关（默认开）：关闭时后台自动锁定一并豁免（冷启动由密钥静默恢复）。 */
  private entryLockRequired: boolean = ENTRY_LOCK_DEFAULT;

  constructor(prefs: PreferencesStore, onLockCleanup: () => void) {
    this.prefs = prefs;
    this.onLockCleanup = onLockCleanup;
  }

  /** 启动时从偏好载入档位（默认 5 分钟，spec F4）与进入解锁开关（默认开，plan v1.3）。 */
  async loadAutoLockLevel(): Promise<void> {
    const stored: number | null = await this.prefs.getNumber(PrefKeys.AUTO_LOCK_LEVEL);
    this.autoLockLevel = stored ?? AutoLockLevel.FIVE_MINUTES;
    const entryLock: boolean | null =
      await this.prefs.getBoolean(PrefKeys.ENTRY_LOCK_REQUIRED);
    this.entryLockRequired = entryLock ?? ENTRY_LOCK_DEFAULT;
  }

  /** 设置页改档位（票 22 调用）。 */
  async setAutoLockLevel(level: number): Promise<void> {
    this.autoLockLevel = level;
    await this.prefs.setNumber(PrefKeys.AUTO_LOCK_LEVEL, level);
  }

  /** 设置页改"进入应用需解锁"开关（关闭时写偏好并豁免后台自动锁定）。 */
  async setEntryLockRequired(required: boolean): Promise<void> {
    this.entryLockRequired = required;
    await this.prefs.setBoolean(PrefKeys.ENTRY_LOCK_REQUIRED, required);
  }

  entryLockIsRequired(): boolean {
    return this.entryLockRequired;
  }

  currentAutoLockLevel(): number {
    return this.autoLockLevel;
  }

  addListener(listener: LockListener): void {
    this.listeners.push(listener);
  }

  isLocked(): boolean {
    return AppState.get().phase === 'locked';
  }

  /** 立即锁定（spec F4/F13）：清内存密钥并转 locked。 */
  lock(): void {
    if (AppState.get().phase !== 'unlocked') {
      return;
    }
    this.onLockCleanup();
    this.backgroundedAt = null;
    this.transition('locked');
  }

  /** 解锁成功（票 16 UnlockPage 调用）。 */
  unlock(): void {
    this.backgroundedAt = null;
    this.transition('unlocked');
  }

  /** EntryAbility.onBackground 转交。 */
  onBackground(): void {
    this.backgroundedAt = Date.now();
  }

  /** EntryAbility.onForeground 转交（真实时钟）。 */
  onForeground(): void {
    this.onForegroundAt(Date.now());
  }

  /** 可测时钟注入版。 */
  onForegroundAt(nowMs: number): void {
    const backgroundedAt: number | null = this.backgroundedAt;
    this.backgroundedAt = null;
    if (backgroundedAt === null) {
      return;
    }
    // 进入免解锁开关关闭：等价"从不"（手动"立即锁定"仍生效）
    if (!this.entryLockRequired) {
      return;
    }
    const minutes: number | null = AutoLockLevel.minutes(this.autoLockLevel);
    if (minutes === null) {
      return;
    }
    if (nowMs - backgroundedAt >= minutes * 60 * 1000) {
      this.lock();
    }
  }

  private transition(phase: AppPhase): void {
    AppState.get().transitionTo(phase);
    const event: LockEvent = phase === 'locked' ? 'locked' : 'unlocked';
    for (let i = 0; i < this.listeners.length; i++) {
      this.listeners[i](event);
    }
  }
}
