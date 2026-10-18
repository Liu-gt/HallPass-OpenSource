/*
 * SPDX-FileCopyrightText: 2026 Liugt
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import { GlassBandModel } from '../tabs/GlassBandModel';

/**
 * 可镜像的子页面（Navigation 压栈的 NavDestination）在镜像树里的登记项。
 *
 * NavDestination 只能挂在 Navigation 下，不能放进镜像树：每个子页面因此拆成
 * "外壳"（NavDestination + 路由参数 + VM 生命周期，留在 Navigation 里）与
 * "内容"（纯 UI，注入共享状态 / band / passive）。主树与镜像树渲染同一个内容组件、
 * 共用同一份 state —— 镜像与屏幕逐像素一致（与页签页同一套约定，见 GlassTabContent）。
 *
 * 镜像页约定（新页面接入时照此实现）：
 *   1. state：页面全部可见状态（VM + 页内 UI 状态）集中在一个 @ObservedV2 对象里，外壳持有；
 *   2. 内容组件 @Param state / band / passive：passive = true 时只渲染 —— 不跑 init / 监听，
 *      所有点击、输入、弹窗、路由跳转都直接 return；
 *   3. 滚动容器用 MirroredScroll（或像 VaultList 那样自己接 band），主树上报、镜像跟随；
 *   4. 外壳 onShown 登记、onHidden / aboutToDisappear 注销（MirrorRouter.show / hide）。
 */
export class MirrorPageEntry {
  readonly route: string;
  readonly state: object;
  /** 本页的滚动同步（独立实例，tabIndex 恒 0）：镜像布局 / 导出尺寸 / 原生补偿都按它。 */
  readonly band: GlassBandModel;
  readonly builder: WrappedBuilder<[MirrorPageEntry]>;

  constructor(route: string, state: object, band: GlassBandModel,
    builder: WrappedBuilder<[MirrorPageEntry]>) {
    this.route = route;
    this.state = state;
    this.band = band;
    this.builder = builder;
  }
}

/** 当前在屏幕上的已接入子页面（null = 页签根页面，或栈顶页面未接入镜像）。 */
@ObservedV2
export class MirrorRouter {
  private static ref: MirrorRouter | null = null;

  static get(): MirrorRouter {
    if (MirrorRouter.ref === null) {
      MirrorRouter.ref = new MirrorRouter();
    }
    return MirrorRouter.ref;
  }

  @Trace top: MirrorPageEntry | null = null;
  /** 回到页签根页面时重推页签的偏移（Index 登记；SharedMirrorManager 持有页签模型）。 */
  private tabsResync: (() => void) | null = null;
  /** 栈顶变化（SharedMirrorManager 据此按新页面的视口重算导出尺寸）。 */
  private topListener: (() => void) | null = null;

  setTabsResync(resync: (() => void) | null): void {
    this.tabsResync = resync;
  }

  setTopListener(listener: (() => void) | null): void {
    this.topListener = listener;
  }

  /** 子页面可见（NavDestination.onShown）：镜像切到本页内容。 */
  show(entry: MirrorPageEntry): void {
    if (this.top === entry) {
      return;
    }
    this.top = entry;
    entry.band.resync();
    if (this.topListener !== null) {
      this.topListener();
    }
  }

  /**
   * 子页面不可见 / 销毁：只有自己仍是栈顶才清掉（压栈时新页面的 onShown 可能先于旧页面的 onHidden）。
   * 清掉后若回到的是另一个已接入页面，它的 onShown 会立刻再登记。
   */
  hide(entry: MirrorPageEntry): void {
    if (this.top !== entry) {
      return;
    }
    this.top = null;
    if (this.tabsResync !== null) {
      this.tabsResync();
    }
    if (this.topListener !== null) {
      this.topListener();
    }
  }

  /** 镜像里当前那一页的滚动同步模型（null = 页签内容，用页签模型）。 */
  activeBand(): GlassBandModel | null {
    return this.top !== null ? this.top.band : null;
  }
}
