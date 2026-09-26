/*
 * SPDX-FileCopyrightText: 2026 Liugt
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { PreferencesStore } from '../../domain/repository/PreferencesStore';

/**
 * PreferencesStore 实现（票 08，plan D3/§1.5）：非敏感偏好唯一存储入口。
 * 键名一律来自 domain 的 PrefKeys 常量收口；每键独立类型通道，
 * 不存在的键返回 null（与接口语义一致）。
 */
export class PreferencesStoreImpl implements PreferencesStore {
  private static readonly STORE_NAME: string = 'hallpass_prefs';
  private readonly context: common.Context;
  private store: preferences.Preferences | null = null;
  private initPromise: Promise<preferences.Preferences> | null = null;

  constructor(context: common.Context) {
    this.context = context;
  }

  private ready(): Promise<preferences.Preferences> {
    if (this.store !== null) {
      return Promise.resolve(this.store);
    }
    if (this.initPromise === null) {
      this.initPromise = preferences.getPreferences(this.context,
        PreferencesStoreImpl.STORE_NAME).then((store: preferences.Preferences):
        preferences.Preferences => {
        this.store = store;
        return store;
      });
    }
    return this.initPromise;
  }

  async getString(key: string): Promise<string | null> {
    const store: preferences.Preferences = await this.ready();
    if (!(await store.has(key))) {
      return null;
    }
    return store.get(key, '') as Promise<string | null>;
  }

  async setString(key: string, value: string): Promise<void> {
    const store: preferences.Preferences = await this.ready();
    await store.put(key, value);
    await store.flush();
  }

  async getBoolean(key: string): Promise<boolean | null> {
    const store: preferences.Preferences = await this.ready();
    if (!(await store.has(key))) {
      return null;
    }
    return store.get(key, false) as Promise<boolean | null>;
  }

  async setBoolean(key: string, value: boolean): Promise<void> {
    const store: preferences.Preferences = await this.ready();
    await store.put(key, value);
    await store.flush();
  }

  async getNumber(key: string): Promise<number | null> {
    const store: preferences.Preferences = await this.ready();
    if (!(await store.has(key))) {
      return null;
    }
    return store.get(key, 0) as Promise<number | null>;
  }

  async setNumber(key: string, value: number): Promise<void> {
    const store: preferences.Preferences = await this.ready();
    await store.put(key, value);
    await store.flush();
  }
}
