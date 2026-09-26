/*
 * SPDX-FileCopyrightText: 2026 Liugt
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import { AppTheme } from '../../common/design/AppTheme';
import { Motion } from '../../common/design/Motion';
import { ThemeService, ThemeState } from '../../application/theme/ThemeService';
import { ShieldAssets } from './ShieldAssets';

/**
 * 解锁完成盾牌动效（解锁成功进入主页时播放一次，三段式对齐参考视频）：
 * ① 中心弹出：盾牌自屏幕中央由小到大快速弹出（弹簧微回弹），背景保持清晰、无模糊；
 * ② 悬停微增：几近悬停的极缓慢放大，盾牌（含中央竖条）保持清晰；
 * ③ 模糊扩散：进入爆炸式放大时中央竖条与清晰线条一同溶解，盾牌线条经 SVG 高斯模糊融入
 *    内部、化为"外缘强、向内渐浅"的实心渐变盾牌并铺满全屏 → 盾体自铺满起匀速渐隐，直到
 *    全屏渐变与压暗退尽，平滑过渡回清晰背景（不做"一下子就清晰"的陡变）。
 * 盾体 / 竖条 / 融化态均为 security_shield 字形导出的 SVG（ShieldAssets，按主题色预制，
 * 白色带一点主题色渐变，竖条主题色比左右线条更深一档）：线条分层以便竖条单独淡出；
 * 融化态 = 轮廓剪影 + 径向渐变 + feGaussianBlur 线条。弹出/悬停阶段不施加任何模糊，
 * 模糊仅在爆发扩散段渐变出现。
 * 由 Index 在生物识别成功时挂载（登录后引导开启 / 每次生物解锁 / 设置页开启），播完经 onFinished 卸载。
 * 纯装饰覆盖层：不拦截任何交互，登录流程（onboarding→unlocked）不播放。
 */
@ComponentV2
export struct UnlockShieldEffect {
  /** 容器短边（vp，Index 挂载前算好）：据此换算盾牌边长，首帧即按正确尺寸播出 */
  @Param containerShortSide: number = 0;
  /** 播放结束回调（Index 据此卸载覆盖层） */
  @Event onFinished: () => void = (): void => {
  };

  /** 盾牌不透明度（弹出渐显；③ 铺满屏宽后匀速渐隐，直到动效结束） */
  @Local private shieldOpacity: number = 0;
  /** 中央竖条不透明度（弹出/悬停全程常显，③ 爆炸扩散段随线条一同淡出） */
  @Local private barOpacity: number = 1;
  /** 清晰线条不透明度：扩散段前 130ms 内溶解，让位给融化态（弹出/悬停全程清晰、无模糊） */
  @Local private lineOpacity: number = 1;
  /** 融化态不透明度（线条融入内部形成的实心渐变盾牌） */
  @Local private solidOpacity: number = 0;
  /** 盾牌缩放（0.45 弹出 → 0.7 定格 → 0.85 悬停 → 1.31 占满屏宽 → 3.15 全屏 → 3.6 消散） */
  @Local private shieldScale: number = 0.45;
  /** 盾牌内容模糊（③ 起急速增大：清晰轮廓化为渐变，线条消失） */
  @Local private shieldBlur: number = 0;
  /** 全屏渐变的强度（③-3 填充全屏 → ③-4 消散；中心透、边界显色） */
  @Local private washOpacity: number = 0;
  /** 压暗层不透明度（提升浅色背景下玻璃盾的对比） */
  @Local private dimOpacity: number = 0;
  /** 盾牌边长：首帧布局完成后按容器短边换算，保证以正确尺寸入场 */
  @Local private shieldSize: number = 0;
  /** 弹出（弹簧）到悬停段的衔接计时句柄（卸载时清理） */
  private hoverTimer: number = -1;
  /** 当前主题（主题色切换时联动换用对应预制的盾牌 SVG 与全屏渐变色） */
  private theme: ThemeState = ThemeService.get().state;

  /** 盾牌尺寸（正方形边长）占容器短边的比例；与 symbol 同尺寸：SVG 即 1em 见方、图案居中（占 em 宽约 78%） */
  private readonly SHIELD_SIZE_RATIO: number = 0.98;
  /** ① 定格尺寸：图案宽约 0.54 屏宽（对齐视频弹出态）。 */
  private readonly SHIELD_REST_SCALE: number = 0.7;
  /** ② 悬停终点：图案宽约 0.65 屏宽（缓慢变大，几近悬停）。 */
  private readonly SHIELD_HOVER_SCALE: number = 0.85;
  /** ③-1 占满屏宽：图案宽 = 屏宽（此处开始模糊）。 */
  private readonly SHIELD_FILL_SCALE: number = 1.31;
  /** ③-2 全屏铺满：图案高约 1.3 屏高、宽约 2.4 屏宽（四周大幅出界）。 */
  private readonly SHIELD_WASH_SCALE: number = 3.15;
  /** ③-3 消散终点：继续外扩一大截（最大那一刻继续向外冲）。 */
  private readonly SHIELD_DISSOLVE_SCALE: number = 3.6;
  /** ③ 内容模糊阶梯（px）：开始模糊 → 轮廓融化 → 收尾模糊渐退归零（背景随之由虚返实，
   *  避免卸载瞬间"啪"地变清晰）。 */
  private readonly BLUR_FILL: number = 6;
  private readonly BLUR_WASH: number = 16;
  private readonly BLUR_DISSOLVE: number = 0;
  /** 融化态图层外扩倍率（SVG 画布 1600 / em 1000，含模糊余量；按此放大后与线条层逐像素对齐） */
  private readonly SOLID_OVERSCAN: number = 1.6;
  /** 线条层外扩倍率（SVG 画布 1240 / em 1000，为泛光留余量） */
  private readonly LINE_OVERSCAN: number = 1.24;
  /** ③-3 全屏渐变强度峰值 */
  private readonly WASH_PEAK_OPACITY: number = 0.6;
  /** 压暗峰值：在 scrim 色（浅 20% / 深 40% 黑）基础上的不透明度 */
  private readonly DIM_PEAK_OPACITY: number = 0.35;
  /** 全屏渐变：中心透明、边界显色（"化作渐变填充整个屏幕"）；色值按当前主题色的 22% 混白 */
  private washGradient(): RadialGradientOptions {
    return {
      center: ['50%', '50%'],
      radius: '75%',
      colors: [[$r('app.color.system_background_transparent'), 0.0],
        [AppTheme.tint(this.theme.primary, AppTheme.glassLowMix, AppTheme.glassLowAlpha), 1.0]]
    };
  }

  aboutToAppear(): void {
    // 容器短边已知（Index 传入）：首帧布局前即换算尺寸并起播，避免 0 尺寸首帧的定位跳变
    if (this.containerShortSide > 0 && this.shieldSize === 0) {
      this.shieldSize = this.containerShortSide * this.SHIELD_SIZE_RATIO;
      this.play();
    }
  }

  /** ① 弹出：弹簧微回弹，盾牌在屏幕中央快速浮现（背景不动；弹簧无显式时长，按仓库约定计时衔接） */
  private play(): void {
    this.getUIContext().animateTo({ curve: Motion.curveShieldPop }, (): void => {
      this.shieldOpacity = 1;
      this.shieldScale = this.SHIELD_REST_SCALE;
    });
    this.hoverTimer = setTimeout((): void => {
      this.hoverTimer = -1;
      this.hover();
    }, Motion.durationShieldPop);
  }

  /** ② 悬停：极缓慢线性微增（几近定格），随后进入模糊扩散（竖条全程常显） */
  private hover(): void {
    this.getUIContext().animateTo({
      duration: Motion.durationShieldHover,
      curve: Motion.curveLinear,
      onFinish: (): void => {
        this.sweep();
      }
    }, (): void => {
      this.shieldScale = this.SHIELD_HOVER_SCALE;
    });
  }

  /** ③ 模糊扩散：占满屏宽起模糊，线条融入内部化为实心渐变盾牌 → 铺满全屏 → 消散 */
  private sweep(): void {
    // 盾体（模糊巨盾）不透明度：自"铺满屏宽"起匀速渐隐、直到动效结束——
    // "全屏模糊 → 清晰"用一条长而均匀的渐变过渡，避免中途陡降（关键帧只负责缩放/模糊/渐变强度）
    this.getUIContext().animateTo({
      duration: Motion.durationShieldWash + Motion.durationShieldDissolve,
      delay: Motion.durationShieldFill,
      curve: Motion.curveShieldDissolve
    }, (): void => {
      this.shieldOpacity = 0;
    });
    this.getUIContext().keyframeAnimateTo({
      iterations: 1,
      onFinish: (): void => {
        this.onFinished();
      }
    }, [
      {
        duration: Motion.durationShieldFill,
        curve: Motion.curve,
        event: (): void => {
          this.shieldScale = this.SHIELD_FILL_SCALE;
          this.shieldBlur = this.BLUR_FILL;
          this.dimOpacity = this.DIM_PEAK_OPACITY * 0.4;
          // 中央竖条：进入爆炸式放大才开始消失，与线条溶解同步
          this.barOpacity = 0;
          // 线条溶解融入内部：清晰层退场、融化态（SVG 内已高斯模糊）接管
          this.lineOpacity = 0;
          this.solidOpacity = 1;
        }
      },
      {
        duration: Motion.durationShieldWash,
        curve: Motion.curve,
        event: (): void => {
          this.shieldScale = this.SHIELD_WASH_SCALE;
          this.shieldBlur = this.BLUR_WASH;
          this.dimOpacity = this.DIM_PEAK_OPACITY;
          this.washOpacity = this.WASH_PEAK_OPACITY;
        }
      },
      {
        duration: Motion.durationShieldDissolve,
        curve: Motion.curveShieldDissolve,
        event: (): void => {
          this.shieldScale = this.SHIELD_DISSOLVE_SCALE;
          this.shieldBlur = this.BLUR_DISSOLVE;
          this.dimOpacity = 0;
          this.washOpacity = 0;
        }
      }
    ]);
  }

  aboutToDisappear(): void {
    if (this.hoverTimer >= 0) {
      clearTimeout(this.hoverTimer);
      this.hoverTimer = -1;
    }
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      // 压暗层（scrim 色，随动效渐显渐隐）
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor($r('app.color.scrim'))
        .opacity(this.dimOpacity)
        .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
        .hitTestBehavior(HitTestMode.None)

      // 全屏渐变层（中心透明、边界显色；③-3 填充全屏、③-4 消散）
      Column()
        .width('100%')
        .height('100%')
        .radialGradient(this.washGradient())
        .opacity(this.washOpacity)
        .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
        .hitTestBehavior(HitTestMode.None)

      // 玻璃盾（security_shield 字形导出的 SVG，白中带一点主题色；弹出/悬停阶段完全清晰）
      Stack({ alignContent: Alignment.Center }) {
        // 融化态：线条高斯模糊融入内部 + 轮廓剪影径向渐变（外强内浅的实心盾牌）
        Image(ShieldAssets.solid(this.theme.themeId))
          .width(this.shieldSize * this.SOLID_OVERSCAN)
          .height(this.shieldSize * this.SOLID_OVERSCAN)
          .objectFit(ImageFit.Contain)
          .opacity(this.solidOpacity)
          .hitTestBehavior(HitTestMode.None)

        // 盾体：剪影淡填充 + 线条泛光 + 左半盾/右半盾清晰线条（中缝断口保留）
        Image(ShieldAssets.body(this.theme.themeId))
          .width(this.shieldSize * this.LINE_OVERSCAN)
          .height(this.shieldSize * this.LINE_OVERSCAN)
          .objectFit(ImageFit.Contain)
          .opacity(this.lineOpacity)
          .hitTestBehavior(HitTestMode.None)

        // 中央竖条：泛光 + 清晰线条，悬停段先行淡出
        Image(ShieldAssets.bar(this.theme.themeId))
          .width(this.shieldSize * this.LINE_OVERSCAN)
          .height(this.shieldSize * this.LINE_OVERSCAN)
          .objectFit(ImageFit.Contain)
          .opacity(this.barOpacity)
          .hitTestBehavior(HitTestMode.None)
      }
      .blur(this.shieldBlur)
      .opacity(this.shieldOpacity)
      .scale({ x: this.shieldScale, y: this.shieldScale })
      .hitTestBehavior(HitTestMode.None)
    }
    .width('100%')
    .height('100%')
    // 沉浸式覆盖：expandSafeArea 仅作用于组件自身绘制，全屏各层（压暗/渐变/盾牌）已各自声明
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    .hitTestBehavior(HitTestMode.None)
    .onAreaChange((_oldValue: Area, newValue: Area): void => {
      // 首帧布局完成后换算盾牌尺寸并起播（动画从正确尺寸开始，避免入场跳变）
      if (this.shieldSize > 0) {
        return;
      }
      const shortSide: number = Math.min(Number(newValue.width), Number(newValue.height));
      if (shortSide <= 0) {
        return;
      }
      this.shieldSize = shortSide * this.SHIELD_SIZE_RATIO;
      this.play();
    })
  }
}
