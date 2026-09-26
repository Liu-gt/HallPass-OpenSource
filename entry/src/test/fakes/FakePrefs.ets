/*
 * SPDX-FileCopyrightText: 2026 Liugt
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import { PreferencesStore } from '../../main/ets/domain/repository/PreferencesStore';

/**
 * FakePrefs（T04 测试假实现）：内存版 PreferencesStore，按类型分表存取，供服务层单测。
 */
export class FakePrefs implements PreferencesStore {
  private strings: Map<string, string> = new Map();
  private booleans: Map<string, boolean> = new Map();
  private numbers: Map<string, number> = new Map();

  getString(key: string): Promise<string | null> {
    const v: string | undefined = this.strings.get(key);
    return Promise.resolve(v === undefined ? null : v);
  }

  setString(key: string, value: string): Promise<void> {
    this.strings.set(key, value);
    return Promise.resolve();
  }

  getBoolean(key: string): Promise<boolean | null> {
    const v: boolean | undefined = this.booleans.get(key);
    return Promise.resolve(v === undefined ? null : v);
  }

  setBoolean(key: string, value: boolean): Promise<void> {
    this.booleans.set(key, value);
    return Promise.resolve();
  }

  getNumber(key: string): Promise<number | null> {
    const v: number | undefined = this.numbers.get(key);
    return Promise.resolve(v === undefined ? null : v);
  }

  setNumber(key: string, value: number): Promise<void> {
    this.numbers.set(key, value);
    return Promise.resolve();
  }
}
