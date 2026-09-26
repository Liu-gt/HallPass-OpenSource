/*
 * SPDX-FileCopyrightText: 2026 Liugt
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import localUnitTest from './LocalUnit.test';
import encStringCodecTest from './EncStringCodec.test';
import modelTest from './ModelTest';
import fakesFlowTest from './FakesFlow.test';
import lockFlowTest from './LockFlow.test';
import syncWriteFlowTest from './SyncWriteFlow.test';
import syncProjectionTest from './SyncProjection.test';
import totpTest from './Totp.test';
import attachmentTest from './Attachment.test';
import urlCheckTest from './UrlCheck.test';
import settingsServiceTest from './SettingsService.test';
import systemBarTest from './SystemBar.test';
import sponsorTest from './Sponsor.test';

export default function testsuite() {
  localUnitTest();
  encStringCodecTest();
  modelTest();
  fakesFlowTest();
  lockFlowTest();
  syncWriteFlowTest();
  syncProjectionTest();
  totpTest();
  attachmentTest();
  urlCheckTest();
  settingsServiceTest();
  systemBarTest();
  sponsorTest();
}
