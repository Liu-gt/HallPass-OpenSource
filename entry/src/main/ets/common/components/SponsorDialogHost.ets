/*
 * SPDX-FileCopyrightText: 2026 Liugt
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import { SponsorDialogService } from '../../features/settings/sponsor/SponsorDialogService';
import { SponsorDialog } from './SponsorDialog';

/**
 * 支持作者赞助弹窗的根级宿主：
 * 由 Index 渲染在最顶层，覆盖状态栏与整个 GlassTabBar 页签栏，阻断选择前的所有交互。
 * 彻底消除在页面内使用 bindSheet 导致的镜像树双重渲染和离屏崩溃。
 */
@ComponentV2
export struct SponsorDialogHost {
  private service: SponsorDialogService = SponsorDialogService.get();

  build() {
    if (this.service.visible) {
      SponsorDialog()
    }
  }
}
