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
import {
  GLASS_TOGGLE_HEIGHT,
  GLASS_TOGGLE_TRAVEL,
  GLASS_TOGGLE_WIDTH,
  GLASS_WIDGET_TOGGLE,
  hexToArgb,
  nextGlassWidgetId,
  resolveColorArgb
} from './GlassWidgetCommon';

const DOMAIN: number = 0x0000;
const TAG: string = 'HallPassGlassToggle';
/** 原生自检：surface / EGL 起不来就回退 ArkUI 开关（与玻璃页签同一策略）。 */
const READY_CHECK_DELAY_MS: number = 350;
const READY_CHECK_RETRY_MS: number = 700;
const READY_CHECK_MAX_ATTEMPTS: number = 3;
/** 拖拽结束后抑制自带点击的窗口（ms）：两者可能同一帧内先后回调。 */
const DRAG_TAP_GUARD_MS: number = 300;

/**
 * 液态玻璃开关（试验性，设置页「液态玻璃开关」开启后生效）：
 *
 * - 视觉由 backdrop HAR 的 GLES 渲染器画在一个 64×44 的 XComponent 上；
 * - 触摸 / 手势由**覆盖在上层的隐形 ArkUI Toggle** 处理 —— 这样滚动手势、无障碍、
 *   键盘操作与系统控件完全一致，原生只负责画；
 * - 背景是固定的卡片底色（不采样内容快照），所以原生按需渲染：不交互时线程休眠；
 * - 原生不可用 / 功能关闭时，原样回退 ArkUI Toggle。
 */
@ComponentV2
export struct GlassToggle {
  /** 开关状态（父组件是唯一状态源）。 */
  @Param isOn: boolean = false;
  /** 禁用态（整行禁用时与 ArkUI 开关一致：不可点，由父组件负责置灰）。 */
  @Param isEnabled: boolean = true;
  /** 状态变化回链。 */
  @Param onChange: (isOn: boolean) => void = (_isOn: boolean): void => {
  };
  /** 所在容器是否为卡片底色（决定玻璃采样的背景色）。 */
  @Param onCard: boolean = true;
  /** 镜像树（玻璃条带背景导出）里为 true：回退静态 ArkUI 开关，不另起原生控件线程。 */
  @Param passive: boolean = false;

  /** @Local 包装主题状态：@Monitor 只能监听状态变量（嵌套 @Trace 属性可深度监听）。 */
  @Local private theme: ThemeState = ThemeService.get().state;
  /** 原生不可用（surface / EGL 起不来）：回退 ArkUI 开关。 */
  @Local private failed: boolean = false;
  private widgetId: string = nextGlassWidgetId('glassToggle');
  private readyTimer: number = -1;
  private readyAttempt: number = 0;
  private alive: boolean = true;
  /** 可见性（页签未激活 / 页面被覆盖时为 false）：不可见时 surface 本就不存在，自检不算失败。 */
  private visible: boolean = true;
  /** 已推送的颜色组合（主题 / 深浅色 / 容器）：重复推送没有意义，去重。 */
  private lastColorsKey: string = '';
  /** 横向拖拽：按下时的 fraction、当前 fraction、是否正在拖（期间抑制 onTouch 的松手）。 */
  private dragStartFraction: number = 0;
  private dragFraction: number = 0;
  private dragging: boolean = false;
  /** 拖拽结束时刻：用于压掉 Toggle 自带手势紧随其后的那次"点击"。 */
  private dragEndedAt: number = 0;
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
    this.clearReadyTimer();
    this.dispose();
  }

  /** 父组件状态变化 -> 同步给原生（弹簧动画在原生侧跑）。 */
  @Monitor('isOn')
  private onIsOnChange(): void {
    this.pushState();
  }

  /** 禁用时强制松开按压态（避免原生停在按压缩放上）。 */
  @Monitor('isEnabled')
  private onEnabledChange(): void {
    if (!this.isEnabled) {
      this.pushPress(false);
    }
  }

  /** 主题 / 深浅色变化：强调色与背景色都要重推。 */
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

  /** 试验性开关（设置页可关）：关闭时回退原版 ArkUI 开关。必须总开关与组件开关同时开启。 */
  private settingsEnabled(): boolean {
    try {
      return ServiceLocator.settings().isGlassToggleActive();
    } catch (err) {
      return false;
    }
  }

  private glassActive(): boolean {
    return !this.passive && !this.failed && this.settingsEnabled();
  }

  private clearReadyTimer(): void {
    if (this.readyTimer >= 0) {
      clearTimeout(this.readyTimer);
      this.readyTimer = -1;
    }
  }

  /** XComponent 挂载：绑定原生控件实例并推入初始状态 / 颜色。 */
  private configure(): void {
    if (!this.alive) {
      return;
    }
    try {
      GlassGLWidgetConfigure(this.widgetId, GLASS_WIDGET_TOGGLE,
        this.getUIContext().vp2px(1));
      this.lastColorsKey = '';   // 原生实例可能重建过：颜色必须重推
      this.pushColors();
      this.pushState();
    } catch (err) {
      // 原生不可用（极少见）：回退 ArkUI 控件，不打断用户操作
      this.failed = true;
      return;
    }
    this.clearReadyTimer();
    this.readyAttempt = 0;
    this.readyTimer = setTimeout((): void => {
      this.checkNativeReady();
    }, READY_CHECK_DELAY_MS);
  }

  /** 原生自检：渲染线程没起来（老 ROM / EGL 失败）就回退 ArkUI 开关。 */
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
      // 首帧可能早于 configure 的状态推送，这里再补一次，保证状态 / 颜色一定落上
      this.pushColors();
      this.pushState();
      hilog.info(DOMAIN, TAG, 'glass toggle ready id=%{public}s', this.widgetId);
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
    hilog.warn(DOMAIN, TAG, 'glass toggle not running, fallback id=%{public}s', this.widgetId);
    this.failed = true;
    this.dispose();
  }

  private pushState(): void {
    if (!this.glassActive()) {
      return;
    }
    // 顺带兜底刷新颜色：@Monitor 对嵌套路径的监听在个别版本上不触发时，
    // 状态变化也会把主题色 / 背景色带上（pushColors 内部有去重）。
    this.pushColors();
    this.pushStateValue(this.isOn ? 1 : 0);
  }

  /** 直接推状态值（开关 0/1；拖拽过程中推 0..1 的连续 fraction）。 */
  private pushStateValue(value: number): void {
    if (!this.glassActive()) {
      return;
    }
    try {
      GlassGLWidgetSetState(this.widgetId, value);
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

  /** 覆盖在上层的隐形开关：负责手势仲裁 / 无障碍 / 键盘，视觉由 GL 画。 */
  @Builder
  glassLayer() {
    Stack() {
      XComponent({
        id: this.widgetId,
        type: XComponentType.TEXTURE,
        libraryname: 'backdrop',
        controller: this.controller
      })
        .width(GLASS_TOGGLE_WIDTH)
        .height(GLASS_TOGGLE_HEIGHT)
        .backgroundColor(Color.Transparent)
        // 禁用态：对齐 ArkUI 开关的置灰（父组件若已整行置灰会叠乘，与旧观感一致）
        .opacity(this.isEnabled ? 1 : 0.4)
        // 触摸全部交给上层隐形开关（XComponent 不参与命中测试）
        .hitTestBehavior(HitTestMode.None)
        .onAppear((): void => {
          this.configure();
        })
      Toggle({ type: ToggleType.Switch, isOn: this.isOn })
        .width(GLASS_TOGGLE_WIDTH)
        .height(GLASS_TOGGLE_HEIGHT)
        .opacity(0)
        .enabled(this.isEnabled)
        .selectedColor(this.theme.primary)
        .onChange((isOn: boolean): void => {
          // 拖拽期间 / 松手瞬间：Toggle 自带手势可能也识别出一次"点击"，
          // 状态一律以手势回调为准，避免同一次操作被切换两次。
          if (this.dragging || (this.dragEndedAt > 0
            && Date.now() - this.dragEndedAt < DRAG_TAP_GUARD_MS)) {
            return;
          }
          this.onChange(isOn);
        })
        .onTouch((event: TouchEvent): void => {
          if (event.type === TouchType.Down) {
            this.pushPress(true);
          } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
            // 拖拽中不在触摸层松手：松手由手势回调统一处理（避免先落回旧状态再跳新状态）
            if (!this.dragging) {
              this.pushPress(false);
            }
          }
        })
        // 横向拖拽（与 demo 的"拖旋钮切开关"一致）：垂直方向不识别，
        // 纵向滑动仍交给父级 Scroll。⚠️ 必须用 parallelGesture：Toggle 自带点击手势，
        // 普通 gesture 会被它压住（真机实测 pan 回调完全不触发）。
        .parallelGesture(
          PanGesture({ direction: PanDirection.Horizontal })
            .onActionStart((): void => {
              this.dragging = true;
              this.dragStartFraction = this.isOn ? 1 : 0;
              this.dragFraction = this.dragStartFraction;
              this.pushPress(true);
            })
            .onActionUpdate((event: GestureEvent): void => {
              if (!this.dragging) {
                return;
              }
              // 手指位移 / 行程 = fraction 增量（原生旋钮 1:1 跟手）
              const next: number = this.dragStartFraction + event.offsetX / GLASS_TOGGLE_TRAVEL;
              this.dragFraction = Math.max(0, Math.min(1, next));
              this.pushStateValue(this.dragFraction);
            })
            .onActionEnd((): void => {
              if (!this.dragging) {
                return;
              }
              this.dragging = false;
              this.dragEndedAt = Date.now();
              const nextOn: boolean = this.dragFraction >= 0.5;
              // 先直接把最终状态推给原生（onChange 走父组件是异步的，避免落点回弹到旧值）
              this.pushStateValue(nextOn ? 1 : 0);
              this.pushPress(false);
              if (nextOn !== this.isOn) {
                this.onChange(nextOn);
              }
            })
            .onActionCancel((): void => {
              this.dragging = false;
              this.pushPress(false);
              this.pushState();
            })
        )
    }
    .width(GLASS_TOGGLE_WIDTH)
    .height(GLASS_TOGGLE_HEIGHT)
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
      // 镜像树回退：**占位尺寸必须与玻璃层一致**（GLASS_TOGGLE_WIDTH × HEIGHT）。
      // 尺寸不一致会让镜像内容比主树矮一截 → 滚到底时玻璃整体偏移（真机实测 58vp）。
      Row() {
        Toggle({ type: ToggleType.Switch, isOn: this.isOn })
          .selectedColor(this.theme.primary)
          .enabled(this.isEnabled)
          .onChange((isOn: boolean): void => {
            this.onChange(isOn);
          })
      }
      .width(GLASS_TOGGLE_WIDTH)
      .height(GLASS_TOGGLE_HEIGHT)
      .justifyContent(FlexAlign.Center)
    } else {
      Toggle({ type: ToggleType.Switch, isOn: this.isOn })
        .selectedColor(this.theme.primary)
        .enabled(this.isEnabled)
        .onChange((isOn: boolean): void => {
          this.onChange(isOn);
        })
    }
  }
}
