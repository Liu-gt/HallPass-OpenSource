/*
 * SPDX-FileCopyrightText: 2026 Liugt
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
import {
  GlassGLWidgetConfigure,
  GlassGLWidgetDispose,
  GlassGLWidgetIsRunning,
  GlassGLWidgetSetColors,
  GlassGLWidgetSetPress,
  GlassGLWidgetSetState
} from 'backdrop';
import { ThemeService, ThemeState } from '../../../application/theme/ThemeService';
import { ServiceLocator } from '../../../application/ServiceLocator';
import { Sizes, Spacing } from '../../design/Tokens';
import {
  GLASS_SLIDER_HEIGHT,
  GLASS_WIDGET_SLIDER,
  hexToArgb,
  nextGlassWidgetId,
  resolveColorArgb
} from './GlassWidgetCommon';

const DOMAIN: number = 0x0000;
const TAG: string = 'HallPassGlassSlider';
/** 原生自检：surface / EGL 起不来就回退 ArkUI 滑块（与玻璃页签同一策略）。 */
const READY_CHECK_DELAY_MS: number = 350;
const READY_CHECK_RETRY_MS: number = 700;
const READY_CHECK_MAX_ATTEMPTS: number = 3;
/** 轻点轨道的"按压一闪"时长（SliderChangeMode.Click 没有 Begin/End 配对）。 */
const CLICK_PRESS_MS: number = 140;

/**
 * 液态玻璃滑块（试验性，设置页「液态玻璃滑块」开启后生效）：
 *
 * - 视觉由 backdrop HAR 的 GLES 渲染器画在 XComponent 上（宽度由父容器排布决定）；
 * - 触摸 / 拖动由**覆盖在上层的隐形 ArkUI Slider** 处理（滚动手势仲裁、无障碍与
 *   系统控件一致），原生只负责画；
 * - 值由 ArkUI 侧实时同步，原生的旋钮用弹簧追随（带一点滞后与回弹）；
 * - 背景固定为卡片底色，原生按需渲染；原生不可用 / 功能关闭时回退 ArkUI Slider。
 */
@ComponentV2
export struct GlassSlider {
  @Param value: number = 0;
  @Param min: number = 0;
  @Param max: number = 100;
  @Param step: number = 1;
  @Param isEnabled: boolean = true;
  /** 值变化回链（与 ArkUI Slider.onChange 同签名，父组件无需区分）。 */
  @Param onChange: (value: number, mode: SliderChangeMode) => void =
    (_value: number, _mode: SliderChangeMode): void => {
    };
  /** 所在容器是否为卡片底色（决定玻璃采样的背景色）。 */
  @Param onCard: boolean = true;
  /** 镜像树（玻璃条带背景导出）里为 true：回退静态 ArkUI 滑块，不另起原生控件线程。 */
  @Param passive: boolean = false;

  /** @Local 包装主题状态：@Monitor 只能监听状态变量（嵌套 @Trace 属性可深度监听）。 */
  @Local private theme: ThemeState = ThemeService.get().state;
  @Local private failed: boolean = false;
  private widgetId: string = nextGlassWidgetId('glassSlider');
  private readyTimer: number = -1;
  private clickTimer: number = -1;
  private readyAttempt: number = 0;
  private alive: boolean = true;
  /** 可见性（页签未激活 / 页面被覆盖时为 false）：不可见时 surface 本就不存在，自检不算失败。 */
  private visible: boolean = true;
  /** 已推送的颜色组合（主题 / 深浅色 / 容器）：重复推送没有意义，去重。 */
  private lastColorsKey: string = '';
  private controller: XComponentController = new XComponentController();

  aboutToAppear(): void {
    this.alive = true;
    try {
      this.controller.setXComponentSurfaceConfig({ isOpaque: false });
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'setXComponentSurfaceConfig failed: %{public}s', JSON.stringify(err));
    }
  }

  aboutToDisappear(): void {
    this.alive = false;
    this.clearTimers();
    this.dispose();
  }

  @Monitor('value', 'min', 'max')
  private onValueChange(): void {
    this.pushState(this.value);
  }

  @Monitor('isEnabled')
  private onEnabledChange(): void {
    if (!this.isEnabled) {
      this.pushPress(false);
    }
  }

  @Monitor('theme.primary', 'theme.isDark')
  private onThemeChange(): void {
    this.lastColorsKey = '';
    this.pushColors();
    setTimeout((): void => {
      if (this.alive) {
        this.lastColorsKey = '';
        this.pushColors();
      }
    }, 50);
    setTimeout((): void => {
      if (this.alive) {
        this.lastColorsKey = '';
        this.pushColors();
      }
    }, 150);
  }

  /** 试验性开关（设置页可关）：关闭时回退原版 ArkUI 滑块。必须总开关与组件开关同时开启。 */
  private settingsEnabled(): boolean {
    try {
      return ServiceLocator.settings().isGlassSliderActive();
    } catch (err) {
      return false;
    }
  }

  private glassActive(): boolean {
    return !this.passive && !this.failed && this.settingsEnabled();
  }

  private clearTimers(): void {
    if (this.readyTimer >= 0) {
      clearTimeout(this.readyTimer);
      this.readyTimer = -1;
    }
    if (this.clickTimer >= 0) {
      clearTimeout(this.clickTimer);
      this.clickTimer = -1;
    }
  }

  /** 值 -> 0..1（原生滑块按归一化值驱动）。 */
  private fractionOf(value: number): number {
    const span: number = this.max - this.min;
    if (span <= 0) {
      return 0;
    }
    return Math.max(0, Math.min(1, (value - this.min) / span));
  }

  private configure(): void {
    if (!this.alive) {
      return;
    }
    try {
      GlassGLWidgetConfigure(this.widgetId, GLASS_WIDGET_SLIDER,
        this.getUIContext().vp2px(1));
      this.lastColorsKey = '';   // 原生实例可能重建过：颜色必须重推
      this.pushColors();
      this.pushState(this.value);
    } catch (err) {
      // 原生不可用（极少见）：回退 ArkUI 控件，不打断用户操作
      this.failed = true;
      return;
    }
    if (this.readyTimer >= 0) {
      clearTimeout(this.readyTimer);
      this.readyTimer = -1;
    }
    this.readyAttempt = 0;
    this.readyTimer = setTimeout((): void => {
      this.checkNativeReady();
    }, READY_CHECK_DELAY_MS);
  }

  private checkNativeReady(): void {
    this.readyTimer = -1;
    if (!this.alive) {
      return;
    }
    let running: boolean = false;
    try {
      running = GlassGLWidgetIsRunning(this.widgetId);
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'isRunning failed: %{public}s', JSON.stringify(err));
    }
    if (running) {
      this.pushColors();
      this.pushState(this.value);
      hilog.info(DOMAIN, TAG, 'glass slider ready id=%{public}s', this.widgetId);
      return;
    }
    // 不可见（如未激活页签 / 被覆盖的页面）：surface 本来就不存在，等可见后再查，
    // 不计失败 —— 否则隐藏挂载的控件会误判成"原生不可用"永久回退。
    if (!this.visible) {
      this.readyTimer = setTimeout((): void => {
        this.checkNativeReady();
      }, READY_CHECK_RETRY_MS);
      return;
    }
    this.readyAttempt += 1;
    if (this.readyAttempt < READY_CHECK_MAX_ATTEMPTS) {
      this.readyTimer = setTimeout((): void => {
        this.checkNativeReady();
      }, READY_CHECK_RETRY_MS);
      return;
    }
    hilog.warn(DOMAIN, TAG, 'glass slider not running, fallback id=%{public}s', this.widgetId);
    this.failed = true;
    this.dispose();
  }

  private pushState(value: number): void {
    if (!this.glassActive()) {
      return;
    }
    // 顺带兜底刷新颜色（@Monitor 嵌套路径不触发时的保险，pushColors 内部去重）
    this.pushColors();
    try {
      GlassGLWidgetSetState(this.widgetId, this.fractionOf(value));
    } catch (err) {
      // 原生实例可能刚被释放：静默忽略，UI 侧状态自会回退
    }
  }

  private pushPress(pressed: boolean): void {
    if (!this.glassActive()) {
      return;
    }
    try {
      GlassGLWidgetSetPress(this.widgetId, pressed);
    } catch (err) {
      // 高频路径（每次触摸都会走）：失败只可能是原生实例已释放，静默忽略
    }
  }

  private pushColors(): void {
    if (!this.glassActive()) {
      return;
    }
    const key: string = `${this.theme.primary}|${this.theme.isDark}|${this.onCard}`;
    if (key === this.lastColorsKey) {
      return;
    }
    try {
      const context = this.getUIContext().getHostContext();
      const background: number = resolveColorArgb(context, this.onCard
        ? $r('app.color.secondary_system_background')
        : $r('app.color.system_background'));
      GlassGLWidgetSetColors(this.widgetId, hexToArgb(this.theme.primary), background);
      this.lastColorsKey = key;
    } catch (err) {
      // 同上：颜色推送失败不影响功能
    }
  }

  private dispose(): void {
    try {
      GlassGLWidgetDispose(this.widgetId);
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'dispose failed: %{public}s', JSON.stringify(err));
    }
  }

  /** 轻点轨道的按压反馈：Click 模式没有 Begin/End 配对，补一个短促按压。 */
  private flashPress(): void {
    this.pushPress(true);
    if (this.clickTimer >= 0) {
      clearTimeout(this.clickTimer);
    }
    this.clickTimer = setTimeout((): void => {
      this.clickTimer = -1;
      this.pushPress(false);
    }, CLICK_PRESS_MS);
  }

  /** 覆盖在上层的隐形滑块：手势 / 值由它产生，视觉由 GL 画。 */
  @Builder
  glassLayer() {
    Stack() {
      XComponent({
        id: this.widgetId,
        type: XComponentType.TEXTURE,
        libraryname: 'backdrop',
        controller: this.controller
      })
        .width('100%')
        .height(GLASS_SLIDER_HEIGHT)
        .backgroundColor(Color.Transparent)
        // 禁用态：对齐 ArkUI 滑块的置灰
        .opacity(this.isEnabled ? 1 : 0.4)
        .hitTestBehavior(HitTestMode.None)
        .onAppear((): void => {
          this.configure();
        })
      Slider({
        value: this.value,
        min: this.min,
        max: this.max,
        step: this.step,
        style: SliderStyle.OutSet
      })
        .width('100%')
        .height(GLASS_SLIDER_HEIGHT)
        .opacity(0)
        .enabled(this.isEnabled)
        .selectedColor(this.theme.primary)
        .trackThickness(Spacing.xs)
        .blockSize({ width: Sizes.sliderBlock, height: Sizes.sliderBlock })
        .onChange((value: number, mode: SliderChangeMode): void => {
          this.pushState(value);
          if (mode === SliderChangeMode.Begin || mode === SliderChangeMode.Moving) {
            this.pushPress(true);
          } else if (mode === SliderChangeMode.Click) {
            this.flashPress();
          } else {
            this.pushPress(false);
          }
          this.onChange(value, mode);
        })
    }
    .width('100%')
    .height(GLASS_SLIDER_HEIGHT)
    // 可见性变化：重新可见时补一次配置 / 自检（页签未激活时 surface 不存在，见 checkNativeReady）
    .onVisibleAreaChange([0.0], (isVisible: boolean, _ratio: number): void => {
      this.visible = isVisible;
      if (isVisible) {
        this.configure();
      }
    })
  }

  build() {
    if (this.glassActive()) {
      this.glassLayer()
    } else if (this.passive && this.settingsEnabled()) {
      // 镜像树回退：占位高度必须与玻璃层一致（GLASS_SLIDER_HEIGHT），否则镜像内容变矮
      Row() {
        Slider({
          value: this.value,
          min: this.min,
          max: this.max,
          step: this.step,
          style: SliderStyle.OutSet
        })
          .selectedColor(this.theme.primary)
          .trackThickness(Spacing.xs)
          .blockSize({ width: Sizes.sliderBlock, height: Sizes.sliderBlock })
          .enabled(this.isEnabled)
          .onChange((value: number, mode: SliderChangeMode): void => {
            this.onChange(value, mode);
          })
      }
      .width('100%')
      .height(GLASS_SLIDER_HEIGHT)
    } else {
      Slider({
        value: this.value,
        min: this.min,
        max: this.max,
        step: this.step,
        style: SliderStyle.OutSet
      })
        .selectedColor(this.theme.primary)
        .trackThickness(Spacing.xs)
        .blockSize({ width: Sizes.sliderBlock, height: Sizes.sliderBlock })
        .enabled(this.isEnabled)
        .onChange((value: number, mode: SliderChangeMode): void => {
          this.onChange(value, mode);
        })
    }
  }
}
