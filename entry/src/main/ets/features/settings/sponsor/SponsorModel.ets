/*
 * SPDX-FileCopyrightText: 2026 Liugt
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

/** 赞助商品档位枚举（1元、7元、17元） */
export enum SponsorTierId {
  ONE = 'one',
  SEVEN = 'seven',
  SEVENTEEN = 'seventeen'
}

/** 赞助档位配置定义 */
export interface SponsorTierConfig {
  readonly id: SponsorTierId;
  readonly productId: string;
  readonly title: ResourceStr;
  readonly defaultPrice: string;
  readonly subtitle: ResourceStr;
  readonly symbolIcon: Resource;
}

/** 预定义常态配置（无敏感信息，纯客户端元数据） */
export const SPONSOR_TIERS: SponsorTierConfig[] = [
  {
    id: SponsorTierId.ONE,
    productId: 'com.liugt.hallpass.sponsor_1',
    title: $r('app.string.sponsor_tier_1_title'),
    defaultPrice: '¥1.00',
    subtitle: $r('app.string.sponsor_tier_1_desc'),
    symbolIcon: $r('sys.symbol.cup_fill')
  },
  {
    id: SponsorTierId.SEVEN,
    productId: 'com.liugt.hallpass.sponsor_7',
    title: $r('app.string.sponsor_tier_7_title'),
    defaultPrice: '¥7.00',
    subtitle: $r('app.string.sponsor_tier_7_desc'),
    symbolIcon: $r('sys.symbol.cup_fill')
  },
  {
    id: SponsorTierId.SEVENTEEN,
    productId: 'com.liugt.hallpass.sponsor_17',
    title: $r('app.string.sponsor_tier_17_title'),
    defaultPrice: '¥17.00',
    subtitle: $r('app.string.sponsor_tier_17_desc'),
    symbolIcon: $r('sys.symbol.cup_fill')
  }
];

/** 赞助全流程状态机 */
export enum SponsorState {
  IDLE = 'idle',
  LOADING = 'loading',           // 并发检查环境与商品
  READY = 'ready',               // 商品就绪，可供用户选择
  PURCHASING = 'purchasing',     // 收银台支付中
  DELIVERING = 'delivering',     // 发货确认中
  SUCCESS = 'success',           // 赞助完成，鸣谢态
  ERROR = 'error',               // 发生异常，展示错误信息
  UNSUPPORTED = 'unsupported'    // 服务地不支持
}

/** 运行期装配的产品展示数据 */
export interface SponsorDisplayTier {
  readonly config: SponsorTierConfig;
  priceText: string;
  name: string;
  isValid: boolean;
}

/**
 * JWS 解码后的订单核心载荷契约
 * 对齐 HarmonyOS NEXT IAP Kit 官方规范：productType 与 finishStatus 均为 string
 */
export interface PurchaseOrderPayload {
  readonly environment: string;
  readonly purchaseOrderId: string;
  readonly purchaseToken: string;
  readonly productId: string;
  readonly productType: string;    // '0': 消耗型, '1': 非消耗型
  readonly purchaseTime: number;
  readonly finishStatus: string;   // '1': 已发货, '2': 未发货
}
