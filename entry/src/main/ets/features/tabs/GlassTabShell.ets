/*
 * SPDX-FileCopyrightText: 2026 Liugt
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
import { SharedMirrorManager, ConsumerConfig, ViewportRect } from "./SharedMirrorManager";
import { BuilderNode, FrameCallback, FrameNode, NodeController, NodeRenderType, UIContext } from '@kit.ArkUI';
import { display } from '@kit.ArkUI';
import {
  GlassGLGetContentSurfaceId,
  GlassGLHasContentFrame,
  GlassGLIsRunning,
  GlassGLRegisterTabCallback,
  GlassGLSetBackdrop,
  GlassGLSetContentBackdrop,
  GlassGLSetContentBand,
  GlassGLSetDemoChrome,
  GlassGLSetDensity,
  GlassGLSetNumber,
  GlassGLSetOverlayMode,
  GlassGLSetPaused,
  GlassGLSetScene,
  GlassGLSetSelectedTab,
  GlassGLSetTabs,
  GlassGLUnbindNode,
  GlassGLUnregisterTabCallback
} from 'backdrop';
import { GLASS_TAB_MIRROR, GlassTabContentModel } from './GlassTabContent';
import { BAND_EXTRA_TOP_VP, BAND_EXTRA_BOTTOM_VP, GlassBandModel, setGlassLeadFrames } from './GlassBandModel';
import { Spacing } from '../../common/design/Tokens';
import { ThemeService, ThemeState } from '../../application/theme/ThemeService';
import { GlassTabIcons } from './GlassTabIcons';

const DOMAIN: number = 0x0000;
const TAG: string = 'HallPassGlassShell';

/** 原生 XComponent id：与 glass_napi.cpp 的 RegisterNativeXComponent 白名单一致。 */
const SURFACE_ID: string = 'glassSurface';
/** 原生库名（backdrop HAR 的 libbackdrop.so）。 */
const SURFACE_LIBRARY: string = 'backdrop';
/**
 * 玻璃 surface 的类型：SURFACE（RenderService 直接消费）。
 *
 * TEXTURE 的帧要等 UI 线程下一帧取走（vsync + ~0.8ms）再随 UI 事务进 RS：比主内容晚 1 帧
 * （只能靠外推补，外推误差就是"玻璃里的内容在晃"），而且 buffer 取走后 ~40ms 才归还，
 * 120Hz 下 5 张不够用、RequestBuffer 频繁阻塞。SURFACE 的帧在下一个 vsync 由 RS 直接取走，
 * 与同一 UI 帧的主内容同一合成帧上屏：对齐不再需要外推（setGlassLeadFrames(0)），
 * buffer 下一帧即归还。真机对比见 docs/glass-render-perf-report.md。
 * 切回 TEXTURE 只改这一处（外推帧数随之回到 1）。
 */
const GLASS_SURFACE_TYPE: XComponentType = XComponentType.SURFACE;

/** 原生参数编号（见 backdrop/src/main/cpp/glass/glass_params.h 的 pid）。 */
const PID_BAR_HEIGHT: number = 0;               // 底板高度（dp）
const PID_BLUR_RADIUS: number = 1;              // 底座模糊半径（dp）
const PID_REFRACTION_HEIGHT: number = 2;        // 底座折射高度（dp）
const PID_REFRACTION_AMOUNT: number = 3;        // 底座折射强度（dp）
const PID_CONTAINER_ALPHA: number = 4;          // 底色不透明度
const PID_PRESS_GROWTH: number = 5;             // 底座按压缩放量（dp）
const PID_GLOW_FLAT: number = 6;                // 跟手光斑·平面分量
const PID_GLOW_RADIAL: number = 7;              // 跟手光斑·径向分量
const PID_GLOW_RADIUS_FACTOR: number = 8;       // 跟手光斑半径系数
const PID_LABEL_FONT_SIZE: number = 24;         // 页签文字字号（dp）
const PID_LABEL_UNSELECTED_ALPHA: number = 26;  // 未选中字透明度
const PID_INDICATOR_TINT_REST: number = 35;     // 指示器静止时选中底色
const PID_INDICATOR_TINT_DRAG: number = 45;     // 指示器按压 / 拖动时选中底色
const PID_INDICATOR_SHADOW_REST: number = 38;   // 指示器静止时阴影
const PID_INDICATOR_HEIGHT: number = 41;        // 指示器胶囊高度（dp）
const PID_INDICATOR_REFRACTION_HEIGHT_DRAG: number = 43; // 指示器拖动时折射高度（dp）
const PID_INDICATOR_REFRACTION_AMOUNT_DRAG: number = 44; // 指示器拖动时折射强度（dp）
const PID_INDICATOR_HIGHLIGHT_DRAG: number = 47; // 指示器拖动时的棱边高光（轮廓）
const PID_INDICATOR_SHADOW_DRAG: number = 48;   // 指示器拖动时的投影强度
const PID_INDICATOR_INNER_SHADOW_RADIUS_DRAG: number = 49; // 拖动时内阴影半径（dp）
const PID_INDICATOR_INNER_SHADOW_ALPHA_DRAG: number = 50;  // 拖动时内阴影强度
const PID_PRESSED_SCALE: number = 51;           // 按压时胶囊纵向放大倍率（弹簧目标，demo 默认 1.7）
const PID_OUTER_PADDING_V: number = 23;         // 底板距 surface 底边（dp）
const PID_OUTER_PADDING_H: number = 22;         // 底板距 surface 左右边的外边距（dp）
const PID_BACKGROUND_SCROLL_RANGE: number = 64; // =1 时背景 1:1 铺满，不做照片式放大
const PID_PANEL_CORNER_RADIUS: number = 68;     // 底板圆角半径（dp）
const PID_HIGHLIGHT_WIDTH: number = 69;         // 棱边高光宽度（dp）
const PID_SHADOW_BLUR: number = 70;             // 投影模糊半径（dp，底板与指示器共用）
const PID_SHADOW_OFFSET: number = 71;           // 投影下移（dp）
const PID_SHADOW_ALPHA: number = 72;            // 投影强度（叠加模式下即最大压暗量）
const PID_PRESS_SAMPLE_SHRINK: number = 81;     // 按压时指示器内内容的采样缩小比例
const PID_PRESSED_SCALE_X: number = 82;         // 按压时胶囊横向放大倍率（原生追加参数）
const PID_TAB_ICON_SIZE: number = 83;           // 页签图标尺寸（dp，原生追加参数）
const PID_SURFACE_COLOR_R: number = 84;         // 表面填充色 R（0..1，原生追加参数）
const PID_SURFACE_COLOR_G: number = 85;         // 表面填充色 G
const PID_SURFACE_COLOR_B: number = 86;         // 表面填充色 B
const PID_INDICATOR_FILL_REST: number = 87;     // 选中胶囊黑底不透明度·静止（原生追加参数）
const PID_INDICATOR_FILL_DRAG: number = 88;     // 选中胶囊黑底不透明度·拖动
const PID_PRESS_LABEL_SCALE: number = 89;       // 按压时指示器内页签文字/图标的放大比例（原生追加参数）
const PID_TAB_ICON_SIZE_ACCENT: number = 90;    // 指示器内凸显色文字的图标尺寸（原生追加参数）
const PID_LABEL_FONT_SIZE_ACCENT: number = 91;  // 指示器内凸显色文字的字号
const PID_SHADOW_BLUR_PRESS: number = 92;       // 按压态底座投影模糊半径（原生追加参数）
const PID_SHADOW_ALPHA_PRESS: number = 93;      // 按压态底座投影强度

/** 底座材质（调参定稿 2026-09-20，见原生默认值注释）。 */
const BLUR_RADIUS: number = 0.3;            // 原生 0.2
const REFRACTION_HEIGHT: number = 21;       // 原生 12
const REFRACTION_AMOUNT: number = 18;       // 原生 30
const CONTAINER_ALPHA: number = 0.45;       // 原生 0.5
const PRESS_GROWTH: number = 8;             // 原生 3（底座按压缩放量，dp）
const GLOW_FLAT: number = 0.003;            // 原生 0.07：按压时整块底板加白（走查两轮嫌亮 → 收到极弱）
const GLOW_RADIAL: number = 0.008;          // 原生 0.15：跟手径向光斑，同比例收到极弱
const GLOW_RADIUS_FACTOR: number = 1;       // 原生 1.5

/**
 * 按压态只看轮廓：材质（白光 / 折射 / tint / 表面白）全部走 demo 默认，
 * 只额外加"棱边高光 + 内阴影"两项做胶囊边界（白底 / 灰底都能看清轮廓）。
 */
const HIGHLIGHT_DRAG: number = 0.5;
const INNER_SHADOW_RADIUS_DRAG: number = 7;
const INNER_SHADOW_ALPHA_DRAG: number = 0.20;
const HIGHLIGHT_WIDTH: number = 0.3;
const PRESS_SAMPLE_SHRINK: number = 0.1;
const PRESS_LABEL_SCALE: number = 0.2;
const PRESSED_SCALE: number = 1.44;
const PRESSED_SCALE_X: number = 1.26;
const LABEL_UNSELECTED_ALPHA: number = 0.65;
const INDICATOR_TINT_REST: number = 0.19;
/**
 * 浅色按压 / 拖动时的选中底色（静止 0.19）。当前定稿 0 = 不保留，
 * 按到底仍是纯玻璃透镜；想给按压态留一点选中色改这一个值即可。
 */
const INDICATOR_TINT_DRAG_LIGHT: number = 0;
const INDICATOR_SHADOW_REST: number = 0;
const INDICATOR_REFRACTION_HEIGHT_DRAG: number = 13;
const INDICATOR_REFRACTION_AMOUNT_DRAG: number = 10;

/** 深浅色分侧参数。 */
const SURFACE_LIGHT_R: number = 1;
const SURFACE_LIGHT_G: number = 1;
const SURFACE_LIGHT_B: number = 1;
const SURFACE_DARK_R: number = 0.18;
const SURFACE_DARK_G: number = 0.18;
const SURFACE_DARK_B: number = 0.2;
const LABEL_UNSELECTED_ALPHA_DARK: number = 0.8;
const INDICATOR_TINT_REST_DARK: number = 0;
const INDICATOR_TINT_DRAG_DARK: number = 0;
const INDICATOR_FILL_REST_DARK: number = 0.6;
const INDICATOR_FILL_DRAG_DARK: number = 0;
/** 未选中页签（文字 + 图标）颜色：浅色纯黑 / 深色纯白（对比度优先，不用灰色）。 */
const TAB_UNSELECTED_LIGHT: string = '#000000';
const TAB_UNSELECTED_DARK: string = '#FFFFFF';

/** 底座投影。 */
const SHADOW_BLUR: number = 24;
const SHADOW_OFFSET: number = 6;
const SHADOW_ALPHA: number = 0.07;
/**
 * 按压态底座投影：大范围、更弱、更散。
 *
 * 按压时胶囊鼓出底板，贴着轮廓的窄投影会紧贴鼓出的胶囊露出一圈暗边（真机走查），
 * 换成大模糊 + 低强度的环境影 —— 既避开暗边，又给按压鼓出留出体积感。
 */
const SHADOW_BLUR_PRESS: number = 40;
const SHADOW_ALPHA_PRESS: number = 0.035;

/** 底板高度（vp）：对齐设计 token（Sizes.tabBar 56）与内容尾部避让（56 + 24）。 */
const BAR_HEIGHT: number = 56;
/** 底板圆角（vp）：定稿 30（原生会钳到半高 = 28，即胶囊形状；再大无效果）。 */
const PANEL_CORNER_RADIUS: number = 30;
/** 指示器高度（vp）：与底板保持上下各 4vp 留白。 */
const INDICATOR_HEIGHT: number = BAR_HEIGHT - 8;
const TAB_ICON_SIZE: number = 25.6;
const LABEL_FONT_SIZE: number = 8;
const TAB_ICON_SIZE_ACCENT: number = 24.4;
const LABEL_FONT_SIZE_ACCENT: number = 8;
/**
 * 页签条上方多留出的高度（vp）：投影 / 按压鼓出要画进 surface，否则会被裁。
 * 按**按压态**投影的上沿取值（模糊半径 + 下偏移）：按压影比常态影大得多，
 * 上沿被裁会在条带顶边留下一道硬边。
 */
const STRIP_OVERHANG: number = SHADOW_BLUR_PRESS + SHADOW_OFFSET + 6;
/** 底板标准设计宽度（vp）：3 个槽位各 86vp，与设计 token 和 HdsTabs 对齐。大屏上以此宽度居中钳位。 */
const BASE_BAR_WIDTH: number = 258;
/** 底板最小左右外留白（vp）：小屏手机保证底板两侧至少有 64vp 间距。 */
const MIN_OUTER_PADDING_H: number = 64;

/**
 * 原生自检：surface / EGL 起不来就回退 ArkUI 页签。
 *
 * 50ms 轮询而不是固定等 500ms：surface 一般 20~30ms 就绪，早判定才能早把
 * 选中态 / 暂停标记对齐真实状态；总预算与旧版（500 + 1200×2）持平。
 */
const READY_CHECK_INTERVAL_MS: number = 50;
const READY_CHECK_TIMEOUT_MS: number = 3000;
/** 内容纹理轮询间隔（ms）：16ms ≈ 一帧，早一帧拿到就早一帧出玻璃。 */
const CONTENT_POLL_MS: number = 16;
/**
 * 首帧等待超时（ms）：超时只降频继续等，**不再回退 ArkUI 页签** —— 玻璃壳本身
 * 可用（只是背景还停在兜底底色），而回退是破坏性的（旧实现超时即整壳切 Ark，
 * 且失败标记粘滞，只能重启进程恢复）。
 */
const CONTENT_READY_TIMEOUT_MS: number = 5000;
/** 首帧超时后的轮询间隔（ms）：迟到补偿不必按帧轮询。 */
const CONTENT_POLL_SLOW_MS: number = 250;
/**
 * 催帧间隔（ms）：界面空闲时 ArkUI 不会为刚挂上主树的纹理子树排帧
 * （真机实测：静止时镜像永不产帧、一触摸 6ms 内出帧，日志只有 AcquireBuffer failed）——
 * 首帧未到期间按此周期给镜像 Scroll 一个"虚拟滑动"（见 kickMirrorRepaint）。
 */
const CONTENT_KICK_INTERVAL_MS: number = 100;

/** '#RRGGBB' / '#AARRGGBB' -> 无符号 ARGB（原生 SetTabs 要 uint32）。 */
function hexToArgb(color: string): number {
  const hex: string = color.startsWith('#') ? color.substring(1) : color;
  if (hex.length === 8) {
    return parseInt(hex, 16) >>> 0;
  }
  if (hex.length === 6) {
    return (0xFF000000 | parseInt(hex, 16)) >>> 0;
  }
  return 0xFF000000;
}

/**
 * 玻璃条带高（vp）：底板 + 下边距 + 投影 / 按压留白。
 *
 * 这是 B 形态的**核心几何量**：GL 的 XComponent 只占这一条，镜像树的
 * `NodeContainer` 也裁成这一条 —— 纹理与 surface 1:1，玻璃的全部 pass 都是条带级。
 */
export const GLASS_STRIP_HEIGHT: number = Spacing.xl + BAR_HEIGHT + STRIP_OVERHANG;

/**
 * 采样位移预算（vp，非对称）：面板上沿到纹理上沿 / 面板下沿到纹理下沿的可用余量。
 *
 * = 条带自身留白（上 STRIP_OVERHANG 36 / 下 Spacing.xl 24）+ 镜像条带余量
 * （BAND_EXTRA_TOP/BOTTOM，见 GlassBandModel）− 安全边距（色散采样在面板边缘
 * 会往外偏几个 px）。**必须与原生 `GlassGLSetContentBand` 下发的一致**。
 */
const SHIFT_SAFETY_VP: number = 4;
export const SHIFT_UP_LIMIT_VP: number = STRIP_OVERHANG + BAND_EXTRA_TOP_VP - SHIFT_SAFETY_VP;
export const SHIFT_DOWN_LIMIT_VP: number = Spacing.xl + BAND_EXTRA_BOTTOM_VP - SHIFT_SAFETY_VP;
/**
 * 容器平移的拆分阈值（vp）= 原生预算 − 头寸：采样位移在"预算"内还要额外吃下
 * 1~2 帧的纹理滞后 + 一帧外推，拆分点提前这么多，采样才不会顶到预算被夹。
 *
 * 头寸就是**高速余量**：拆分越小、能容忍的手势速度越高（长下拉 / 大甩时残差超出
 * 拆分、落容器平移，只要 shift ≤ 预算，玻璃仍与内容同帧）；拆分越大，镜像树在
 * 下拉/回弹里重渲染越少。48vp ≈ 单帧 48vp 位移（120Hz 下 ≈ 5760vp/s）已远超手指速度。
 */
const TRANSLATE_HEADROOM_VP: number = 48;
export const TRANSLATE_SPLIT_UP_VP: number = SHIFT_UP_LIMIT_VP - TRANSLATE_HEADROOM_VP;
export const TRANSLATE_SPLIT_DOWN_VP: number = SHIFT_DOWN_LIMIT_VP - TRANSLATE_HEADROOM_VP;
/** 镜像条带总高（vp）：NodeContainer / 镜像树根 Stack 的尺寸（纹理尺寸）。 */
export const GLASS_BAND_HEIGHT: number =
  GLASS_STRIP_HEIGHT + BAND_EXTRA_TOP_VP + BAND_EXTRA_BOTTOM_VP;

/**
 * 系统环境变化的下一帧回调：把"环境已变"转交给 BuilderNode。
 *
 * 官方约定（《应用深浅色适配》"自定义节点适配"）：BuilderNode / ComponentContent
 * **不会**自动跟随系统环境变化（深浅色 / 语言 / 字体缩放），必须手动调
 * `updateConfiguration()` 触发全量更新；且要等新配置落地后再调（下一帧），
 * 否则节点会按旧配置重建。
 */
class ConfigUpdateFrameCallback extends FrameCallback {
  private readonly apply: () => void;

  constructor(apply: () => void) {
    super();
    this.apply = apply;
  }

  onFrame(): void {
    this.apply();
  }
}

// GlassTabContentController was moved to SharedMirrorManager.ets

/**
 * 液态玻璃页签壳（B 形态）：只占底部条带的玻璃层，内容是 ArkUI 直显的。
 *
 * 生命周期：
 *   ① 挂载条带高的 XComponent → 原生起 GL；
 *   ② 拿到镜像纹理 surfaceId 后挂 `NodeContainer`（镜像树导出成条带纹理，**不上屏**）；
 *   ③ 镜像纹理出第一帧 → `GlassGLSetContentBackdrop(true)`：玻璃背景改用实时镜像；
 *      在此之前用 1×1 主题色兜底（`SetBackdrop`）。
 *
 * 主树（可交互内容）由父组件 ArkUI 直显：转场 / 触摸 / 滚动全原生；本壳只盖住
 * 底部条带，不拦截内容区触摸。任何一步超时（GL 起不来 / 镜像没帧）都回调
 * `onUnavailable`，由父组件回退原版页签。
 */
@ComponentV2
export struct GlassTabShell {
  /** 页签壳共享状态（主树与镜像树共用：view model / 选中态 / 滚动偏移 / 视口几何）。 */
  @Require @Param model: GlassTabContentModel;
  /** 当前选中页签（0..2）。父组件是唯一状态源。 */
  @Param selectedIndex: number = 0;
  /** 原生判定页签切换（点击 / 拖动松手）。 */
  @Param onSelect: (index: number) => void = (_index: number): void => {};
  /** 原生不可用 / 镜像纹理起不来，父组件回退原版 ArkUI 页签。 */
  @Param onUnavailable: () => void = (): void => {};
  /** 应用是否在前台（后台暂停绘制）。 */
  @Param foreground: boolean = true;
  /** 页签壳是否可见（push 了子页面时为 false）。 */
  @Param visible: boolean = true;

  /** @Local 包装主题状态：@Monitor 只能监听状态变量（嵌套 @Trace 属性可深度监听）。 */
  @Local private theme: ThemeState = ThemeService.get().state;
  private alive: boolean = true;
  /** 原生渲染线程是否已起来（不参与 UI 刷新，故不用 @Local）。 */
  private ready: boolean = false;
  /** 镜像纹理 surfaceId 是否已拿到（@Local：拿到后才挂 NodeContainer）。 */
  @Local private contentSurfaceId: string = '';

  private readyTimer: number = -1;
  
  private readyCheckStartMs: number = 0;
  /** surfaceId 轮询起点（拿不到 = 原生内容纹理没建起来，超时才回退 ArkUI）。 */
  
  /** 首帧轮询自己的起点：与 surfaceId 轮询分开计时（surfaceId 迟到的场景不误判首帧超时）。 */
  
  /** 首帧等待是否已超时（超时后只降频，不回退，见 CONTENT_READY_TIMEOUT_MS）。 */
  
  /** 上一次催帧时间（见 CONTENT_KICK_INTERVAL_MS）。 */
  
  /** 内容纹理轮询是否已在跑（startContentPoll 幂等用）。 */
  
  private controller: XComponentController = new XComponentController();

  /** 环境变化订阅句柄（经 ThemeService 转发，features 层不直接碰系统能力）。 */
  private readonly configurationListener: () => void = (): void => {
    this.scheduleMirrorConfigUpdate();
  };

  /** 底板下边距（vp）：与普通版页签条（Index 的 BAR_BOTTOM_MARGIN）一致。 */
  private marginV: number = Spacing.xl;
  /** surface 高（vp）= 下边距 + 底板 + 上方留白（与镜像树裁剪高一致）。 */
  private stripHeight: number = GLASS_STRIP_HEIGHT;
  /** 当前条带容器宽度（vp） */
  private cachedContainerWidth: number = 0;

  /** 计算底板水平外留白：宽屏（平板/折叠屏）锁定底板为 258vp 并居中，窄屏保留最小 64vp 留白。 */
  private computeOuterPaddingH(width: number): number {
    if (width <= 0) {
      return MIN_OUTER_PADDING_H;
    }
    const targetBarWidth: number = Math.min(Math.max(width - MIN_OUTER_PADDING_H * 2, 0), BASE_BAR_WIDTH);
    return Math.max((width - targetBarWidth) / 2, MIN_OUTER_PADDING_H);
  }

  /** 同步下发原生外边距 */
  private syncOuterPaddingH(width: number): void {
    if (width <= 0) {
      return;
    }
    this.cachedContainerWidth = width;
    const paddingH: number = this.computeOuterPaddingH(width);
    try {
      GlassGLSetNumber(PID_OUTER_PADDING_H, paddingH);
    } catch (_e) {
      // 容错处理
    }
  }

  aboutToAppear(): void {
    this.alive = true;
    setGlassLeadFrames(GLASS_SURFACE_TYPE === XComponentType.SURFACE ? 0 : 1);

    try {
      const disp = display.getDefaultDisplaySync();
      const screenWidth = px2vp(disp.width);
      const screenHeight = px2vp(disp.height);
      this.cachedContainerWidth = screenWidth;
      SharedMirrorManager.getInstance().registerConsumer(SURFACE_ID, {
        type: 'tabBar',
        viewportRect: { x: 0, y: screenHeight - GLASS_STRIP_HEIGHT, width: screenWidth, height: GLASS_STRIP_HEIGHT } as ViewportRect,
        materialParams: new Map(),
        lagCompensation: true
      } as ConsumerConfig);
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'failed to register consumer: %{public}s', JSON.stringify(e));
    }

    this.applySurfaceConfig();
    this.applyNativeConfig();
    this.setStartupBackdrop();
    this.registerEnvironmentCallback();
    // 就绪自检与内容纹理轮询都不依赖对方的时序：从首帧就开始轮询，
    // 玻璃尽早从 1×1 兜底底色切到实时镜像（旧版等 ready 判定后才开始，白等 ~0.6s）。
    this.readyCheckStartMs = Date.now();
    this.checkNativeReady();
    SharedMirrorManager.getInstance().startPolling(this.model);
  }

  aboutToDisappear(): void {
    this.alive = false;
    
    try {
      SharedMirrorManager.getInstance().unregisterConsumer(SURFACE_ID);
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'failed to unregister consumer: %{public}s', JSON.stringify(e));
    }
    
    this.clearTimers();
    this.unregisterEnvironmentCallback();
    SharedMirrorManager.getInstance().stopPolling();
    // 先停渲染线程（join）再拆 BuilderNode：渲染线程每帧都在消费 OH_NativeImage，
    // 生产端先被 dispose 的话两边会互相等 —— 关闭液态玻璃页签时卡死的根因就是
    // 这个顺序（旧代码 dispose 在前、unbind 由 XComponent 卸载时才发生）。
    hilog.info(DOMAIN, TAG, 'teardown: stop render thread');
    try {
      GlassGLUnbindNode(SURFACE_ID);
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'UnbindNode failed: %{public}s', JSON.stringify(err));
    }
    hilog.info(DOMAIN, TAG, 'teardown: dispose mirror tree');
    SharedMirrorManager.getInstance().controller.dispose();

    this.contentSurfaceId = '';
    try {
      GlassGLUnregisterTabCallback();
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'teardown failed: %{public}s', JSON.stringify(err));
    }
    hilog.info(DOMAIN, TAG, 'teardown: done');
  }

  /**
   * surface 必须按"带透明"合成：内容纹理还没接管时页签条以外的透明像素不能压成黑带
   * （表层 alpha 被忽略）。`setXComponentSurfaceConfig` 是 API 22+ 接口，
   * 老 ROM 上不存在 —— try/catch 掉，此时靠原生侧把窗口格式设成 RGBA 兜底。
   */
  private applySurfaceConfig(): void {
    try {
      this.controller.setXComponentSurfaceConfig({ isOpaque: false });
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'setXComponentSurfaceConfig unavailable: %{public}s',
        JSON.stringify(err));
    }
  }

  private clearTimers(): void {
    if (this.readyTimer !== -1) {
      clearTimeout(this.readyTimer);
      this.readyTimer = -1;
    }
  }

  /** 外部（父组件）切换选中页签：同步给原生指示器，弹簧跟过去。 */
  @Monitor('selectedIndex')
  private onSelectedIndexChange(): void {
    if (!this.ready) {
      return;
    }
    try {
      GlassGLSetSelectedTab(this.selectedIndex);
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'SetSelectedTab failed: %{public}s', JSON.stringify(err));
    }
  }

  @Monitor('foreground', 'visible')
  private onVisibilityChange(): void {
    this.syncPaused();
  }

  @Monitor('theme.themeId', 'theme.isDark', 'theme.primary')
  private onThemeChange(): void {
    this.applyThemeConfig();
    this.applyTabConfig();
  }

  /** 页面不可见（后台 / 被覆盖）时暂停绘制，省电；恢复时自动补一帧。 */
  private syncPaused(): void {
    if (!this.ready) {
      return;
    }
    const paused: boolean = !(this.foreground && this.visible);
    try {
      GlassGLSetPaused(paused);
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'SetPaused failed: %{public}s', JSON.stringify(err));
    }
  }

  /**
   * 监听系统环境变化（深浅色 / 语言 / 字体缩放）。
   *
   * BuilderNode 镜像树不在 ArkUI 的自动刷新链路上，必须手动转交（见
   * ConfigUpdateFrameCallback）；应用自己 setColorMode 也会触发该广播。
   */
  private registerEnvironmentCallback(): void {
    ThemeService.get().onConfigurationChanged(this.configurationListener);
  }

  private unregisterEnvironmentCallback(): void {
    ThemeService.get().offConfigurationChanged(this.configurationListener);
  }

  /** 新配置落地后的下一帧再通知镜像树：早于配置生效调用会按旧配置重建。 */
  private scheduleMirrorConfigUpdate(): void {
    if (!this.alive) {
      return;
    }
    this.getUIContext().postFrameCallback(new ConfigUpdateFrameCallback((): void => {
      if (!this.alive) {
        return;
      }
      try {
        hilog.info(DOMAIN, TAG, 'environment changed -> mirror updateConfiguration');
        SharedMirrorManager.getInstance().controller.updateConfiguration();
      } catch (err) {
        hilog.warn(DOMAIN, TAG, 'mirror updateConfiguration failed: %{public}s',
          JSON.stringify(err));
      }
    }));
  }

  // ===== 原生接线 =====

  private applyNativeConfig(): void {
    try {
      GlassGLSetDensity(this.getUIContext().vp2px(1));
      GlassGLSetScene(0);                                  // 0 = 玻璃页签条
      GlassGLSetOverlayMode(true);                         // 透明 surface，只画页签条
      GlassGLSetDemoChrome(false);                         // 关掉 demo 的三按钮 / 浮动件 / 照片滚动
      GlassGLSetPaused(false);
      GlassGLSetContentBackdrop(false);                    // 内容纹理就绪后再打开
      // 镜像条带余量 + 采样位移预算：原生按它分配内容纹理（比 surface 高）、
      // 算背景采样的纹理坐标映射与非对称夹取。模型侧用更保守的拆分阈值
      // （预留纹理滞后 + 一帧外推的头寸），见 TRANSLATE_SPLIT_UP/DOWN_VP。
      GlassGLSetContentBand(BAND_EXTRA_TOP_VP, BAND_EXTRA_BOTTOM_VP,
        SHIFT_UP_LIMIT_VP, SHIFT_DOWN_LIMIT_VP);
      this.model.band.setShiftLimits(TRANSLATE_SPLIT_UP_VP, TRANSLATE_SPLIT_DOWN_VP);
      GlassGLSetNumber(PID_BAR_HEIGHT, BAR_HEIGHT);        // 底板高：对齐内容尾部避让（Sizes.tabBar）
      GlassGLSetNumber(PID_PANEL_CORNER_RADIUS, PANEL_CORNER_RADIUS); // 底板圆角
      GlassGLSetNumber(PID_INDICATOR_HEIGHT, INDICATOR_HEIGHT); // 指示器：与底板同步留白
      GlassGLSetNumber(PID_LABEL_FONT_SIZE, LABEL_FONT_SIZE);   // 字号：对齐 ArkUI 版页签条
      GlassGLSetNumber(PID_TAB_ICON_SIZE, TAB_ICON_SIZE);       // 图标尺寸（pid 83）
      GlassGLSetNumber(PID_TAB_ICON_SIZE_ACCENT, TAB_ICON_SIZE_ACCENT);       // 指示器内的图标
      GlassGLSetNumber(PID_LABEL_FONT_SIZE_ACCENT, LABEL_FONT_SIZE_ACCENT);   // 指示器内的字号
      GlassGLSetNumber(PID_LABEL_UNSELECTED_ALPHA, LABEL_UNSELECTED_ALPHA);
      // 底座材质（调参定稿值，原生默认见 glass_params.cpp）
      GlassGLSetNumber(PID_BLUR_RADIUS, BLUR_RADIUS);
      GlassGLSetNumber(PID_REFRACTION_HEIGHT, REFRACTION_HEIGHT);
      GlassGLSetNumber(PID_REFRACTION_AMOUNT, REFRACTION_AMOUNT);
      GlassGLSetNumber(PID_CONTAINER_ALPHA, CONTAINER_ALPHA);
      GlassGLSetNumber(PID_PRESS_GROWTH, PRESS_GROWTH);
      GlassGLSetNumber(PID_GLOW_FLAT, GLOW_FLAT);
      GlassGLSetNumber(PID_GLOW_RADIAL, GLOW_RADIAL);
      GlassGLSetNumber(PID_GLOW_RADIUS_FACTOR, GLOW_RADIUS_FACTOR);
      GlassGLSetNumber(PID_HIGHLIGHT_WIDTH, HIGHLIGHT_WIDTH);
      // 指示器·静止 / 拖动
      GlassGLSetNumber(PID_INDICATOR_TINT_REST, INDICATOR_TINT_REST);
      GlassGLSetNumber(PID_INDICATOR_SHADOW_REST, INDICATOR_SHADOW_REST);
      GlassGLSetNumber(PID_INDICATOR_REFRACTION_HEIGHT_DRAG, INDICATOR_REFRACTION_HEIGHT_DRAG);
      GlassGLSetNumber(PID_INDICATOR_REFRACTION_AMOUNT_DRAG, INDICATOR_REFRACTION_AMOUNT_DRAG);
      GlassGLSetNumber(PID_INDICATOR_SHADOW_DRAG, 0);           // 不再使用：按压态投影已改为原生写死的"贴边投影"（更弱）
      // 按压态材质走 demo 默认（白光 / 折射 / tint / 表面白都不覆写），只调这几处：
      GlassGLSetNumber(PID_PRESSED_SCALE, PRESSED_SCALE);
      GlassGLSetNumber(PID_PRESSED_SCALE_X, PRESSED_SCALE_X);
      GlassGLSetNumber(PID_PRESS_SAMPLE_SHRINK, PRESS_SAMPLE_SHRINK);
      GlassGLSetNumber(PID_PRESS_LABEL_SCALE, PRESS_LABEL_SCALE);
      GlassGLSetNumber(PID_INDICATOR_HIGHLIGHT_DRAG, HIGHLIGHT_DRAG);
      GlassGLSetNumber(PID_INDICATOR_INNER_SHADOW_RADIUS_DRAG, INNER_SHADOW_RADIUS_DRAG);
      GlassGLSetNumber(PID_INDICATOR_INNER_SHADOW_ALPHA_DRAG, INNER_SHADOW_ALPHA_DRAG);
      // 底座投影（surface 上方留白按它算，见 STRIP_OVERHANG）
      GlassGLSetNumber(PID_SHADOW_BLUR, SHADOW_BLUR);
      GlassGLSetNumber(PID_SHADOW_OFFSET, SHADOW_OFFSET);
      GlassGLSetNumber(PID_SHADOW_ALPHA, SHADOW_ALPHA);
      // 按压态投影：大范围 / 更弱 / 更散（原生按按压进度与常态值插值）
      GlassGLSetNumber(PID_SHADOW_BLUR_PRESS, SHADOW_BLUR_PRESS);
      GlassGLSetNumber(PID_SHADOW_ALPHA_PRESS, SHADOW_ALPHA_PRESS);
      GlassGLSetNumber(PID_OUTER_PADDING_V, this.marginV);
      GlassGLSetNumber(PID_OUTER_PADDING_H, this.computeOuterPaddingH(this.cachedContainerWidth));   // 左右外距：大屏居中钳位258vp，窄屏自适应
      GlassGLSetNumber(PID_BACKGROUND_SCROLL_RANGE, 1);    // 背景 1:1 铺满
      this.applyThemeConfig();                             // 深浅色分侧（表面填充色 / 胶囊底色…）
      this.applyTabConfig();
      GlassGLRegisterTabCallback((index: number): void => {
        hilog.info(DOMAIN, TAG, 'native tab change -> %{public}d', index);
        if (this.alive) {
          this.onSelect(index);
        }
      });
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'apply native config failed: %{public}s', JSON.stringify(err));
      this.onUnavailable();
    }
  }

  /**
   * 深浅色分侧的材质参数：玻璃的"表面填充色"（id 84..86）+ 未选中字透明度 +
   * 指示器静止底色 / 表面白。
   */
  private applyThemeConfig(): void {
    const dark: boolean = this.theme.isDark;
    try {
      GlassGLSetNumber(PID_SURFACE_COLOR_R, dark ? SURFACE_DARK_R : SURFACE_LIGHT_R);
      GlassGLSetNumber(PID_SURFACE_COLOR_G, dark ? SURFACE_DARK_G : SURFACE_LIGHT_G);
      GlassGLSetNumber(PID_SURFACE_COLOR_B, dark ? SURFACE_DARK_B : SURFACE_LIGHT_B);
      GlassGLSetNumber(PID_LABEL_UNSELECTED_ALPHA,
        dark ? LABEL_UNSELECTED_ALPHA_DARK : LABEL_UNSELECTED_ALPHA);
      GlassGLSetNumber(PID_INDICATOR_TINT_REST,
        dark ? INDICATOR_TINT_REST_DARK : INDICATOR_TINT_REST);
      // 按压 / 拖动：浅色保留一点选中底色，深色仍淡出为 0（纯黑胶囊换成玻璃透镜）
      GlassGLSetNumber(PID_INDICATOR_TINT_DRAG,
        dark ? INDICATOR_TINT_DRAG_DARK : INDICATOR_TINT_DRAG_LIGHT);
      // 深色：静态纯黑胶囊；浅色：不画（0/0），仍是玻璃透镜
      GlassGLSetNumber(PID_INDICATOR_FILL_REST, dark ? INDICATOR_FILL_REST_DARK : 0);
      GlassGLSetNumber(PID_INDICATOR_FILL_DRAG, dark ? INDICATOR_FILL_DRAG_DARK : 0);
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'apply theme config failed: %{public}s', JSON.stringify(err));
    }
  }

  /** 文案（走资源多语言）+ 图标 path + 选中/未选中颜色，交给原生栅格化。 */
  private applyTabConfig(): void {
    const context = this.getUIContext().getHostContext();
    if (context === undefined) {
      return;
    }
    const resMgr = context.resourceManager;
    try {
      const labels: string[] = [
        resMgr.getStringSync($r('app.string.tab_vault').id),
        resMgr.getStringSync($r('app.string.tab_generator').id),
        resMgr.getStringSync($r('app.string.tab_settings').id)
      ];
      const unselected: number =
        hexToArgb(this.theme.isDark ? TAB_UNSELECTED_DARK : TAB_UNSELECTED_LIGHT);
      const selected: number = hexToArgb(this.theme.primary);
      GlassGLSetTabs(labels, GlassTabIcons.PATHS, selected, unselected);
      GlassGLSetSelectedTab(this.selectedIndex);
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'SetTabs failed: %{public}s', JSON.stringify(err));
    }
  }

  /**
   * 启动底图：1×1 的主题背景色。内容纹理接管前玻璃也有正确底色，
   * 不会先闪一帧原生缺省深灰（`SetBackdrop` 与照片同一条纹理通路）。
   */
  private setStartupBackdrop(): void {
    const context = this.getUIContext().getHostContext();
    if (context === undefined) {
      return;
    }
    try {
      const argb: number =
        context.resourceManager.getColorSync($r('app.color.system_background').id) >>> 0;
      const buffer: ArrayBuffer = new ArrayBuffer(4);
      const view: Uint8Array = new Uint8Array(buffer);
      view[0] = (argb >>> 16) & 0xFF;
      view[1] = (argb >>> 8) & 0xFF;
      view[2] = argb & 0xFF;
      view[3] = (argb >>> 24) & 0xFF;
      GlassGLSetBackdrop(buffer, 1, 1, 4);
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'startup backdrop failed: %{public}s', JSON.stringify(err));
    }
  }

  /** 就绪自检（50ms 轮询，总预算 READY_CHECK_TIMEOUT_MS，超时才回退 ArkUI 页签）。 */
  private checkNativeReady(): void {
    if (!this.alive) {
      return;
    }
    let running: boolean = false;
    try {
      running = GlassGLIsRunning();
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'IsRunning failed: %{public}s', JSON.stringify(err));
    }
    if (running) {
      this.ready = true;
      this.applyTabConfig();
      this.syncPaused();
      hilog.info(DOMAIN, TAG, 'glass shell ready');
      return;
    }
    if (Date.now() - this.readyCheckStartMs >= READY_CHECK_TIMEOUT_MS) {
      hilog.warn(DOMAIN, TAG, 'glass renderer not running, fall back to ArkUI tabs');
      this.onUnavailable();
      return;
    }
    this.readyTimer = setTimeout(() => {
      this.checkNativeReady();
    }, READY_CHECK_INTERVAL_MS);
  }

  build() {
    Stack() {


      XComponent({
        id: SURFACE_ID,
        // 类型见 GLASS_SURFACE_TYPE。SURFACE 也逐像素尊重 alpha，前提是下面的透明背景色
        // （旧版"SURFACE 透明区域被压成黑带"就是缺了它）。
        type: GLASS_SURFACE_TYPE,
        libraryname: SURFACE_LIBRARY,
        controller: this.controller
      })
        .width('100%')
        .height('100%')
        // SURFACE 型的 surface 默认铺黑底，组件设了非黑背景色时系统才把 surface 底色改成透明
        .backgroundColor(Color.Transparent)
    }
    .width('100%')
    .height(this.stripHeight)
    .visibility(this.visible ? Visibility.Visible : Visibility.Hidden)
    .onAreaChange((_oldValue: Area, newValue: Area) => {
      const newWidth: number = Number(newValue.width);
      if (newWidth > 0 && Math.abs(newWidth - this.cachedContainerWidth) > 1) {
        this.syncOuterPaddingH(newWidth);
      }
    })
  }
}
