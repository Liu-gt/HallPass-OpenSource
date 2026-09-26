/*
 * SPDX-FileCopyrightText: 2026 Liugt
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import { PageScaffold } from '../../common/design/PageScaffold';
import { ThemeService, ThemeState } from '../../application/theme/ThemeService';
import { Spacing, Typography, Radius, Sizes, Opacity, GroupedList } from '../../common/design/Tokens';
import { Motion } from '../../common/design/Motion';
import { animateToSync } from '../../common/design/Animate';
import { AppGroup } from '../../common/components/AppGroup';
import { GlassToggle } from '../../common/components/glass/GlassToggle';
import { GlassSlider } from '../../common/components/glass/GlassSlider';
import { GeneratorViewModel, GeneratorMode, MIN_LENGTH, MAX_LENGTH, NO_RESULT }
  from './GeneratorViewModel';
import { ServiceLocator } from '../../application/ServiceLocator';
import { GlassBandModel } from '../tabs/GlassBandModel';

/**
 * 生成器页（票 21，spec F11）：类型分段（密码/密语，沉浸光感材质 + 背景透明）+
 * 长度滑条（8–128 步长 1，结果卡上方）+ 结果卡（刷新/复制 touchMin）+ 字符集四开关；
 * 任意参数变化即时重生成；密语模式隐藏长度/字符集卡；全关字符集"—"且复制禁用。
 */
@ComponentV2
export struct GeneratorPage {
  @Consumer('isMirrorContext') isMirrorContext: boolean = false;
  /** 品牌色响应源（T24：主题切换经 ThemeState 即时生效）。 */
  private theme: ThemeState = ThemeService.get().state;
  /**
   * 生成器状态（B 形态）：由 `GlassTabContent` 注入（主树与镜像树同一实例）；
   * 非玻璃路径不传时退回页内自建（默认值），行为与旧版一致。
   */
  @Param viewModel: GeneratorViewModel = new GeneratorViewModel();
  /** 玻璃条带镜像（本页不滚动，仅占位保持签名一致，见 GlassBandModel）。 */
  @Param band: GlassBandModel = new GlassBandModel();
  /** 镜像树标记：只渲染、不跑副作用；内嵌玻璃控件回退静态渲染。 */
  @Param passive: boolean = false;
  @Local private toastText: ResourceStr | null = null;
  private toastTimer: number = -1;
  @Local private segmentWidth: number = 0;
  /** 结果行目标高度（vp；'auto' = 尚未量算，交由布局自适应）。 */
  @Local private resultHeight: Length = 'auto';
  /** 结果文本可用宽度（vp）：换行宽度，决定结果行高度。 */
  private resultTextWidth: number = 0;
  /** 页面 Scroll 的控制器：主树用它上报绝对偏移，镜像树用它 scrollTo。 */
  private pageScroller: Scroller = new Scroller();

  aboutToAppear(): void {
    if (this.passive) {
      // 镜像树挂载首帧跟上主树当前偏移（滚动中进场时不是 0）
      setTimeout((): void => {
        this.applyBandOffset(true);
      }, 0);
      return;
    }
    this.afterRegenerate(this.viewModel.init());
    // 页面（重）建时位置必然在顶部：修正该页签的镜像偏移
    this.band.resetOffset();
  }

  /**
   * 镜像树：把滚动位置对齐到主树（无动画跳转）；夹不掉的回弹由 GlassTabMirror 平移补齐。
   * 滚动跟随走量化（见 `mirrorNeedsReposition`），挂载 / 重新可见时 `force` 无条件对一次。
   */
  private applyBandOffset(force: boolean = false): void {
    if (!this.passive && !this.isMirrorContext) {
      return;
    }
    if (!force && !this.band.mirrorNeedsReposition(this.band.mirrorTargetY())) {
      return;
    }
    this.pageScroller.scrollTo({ xOffset: 0, yOffset: this.band.mirrorTargetY(), animation: false });
  }

  /** 镜像树：上报自己实际落到的偏移（被内容范围夹取后的值）。 */
  private reportMirrorOffset(): void {
    if (!this.passive && !this.isMirrorContext) {
      return;
    }
    this.band.setApplied(this.pageScroller.currentOffset().yOffset);
  }

  /** 主树滚动 → 上报视觉偏移（镜像树的滚动同步源）。镜像树的程序化滚动不回报。 */
  private reportBandOffset(delta: number): void {
    if (this.passive) {
      return;
    }
    this.band.report(delta, this.pageScroller.currentOffset().yOffset);
  }

  @Monitor('band.offsetY')
  private onBandOffsetChange(): void {
    this.applyBandOffset();
  }

  /** 滚动停下后的精确对齐请求（见 GlassBandModel.requestAlign；只有镜像侧会真的滚）。 */
  @Monitor('band.alignEpoch')
  private onAlignRequest(): void {
    this.applyBandOffset(true);
  }

  /**
   * 生成完成后重测结果行高度：结果文本换行行数可能变化，高度走显式动画过渡，
   * 避免整卡高度直接跳变（长度滑条连续调整时尤明显）。
   */
  private afterRegenerate(pending: Promise<void>): void {
    void pending.then((): void => {
      this.syncResultHeight();
    });
  }

  /**
   * 结果行目标高度：按结果文本在当前可用宽度下实测的占用高度换算，
   * 下限为图标热区高度（单行时行高由图标决定）。测算失败时保持现状（不引入错误高度）。
   */
  private syncResultHeight(): void {
    if (this.resultTextWidth <= 0 || this.viewModel.result.length === 0) {
      return;
    }
    const measured: SizeOptions | undefined =
      this.getUIContext().getMeasureUtils().measureTextSize({
        textContent: this.viewModel.result,
        fontSize: Typography.subhead.size,
        fontWeight: Typography.headline.weight,
        lineHeight: Typography.subhead.lineHeight,
        constraintWidth: this.resultTextWidth
      });
    if (measured === undefined || measured.height === undefined) {
      return;
    }
    const pixels: number = parseFloat(`${measured.height}`);
    if (Number.isNaN(pixels)) {
      return;
    }
    this.applyResultHeight(Math.max(this.getUIContext().px2vp(pixels), Sizes.touchMin));
  }

  /**
   * 应用结果行高度：首次接管直接赋值（与自然高度基本一致，无需过渡），
   * 其后用 animateToSync 过渡（结果更新在异步回调里，须同步标脏才不丢动画）。
   */
  private applyResultHeight(target: number): void {
    if (typeof this.resultHeight === 'number' &&
      Math.abs(this.resultHeight - target) < 0.5) {
      return;
    }
    if (this.resultHeight === 'auto') {
      this.resultHeight = target;
      return;
    }
    animateToSync(this.getUIContext(),
      { duration: Motion.durationResultResize, curve: Motion.curve }, (): void => {
        this.resultHeight = target;
      });
  }

  aboutToDisappear(): void {
    if (this.toastTimer !== -1) {
      clearTimeout(this.toastTimer);
      this.toastTimer = -1;
    }
  }

  private showToast(): void {
    this.toastText = $r('app.string.toast_copied');
    if (this.toastTimer !== -1) {
      clearTimeout(this.toastTimer);
    }
    this.toastTimer = setTimeout((): void => {
      this.toastText = null;
      this.toastTimer = -1;
    }, 1800);
  }

  @Builder
  sectionTitle(title: ResourceStr, first: boolean = false) {
    Text(title)
      .fontSize(GroupedList.headerText.size)
      .lineHeight(GroupedList.headerText.lineHeight)
      .fontWeight(FontWeight.Bold)
      .fontColor($r('app.color.secondary_label'))
      .width('100%')
      .padding({ left: GroupedList.headerInset })
      .margin({ top: first ? 0 : GroupedList.sectionGap, bottom: GroupedList.headerGap })
  }

  /** 类型分段（spec F11）：滑动指示条 + 延时曲线动画。
   *  @Builder 按值传参不注册依赖，标签选中态须在 builder 内直接读取 viewModel.mode。 */
  @Builder
  modeSegment() {
    Stack({ alignContent: Alignment.Center }) {
      if (this.segmentWidth > 0) {
        Row()
          .width(this.pillWidth())
          .height(Sizes.control - Spacing.xs * 2)
          .borderRadius(Radius.md - Spacing.xs)
          .backgroundColor(this.theme.primary)
          .translate({
            x: this.viewModel.mode === 'passphrase'
              ? (this.pillWidth() + Spacing.xs) / 2
              : -(this.pillWidth() + Spacing.xs) / 2
          })
          .animation({ duration: 250, curve: Curve.EaseInOut })
      }
      Row({ space: Spacing.xs }) {
        Text($r('app.string.gen_password'))
          .fontSize(Typography.subhead.size)
          .lineHeight(Typography.subhead.lineHeight)
          .fontColor(this.viewModel.mode === 'password' ? this.theme.onPrimary : $r('app.color.label'))
          .animation({ duration: 150, curve: Curve.EaseInOut })
          .textAlign(TextAlign.Center)
          .constraintSize({ minHeight: Sizes.chip })
          .layoutWeight(1)
          // 视觉 32 高（spec 尺寸），热区外扩至 44（T25 无障碍）
          .responseRegion({ x: 0, y: -6, width: '100%', height: Sizes.touchMin })
          .onClick((): void => {
            this.afterRegenerate(this.viewModel.setMode('password'));
          })
        Text($r('app.string.gen_passphrase'))
          .fontSize(Typography.subhead.size)
          .lineHeight(Typography.subhead.lineHeight)
          .fontColor(this.viewModel.mode === 'passphrase' ? this.theme.onPrimary : $r('app.color.label'))
          .animation({ duration: 150, curve: Curve.EaseInOut })
          .textAlign(TextAlign.Center)
          .constraintSize({ minHeight: Sizes.chip })
          .layoutWeight(1)
          .responseRegion({ x: 0, y: -6, width: '100%', height: Sizes.touchMin })
          .onClick((): void => {
            this.afterRegenerate(this.viewModel.setMode('passphrase'));
          })
      }
      .width('100%')
      .height('100%')
    }
    .width('100%')
    .height(Sizes.control)
    .padding(Spacing.xs)
    .borderRadius(Radius.md)
    .backgroundColor(Color.Transparent)
    .backgroundBlurStyle(BlurStyle.COMPONENT_REGULAR)
    .onAreaChange((_oldArea: Area, newArea: Area) => {
      this.segmentWidth = newArea.width as number;
    })
  }

  /** 指示条宽度：容器宽减左右 padding 后对半分（间距由滑动偏移补回）。 */
  private pillWidth(): number {
    return (this.segmentWidth - Spacing.xs * 3) / 2;
  }

  @Builder
  toggleDivider() {
    Divider()
      .color($r('app.color.separator'))
      .strokeWidth(1)
      .opacity(0.5)
      .margin({ left: Spacing.md, right: Spacing.md })
  }

  @Builder
  toggleRow(label: ResourceStr, isOn: boolean, onChange: (enabled: boolean) => void) {
    Row({ space: Spacing.md }) {
      Text(label)
        .fontSize(GroupedList.primaryText.size)
        .lineHeight(GroupedList.primaryText.lineHeight)
        .fontColor($r('app.color.label'))
        .layoutWeight(1)
      // 液态玻璃开关（试验性）：开启后自动替换为 GL 渲染的玻璃开关；镜像树回退静态开关
      GlassToggle({
        isOn: isOn,
        passive: this.passive,
        onChange: (enabled: boolean): void => onChange(enabled)
      })
    }
    .width('100%')
    .constraintSize({ minHeight: GroupedList.rowMinHeight })
    .padding({ left: GroupedList.rowHorizontal, right: GroupedList.rowHorizontal,
      top: GroupedList.rowVertical, bottom: GroupedList.rowVertical })
  }

  build() {
    Stack() {
      PageScaffold({ title: $r('app.string.gen_title') }) {
        Scroll(this.pageScroller) {
          Column() {
            this.sectionTitle($r('app.string.gen_type'), true)
            this.modeSegment()

            if (this.viewModel.mode === 'password') {
              AppGroup({ title: $r('app.string.gen_length') }) {
                Row({ space: Spacing.md }) {
                  Text(`${this.viewModel.length}`)
                    .fontSize(Typography.callout.size)
                    .lineHeight(Typography.callout.lineHeight)
                    .fontWeight(Typography.headline.weight)
                    .fontColor(this.theme.primary)
                    .width(Sizes.touchMin)
                    .textAlign(TextAlign.Center)
                    .contentTransition(new NumericTextTransition({ flipDirection: FlipDirection.UP }))
                  // 液态玻璃滑块（试验性）：开启后自动替换为 GL 渲染的玻璃滑块；镜像树回退静态滑块
                  GlassSlider({
                    value: this.viewModel.length,
                    min: MIN_LENGTH,
                    max: MAX_LENGTH,
                    step: 1,
                    passive: this.passive,
                    onChange: (value: number, mode: SliderChangeMode): void => {
                      // 任意参数变化即时重生成（spec F11 交互流程）
                      this.afterRegenerate(this.viewModel.setLength(value));
                    }
                  })
                    .layoutWeight(1)
                }
                .width('100%')
                .padding({ left: Spacing.xs, right: Spacing.xs, top: Spacing.sm,
                  bottom: Spacing.sm })
              }
            }

            AppGroup({ title: $r('app.string.gen_result'), contentPadding: GroupedList.cardPadding }) {
              Row({ space: Spacing.md }) {
                Text(this.viewModel.result)
                  .fontSize(Typography.subhead.size)
                  .lineHeight(Typography.subhead.lineHeight)
                  .fontWeight(Typography.headline.weight)
                  .fontColor($r('app.color.label'))
                  .layoutWeight(1)
                  .onAreaChange((_oldArea: Area, newArea: Area): void => {
                    // 换行只取决于宽度：仅在宽度变化时重测结果行高度
                    const raw: Length = newArea.width;
                    const width: number = typeof raw === 'number' ? raw : parseFloat(`${raw}`);
                    if (width === this.resultTextWidth) {
                      return;
                    }
                    this.resultTextWidth = width;
                    this.syncResultHeight();
                  })
                Column() {
                  SymbolGlyph($r('sys.symbol.arrow_clockwise'))
                    .fontSize(Sizes.rowIcon)
                    .fontColor([this.theme.primary])
                }
                .width(Sizes.touchMin)
                .height(Sizes.touchMin)
                .justifyContent(FlexAlign.Center)
                .onClick(() => {
                  this.afterRegenerate(this.viewModel.regenerate());
                })
                .accessibilityText($r('app.string.a11y_refresh'))
                Column() {
                  Image($r('sys.media.ohos_ic_public_copy'))
                    .width(Sizes.rowIcon)
                    .height(Sizes.rowIcon)
                    .fillColor(this.theme.primary)
                }
                .width(Sizes.touchMin)
                .height(Sizes.touchMin)
                .justifyContent(FlexAlign.Center)
                .opacity(this.viewModel.canCopy ? 1 : Opacity.disabled)
                .onClick(() => {
                  if (!this.viewModel.canCopy) {
                    return;
                  }
                  this.viewModel.copyResult();
                  this.showToast();
                })
                .accessibilityText($r('app.string.a11y_copy'))
              }
              .width('100%')
              // 结果行高度：量算值变化时走过渡（增/减行不再闪跳）；溢出裁切让增行逐行露出
              .height(this.resultHeight)
              .clip(true)
            }

            if (this.viewModel.mode === 'password') {
              AppGroup({ title: $r('app.string.gen_charset') }) {
                Column() {
                  this.toggleRow($r('app.string.gen_upper'), this.viewModel.upper,
                    (enabled: boolean): void => {
                      this.afterRegenerate(this.viewModel.setCharClass('upper', enabled));
                    })
                  this.toggleDivider()
                  this.toggleRow($r('app.string.gen_lower'), this.viewModel.lower,
                    (enabled: boolean): void => {
                      this.afterRegenerate(this.viewModel.setCharClass('lower', enabled));
                    })
                  this.toggleDivider()
                  this.toggleRow($r('app.string.gen_digits'), this.viewModel.digits,
                    (enabled: boolean): void => {
                      this.afterRegenerate(this.viewModel.setCharClass('digits', enabled));
                    })
                  this.toggleDivider()
                  this.toggleRow($r('app.string.gen_symbols'), this.viewModel.symbols,
                    (enabled: boolean): void => {
                      this.afterRegenerate(this.viewModel.setCharClass('symbols', enabled));
                    })
                }
                .width('100%')
              }
            }
          }
          .width('100%')
          .padding({ left: Spacing.page, right: Spacing.page })
        }
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
        .width('100%')
        .height('100%')
        .align(Alignment.Top)
        // 滚动位移上报：玻璃条带镜像据此同帧跟随（主树上报视觉偏移 + 边界增量；镜像树只回自己的落点）
        .onDidScroll((scrollOffset: number, scrollState: ScrollState) => {
          this.reportBandOffset(scrollOffset)
          this.reportMirrorOffset()
          // 停下时请求一次精确对齐：滚动中量化留下的偏差在这里收敛（见 mirrorNeedsReposition）。
          // 主树侧感知得到 Idle，但只有镜像侧能 scrollTo —— 走模型的信号量转发（对齐由 @Monitor 执行）。
          if (scrollState === ScrollState.Idle) {
            this.band.requestAlign()
          }
        })
        // 挂载 / 重新可见时上报一次（页签切回都靠它对齐镜像）；无条件对一次
        .onAppear(() => {
          this.reportBandOffset(0)
          this.applyBandOffset(true)
        })
      }

      if (this.toastText !== null) {
        Text(this.toastText)
          .fontSize(Typography.footnote.size)
          .lineHeight(Typography.footnote.lineHeight)
          .fontColor(this.theme.onPrimary)
          .padding({ left: Spacing.lg, right: Spacing.lg, top: Spacing.sm, bottom: Spacing.sm })
          .borderRadius(Radius.xs)
          .backgroundColor($r('app.color.secondary_label'))
          .margin({ bottom: Sizes.tabBar + Spacing.xl })
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.system_background'))
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])
    // 镜像布局基准 = 页面盒高度（不是滚动容器高度）：本页标题在滚动内容里，
    // 两者同高；统一用页面盒，镜像原点按"底边对齐屏幕底"反推。
    .onAreaChange((_oldValue: Area, newValue: Area): void => {
      if (!this.passive && !this.isMirrorContext) {
        this.band.reportViewportHeight(Number(newValue.height))
      }
    })
  }
}
