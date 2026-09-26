/*
 * SPDX-FileCopyrightText: 2026 Liugt
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { PreferencesStoreImpl } from '../../infrastructure/prefs/PreferencesStoreImpl';
import { KeyStoreImpl } from '../../infrastructure/asset/KeyStoreImpl';
import { Db } from '../../infrastructure/db/Db';
import { VaultRepositoryImpl } from '../../infrastructure/db/VaultRepositoryImpl';
import { BwApiClientImpl } from '../../infrastructure/http/BwApiClientImpl';
import { CryptoEngineImpl } from '../../infrastructure/crypto/CryptoEngineImpl';
import { SessionService, SessionSink } from '../SessionService';
import { LockService } from '../LockService';
import { SettingsService } from '../SettingsService';
import { AppState } from '../state/AppState';
import { ServiceLocator } from '../ServiceLocator';
import { SymmetricKey } from '../../domain/crypto/CryptoEngine';
import { ThemeService } from '../../application/theme/ThemeService';
import { PreferencesStore, PrefKeys } from '../../domain/repository/PreferencesStore';
import { KeyStore } from '../../domain/repository/KeyStore';
import { VaultRepository } from '../../domain/repository/VaultRepository';
import { CryptoEngine } from '../../domain/crypto/CryptoEngine';
import { Session } from '../../domain/model/Session';

/**
 * 组合根（票 10，plan D7）：唯一允许同时触及 application 与 infrastructure 的位置。
 * 启动时按序构造 infrastructure 实现 → 注入 domain 接口 → 服务单例。
 * 偏差记录（audit/T10）：plan D9 的 @Provider 下发需改 Index.ets（票 02 所有，文件互斥），
 * 改为组合根单例直取；AppState/ThemeState 仍为 @ObservedV2 响应源，页面经 @Consumer 消费。
 */
export class AppContainer {
  readonly prefs: PreferencesStore;
  readonly keyStore: KeyStore;
  readonly repository: VaultRepository;
  readonly crypto: CryptoEngine;
  readonly client: BwApiClientImpl;
  readonly sessionService: SessionService;
  readonly lockService: LockService;
  readonly settingsService: SettingsService;

  private static instanceRef: AppContainer | null = null;
  private static initPromise: Promise<AppContainer> | null = null;
  /** 防截屏窗口标志回调（EntryAbility 窗口创建后注入，T22 设置页运行时切换用）。 */
  private screenshotSetter: ((enabled: boolean) => void) | null = null;

  private constructor(prefs: PreferencesStore, keyStore: KeyStore,
    repository: VaultRepository, crypto: CryptoEngine, client: BwApiClientImpl,
    sessionService: SessionService, lockService: LockService,
    settingsService: SettingsService) {
    this.prefs = prefs;
    this.keyStore = keyStore;
    this.repository = repository;
    this.crypto = crypto;
    this.client = client;
    this.sessionService = sessionService;
    this.lockService = lockService;
    this.settingsService = settingsService;
  }

  static initialized(): boolean {
    return AppContainer.instanceRef !== null;
  }

  static get(): AppContainer {
    const ref: AppContainer | null = AppContainer.instanceRef;
    if (ref === null) {
      throw new Error('AppContainer not initialized');
    }
    return ref;
  }

  static async init(context: common.Context): Promise<AppContainer> {
    if (AppContainer.instanceRef !== null) {
      return AppContainer.instanceRef;
    }
    if (AppContainer.initPromise !== null) {
      return AppContainer.initPromise;
    }
    AppContainer.initPromise = (async (): Promise<AppContainer> => {
      const prefs: PreferencesStoreImpl = new PreferencesStoreImpl(context);
      const keyStore: KeyStoreImpl = new KeyStoreImpl();
      const store = await Db.open(context);
      const repository: VaultRepositoryImpl = new VaultRepositoryImpl(store);
      const client: BwApiClientImpl = new BwApiClientImpl();
      // 设备标识持久化（plan §1.5 v1.5）：首次生成写入偏好，此后冷启动复用同一 UUID，
      // 服务器把本机记为已知设备，避免每次登录都触发官方云新设备邮箱验证
      await AppContainer.restoreDeviceIdentifier(prefs, client);
      const crypto: CryptoEngineImpl = new CryptoEngineImpl();
      const sink: SessionSink = client as SessionSink; // 实现层显式转换（ArkTS 禁结构化类型）
      const sessionService: SessionService =
        new SessionService(prefs, keyStore, sink, repository);
      const lockService: LockService = new LockService(prefs,
        (): void => sessionService.clearSecrets());
      const settingsService: SettingsService = new SettingsService(prefs);
      client.onTokensRefreshed = (session: Session): Promise<void> =>
        sessionService.onTokensRefreshed(session);
      // 主题服务接线（plan D4）：上下文注入 + 偏好恢复（T22：主题/深浅色持久化）
      ThemeService.get().attach(context);
      await AppContainer.restoreTheme(prefs);
      await lockService.loadAutoLockLevel();
      // 设置项冷启动一次性预载（页面首帧即正确值，无进入设置页的异步回填闪烁）
      await settingsService.load();
      // v1.4：按设备能力收敛生物识别开关（单模态/无生物识别设备不保留不支持方式的开启态）
      settingsService.retainSupportedBiometrics(ServiceLocator.biometric());
      const container: AppContainer = new AppContainer(prefs, keyStore, repository, crypto,
        client, sessionService, lockService, settingsService);
      AppContainer.instanceRef = container;
      return container;
    })();
    return AppContainer.initPromise;
  }

  /** 防截屏窗口标志应用（spec F13，默认开；EntryAbility 窗口创建后调用）。 */
  async applyScreenshotPolicy(setPrivacy: (enabled: boolean) => void): Promise<void> {
    this.registerScreenshotSetter(setPrivacy);
    const stored: boolean | null = await this.prefs.getBoolean(PrefKeys.BLOCK_SCREENSHOT);
    const enabled: boolean = stored ?? true;
    setPrivacy(enabled);
    ThemeService.get();
  }

  private registerScreenshotSetter(setPrivacy: (enabled: boolean) => void): void {
    this.screenshotSetter = setPrivacy;
  }

  /** 设置页防截屏开关（T22，spec F13）：写偏好并即时应用到窗口隐私标志。 */
  async setScreenshotBlocked(enabled: boolean): Promise<void> {
    await this.prefs.setBoolean(PrefKeys.BLOCK_SCREENSHOT, enabled);
    if (this.screenshotSetter !== null) {
      this.screenshotSetter(enabled);
    }
  }

  /**
   * 冷启动自动解锁（plan §1.5 v1.3）：用户显式关闭"进入应用需解锁"后，主密钥经
   * Asset 设备锁屏保护存储，冷启动静默恢复密钥直接进入 unlocked；恢复失败保持锁定。
   */
  async tryAutoUnlockOnLaunch(): Promise<void> {
    if (AppState.get().phase !== 'locked') {
      return;
    }
    const entryLock: boolean | null =
      await this.prefs.getBoolean(PrefKeys.ENTRY_LOCK_REQUIRED);
    if (entryLock !== false) {
      return;
    }
    const vaultId: string = this.sessionService.state.vaultId;
    if (vaultId.length === 0) {
      return;
    }
    const masterKey: Uint8Array | null = await this.keyStore.readAutoUnlockKey(vaultId);
    if (masterKey === null) {
      return;
    }
    try {
      const stretched: SymmetricKey = await this.crypto.stretchKeyHkdf(masterKey);
      let userKey: SymmetricKey | null = null;
      const wrapped: string | null = this.sessionService.protectedUserKey();
      if (wrapped !== null) {
        userKey = await this.crypto.unwrapUserKey(wrapped, stretched);
      }
      this.sessionService.restoreKeys(masterKey, stretched, userKey);
      ServiceLocator.sync();
      this.lockService.unlock();
    } catch (e) {
      this.sessionService.clearSecrets();
    }
  }

  /** 设备标识恢复（plan §1.5 v1.5）：偏好缺失时生成新 UUID 并落盘（非敏感，spec F2 允许）。 */
  private static async restoreDeviceIdentifier(prefs: PreferencesStore,
    client: BwApiClientImpl): Promise<void> {
    const stored: string | null = await prefs.getString(PrefKeys.DEVICE_IDENTIFIER);
    if (stored !== null && stored.length > 0) {
      client.setDeviceIdentifier(stored);
      return;
    }
    const generated: string = util.generateRandomUUID(true);
    await prefs.setString(PrefKeys.DEVICE_IDENTIFIER, generated);
    client.setDeviceIdentifier(generated);
  }

  /** 主题/深浅色偏好恢复（T22，spec F14：默认跟随系统/默认绿）。 */
  private static async restoreTheme(prefs: PreferencesStore): Promise<void> {
    const themeId: string | null = await prefs.getString(PrefKeys.THEME_ID);
    if (themeId !== null) {
      ThemeService.get().setTheme(themeId);
    }
    const colorMode: string | null = await prefs.getString(PrefKeys.COLOR_MODE);
    if (colorMode === 'light' || colorMode === 'dark' || colorMode === 'system') {
      ThemeService.get().setColorMode(colorMode);
    }
  }
}
