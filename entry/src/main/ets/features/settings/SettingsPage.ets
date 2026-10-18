/*
 * SPDX-FileCopyrightText: 2026 Liugt
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import { PageScaffold } from '../../common/design/PageScaffold';
import { AppCard } from '../../common/components/AppCard';
import { AppGroup } from '../../common/components/AppGroup';
import { Spacing, Typography, Radius, Sizes, GroupedList } from '../../common/design/Tokens';
import { SettingsViewModel, COPYRIGHT_NOTICE } from './SettingsViewModel';
import { ThemeOption } from '../../common/design/AppTheme';
import { BiometricType } from '../../domain/biometric/BiometricCapability';
import { ThemeService, ThemeState, ColorModePreference } from '../../application/theme/ThemeService';
import { ConfirmDialogService } from '../../application/ConfirmDialogService';
import { GlassToggle } from '../../common/components/glass/GlassToggle';
import { ServiceLocator } from '../../application/ServiceLocator';
import { GlassBandModel } from '../tabs/GlassBandModel';
import { AppState } from '../../application/state/AppState';
import { DemoModeManager } from '../../application/demo/DemoModeManager';
// 暂时注释掉赞助/支持作者功能
// import { SponsorDialogService } from './sponsor/SponsorDialogService';
// import { common } from '@kit.AbilityKit';

/**
 * 设置页（票 22，spec F13/F14）：五组卡片（账号/安全/外观/通用/关于），
 * 行规格：最小高 Sizes.touchMin、内距 Spacing.md、值右对齐省略、危险行 danger；
 * 自动锁定/排序 bindMenu；主题单选（色点 + checkmark）；深浅色 3 项；
 * 退出登录二次确认弹窗（Radius.xl）；防截屏开关即时映射窗口隐私标志。
 */

@ComponentV2
export struct SettingsPage {
  @Consumer('isMirrorContext') isMirrorContext: boolean = false;
  /** 品牌色响应源（T24：主题切换经 ThemeState 即时生效）。 */
  private theme: ThemeState = ThemeService.get().state;
  /**
   * 设置状态（B 形态）：由 `GlassTabContent` 注入（主树与镜像树同一实例）；
   * 非玻璃路径不传时退回页内自建（默认值），行为与旧版一致。
   */
  @Param viewModel: SettingsViewModel = new SettingsViewModel();
  /** 玻璃条带镜像：主树上报绝对滚动偏移，镜像树按它 scrollTo（见 GlassBandModel）。 */
  @Param band: GlassBandModel = new GlassBandModel();
  /** 镜像树标记：只渲染、不跑副作用、滚动被动跟随；内嵌玻璃控件回退静态渲染。 */
  @Param passive: boolean = false;
  @Local private toastText: string | null = null;
  private toastTimerId: number = -1;
  /** bindMenu 项须为显式类型属性（ArkTS 禁未类型化对象字面量）。 */
  private autoLockMenu: Array<MenuElement> = [
    { value: $r('app.string.autolock_never'),
      action: (): void => {
        this.viewModel.setAutoLockLevel(0);
      } },
    { value: $r('app.string.autolock_1min'),
      action: (): void => {
        this.viewModel.setAutoLockLevel(1);
      } },
    { value: $r('app.string.autolock_5min'),
      action: (): void => {
        this.viewModel.setAutoLockLevel(2);
      } },
    { value: $r('app.string.autolock_1hour'),
      action: (): void => {
        this.viewModel.setAutoLockLevel(3);
      } }
  ];
  private sortMenu: Array<MenuElement> = [
    { value: $r('app.string.sort_name'),
      action: (): void => {
        this.viewModel.setSort(false);
      } },
    { value: $r('app.string.sort_recent'),
      action: (): void => {
        this.viewModel.setSort(true);
      } }
  ];
  /** 优先使用方式菜单（v1.4，两种方式均支持时展示）。 */
  private preferredMenu: Array<MenuElement> = [
    { value: $r('app.string.biometric_preferred_fingerprint'),
      action: (): void => {
        this.viewModel.setBiometricPreferred('fingerprint');
      } },
    { value: $r('app.string.biometric_preferred_face'),
      action: (): void => {
        this.viewModel.setBiometricPreferred('face');
      } }
  ];

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
    this.viewModel.init();
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

  aboutToDisappear(): void {
    if (this.toastTimerId !== -1) {
      clearTimeout(this.toastTimerId);
      this.toastTimerId = -1;
    }
  }

  /** 复制文本到系统剪贴板并轻提示（开源地址/联系作者邮箱）。 */
  private copyText(text: string): void {
    if (text.length === 0) {
      return;
    }
    ServiceLocator.clipboard().copy(text);
    this.toastText = getContext(this).resourceManager.getStringSync($r('app.string.toast_copied'));
    if (this.toastTimerId !== -1) {
      clearTimeout(this.toastTimerId);
    }
    this.toastTimerId = setTimeout((): void => {
      this.toastText = null;
      this.toastTimerId = -1;
    }, 1800);
  }

  /** 退出登录二次确认：根级弹窗（覆盖页签栏与状态栏，选择前阻断交互）。 */
  private requestSignOut(): void {
    ConfirmDialogService.get().show({
      title: $r('app.string.settings_signout'),
      body: $r('app.string.settings_signout_confirm'),
      cancelLabel: $r('app.string.cancel'),
      confirmLabel: $r('app.string.settings_signout'),
      onCancel: (): void => {
      },
      onConfirm: (): void => {
        this.viewModel.signOut();
      }
    });
  }

  @Builder
  rowDivider() {
    Divider()
      .color($r('app.color.separator'))
      .strokeWidth(1)
      .opacity(0.5)
      .margin({ left: Spacing.md, right: Spacing.md })
  }

  /** 行骨架：标签 + 弹性值（右对齐省略）+ 可选箭头；onTap 非空时整行可点（如点击复制）。 */
  @Builder
  row(label: ResourceStr | string, value: ResourceStr, danger: boolean = false,
    showChevron: boolean = false, onTap: () => void = (): void => {
  }) {
    Row({ space: Spacing.md }) {
      Text(label)
        .fontSize(GroupedList.primaryText.size)
        .lineHeight(GroupedList.primaryText.lineHeight)
        .fontColor(danger ? $r('app.color.danger') : $r('app.color.label'))
        .flexShrink(0)
      Blank()
      if (typeof value === 'string' ? value.length > 0 : true) {
        Text(value)
          .fontSize(GroupedList.secondaryText.size)
          .lineHeight(GroupedList.secondaryText.lineHeight)
          .fontColor($r('app.color.secondary_label'))
          .layoutWeight(1)
          .textAlign(TextAlign.End)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      if (showChevron) {
        SymbolGlyph($r('sys.symbol.chevron_right'))
          .fontSize(GroupedList.chevronText.size)
          .fontWeight(FontWeight.Bold)
          .fontColor([$r('app.color.tertiary_label')])
      }
    }
    .width('100%')
    .constraintSize({ minHeight: GroupedList.rowMinHeight })
    .padding({ left: GroupedList.rowHorizontal, right: GroupedList.rowHorizontal,
      top: GroupedList.rowVertical, bottom: GroupedList.rowVertical })
    .onClick(() => onTap())
  }

  /**
   * 菜单行：bindMenu 只挂右侧"值+箭头"区域；
   * 值经取值闭包在 builder 内求值（@Builder 按值传参不注册依赖，文本不会随状态刷新）。
   */
  @Builder
  menuRow(label: ResourceStr, valueOf: () => ResourceStr, menu: Array<MenuElement>) {
    Row({ space: Spacing.md }) {
      Text(label)
        .fontSize(GroupedList.primaryText.size)
        .lineHeight(GroupedList.primaryText.lineHeight)
        .fontColor($r('app.color.label'))
        .flexShrink(0)
      Blank()
      Row({ space: Spacing.xs }) {
        Text(valueOf())
          .fontSize(GroupedList.secondaryText.size)
          .lineHeight(GroupedList.secondaryText.lineHeight)
          .fontColor($r('app.color.secondary_label'))
          .textAlign(TextAlign.End)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        SymbolGlyph($r('sys.symbol.chevron_right'))
          .fontSize(GroupedList.chevronText.size)
          .fontWeight(FontWeight.Bold)
          .fontColor([$r('app.color.tertiary_label')])
      }
      .bindMenu(menu)
    }
    .width('100%')
    .constraintSize({ minHeight: GroupedList.rowMinHeight })
    .padding({ left: GroupedList.rowHorizontal, right: GroupedList.rowHorizontal,
      top: GroupedList.rowVertical, bottom: GroupedList.rowVertical })
  }

  /** 开关行：标签 + 副标题 + Toggle。isOn/isEnabled 均经取值闭包在 builder 内求值
   *  （@Builder 按值传参不注册依赖，状态变化后行/开关不会刷新——同 menuRow 处理）。
   *  isEnabledOf=false（如总开关"进入应用需解锁"关闭时的生物识别行）：整行禁用并置灰。 */
  @Builder
  toggleRow(label: ResourceStr, hint: ResourceStr, isEnabledOf: () => boolean,
    isOnOf: () => boolean, onChange: (enabled: boolean) => void) {
    Row({ space: Spacing.md }) {
      Column({ space: Spacing.xs }) {
        Text(label)
          .fontSize(GroupedList.primaryText.size)
          .lineHeight(GroupedList.primaryText.lineHeight)
          .fontColor($r('app.color.label'))
          .width('100%')
          .textAlign(TextAlign.Start)
        if (hint !== '') {
          Text(hint)
            .fontSize(Typography.footnote.size)
            .lineHeight(Typography.footnote.lineHeight)
            .fontColor($r('app.color.tertiary_label'))
            .width('100%')
            .textAlign(TextAlign.Start)
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      // 液态玻璃开关（试验性）：开启后自动替换为 GL 渲染的玻璃开关；镜像树回退静态开关
      GlassToggle({
        isOn: isOnOf(),
        isEnabled: isEnabledOf(),
        passive: this.passive,
        onChange: (enabled: boolean): void => onChange(enabled)
      })
    }
    .width('100%')
    .constraintSize({ minHeight: GroupedList.rowMinHeight })
    .padding({ left: GroupedList.rowHorizontal, right: GroupedList.rowHorizontal,
      top: GroupedList.rowVertical, bottom: GroupedList.rowVertical })
    .enabled(isEnabledOf())
    .opacity(isEnabledOf() ? 1 : 0.4)
  }

  private themeLabel(theme: ThemeOption): Resource {
    switch (theme.id) {
      case 'waterlily':
        return $r('app.string.theme_waterlily');
      case 'cathedral':
        return $r('app.string.theme_cathedral');
      case 'rose':
        return $r('app.string.theme_rose');
      case 'haystack':
        return $r('app.string.theme_haystack');
      default:
        return $r('app.string.theme_default');
    }
  }

  /** 主题行：色点（随深浅侧取色）+ 名称 + 选中 checkmark。 */
  @Builder
  themeRow(theme: ThemeOption) {
    Row({ space: Spacing.md }) {
      Column()
        .width(Sizes.themeDot)
        .height(Sizes.themeDot)
        .borderRadius(Radius.pill(Sizes.themeDot))
        .backgroundColor(this.viewModel.isDark ? theme.dark : theme.light)
      Text(this.themeLabel(theme))
        .fontSize(GroupedList.primaryText.size)
        .lineHeight(GroupedList.primaryText.lineHeight)
        .fontColor($r('app.color.label'))
        .layoutWeight(1)
      if (this.viewModel.themeId === theme.id) {
        SymbolGlyph($r('sys.symbol.checkmark'))
          .fontSize(Sizes.rowIcon)
          .fontColor([this.theme.primary])
      }
    }
    .width('100%')
    .constraintSize({ minHeight: GroupedList.rowMinHeight })
    .padding({ left: GroupedList.rowHorizontal, right: GroupedList.rowHorizontal,
      top: GroupedList.rowVertical, bottom: GroupedList.rowVertical })
    .onClick(() => this.viewModel.setTheme(theme.id))
  }

  /** 深浅色单选行。 */
  @Builder
  modeRow(label: ResourceStr, mode: ColorModePreference) {
    Row({ space: Spacing.md }) {
      Text(label)
        .fontSize(GroupedList.primaryText.size)
        .lineHeight(GroupedList.primaryText.lineHeight)
        .fontColor($r('app.color.label'))
        .layoutWeight(1)
      if (this.viewModel.colorMode === mode) {
        SymbolGlyph($r('sys.symbol.checkmark'))
          .fontSize(Sizes.rowIcon)
          .fontColor([this.theme.primary])
      }
    }
    .width('100%')
    .constraintSize({ minHeight: GroupedList.rowMinHeight })
    .padding({ left: GroupedList.rowHorizontal, right: GroupedList.rowHorizontal,
      top: GroupedList.rowVertical, bottom: GroupedList.rowVertical })
    .onClick(() => this.viewModel.setColorMode(mode))
  }

  /*
  @Builder
  sponsorEntryRow() {
    Row({ space: Spacing.md }) {
      Text($r('app.string.settings_sponsor_title'))
        .fontSize(GroupedList.primaryText.size)
        .lineHeight(GroupedList.primaryText.lineHeight)
        .fontColor($r('app.color.label'))
        .flexShrink(0)

      Blank()

      SymbolGlyph($r('sys.symbol.chevron_right'))
        .fontSize(GroupedList.chevronText.size)
        .fontWeight(FontWeight.Bold)
        .fontColor([$r('app.color.tertiary_label')])
        .flexShrink(0)
    }
    .width('100%')
    .constraintSize({ minHeight: GroupedList.rowMinHeight })
    .padding({
      left: GroupedList.rowHorizontal,
      right: GroupedList.rowHorizontal,
      top: GroupedList.rowVertical,
      bottom: GroupedList.rowVertical
    })
    .onClick(() => {
      // 关键安全守卫：镜像树属于离屏渲染节点，严禁响应点击或唤起弹窗
      if (this.passive) {
        return;
      }
      const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
      SponsorDialogService.get().open(ctx);
    })
  }
  */

  build() {
    Stack() {
      PageScaffold({ title: $r('app.string.tab_settings') }) {
        Scroll(this.pageScroller) {
          Column() {
            AppGroup({ title: $r('app.string.settings_account'), first: true }) {
              Column() {
                this.row($r('app.string.settings_account_email'), this.viewModel.email)
                this.rowDivider()
                this.row($r('app.string.settings_server'), this.viewModel.serverUrl)
                this.rowDivider()
                this.row(
                  AppState.get().phase === 'demo' ? $r('app.string.demo_exit_btn') : $r('app.string.settings_signout'),
                  '',
                  true,
                  true,
                  (): void => {
                    if (AppState.get().phase === 'demo') {
                      // 修复 CRIT-v2-02：显式补充 onCancel
                      ConfirmDialogService.get().show({
                        title: $r('app.string.demo_exit_title'),
                        body: $r('app.string.demo_exit_confirm_body'),
                        cancelLabel: $r('app.string.cancel'),
                        confirmLabel: $r('app.string.demo_exit_btn'),
                        onCancel: (): void => {},
                        onConfirm: (): void => {
                          DemoModeManager.get().exitDemoMode();
                        }
                      });
                    } else {
                      this.requestSignOut();
                    }
                  }
                )
              }
              .width('100%')
            }

            AppGroup({ title: $r('app.string.settings_security') }) {
              Column() {
                this.toggleRow($r('app.string.settings_entry_lock'), '',
                  (): boolean => true,
                  (): boolean => this.viewModel.entryLock,
                  (enabled: boolean): void => {
                    this.viewModel.setEntryLock(enabled);
                  })
                if (this.viewModel.fingerprintSupported) {
                  this.rowDivider()
                  this.toggleRow($r('app.string.settings_biometric_fingerprint'), '',
                    (): boolean => this.viewModel.entryLock,
                    (): boolean => this.viewModel.fingerprintEnabled,
                    (enabled: boolean): void => {
                      this.viewModel.setFingerprintUnlock(enabled);
                    })
                }
                if (this.viewModel.faceSupported) {
                  this.rowDivider()
                  this.toggleRow($r('app.string.settings_biometric_face'), '',
                    (): boolean => this.viewModel.entryLock,
                    (): boolean => this.viewModel.faceEnabled,
                    (enabled: boolean): void => {
                      this.viewModel.setFaceUnlock(enabled);
                    })
                }
                if (this.viewModel.fingerprintSupported && this.viewModel.faceSupported) {
                  this.rowDivider()
                  this.menuRow($r('app.string.settings_biometric_preferred'),
                    (): ResourceStr => this.viewModel.preferredBiometric === 'face'
                      ? $r('app.string.biometric_preferred_face')
                      : $r('app.string.biometric_preferred_fingerprint'),
                    this.preferredMenu)
                }
                this.rowDivider()
                this.menuRow($r('app.string.settings_autolock'),
                  (): ResourceStr => this.viewModel.autoLockLevel === 0
                    ? $r('app.string.autolock_never')
                    : (this.viewModel.autoLockLevel === 1
                      ? $r('app.string.autolock_1min')
                      : (this.viewModel.autoLockLevel === 2
                        ? $r('app.string.autolock_5min')
                        : $r('app.string.autolock_1hour'))),
                  this.autoLockMenu)
                this.rowDivider()
                this.row($r('app.string.settings_lock_now'), '', false, true,
                  (): void => this.viewModel.lockNow())
                this.rowDivider()
                this.toggleRow($r('app.string.settings_clipboard'),
                  $r('app.string.settings_clipboard_hint'),
                  (): boolean => true,
                  (): boolean => this.viewModel.clipboardClear,
                  (enabled: boolean): void => {
                    this.viewModel.setClipboardClear(enabled);
                  })
                this.rowDivider()
                this.toggleRow($r('app.string.settings_screenshot'),
                  $r('app.string.settings_screenshot_hint'),
                  (): boolean => true,
                  (): boolean => this.viewModel.blockScreenshot,
                  (enabled: boolean): void => {
                    this.viewModel.setScreenshotBlocked(enabled);
                  })
              }
              .width('100%')
            }

            AppGroup({ title: $r('app.string.settings_appearance') }) {
              Column() {
                ForEach(this.viewModel.themes(), (theme: ThemeOption, index: number) => {
                  if (index > 0) {
                    this.rowDivider()
                  }
                  this.themeRow(theme)
                }, (theme: ThemeOption) => theme.id)
              }
              .width('100%')
            }
            // 模式卡与主题卡间距（spec F13：模式卡间距 Spacing.md）
            Column() {
              AppCard({ contentPadding: 0 }) {
                Column() {
                  this.modeRow($r('app.string.mode_system'), 'system')
                  this.rowDivider()
                  this.modeRow($r('app.string.mode_light'), 'light')
                  this.rowDivider()
                  this.modeRow($r('app.string.mode_dark'), 'dark')
                }
                .width('100%')
              }
            }.margin({ top: Spacing.md })

            AppGroup({ title: $r('app.string.settings_general') }) {
              this.menuRow($r('app.string.settings_sort'),
                (): ResourceStr => this.viewModel.sortRecent
                  ? $r('app.string.sort_recent')
                  : $r('app.string.sort_name'),
                this.sortMenu)
            }

            // 试验性内容：默认全关的功能开关放这里（当前为液态玻璃页签 / 开关 / 滑块）；
            // 风险提示收进标题旁感叹号气泡，不占行内副标题
            AppGroup({
              title: $r('app.string.settings_experimental'),
              hintText: $r('app.string.settings_glass_tab_hint')
            }) {
              Column() {
                this.toggleRow($r('app.string.settings_glass_effects'), '',
                  (): boolean => true,
                  (): boolean => this.viewModel.glassEffects,
                  (enabled: boolean): void => {
                    this.viewModel.setGlassEffects(enabled);
                  })
                this.rowDivider()
                this.toggleRow($r('app.string.settings_glass_tab'), '',
                  (): boolean => this.viewModel.glassEffects,
                  (): boolean => this.viewModel.glassTabBar,
                  (enabled: boolean): void => {
                    this.viewModel.setGlassTabBar(enabled);
                  })
                this.rowDivider()
                this.toggleRow($r('app.string.settings_glass_toggle'), '',
                  (): boolean => this.viewModel.glassEffects,
                  (): boolean => this.viewModel.glassToggle,
                  (enabled: boolean): void => {
                    this.viewModel.setGlassToggle(enabled);
                  })
                this.rowDivider()
                this.toggleRow($r('app.string.settings_glass_slider'), '',
                  (): boolean => this.viewModel.glassEffects,
                  (): boolean => this.viewModel.glassSlider,
                  (enabled: boolean): void => {
                    this.viewModel.setGlassSlider(enabled);
                  })
                this.rowDivider()
                this.toggleRow($r('app.string.settings_glass_dialog'), '',
                  (): boolean => this.viewModel.glassEffects,
                  (): boolean => this.viewModel.glassDialog,
                  (enabled: boolean): void => {
                    this.viewModel.setGlassDialog(enabled);
                  })
              }
              .width('100%')
            }

            AppGroup({ title: $r('app.string.settings_about') }) {
              Column() {
                this.row($r('app.string.settings_version'), this.viewModel.version)
                this.rowDivider()
                this.row($r('app.string.settings_license'), $r('app.string.settings_license_value'))
                this.rowDivider()
                this.row($r('app.string.settings_copyright'), COPYRIGHT_NOTICE)
                this.rowDivider()
                this.row($r('app.string.settings_repo'), this.viewModel.repoUrl(), false, false,
                  (): void => this.copyText(this.viewModel.repoUrl()))
                this.rowDivider()
                this.row($r('app.string.settings_contact'), this.viewModel.contactEmail(), false, false,
                  (): void => this.copyText(this.viewModel.contactEmail()))
                // 暂时注释掉赞助/支持作者功能
                // this.rowDivider()
                // this.sponsorEntryRow()
              }
              .width('100%')
            }

            Column()
              .width('100%')
              .height('30%')
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
        // Scroll 的回调是 (xOffset, yOffset, scrollState)（List 才是 (scrollOffset, scrollState)）：
        // 按 List 的签名写会把恒为 0 的 xOffset 当位移（一帧外推 / 越界增量全丢）、把位移当状态
        .onDidScroll((_xOffset: number, yOffset: number, scrollState: ScrollState) => {
          this.reportBandOffset(yOffset)
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
        this.band.reportViewportHeight(Number(newValue.height), Number(newValue.globalPosition.y))
      }
    })
  }
}
