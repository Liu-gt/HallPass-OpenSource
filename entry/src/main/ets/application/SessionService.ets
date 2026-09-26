/*
 * SPDX-FileCopyrightText: 2026 Liugt
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import { AppState } from './state/AppState';
import { Session } from '../domain/model/Session';
import { SymmetricKey } from '../domain/crypto/CryptoEngine';
import { KdfParams, KdfType } from '../domain/model/VaultContext';
import { PreferencesStore, PrefKeys } from '../domain/repository/PreferencesStore';
import { KeyStore } from '../domain/repository/KeyStore';
import { VaultRepository } from '../domain/repository/VaultRepository';
import { hilog } from '@kit.PerformanceAnalysisKit';

/**
 * 会话注入口（plan D5 令牌注入职责在实现层；application 通过此窄接口驱动，
 * BwApiClientImpl 实现之，保证 SessionService 零 kit 依赖、可本地单测）。
 */
export interface SessionSink {
  attachSession(session: Session): void;
  detachSession(): void;
}

/** 会话展示态（响应式：email/serverUrl 供设置页与登录页回显）。 */
@ObservedV2
export class SessionState {
  @Trace email: string = '';
  @Trace serverUrl: string = '';
  @Trace vaultId: string = '';
}

/**
 * SessionService（票 10，plan D7/R5）：登录/登出/会话过期的唯一编排者。
 * 相位约束：只有本服务能改 onboarding↔unlocked（AppState 注释契约）；
 * locked↔unlocked 归 LockService（R5 单一状态机裁决）。
 * 安全基线（plan D3）：主密钥/拉伸密钥仅存内存，锁定即清（clearSecrets）；
 * 会话令牌经 KeyStore（Asset）持久化，绝不入 RDB/Preferences。
 */
export class SessionService {
  readonly state: SessionState = new SessionState();
  private readonly prefs: PreferencesStore;
  private readonly keyStore: KeyStore;
  private readonly sink: SessionSink;
  private readonly repository: VaultRepository;
  private session: Session | null = null;
  private masterKeyRef: Uint8Array | null = null;
  private stretchedRef: SymmetricKey | null = null;
  /** 服务器用户对称密钥（条目加解密真正密钥，E2E-01 fix-06）。 */
  private userKeyRef: SymmetricKey | null = null;

  constructor(prefs: PreferencesStore, keyStore: KeyStore, sink: SessionSink,
    repository: VaultRepository) {
    this.prefs = prefs;
    this.keyStore = keyStore;
    this.sink = sink;
    this.repository = repository;
  }

  /** 冷启动恢复（plan R5：永远从 locked/onboarding 起步，绝不直接 unlocked）。 */
  async restoreOnLaunch(): Promise<void> {
    const stored: Session | null = await this.keyStore.readSession();
    if (stored === null) {
      this.session = null;
      this.sink.detachSession();
      AppState.get().transitionTo('onboarding');
      return;
    }
    this.session = stored;
    this.sink.attachSession(stored);
    const email: string | null = await this.prefs.getString(PrefKeys.LAST_EMAIL);
    const serverUrl: string | null = await this.prefs.getString(PrefKeys.LAST_SERVER_URL);
    this.state.email = email ?? '';
    this.state.serverUrl = serverUrl ?? '';
    this.state.vaultId = VaultContextId.forEmail(this.state.email);
    AppState.get().transitionTo('locked');
  }

  /**
   * 登录编排收口（票 15 登录步调用）：写入会话与密钥（仅内存）、持久化非敏感回显项、
   * 迁移到 unlocked。返回前不落盘任何可逆密钥明文（spec F2）。
   */
  async completeLogin(vaultId: string, email: string, serverUrl: string,
    session: Session, masterKey: Uint8Array, stretched: SymmetricKey,
    userKey: SymmetricKey | null = null, kdf: KdfParams | null = null): Promise<void> {
    this.session = session;
    this.masterKeyRef = masterKey;
    this.stretchedRef = stretched;
    this.userKeyRef = userKey;
    this.sink.attachSession(session);
    this.state.email = email;
    this.state.serverUrl = serverUrl;
    this.state.vaultId = vaultId;
    await this.prefs.setString(PrefKeys.LAST_EMAIL, email);
    await this.prefs.setString(PrefKeys.LAST_SERVER_URL, serverUrl);
    if (kdf !== null) {
      await this.saveKdfCache(serverUrl, email, kdf);
    }
    await this.keyStore.saveSession(session);
    await this.restoreUnlockKeys(vaultId, masterKey);
    this.lockServiceHook?.onSessionEstablished();
    AppState.get().transitionTo('unlocked');
  }

  /**
   * 按偏好重建解锁密钥（开关状态同步的关键路径）：偏好是各解锁开关的唯一状态源，
   * Asset 密钥是派生物——登出会清密钥（不清偏好），重新登录时据此自动恢复：
   * entryLockRequired=false → 写自动会话密钥（冷启动静默解锁），生物识别随总开关
   * 关闭（v1.4 联动），不恢复门控密钥；任一生物识别方式开启 → 写快速解锁门控密钥。
   * 恢复失败仅记日志（可稍后在设置重开开关触发重写），不阻塞登录。
   */
  private async restoreUnlockKeys(vaultId: string, masterKey: Uint8Array): Promise<void> {
    try {
      const entryLock: boolean | null =
        await this.prefs.getBoolean(PrefKeys.ENTRY_LOCK_REQUIRED);
      if (entryLock === false) {
        await this.keyStore.saveAutoUnlockKey(vaultId, masterKey);
        return;
      }
      const fingerprint: boolean | null =
        await this.prefs.getBoolean(PrefKeys.BIOMETRIC_FINGERPRINT_ENABLED);
      const face: boolean | null =
        await this.prefs.getBoolean(PrefKeys.BIOMETRIC_FACE_ENABLED);
      if (fingerprint === true || face === true) {
        await this.keyStore.saveFastUnlockKey(vaultId, masterKey);
      }
    } catch (e) {
      const err: Error = e as Error;
      hilog.error(0x0000, 'HallPassSession', 'restore unlock keys fail %{public}s: %{public}s',
        err.name ?? 'unknown', err.message ?? '');
    }
  }

  /** 刷新令牌落地（BwApiClientImpl.onTokensRefreshed 转接）。 */
  async onTokensRefreshed(session: Session): Promise<void> {
    this.session = session;
    await this.keyStore.saveSession(session);
  }

  masterKey(): Uint8Array | null {
    return this.masterKeyRef;
  }

  stretchedKey(): SymmetricKey | null {
    return this.stretchedRef;
  }

  /**
   * 条目加解密密钥（fix-06）：优先服务器用户密钥；未获得（旧会话/离线自建库）
   * 退化为拉伸主密钥，保持旧行为可用。
   */
  userKey(): SymmetricKey | null {
    return this.userKeyRef ?? this.stretchedRef;
  }

  /** 服务器用户密钥密文（解锁链路重新解开用；无会话返回 null）。 */
  protectedUserKey(): string | null {
    return this.session === null ? null : this.session.protectedUserKey;
  }

  /**
   * KDF 参数缓存写入（T26，plan §1.5 lastKdfJson）：按"服务器+邮箱"维度，
   * 仅存 type/iterations/memory/parallelism，绝不含密钥材料或主密码（spec F2）。
   */
  async saveKdfCache(serverUrl: string, email: string, kdf: KdfParams): Promise<void> {
    const payload: Record<string, Object> = {
      'serverUrl': serverUrl,
      'email': email,
      'type': kdf.type as Object,
      'iterations': kdf.iterations as Object
    };
    if (kdf.memory !== null) {
      payload['memory'] = kdf.memory as Object;
    }
    if (kdf.parallelism !== null) {
      payload['parallelism'] = kdf.parallelism as Object;
    }
    await this.prefs.setString(PrefKeys.LAST_KDF_JSON, JSON.stringify(payload));
  }

  /** KDF 参数缓存读取（T26）：维度（服务器+邮箱）不匹配或缺失/损坏返回 null。 */
  async kdfCacheFor(serverUrl: string, email: string): Promise<KdfParams | null> {
    const raw: string | null = await this.prefs.getString(PrefKeys.LAST_KDF_JSON);
    if (raw === null || raw.length === 0) {
      return null;
    }
    try {
      const obj: Record<string, Object> = JSON.parse(raw) as Record<string, Object>;
      if (asPlainString(obj['serverUrl']) !== serverUrl || asPlainString(obj['email']) !== email) {
        return null;
      }
      const type: number = asPlainNumber(obj['type']);
      const iterations: number = asPlainNumber(obj['iterations']);
      if (type !== KdfType.Pbkdf2 && type !== KdfType.Argon2id || iterations <= 0) {
        return null;
      }
      const memory: number | null = asPlainNumberOrNull(obj['memory']);
      const parallelism: number | null = asPlainNumberOrNull(obj['parallelism']);
      if (type === KdfType.Argon2id && (memory === null || parallelism === null)) {
        return null;
      }
      return new KdfParams(type, iterations, memory, parallelism);
    } catch (e) {
      return null;
    }
  }

  hasSession(): boolean {
    return this.session !== null;
  }

  /** 锁定清理（LockService 专属钩子，plan R5）：清内存密钥，会话保留。 */
  clearSecrets(): void {
    this.masterKeyRef = null;
    this.stretchedRef = null;
    this.userKeyRef = null;
  }

  /**
   * 解锁时恢复内存密钥（票 16 生物识别/主密码解锁路径；与 clearSecrets 对称）。
   * 仅在已登录（会话存在）时生效，锁定期由根级条件渲染保证。
   * userKey 为解开后的服务器用户密钥（fix-06），null 时回退拉伸密钥语义。
   */
  restoreKeys(masterKey: Uint8Array, stretched: SymmetricKey,
    userKey: SymmetricKey | null): void {
    if (this.session !== null) {
      this.masterKeyRef = masterKey;
      this.stretchedRef = stretched;
      this.userKeyRef = userKey;
    }
  }

  /** 退出登录（spec F13）：清全部密文缓存与 Asset 密钥，回 onboarding。 */
  async logout(): Promise<void> {
    this.clearSecrets();
    this.session = null;
    this.sink.detachSession();
    await this.keyStore.clearSession();
    if (this.state.vaultId.length > 0) {
      await this.keyStore.clearFastUnlockKey(this.state.vaultId);
      await this.keyStore.clearAutoUnlockKey(this.state.vaultId);
      await this.repository.replaceCiphers(this.state.vaultId, []);
      await this.repository.replaceFolders(this.state.vaultId, []);
    }
    await this.clearKdfCache();
    this.state.email = '';
    this.state.serverUrl = '';
    this.state.vaultId = '';
    AppState.get().transitionTo('onboarding');
  }

  /** 会话过期（刷新令牌失效）：会话作废、密钥清空、转 locked。 */
  async handleSessionExpired(): Promise<void> {
    this.clearSecrets();
    this.session = null;
    this.sink.detachSession();
    await this.keyStore.clearSession();
    AppState.get().transitionTo('locked');
  }

  /** KDF 缓存清除（spec F13：随登出清除；仅锁定不清）。 */
  private async clearKdfCache(): Promise<void> {
    await this.prefs.setString(PrefKeys.LAST_KDF_JSON, '');
  }

  /** LockService 接线钩子（AppContainer 注入）。 */
  lockServiceHook: SessionLockHook | null = null;
}

function asPlainString(value: Object | undefined): string {
  return typeof value === 'string' ? value as string : '';
}

function asPlainNumber(value: Object | undefined): number {
  return typeof value === 'number' ? value as number : -1;
}

function asPlainNumberOrNull(value: Object | undefined): number | null {
  return typeof value === 'number' ? value as number : null;
}

/** LockService 需要感知的会话事件（解耦：不直接 import 服务实例）。 */
export interface SessionLockHook {
  onSessionEstablished(): void;
}

/** vaultId 派生（MVP 单保管库，ADR-0002：以账号邮箱派生稳定 id）。 */
export class VaultContextId {
  static forEmail(email: string): string {
    let hash: number = 0;
    for (let i = 0; i < email.length; i++) {
      hash = ((hash * 31) + email.charCodeAt(i)) | 0;
    }
    return `local-${(hash >>> 0).toString(16)}`;
  }
}
