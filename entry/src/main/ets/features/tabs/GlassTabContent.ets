/*
 * SPDX-FileCopyrightText: 2026 Liugt
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import { HdsTabs } from '@kit.UIDesignKit';
import { VaultPage } from '../vault/VaultPage';
import { GeneratorPage } from '../generator/GeneratorPage';
import { SettingsPage } from '../settings/SettingsPage';
import { VaultViewModel } from '../vault/VaultViewModel';
import { SettingsViewModel } from '../settings/SettingsViewModel';
import { GeneratorViewModel } from '../generator/GeneratorViewModel';
import { GlassBandModel, BAND_EXTRA_TOP_VP, BAND_EXTRA_BOTTOM_VP } from './GlassBandModel';
import { MirrorRouter, MirrorPageEntry } from '../mirror/MirrorRouter';

/**
 * HdsTabs 沉浸光感能力检测（plan D8/R4）：kit 系统能力缺失时降级普通 Tabs
 * （样式退化为普通页签条），保证模拟器/旧 ROM 可运行。
 */
export const HDS_TABS_SUPPORTED: boolean = canIUse('SystemCapability.UIDesign.HDSComponent.Core');

/**
 * 页签内容壳的共享状态（B 形态）。
 *
 * 内容由 ArkUI 直显（主树，唯一可交互实例）；底部玻璃条带的背景另有一棵
 * **镜像树**（`BuilderNode(RENDER_TYPE_TEXTURE)`，passive），按整屏尺寸布局、
 * 只裁最底部条带导出给 GL。两棵树共用同一份 view model / 选中态 / 滚动偏移，
 * 镜像因此与主树逐像素一致（见 docs/glass-live-content-optimization.md）。
 *
 * view model 懒建：`Index` 的字段初始化早于 AppContainer 就绪，构造期取
 * ServiceLocator 会抛错（与 `glassTabBarEnabled` 同因），首次 build 时才创建。
 */
@ObservedV2
export class GlassTabContentModel {
  /** 当前选中页签（0..2）：两棵树同一状态源。 */
  @Trace curIndex: number = 0;
  /** 玻璃条带高（vp，Index 取 GlassTabShell 的条带常量）：镜像树的导出裁剪高度。 */
  @Trace bandHeight: number = 0;
  /**
   * 镜像导出的上沿余量（vp）：平时 = 条带余量（只导出条带）；有整屏消费者（玻璃弹窗等）时
   * 由 SharedMirrorManager 放开到"整页高 − 条带高"，纹理覆盖整页（见 acquireFullscreen）。
   */
  @Trace exportExtraTopVp: number = BAND_EXTRA_TOP_VP;
  /** 镜像根容器布局完成（导出高度，vp）：SharedMirrorManager 据此下发原生导出余量。 */
  exportLayoutListener: ((heightVp: number) => void) | null = null;
  /** 滚动同步（主树上报绝对偏移 → 镜像树 scrollTo；首帧催帧见 GlassBandModel.nudge）。 */
  readonly band: GlassBandModel = new GlassBandModel();

  private vault: VaultViewModel | null = null;
  private settings: SettingsViewModel | null = null;
  private generator: GeneratorViewModel | null = null;

  /**
   * 修复 HIGH-01：重置缓存的 ViewModels。
   * 确保进入/退出体验模式时，重新构造 ViewModel 并绑定当前活动的 VaultMemoryIndex。
   */
  resetViewModels(): void {
    this.vault = null;
    this.settings = null;
    this.generator = null;
  }

  vaultVm(): VaultViewModel {
    if (this.vault === null) {
      this.vault = new VaultViewModel();
    }
    return this.vault;
  }

  settingsVm(): SettingsViewModel {
    if (this.settings === null) {
      this.settings = new SettingsViewModel();
    }
    return this.settings;
  }

  generatorVm(): GeneratorViewModel {
    if (this.generator === null) {
      this.generator = new GeneratorViewModel();
    }
    return this.generator;
  }
}

/** 页签条由 GL / 原版指示器负责，内容树里的页签条不需要内容。 */
@Builder
function emptyTabBar() {
}

/**
 * 三页签内容树（页签条高度 0，仅内容）。
 *
 * 主树：挂在 ArkUI 上直显（转场 / 触摸 / 滚动全原生），`passive = false`；
 * 镜像树：包在 `GlassTabMirror` 里导出成条带纹理，`passive = true`
 * （页面不跑生命周期副作用、不注册监听，滚动跟随 `model.band`）。
 *
 * 必须是**自定义组件**：RENDER_TYPE_TEXTURE 只在"BuilderNode 持有组件树的根节点
 * 为自定义组件"时生效（官方接口说明），根直接挂 HdsTabs 不会产帧。
 */
@ComponentV2
export struct GlassTabContent {
  @Require @Param model: GlassTabContentModel;
  /** 镜像树标记：页面被动渲染（见各页 `passive` 参数）。 */
  @Param passive: boolean = false;

  build() {
    if (HDS_TABS_SUPPORTED) {
      HdsTabs({ barPosition: BarPosition.End, index: this.model.curIndex }) {
        TabContent() {
          VaultPage({
            viewModel: this.model.vaultVm(),
            band: this.model.band,
            passive: this.passive
          })
        }
        .tabBar(emptyTabBar)

        TabContent() {
          GeneratorPage({
            viewModel: this.model.generatorVm(),
            band: this.model.band,
            passive: this.passive
          })
        }
        .tabBar(emptyTabBar)

        TabContent() {
          SettingsPage({
            viewModel: this.model.settingsVm(),
            band: this.model.band,
            passive: this.passive
          })
        }
        .tabBar(emptyTabBar)
      }
      .barHeight(0)
      .vertical(false)
      // 与 HandLED DeviceControlPannel 一致：内容页瞬时切换，指示器弹簧是唯一动画
      .animationDuration(0)
      // 关闭左右翻页：避免吞掉筛选 chips 横向滚动手势
      .scrollable(false)
      .barPosition(BarPosition.End)
      .width('100%')
      .height('100%')
    } else {
      Tabs({ index: this.model.curIndex }) {
        TabContent() {
          VaultPage({
            viewModel: this.model.vaultVm(),
            band: this.model.band,
            passive: this.passive
          })
        }
        .tabBar(emptyTabBar)

        TabContent() {
          GeneratorPage({
            viewModel: this.model.generatorVm(),
            band: this.model.band,
            passive: this.passive
          })
        }
        .tabBar(emptyTabBar)

        TabContent() {
          SettingsPage({
            viewModel: this.model.settingsVm(),
            band: this.model.band,
            passive: this.passive
          })
        }
        .tabBar(emptyTabBar)
      }
      .barHeight(0)
      .barPosition(BarPosition.End)
      .scrollable(false)
      .width('100%')
      .height('100%')
    }
  }
}

/**
 * 镜像树（导出给 GL 当玻璃背景）。
 *
 * 几何：内容按**整屏尺寸**布局（`model.viewportHeight`，与主树同一坐标系），
 * 整体上移 `viewportHeight - bandHeight - BAND_EXTRA_TOP`、外层裁成**条带 + 上下余量** ——
 * NodeContainer 的尺寸即纹理，比可见条带高出的两段余量让 GL 采样位移能直接吃掉
 * 下拉刷新 / 越界回弹的整段位移（零延迟，见 GlassBandModel 的余量注释）。不能把整屏
 * 内容直接塞进条带高的容器（布局约束会变、页面被压扁）。
 *
 * 余量几何：可见条带 = 纹理的 [EXTRA_BOTTOM, EXTRA_BOTTOM + bandHeight]，
 * 所以内容相对条带要多上移 EXTRA_TOP（让纹理上沿多露一截页面内容、下沿多露一截
 * 页面底部区域），见 docs/glass-live-content-optimization.md §B6。
 */
@ComponentV2
export struct GlassTabMirror {
  @Require @Param model: GlassTabContentModel;
  @Provider('isMirrorContext') readonly isMirror: boolean = true;
  /** 栈顶已接入镜像的子页面（null = 页签根页面）：镜像内容 / 布局 / 偏移都按它。 */
  private router: MirrorRouter = MirrorRouter.get();

  /** 镜像里当前那一页的滚动同步模型。 */
  private activeBand(): GlassBandModel {
    return this.router.top !== null ? this.router.top.band : this.model.band;
  }

  @Builder
  private topPage(entry: MirrorPageEntry) {
    entry.builder.builder(entry)
  }

  build() {
    Stack({ alignContent: Alignment.Top }) {
      Stack() {
        // 页签内容常驻（压栈期间隐藏，不卸载：出栈回来不必重建、滚动位置不丢）
        GlassTabContent({ model: this.model, passive: true })
          .visibility(this.router.top === null ? Visibility.Visible : Visibility.Hidden)
        if (this.router.top !== null) {
          this.topPage(this.router.top as MirrorPageEntry)
        }
      }
      .width('100%')
      .height(this.activeBand().viewportHeight > 0 ? this.activeBand().viewportHeight : 1)
      // 越界回弹（Scroll 到不了的部分）用整体平移补齐；滞后的小位移由 GL 采样位移补
      // （见 GlassBandModel.updateSplit），保证玻璃与真实内容同帧。
      .offset({
        y: -(this.activeBand().viewportHeight - this.model.bandHeight - this.model.exportExtraTopVp) -
          this.activeBand().translateY
      })
    }
    .width('100%')
    .height((this.model.bandHeight > 0 ? this.model.bandHeight : 1) +
      this.model.exportExtraTopVp + BAND_EXTRA_BOTTOM_VP)
    .clip(true)
    // 导出高度真正布局完才告诉原生（外纹理随后按新尺寸出帧）：放开 / 收回整屏的过渡帧不错位
    .onAreaChange((_old: Area, area: Area) => {
      if (this.model.exportLayoutListener !== null) {
        this.model.exportLayoutListener(Number(area.height));
      }
    })
    .backgroundColor($r('app.color.system_background'))
    .hitTestBehavior(HitTestMode.None)
    .accessibilityLevel('no')
  }
}

/** 给 `BuilderNode.build` / ArkUI 直显共用的包装构建器。 */
@Builder
function glassTabContentBuilder(model: GlassTabContentModel) {
  GlassTabContent({ model: model })
}

export const GLASS_TAB_CONTENT: WrappedBuilder<[GlassTabContentModel]> =
  wrapBuilder(glassTabContentBuilder);

/** 条带镜像的包装构建器（`GlassTabShell` 的 NodeContainer 用）。 */
@Builder
function glassTabMirrorBuilder(model: GlassTabContentModel) {
  GlassTabMirror({ model: model })
}

export const GLASS_TAB_MIRROR: WrappedBuilder<[GlassTabContentModel]> =
  wrapBuilder(glassTabMirrorBuilder);
