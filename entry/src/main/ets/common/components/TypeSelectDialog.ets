/*
 * SPDX-FileCopyrightText: 2026 Liugt
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import { KeyCode } from '@kit.InputKit';
import { Spacing, Typography, Radius, Sizes, Shadows, Opacity } from '../design/Tokens';
import { Motion } from '../design/Motion';
import { AnimatorResult } from '@kit.ArkUI';
import { TypeSelectDialogService } from '../../application/TypeSelectDialogService';
import { DialogOrigin, DialogOriginPoint } from './glass/DialogOrigin';
import { SharedMirrorManager, ViewportRect } from '../../features/tabs/SharedMirrorManager';
import { SafeArea } from '../design/SafeArea';
import { ItemType } from '../../domain/model/ItemType';
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

interface TypeOptionItem {
  type: ItemType;
  label: Resource;
  icon: Resource;
  badgeBg: ResourceColor;
}

/**
 * 条目类型选择弹窗：居中卡片、scrim 全屏压暗（含状态栏与底座）；
 * 主标题 "Type" 左对齐，类型选项垂直列表左对齐，带图标徽章与点击态。
 */
@ComponentV2
export struct TypeSelectDialog {
  private static idCounter: number = 0;
  private dialogId: string = `glassDialog_typeSelect_${++TypeSelectDialog.idCounter}`;
  private panelHeightDp: number = 328;
  private cardArea: Area | null = null;
  private btn0Area: Area | null = null;
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

  private theme: ThemeState = ThemeService.get().state;
  private settings: SettingsState = ServiceLocator.settings().state;
  @Param title: ResourceStr = $r('app.string.dialog_type_title');
  @Event onSelect: (type: ItemType) => void = (_type: ItemType): void => {};
  @Event onCancel: () => void = (): void => {};

  private isGlass(): boolean {
    return this.settings.glassEffects && this.settings.glassDialog;
  }

  aboutToAppear(): void {
    // F2-04: 主动清除焦点以收起软键盘，避免弹窗被 IME 遮挡
    try {
      this.getUIContext().getFocusController().clearFocus();
    } catch (_e) {
      // 容错处理
    }
    if (this.isGlass()) {
      const origin: DialogOriginPoint | null = DialogOrigin.recent();
      if (origin !== null) {
        this.pivotX = origin.x;
        this.pivotY = origin.y;
      }
      TypeSelectDialogService.get().setExitAnimator((done: () => void): void => {
        this.playExit(done);
      });
      try {
        const density = this.getUIContext().vp2px(1);
        GlassGLDialogConfigure(
          this.dialogId,
          1,
          this.panelHeightDp,
          density,
          this.theme.isDark
        );
        this.startBackdrop();
        this.startReadyPoll();
      } catch (err) {
        this.layerScale = 1;
        this.layerOpacity = 1;
        hilog.error(0x0000, 'TypeSelectDialog', 'Dialog configure failed: %{public}s', String(err));
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
        hilog.warn(0x0000, 'TypeSelectDialog', 'live backdrop late, fallback to snapshot');
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
      hilog.warn(0x0000, 'TypeSelectDialog', 'SetLiveRect failed: %{public}s', String(err));
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
      hilog.warn(0x0000, 'TypeSelectDialog', 'Snapshot failed: %{public}s', String(err));
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
      hilog.warn(0x0000, 'TypeSelectDialog', 'SetBackdropRect failed: %{public}s', String(err));
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
    if (this.btn0Area !== null) {
      const w = vp2px(Number(this.btn0Area.width));
      const h = vp2px(Number(this.btn0Area.height));
      if (w > 0 && h > 0) {
        buttons.push({
          x: vp2px(Number(this.btn0Area.globalPosition.x)) - leftInsetPx,
          y: vp2px(Number(this.btn0Area.globalPosition.y)) - topInsetPx,
          w: w,
          h: h
        });
      }
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
      hilog.warn(0x0000, 'TypeSelectDialog', 'SetGeometry failed: %{public}s', String(err));
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
      TypeSelectDialogService.get().setExitAnimator(null);
      try {
        GlassGLDialogDispose(this.dialogId);
      } catch (err) {
        hilog.error(0x0000, 'TypeSelectDialog', 'Dialog dispose failed: %{public}s', String(err));
      }
    }
  }

  // F-08: 遵循设计系统规范，使用资源颜色令牌替代硬编码色值
  private readonly options: TypeOptionItem[] = [
    {
      type: ItemType.Login,
      label: $r('app.string.type_login'),
      icon: $r('sys.symbol.person_crop_circle_fill_1'),
      badgeBg: $r('app.color.type_badge_login')
    },
    {
      type: ItemType.Card,
      label: $r('app.string.type_card'),
      icon: $r('sys.symbol.creditcard_fill'),
      badgeBg: $r('app.color.type_badge_card')
    },
    {
      type: ItemType.Identity,
      label: $r('app.string.type_identity'),
      icon: $r('sys.symbol.person_text_rectangle_fill'),
      badgeBg: $r('app.color.type_badge_identity')
    },
    {
      type: ItemType.SecureNote,
      label: $r('app.string.type_note'),
      icon: $r('sys.symbol.doc_text'),
      badgeBg: $r('app.color.type_badge_note')
    }
  ];

  @Builder
  typeRow(item: TypeOptionItem, withDivider: boolean, isFirst: boolean) {
    Column() {
      if (withDivider) {
        Divider()
          .color($r('app.color.separator'))
          .strokeWidth(Sizes.hairline)
          .margin({ left: Spacing.md + Sizes.chip + Spacing.md })
      }
      Row({ space: Spacing.md }) {
        Column() {
          SymbolGlyph(item.icon)
            .fontSize(Sizes.rowIcon)
            .fontColor([$r('app.color.on_tint')])
        }
        .width(Sizes.chip)
        .height(Sizes.chip)
        .borderRadius(Radius.pill(Sizes.chip))
        .backgroundColor(item.badgeBg)
        .justifyContent(FlexAlign.Center)

        Text(item.label)
          .fontSize(Typography.body.size)
          .lineHeight(Typography.body.lineHeight)
          .fontColor($r('app.color.label'))
          .layoutWeight(1)
          .textAlign(TextAlign.Start)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })

        SymbolGlyph($r('sys.symbol.chevron_right'))
          .fontSize(Sizes.chevron)
          .fontColor([$r('app.color.tertiary_label')])
      }
      .width('100%')
      .constraintSize({ minHeight: Sizes.touchMin })
      .padding({ left: Spacing.md, right: Spacing.md, top: Spacing.sm, bottom: Spacing.sm })
      .accessibilityGroup(true)
      .accessibilityText(item.label)
      .accessibilityRole(AccessibilityRoleType.BUTTON)
      .focusable(true)
      .defaultFocus(isFirst) // F2-04: 首项默认获焦，确保外接键盘即时响应 Tab/Enter/Esc
      .stateStyles({
        pressed: {
          .backgroundColor($r('app.color.search_field_secondary'))
        }
      })
      .onClick(() => {
        this.onSelect(item.type);
      })
      .onKeyEvent((event: KeyEvent): boolean => {
        // F2-02: 物理键盘 Enter / Space 触发选中
        if (event.type === KeyType.Down &&
            (event.keyCode === KeyCode.KEYCODE_ENTER || event.keyCode === KeyCode.KEYCODE_SPACE)) {
          this.onSelect(item.type);
          return true;
        }
        return false;
      })
    }
    .width('100%')
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
      // 底层：自渲染液态玻璃 XComponent（SDF 玻璃卡片 + 胶囊液态玻璃按钮）
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

      // 上层：文字、选项列表与胶囊取消按钮
      Column() {
        Column() {
          // 主标题 "Type" 左对齐
          Row() {
            Text(this.title)
              .fontSize(GlassDialogTokens.titleFontSize)
              .lineHeight(Typography.headline.lineHeight)
              .fontWeight(FontWeight.Bold)
              .fontColor(this.theme.isDark ? GlassDialogTokens.titleTextDark : GlassDialogTokens.titleTextLight)
              .textAlign(TextAlign.Start)
          }
          .width('100%')
          .padding({
            left: GlassDialogTokens.paddingHorizontal,
            right: GlassDialogTokens.paddingHorizontal,
            bottom: GlassDialogTokens.spacingTitleBody
          })

          // 约束滚动容器
          Scroll() {
            Column() {
              ForEach(this.options, (item: TypeOptionItem, index: number) => {
                this.typeRow(item, index > 0, index === 0);
              }, (item: TypeOptionItem) => String(item.type))
            }
            .width('100%')
            .borderRadius(18)
            .backgroundColor(this.theme.isDark ? 'rgba(255, 255, 255, 0.08)' : 'rgba(255, 255, 255, 0.40)')
            .border({
              width: 0.45,
              color: this.theme.isDark ? 'rgba(255, 255, 255, 0.12)' : 'rgba(255, 255, 255, 0.25)'
            })
            .clip(true)
          }
          .width('100%')
          .padding({ left: GlassDialogTokens.paddingLateral, right: GlassDialogTokens.paddingLateral })
          .constraintSize({ maxHeight: '55%' })
          .scrollBar(BarState.Off)

          // 胶囊取消按钮（透明上层响应点击与按压变形，底层 GLES 渲染双折射胶囊玻璃）
          Row() {
            Button({ type: ButtonType.Normal }) {
              Text($r('app.string.cancel'))
                .fontColor(this.theme.isDark ? GlassDialogTokens.secondaryTextDark : GlassDialogTokens.secondaryTextLight)
                .fontSize(GlassDialogTokens.buttonFontSize)
                .fontWeight(FontWeight.Medium)
                .margin({ top: 2 })
            }
              .layoutWeight(1)
              .height(GlassDialogTokens.buttonHeight)
              .borderRadius(GlassDialogTokens.buttonCornerRadius)
              .clip(true)
              .backgroundColor(Color.Transparent)
              .stateEffect(false)   // 按压视觉由底层玻璃负责（放大 + 棱边高光），不叠系统灰底
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
          .width('100%')
          .padding({ left: GlassDialogTokens.paddingLateral, right: GlassDialogTokens.paddingLateral })
          .margin({ top: GlassDialogTokens.spacingBodyButtons })
        }
        .width('100%')
        .constraintSize({ maxWidth: GlassDialogTokens.panelMaxWidth, maxHeight: '85%' })
        .padding({
          top: GlassDialogTokens.paddingTop,
          bottom: GlassDialogTokens.paddingBottom
        })
        .onAreaChange((_oldVal: Area, newVal: Area) => {
          this.cardArea = newVal;
          this.syncGeometry();
        })
        .onKeyEvent((event: KeyEvent): boolean => {
          if (event.type === KeyType.Down && event.keyCode === KeyCode.KEYCODE_ESCAPE) {
            this.onCancel();
            return true;
          }
          return false;
        })
        .onClick(() => {
          // 拦截点击
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
        this.onCancel();
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
        Row() {
          Text(this.title)
            .fontSize(Typography.headline.size)
            .lineHeight(Typography.headline.lineHeight)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.label'))
            .textAlign(TextAlign.Start)
        }
        .width('100%')
        .padding({ bottom: Spacing.md })

        Scroll() {
          Column() {
            ForEach(this.options, (item: TypeOptionItem, index: number) => {
              this.typeRow(item, index > 0, index === 0);
            }, (item: TypeOptionItem) => String(item.type))
          }
          .width('100%')
          .borderRadius(Radius.lg)
          .backgroundColor($r('app.color.tertiary_system_background'))
          .clip(true)
        }
        .width('100%')
        .constraintSize({ maxHeight: '55%' })
        .scrollBar(BarState.Off)

        Button($r('app.string.cancel'))
          .type(ButtonType.Normal)
          .width('100%')
          .height(Sizes.control)
          .borderRadius(Radius.pill(Sizes.control))
          .clip(true)
          .backgroundColor($r('app.color.tertiary_system_background'))
          .fontColor($r('app.color.label'))
          .fontSize(Typography.body.size)
          .fontWeight(FontWeight.Medium)
          .margin({ top: Spacing.lg })
          .stateStyles({
            pressed: { .opacity(Opacity.pressed) },
            normal: { .opacity(1.0) }
          })
          .onClick(() => {
            this.onCancel();
          })
      }
      .width('100%')
      .constraintSize({ maxWidth: 380, maxHeight: '85%' })
      .padding(Spacing.xl)
      .borderRadius(Radius.xl)
      .backgroundColor($r('app.color.secondary_system_background'))
      .clip(true)
      .shadow({
        radius: Shadows.dialog.radius,
        color: Shadows.dialog.color,
        offsetY: Shadows.dialog.offsetY
      })
      .onKeyEvent((event: KeyEvent): boolean => {
        if (event.type === KeyType.Down && event.keyCode === KeyCode.KEYCODE_ESCAPE) {
          this.onCancel();
          return true;
        }
        return false;
      })
      .onClick(() => {
        // 拦截点击
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
      this.onCancel();
    })
    .transition(TransitionEffect.opacity(0)
      .animation({ duration: Motion.durationDialog, curve: Motion.curve })
      .combine(TransitionEffect.scale({ x: 1.15, y: 1.15 })
        .animation({ duration: Motion.durationDialog, curve: Motion.curve })))
  }
}
