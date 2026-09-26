/*
 * SPDX-FileCopyrightText: 2026 Liugt
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import { describe, it, expect } from '@ohos/hypium';
import { buffer } from '@kit.ArkTS';
import {
  SPONSOR_TIERS,
  SponsorTierId,
  SponsorState
} from '../main/ets/features/settings/sponsor/SponsorModel';
import { SponsorService } from '../main/ets/features/settings/sponsor/SponsorService';
import { SponsorDialogService } from '../main/ets/features/settings/sponsor/SponsorDialogService';

export default function sponsorTest() {
  describe('SponsorTest', () => {
    it('should have 3 configured sponsor tiers', 0, () => {
      expect(SPONSOR_TIERS.length).assertEqual(3);

      expect(SPONSOR_TIERS[0].id).assertEqual(SponsorTierId.ONE);
      expect(SPONSOR_TIERS[0].productId).assertEqual('com.liugt.hallpass.sponsor_1');
      expect(SPONSOR_TIERS[0].defaultPrice).assertEqual('¥1.00');

      expect(SPONSOR_TIERS[1].id).assertEqual(SponsorTierId.SEVEN);
      expect(SPONSOR_TIERS[1].productId).assertEqual('com.liugt.hallpass.sponsor_7');
      expect(SPONSOR_TIERS[1].defaultPrice).assertEqual('¥7.00');

      expect(SPONSOR_TIERS[2].id).assertEqual(SponsorTierId.SEVENTEEN);
      expect(SPONSOR_TIERS[2].productId).assertEqual('com.liugt.hallpass.sponsor_17');
      expect(SPONSOR_TIERS[2].defaultPrice).assertEqual('¥17.00');
    });

    it('should correctly decode valid JWS purchase order', 0, () => {
      const payloadObj: Record<string, Object> = {
        'environment': '0',
        'purchaseOrderId': 'order_test_123',
        'purchaseToken': 'token_abc_xyz',
        'productId': 'com.liugt.hallpass.sponsor_1',
        'productType': '0',
        'purchaseTime': 1727366400000,
        'finishStatus': '2'
      };
      const payloadJson = JSON.stringify(payloadObj);
      const encodedPayload = buffer.from(payloadJson, 'utf-8').toString('base64url');
      const jws = `header.${encodedPayload}.signature`;

      const purchaseData = JSON.stringify({
        jwsPurchaseOrder: jws
      });

      const parsed = SponsorService.get().parsePurchaseOrder(purchaseData);
      expect(parsed !== null).assertTrue();
      if (parsed) {
        expect(parsed.purchaseOrderId).assertEqual('order_test_123');
        expect(parsed.purchaseToken).assertEqual('token_abc_xyz');
        expect(parsed.productId).assertEqual('com.liugt.hallpass.sponsor_1');
        expect(parsed.productType).assertEqual('0');
        expect(parsed.finishStatus).assertEqual('2');
      }
    });

    it('should return null for invalid or missing JWS data', 0, () => {
      expect(SponsorService.get().parsePurchaseOrder('{}')).assertNull();
      expect(SponsorService.get().parsePurchaseOrder('{"jwsPurchaseOrder":"invalid"}')).assertNull();
      expect(SponsorService.get().parsePurchaseOrder('corrupt_json')).assertNull();
    });

    it('should manage SponsorDialogService initial state and dismiss', 0, () => {
      const dialogSvc = SponsorDialogService.get();
      dialogSvc.dismiss();
      expect(dialogSvc.visible).assertFalse();
      expect(dialogSvc.sponsorState).assertEqual(SponsorState.IDLE);
      expect(dialogSvc.selectedTierId).assertEqual(SponsorTierId.ONE);

      // handleBack when hidden should return false
      expect(dialogSvc.handleBack()).assertFalse();

      // handleBack when PURCHASING should intercept (return true) without dismissing
      dialogSvc.visible = true;
      dialogSvc.sponsorState = SponsorState.PURCHASING;
      expect(dialogSvc.handleBack()).assertTrue();
      expect(dialogSvc.visible).assertTrue();

      // handleBack when DELIVERING should intercept without dismissing
      dialogSvc.sponsorState = SponsorState.DELIVERING;
      expect(dialogSvc.handleBack()).assertTrue();
      expect(dialogSvc.visible).assertTrue();

      // handleBack when READY should dismiss
      dialogSvc.sponsorState = SponsorState.READY;
      expect(dialogSvc.handleBack()).assertTrue();
      expect(dialogSvc.visible).assertFalse();
      expect(dialogSvc.sponsorState).assertEqual(SponsorState.IDLE);
    });
  });
}
