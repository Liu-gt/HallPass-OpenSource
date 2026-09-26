/*
 * SPDX-FileCopyrightText: 2026 Liugt
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import { describe, it, expect } from '@ohos/hypium';
import { SettingsService } from '../main/ets/application/SettingsService';
import { BiometricCapability, BiometricType }
  from '../main/ets/domain/biometric/BiometricCapability';
import { FakePrefs } from './fakes/FakePrefs';
import { PrefKeys } from '../main/ets/domain/repository/PreferencesStore';

/** 能力假实现：按构造参数声明设备支持哪些生物识别方式。 */
class FakeCapability implements BiometricCapability {
  private readonly fingerprint: boolean;
  private readonly face: boolean;

  constructor(fingerprint: boolean, face: boolean) {
    this.fingerprint = fingerprint;
    this.face = face;
  }

  isSupported(type: BiometricType): boolean {
    return type === 'face' ? this.face : this.fingerprint;
  }
}

/**
 * SettingsService 本地单测（v1.4 生物识别按模态拆键）：plan §1.5 约定各开关以偏好为
 * 唯一状态源、冷启动 load() 回显。设置页写路径必须"偏好 + 镜像同写"，
 * 否则冷启动镜像回读旧偏好，开关回弹固定值——即"重新进入设置页开关显示固定非实际值"。
 */
export default function settingsServiceTest() {
  describe('SettingsService', () => {

    it('fingerprint_enable_persists_across_cold_restart', 0, async () => {
      const prefs: FakePrefs = new FakePrefs();
      const service: SettingsService = new SettingsService(prefs);
      // 模拟设置页开启路径的落状态调用（SettingsViewModel.setFingerprintUnlock）
      service.setFingerprintEnabled(true);
      // 模拟冷启动：新进程新服务实例，从偏好重新预载镜像
      const restarted: SettingsService = new SettingsService(prefs);
      await restarted.load();
      expect(restarted.state.fingerprintEnabled).assertTrue();
    });

    it('face_disable_persists_across_cold_restart', 0, async () => {
      const prefs: FakePrefs = new FakePrefs();
      await prefs.setBoolean(PrefKeys.BIOMETRIC_FACE_ENABLED, true);
      const service: SettingsService = new SettingsService(prefs);
      // 模拟设置页关闭路径（清密钥后回落的镜像写）
      service.setFaceEnabled(false);
      const restarted: SettingsService = new SettingsService(prefs);
      await restarted.load();
      expect(restarted.state.faceEnabled).assertFalse();
      expect(restarted.anyBiometricEnabled()).assertFalse();
    });

    it('legacy_biometric_pref_migrates_to_both_modalities_once', 0, async () => {
      const prefs: FakePrefs = new FakePrefs();
      // v1.3 升级设备：legacy 总开关为 true，v1.4 新键缺失
      await prefs.setBoolean(PrefKeys.BIOMETRIC_UNLOCK_ENABLED, true);
      const service: SettingsService = new SettingsService(prefs);
      await service.load();
      expect(service.state.fingerprintEnabled).assertTrue();
      expect(service.state.faceEnabled).assertTrue();
      // 迁移产物已落新键：再开新进程（legacy 仍在但不再读取）状态保持
      const restarted: SettingsService = new SettingsService(prefs);
      await restarted.load();
      expect(restarted.state.fingerprintEnabled).assertTrue();
      expect(restarted.state.faceEnabled).assertTrue();
      // legacy=false 不应迁移
      const prefs2: FakePrefs = new FakePrefs();
      await prefs2.setBoolean(PrefKeys.BIOMETRIC_UNLOCK_ENABLED, false);
      const s2: SettingsService = new SettingsService(prefs2);
      await s2.load();
      expect(s2.state.fingerprintEnabled).assertFalse();
      expect(s2.state.faceEnabled).assertFalse();
    });

    it('preferred_biometric_persists_across_cold_restart', 0, async () => {
      const prefs: FakePrefs = new FakePrefs();
      const service: SettingsService = new SettingsService(prefs);
      service.setBiometricPreferred('face');
      const restarted: SettingsService = new SettingsService(prefs);
      await restarted.load();
      expect(restarted.state.preferredBiometric).assertEqual('face');
    });

    it('retain_supported_biometrics_clamps_unsupported_modalities', 0, async () => {
      const prefs: FakePrefs = new FakePrefs();
      const service: SettingsService = new SettingsService(prefs);
      // 模拟 legacy 迁移/登录页批量落值：两种方式均为开启
      service.setFingerprintEnabled(true);
      service.setFaceEnabled(true);
      // 仅指纹设备：人脸开启值被收敛落盘，指纹保留
      service.retainSupportedBiometrics(new FakeCapability(true, false));
      expect(service.state.fingerprintEnabled).assertTrue();
      expect(service.state.faceEnabled).assertFalse();
      expect(service.anyBiometricEnabled()).assertTrue();
      const restarted: SettingsService = new SettingsService(prefs);
      await restarted.load();
      expect(restarted.state.faceEnabled).assertFalse();
      // 无任何生物识别设备：两种方式全收敛
      const prefs2: FakePrefs = new FakePrefs();
      const s2: SettingsService = new SettingsService(prefs2);
      s2.setFingerprintEnabled(true);
      s2.setFaceEnabled(true);
      s2.retainSupportedBiometrics(new FakeCapability(false, false));
      expect(s2.anyBiometricEnabled()).assertFalse();
    });

    it('clipboard_toggle_persists_across_cold_restart', 0, async () => {
      const prefs: FakePrefs = new FakePrefs();
      const service: SettingsService = new SettingsService(prefs);
      service.setClipboardClear(false);
      const restarted: SettingsService = new SettingsService(prefs);
      await restarted.load();
      expect(restarted.state.clipboardClear).assertFalse();
    });

    it('glass_effects_and_sub_switches_active_states', 0, async () => {
      const prefs: FakePrefs = new FakePrefs();
      const service: SettingsService = new SettingsService(prefs);
      // 默认状态：全部为 false
      expect(service.isGlassEffectsActive()).assertFalse();
      expect(service.isGlassTabBarActive()).assertFalse();
      expect(service.isGlassToggleActive()).assertFalse();
      expect(service.isGlassSliderActive()).assertFalse();

      // 开启总开关与各子开关
      service.setGlassEffects(true);
      service.setGlassTabBar(true);
      service.setGlassToggle(true);
      service.setGlassSlider(true);
      expect(service.isGlassEffectsActive()).assertTrue();
      expect(service.isGlassTabBarActive()).assertTrue();
      expect(service.isGlassToggleActive()).assertTrue();
      expect(service.isGlassSliderActive()).assertTrue();

      // 关闭总开关：所有子开关生效判定均应为 false
      service.setGlassEffects(false);
      expect(service.isGlassEffectsActive()).assertFalse();
      expect(service.isGlassTabBarActive()).assertFalse();
      expect(service.isGlassToggleActive()).assertFalse();
      expect(service.isGlassSliderActive()).assertFalse();
    });

    it('setGlassEffects_does_not_mutate_glassTabBarEpoch', 0, async () => {
      const prefs: FakePrefs = new FakePrefs();
      const service: SettingsService = new SettingsService(prefs);
      const initialEpoch: number = service.state.glassTabBarEpoch;

      service.setGlassEffects(false);
      expect(service.state.glassTabBarEpoch).assertEqual(initialEpoch);

      service.setGlassEffects(true);
      expect(service.state.glassTabBarEpoch).assertEqual(initialEpoch);

      // setGlassTabBar 仍应自增纪元
      service.setGlassTabBar(false);
      expect(service.state.glassTabBarEpoch).assertEqual(initialEpoch + 1);
    });
  });
}
