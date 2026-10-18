import { GlassBandModel, BAND_EXTRA_TOP_VP, BAND_EXTRA_BOTTOM_VP } from './GlassBandModel';
import { window } from '@kit.ArkUI';
import { BuilderNode, FrameNode, NodeController, NodeRenderType, UIContext } from '@kit.ArkUI';
import { GlassTabContentModel, GLASS_TAB_MIRROR } from './GlassTabContent';
import { MirrorRouter } from '../mirror/MirrorRouter';

// NAPI bindings import
import backdrop from 'libbackdrop.so';

export interface ViewportRect { x: number; y: number; width: number; height: number; }

export interface ConsumerConfig {
  type: 'tabBar' | 'genericGlass';
  viewportRect: ViewportRect;
  materialParams: Map<number, number>;
  lagCompensation: boolean;
}

@ObservedV2
export class SharedMirrorManager {
  // State for polling
  private contentPollStartMs: number = 0;
  private contentPollTimer: number = -1;
  private contentFramePollStartMs: number = 0;
  private lastKickMs: number = 0;
  private contentPastTimeout: boolean = false;
  private pollingModel: GlassTabContentModel | null = null;

  startPolling(model: GlassTabContentModel): void {
    this.stopPolling();
    this.pollingModel = model;
    model.exportLayoutListener = (heightVp: number): void => {
      this.onMirrorExportLayout(heightVp);
    };
    // 子页面压栈 / 出栈：镜像换页，导出尺寸按新页面视口重算；回到页签时重推页签偏移
    MirrorRouter.get().setTopListener((): void => {
      this.applyExport();
    });
    MirrorRouter.get().setTabsResync((): void => {
      model.band.resync();
    });
    this.applyExport();
    this.pollContentSurfaceId();
  }

  stopPolling(): void {
    if (this.contentPollTimer !== -1) {
      clearTimeout(this.contentPollTimer);
      this.contentPollTimer = -1;
    }
    if (this.pollingModel !== null) {
      this.pollingModel.exportLayoutListener = null;
      MirrorRouter.get().setTopListener(null);
      MirrorRouter.get().setTabsResync(null);
    }
    this.pollingModel = null;
    this.contentPollStartMs = 0;
    this.contentFramePollStartMs = 0;
    this.lastKickMs = 0;
    this.contentPastTimeout = false;
    this.isReady = false;
    try {
      backdrop.GlassGLSetContentBackdrop(false);
    } catch (err) {}
  }

  private pollContentSurfaceId(): void {
    if (this.contentPollStartMs === 0) {
      this.contentPollStartMs = Date.now();
    }
    let id: string = '';
    try {
      id = backdrop.GlassGLGetContentSurfaceId();
    } catch (err) {}
    
    if (id.length > 0) {
      this.setSurfaceId(id);
      if (this.pollingModel) {
        this.controller.setModel(this.pollingModel);
      }
      // NodeContainer 首次出现时 makeNode() 因 surfaceId 为空返回了 null，
      // 现在两个前置条件（surfaceId + model）都齐了，必须 rebuild 重触发 makeNode。
      this.controller.rebuild();
      this.pollContentFrame();
      return;
    }
    
    if (Date.now() - this.contentPollStartMs > 3000) {
      return;
    }
    this.contentPollTimer = setTimeout(() => {
      this.pollContentSurfaceId();
    }, 16);
  }

  private pollContentFrame(): void {
    let hasFrame: boolean = false;
    try {
      hasFrame = backdrop.GlassGLHasContentFrame();
    } catch (err) {}
    
    if (hasFrame) {
      if (this.pollingModel) {
        this.pollingModel.band.clearNudge();
      }
      try {
        backdrop.GlassGLSetContentBackdrop(true);
      } catch (err) {}
      return;
    }
    
    const now: number = Date.now();
    if (this.contentFramePollStartMs === 0) {
      this.contentFramePollStartMs = now;
      this.lastKickMs = now;
    }
    
    if (!this.contentPastTimeout && now - this.lastKickMs >= 100) {
      this.lastKickMs = now;
      if (this.pollingModel) {
        this.pollingModel.band.nudge = this.pollingModel.band.nudge === 1 ? -1 : 1;
        this.pollingModel.band.requestAlign();
      }
    }
    
    if (!this.contentPastTimeout && now - this.contentFramePollStartMs >= 3000) {
      this.contentPastTimeout = true;
    }
    
    this.contentPollTimer = setTimeout(() => {
      this.pollContentFrame();
    }, this.contentPastTimeout ? 250 : 16);
  }

  private static instance: SharedMirrorManager;
  
  @Trace isReady: boolean = false;
  @Trace nudgePadding: number = 0;
  
  readonly band: GlassBandModel = new GlassBandModel();
  controller: GlassTabContentController = new GlassTabContentController();

  static getInstance(): SharedMirrorManager {
    if (!SharedMirrorManager.instance) {
      SharedMirrorManager.instance = new SharedMirrorManager();
    }
    return SharedMirrorManager.instance;
  }

  // ===== 整屏消费者（玻璃弹窗 / 以后的悬浮玻璃按钮）=====
  //
  // 镜像平时只导出页签条带；有整屏消费者时放开到整页（P0 实测：整屏全分辨率导出约 +12% GPU、
  // +1.2pt CPU），全部释放后收回条带。原生中枢据此把每帧内容另发布到共享纹理，
  // 消费者渲染器在同一 share group 里直接采样（见 backdrop shared_backdrop.h）。

  private fullscreenRefs: number = 0;
  private coverageProbe: (() => boolean) | null = null;

  /**
   * 镜像内容 == 屏幕内容的判定（Index 登记）：镜像树只有三个页签页，
   * 压了 Navigation 子页面 / 玻璃页签没在跑时，镜像里不是用户眼前的画面，消费者应回退快照。
   */
  setCoverageProbe(probe: (() => boolean) | null): void {
    this.coverageProbe = probe;
  }

  /** 镜像里当前那一页的滚动同步模型（栈顶子页面优先，否则页签）。 */
  private activeBand(model: GlassTabContentModel): GlassBandModel {
    const top: GlassBandModel | null = MirrorRouter.get().activeBand();
    return top !== null ? top : model.band;
  }

  /** 当前能否给整屏消费者提供实时背景。 */
  canServeLive(): boolean {
    if (!this.isReady || this.pollingModel === null ||
      this.activeBand(this.pollingModel).viewportHeight <= 0) {
      return false;
    }
    if (this.coverageProbe !== null && !this.coverageProbe()) {
      return false;
    }
    try {
      return backdrop.GlassGLSharedBackdropReady();
    } catch (err) {
      return false;
    }
  }

  acquireFullscreen(): void {
    this.fullscreenRefs += 1;
    if (this.fullscreenRefs === 1) {
      this.applyExport();
    }
  }

  releaseFullscreen(): void {
    if (this.fullscreenRefs === 0) {
      return;
    }
    this.fullscreenRefs -= 1;
    if (this.fullscreenRefs === 0) {
      this.applyExport();
    }
  }

  /** 改镜像的导出高度（只动布局；原生等 onMirrorExportLayout 布局完成再下发）。 */
  private applyExport(): void {
    const model: GlassTabContentModel | null = this.pollingModel;
    if (model === null) {
      return;
    }
    const band: GlassBandModel = this.activeBand(model);
    const full: boolean = this.fullscreenRefs > 0 && band.viewportHeight > 0;
    model.exportExtraTopVp = full ?
      Math.max(BAND_EXTRA_TOP_VP, band.viewportHeight - model.bandHeight) : BAND_EXTRA_TOP_VP;
  }

  /** 镜像根容器布局完成：按实际导出高度下发原生（之后到来的内容帧即新尺寸）。 */
  private onMirrorExportLayout(heightVp: number): void {
    const model: GlassTabContentModel | null = this.pollingModel;
    if (model === null || heightVp <= 0) {
      return;
    }
    const extraTop: number = heightVp - model.bandHeight - BAND_EXTRA_BOTTOM_VP;
    try {
      // 与条带余量相同 = 收回条带（原生按 -1 处理，不做整幅发布用的裁剪换算）
      backdrop.GlassGLSetContentExport(Math.abs(extraTop - BAND_EXTRA_TOP_VP) < 0.5 ? -1 : extraTop);
    } catch (err) {}
  }

  /**
   * 整屏导出纹理在窗口里的矩形（px）：镜像按整页布局（见 GlassTabMirror），纹理 = 页面盒 + 下余量，
   * 行 0 = 页面盒上沿（主树 onAreaChange 实测上报）。
   */
  liveRectWindowPx(uiContext: UIContext): ViewportRect | null {
    const model: GlassTabContentModel | null = this.pollingModel;
    if (model === null) {
      return null;
    }
    const band: GlassBandModel = this.activeBand(model);
    if (band.viewportHeight <= 0) {
      return null;
    }
    try {
      const root = uiContext.getComponentUtils().getRectangleById('mainNavigation');
      if (root.size.width <= 0 || root.size.height <= 0) {
        return null;
      }
      const pageHeightPx: number = uiContext.vp2px(band.viewportHeight);
      const bottomPx: number = root.windowOffset.y + root.size.height;
      return {
        x: root.windowOffset.x,
        // 优先用主树页面盒的实测上沿；未上报时退回"底边贴 Navigation 根底边"的旧推算
        y: band.viewportTop >= 0 ? uiContext.vp2px(band.viewportTop) : bottomPx - pageHeightPx,
        width: root.size.width,
        height: uiContext.vp2px(band.viewportHeight + BAND_EXTRA_BOTTOM_VP)
      };
    } catch (err) {
      return null;
    }
  }

  registerConsumer(id: string, config: ConsumerConfig): void {
    backdrop.GlassGLRegisterConsumer(id, config.type, config.viewportRect, config.lagCompensation);
  }

  unregisterConsumer(id: string): void {
    backdrop.GlassGLUnregisterConsumer(id);
  }

  setSurfaceId(id: string): void {
    this.controller.setSurfaceId(id);
    this.isReady = true;
    this.kickMirrorRepaint();
  }

  kickMirrorRepaint(): void {
    this.nudgePadding = this.nudgePadding === 0 ? 1 : 0;
  }
}

export class GlassTabContentController extends NodeController {
  private surfaceId: string = '';
  private model: GlassTabContentModel | null = null;
  private root: BuilderNode<[GlassTabContentModel]> | null = null;

  setSurfaceId(id: string): void {
    if (this.surfaceId !== id) {
      this.surfaceId = id;
      if (this.root !== null) {
        this.root.dispose();
        this.root = null;
      }
    }
  }

  setModel(model: GlassTabContentModel): void {
    this.model = model;
  }

  makeNode(uiContext: UIContext): FrameNode | null {
    if (this.root === null && this.surfaceId.length > 0 && this.model !== null) {
      this.root = new BuilderNode<[GlassTabContentModel]>(uiContext, {
        type: NodeRenderType.RENDER_TYPE_TEXTURE,
        surfaceId: this.surfaceId
      });
      this.root.build(GLASS_TAB_MIRROR, this.model, { enableProvideConsumeCrossing: true });
    }
    return this.root !== null ? this.root.getFrameNode() : null;
  }

  updateConfiguration(): void {
    if (this.root !== null) {
      this.root.updateConfiguration();
    }
  }

  dispose(): void {
    this.surfaceId = '';
    if (this.root !== null) {
      this.root.dispose();
      this.root = null;
    }
    this.rebuild();
  }
}
