/*
 * SPDX-FileCopyrightText: 2026 Liugt
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import { Spacing, Typography, Radius, Sizes, Shadows, Opacity } from '../design/Tokens';
import { Motion } from '../design/Motion';
import { AnimatorResult } from '@kit.ArkUI';
import { ConfirmDialogService } from '../../application/ConfirmDialogService';
import { DialogOrigin, DialogOriginPoint } from './glass/DialogOrigin';
import { SharedMirrorManager, ViewportRect } from '../../features/tabs/SharedMirrorManager';
import { SafeArea } from '../design/SafeArea';
import { ThemeService, ThemeState } from '../../application/theme/ThemeService';
import { ServiceLocator } from '../../application/ServiceLocator';
import { SettingsState } from '../../application/SettingsService';
import { GlassDialogTokens } from '../design/GlassDialogTokens';
import {
  GlassGLDialogConfigure,
  GlassGLDialogSetBackdrop,
  GlassGLDialogSetPress,
  GlassGLDialogSetGeometry,
  GlassGLDialogDispose,
  GlassGLDialogIsReady,
  GlassGLDialogSetBackdropRect,
  GlassGLDialogSetLiveRect,
  GlassGLDialogSetTransform,
  DialogGeometryRect
} from 'backdrop';
import { hilog } from '@kit.PerformanceAnalysisKit';

/** 玻璃首帧就绪轮询：间隔 / 上限（超时直接显示，原生异常时不让弹窗"消失"）。 */
const GLASS_READY_POLL_MS: number = 16;
const GLASS_READY_TIMEOUT_MS: number = 600;
/**
 * 出现 / 消失动效（对齐 iOS 26 的录屏逐帧：60fps 下约 15 帧出现、9 帧消失）：
 * 以触发点为缩放中心，从 0.5 倍长出 —— 缩放中心不在弹窗中心，放大过程自然就是
 * "从触发处移向最终位置"；高阻尼弹簧几乎不回弹。不透明度先于尺寸到位（约 5 帧）。
 * 消失：加速缩回同一中心并随 scrim 一起淡出。
 */
const GLASS_ENTER_SCALE: number = 0.5;
/** 出现弹簧（同 springMotion(0.32, 0.86)，解析解逐帧求值；0.45s 后振幅 < 0.1%）。 */
const GLASS_ENTER_SPRING_RESPONSE: number = 0.32;
const GLASS_ENTER_SPRING_DAMPING: number = 0.86;
const GLASS_ENTER_SPRING_MS: number = 450;
const GLASS_ENTER_FADE_MS: number = 90;
const GLASS_EXIT_SCALE: number = 0.5;
const GLASS_EXIT_MS: number = 160;
const GLASS_EXIT_EASING: string = 'cubic-bezier(0.4, 0.0, 1.0, 1.0)';

/** 欠阻尼弹簧从 0 到 1 的进度（初速 0）：ω0 = 2π / response，ζ = dampingFraction。 */
function glassEnterSpring(tSec: number): number {
  const w0: number = 2 * Math.PI / GLASS_ENTER_SPRING_RESPONSE;
  const z: number = GLASS_ENTER_SPRING_DAMPING;
  const wd: number = w0 * Math.sqrt(1 - z * z);
  const decay: number = Math.exp(-z * w0 * tSec);
  return 1 - decay * (Math.cos(wd * tSec) + (z * w0 / wd) * Math.sin(wd * tSec));
}
/**
 * 背景快照：目标组件与降采样倍率。玻璃面板本身要做 sigma 8dp 的模糊，半分辨率看不出差别，
 * 像素量 / 拷贝 / 上传都降到 1/4（整屏 1280×2832 快照是弹窗"弹得慢"的大头）。
 */
const BACKDROP_SNAPSHOT_ID: string = 'mainNavigation';
const BACKDROP_SNAPSHOT_SCALE: number = 0.5;
/** 实时背景（共享镜像纹理）这么久还没让玻璃就绪，就补一张快照兜底（中枢重建 / 共享上下文失败）。 */
const LIVE_SNAPSHOT_FALLBACK_MS: number = 150;

/**
 * 通用确认弹窗（应用内唯一弹窗形态）：
 * - 经典模式：页面居中的纯色卡片，带圆角与阴影；
 * - 液态玻璃模式：1:1 对齐 HarmonyOSLiquidGlass demo 样式（43dp G2 圆角、透镜折射材质、0.65dp 高光、50dp 胶囊按钮）。
 * 全屏轻微压暗（scrim，覆盖状态栏与导航栏）+ 拦截层，选择前点击不触达下层内容；
 * 所有带按钮的确认/提示统一使用本组件（替代各页内联卡片与系统 showAlertDialog）。
 */
@ComponentV2
export struct ConfirmDialog {
  private static idCounter: number = 0;
  private dialogId: string = `glassDialog_confirm_${++ConfirmDialog.idCounter}`;
  private panelHeightDp: number = 209;
  private cardArea: Area | null = null;
  private btn0Area: Area | null = null;
  private btn1Area: Area | null = null;
  private xcArea: Area | null = null;
  /**
   * 玻璃层（XComponent + 文字层）的缩放 / 不透明度：ArkUI 文字层第一帧就能画出，而 GL 面板
   * 要等 surface 创建 + 快照上传 + 几何同步后才有首帧 —— 首帧就绪前保持透明，就绪后才播出现动效。
   */
  @Local private layerScale: number = GLASS_ENTER_SCALE;
  @Local private layerOpacity: number = 0;
  /** 整个弹窗（含 scrim）的不透明度：消失动效用。 */
  @Local private exitOpacity: number = 1;
  /** 缩放中心（相对全屏玻璃层，vp）：最近一次点击处；没有则屏幕中心。 */
  private pivotX: number | string = '50%';
  private pivotY: number | string = '50%';
  /**
   * 缩放动效逐帧驱动（UI 线程 vsync）：同一个值同帧写给 ArkUI 文字层（scale）与原生玻璃
   * （SetDialogTransform，按变换后的真实位置绘制，折射全程采样真实背景）—— XComponent 本身不缩放。
   */
  private scaleAnimator: AnimatorResult | null = null;
  private entered: boolean = false;
  private readyTimer: number = -1;
  /** 背景走实时镜像（页签根页面 + 玻璃页签在跑）；否则走快照。 */
  private liveBackdrop: boolean = false;
  private snapshotTimer: number = -1;

  /** 品牌色响应源（T24：主题切换经 ThemeState 即时生效）。 */
  private theme: ThemeState = ThemeService.get().state;
  private settings: SettingsState = ServiceLocator.settings().state;
  @Param title: ResourceStr = '';
  @Param body: ResourceStr = '';
  @Param cancelLabel: ResourceStr = '';
  @Param confirmLabel: ResourceStr = '';
  /** 单按钮提示场景置 false（只渲染强调按钮，占满整行）。 */
  @Param showCancel: boolean = true;
  @Param confirmEnabled: boolean = true;
  @Param cancelEnabled: boolean = true;
  /** 卡片内联错误提示（如生物识别验证未通过），null 不渲染。 */
  @Param errorText: ResourceStr | null = null;
  @Event onCancel: () => void = (): void => {
  };
  @Event onConfirm: () => void = (): void => {
  };

  private isGlass(): boolean {
    return this.settings.glassEffects && this.settings.glassDialog;
  }

  aboutToAppear(): void {
    if (this.isGlass()) {
      const origin: DialogOriginPoint | null = DialogOrigin.recent();
      if (origin !== null) {
        this.pivotX = origin.x;
        this.pivotY = origin.y;
      }
      ConfirmDialogService.get().setExitAnimator((done: () => void): void => {
        this.playExit(done);
      });
      try {
        const density = this.getUIContext().vp2px(1);
        GlassGLDialogConfigure(
          this.dialogId,
          this.showCancel ? 2 : 1,
          this.panelHeightDp,
          density,
          this.theme.isDark
        );
        this.startBackdrop();
        this.startReadyPoll();
      } catch (err) {
        this.layerScale = 1;
        this.layerOpacity = 1;
        hilog.error(0x0000, 'ConfirmDialog', 'Dialog configure failed: %{public}s', String(err));
      }
    }
  }

  /** 背景来源：能走实时镜像就占用整屏导出（快照只作兜底），否则直接截快照。 */
  private startBackdrop(): void {
    const mirror: SharedMirrorManager = SharedMirrorManager.getInstance();
    this.liveBackdrop = mirror.canServeLive();
    if (!this.liveBackdrop) {
      this.captureBackdrop();
      return;
    }
    mirror.acquireFullscreen();
    this.snapshotTimer = setTimeout((): void => {
      this.snapshotTimer = -1;
      let ready: boolean = false;
      try {
        ready = GlassGLDialogIsReady(this.dialogId);
      } catch (err) {
        ready = false;
      }
      if (!ready) {
        hilog.warn(0x0000, 'ConfirmDialog', 'live backdrop late, fallback to snapshot');
        this.captureBackdrop();
      }
    }, LIVE_SNAPSHOT_FALLBACK_MS);
  }

  /** 实时背景纹理相对 XComponent surface 的矩形（px）。 */
  private syncLiveRect(): void {
    if (!this.liveBackdrop || this.xcArea === null) {
      return;
    }
    const ui = this.getUIContext();
    const rect: ViewportRect | null = SharedMirrorManager.getInstance().liveRectWindowPx(ui);
    if (rect === null) {
      return;
    }
    try {
      GlassGLDialogSetLiveRect(
        this.dialogId,
        rect.x - ui.vp2px(Number(this.xcArea.globalPosition.x)),
        rect.y - ui.vp2px(Number(this.xcArea.globalPosition.y)),
        rect.width,
        rect.height
      );
    } catch (err) {
      hilog.warn(0x0000, 'ConfirmDialog', 'SetLiveRect failed: %{public}s', String(err));
    }
  }

  private async captureBackdrop(): Promise<void> {
    try {
      const snapshot = this.getUIContext().getComponentSnapshot();
      const pixelMap = await snapshot.get(BACKDROP_SNAPSHOT_ID, { scale: BACKDROP_SNAPSHOT_SCALE });
      const info = pixelMap.getImageInfoSync();
      const byteCount = pixelMap.getPixelBytesNumber();
      const buffer = new ArrayBuffer(byteCount);
      pixelMap.readPixelsToBufferSync(buffer);
      const stride = info.stride > 0 ? info.stride : info.size.width * 4;
      GlassGLDialogSetBackdrop(this.dialogId, buffer, info.size.width, info.size.height, stride);
      pixelMap.release();
    } catch (err) {
      hilog.warn(0x0000, 'ConfirmDialog', 'Snapshot failed: %{public}s', String(err));
    }
  }

  /**
   * 快照目标相对 XComponent surface 的矩形（px）：快照覆盖整窗（含系统栏），XComponent 不一定，
   * 原生按这个矩形摆放快照，玻璃折射 / 模糊的内容才与下层页面逐像素对齐。
   */
  private syncBackdropRect(): void {
    try {
      const utils = this.getUIContext().getComponentUtils();
      const target = utils.getRectangleById(BACKDROP_SNAPSHOT_ID);
      // XComponent 用布局位置（onAreaChange，不含出现动效的缩放）；快照目标不受弹窗变换影响
      if (this.xcArea === null || target.size.width <= 0 || target.size.height <= 0) {
        return;
      }
      const surfaceX: number = this.getUIContext().vp2px(Number(this.xcArea.globalPosition.x));
      const surfaceY: number = this.getUIContext().vp2px(Number(this.xcArea.globalPosition.y));
      GlassGLDialogSetBackdropRect(
        this.dialogId,
        target.windowOffset.x - surfaceX,
        target.windowOffset.y - surfaceY,
        target.size.width,
        target.size.height
      );
    } catch (err) {
      hilog.warn(0x0000, 'ConfirmDialog', 'SetBackdropRect failed: %{public}s', String(err));
    }
  }

  private syncGeometry(): void {
    this.syncBackdropRect();
    this.syncLiveRect();
    if (!this.entered) {
      // 首帧就绪前就按出现动效的起点缩放画好：淡入第一帧玻璃已在 0.5 倍、触发点处
      this.pushTransform(GLASS_ENTER_SCALE);
    }
    if (this.cardArea === null) {
      return;
    }
    const vp2px = (v: number): number => this.getUIContext().vp2px(v);
    const topInsetPx = this.xcArea !== null
      ? vp2px(Number(this.xcArea.globalPosition.y))
      : vp2px(SafeArea.top());
    const leftInsetPx = this.xcArea !== null
      ? vp2px(Number(this.xcArea.globalPosition.x))
      : 0;

    const cardW = vp2px(Number(this.cardArea.width));
    const cardH = vp2px(Number(this.cardArea.height));
    if (cardW <= 0 || cardH <= 0) {
      return;
    }
    const cardX = vp2px(Number(this.cardArea.globalPosition.x)) - leftInsetPx;
    const cardY = vp2px(Number(this.cardArea.globalPosition.y)) - topInsetPx;

    const buttons: DialogGeometryRect[] = [];
    const pushBtn = (area: Area | null): void => {
      if (area !== null) {
        const w = vp2px(Number(area.width));
        const h = vp2px(Number(area.height));
        if (w > 0 && h > 0) {
          buttons.push({
            x: vp2px(Number(area.globalPosition.x)) - leftInsetPx,
            y: vp2px(Number(area.globalPosition.y)) - topInsetPx,
            w: w,
            h: h
          });
        }
      }
    };

    if (this.showCancel) {
      pushBtn(this.btn0Area);
      pushBtn(this.btn1Area);
    } else {
      pushBtn(this.btn0Area);
    }

    try {
      hilog.info(0x0000, 'GLASS', 'syncGeometry dialogId=%{public}s card=[%{public}s] btns=%{public}d topInset=%{public}s',
        this.dialogId, `${cardX.toFixed(1)}, ${cardY.toFixed(1)}, ${cardW.toFixed(1)}, ${cardH.toFixed(1)}`, buttons.length, topInsetPx.toFixed(1));
      GlassGLDialogSetGeometry(
        this.dialogId,
        cardX,
        cardY,
        cardW,
        cardH,
        buttons
      );
    } catch (err) {
      hilog.warn(0x0000, 'ConfirmDialog', 'SetGeometry failed: %{public}s', String(err));
    }
  }

  private startReadyPoll(): void {
    const deadline: number = Date.now() + GLASS_READY_TIMEOUT_MS;
    this.readyTimer = setInterval((): void => {
      let ready: boolean = false;
      try {
        ready = GlassGLDialogIsReady(this.dialogId);
      } catch (err) {
        ready = true;
      }
      if (ready || Date.now() >= deadline) {
        this.stopReadyPoll();
        this.playEnter();
      }
    }, GLASS_READY_POLL_MS);
  }

  private playEnter(): void {
    this.entered = true;
    this.applyScale(GLASS_ENTER_SCALE);
    this.getUIContext().animateTo({ duration: GLASS_ENTER_FADE_MS, curve: Curve.EaseOut }, (): void => {
      this.layerOpacity = 1;
    });
    this.runScale(GLASS_ENTER_SPRING_MS, 'linear', (t: number): number => {
      return t >= 1 ? 1 : GLASS_ENTER_SCALE +
        (1 - GLASS_ENTER_SCALE) * glassEnterSpring(t * GLASS_ENTER_SPRING_MS / 1000);
    });
  }

  private runScale(durationMs: number, easing: string, value: (t: number) => number,
    onDone?: () => void): void {
    this.stopScale();
    const animator: AnimatorResult = this.getUIContext().createAnimator({
      duration: durationMs,
      easing: easing,
      delay: 0,
      fill: 'forwards',
      direction: 'normal',
      iterations: 1,
      begin: 0,
      end: 1
    });
    animator.onFrame = (t: number): void => {
      this.applyScale(value(t));
    };
    animator.onFinish = (): void => {
      this.scaleAnimator = null;
      this.applyScale(value(1));
      if (onDone !== undefined) {
        onDone();
      }
    };
    this.scaleAnimator = animator;
    animator.play();
  }

  private stopScale(): void {
    if (this.scaleAnimator !== null) {
      const animator: AnimatorResult = this.scaleAnimator;
      this.scaleAnimator = null;
      animator.cancel();
    }
  }

  private applyScale(scale: number): void {
    this.layerScale = scale;
    this.pushTransform(scale);
  }

  /** 缩放中心换成 XComponent surface 坐标（px，左上原点）推给原生。 */
  private pushTransform(scale: number): void {
    if (this.xcArea === null) {
      return;
    }
    const ui = this.getUIContext();
    const originX: number = ui.vp2px(Number(this.xcArea.globalPosition.x));
    const originY: number = ui.vp2px(Number(this.xcArea.globalPosition.y));
    const pivotX: number = typeof this.pivotX === 'number' ?
      ui.vp2px(this.pivotX) - originX : ui.vp2px(Number(this.xcArea.width)) / 2;
    const pivotY: number = typeof this.pivotY === 'number' ?
      ui.vp2px(this.pivotY) - originY : ui.vp2px(Number(this.xcArea.height)) / 2;
    try {
      GlassGLDialogSetTransform(this.dialogId, scale, pivotX, pivotY);
    } catch (err) {
      // 旧 .so：玻璃不缩放，只有文字层动效
    }
  }

  /** 服务层 dismiss 的退出钩子：缩回触发点 + 连同 scrim 淡出，播完才真正卸载。 */
  private playExit(done: () => void): void {
    this.stopReadyPoll();
    let finished: boolean = false;
    const finish = (): void => {
      if (!finished) {
        finished = true;
        done();
      }
    };
    // onFinish 在退后台 / 动画被打断时可能不回调：兜底定时，弹窗不能卡在半透明
    setTimeout(finish, GLASS_EXIT_MS + 120);
    const from: number = this.layerScale;
    this.getUIContext().animateTo({ duration: GLASS_EXIT_MS, curve: Curve.EaseIn }, (): void => {
      this.exitOpacity = 0;
    });
    this.runScale(GLASS_EXIT_MS, GLASS_EXIT_EASING, (t: number): number => {
      return from + (GLASS_EXIT_SCALE - from) * t;
    }, finish);
  }

  private stopReadyPoll(): void {
    if (this.readyTimer !== -1) {
      clearInterval(this.readyTimer);
      this.readyTimer = -1;
    }
  }

  aboutToDisappear(): void {
    this.stopReadyPoll();
    this.stopScale();
    if (this.snapshotTimer !== -1) {
      clearTimeout(this.snapshotTimer);
      this.snapshotTimer = -1;
    }
    if (this.liveBackdrop) {
      this.liveBackdrop = false;
      SharedMirrorManager.getInstance().releaseFullscreen();
    }
    if (this.isGlass()) {
      ConfirmDialogService.get().setExitAnimator(null);
      try {
        GlassGLDialogDispose(this.dialogId);
      } catch (err) {
        hilog.error(0x0000, 'ConfirmDialog', 'Dialog dispose failed: %{public}s', String(err));
      }
    }
  }

  build() {
    if (this.isGlass()) {
      this.glassDialogView()
    } else {
      this.classicDialogView()
    }
  }

  @Builder
  private glassDialogView() {
    Stack({ alignContent: Alignment.Center }) {
      // 底层：自渲染液态玻璃 XComponent（暗化全屏背景 + G2 SDF 玻璃卡片 + 胶囊液态玻璃按钮）
      XComponent({
        id: this.dialogId,
        type: XComponentType.TEXTURE,
        libraryname: 'backdrop'
      })
        .width('100%')
        .height('100%')
        .backgroundColor(Color.Transparent)
        .hitTestBehavior(HitTestMode.None)
        .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
        .opacity(this.layerOpacity)
        .onAreaChange((_oldVal: Area, newVal: Area) => {
          this.xcArea = newVal;
          this.syncGeometry();
        })

      // 上层：文字与透明可交互按钮（位置与底层 GLES 精确 1:1 对齐）
      Column() {
        Column() {
          Text(this.title)
            .fontSize(GlassDialogTokens.titleFontSize)
            .lineHeight(Typography.headline.lineHeight)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.theme.isDark ? GlassDialogTokens.titleTextDark : GlassDialogTokens.titleTextLight)
            .width('100%')
            .padding({ left: GlassDialogTokens.paddingHorizontal, right: GlassDialogTokens.paddingHorizontal })
          Text(this.body)
            .fontSize(GlassDialogTokens.bodyFontSize)
            .lineHeight(GlassDialogTokens.bodyLineHeight)
            .fontColor(this.theme.isDark ? GlassDialogTokens.bodyTextDark : GlassDialogTokens.bodyTextLight)
            .margin({ top: GlassDialogTokens.spacingTitleBody })
            .width('100%')
            .padding({ left: GlassDialogTokens.paddingHorizontal, right: GlassDialogTokens.paddingHorizontal })
          if (this.errorText !== null) {
            Text(this.errorText)
              .fontSize(Typography.footnote.size)
              .lineHeight(Typography.footnote.lineHeight)
              .fontColor($r('app.color.danger'))
              .width('100%')
              .margin({ top: Spacing.sm })
              .padding({ left: GlassDialogTokens.paddingHorizontal, right: GlassDialogTokens.paddingHorizontal })
          }
          Row({ space: GlassDialogTokens.spacingBetweenButtons }) {
            if (this.showCancel) {
              Button({ type: ButtonType.Normal }) {
                Text(this.cancelLabel)
                  .fontSize(GlassDialogTokens.buttonFontSize)
                  .fontWeight(FontWeight.Medium)
                  .fontColor(this.theme.isDark ? GlassDialogTokens.secondaryTextDark : GlassDialogTokens.secondaryTextLight)
                  .margin({ top: 2 })
              }
                .layoutWeight(1)
                .height(GlassDialogTokens.buttonHeight)
                .borderRadius(GlassDialogTokens.buttonCornerRadius)
                .clip(true)
                .backgroundColor(Color.Transparent)
                .stateEffect(false)   // 按压视觉由底层玻璃负责（放大 + 棱边高光），不叠系统灰底
                .enabled(this.cancelEnabled)
                .onTouch((event: TouchEvent) => {
                  if (event.type === TouchType.Down) {
                    GlassGLDialogSetPress(this.dialogId, 0, true);
                  } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
                    GlassGLDialogSetPress(this.dialogId, 0, false);
                  }
                })
                .onClick(() => {
                  this.onCancel();
                })
                .onAreaChange((_oldVal: Area, newVal: Area) => {
                  this.btn0Area = newVal;
                  this.syncGeometry();
                })
            }
            Button({ type: ButtonType.Normal }) {
              Text(this.confirmLabel)
                .fontSize(GlassDialogTokens.buttonFontSize)
                .fontWeight(FontWeight.Bold)
                .fontColor(this.theme.primary)
                .margin({ top: 2 })
            }
              .layoutWeight(1)
              .height(GlassDialogTokens.buttonHeight)
              .borderRadius(GlassDialogTokens.buttonCornerRadius)
              .clip(true)
              .backgroundColor(Color.Transparent)
              .stateEffect(false)   // 按压视觉由底层玻璃负责（放大 + 棱边高光），不叠系统灰底
              .enabled(this.confirmEnabled)
              .onTouch((event: TouchEvent) => {
                const btnIdx = this.showCancel ? 1 : 0;
                if (event.type === TouchType.Down) {
                  GlassGLDialogSetPress(this.dialogId, btnIdx, true);
                } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
                  GlassGLDialogSetPress(this.dialogId, btnIdx, false);
                }
              })
              .onClick(() => {
                this.onConfirm();
              })
              .onAreaChange((_oldVal: Area, newVal: Area) => {
                if (this.showCancel) {
                  this.btn1Area = newVal;
                } else {
                  this.btn0Area = newVal;
                }
                this.syncGeometry();
              })
          }
          .width('100%')
          .padding({ left: GlassDialogTokens.paddingLateral, right: GlassDialogTokens.paddingLateral })
          .margin({ top: GlassDialogTokens.spacingBodyButtons })
        }
        .width('100%')
        .constraintSize({ maxWidth: GlassDialogTokens.panelMaxWidth })
        .padding({
          top: GlassDialogTokens.paddingTop,
          bottom: GlassDialogTokens.paddingBottom
        })
        .onAreaChange((_oldVal: Area, newVal: Area) => {
          this.cardArea = newVal;
          this.syncGeometry();
        })
      }
      .width('100%')
      .height('100%')
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
      .padding({ left: 20, right: 20 })
      .opacity(this.layerOpacity)
      .scale({ x: this.layerScale, y: this.layerScale, centerX: this.pivotX, centerY: this.pivotY })
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
      .onClick(() => {
        // 拦截点击
      })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.theme.isDark ? GlassDialogTokens.scrimColorDark : GlassDialogTokens.scrimColor)
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    .onAreaChange((_oldVal: Area, newVal: Area) => {
      if (this.xcArea === null) {
        this.xcArea = newVal;
        this.syncGeometry();
      }
    })
    .opacity(this.exitOpacity)
    .transition(TransitionEffect.opacity(0).animation({ duration: Motion.durationDialog, curve: Motion.curve }))
  }

  @Builder
  private classicDialogView() {
    Column() {
      Column() {
        Text(this.title)
          .fontSize(Typography.headline.size)
          .lineHeight(Typography.headline.lineHeight)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.label'))
          .width('100%')
        Text(this.body)
          .fontSize(Typography.subhead.size)
          .lineHeight(Typography.subhead.lineHeight)
          .fontColor($r('app.color.secondary_label'))
          .margin({ top: Spacing.sm })
          .width('100%')
        if (this.errorText !== null) {
          Text(this.errorText)
            .fontSize(Typography.footnote.size)
            .lineHeight(Typography.footnote.lineHeight)
            .fontColor($r('app.color.danger'))
            .width('100%')
            .margin({ top: Spacing.sm })
        }
        Row({ space: Spacing.md }) {
          if (this.showCancel) {
            Button(this.cancelLabel)
              .type(ButtonType.Normal)
              .layoutWeight(1)
              .height(Sizes.control)
              .borderRadius(Radius.pill(Sizes.control))
              .clip(true)
              .backgroundColor($r('app.color.tertiary_system_background'))
              .fontColor($r('app.color.label'))
              .fontSize(Typography.body.size)
              .fontWeight(FontWeight.Medium)
              .enabled(this.cancelEnabled)
              .onClick(() => {
                this.onCancel();
              })
          }
          Button(this.confirmLabel)
            .type(ButtonType.Normal)
            .layoutWeight(1)
            .height(Sizes.control)
            .borderRadius(Radius.pill(Sizes.control))
            .clip(true)
            .backgroundColor(this.theme.primary)
            .fontColor(this.theme.onPrimary)
            .fontSize(Typography.body.size)
            .fontWeight(FontWeight.Bold)
            .enabled(this.confirmEnabled)
            .onClick(() => {
              this.onConfirm();
            })
        }
        .width('100%')
        .margin({ top: Spacing.xl })
      }
      .width('100%')
      .constraintSize({ maxWidth: 380 })
      .padding(Spacing.xl)
      .borderRadius(Radius.xl)
      .backgroundColor($r('app.color.secondary_system_background'))
      .clip(true)
      .shadow({
        radius: Shadows.dialog.radius,
        color: Shadows.dialog.color,
        offsetY: Shadows.dialog.offsetY
      })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .padding({ left: Spacing.xl, right: Spacing.xl })
    .backgroundColor($r('app.color.scrim'))
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    .onClick(() => {
      // 拦截层
    })
    .transition(TransitionEffect.opacity(0)
      .animation({ duration: Motion.durationDialog, curve: Motion.curve })
      .combine(TransitionEffect.scale({ x: 1.15, y: 1.15 })
        .animation({ duration: Motion.durationDialog, curve: Motion.curve })))
  }
}
