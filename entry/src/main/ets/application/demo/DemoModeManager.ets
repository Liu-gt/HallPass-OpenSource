/*
 * SPDX-FileCopyrightText: 2026 Liugt
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import { AppState } from '../state/AppState';
import { ServiceLocator } from '../ServiceLocator';
import { ItemEditViewModel } from '../../features/vault/ItemEditViewModel';
import { MockDataset } from './MockDataset';
import { createDemoSandbox } from './DemoServices';
import { AppContainer } from '../bootstrap/AppContainer';
import { ThemeService } from '../theme/ThemeService';
import { AppTheme } from '../../common/design/AppTheme';
import { PrefKeys } from '../../domain/repository/PreferencesStore';
import { hilog } from '@kit.PerformanceAnalysisKit';

const TAG: string = 'DemoModeManager';

export class DemoModeManager {
  private static instance: DemoModeManager | null = null;
  private inDemoMode: boolean = false;

  static get(): DemoModeManager {
    if (DemoModeManager.instance === null) {
      DemoModeManager.instance = new DemoModeManager();
    }
    return DemoModeManager.instance;
  }

  isDemo(): boolean {
    return this.inDemoMode;
  }

  /** 进入体验模式 */
  enterDemoMode(): void {
    if (this.inDemoMode) {
      return;
    }
    hilog.info(0x0000, TAG, 'Entering UI Experience Mode...');
    this.inDemoMode = true;

    // 1. 初始化 Mock 数据并注水到 ServiceLocator 沙箱
    const mockCiphers = MockDataset.createMockCiphers();
    const mockFolders = MockDataset.createMockFolders();
    const cryptoEngine = ServiceLocator.crypto();
    const sandbox = createDemoSandbox(mockCiphers, mockFolders, cryptoEngine, (): void => {
      this.exitDemoMode();
    });
    ServiceLocator.enterDemoMode(sandbox);

    // 2. 状态机迁移到 demo
    AppState.get().transitionTo('demo');
  }

  /**
   * 退出体验模式并彻底擦除内存 (严格执行异步生命周期解耦，修复 HIGH-v2-01)
   */
  exitDemoMode(): void {
    if (!this.inDemoMode) {
      return;
    }
    hilog.info(0x0000, TAG, 'Exiting UI Experience Mode and clearing memory...');
    this.inDemoMode = false;

    // 阶段 1：深度清除所有新建/编辑草稿
    ItemEditViewModel.clearAll();

    // 阶段 2：优先迁移状态机回 onboarding，触发 ArkUI 卸载主界面主树与子页面
    AppState.get().transitionTo('onboarding');

    // 阶段 3 (修复 HIGH-v2-01)：推迟沙箱销毁至下一个宏任务循环
    // 确保当前挂载的所有 UI 组件与子页面（如 ItemDetailPage）的 aboutToDisappear() 钩子
    // 能够平稳在当前的沙箱上下文内完成注销，绝不误唤醒生产 SyncService！
    setTimeout((): void => {
      ServiceLocator.exitDemoMode();

      // 阶段 4 (修复 MED-01)：从真实持久化磁盘 Preferences 中重载主题与深浅色，消除外观分裂
      AppContainer.get().prefs.getString(PrefKeys.THEME_ID).then((themeId: string | null): Promise<string | null> => {
        if (themeId !== null) {
          ThemeService.get().setTheme(themeId);
        } else {
          ThemeService.get().setTheme(AppTheme.defaultTheme.id);
        }
        return AppContainer.get().prefs.getString(PrefKeys.COLOR_MODE);
      }).then((colorMode: string | null): void => {
        if (colorMode === 'light' || colorMode === 'dark' || colorMode === 'system') {
          ThemeService.get().setColorMode(colorMode);
        } else {
          ThemeService.get().setColorMode('system');
        }
      }).catch((_e: Object): void => {
        // 容错兜底
      });
    }, 0);
  }
}
