/*
 * SPDX-FileCopyrightText: 2026 Liugt
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import abilityTest from './Ability.test';
import argon2VectorTest from './Argon2Vector.test';
import cryptoVectorTest from './CryptoVector.test';
import vaultRepositoryTest from './VaultRepository.test';
import keyStoreTest from './KeyStore.test';
import bwApiClientTest from './BwApiClient.test';

export default function testsuite() {
  abilityTest();
  argon2VectorTest();
  cryptoVectorTest();
  vaultRepositoryTest();
  keyStoreTest();
  bwApiClientTest();
}
