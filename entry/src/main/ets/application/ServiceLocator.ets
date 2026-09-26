/*
 * SPDX-FileCopyrightText: 2026 Liugt
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import { AppContainer } from './bootstrap/AppContainer';
import { SyncService } from './SyncService';
import { SettingsService } from './SettingsService';
import { WriteService } from './WriteService';
import { VaultMemoryIndex } from './state/VaultMemoryIndex';
import { ClockService } from './ClockService';
import { ClipboardService } from './ClipboardService';
import { PasteboardAdapter } from '../infrastructure/clipboard/PasteboardAdapter';
import { AttachmentService, AttachmentTransport } from './AttachmentService';
import { CipherResponse } from '../domain/protocol/Types';
import { PreferencesStore, PrefKeys } from '../domain/repository/PreferencesStore';
import { BiometricCapability } from '../domain/biometric/BiometricCapability';
import { BiometricCapabilityImpl } from '../infrastructure/asset/BiometricCapabilityImpl';
import { KeyStore } from '../domain/repository/KeyStore';
import { VaultRepository } from '../domain/repository/VaultRepository';
import { BwApiClient } from '../domain/protocol/BwApiClient';
import { BwApiClientImpl } from '../infrastructure/http/BwApiClientImpl';
import { CryptoEngine } from '../domain/crypto/CryptoEngine';
import { SessionService } from './SessionService';
import { LockService } from './LockService';
import { AttachmentApi } from '../infrastructure/http/AttachmentApi';

/**
 * 体验模式沙箱服务集：通过依赖倒置传入，彻底解除 ServiceLocator 对 DemoServices 的强依赖
 */
export interface DemoSandboxServices {
  index: VaultMemoryIndex;
  write: WriteService;
  sync: SyncService;
  session: SessionService;
  lock: LockService;
  prefs: PreferencesStore;
  keyStore: KeyStore;
  repository: VaultRepository;
  attachment: AttachmentService;
  settings: SettingsService;
  clipboard: ClipboardService;
  client: BwApiClient;
  destroySync?: () => void;
}

export class ServiceLocator {
  private static syncRef: SyncService | null = null;
  private static writeRef: WriteService | null = null;
  private static clockRef: ClockService | null = null;
  private static clipboardRef: ClipboardService | null = null;
  private static attachmentRef: AttachmentService | null = null;
  private static biometricRef: BiometricCapability | null = null;

  // === Demo 模式沙箱引用 ===
  private static demoActive: boolean = false;
  private static demoSandbox: DemoSandboxServices | null = null;

  static isDemo(): boolean {
    return ServiceLocator.demoActive;
  }

  static enterDemoMode(sandbox: DemoSandboxServices): void {
    ServiceLocator.demoActive = true;
    ServiceLocator.demoSandbox = sandbox;
  }

  static exitDemoMode(): void {
    if (ServiceLocator.demoSandbox !== null) {
      ServiceLocator.demoSandbox.index.clear();
      if (ServiceLocator.demoSandbox.destroySync) {
        ServiceLocator.demoSandbox.destroySync();
      }
      ServiceLocator.demoSandbox = null;
    }
    ServiceLocator.demoActive = false;
  }

  static biometric(): BiometricCapability {
    if (ServiceLocator.biometricRef === null) {
      ServiceLocator.biometricRef = new BiometricCapabilityImpl();
    }
    return ServiceLocator.biometricRef;
  }

  static sync(): SyncService {
    if (ServiceLocator.demoActive && ServiceLocator.demoSandbox !== null) {
      return ServiceLocator.demoSandbox.sync;
    }
    if (ServiceLocator.syncRef === null) {
      const container: AppContainer = AppContainer.get();
      ServiceLocator.syncRef = new SyncService(new VaultMemoryIndex(),
        container.client, container.repository, container.crypto, container.sessionService,
        container.lockService);
    }
    return ServiceLocator.syncRef;
  }

  static clock(): ClockService {
    if (ServiceLocator.clockRef === null) {
      ServiceLocator.clockRef = new ClockService();
    }
    ServiceLocator.clockRef.start();
    return ServiceLocator.clockRef;
  }

  static clipboard(): ClipboardService {
    // 修复 MED-v2-02：体验模式返回沙箱剪贴板服务
    if (ServiceLocator.demoActive && ServiceLocator.demoSandbox !== null) {
      return ServiceLocator.demoSandbox.clipboard;
    }
    if (ServiceLocator.clipboardRef === null) {
      const container: AppContainer = AppContainer.get();
      ServiceLocator.clipboardRef = new ClipboardService(new PasteboardAdapter(),
        container.prefs);
    }
    return ServiceLocator.clipboardRef;
  }

  static attachment(): AttachmentService {
    if (ServiceLocator.demoActive && ServiceLocator.demoSandbox !== null) {
      return ServiceLocator.demoSandbox.attachment;
    }
    if (ServiceLocator.attachmentRef === null) {
      const container: AppContainer = AppContainer.get();
      const transport: AttachmentTransport = new AttachmentApi() as AttachmentTransport;
      const service: AttachmentService = new AttachmentService(container.client, transport,
        container.crypto, container.sessionService, container.repository,
        (response: CipherResponse): Promise<void> =>
          ServiceLocator.sync().upsertFromServerResponse(response));
      AttachmentService.initShared(service);
      ServiceLocator.attachmentRef = service;
    }
    return ServiceLocator.attachmentRef;
  }

  static async lastEmail(): Promise<string | null> {
    if (ServiceLocator.demoActive) {
      return null;
    }
    return AppContainer.get().prefs.getString(PrefKeys.LAST_EMAIL);
  }

  static prefs(): PreferencesStore {
    if (ServiceLocator.demoActive && ServiceLocator.demoSandbox !== null) {
      return ServiceLocator.demoSandbox.prefs;
    }
    return AppContainer.get().prefs;
  }

  static keyStore(): KeyStore {
    if (ServiceLocator.demoActive && ServiceLocator.demoSandbox !== null) {
      return ServiceLocator.demoSandbox.keyStore;
    }
    return AppContainer.get().keyStore;
  }

  static repository(): VaultRepository {
    if (ServiceLocator.demoActive && ServiceLocator.demoSandbox !== null) {
      return ServiceLocator.demoSandbox.repository;
    }
    return AppContainer.get().repository;
  }

  static session(): SessionService {
    if (ServiceLocator.demoActive && ServiceLocator.demoSandbox !== null) {
      return ServiceLocator.demoSandbox.session;
    }
    return AppContainer.get().sessionService;
  }

  /**
   * 修复 CRIT-v2-04：沙箱化锁屏服务，彻底切断对真机磁盘 preferences.xml 的写入
   */
  static lock(): LockService {
    if (ServiceLocator.demoActive && ServiceLocator.demoSandbox !== null) {
      return ServiceLocator.demoSandbox.lock;
    }
    return AppContainer.get().lockService;
  }

  static settings(): SettingsService {
    if (ServiceLocator.demoActive && ServiceLocator.demoSandbox !== null) {
      return ServiceLocator.demoSandbox.settings;
    }
    return AppContainer.get().settingsService;
  }

  static client(): BwApiClient {
    if (ServiceLocator.demoActive && ServiceLocator.demoSandbox !== null) {
      return ServiceLocator.demoSandbox.client;
    }
    return AppContainer.get().client;
  }

  static clientImpl(): BwApiClientImpl {
    return AppContainer.get().client;
  }

  /**
   * 修复 CRIT-v2-01 & HIGH-v2-02：复用生产纯数学 CryptoEngine，
   * 零状态、零磁盘、零网络，全量支持 GeneratorViewModel 密码生成器的真随机数！
   */
  static crypto(): CryptoEngine {
    return AppContainer.get().crypto;
  }

  static write(): WriteService {
    if (ServiceLocator.demoActive && ServiceLocator.demoSandbox !== null) {
      return ServiceLocator.demoSandbox.write;
    }
    if (ServiceLocator.writeRef === null) {
      const container: AppContainer = AppContainer.get();
      const writeService: WriteService = new WriteService(container.client,
        container.repository, container.crypto, container.sessionService,
        (response: CipherResponse): Promise<void> =>
          ServiceLocator.sync().upsertFromServerResponse(response));
      writeService.setRemovedHook((id: string): void => {
        ServiceLocator.sync().removeLocally(id);
      });
      writeService.setLocalCipherHook((id: string, deletedDate: number | null): Promise<void> =>
        ServiceLocator.sync().refreshCipherLocally(id, deletedDate));
      ServiceLocator.writeRef = writeService;
      ServiceLocator.syncRef?.setReplayHook((): Promise<void> => writeService.replayOutbox());
    }
    return ServiceLocator.writeRef;
  }
}
