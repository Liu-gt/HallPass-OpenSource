/*
 * SPDX-FileCopyrightText: 2026 Liugt
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

/**
 * 非敏感偏好键（plan §1.5 锁定清单，唯一收口）。
 * 新增键必须先修订 plan.md（autonomous_run.md 约束）；会话令牌等敏感值不在此存储（走 KeyStore）。
 */
export class PrefKeys {
  static readonly THEME_ID: string = 'themeId';
  static readonly COLOR_MODE: string = 'colorMode';
  /** 0 从不 / 1 一分钟 / 2 五分钟 / 3 一小时（spec F4，默认 2） */
  static readonly AUTO_LOCK_LEVEL: string = 'autoLockLevel';
  static readonly CLIPBOARD_AUTO_CLEAR: string = 'clipboardAutoClear';
  static readonly BLOCK_SCREENSHOT: string = 'blockScreenshot';
  /** 0 名称 / 1 最近使用（spec F6） */
  static readonly SORT_MODE: string = 'sortMode';
  static readonly LAST_EMAIL: string = 'lastEmail';
  static readonly LAST_SERVER_URL: string = 'lastServerUrl';
  /** KDF 参数缓存（plan §1.5 v1.1）：按"服务器+邮箱"维度，仅参数、无密钥材料；登出清除。 */
  static readonly LAST_KDF_JSON: string = 'lastKdfJson';
  /** 生成器参数（plan §1.5 v1.2）：模式/长度/字符集开关；生成结果不落盘。 */
  static readonly GEN_PARAMS_JSON: string = 'genParamsJson';
  /** 进入应用需解锁开关（plan §1.5 v1.3，默认 true）；关闭时冷启动静默恢复密钥。 */
  static readonly ENTRY_LOCK_REQUIRED: string = 'entryLockRequired';
  /** 生物识别快速解锁总开关（plan §1.5 v1.3，已废弃）：仅作 v1.4 按模态拆键的一次性迁移源。 */
  static readonly BIOMETRIC_UNLOCK_ENABLED: string = 'biometricUnlockEnabled';
  /** 指纹解锁开关（plan §1.5 v1.4，默认 false）；偏好为唯一状态源。 */
  static readonly BIOMETRIC_FINGERPRINT_ENABLED: string = 'biometricFingerprintEnabled';
  /** 人脸解锁开关（plan §1.5 v1.4，默认 false）；偏好为唯一状态源。 */
  static readonly BIOMETRIC_FACE_ENABLED: string = 'biometricFaceEnabled';
  /** 优先使用方式（plan §1.5 v1.4，'fingerprint' | 'face'，默认 'fingerprint'）。 */
  static readonly BIOMETRIC_PREFERRED: string = 'biometricPreferred';
  /** 设备标识 UUID（plan §1.5 v1.5）：非敏感，首次生成后持久化，让服务器把本机记为
   *  已知设备（官方云新设备验证/新设备登录邮件以它识别设备）。 */
  static readonly DEVICE_IDENTIFIER: string = 'deviceIdentifier';
  /** 液态玻璃效果总开关（试验性，默认 false）：开启后才启用镜像组件树与液态玻璃各组件。 */
  static readonly GLASS_EFFECTS_ENABLED: string = 'glassEffectsEnabled';
  /** 液态玻璃页签开关（试验性，默认 false）：关闭回退原版 ArkUI 页签。 */
  static readonly GLASS_TAB_BAR_ENABLED: string = 'glassTabBarEnabled';
  /** 液态玻璃开关控件（试验性，默认 false）：开启后所有 Switch 型 Toggle 走 GL 渲染。 */
  static readonly GLASS_TOGGLE_ENABLED: string = 'glassToggleEnabled';
  /** 液态玻璃滑块控件（试验性，默认 false）：开启后所有 Slider 走 GL 渲染。 */
  static readonly GLASS_SLIDER_ENABLED: string = 'glassSliderEnabled';
}

/**
 * 非敏感偏好存取接口（plan D3 持久化分工）：键值小对象、高频同步读。
 * 实现位于 infrastructure/prefs（Preferences）；键名一律经 PrefKeys 收口（T08 验收）。
 * colorMode 的取值为 'system' | 'light' | 'dark' 字符串（与 application/theme/ThemeService
 * 的 ColorModePreference 对齐）；domain 层不 import application（依赖方向，plan §3），转换由调用方做。
 */
export interface PreferencesStore {
  getString(key: string): Promise<string | null>;
  setString(key: string, value: string): Promise<void>;

  getBoolean(key: string): Promise<boolean | null>;
  setBoolean(key: string, value: boolean): Promise<void>;

  getNumber(key: string): Promise<number | null>;
  setNumber(key: string, value: number): Promise<void>;
}
