/*
 * SPDX-FileCopyrightText: 2026 Liugt
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import { GlassBandModel } from '../tabs/GlassBandModel';

/**
 * 镜像页的滚动容器（与 SettingsPage 同一套同步逻辑，抽出来给子页面复用）：
 * 主树（passive = false）上报绝对偏移 → band；镜像树（passive = true）按 band 无动画 scrollTo，
 * 并回报自己实际落点（原生据此锁存纹理偏移、做滞后补偿）。停下时请求一次精确对齐。
 *
 * 尺寸：内部 Scroll 铺满本组件，调用方在组件上给 layoutWeight / height。
 */
@ComponentV2
export struct MirroredScroll {
  @Require @Param band: GlassBandModel;
  @Param passive: boolean = false;
  @BuilderParam content: () => void;
  private scroller: Scroller = new Scroller();

  aboutToAppear(): void {
    if (this.passive) {
      // 镜像挂载首帧跟上主树当前偏移（滚动中进场时不是 0）
      setTimeout((): void => {
        this.applyBandOffset(true);
      }, 0);
      return;
    }
    // 页面（重）建时位置必然在顶部
    this.band.resetOffset();
  }

  private applyBandOffset(force: boolean = false): void {
    if (!this.passive) {
      return;
    }
    if (!force && !this.band.mirrorNeedsReposition(this.band.mirrorTargetY())) {
      return;
    }
    this.scroller.scrollTo({ xOffset: 0, yOffset: this.band.mirrorTargetY(), animation: false });
  }

  @Monitor('band.offsetY')
  private onBandOffsetChange(): void {
    this.applyBandOffset();
  }

  @Monitor('band.alignEpoch')
  private onAlignRequest(): void {
    this.applyBandOffset(true);
  }

  build() {
    Scroll(this.scroller) {
      this.content()
    }
    .width('100%')
    .height('100%')
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring)
    .align(Alignment.Top)
    // Scroll 的回调是 (xOffset, yOffset, scrollState)（List 才是 (scrollOffset, scrollState)）：
    // 按 List 的签名写会把恒为 0 的 xOffset 当位移（一帧外推 / 越界增量全丢）、把位移当状态
    .onDidScroll((_xOffset: number, yOffset: number, scrollState: ScrollState) => {
      if (this.passive) {
        this.band.setApplied(this.scroller.currentOffset().yOffset);
      } else {
        this.band.report(yOffset, this.scroller.currentOffset().yOffset);
      }
      if (scrollState === ScrollState.Idle) {
        this.band.requestAlign();
      }
    })
    .onAppear(() => {
      if (!this.passive) {
        this.band.report(0, this.scroller.currentOffset().yOffset);
      }
      this.applyBandOffset(true);
    })
  }
}
