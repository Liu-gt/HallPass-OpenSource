/*
 * SPDX-FileCopyrightText: 2026 Liugt
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import { window } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN = 0x0000;
const TAG = 'SystemBar';

/**
 * 系统栏（状态栏与导航栏）属性管理。
 * 根据当前深浅色模式自动适配状态栏与导航栏字体/图标颜色：
 * 深色模式下为白色（#FFFFFF），浅色模式下为黑色半透明（#B3000000）。
 */
export class SystemBar {
  static readonly LIGHT_CONTENT_COLOR: string = '#B3000000';
  static readonly DARK_CONTENT_COLOR: string = '#FFFFFF';

  /**
   * 应用状态栏与导航栏内容颜色。
   * @param isDark 是否处于深色模式
   * @param targetWindow 可选的窗口实例，缺省时从 AppStorage 获取 'mainWindow'
   */
  static apply(isDark: boolean, targetWindow?: window.Window): void {
    const mainWindow: window.Window | undefined =
      targetWindow ?? AppStorage.get<window.Window>('mainWindow');
    if (!mainWindow) {
      return;
    }
    const contentColor: string = isDark ? SystemBar.DARK_CONTENT_COLOR : SystemBar.LIGHT_CONTENT_COLOR;
    try {
      mainWindow.setWindowSystemBarProperties({
        statusBarColor: '#00000000',
        statusBarContentColor: contentColor,
        isStatusBarLightIcon: isDark,
        navigationBarColor: '#00000000',
        navigationBarContentColor: contentColor,
        isNavigationBarLightIcon: isDark
      }).catch((err: Object): void => {
        hilog.warn(DOMAIN, TAG, 'full setWindowSystemBarProperties failed: %{public}s, retrying minimal config',
          JSON.stringify(err));
        // 降级保护：在不支持 navigationBar 属性或参数校验严格的系统上仅设置状态栏
        mainWindow.setWindowSystemBarProperties({
          statusBarColor: '#00000000',
          statusBarContentColor: contentColor,
          isStatusBarLightIcon: isDark
        }).catch((fallbackErr: Object): void => {
          hilog.error(DOMAIN, TAG, 'fallback setWindowSystemBarProperties failed: %{public}s',
            JSON.stringify(fallbackErr));
        });
      });
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'setWindowSystemBarProperties throw: %{public}s', JSON.stringify(err));
    }
  }
}
