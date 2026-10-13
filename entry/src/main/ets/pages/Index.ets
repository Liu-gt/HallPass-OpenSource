/*
 * SPDX-FileCopyrightText: 2026 Liugt
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import { Spacing, Sizes, Radius, Typography } from '../common/design/Tokens';
import { SafeArea } from '../common/design/SafeArea';
import { DemoModeManager } from '../application/demo/DemoModeManager';
import { HdsTabs, HdsTabsController, hdsMaterial } from '@kit.UIDesignKit';
import { HdsMiniBarButton } from 'hds_button';
import { display, window } from '@kit.ArkUI';
import curves from '@ohos.curves';
import { AppState, AppPhase } from '../application/state/AppState';
import { ThemeService, ThemeState } from '../application/theme/ThemeService';
import { ShieldEffectService } from '../application/ShieldEffectService';
import { ConfirmDialogService } from '../application/ConfirmDialogService';
import { ConfirmDialogHost } from '../common/components/ConfirmDialogHost';
import { TypeSelectDialogService } from '../application/TypeSelectDialogService';
import { TypeSelectDialogHost } from '../common/components/TypeSelectDialogHost';
import { OnboardingPage, OnboardingBackInterceptor } from '../features/onboarding/OnboardingPage';
import { UnlockPage } from '../features/unlock/UnlockPage';
import { UnlockShieldEffect } from '../features/unlock/UnlockShieldEffect';
import { VaultPage } from '../features/vault/VaultPage';
import { FastUnlockPrompt } from '../features/vault/FastUnlockPrompt';
import { ItemDetailPage } from '../features/vault/ItemDetailPage';
import { ItemEditPage } from '../features/vault/ItemEditPage';
import { PasswordHistoryPage } from '../features/vault/PasswordHistoryPage';
import { CategoryListPage } from '../features/vault/CategoryListPage';
import { GeneratorPage } from '../features/generator/GeneratorPage';
import { SettingsPage } from '../features/settings/SettingsPage';
import { GlassTabShell, GLASS_STRIP_HEIGHT } from '../features/tabs/GlassTabShell';
import { GLASS_TAB_CONTENT, GlassTabContentModel, HDS_TABS_SUPPORTED } from '../features/tabs/GlassTabContent';
import { SharedMirrorManager } from '../features/tabs/SharedMirrorManager';
import { ServiceLocator } from '../application/ServiceLocator';
// 暂时注释掉赞助/支持作者功能相关引用
// import { common } from '@kit.AbilityKit';
// import { SponsorDialogHost } from '../common/components/SponsorDialogHost';
// import { SponsorDialogService } from '../features/settings/sponsor/SponsorDialogService';
// import { SponsorService } from '../features/settings/sponsor/SponsorService';

/**
 * 全局唯一根页面（plan D1/D2/D9）：AppState 三态根级条件渲染（Onboarding/Unlock 非路由页，
 * 主界面不挂载）+ 根 Navigation(NavigationMode.Stack) 持有唯一 NavPathStack。
 * Home NavDestination 承载三页签壳，作为栈底首页。
 * 路由表见 plan §1.2（ItemDetail/ItemEdit）；push 的 NavDestination 全屏覆盖页签；
 * 路由参数（cipherId / cipherId+type）由票 18/19 经 ViewModel 接线。
 * 页签指示器：仿 HandLED DeviceControlPannel 的浮动胶囊（可拖拽 + 速度形变 + 弹簧回弹）。
 * 液态玻璃页签（B 形态）：内容由 ArkUI 直显（转场 / 触摸 / 滚动全原生），底部条带由 GL
 * 绘制、背景来自一棵 BuilderNode 条带镜像树（0 延迟折射，见 features/tabs/GlassTabShell.ets）。
 */
@Entry
@ComponentV2
struct Index {
  @Provider('navStack') navStack: NavPathStack = new NavPathStack();
  /** 相位响应源（plan D9）。[E2E-01 fix-05] 不再用 @Provider 包装：真机上 @Provider 包装的
   *  @ObservedV2 对象其 @Trace 变化不触发本组件重渲染（后端链路全通而画面不切换的根因），
   *  改为普通属性 + 显式监听器驱动下方 @Local 镜像（全仓无 @Consumer('appState')，零影响面）。 */
  private appState: AppState = AppState.get();
  /** 品牌色响应源（T24：页签图标配色随主题切换重建）。 */
  private theme: ThemeState = ThemeService.get().state;
  /** 盾牌动效触发源（生物识别成功）。 */
  private shieldEffect: ShieldEffectService = ShieldEffectService.get();
  /** 根级条件渲染镜像（fix-05）：@Local 赋值必然触发重渲染，语义与 appState.phase 一致。 */
  @Local uiPhase: AppPhase = AppState.get().phase;
  /** 盾牌动效播放标记：生物识别成功触发（登录后引导开启 / 生物解锁 / 设置页开启），
   *  播完由覆盖层回调复位。 */
  @Local private shieldPlaying: boolean = false;
  /** 根容器短边（vp）：覆盖层挂载前即传入，避免其首帧 0 尺寸导致的定位跳变。 */
  @Local private rootShortSide: number = 0;
  /** 修复 CRIT-v2-03：显式声明 safeTop 成员变量，并接入响应式 */
  @Local private safeTop: number = 0;

  // ===== 浮动指示器（照搬 HandLED DeviceControlPannel，页签底座为 3×86 宽度，锚点使胶囊居中于各槽位）=====
  private readonly BASE_POSITIONS: number[] = [9, 89, 169]
  private readonly BASE_CONTAINER_WIDTH: number = 258
  private readonly BASE_SLOT_WIDTH: number = 86
  private readonly STATIC_PILL_WIDTH: number = 95
  private readonly STATIC_PILL_HEIGHT: number = 61
  private readonly MOVING_PILL_WIDTH: number = 115
  private readonly MOVING_PILL_HEIGHT: number = 81.5
  private readonly MAX_VELOCITY_DEFORM: number = 45
  private readonly VELOCITY_THRESHOLD: number = 0.1
  private readonly VELOCITY_NORMALIZE_BASE: number = 25
  private readonly PAUSE_DURATION_MS: number = 80
  private readonly PAUSE_VELOCITY_THRESHOLD: number = 0.3
  private readonly BAR_HEIGHT: number = 56
  private readonly BAR_BOTTOM_MARGIN: number = Spacing.xl
  // BAR_WIDTH 移除：改用 getBarWidth() 从 rootShortSide 动态计算，与液态玻璃底板宽度对齐
  private readonly PILL_RADIUS: number = 30
  private readonly DRAG_AREA_SIZE: number = 80
  private readonly PILL_Y_OFFSET: number = -8
  private readonly ANCHOR_PROXIMITY_THRESHOLD: number = 28
  private tabTitles: Resource[] = [$r('app.string.tab_vault'), $r('app.string.tab_generator'), $r('app.string.tab_settings')]

  /** 悬浮页签底座宽度（vp）：窄屏手机保证两侧留白自适应收缩，宽屏（折叠屏/平板）钳位锁定在设计基准 258vp 居中。
   *  rootShortSide 为 0 时（首帧、异常）回退 258vp（3 × 86 等分设计基准）。 */
  private getBarWidth(): number {
    if (this.rootShortSide <= 0) {
      return this.BASE_CONTAINER_WIDTH
    }
    return Math.min(this.rootShortSide - 128, this.BASE_CONTAINER_WIDTH)
  }

  @Local curIndex: number = 0
  private tabsController: HdsTabsController = new HdsTabsController()

  /**
   * 液态玻璃页签（GL）是否可用：原生 surface / EGL 起不来时回退现有 ArkUI 页签。
   *
   * 存的是**失败发生时的开关纪元**（-1 = 未失败），而不是布尔粘滞标记：设置页每次
   * 拨动开关纪元都会自增、解锁时这里复位，于是"关掉再开"或"锁屏再解锁"都会重新
   * 尝试玻璃页签（旧实现失败后只能重启进程才恢复，见 glassBarActive）。
   */
  @Local private glassTabFailEpoch: number = -1
  /**
   * 页签壳共享状态（B 形态）：主树（ArkUI 直显）与条带镜像树共用同一份
   * view model / 选中态 / 滚动偏移（见 features/tabs/GlassTabContent.ets）。
   */
  private tabModel: GlassTabContentModel = new GlassTabContentModel()
  /** 前台标记：后台停掉玻璃背景快照定时器（@Entry 的 onPageShow/onPageHide 维护）。 */
  @Local private foreground: boolean = true
  /** Home 是否被子页面覆盖：XComponent 是独立图层，被覆盖时必须隐藏玻璃页签条。 */
  @Local private tabShellCovered: boolean = false

  @Local private indicatorContainerWidth: number = 258
  @Local private currentIndicatorIndex: number = 0
  @Local private dragOffsetX: number = 0
  @Local private isMoving: boolean = false
  /** 基础尺寸：仅由 isMoving 弹簧动画驱动（拖动/回缩的生长期） */
  @Local private baseBarWidth: number = 95
  @Local private baseBarHeight: number = 61
  @Local private velocityDeformationWidth: number = 0
  @Local private velocityDeformationHeight: number = 0
  @Local private isProgrammaticChange: boolean = false
  @Local private displayIndex: number = 0
  @Local private isNearAnchor: boolean = false
  private lastOffsetX: number = 0
  private currentVelocity: number = 0
  private smoothedVelocity: number = 0
  private initialDragDirection: number = 0
  private lastActiveTimestamp: number = 0
  private pauseDetected: boolean = false

  private getAnchorPositions(): number[] {
    const scale: number = this.indicatorContainerWidth / this.BASE_CONTAINER_WIDTH
    const result: number[] = []
    for (let i = 0; i < this.BASE_POSITIONS.length; i++) {
      result[i] = this.BASE_POSITIONS[i] * scale
    }
    return result
  }

  private getAnchorPosition(): number {
    const positions: number[] = this.getAnchorPositions()
    return positions[this.currentIndicatorIndex]
  }

  private getSlotWidth(): number {
    return this.indicatorContainerWidth * (this.BASE_SLOT_WIDTH / this.BASE_CONTAINER_WIDTH)
  }

  /** 胶囊生长/回缩：必须在事件回调里用 animateTo 包裹状态变更
   *  （V2 中 animateTo 在 @Monitor/@Watch 回调内调用不生效，会直接跳变） */
  private growPill(): void {
    this.getUIContext().animateTo({ curve: curves.interpolatingSpring(0, 1, 200, 17) }, () => {
      this.baseBarWidth = this.MOVING_PILL_WIDTH
      this.baseBarHeight = this.MOVING_PILL_HEIGHT
    })
  }

  private shrinkPill(): void {
    this.getUIContext().animateTo({ curve: curves.interpolatingSpring(0, 1, 200, 17) }, () => {
      this.baseBarWidth = this.STATIC_PILL_WIDTH
      this.baseBarHeight = this.STATIC_PILL_HEIGHT
      this.velocityDeformationWidth = 0
      this.velocityDeformationHeight = 0
      this.currentVelocity = 0
      this.smoothedVelocity = 0
      this.displayIndex = this.currentIndicatorIndex
    })
    this.initialDragDirection = 0
    this.lastActiveTimestamp = 0
    this.pauseDetected = false
  }

  /** 实际渲染尺寸 = 弹簧基础尺寸 + 逐帧速度形变（形变连续变化，不覆盖基础弹簧） */
  private get animatedBarWidth(): number {
    return this.baseBarWidth + this.velocityDeformationWidth
  }

  private get animatedBarHeight(): number {
    return this.baseBarHeight + this.velocityDeformationHeight
  }

  private updateVelocityDeformation(velocity: number): void {
    this.currentVelocity = velocity
    const smoothingFactor: number = 0.3
    this.smoothedVelocity = this.smoothedVelocity * (1 - smoothingFactor) + velocity * smoothingFactor
    const absVelocity: number = Math.abs(this.smoothedVelocity)
    const now: number = Date.now()
    if (absVelocity >= this.PAUSE_VELOCITY_THRESHOLD) {
      this.lastActiveTimestamp = now
    }
    if (this.lastActiveTimestamp > 0 && absVelocity < this.PAUSE_VELOCITY_THRESHOLD) {
      const elapsed: number = now - this.lastActiveTimestamp
      if (elapsed >= this.PAUSE_DURATION_MS) {
        this.pauseDetected = true
        this.initialDragDirection = 0
        this.lastActiveTimestamp = 0
      }
    }
    if (absVelocity < this.VELOCITY_THRESHOLD) {
      this.velocityDeformationWidth = 0
      this.velocityDeformationHeight = 0
      return
    }
    if (this.initialDragDirection === 0 || this.pauseDetected) {
      this.initialDragDirection = this.smoothedVelocity > 0 ? 1 : -1
      this.pauseDetected = false
    }
    const normalizedVelocity: number = Math.min(absVelocity / this.VELOCITY_NORMALIZE_BASE, 1)
    const easedVelocity: number = Math.sqrt(normalizedVelocity)
    const deformAmount: number = easedVelocity * this.MAX_VELOCITY_DEFORM
    const currentDirection: number = this.smoothedVelocity > 0 ? 1 : -1
    const isSameDirection: boolean = currentDirection === this.initialDragDirection
    if (isSameDirection) {
      this.velocityDeformationWidth = deformAmount
      this.velocityDeformationHeight = -deformAmount * 0.5
    } else {
      this.velocityDeformationWidth = -deformAmount * 0.5
      this.velocityDeformationHeight = deformAmount
    }
  }

  private checkIfNearAnchor(): void {
    const currentX: number = this.getAnchorPosition() + this.dragOffsetX
    const positions: number[] = this.getAnchorPositions()

    let nearestDistance: number = Infinity
    let nearestIndex: number = this.currentIndicatorIndex

    for (let i = 0; i < positions.length; i++) {
      const distance: number = Math.abs(currentX - positions[i])
      if (distance < nearestDistance) {
        nearestDistance = distance
        nearestIndex = i
      }
    }

    this.isNearAnchor = nearestDistance <= this.ANCHOR_PROXIMITY_THRESHOLD
    this.displayIndex = nearestIndex
  }

  @Monitor('curIndex')
  private onActiveTabChange(_monitor: IMonitor): void {
    // 兜底路径（如非点击触发的 index 变更）；点击已在 tabBuilder 的 onClick 中即时响应
    this.moveIndicatorTo(this.curIndex)
    // 内容树（主树 ArkUI 直显 / 条带镜像树）共用同一份选中态
    this.tabModel.curIndex = this.curIndex
    // 镜像树切页：跟随该页签上次上报的滚动偏移（页面被 ArkUI 保留时位置一致）
    this.tabModel.band.setTab(this.curIndex)
  }

  /** 收尾 timer 句柄：新点击必须取消旧收尾，否则旧 timer 在新动画中途执行 shrinkPill
   *  把胶囊掐断回弹（快速连点"播完上一个再跳"的根因，照搬 HandLED 的 isMoving 状态机语义） */
  private moveSettleTimer: number = -1

  /** 点击页签/页签变更时立即移动指示器：不依赖 HdsTabs onChange（其触发晚于点击，导致视觉延迟） */
  private moveIndicatorTo(index: number): void {
    if (this.isProgrammaticChange || index === this.currentIndicatorIndex) {
      return
    }
    if (this.moveSettleTimer >= 0) {
      clearTimeout(this.moveSettleTimer)
      this.moveSettleTimer = -1
    }
    this.isMoving = true
    if (this.baseBarWidth !== this.MOVING_PILL_WIDTH) {
      this.growPill()
    }
    this.getUIContext().animateTo({ duration: 300, curve: curves.interpolatingSpring(0, 1, 200, 17) }, () => {
      this.currentIndicatorIndex = index
      this.displayIndex = index
      this.dragOffsetX = 0
    })
    this.moveSettleTimer = setTimeout(() => {
      this.moveSettleTimer = -1
      this.isMoving = false
      this.shrinkPill()
    }, 310)
  }

  /** 页签图标（index → app.media SVG 资源，与玻璃页签条同一套形状） */
  private tabIcon(index: number): Resource {
    if (index === 0) {
      return $r('app.media.tab_vault')
    }
    if (index === 1) {
      return $r('app.media.tab_generator')
    }
    return $r('app.media.tab_settings')
  }

  /** 页签未选中色（文字 + 图标）：浅色纯黑 / 深色纯白（与玻璃页签一致，对比度优先）。 */
  private tabUnselectedColor(): ResourceColor {
    return this.theme.isDark ? Color.White : Color.Black
  }

  // 页签槽位（图标 + 文字，委托给 NativeTabItem 响应式渲染选中色）
  @Builder
  tabBuilder(index: number) {
    NativeTabItem({
      index: index,
      tabModel: this.tabModel,
      title: this.tabTitles[index],
      icon: this.tabIcon(index),
      primaryColor: this.theme.primary,
      unselectedColor: this.tabUnselectedColor(),
      isDark: this.theme.isDark,
      onSelect: (idx: number) => {
        this.curIndex = idx
        this.tabModel.curIndex = idx
        this.tabsController.changeIndex(idx)
      }
    })
  }

  // 浮动指示器胶囊（照搬 HandLED：HdsMiniBarButton 沉浸光感 + 速度形变 + 拖拽换页）
  @Builder
  tabIndicator() {
    Column() {
      // 胶囊视觉层
      Row() {
        Stack() {
          HdsMiniBarButton({
            maskColor: $r('app.color.system_background_transparent'),
            barWidth: this.animatedBarWidth,
            barHeight: this.animatedBarHeight,
            materialType: hdsMaterial.MaterialType.IMMERSIVE,
            materialLevel: hdsMaterial.MaterialLevel.EXQUISITE
          }) {
            Column() {
              Image(this.tabIcon(this.displayIndex))
                .width(24.4)
                .height(24.4)
                .objectFit(ImageFit.Contain)
                .fillColor(this.theme.primary)
                .margin({ bottom: 2 })
              Text(this.tabTitles[this.displayIndex])
                .fontSize(9.3)
                .fontColor(this.theme.primary)
                .fontWeight(FontWeight.Bold)
                .maxLines(1)
                .minFontSize(6.7)
                .maxFontSize(9.3)
                .textAlign(TextAlign.Center)
                .padding(2)
                .borderRadius(15)
                .animation({ curve: curves.interpolatingSpring(0, 1, 200, 17) })
            }
            .justifyContent(FlexAlign.Center)
            .alignItems(HorizontalAlign.Center)
            .width('100%')
            .height('100%')
            .borderRadius(this.PILL_RADIUS)
          }

          Row() {
          }
            .width(this.STATIC_PILL_WIDTH)
            .height(this.STATIC_PILL_HEIGHT)
            .borderRadius(this.PILL_RADIUS)
            .backgroundColor($r('app.color.system_background_transparent'))
            .animation({ curve: curves.interpolatingSpring(0, 1, 200, 17) })
        }
        .borderRadius(this.PILL_RADIUS)
        .clip(false)
        .width(this.DRAG_AREA_SIZE)
        .height(this.DRAG_AREA_SIZE)
      }
      .borderRadius(this.PILL_RADIUS)
      .clip(false)
      .translate({ x: this.dragOffsetX })
      .gesture(
        PanGesture({ direction: PanDirection.Horizontal })
          .onActionStart(() => {
            this.isMoving = true
            this.growPill()
            this.lastOffsetX = 0
            this.currentVelocity = 0
            this.smoothedVelocity = 0
            this.displayIndex = this.currentIndicatorIndex
            this.initialDragDirection = 0
            this.lastActiveTimestamp = 0
            this.pauseDetected = false
          })
          .onActionUpdate((event: GestureEvent) => {
            const velocity: number = event.offsetX - this.lastOffsetX
            this.lastOffsetX = event.offsetX
            if (this.isMoving) {
              this.updateVelocityDeformation(velocity)
            }
            // 钳制拖动范围：手势热区（DRAG_AREA_SIZE 宽）不得超出页签底座 [0, BAR_WIDTH]
            const anchor: number = this.getAnchorPosition()
            const minDx: number = -anchor
            const maxDx: number = this.indicatorContainerWidth - this.DRAG_AREA_SIZE - anchor
            if (this.currentIndicatorIndex === 0 && event.offsetX < 0) {
              this.dragOffsetX = event.offsetX * 0.3
            } else if (this.currentIndicatorIndex === this.BASE_POSITIONS.length - 1 && event.offsetX > 0) {
              this.dragOffsetX = event.offsetX * 0.3
            } else {
              this.dragOffsetX = event.offsetX
            }
            this.dragOffsetX = Math.max(minDx, Math.min(maxDx, this.dragOffsetX))
            if (this.isMoving) {
              this.checkIfNearAnchor()
            }
          })
          .onActionEnd(() => {
            const slotWidth: number = this.getSlotWidth()
            const movedSlots: number = Math.round(this.dragOffsetX / slotWidth)
            let newIndex: number = this.currentIndicatorIndex + movedSlots
            newIndex = Math.max(0, Math.min(this.BASE_POSITIONS.length - 1, newIndex))
            if (newIndex !== this.currentIndicatorIndex) {
              this.isProgrammaticChange = true
              if (this.moveSettleTimer >= 0) {
                clearTimeout(this.moveSettleTimer)
              }
              this.getUIContext().animateTo({ duration: 300, curve: curves.interpolatingSpring(0, 1, 200, 17) }, () => {
                this.currentIndicatorIndex = newIndex
                this.displayIndex = newIndex
                this.dragOffsetX = 0
              })
              this.moveSettleTimer = setTimeout(() => {
                this.isMoving = false
                this.isProgrammaticChange = false
                this.moveSettleTimer = -1
                this.tabsController.changeIndex(newIndex)
                this.curIndex = newIndex
                this.shrinkPill()
              }, 310)
            } else {
              this.isMoving = false
              this.shrinkPill()
              this.getUIContext().animateTo({ duration: 200, curve: curves.interpolatingSpring(0, 1, 200, 17) }, () => {
                this.dragOffsetX = 0
              })
            }
          })
      )
      .position({
        x: this.getAnchorPosition(),
        y: this.PILL_Y_OFFSET
      })
      .animation({ curve: curves.interpolatingSpring(0, 1, 200, 17) })
    }
    .width(this.getBarWidth())
    .height(this.BAR_BOTTOM_MARGIN + this.BAR_HEIGHT)
    .clip(false)
    .hitTestBehavior(HitTestMode.Transparent)
    .backgroundColor(Color.Transparent)
    .onAreaChange((_oldValue: Area, newValue: Area) => {
      const newWidth: number = Number(newValue.width)
      if (newWidth > 0 && Math.abs(newWidth - this.indicatorContainerWidth) > 0.5) {
        this.indicatorContainerWidth = newWidth
      }
    })
  }

  /** Home 与各级页面均由同一个 Navigation 管理，支持后续页面间共享元素转场。 */
  @Builder
  PagesMap(name: string, param: object) {
    if (name === 'Home') {
      NavDestination() {
        this.tabShell()
      }
      .hideTitleBar(true)
      .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.BOTTOM])
      // 子页面压栈时隐藏玻璃页签条（XComponent 是独立图层，不随 ArkUI 遮挡关系消失）
      .onHidden(() => {
        this.tabShellCovered = true
      })
      .onShown(() => {
        this.tabShellCovered = false
      })
      // 确认弹窗可见时吞掉返回手势/返回键（视为取消），避免弹窗悬在已弹出的页面上
      .onBackPressed((): boolean => {
        // if (SponsorDialogService.get().handleBack()) {
        //   return true;
        // }
        if (TypeSelectDialogService.get().handleBack()) {
          return true;
        }
        return ConfirmDialogService.get().handleBack();
      })
      .width('100%')
      .height('100%')
      .backgroundColor($r('app.color.system_background'))
    } else if (name === 'ItemDetail') {
      ItemDetailPage()
    } else if (name === 'ItemEdit') {
      ItemEditPage()
    } else if (name === 'CategoryList') {
      CategoryListPage()
    } else if (name === 'PasswordHistory') {
      PasswordHistoryPage()
    }
  }

  @Builder
  vaultTab() {
    VaultPage()
  }

  @Builder
  generatorTab() {
    GeneratorPage()
  }

  @Builder
  settingsTab() {
    SettingsPage()
  }

  /** 玻璃效果总开关（试验性，控制镜像树与各液态玻璃组件）。 */
  private glassEffectsActive(): boolean {
    try {
      return ServiceLocator.settings().isGlassEffectsActive();
    } catch (err) {
      return false; // Consistent with widget fallback on cold start
    }
  }

  /** 玻璃页签是否生效：总开关开启 + 试验性开关（设置页可关）+ 原生自检未在当前纪元失败。 */
  private glassBarActive(): boolean {
    try {
      return ServiceLocator.settings().isGlassTabBarActive() &&
        this.glassTabFailEpoch !== this.glassBarEpoch();
    } catch (err) {
      return false;
    }
  }

  /**
   * 当前开关纪元（设置页每次拨动 `glassTabBar` 自增；解锁走 aboutToAppear 里的失败标记复位）。
   *
   * 必须在构建期读：`glassBarActive` 每次 build 都会读到它，V2 因此登记依赖 ——
   * 纪元一变（拨开关）页签壳就重建，重新尝试玻璃。
   */
  private glassBarEpoch(): number {
    try {
      return ServiceLocator.settings().state.glassTabBarEpoch;
    } catch (err) {
      return 0;
    }
  }

  /**
   * 三页签壳（B 形态）：内容由 ArkUI 直显（主树，唯一可交互实例），底部条带是
   * 玻璃层（GL），其背景由一棵**镜像树**（`BuilderNode` 导出，passive）实时提供。
   *
   * - 玻璃开启且原生可用：`GLASS_TAB_CONTENT` 直显 + `GlassTabShell`（条带）；
   * - 玻璃关闭 / 原生不可用：原版页签（HdsTabs 悬浮光感 + 浮动胶囊指示器 / 普通 Tabs）。
   *
   * 转场 / 触摸 / 滚动全部走 ArkUI 原生路径：push 二级页时主页画面照常参与转场，
   * GL 只影响玻璃条本身（见 docs/glass-live-content-optimization.md）。
   */
  @Builder
  tabShell() {
    Stack({ alignContent: Alignment.Bottom }) {
      if (this.glassBarActive()) {
        // 主树：ArkUI 直显内容（与镜像树共用同一个 model：vm / 选中态 / 滚动偏移）
        GLASS_TAB_CONTENT.builder(this.tabModel)
        GlassTabShell({
          model: this.tabModel,
          selectedIndex: this.curIndex,
          onSelect: (index: number): void => {
            this.curIndex = index
          },
          onUnavailable: (): void => {
            this.glassTabFailEpoch = this.glassBarEpoch()
          },
          foreground: this.foreground,
          visible: !this.tabShellCovered
        })
      } else if (HDS_TABS_SUPPORTED) {
        HdsTabs({ barPosition: BarPosition.End, index: this.curIndex, controller: this.tabsController }) {
          TabContent() {
            this.vaultTab()
          }
          .tabBar(this.tabBuilder(0))

          TabContent() {
            this.generatorTab()
          }
          .tabBar(this.tabBuilder(1))

          TabContent() {
            this.settingsTab()
          }
          .tabBar(this.tabBuilder(2))
        }
        .barHeight(this.BAR_HEIGHT)
        .vertical(false)
        // 内容页瞬时切换
        .animationDuration(0)
        // 与降级分支一致关闭左右翻页：避免吞掉筛选 chips 横向滚动手势
        .scrollable(false)
        .barPosition(BarPosition.End)
        .barOverlap(true)
        .barFloatingStyle({
          barWidth: { smallWidth: this.getBarWidth(), mediumWidth: this.getBarWidth(), largeWidth: this.getBarWidth() },
          barBottomMargin: this.BAR_BOTTOM_MARGIN,
          systemMaterialEffect: {
            materialType: hdsMaterial.MaterialType.ADAPTIVE,
            materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE
          }
        })
        .onChange((index: number) => {
          this.curIndex = index
          this.tabModel.curIndex = index
        })
        .width('100%')
        .height('100%')
      } else {
        Tabs({ index: this.curIndex }) {
          TabContent() {
            this.vaultTab()
          }
          .tabBar(this.tabBuilder(0))

          TabContent() {
            this.generatorTab()
          }
          .tabBar(this.tabBuilder(1))

          TabContent() {
            this.settingsTab()
          }
          .tabBar(this.tabBuilder(2))
        }
        .barHeight(Sizes.tabBar)
        .barPosition(BarPosition.End)
        .scrollable(false)
        .barBackgroundColor($r('app.color.system_background'))
        .onChange((index: number) => {
          this.curIndex = index
          this.tabModel.curIndex = index
        })
        .width('100%')
        .height('100%')
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.system_background'))
  }

  aboutToAppear(): void {
    // 玻璃条带高（vp）：镜像树导出裁剪用；与 GlassTabShell 的条带壳同值
    this.tabModel.bandHeight = GLASS_STRIP_HEIGHT
    // 修复 CRIT-v2-03：初始化顶部安全区高度
    this.safeTop = SafeArea.top();
    // 根容器短边同步预热：优先按应用主窗口实际 Rect（精准兼容分屏、自由悬浮窗），回退按默认屏幕
    try {
      const win = AppStorage.get<window.Window>('mainWindow');
      const uiCtx = this.getUIContext();
      if (win) {
        const rect = win.getWindowProperties().windowRect;
        const winShort = Math.min(uiCtx.px2vp(rect.width), uiCtx.px2vp(rect.height));
        if (winShort > 0) {
          this.rootShortSide = winShort;
        }
      } else {
        const disp = display.getDefaultDisplaySync();
        const dispShort = Math.min(uiCtx.px2vp(disp.width), uiCtx.px2vp(disp.height));
        if (dispShort > 0) {
          this.rootShortSide = dispShort;
        }
      }
    } catch (_err) {
      // 异常时维持 0，由挂载后的 onAreaChange 动态填充
    }
    // F-08: 冷启动非阻塞静默补发漏单（赞助功能暂时注释）
    /*
    try {
      const hostContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
      if (hostContext) {
        SponsorService.get().recoverUnfinishedPurchases(hostContext);
      }
    } catch (_e) {
      // 静默兜底，不干扰主线程启动
    }
    */
    // 仅初始化空栈；锁定/解锁重建 Navigation 时保留 Home 及其上方页面。
    if (this.navStack.size() === 0) {
      this.navStack.pushPath({ name: 'Home' }, false);
    }
    this.appState.addPhaseListener((phase: AppPhase): void => {
      // 相位迁移（锁定/登出/体验）强制收起根级确认弹窗与赞助弹窗：回调闭包属旧页面，解锁后不可复现
      // SponsorDialogService.get().dismiss();
      ConfirmDialogService.get().dismiss();
      TypeSelectDialogService.get().dismiss();
      if (phase === 'onboarding' || phase === 'demo') {
        // 修复 HIGH-01：重置 ViewModel 缓存
        this.tabModel.resetViewModels();
        // 退出登录/进入体验（登出即回向导）：页面状态还原——页签回"保管库"、路由栈回 Home、覆盖层复位，
        // 避免下次登录后仍停在上次所在的页签/子页面（锁定→解锁保留页面栈，登出不保留）
        this.tabsController.changeIndex(0);
        this.curIndex = 0;
        this.tabModel.band.reset();
        this.tabShellCovered = false;
        this.shieldPlaying = false;
        this.navStack.clear();
        this.navStack.pushPath({ name: 'Home' }, false);
      } else if (phase === 'locked') {
        this.shieldPlaying = false;
      } else if (phase === 'unlocked') {
        // 解锁后重试玻璃页签：上次失败可能只是启动期瞬时问题（surface / 内容纹理时序），
        // 不该拖到下次冷启动才恢复（失败标记见 glassTabFailEpoch）
        this.glassTabFailEpoch = -1;
      }
      this.uiPhase = phase;
    });
    // 盾牌动效：仅生物识别成功节点触发（见 ShieldEffectService），相位迁移本身不播放
    this.shieldEffect.addListener((): void => {
      this.shieldPlaying = true;
    });
  }

  /** 返回手势/返回键：确认弹窗优先消费，其次向导与解锁前的子流程，未被拦截则交给系统。 */
  onBackPress(): boolean {
    // if (SponsorDialogService.get().handleBack()) {
    //   return true;
    // }
    if (TypeSelectDialogService.get().handleBack()) {
      return true;
    }
    if (ConfirmDialogService.get().handleBack()) {
      return true;
    }
    // 处于体验模式且在主页根层级（navStack 深度 <= 1）时，拦截并拉起退出体验模式确认弹窗
    if (this.uiPhase === 'demo' && this.navStack.size() <= 1) {
      this.requestExitDemo();
      return true;
    }
    return OnboardingBackInterceptor.handle();
  }

  /**
   * 修复 CRIT-v2-02：显式提供 onCancel: (): void => {} 严格满足 ConfirmDialogRequest 强类型契约
   */
  private requestExitDemo(): void {
    ConfirmDialogService.get().show({
      title: $r('app.string.demo_exit_title'),
      body: $r('app.string.demo_exit_confirm_body'),
      cancelLabel: $r('app.string.cancel'),
      confirmLabel: $r('app.string.demo_exit_btn'),
      onCancel: (): void => {}, // 必填强类型字段
      onConfirm: (): void => {
        DemoModeManager.get().exitDemoMode();
      }
    });
  }

  onPageShow(): void {
    this.foreground = true;
  }

  onPageHide(): void {
    this.foreground = false;
  }

  @Builder
  private mainContentStack() {
    Stack({ alignContent: Alignment.Top }) {
      Navigation(this.navStack)
      .mode(NavigationMode.Stack)
      .hideNavBar(true)
      .hideTitleBar(true)
      .navDestination(this.PagesMap)
      .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.BOTTOM])
      .width('100%')
      .height('100%')
      .backgroundColor($r('app.color.system_background'))

      // === 修复 LOW-v2-01 & CRIT-v2-03：体验模式全局自适应悬浮指示胶囊 ===
      if (this.uiPhase === 'demo') {
        Row({ space: Spacing.xs }) {
          SymbolGlyph($r('sys.symbol.star_animation'))
            .fontSize(14)
            .fontColor([this.theme.isDark ? '#FFD580' : '#B25E00'])
          Text($r('app.string.demo_banner_title'))
            .fontSize(Typography.footnote.size)
            .fontColor(this.theme.isDark ? '#FFD580' : '#B25E00')
            .fontWeight(FontWeight.Medium)
          
          Text('|')
            .fontSize(Typography.footnote.size)
            .fontColor(this.theme.isDark ? '#8A6D3B' : '#D4A373')
            .margin({ left: Spacing.xs, right: Spacing.xs })

          Text($r('app.string.demo_exit_btn'))
            .fontSize(Typography.footnote.size)
            .fontColor($r('app.color.danger'))
            .fontWeight(FontWeight.Bold)
            .onClick((): void => {
              this.requestExitDemo();
            })
        }
        .padding({ left: Spacing.md, right: Spacing.md, top: Spacing.xs, bottom: Spacing.xs })
        .borderRadius(Radius.pill(28))
        .backgroundColor(this.theme.isDark ? '#2C2600' : '#FFF8E7')
        .borderWidth(1)
        .borderColor(this.theme.isDark ? '#6B5200' : '#FFE0A3')
        .shadow(ShadowStyle.OUTER_DEFAULT_XS)
        .margin({ top: this.safeTop + 8 }) // 安全区适配
        .hitTestBehavior(HitTestMode.Default)
      }

      // 通用确认弹窗（根级模态：覆盖页签栏与状态栏，选择前阻断所有交互）
      ConfirmDialogHost()

      // 条目类型选择弹窗（根级模态：覆盖页签栏与状态栏，选择前阻断交互）
      TypeSelectDialogHost()

      // 登录后快速解锁开启确认（根级模态：覆盖页签栏与所有页面，选择前阻断交互）
      FastUnlockPrompt()

      // 支持作者赞助弹窗（根级模态宿主：暂时注释）
      // SponsorDialogHost()

      // 解锁完成盾牌动效（最顶层覆盖：播放期间不拦截交互，播完自卸载）
      if (this.shieldPlaying) {
        UnlockShieldEffect({
          containerShortSide: this.rootShortSide,
          onFinished: (): void => {
            this.shieldPlaying = false;
          }
        })
      }
    }
    .width('100%')
    .height('100%')
  }

  build() {
    Stack() {
      if (this.uiPhase === 'onboarding') {
        OnboardingPage()
      } else if (this.uiPhase === 'locked') {
        UnlockPage()
      } else {
        MirrorHost({ tabModel: this.tabModel }) {
          this.mainContentStack()
        }
      }
    }
    .width('100%')
    .height('100%')
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    .onAreaChange((_oldValue: Area, newValue: Area): void => {
      const shortSide: number = Math.min(Number(newValue.width), Number(newValue.height));
      if (shortSide > 0) {
        this.rootShortSide = shortSide;
      }
    })
  }
}


@ComponentV2
export struct MirrorHost {
  @Require @Param tabModel: GlassTabContentModel;
  @Local manager: SharedMirrorManager = SharedMirrorManager.getInstance();
  @BuilderParam MainContent: () => void;

  private isMirrorActive(): boolean {
    try {
      return ServiceLocator.settings().isGlassEffectsActive();
    } catch (err) {
      return false;
    }
  }

  build() {
    Stack() {
      // 只有总开关开启时，才挂载 NodeContainer 镜像导出层；关闭时完全卸载 NodeContainer
      if (this.isMirrorActive()) {
        Row() {
          NodeContainer(this.manager.controller)
            .hitTestBehavior(HitTestMode.None)
        }
        .hitTestBehavior(HitTestMode.None)
        .padding({ top: this.manager.nudgePadding })
        .onAppear(() => {
          this.manager.startPolling(this.tabModel);
        })
        .onDisAppear(() => {
          this.manager.stopPolling();
          this.manager.controller.dispose();
        })
      }

      this.MainContent()
    }
  }

  aboutToDisappear() {
    this.manager.stopPolling();
    this.manager.controller.dispose();
  }
}

@ComponentV2
struct NativeTabItem {
  @Require @Param index: number;
  @Require @Param tabModel: GlassTabContentModel;
  @Require @Param title: Resource;
  @Require @Param icon: Resource;
  @Require @Param primaryColor: ResourceColor;
  @Require @Param unselectedColor: ResourceColor;
  @Require @Param isDark: boolean;
  @Event onSelect: (index: number) => void = () => {};

  build() {
    Column() {
      Image(this.icon)
        .width(29.3)
        .height(29.3)
        .objectFit(ImageFit.Contain)
        .fillColor(this.tabModel.curIndex === this.index ? this.primaryColor : this.unselectedColor)
        .margin({ bottom: 2 })
      Text(this.title)
        .fontColor(this.tabModel.curIndex === this.index ? this.primaryColor : this.unselectedColor)
        .fontSize(8)
        .maxLines(1)
        .fontWeight(this.tabModel.curIndex === this.index ? FontWeight.Bold : FontWeight.Regular)
    }
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
    .opacity(this.tabModel.curIndex === this.index ? 1.0 : (this.isDark ? 0.8 : 0.65))
    .onClick(() => {
      this.onSelect(this.index);
    })
  }
}
