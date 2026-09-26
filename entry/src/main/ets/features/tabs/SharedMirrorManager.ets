import { GlassBandModel } from './GlassBandModel';
import { window } from '@kit.ArkUI';
import { BuilderNode, FrameNode, NodeController, NodeRenderType, UIContext } from '@kit.ArkUI';
import { GlassTabContentModel, GLASS_TAB_MIRROR } from './GlassTabContent';

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
    this.pollContentSurfaceId();
  }

  stopPolling(): void {
    if (this.contentPollTimer !== -1) {
      clearTimeout(this.contentPollTimer);
      this.contentPollTimer = -1;
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
