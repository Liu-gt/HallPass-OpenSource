/*
 * SPDX-FileCopyrightText: 2026 Liugt
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import { common, ConfigurationConstant, AbilityConstant, Configuration, EnvironmentCallback } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { AppTheme, ThemeOption } from '../../common/design/AppTheme';
import { SystemBar } from '../../common/design/SystemBar';

const DOMAIN = 0x0000;
const TAG = 'HallPassTheme';

/** 深浅色偏好：跟随系统 / 手动固定（plan D4） */
export type ColorModePreference = 'system' | 'light' | 'dark';

/** 系统环境变化（深浅色 / 语言 / 字体缩放）订阅者。 */
export type ConfigurationListener = () => void;

/**
 * 品牌色状态（plan D4 颜色三通道之二）：primary/on_primary 运行时取值。
 * 中性色不在此处——走 $r('app.color.*') 资源限定词自动深浅。
 * 深浅双值取自 AppTheme 色板；isDark 为生效侧别（固定深浅优先于系统）。
 */
@ObservedV2
export class ThemeState {
  @Trace themeId: string = AppTheme.defaultTheme.id;
  @Trace colorMode: ColorModePreference = 'system';
  /** 生效深色标记：固定深浅时取固定值，跟随系统时取最近一次系统上报 */
  @Trace isDark: boolean = false;
  @Trace primary: string = AppTheme.defaultTheme.light;
  @Trace onPrimary: string = AppTheme.onPrimaryLight;
}

/**
 * 主题服务（单例）：五套主题运行时切换 + 深浅色固定 API。
 * 接线约定（票 10 执行）：EntryAbility 启动时调 attach(context)；
 * onConfigurationUpdate 转交 notifySystemDarkMode(isDark)。
 */
export class ThemeService {
  private static readonly instance: ThemeService = new ThemeService();

  static get(): ThemeService {
    return ThemeService.instance;
  }

  readonly state: ThemeState = new ThemeState();
  private appContext?: common.Context;
  private systemDark: boolean = false;
  /** 环境变化订阅者（见 onConfigurationChanged）。 */
  private configListeners: ConfigurationListener[] = [];
  private environmentCallbackId: number = -1;

  private constructor() {
  }

  /** EntryAbility 注入上下文：手动固定深浅时同步 ApplicationContext.setColorMode（plan D4） */
  attach(context: common.Context): void {
    this.appContext = context;
    try {
      const config: Configuration | undefined = (context as common.UIAbilityContext).config;
      if (config && config.colorMode !== undefined) {
        this.systemDark = config.colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
        if (this.state.colorMode === 'system') {
          this.state.isDark = this.systemDark;
          this.applyBrandColors();
        }
      }
      this.syncGlassDarkMode();
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'Failed to inspect initial context config: %{public}s', JSON.stringify(err));
    }
    this.registerEnvironmentCallback();
  }

  /**
   * 订阅系统环境变化（深浅色 / 语言 / 字体缩放）。
   *
   * BuilderNode / ComponentContent 不在 ArkUI 的自动刷新链路上，必须由持有者手动调
   * `updateConfiguration()` 才能跟随（见《应用深浅色适配》"自定义节点适配"）——
   * 这里把 application context 的 'environment' 回调转成应用内广播，features 层
   * 因此不必直接 import 系统能力（plan D1 铁律 1）。
   */
  onConfigurationChanged(listener: ConfigurationListener): void {
    if (this.configListeners.indexOf(listener) < 0) {
      this.configListeners.push(listener);
    }
  }

  offConfigurationChanged(listener: ConfigurationListener): void {
    const index: number = this.configListeners.indexOf(listener);
    if (index >= 0) {
      this.configListeners.splice(index, 1);
    }
  }

  private registerEnvironmentCallback(): void {
    if (this.environmentCallbackId >= 0 || this.appContext === undefined) {
      return;
    }
    const callback: EnvironmentCallback = {
      onConfigurationUpdated: (config: Configuration): void => {
        if (config.colorMode !== undefined) {
          const isDark: boolean =
            config.colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
          this.notifySystemDarkMode(isDark);
        }
        this.notifyConfigurationChanged();
      },
      onMemoryLevel: (_level: AbilityConstant.MemoryLevel): void => {}
    };
    try {
      this.environmentCallbackId = this.appContext.getApplicationContext().on('environment', callback);
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'Failed to listen environment change. Cause: %{public}s',
        JSON.stringify(err));
    }
  }

  /** 广播给订阅者（先拷贝：回调里可能退订）。 */
  private notifyConfigurationChanged(): void {
    const listeners: ConfigurationListener[] = this.configListeners.slice();
    listeners.forEach((listener: ConfigurationListener): void => {
      listener();
    });
  }

  /** 切换主题（themeId 取 AppTheme.all 的 id），即时生效无需重启 */
  setTheme(themeId: string): void {
    if (!AppTheme.all.some((t: ThemeOption) => t.id === themeId)) {
      return;
    }
    this.state.themeId = themeId;
    this.applyBrandColors();
  }

  /** 固定深浅色：'system' 跟随系统，'light'/'dark' 强制品牌色取对应侧值 */
  setColorMode(mode: ColorModePreference): void {
    this.state.colorMode = mode;
    this.state.isDark = mode === 'dark' ? true : (mode === 'light' ? false : this.systemDark);
    this.applyBrandColors();
    SystemBar.apply(this.state.isDark);
    this.syncApplicationContext();
    this.syncGlassDarkMode();
  }

  /** EntryAbility.onConfigurationUpdate 转交：跟随系统时刷新品牌色侧别 */
  notifySystemDarkMode(isDark: boolean): void {
    this.systemDark = isDark;
    if (this.state.colorMode === 'system') {
      this.state.isDark = isDark;
      this.applyBrandColors();
      SystemBar.apply(this.state.isDark);
      this.syncGlassDarkMode();
    }
  }

  private applyBrandColors(): void {
    const theme: ThemeOption = AppTheme.all.find((t: ThemeOption) => t.id === this.state.themeId)
      ?? AppTheme.defaultTheme;
    this.state.primary = this.state.isDark ? theme.dark : theme.light;
    this.state.onPrimary = this.state.isDark ? AppTheme.onPrimaryDark : AppTheme.onPrimaryLight;
  }

  private syncApplicationContext(): void {
    if (!this.appContext) {
      return;
    }
    const target = this.state.colorMode === 'dark' ? ConfigurationConstant.ColorMode.COLOR_MODE_DARK
      : (this.state.colorMode === 'light' ? ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT
        : ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
    try {
      this.appContext.getApplicationContext().setColorMode(target);
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'Failed to set colorMode. Cause: %{public}s', JSON.stringify(err));
    }
  }

  private static glassDarkModeHandler?: (dark: boolean) => void;

  /** 注册液态玻璃深色模式同步器（UI 层注入，避免基础服务层静态依赖原生模块） */
  static registerGlassDarkModeHandler(handler: (dark: boolean) => void): void {
    ThemeService.glassDarkModeHandler = handler;
    try {
      handler(ThemeService.instance.state.isDark);
    } catch (_e) {
      // 容错处理
    }
  }

  private syncGlassDarkMode(): void {
    try {
      ThemeService.glassDarkModeHandler?.(this.state.isDark);
    } catch (_e) {
      // 容错处理
    }
  }
}
