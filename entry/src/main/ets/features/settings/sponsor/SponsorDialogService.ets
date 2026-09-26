/*
 * SPDX-FileCopyrightText: 2026 Liugt
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import { common } from '@kit.AbilityKit';
import { iap } from '@kit.IAPKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import {
  SponsorState,
  SponsorTierId,
  SponsorDisplayTier,
  SPONSOR_TIERS,
  SponsorTierConfig
} from './SponsorModel';
import { SponsorService } from './SponsorService';

const DOMAIN: number = 0x0000;
const TAG: string = 'HallPass_SponsorDialogSvc';

@ObservedV2
export class SponsorDialogService {
  private static instance: SponsorDialogService | null = null;

  public static get(): SponsorDialogService {
    if (!SponsorDialogService.instance) {
      SponsorDialogService.instance = new SponsorDialogService();
    }
    return SponsorDialogService.instance;
  }

  /** 宿主组件显隐控制（全屏 scrim 遮罩） */
  @Trace visible: boolean = false;
  /** 当前业务状态机 */
  @Trace sponsorState: SponsorState = SponsorState.IDLE;
  /** 档位展示列表 */
  @Trace sponsorTiers: SponsorDisplayTier[] = [];
  /** 当前选中的档位 ID（默认第 1 档） */
  @Trace selectedTierId: SponsorTierId = SponsorTierId.ONE;
  /** 错误文案提示 */
  @Trace errorMessage: ResourceStr = '';

  /**
   * 打开赞助弹窗（Promise.all 并发检查环境与商品）
   */
  async open(context: common.UIAbilityContext): Promise<void> {
    if (this.visible) {
      return;
    }
    this.visible = true;
    this.sponsorState = SponsorState.LOADING;
    this.errorMessage = '';
    this.selectedTierId = SponsorTierId.ONE;

    // 默认展示兜底本地档位
    this.sponsorTiers = SPONSOR_TIERS.map((cfg: SponsorTierConfig): SponsorDisplayTier => ({
      config: cfg,
      priceText: cfg.defaultPrice,
      name: '',
      isValid: true
    }));

    // 并发执行：环境探测 + 商品信息拉取
    const envPromise = SponsorService.get().checkEnvironment(context);
    const prodPromise = SponsorService.get().queryProducts(context);
    const results = await Promise.all([envPromise, prodPromise]);
    if (!this.visible) {
      return;
    }
    const envCode: number = results[0];
    const productMap: Map<string, iap.Product> = results[1];

    // 1. 服务地不支持判断
    if (envCode === iap.IAPErrorCode.ACCOUNT_TERRITORY_NOT_SUPPORTED) {
      this.sponsorState = SponsorState.UNSUPPORTED;
      return;
    }

    // 2. 装配商品与有效性校验：若从线上成功匹配到商品则以线上为准，未配置时使用本地兜底
    this.sponsorTiers = SPONSOR_TIERS.map((cfg: SponsorTierConfig): SponsorDisplayTier => {
      const liveProd = productMap.get(cfg.productId);
      const isOk = liveProd ? liveProd.status === iap.ProductStatus.VALID : true;
      return {
        config: cfg,
        priceText: liveProd?.localPrice ?? cfg.defaultPrice,
        name: liveProd?.name ?? '',
        isValid: isOk
      };
    });

    if (envCode !== 0) {
      hilog.warn(DOMAIN, TAG, `IAP environment returned non-zero code: ${envCode}`);
      this.sponsorState = SponsorState.READY;
      this.errorMessage = this.mapErrorMessage(envCode);
      return;
    }

    this.sponsorState = SponsorState.READY;
  }

  /**
   * 执行赞助支付（发货强校验 + 幂等识别）
   */
  async executeSponsor(context: common.UIAbilityContext): Promise<void> {
    if (this.sponsorState !== SponsorState.READY) {
      return;
    }
    const currentTier = this.sponsorTiers.find((t: SponsorDisplayTier) => t.config.id === this.selectedTierId);
    if (!currentTier || !currentTier.isValid) {
      return;
    }

    this.sponsorState = SponsorState.PURCHASING;
    this.errorMessage = '';

    try {
      const rawData = await SponsorService.get().createPurchase(context, currentTier.config.productId);
      this.sponsorState = SponsorState.DELIVERING;

      // 强校验解析（F-02: 若解析失败直接标记 ERROR，绝不误判成功）
      const payload = SponsorService.get().parsePurchaseOrder(rawData);
      if (!payload || !payload.purchaseToken || !payload.purchaseOrderId) {
        hilog.error(DOMAIN, TAG, 'Payload verification failed. Aborting finishPurchase.');
        this.sponsorState = SponsorState.ERROR;
        this.errorMessage = $r('app.string.sponsor_err_payload_invalid');
        return;
      }

      // 执行发货确认
      const finished = await SponsorService.get().finishPurchase(context, payload.purchaseToken, payload.purchaseOrderId);
      if (finished) {
        this.sponsorState = SponsorState.SUCCESS;
      } else {
        this.sponsorState = SponsorState.ERROR;
        this.errorMessage = $r('app.string.sponsor_err_general');
      }
    } catch (err) {
      const bErr = err as BusinessError;
      hilog.error(DOMAIN, TAG, `executeSponsor error: ${bErr.code} - ${bErr.message}`);

      if (bErr.code === iap.IAPErrorCode.USER_CANCELED) {
        // 用户取消，平静重置
        this.sponsorState = SponsorState.READY;
      } else if (bErr.code === iap.IAPErrorCode.PRODUCT_OWNED) {
        // 发现未发货拥有，原地触发补单
        await SponsorService.get().recoverUnfinishedPurchases(context);
        this.sponsorState = SponsorState.SUCCESS;
      } else {
        this.sponsorState = SponsorState.ERROR;
        this.errorMessage = this.mapErrorMessage(bErr.code);
      }
    }
  }

  /**
   * 强制收起并重置（用于外部生命周期事件，如锁屏、登出、体验模式迁移）
   */
  dismiss(): void {
    this.visible = false;
    this.sponsorState = SponsorState.IDLE;
    this.errorMessage = '';
  }

  /**
   * 返回手势消费
   */
  handleBack(): boolean {
    if (!this.visible) {
      return false;
    }
    // 若在支付中或发货中，不消费返回手势，防止用户在关键事务中误触
    if (this.sponsorState === SponsorState.PURCHASING || this.sponsorState === SponsorState.DELIVERING) {
      return true;
    }
    this.dismiss();
    return true;
  }

  private mapErrorMessage(code: number): ResourceStr {
    switch (code) {
      case 1001860002:
        return $r('app.string.sponsor_err_not_authorized');
      case iap.IAPErrorCode.ACCOUNT_NOT_LOGGED_IN:
        return $r('app.string.sponsor_err_account_not_logged_in');
      case iap.IAPErrorCode.NETWORK_ERROR:
        return $r('app.string.sponsor_err_network');
      case iap.IAPErrorCode.FREQUENT_CALLS:
        return $r('app.string.sponsor_err_frequent');
      case iap.IAPErrorCode.USER_NOT_ALLOWED:
        return $r('app.string.sponsor_err_user_not_allowed');
      default:
        return $r('app.string.sponsor_err_general');
    }
  }
}
