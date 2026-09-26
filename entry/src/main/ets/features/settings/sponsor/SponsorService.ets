/*
 * SPDX-FileCopyrightText: 2026 Liugt
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import { iap } from '@kit.IAPKit';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { buffer } from '@kit.ArkTS';
import { SPONSOR_TIERS, SponsorTierConfig, PurchaseOrderPayload } from './SponsorModel';
import { ServiceLocator } from '../../../application/ServiceLocator';

const DOMAIN: number = 0x0000;
const TAG: string = 'HallPass_Sponsor';
const PREF_KEY_PROCESSED_ORDERS: string = 'sponsorProcessedOrders';
const MAX_PROCESSED_CACHE: number = 20;

export class SponsorService {
  private static instance: SponsorService | null = null;
  /** 内存 O(1) 防重集合 */
  private processedOrderIds: Set<string> = new Set<string>();
  private cacheLoaded: boolean = false;

  public static get(): SponsorService {
    if (!SponsorService.instance) {
      SponsorService.instance = new SponsorService();
    }
    return SponsorService.instance;
  }

  /**
   * 检查用户当前环境是否支持 IAP 服务
   */
  async checkEnvironment(context: common.UIAbilityContext): Promise<number> {
    try {
      await iap.queryEnvironmentStatus(context);
      hilog.info(DOMAIN, TAG, 'IAP environment is valid.');
      return 0;
    } catch (err) {
      const bErr: BusinessError = err as BusinessError;
      hilog.error(DOMAIN, TAG, `queryEnvironmentStatus error: ${bErr.code} - ${bErr.message}`);
      return bErr.code;
    }
  }

  /**
   * 查询 AGC 配置的商品实际价格与生效状态
   */
  async queryProducts(context: common.UIAbilityContext): Promise<Map<string, iap.Product>> {
    const productMap = new Map<string, iap.Product>();
    const productIds: string[] = SPONSOR_TIERS.map((tier: SponsorTierConfig) => tier.productId);

    try {
      const param: iap.QueryProductsParameter = {
        productType: iap.ProductType.CONSUMABLE,
        productIds: productIds
      };
      const products: Array<iap.Product> = await iap.queryProducts(context, param);
      for (const p of products) {
        productMap.set(p.id, p);
      }
      hilog.info(DOMAIN, TAG, `queryProducts success, loaded: ${products.length}`);
    } catch (err) {
      const bErr: BusinessError = err as BusinessError;
      hilog.error(DOMAIN, TAG, `queryProducts failed: ${bErr.code} - ${bErr.message}`);
    }
    return productMap;
  }

  /**
   * 拉起系统收银台发起购买
   */
  async createPurchase(context: common.UIAbilityContext, productId: string): Promise<string> {
    const param: iap.PurchaseParameter = {
      productId: productId,
      productType: iap.ProductType.CONSUMABLE,
      developerPayload: `hallpass_${Date.now()}`
    };

    const result: iap.CreatePurchaseResult = await iap.createPurchase(context, param);
    hilog.info(DOMAIN, TAG, 'createPurchase succeeded.');
    return result.purchaseData;
  }

  /**
   * 单机发货确认（支持 1001860053 幂等性识别）
   */
  async finishPurchase(context: common.UIAbilityContext, token: string, orderId: string): Promise<boolean> {
    const finishParam: iap.FinishPurchaseParameter = {
      productType: iap.ProductType.CONSUMABLE,
      purchaseToken: token,
      purchaseOrderId: orderId
    };

    try {
      await iap.finishPurchase(context, finishParam);
      hilog.info(DOMAIN, TAG, `finishPurchase success for order: ${orderId}`);
      await this.markOrderProcessed(orderId);
      return true;
    } catch (err) {
      const bErr: BusinessError = err as BusinessError;
      // 1001860053 (PURCHASE_FINISHED) 表示该购买已完成发货，属于幂等成功
      if (bErr.code === 1001860053 || bErr.code === iap.IAPErrorCode.PURCHASE_FINISHED) {
        hilog.warn(DOMAIN, TAG, `Order ${orderId} was already finished (1001860053).`);
        await this.markOrderProcessed(orderId);
        return true;
      }
      hilog.error(DOMAIN, TAG, `finishPurchase failed: ${bErr.code} - ${bErr.message}`);
      return false;
    }
  }

  /**
   * 自动补偿未完成的消耗型订单（含 continuationToken 分页与单项异常隔离）
   */
  async recoverUnfinishedPurchases(context: common.UIAbilityContext): Promise<number> {
    let recoveredCount = 0;
    let continuationToken: string | undefined = undefined;
    await this.ensureCacheLoaded();

    try {
      do {
        const queryParam: iap.QueryPurchasesParameter = {
          productType: iap.ProductType.CONSUMABLE,
          queryType: iap.PurchaseQueryType.UNFINISHED,
          continuationToken: continuationToken
        };
        const result: iap.QueryPurchaseResult = await iap.queryPurchases(context, queryParam);
        const list: string[] | undefined = result.purchaseDataList;

        if (list && list.length > 0) {
          hilog.info(DOMAIN, TAG, `Recovering batch with ${list.length} unfinished purchases.`);
          for (const dataStr of list) {
            try {
              const payload = this.parsePurchaseOrder(dataStr);
              if (payload && payload.purchaseToken && payload.purchaseOrderId) {
                if (!this.processedOrderIds.has(payload.purchaseOrderId)) {
                  const ok = await this.finishPurchase(context, payload.purchaseToken, payload.purchaseOrderId);
                  if (ok) {
                    recoveredCount++;
                  }
                }
              }
            } catch (singleErr) {
              // 单项异常隔离，保证后续订单能继续恢复
              hilog.error(DOMAIN, TAG, `Single order recovery failed: ${JSON.stringify(singleErr)}`);
            }
          }
        }
        continuationToken = result.continuationToken;
      } while (continuationToken && continuationToken.length > 0);
    } catch (err) {
      const bErr: BusinessError = err as BusinessError;
      hilog.error(DOMAIN, TAG, `recoverUnfinishedPurchases fatal error: ${bErr.code} - ${bErr.message}`);
    }
    return recoveredCount;
  }

  /**
   * 客户端 JWS 解码（编译混淆安全防护 + 原生 base64url 解码）
   */
  parsePurchaseOrder(purchaseDataJson: string): PurchaseOrderPayload | null {
    try {
      // 1. 防御混淆：使用字典安全取值
      const parsed = JSON.parse(purchaseDataJson) as Record<string, Object>;
      const jws = (parsed['jwsPurchaseOrder'] ?? parsed.jwsPurchaseOrder) as string;
      if (!jws) {
        hilog.error(DOMAIN, TAG, 'No jwsPurchaseOrder field in purchaseData.');
        return null;
      }
      const parts = jws.split('.');
      if (parts.length < 2) {
        hilog.error(DOMAIN, TAG, 'Invalid JWS token segments.');
        return null;
      }

      // 2. 原生 base64url 解码 Payload
      const decodedBuf = buffer.from(parts[1], 'base64url');
      const jsonStr = decodedBuf.toString('utf-8');
      const payload = JSON.parse(jsonStr) as Record<string, Object>;

      // 3. 安全转换返回，对齐契约
      return {
        environment: String(payload['environment'] ?? ''),
        purchaseOrderId: String(payload['purchaseOrderId'] ?? ''),
        purchaseToken: String(payload['purchaseToken'] ?? ''),
        productId: String(payload['productId'] ?? ''),
        productType: String(payload['productType'] ?? '0'),
        purchaseTime: Number(payload['purchaseTime'] ?? 0),
        finishStatus: String(payload['finishStatus'] ?? '2')
      };
    } catch (e) {
      hilog.error(DOMAIN, TAG, `parsePurchaseOrder exception: ${JSON.stringify(e)}`);
      return null;
    }
  }

  /** 防重记录持久化管理 */
  private async ensureCacheLoaded(): Promise<void> {
    if (this.cacheLoaded) {
      return;
    }
    try {
      const json = await ServiceLocator.prefs().getString(PREF_KEY_PROCESSED_ORDERS);
      if (json && json.length > 0) {
        const arr = JSON.parse(json) as string[];
        for (const id of arr) {
          this.processedOrderIds.add(id);
        }
      }
      this.cacheLoaded = true;
    } catch (_e) {
      this.cacheLoaded = true;
    }
  }

  private async markOrderProcessed(orderId: string): Promise<void> {
    await this.ensureCacheLoaded();
    this.processedOrderIds.add(orderId);
    try {
      const arr = Array.from(this.processedOrderIds);
      if (arr.length > MAX_PROCESSED_CACHE) {
        arr.splice(0, arr.length - MAX_PROCESSED_CACHE);
      }
      await ServiceLocator.prefs().setString(PREF_KEY_PROCESSED_ORDERS, JSON.stringify(arr));
    } catch (e) {
      hilog.error(DOMAIN, TAG, `Failed to persist processed order: ${JSON.stringify(e)}`);
    }
  }
}
