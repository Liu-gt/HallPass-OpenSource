/*
 * SPDX-FileCopyrightText: 2026 Liugt
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import { UIUtils } from '@kit.ArkUI';

/**
 * 显式动画入口（V2 适配）。
 *
 * V2 状态变量改完不会立即标脏，而是抛微任务，等当前宏任务结束后才处理；
 * animateTo 却要求"立刻刷新已标脏节点"来决定动效首帧，两者冲突——异步回调
 * （Promise 续体 / @Monitor）里改状态再 animateTo 会丢动画参数，表现为直接跳变。
 * 闭包内用 UIUtils.applySync 同步标脏即可恢复动画（API 22+，见官方
 * 《applySync/flushUpdates/flushUIUpdates 接口：同步刷新》）。
 */
export function animateToSync(ui: UIContext, params: AnimateParam, task: () => void): void {
  ui.animateTo(params, (): void => {
    UIUtils.applySync((): void => {
      task();
    });
  });
}
