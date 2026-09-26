/*
 * SPDX-FileCopyrightText: 2026 Liugt
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import { describe, it, expect } from '@ohos/hypium';
import { SystemBar } from '../main/ets/common/design/SystemBar';
import { ThemeService } from '../main/ets/application/theme/ThemeService';
import { window } from '@kit.ArkUI';

class MockWindow {
  lastProperties: window.SystemBarProperties | null = null;
  callCount: number = 0;
  shouldRejectFirst: boolean = false;

  setWindowSystemBarProperties(props: window.SystemBarProperties): Promise<void> {
    this.callCount++;
    this.lastProperties = props;
    if (this.shouldRejectFirst && this.callCount === 1) {
      return Promise.reject(new Error('navigation bar not supported'));
    }
    return Promise.resolve();
  }
}

export default function systemBarTest() {
  describe('SystemBar', () => {

    it('color_constants_are_correct', 0, () => {
      expect(SystemBar.LIGHT_CONTENT_COLOR).assertEqual('#B3000000');
      expect(SystemBar.DARK_CONTENT_COLOR).assertEqual('#FFFFFF');
    });

    it('apply_dark_mode_sets_white_content_and_light_icons', 0, () => {
      const mock = new MockWindow();
      SystemBar.apply(true, mock as Object as window.Window);

      expect(mock.callCount).assertEqual(1);
      expect(mock.lastProperties !== null).assertTrue();
      if (mock.lastProperties !== null) {
        expect(mock.lastProperties.statusBarColor).assertEqual('#00000000');
        expect(mock.lastProperties.statusBarContentColor).assertEqual('#FFFFFF');
        expect(mock.lastProperties.isStatusBarLightIcon).assertTrue();
        expect(mock.lastProperties.navigationBarColor).assertEqual('#00000000');
        expect(mock.lastProperties.navigationBarContentColor).assertEqual('#FFFFFF');
        expect(mock.lastProperties.isNavigationBarLightIcon).assertTrue();
      }
    });

    it('apply_light_mode_sets_black_content_and_dark_icons', 0, () => {
      const mock = new MockWindow();
      SystemBar.apply(false, mock as Object as window.Window);

      expect(mock.callCount).assertEqual(1);
      expect(mock.lastProperties !== null).assertTrue();
      if (mock.lastProperties !== null) {
        expect(mock.lastProperties.statusBarColor).assertEqual('#00000000');
        expect(mock.lastProperties.statusBarContentColor).assertEqual('#B3000000');
        expect(mock.lastProperties.isStatusBarLightIcon).assertFalse();
        expect(mock.lastProperties.navigationBarColor).assertEqual('#00000000');
        expect(mock.lastProperties.navigationBarContentColor).assertEqual('#B3000000');
        expect(mock.lastProperties.isNavigationBarLightIcon).assertFalse();
      }
    });

    it('fallback_retry_when_full_properties_rejected', 0, async () => {
      const mock = new MockWindow();
      mock.shouldRejectFirst = true;
      SystemBar.apply(true, mock as Object as window.Window);

      // 等待微任务队列执行 catch 逻辑
      await new Promise<void>((resolve: () => void) => {
        setTimeout(resolve, 50);
      });

      expect(mock.callCount).assertEqual(2);
      expect(mock.lastProperties !== null).assertTrue();
      if (mock.lastProperties !== null) {
        expect(mock.lastProperties.statusBarContentColor).assertEqual('#FFFFFF');
        expect(mock.lastProperties.isStatusBarLightIcon).assertTrue();
      }
    });

    it('theme_service_mode_switch_updates_is_dark', 0, () => {
      const themeService = ThemeService.get();

      themeService.setColorMode('dark');
      expect(themeService.state.isDark).assertTrue();

      themeService.setColorMode('light');
      expect(themeService.state.isDark).assertFalse();

      themeService.setColorMode('system');
      themeService.notifySystemDarkMode(true);
      expect(themeService.state.isDark).assertTrue();

      themeService.notifySystemDarkMode(false);
      expect(themeService.state.isDark).assertFalse();
    });
  });
}
