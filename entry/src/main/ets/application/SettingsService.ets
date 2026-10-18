/*
 * SPDX-FileCopyrightText: 2026 Liugt
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import { AppState } from './state/AppState';
import { BiometricCapability, BiometricType } from '../domain/biometric/BiometricCapability';
import { PreferencesStore, PrefKeys } from '../domain/repository/PreferencesStore';

/**
 * 设置展示态（响应式）：冷启动由 AppContainer.init 一次性预载，
 * 页面首帧即取即显（无进入设置页时的异步回填闪烁）。
 */
@ObservedV2
export class SettingsState {
  @Trace clipboardClear: boolean = true;
  @Trace blockScreenshot: boolean = true;
  @Trace entryLock: boolean = true;
  /** 生物识别按模态拆分（v1.4）：偏好为唯一状态源，Asset 密钥为派生物。 */
  @Trace fingerprintEnabled: boolean = false;
  @Trace faceEnabled: boolean = false;
  /** 优先使用方式（两种方式均支持时展示选择，解锁认证框按此排序）。 */
  @Trace preferredBiometric: BiometricType = 'fingerprint';
  @Trace sortRecent: boolean = false;
  /** 液态玻璃效果总开关（试验性，默认关）：控制镜像组件树挂载与各液态玻璃组件启用。 */
  @Trace glassEffects: boolean = false;
  /** 液态玻璃页签（试验性，默认关）：关闭时回退原版 ArkUI 页签。 */
  @Trace glassTabBar: boolean = false;
  /**
   * 页签开关纪元：每次 `setGlassTabBar` 自增。`Index` 用失败纪元与它比对 ——
   * 拨动开关即视为"重新尝试玻璃页签"，失败标记随之过期（见 Index.glassTabFailEpoch）。
   */
  @Trace glassTabBarEpoch: number = 0;
  /** 液态玻璃开关（试验性，默认关）：开启时所有 Switch 型 Toggle 走 GL 渲染。 */
  @Trace glassToggle: boolean = false;
  /** 液态玻璃滑块（试验性，默认关）：开启时所有 Slider 走 GL 渲染。 */
  @Trace glassSlider: boolean = false;
  /** 液态玻璃弹窗（试验性，默认关）：开启时所有弹窗走液态玻璃样式渲染。 */
  @Trace glassDialog: boolean = false;
}

/**
 * 设置服务（plan §1.5 状态源）：preferences 是唯一持久状态源，本服务是冷启动预载的
 * 内存镜像；写入路径统一经此（偏好 + 镜像同写），复杂操作（解锁密钥验证）由
 * SettingsViewModel 编排后调用此处落状态。
 */
export class SettingsService {
  readonly state: SettingsState = new SettingsState();
  private readonly prefs: PreferencesStore;

  constructor(prefs: PreferencesStore) {
    this.prefs = prefs;
  }

  /** 冷启动预载（AppContainer.init 调用；主界面出现前必然完成）。 */
  async load(): Promise<void> {
    this.state.clipboardClear =
      (await this.prefs.getBoolean(PrefKeys.CLIPBOARD_AUTO_CLEAR)) ?? true;
    this.state.blockScreenshot =
      (await this.prefs.getBoolean(PrefKeys.BLOCK_SCREENSHOT)) ?? true;
    this.state.entryLock =
      (await this.prefs.getBoolean(PrefKeys.ENTRY_LOCK_REQUIRED)) ?? true;
    // 生物识别 v1.4 按模态拆键：新键缺失时从废弃的 biometricUnlockEnabled 一次性迁移
    // （legacy true → 两种方式均开；认证框仅呈现设备实际支持的方式），legacy 键保留不再读
    const legacy: boolean | null =
      await this.prefs.getBoolean(PrefKeys.BIOMETRIC_UNLOCK_ENABLED);
    await this.loadBiometricModality(PrefKeys.BIOMETRIC_FINGERPRINT_ENABLED, legacy,
      (enabled: boolean): void => {
        this.state.fingerprintEnabled = enabled;
      });
    await this.loadBiometricModality(PrefKeys.BIOMETRIC_FACE_ENABLED, legacy,
      (enabled: boolean): void => {
        this.state.faceEnabled = enabled;
      });
    const preferred: string | null = await this.prefs.getString(PrefKeys.BIOMETRIC_PREFERRED);
    if (preferred === 'face' || preferred === 'fingerprint') {
      this.state.preferredBiometric = preferred;
    }
    const sort: number | null = await this.prefs.getNumber(PrefKeys.SORT_MODE);
    this.state.sortRecent = sort === 1;
    this.state.glassEffects =
      (await this.prefs.getBoolean(PrefKeys.GLASS_EFFECTS_ENABLED)) ?? false;
    this.state.glassTabBar =
      (await this.prefs.getBoolean(PrefKeys.GLASS_TAB_BAR_ENABLED)) ?? false;
    this.state.glassToggle =
      (await this.prefs.getBoolean(PrefKeys.GLASS_TOGGLE_ENABLED)) ?? false;
    this.state.glassSlider =
      (await this.prefs.getBoolean(PrefKeys.GLASS_SLIDER_ENABLED)) ?? false;
    this.state.glassDialog =
      (await this.prefs.getBoolean(PrefKeys.GLASS_DIALOG_ENABLED)) ?? false;
  }

  private async loadBiometricModality(key: string, legacy: boolean | null,
    assign: (enabled: boolean) => void): Promise<void> {
    const stored: boolean | null = await this.prefs.getBoolean(key);
    if (stored !== null) {
      assign(stored);
      return;
    }
    if (legacy === true) {
      assign(true);
      this.prefs.setBoolean(key, true);
    }
  }

  setClipboardClear(enabled: boolean): void {
    this.state.clipboardClear = enabled;
    this.prefs.setBoolean(PrefKeys.CLIPBOARD_AUTO_CLEAR, enabled);
  }

  setScreenshotBlocked(enabled: boolean): void {
    this.state.blockScreenshot = enabled;
  }

  setEntryLock(required: boolean): void {
    this.state.entryLock = required;
  }

  /** 液态玻璃效果总开关（试验性，偏好 + 镜像同写）：控制镜像组件树挂载与各液态玻璃组件启用。 */
  setGlassEffects(enabled: boolean): void {
    this.state.glassEffects = enabled;
    this.prefs.setBoolean(PrefKeys.GLASS_EFFECTS_ENABLED, enabled);
  }

  /** 液态玻璃页签开关（试验性，偏好 + 镜像同写）：关闭时页签壳切回原版 ArkUI 实现。 */
  setGlassTabBar(enabled: boolean): void {
    this.state.glassTabBar = enabled;
    // 纪元自增：早前的失败标记（Index.glassTabFailEpoch）过期，拨回开时重新挂玻璃壳
    this.state.glassTabBarEpoch++;
    this.prefs.setBoolean(PrefKeys.GLASS_TAB_BAR_ENABLED, enabled);
  }

  /** 液态玻璃开关（试验性，偏好 + 镜像同写）：开启时所有 Switch 型 Toggle 走 GL 渲染。 */
  setGlassToggle(enabled: boolean): void {
    this.state.glassToggle = enabled;
    this.prefs.setBoolean(PrefKeys.GLASS_TOGGLE_ENABLED, enabled);
  }

  /** 液态玻璃滑块（试验性，偏好 + 镜像同写）：开启时所有 Slider 走 GL 渲染。 */
  setGlassSlider(enabled: boolean): void {
    this.state.glassSlider = enabled;
    this.prefs.setBoolean(PrefKeys.GLASS_SLIDER_ENABLED, enabled);
  }

  /** 液态玻璃弹窗（试验性，偏好 + 镜像同写）：开启时所有弹窗走液态玻璃样式渲染。 */
  setGlassDialog(enabled: boolean): void {
    this.state.glassDialog = enabled;
    this.prefs.setBoolean(PrefKeys.GLASS_DIALOG_ENABLED, enabled);
  }

  /** 液态玻璃总开关是否生效 */
  isGlassEffectsActive(): boolean {
    return this.state.glassEffects;
  }

  /** 液态玻璃页签是否生效（总开关与子开关同时开启） */
  isGlassTabBarActive(): boolean {
    return this.state.glassEffects && this.state.glassTabBar;
  }

  /** 液态玻璃开关是否生效（总开关与子开关同时开启） */
  isGlassToggleActive(): boolean {
    return this.state.glassEffects && this.state.glassToggle;
  }

  /** 液态玻璃滑块是否生效（总开关与子开关同时开启） */
  isGlassSliderActive(): boolean {
    return this.state.glassEffects && this.state.glassSlider;
  }

  /** 液态玻璃弹窗是否生效（总开关与子开关同时开启） */
  isGlassDialogActive(): boolean {
    return this.state.glassEffects && this.state.glassDialog;
  }

  /** 指纹解锁开关落状态（偏好 + 镜像同写）：偏好是唯一状态源（plan §1.5 v1.4）。 */
  setFingerprintEnabled(enabled: boolean): void {
    this.state.fingerprintEnabled = enabled;
    this.prefs.setBoolean(PrefKeys.BIOMETRIC_FINGERPRINT_ENABLED, enabled);
  }

  /** 人脸解锁开关落状态（偏好 + 镜像同写）：偏好是唯一状态源（plan §1.5 v1.4）。 */
  setFaceEnabled(enabled: boolean): void {
    this.state.faceEnabled = enabled;
    this.prefs.setBoolean(PrefKeys.BIOMETRIC_FACE_ENABLED, enabled);
  }

  /** 优先使用方式落状态（偏好 + 镜像同写）。 */
  setBiometricPreferred(type: BiometricType): void {
    this.state.preferredBiometric = type;
    this.prefs.setString(PrefKeys.BIOMETRIC_PREFERRED, type);
  }

  /** 是否任一生物识别方式开启（解锁页入口与登录恢复密钥的判定源）。 */
  anyBiometricEnabled(): boolean {
    return this.state.fingerprintEnabled || this.state.faceEnabled;
  }

  /**
   * 按设备能力收敛生物识别开关（组合根冷启动预载后调用）：legacy 迁移或登录页
   * 批量落值可能给设备不支持的方式留下开启值——设置页对应行虽不渲染，但该状态会
   * 误入解锁认证方式列表。此处统一关闭落偏好，保证"开启的方式 ⊆ 设备支持的方式"。
   */
  retainSupportedBiometrics(capability: BiometricCapability): void {
    if (!capability.isSupported('fingerprint') && this.state.fingerprintEnabled) {
      this.setFingerprintEnabled(false);
    }
    if (!capability.isSupported('face') && this.state.faceEnabled) {
      this.setFaceEnabled(false);
    }
  }

  setSort(recent: boolean): void {
    this.state.sortRecent = recent;
    this.prefs.setNumber(PrefKeys.SORT_MODE, recent ? 1 : 0);
    AppState.get().notifySettingsChanged();
  }
}
