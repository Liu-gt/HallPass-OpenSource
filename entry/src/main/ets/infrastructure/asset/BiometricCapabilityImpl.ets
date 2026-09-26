/*
 * SPDX-FileCopyrightText: 2026 Liugt
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import { userAuth } from '@kit.UserAuthenticationKit';
import { BiometricCapability, BiometricType } from '../../domain/biometric/BiometricCapability';

/** userAuth 业务错误码（errorcode-useriam）：硬件不支持该认证类型。 */
const CODE_HARDWARE_NOT_SUPPORTED: number = 12500003;
/** userAuth 业务错误码：认证类型未支持（无该传感器设备的返回形态之一）。 */
const CODE_TYPE_NOT_SUPPORT: number = 12500005;

/**
 * 生物识别能力实现（v1.4）：userAuth.getAvailableStatus 同步探测（ATL1 与快速解锁
 * 门控同级；module.json5 已声明 ACCESS_BIOMETRIC）。
 * 仅硬件缺失（12500003/12500005）判不支持；未录入凭据（12500002）等其余状态视为支持——
 * 开启开关弹系统认证框时由系统引导录入，设置页不应因此隐藏行。
 */
export class BiometricCapabilityImpl implements BiometricCapability {
  isSupported(type: BiometricType): boolean {
    const authType: userAuth.UserAuthType = type === 'face'
      ? userAuth.UserAuthType.FACE
      : userAuth.UserAuthType.FINGERPRINT;
    try {
      userAuth.getAvailableStatus(authType, userAuth.AuthTrustLevel.ATL1);
      return true;
    } catch (e) {
      const code: number = (e as BusinessError).code;
      return code !== CODE_HARDWARE_NOT_SUPPORTED && code !== CODE_TYPE_NOT_SUPPORT;
    }
  }
}
