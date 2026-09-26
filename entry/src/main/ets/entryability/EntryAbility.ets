/*
 * SPDX-FileCopyrightText: 2026 Liugt
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import { AbilityConstant, Configuration, ConfigurationConstant, UIAbility, Want }
  from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { display, window } from '@kit.ArkUI';
import { AppContainer } from '../application/bootstrap/AppContainer';
import { LockService } from '../application/LockService';
import { ThemeService } from '../application/theme/ThemeService';
import { SafeArea } from '../common/design/SafeArea';
import { SystemBar } from '../common/design/SystemBar';

const DOMAIN: number = 0x0000;
const TAG: string = 'HallPassEntry';

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onCreate');
    // 组合根初始化 + 冷启动相位恢复（plan R5：locked/onboarding 起步）
    AppContainer.init(this.context).then((container: AppContainer): Promise<void> => {
      return container.sessionService.restoreOnLaunch()
        .then((): Promise<void> => container.tryAutoUnlockOnLaunch());
    }).catch((err: Object): void => {
      hilog.error(DOMAIN, TAG, 'bootstrap failed: %{public}s', JSON.stringify(err));
    });
  }

  onDestroy(): void {
    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onDestroy');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onWindowStageCreate');
    this.updateSafeArea(windowStage);

    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, TAG, 'Failed to load the content. Cause: %{public}s',
          JSON.stringify(err));
        return;
      }
      hilog.info(DOMAIN, TAG, 'Succeeded in loading the content.');
    });

    try {
      this.context.getApplicationContext().setColorMode(
        ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'Failed to set colorMode. Cause: %{public}s',
        JSON.stringify(err));
    }

    // 防截屏窗口标志（spec F13：默认开，偏好覆盖）
    try {
      const mainWindow: window.Window = windowStage.getMainWindowSync();
      AppContainer.init(this.context).then((container: AppContainer): Promise<void> => {
        return container.applyScreenshotPolicy((enabled: boolean): void => {
          mainWindow.setWindowPrivacyMode(enabled).catch((privacyErr: Object): void => {
            hilog.error(DOMAIN, TAG, 'setWindowPrivacyMode failed: %{public}s',
              JSON.stringify(privacyErr));
          });
        });
      }).catch((err: Object): void => {
        hilog.error(DOMAIN, TAG, 'screenshot policy failed: %{public}s', JSON.stringify(err));
      });
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'main window unavailable: %{public}s', JSON.stringify(err));
    }
  }

  onWindowStageDestroy(): void {
    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onWindowStageDestroy');
  }

  onForeground(): void {
    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onForeground');
    if (AppContainer.initialized()) {
      AppContainer.get().lockService.onForeground();
    }
  }

  onBackground(): void {
    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onBackground');
    if (AppContainer.initialized()) {
      AppContainer.get().lockService.onBackground();
    }
  }

  /** 深浅色系统回调（plan D4）：跟随系统时刷新品牌色侧别。 */
  onConfigurationUpdate(newConfig: Configuration): void {
    const systemDark: boolean =
      newConfig.colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
    ThemeService.get().notifySystemDarkMode(systemDark);
  }

  /** 安全区避让注入（票 23 沉浸式）：状态栏/导航条高度换算 vp 供页面组件读取。 */
  private updateSafeArea(windowStage: window.WindowStage): void {
    try {
      const mainWindow: window.Window = windowStage.getMainWindowSync();
      AppStorage.setOrCreate('mainWindow', mainWindow);
      // 状态栏背景由各页面顶部组件的 expandSafeArea 绘制；这里只保留图标颜色。
      SystemBar.apply(ThemeService.get().state.isDark, mainWindow);
      const density: number = display.getDefaultDisplaySync().densityPixels;
      const systemArea: window.AvoidArea =
        mainWindow.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
      const navArea: window.AvoidArea =
        mainWindow.getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR);
      SafeArea.update(systemArea.topRect.height / density,
        navArea.bottomRect.height / density);
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'updateSafeArea failed: %{public}s', JSON.stringify(err));
    }
  }
}
