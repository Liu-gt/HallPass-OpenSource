/*
 * SPDX-FileCopyrightText: 2026 Liugt
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

/**
 * 生物识别方式（spec F3，v1.4 增补）：设置页按设备支持情况展示对应开关；
 * PIN（锁屏凭据）始终作为快速解锁兜底方式，不属于本枚举。
 */
export type BiometricType = 'fingerprint' | 'face';

/**
 * 生物识别能力探测接口（plan D3 分层：实现位于 infrastructure/asset，零 kit 依赖可本地假实现）。
 * "支持"= 设备具备该识别方式硬件；未录入凭据也视为支持（开启开关后由系统认证框引导录入）。
 */
export interface BiometricCapability {
  isSupported(type: BiometricType): boolean;
}
