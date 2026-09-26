/*
 * SPDX-FileCopyrightText: 2026 Liugt
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import { ServiceLocator } from '../../application/ServiceLocator';
import { AppContainer } from '../../application/bootstrap/AppContainer';
import { ShieldEffectService } from '../../application/ShieldEffectService';
import { ThemeService, ColorModePreference } from '../../application/theme/ThemeService';
import { AppTheme, ThemeOption } from '../../common/design/AppTheme';
import { SettingsState } from '../../application/SettingsService';
import { BiometricType } from '../../domain/biometric/BiometricCapability';
import { PrefKeys } from '../../domain/repository/PreferencesStore';
import { ConfirmDialogService } from '../../application/ConfirmDialogService';
import { DemoModeManager } from '../../application/demo/DemoModeManager';
import { AppState } from '../../application/state/AppState';
import { bundleManager } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

/** 开源地址（spec F13：发布仓库实际 URL，与 git remote 一致）。 */
const REPO_URL: string = 'https://github.com/Liu-gt/HallPass-OpenSource';

/** 联系作者邮箱（spec F13 关于组：点击复制）。 */
const CONTACT_EMAIL: string = 'nathaniel_liugt@qq.com';

/** 版权署名（GPL-3.0 适当法律声明的一半：版权人 + 无担保 + 许可证获取方式见关于页）。 */
export const COPYRIGHT_NOTICE: string = '© 2026 Liugt';

/**
 * 设置页 ViewModel（票 22，spec F13/F14）：五组设置的真实服务接线。
 * - 安全：自动锁定 4 档（LockService）、立即锁定、剪贴板/防截屏开关（偏好 + 窗口隐私标志）；
 * - 外观：主题 5 项 + 深浅色 3 项（ThemeService 即时生效，偏好持久化、冷启动恢复）；
 * - 通用：排序方式（偏好 + AppState 设置信号驱动列表刷新）；
 * - 账号：服务器回显、退出登录（SessionService.logout 清全部缓存）。
 */
@ObservedV2
export class SettingsViewModel {
  @Trace serverUrl: string = '';
  @Trace email: string = '';
  @Trace autoLockLevel: number = 2;
  @Trace clipboardClear: boolean = true;
  @Trace blockScreenshot: boolean = true;
  @Trace entryLock: boolean = true;
  /** 生物识别按设备支持情况展示（v1.4）：支持情况来自能力探测，开关值来自偏好镜像。 */
  @Trace fingerprintSupported: boolean = false;
  @Trace faceSupported: boolean = false;
  @Trace fingerprintEnabled: boolean = false;
  @Trace faceEnabled: boolean = false;
  @Trace preferredBiometric: BiometricType = 'fingerprint';
  private biometricBusy: boolean = false;
  @Trace sortRecent: boolean = false;
  /** 试验性：液态玻璃效果总开关（控制镜像树与各玻璃组件）。 */
  @Trace glassEffects: boolean = false;
  /** 试验性：液态玻璃页签开关（关闭回退原版页签）。 */
  @Trace glassTabBar: boolean = false;
  /** 试验性：液态玻璃开关控件（开启后所有 Switch 型 Toggle 走 GL 渲染）。 */
  @Trace glassToggle: boolean = false;
  /** 试验性：液态玻璃滑块控件（开启后所有 Slider 走 GL 渲染）。 */
  @Trace glassSlider: boolean = false;
  @Trace themeId: string = AppTheme.defaultTheme.id;
  @Trace colorMode: ColorModePreference = 'system';
  /** 生效深色（主题色点取色用，随 ThemeService 同步）。 */
  @Trace isDark: boolean = false;
  @Trace version: string = '';

  async init(): Promise<void> {
    const session = ServiceLocator.session();
    this.serverUrl = session.state.serverUrl;
    this.email = session.state.email;
    this.autoLockLevel = ServiceLocator.lock().currentAutoLockLevel();
    // 设置镜像冷启动已预载（SettingsService）：同步拷贝，页面首帧即正确值、无回填闪烁
    const settings: SettingsState = ServiceLocator.settings().state;
    this.clipboardClear = settings.clipboardClear;
    this.blockScreenshot = settings.blockScreenshot;
    this.entryLock = settings.entryLock;
    this.fingerprintEnabled = settings.fingerprintEnabled;
    this.faceEnabled = settings.faceEnabled;
    this.preferredBiometric = settings.preferredBiometric;
    // 设备生物识别能力探测（同步）：仅硬件支持的方式渲染开关行
    this.fingerprintSupported = ServiceLocator.biometric().isSupported('fingerprint');
    this.faceSupported = ServiceLocator.biometric().isSupported('face');
    this.sortRecent = settings.sortRecent;
    this.glassEffects = settings.glassEffects;
    this.glassTabBar = settings.glassTabBar;
    this.glassToggle = settings.glassToggle;
    this.glassSlider = settings.glassSlider;
    this.themeId = ThemeService.get().state.themeId;
    this.colorMode = ThemeService.get().state.colorMode;
    this.isDark = ThemeService.get().state.isDark;
    this.version = SettingsViewModel.loadVersion();
  }

  private static loadVersion(): string {
    try {
      const info: bundleManager.BundleInfo =
        bundleManager.getBundleInfoForSelfSync(bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT);
      return info.versionName;
    } catch (e) {
      return '';
    }
  }

  /** 自动锁定 4 档（spec F4：0 从不 / 1 一分钟 / 2 五分钟 / 3 一小时，默认 2）。 */
  async setAutoLockLevel(level: number): Promise<void> {
    this.autoLockLevel = level;
    await ServiceLocator.lock().setAutoLockLevel(level);
  }

  /**
   * 修复 HIGH-v2-04：体验模式下点击"立即锁定"，唤起退出体验确认弹窗，杜绝无响应缺陷
   */
  lockNow(): void {
    if (AppState.get().phase === 'demo') {
      ConfirmDialogService.get().show({
        title: $r('app.string.demo_exit_title'),
        body: $r('app.string.demo_exit_confirm_body'),
        cancelLabel: $r('app.string.cancel'),
        confirmLabel: $r('app.string.demo_exit_btn'),
        onCancel: (): void => {},
        onConfirm: (): void => {
          DemoModeManager.get().exitDemoMode();
        }
      });
      return;
    }
    ServiceLocator.lock().lock();
  }

  async setClipboardClear(enabled: boolean): Promise<void> {
    this.clipboardClear = enabled;
    ServiceLocator.settings().setClipboardClear(enabled);
  }

  /** 防截屏（开关映射窗口隐私模式，spec F13；默认开）。 */
  async setScreenshotBlocked(enabled: boolean): Promise<void> {
    if (AppState.get().phase === 'demo') {
      this.blockScreenshot = enabled;
      ServiceLocator.settings().setScreenshotBlocked(enabled);
      return;
    }
    this.blockScreenshot = enabled;
    ServiceLocator.settings().setScreenshotBlocked(enabled);
    await AppContainer.get().setScreenshotBlocked(enabled);
  }

  /**
   * 进入应用需解锁开关（plan §1.5 v1.3，默认开）：先持久化偏好（状态不可丢失），
   * 再尽力维护自动会话密钥（Asset 设备锁屏保护；关闭时写入供冷启动静默恢复，
   * 重新开启即清除）；密钥操作失败不影响开关状态，仅记录日志。
   * 关闭时生物识别快速解锁失去意义（不再出现解锁页）：两种方式同步关闭落偏好
   * （页面随 @Trace 置灰禁用），重新开启总开关不自动恢复，需用户手动开启。
   * 修复 CRIT-v2-04：进入应用免锁开关在体验模式下安全短路
   */
  async setEntryLock(required: boolean): Promise<void> {
    if (AppState.get().phase === 'demo') {
      this.entryLock = required;
      ServiceLocator.settings().setEntryLock(required);
      await ServiceLocator.lock().setEntryLockRequired(required);
      if (!required && ServiceLocator.settings().anyBiometricEnabled()) {
        await this.setFingerprintUnlock(false);
        await this.setFaceUnlock(false);
      }
      return;
    }
    this.entryLock = required;
    ServiceLocator.settings().setEntryLock(required);
    await ServiceLocator.lock().setEntryLockRequired(required);
    if (!required && ServiceLocator.settings().anyBiometricEnabled()) {
      await this.setFingerprintUnlock(false);
      await this.setFaceUnlock(false);
    }
    const vaultId: string = ServiceLocator.session().state.vaultId;
    if (vaultId.length === 0) {
      return;
    }
    try {
      if (required) {
        await ServiceLocator.keyStore().clearAutoUnlockKey(vaultId);
      } else {
        const masterKey: Uint8Array | null = ServiceLocator.session().masterKey();
        if (masterKey !== null) {
          await ServiceLocator.keyStore().saveAutoUnlockKey(vaultId, masterKey);
        }
      }
    } catch (e) {
      const err: Error = e as Error;
      hilog.error(0x0000, 'HallPassSettings', 'auto unlock key fail %{public}s: %{public}s',
        err.name ?? 'unknown', err.message ?? '');
    }
  }

  /**
   * 指纹解锁开关（spec F3，v1.4 按模态拆分，状态源=偏好 biometricFingerprintEnabled）：
   * 状态经 SettingsService 偏好+镜像同写；共享门控密钥的维护见 maintainBiometricKey。
   */
  async setFingerprintUnlock(enabled: boolean): Promise<void> {
    if (AppState.get().phase === 'demo') {
      this.fingerprintEnabled = enabled;
      ServiceLocator.settings().setFingerprintEnabled(enabled);
      if (enabled) {
        ShieldEffectService.get().play();
      }
      return;
    }
    if (this.biometricBusy) {
      return;
    }
    this.fingerprintEnabled = enabled;
    ServiceLocator.settings().setFingerprintEnabled(enabled);
    await this.maintainBiometricKey(enabled, 'fingerprint');
  }

  /**
   * 人脸解锁开关（spec F3，v1.4 按模态拆分，状态源=偏好 biometricFaceEnabled）：
   * 状态经 SettingsService 偏好+镜像同写；共享门控密钥的维护见 maintainBiometricKey。
   */
  async setFaceUnlock(enabled: boolean): Promise<void> {
    if (AppState.get().phase === 'demo') {
      this.faceEnabled = enabled;
      ServiceLocator.settings().setFaceEnabled(enabled);
      if (enabled) {
        ShieldEffectService.get().play();
      }
      return;
    }
    if (this.biometricBusy) {
      return;
    }
    this.faceEnabled = enabled;
    ServiceLocator.settings().setFaceEnabled(enabled);
    await this.maintainBiometricKey(enabled, 'face');
  }

  /** 优先使用方式（v1.4，两种方式均支持时展示）：写偏好，解锁认证框按此排序。 */
  setBiometricPreferred(type: BiometricType): void {
    this.preferredBiometric = type;
    ServiceLocator.settings().setBiometricPreferred(type);
  }

  /**
   * 共享门控密钥维护（两种方式共用一把 Asset 密钥，AUTH_TYPE=ANY）：
   * 开启且密钥不存在 → 写入并按该方式回读验证（弹系统认证框，未录入由系统引导录入），
   * 验证未通过清密钥并回退该开关；关闭后任一方式已关 → 密钥存在但入口由偏好控制，
   * 两种方式均关才清密钥。回退只影响当前操作的方式，不波及已开启的另一方式。
   */
  private async maintainBiometricKey(enabled: boolean, type: BiometricType): Promise<void> {
    this.biometricBusy = true;
    try {
      const vaultId: string = ServiceLocator.session().state.vaultId;
      if (vaultId.length === 0) {
        this.revertBiometricModality(type);
        return;
      }
      const keyStore = ServiceLocator.keyStore();
      if (!enabled) {
        if (!ServiceLocator.settings().anyBiometricEnabled()) {
          try {
            await keyStore.clearFastUnlockKey(vaultId);
          } catch (e) {
            /* 忽略 */
          }
        }
        return;
      }
      const masterKey: Uint8Array | null = ServiceLocator.session().masterKey();
      if (masterKey === null) {
        this.revertBiometricModality(type);
        return;
      }
      try {
        // 保存/覆盖快速解锁密钥
        await keyStore.saveFastUnlockKey(vaultId, masterKey);
        // 针对当前开启的模态发起一次系统认证验证
        const verified: boolean = await keyStore.readFastUnlockKey(vaultId, [type]) !== null;
        if (!verified) {
          this.revertBiometricModality(type);
          if (!ServiceLocator.settings().anyBiometricEnabled()) {
            try {
              await keyStore.clearFastUnlockKey(vaultId);
            } catch (err) {
              /* 忽略 */
            }
          }
        } else {
          // 验证通过：触发盾牌动效，保持开关开启
          ShieldEffectService.get().play();
        }
      } catch (e) {
        const err: Error = e as Error;
        hilog.error(0x0000, 'HallPassSettings', 'fast unlock enable fail %{public}s: %{public}s',
          err.name ?? 'unknown', err.message ?? '');
        this.revertBiometricModality(type);
        if (!ServiceLocator.settings().anyBiometricEnabled()) {
          try {
            await keyStore.clearFastUnlockKey(vaultId);
          } catch (err2) {
            /* 忽略 */
          }
        }
      }
    } finally {
      this.biometricBusy = false;
    }
  }

  /** 验证未通过/无会话密钥时回退当前操作的开关（不波及另一方式）。 */
  private revertBiometricModality(type: BiometricType): void {
    if (type === 'face') {
      this.faceEnabled = false;
      ServiceLocator.settings().setFaceEnabled(false);
    } else {
      this.fingerprintEnabled = false;
      ServiceLocator.settings().setFingerprintEnabled(false);
    }
  }

  /** 主题切换（即时生效无需重启，spec F14；偏好持久化）。 */
  setTheme(themeId: string): void {
    ThemeService.get().setTheme(themeId);
    this.themeId = themeId;
    this.isDark = ThemeService.get().state.isDark;
    ServiceLocator.prefs().setString(PrefKeys.THEME_ID, themeId);
  }

  setColorMode(mode: ColorModePreference): void {
    ThemeService.get().setColorMode(mode);
    this.colorMode = mode;
    this.isDark = ThemeService.get().state.isDark;
    ServiceLocator.prefs().setString(PrefKeys.COLOR_MODE, mode);
  }

  /** 排序方式（spec F6 切换入口在设置页）：写偏好并广播设置信号，列表即时刷新。 */
  async setSort(recent: boolean): Promise<void> {
    this.sortRecent = recent;
    ServiceLocator.settings().setSort(recent);
  }

  /** 试验性：液态玻璃效果总开关（写偏好；Index 监听设置状态即时挂载/卸载镜像树）。 */
  setGlassEffects(enabled: boolean): void {
    this.glassEffects = enabled;
    ServiceLocator.settings().setGlassEffects(enabled);
  }

  /** 试验性：液态玻璃页签开关（写偏好；Index 监听设置状态即时切换页签壳）。 */
  setGlassTabBar(enabled: boolean): void {
    this.glassTabBar = enabled;
    ServiceLocator.settings().setGlassTabBar(enabled);
  }

  /** 试验性：液态玻璃开关控件（写偏好；各页面开关组件监听设置状态即时切换）。 */
  setGlassToggle(enabled: boolean): void {
    this.glassToggle = enabled;
    ServiceLocator.settings().setGlassToggle(enabled);
  }

  /** 试验性：液态玻璃滑块控件（写偏好；各页面滑块组件监听设置状态即时切换）。 */
  setGlassSlider(enabled: boolean): void {
    this.glassSlider = enabled;
    ServiceLocator.settings().setGlassSlider(enabled);
  }

  /** 退出登录（spec F13：二次确认由页面负责；清除全部密文缓存/Asset 密钥/KDF 缓存）。 */
  async signOut(): Promise<void> {
    if (AppState.get().phase === 'demo') {
      DemoModeManager.get().exitDemoMode();
      return;
    }
    await ServiceLocator.session().logout();
  }

  themes(): ThemeOption[] {
    return AppTheme.all;
  }

  repoUrl(): string {
    return REPO_URL;
  }

  contactEmail(): string {
    return CONTACT_EMAIL;
  }
}
