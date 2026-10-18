/*
 * SPDX-FileCopyrightText: 2026 Liugt
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
import { GlassGLSetContentOffset, GlassGLSetMirrorOffset } from 'backdrop';

const DOMAIN: number = 0x0000;
const TAG: string = 'HallPassGlassBand';

/**
 * 镜像条带**上下余量**（vp）：镜像纹理（NodeContainer）比可见条带多出的部分。
 *
 * 采样位移（GL 当帧生效）只能采到"手里这帧纹理"里有的内容，而下拉刷新 / 越界回弹
 * 的整段位移在镜像 Scroll 的范围之外（scrollTo 到不了），过去只有 16vp 的采样预算、
 * 其余靠容器平移（走 ArkUI → 重渲染 → 纹理，晚 1~2 帧）。把纹理本身加高，采样就能
 * 直接吃掉整段位移 —— 这两段余量就是"纯采样区间"（零延迟），超出的部分才回落容器平移。
 *
 * 成本与余量成正比（镜像树光栅面积 + 生产者 surface 缓冲）：按实际最大下拉取，
 * 不要"尽可能大"（见 docs/glass-live-content-optimization.md §B6）。
 *
 * 超出余量的部分（长下拉 / 大甩）落容器平移，**延迟不会回退**：镜像偏移锁存里
 * 含 translateY，采样位移会把容器平移的 1~2 帧纹理滞后一并补掉（见 pushVisual）。
 * 采样位移的"高速余量" = 原生预算 − 拆分阈值（GlassTabShell 的 TRANSLATE_HEADROOM_VP）。
 */
export const BAND_EXTRA_TOP_VP: number = 64;     // 下拉刷新方向（采样往条带上沿）
export const BAND_EXTRA_BOTTOM_VP: number = 48;  // 底部回弹方向（采样往条带下沿）

/**
 * 一帧外推上限（vp）：采样位移是"画这一帧"时生效、下一次 vsync 才上屏，
 * 这段播出去的时间按上一帧的运动量前推（原生按 48ms 衰减），玻璃与真实内容才是同帧。
 * 只取半格位移，宁欠不过（超前比滞后更容易看出来）。
 */
const LEAD_LIMIT_VP: number = 8;

/**
 * 外推几帧（全局，所有页面的滚动同步模型共用）：玻璃比主内容晚上屏几帧就外推几帧。
 * XComponent(TEXTURE) 的帧要等 UI 线程下一帧取走 → 晚 1 帧；SURFACE 由 RenderService 直接消费，
 * 与主内容同一合成帧 → 0（见 GlassTabShell 的 GLASS_SURFACE_TYPE）。
 */
let leadFrames: number = 1;

export function setGlassLeadFrames(frames: number): void {
  leadFrames = frames;
}

/**
 * 镜像重排的量化阈值（vp）：镜像 Scroll 只在误差超过它时才 scrollTo。
 *
 * 小于阈值的滞后全部由 GL 采样位移补（当帧生效、观感连续），镜像树因此不必每帧
 * relayout 整页（第二棵树主要的 UI 线程成本）。阈值要明显小于采样预算：
 * 采样位移还得同时吃下 1~2 帧的纹理滞后，阈值太大就会顶到上限、玻璃补不满。
 * 滚动停下（ScrollState.Idle）时会无条件精确对一次，所以静止时不会留下这份偏差。
 */
const MIRROR_QUANTUM_VP: number = 8;

/**
 * 玻璃条带镜像的滚动同步模型（B 形态：内容 ArkUI 直显 + 条带镜像树导出）。
 *
 * 主树（ArkUI 直显）每帧上报**视觉偏移**，镜像树（BuilderNode 导出）按量化阈值
 * 把自己的 Scroll 跟过去（`scrollTo` 会被内容范围夹取），残差拆成两半补：
 *
 *   offsetY     = 主树的视觉偏移（含回弹，负 = 顶部下拉）
 *   appliedY    = 镜像 Scroll **逻辑上**落到的偏移（被夹取后的值）
 *   translateY  = 镜像容器整体平移，基准是 offsetY - appliedY（越界 / 跳转），
 *                 见 GlassTabMirror
 *   （采样位移不在这里：原生的 GL 每帧按**手里那帧纹理**的偏移重算，
 *     纹理换帧与补偿同帧发生 —— 放在这里算会差一拍，量化重排落地时就是"闪"）
 *
 * 预算非对称（setShiftLimits 下发的拆分阈值）：下拉 / 底部回弹方向的残差先由采样位移吃
 * （条带纹理的上下余量 + 面板留白），超出的部分才落容器平移 —— 且容器平移计入
 * "镜像实际装在哪"（pushMirrorOffset 推 appliedY + translateY），采样才能把它的
 * 1~2 帧纹理滞后一并补掉。
 *
 * 为什么不用「绝对偏移」一把梭：`Scroller.currentOffset()` 在边界回弹时会被
 * 夹到 0 / max（下/拉出空白时玻璃不跟手）；而 `scrollTo` 也到不了范围外。
 * 所以：**非边界**用绝对偏移纠偏（防增量漂移），**边界**用 onDidScroll 的
 * 每帧增量跟住回弹；夹不掉的部分用平移补齐。
 */
@ObservedV2
export class GlassBandModel {
  /** 主树的视觉滚动偏移（vp）：镜像树 scrollTo 的目标。 */
  @Trace offsetY: number = 0;
  /**
   * 催帧微扰（vp）：首帧未到期间由 `GlassTabShell` 交替 ±1，让镜像 Scroll 真的滚一下。
   *
   * 真机实测：镜像纹理的首帧只有"镜像树自己重排重绘"才会产出（用户滑动一帧即出，
   * 静止时永不产出）。所以首帧等待期间用这个微扰当"虚拟滑动"，出帧后由
   * `clearNudge()` 撤销（采样位移会补偿它，玻璃里看不出这一下）。
   */
  @Trace nudge: number = 0;
  /** 镜像 Scroll 实际落到的偏移（vp，被内容范围夹取后的值）。 */
  @Trace appliedY: number = 0;
  /** 当前页签（与 GlassTabContentModel.curIndex 同步）。 */
  @Trace tabIndex: number = 0;
  /**
   * 精确对齐请求（滚动停下时 +1）。
   *
   * 主树与镜像树是两个组件实例，滚动停下只有主树侧能感知（`ScrollState.Idle`），
   * 而精确 `scrollTo` 只能由镜像树侧执行 —— 用模型当一个信号量转发：
   * 两边都 @Monitor 它，只有 passive（镜像）那份会真的去滚。
   */
  @Trace alignEpoch: number = 0;
  private lastAlignMs: number = 0;
  /**
   * 主树**页面盒**高度（vp）：镜像树按它布局整页高度（含页面自己的头部内距）。
   *
   * 不能用滚动容器的高度：页面里可能有浮层头部、内容被顶部内距让位（首页就是），
   * 镜像按滚动容器高度布局会少掉这段内距 → 内容整体上移、玻璃里映射到错误的一行。
   * 页面盒底边贴屏幕底，镜像用"底边对齐"反推原点（见 GlassTabMirror）。
   */
  @Trace viewportHeight: number = 0;
  /**
   * 主树页面盒在窗口里的上沿（vp，-1 = 未上报）：整屏导出纹理的行 0 = 页面盒上沿。
   * 不能假设"页面盒底边贴窗口底"再反推 —— 子页面 / Navigation 根的高度与窗口不一致（差系统栏）。
   */
  viewportTop: number = -1;
  /** 镜像容器平移（vp）：越界回弹 / 跳转（镜像 Scroll 到不了的部分），见 GlassTabMirror。 */
  @Trace translateY: number = 0;
  private offsets: number[] = [0, 0, 0];
  private applied: number[] = [0, 0, 0];
  /** 上一次容器报告的绝对偏移（判断"容器是否真的在动"，见 report）。 */
  private lastAbsolute: number[] = [0, 0, 0];
  /** 原生接口能不能用（旧 .so 会抛异常；只报一次，之后静默降级）。 */
  private nativeOk: boolean = true;
  /** 采样位移预算（vp，非对称）：负残差（下拉）用 up，正残差（底部回弹）用 down。
   *  由 GlassTabShell 按条带几何 + 镜像余量下发（setShiftLimits），默认值 = 旧行为。 */
  private shiftUpLimit: number = 16;
  private shiftDownLimit: number = 16;
  /** 上一帧的运动量（vp，正 = 内容上移）：一帧外推用，随每次上报更新。 */
  private lead: number = 0;
  /**
   * 下拉刷新量（vp，正 = 内容被拉下）。
   *
   * Refresh 的手势不会让内部 Scroll 滚动（`onDidScroll` 不触发），内容是 Refresh
   * 整体平移的 —— 所以它单独记一份，只进"视觉偏移"，不参与镜像 scrollTo
   * （镜像的 Scroll 也到不了范围外，靠容器平移 + 采样位移补）。
   */
  private pullY: number = 0;

  /** 视觉偏移 = 滚动偏移 - 下拉量（含 Refresh 下拉、负 = 内容下移）。 */
  private get visualY(): number {
    return this.offsetY - this.pullY;
  }

  /** 把镜像的逻辑落点推给原生（出帧回调把它锁存成"纹理偏移"，采样位移的基准之一）。 */
  private pushMirrorOffset(offsetY: number, resync: boolean): void {
    if (!this.nativeOk) {
      return;
    }
    try {
      GlassGLSetMirrorOffset(offsetY, resync);
    } catch (err) {
      this.nativeOk = false;
      hilog.warn(DOMAIN, TAG, 'mirror offset unavailable: %{public}s', JSON.stringify(err));
    }
  }

  /**
   * 把主树的视觉偏移 + 一帧外推量推给原生（采样位移由原生每帧算，见 GlassGLSetContentOffset）。
   * 外推量在原生侧按 48ms 衰减，滚动停下后自己归零，这里不需要收尾。
   */
  private pushContentOffset(offsetY: number, leadVp: number): void {
    if (!this.nativeOk) {
      return;
    }
    try {
      GlassGLSetContentOffset(offsetY, leadVp);
    } catch (err) {
      this.nativeOk = false;
      hilog.warn(DOMAIN, TAG, 'content offset unavailable: %{public}s', JSON.stringify(err));
    }
  }

  /**
   * 容器平移（条带可见部分）= 逻辑残差 `visualY - appliedY` 超出**拆分阈值**的部分。
   *
   * 只有镜像 Scroll **到不了**的地方才动它（越界回弹、下拉刷新、程序化跳转）；
   * 正常滚动里逻辑残差 ≈ 一帧位移（阈值内）→ 恒为 0，既不每帧 relayout 整页，
   * 也不会因为容器平移应用晚一帧而抖。基准必须用逻辑落点：拿纹理残差去动容器，
   * 量化重排落地时容器会跟着跳。
   */
  private updateTranslate(): void {
    const residual: number = this.visualY - this.appliedY;
    const translate: number = residual - Math.max(-this.shiftUpLimit,
      Math.min(this.shiftDownLimit, residual));
    if (this.translateY !== translate) {
      this.translateY = translate;
    }
  }

  /**
   * 视觉偏移 / 外推推给原生 + 重算容器平移 + 锁存镜像实际落点（滚动、下拉、落点变化都走这里）。
   *
   * 镜像偏移必须推 **appliedY + translateY**：GL 采样位移的基准是"纹理里装的是什么"，
   * 而容器平移也装在纹理里（越界 / 下拉超预算的部分）—— 只推 appliedY 的话，这部分
   * 1~2 帧的纹理滞后采样补不掉，正是下拉/回弹时玻璃"跟不上手"的根因。
   *
   * @param resync 换内容（切页 / 重建）时 true：原生把锁存值一起重置（见 SetMirrorOffset）。
   */
  private pushVisual(resync: boolean = false): void {
    this.pushContentOffset(this.visualY, this.lead * leadFrames);
    this.updateTranslate();
    this.pushMirrorOffset(this.appliedY + this.translateY, resync);
  }

  /** 请求一次精确对齐（见 alignEpoch）；50ms 去重，防止"对齐 → 事件 → 再对齐"来回打。 */
  requestAlign(): void {
    const now: number = Date.now();
    if (now - this.lastAlignMs < 50) {
      return;
    }
    this.lastAlignMs = now;
    this.alignEpoch++;
  }

  /** 镜像 scrollTo 的目标偏移 = 主树视觉偏移 + 催帧微扰（见 nudge）。 */
  mirrorTargetY(): number {
    return this.offsetY + this.nudge;
  }

  /** 撤销催帧微扰（首帧到达后调用）：镜像回到精确几何，这一帧纹理才是对齐的。 */
  clearNudge(): void {
    if (this.nudge === 0) {
      return;
    }
    this.nudge = 0;
    // 绕过 requestAlign 的 50ms 去重：这次对齐必须真的发生（否则镜像停在微扰位）
    this.lastAlignMs = 0;
    this.requestAlign();
  }

  /**
   * 镜像是否值得重排（量化门限，接在镜像侧 `applyBandOffset` 前）。
   *
   * 误差小于阈值就让 GL 采样位移顶着（观感连续），镜像不回位 —— 每帧 relayout
   * 整页是第二棵树最贵的一笔，量化后只在跨过阈值时付一次。
   */
  mirrorNeedsReposition(target: number): boolean {
    return Math.abs(target - this.appliedY) >= MIRROR_QUANTUM_VP;
  }

  /**
   * 主树上报（接在 `.onDidScroll`）。
   *
   * @param delta 本帧位移（vp，正 = 内容上移；含越界回弹）
   * @param absolute 容器报告的绝对偏移（边界回弹时会被夹取）
   *
   * 判据：**容器报告的偏移真的动了**就用它纠偏（防增量漂移）；**没动但增量非零**
   * 说明已经越界（`currentOffset` 被夹在 0 / max，下上拉出空白就是这种情况），
   * 此时只能靠增量把视觉位移累积出来，夹不掉的部分由 `overscrollY` 平移补齐。
   */
  report(delta: number, absolute: number): void {
    const moved: boolean = Math.abs(absolute - this.lastAbsolute[this.tabIndex]) > 0.01;
    this.lastAbsolute[this.tabIndex] = absolute;
    const next: number = moved ? absolute : this.offsets[this.tabIndex] + delta;
    if (this.offsets[this.tabIndex] === next) {
      return;
    }
    this.offsets[this.tabIndex] = next;
    this.offsetY = next;
    // 一帧外推：画完到上屏还有一帧，按上一帧的运动量前推（原生 48ms 衰减）
    this.lead = Math.max(-LEAD_LIMIT_VP, Math.min(LEAD_LIMIT_VP, delta));
    this.pushVisual();
  }

  /**
   * 主树上报**下拉刷新量**（接在 Refresh 的 `.onOffsetChange`）。
   * 正 = 内容被拉下；不参与镜像 scrollTo，只影响玻璃采样的视觉偏移与容器平移。
   *
   * 与滚动同一套一帧外推：下拉量走的是"视觉偏移 -pull"，运动量取 -Δ（正 = 内容上移），
   * 否则下拉比滚动多欠一帧（画完到上屏的那一帧没人前推）。
   */
  reportPull(pullVp: number): void {
    const pull: number = pullVp > 0 ? pullVp : 0;
    const delta: number = this.pullY - pull;
    if (Math.abs(delta) < 0.01) {
      return;
    }
    this.pullY = pull;
    this.lead = Math.max(-LEAD_LIMIT_VP, Math.min(LEAD_LIMIT_VP, delta));
    this.pushVisual();
  }

  /**
   * 容器平移的拆分阈值（vp，非对称，由 GlassTabShell 按条带几何 + 镜像余量下发）。
   * 必须 ≤ 原生 `GlassGLSetContentBand` 的采样预算（差值是纹理滞后 + 一帧外推的头寸），
   * 否则容器平移与采样位移会重复补 / 补不满。
   */
  setShiftLimits(upVp: number, downVp: number): void {
    if (upVp > 0) {
      this.shiftUpLimit = upVp;
    }
    if (downVp > 0) {
      this.shiftDownLimit = downVp;
    }
    this.pushVisual();
  }

  /** 主树滚动容器上报视口高度（接在 `.onAreaChange`）。 */
  reportViewportHeight(heightVp: number, topVp: number = -1): void {
    if (topVp >= 0) {
      this.viewportTop = topVp;
    }
    if (heightVp > 0 && Math.abs(heightVp - this.viewportHeight) > 0.5) {
      this.viewportHeight = heightVp;
    }
  }

  /** 主树重建 / 重新可见：位置必然在顶部（也用于纠偏）。 */
  resetOffset(): void {
    this.lastAbsolute[this.tabIndex] = 0;
    if (this.offsets[this.tabIndex] === 0 && this.offsetY === 0) {
      return;
    }
    this.offsets[this.tabIndex] = 0;
    this.offsetY = 0;
    this.pullY = 0;
    this.lead = 0;
    // 镜像树也要重建回顶部（换内容），纹理偏移一并重置
    this.pushVisual(true);
  }

  /** 镜像 Scroll 上报实际落点（接在镜像自己的 `.onDidScroll`）。 */
  setApplied(offsetY: number): void {
    if (this.applied[this.tabIndex] === offsetY && this.appliedY === offsetY) {
      return;
    }
    this.applied[this.tabIndex] = offsetY;
    this.appliedY = offsetY;
    // 落点推给原生：下一帧出帧时会被锁存成"纹理偏移"（补偿的基准）
    this.pushVisual();
  }

  /** 切页：镜像改用目标页签上次上报的偏移（换内容，纹理偏移一并重置）。 */
  setTab(index: number): void {
    if (index < 0 || index >= this.offsets.length) {
      return;
    }
    this.tabIndex = index;
    const nextOffset: number = this.offsets[index];
    const nextApplied: number = this.applied[index];
    if (this.offsetY !== nextOffset) {
      this.offsetY = nextOffset;
    }
    if (this.appliedY !== nextApplied) {
      this.appliedY = nextApplied;
    }
    this.pullY = 0;
    this.lead = 0;
    // 换的是另一页的内容：锁存值必须跟着重置，否则残差会算出上一页的一大截假位移
    this.pushVisual(true);
  }

  /**
   * 镜像内容切换到本模型所属页面（子页面压栈 / 出栈回到页签）：原生的偏移与锁存值
   * 都换成本页的（全局只有一套采样补偿状态，谁在镜像里谁推）。
   */
  resync(): void {
    this.pullY = 0;
    this.lead = 0;
    this.pushVisual(true);
  }

  /** 退出登录 / 重建页签壳：偏移清零。 */
  reset(): void {
    this.offsets = [0, 0, 0];
    this.applied = [0, 0, 0];
    this.lastAbsolute = [0, 0, 0];
    this.tabIndex = 0;
    this.offsetY = 0;
    this.appliedY = 0;
    this.pullY = 0;
    this.lead = 0;
    this.pushVisual(true);
  }
}
