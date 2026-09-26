/*
 * SPDX-FileCopyrightText: 2026 Liugt
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import asset from '@ohos.security.asset';
import { userAuth } from '@kit.UserAuthenticationKit';
import { util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { KeyStore } from '../../domain/repository/KeyStore';
import { BiometricType } from '../../domain/biometric/BiometricCapability';
import { Session } from '../../domain/model/Session';

const SESSION_ALIAS: string = 'hallpass.session.tokens';
const FAST_UNLOCK_PREFIX: string = 'hallpass.fastunlock.';
const AUTO_UNLOCK_PREFIX: string = 'hallpass.autounlock.';
/** UserAuthResultCode（统一认证控件结果码）：用户主动取消认证（不触发降级重试）。 */
const AUTH_CANCELED: number = 12500003;
/** Asset 单条 SECRET 上限 1024 字节（E2E-01 fix-03）：会话双 JWT 约 1.6KB 超限，
 *  超限时按该粒度拆为 SESSION_ALIAS.0/1/... 多条记录，读取端按序拼接。 */
const ASSET_SECRET_MAX: number = 1024;
/** 会话分片数上限（8KB 容量，防御性读取边界，避免无限探测）。 */
const SESSION_CHUNK_MAX: number = 8;

function textBytes(text: string): Uint8Array {
  const encoder = new util.TextEncoder();
  return encoder.encodeInto(text);
}

interface SessionPayload {
  accessToken: string;
  refreshToken: string;
  expiresAt: number;
  protectedUserKey?: string | null;
}

/** 单次统一认证尝试结果：token 非空即成功；code 为 UserAuthResultCode（失败原因）。 */
interface AuthAttempt {
  token: Uint8Array | null;
  code: number;
}

/**
 * KeyStore 实现（票 08，plan D3 持久化分工）：Asset Store Kit。
 * - 快速解锁密钥（spec F3）：ALIAS=hallpass.fastunlock.<vaultId>，AUTH_TYPE=ANY +
 *   REQUIRE_PASSWORD_SET 绑定锁屏凭据；读取走 preQuery 挑战 → UserAuthKit 生物识别
 *   → AUTH_TOKEN 查询；任何不可用（未写入/锁屏凭据移除/认证失败/硬件不可用）返回 null，
 *   调用方回退主密码。
 * - 会话令牌（plan D3 安全基线）：非同步型 Asset（SYNC_TYPE=NEVER），重启可恢复，
 *   锁定不清（与密钥生命周期分离）。
 */
export class KeyStoreImpl implements KeyStore {

  async saveFastUnlockKey(vaultId: string, masterKey: Uint8Array): Promise<void> {
    const alias: string = FAST_UNLOCK_PREFIX + vaultId;
    await KeyStoreImpl.removeQuietly(alias);
    const attributes: asset.AssetMap = new Map();
    attributes.set(asset.Tag.SECRET, masterKey);
    attributes.set(asset.Tag.ALIAS, textBytes(alias));
    attributes.set(asset.Tag.ACCESSIBILITY, asset.Accessibility.DEVICE_UNLOCKED);
    attributes.set(asset.Tag.AUTH_TYPE, asset.AuthType.ANY);
    attributes.set(asset.Tag.REQUIRE_PASSWORD_SET, true);
    attributes.set(asset.Tag.SYNC_TYPE, asset.SyncType.NEVER);
    attributes.set(asset.Tag.CONFLICT_RESOLUTION, asset.ConflictResolution.OVERWRITE);
    await asset.add(attributes);
  }

  async readFastUnlockKey(vaultId: string, biometricTypes?: BiometricType[]):
    Promise<Uint8Array | null> {
    const alias: string = FAST_UNLOCK_PREFIX + vaultId;
    const query: asset.AssetMap = new Map();
    query.set(asset.Tag.ALIAS, textBytes(alias));
    let challenge: Uint8Array | null = null;
    try {
      challenge = await asset.preQuery(query);
      const token: Uint8Array | null = await KeyStoreImpl.authenticate(challenge, biometricTypes);
      if (token === null) {
        await KeyStoreImpl.postQueryQuietly(challenge);
        return null;
      }
      query.set(asset.Tag.RETURN_TYPE, asset.ReturnType.ALL);
      query.set(asset.Tag.AUTH_CHALLENGE, challenge);
      query.set(asset.Tag.AUTH_TOKEN, token);
      const result: Array<asset.AssetMap> = await asset.query(query);
      const secret: Uint8Array | null = KeyStoreImpl.findSecret(result);
      await KeyStoreImpl.postQueryQuietly(challenge);
      return secret;
    } catch (e) {
      if (challenge !== null) {
        await KeyStoreImpl.postQueryQuietly(challenge);
      }
      const err: Error = e as Error;
      hilog.error(0x0000, 'HallPassKeyStore',
        'readFastUnlockKey fail %{public}s: %{public}s', err.name ?? 'unknown',
        err.message ?? '');
      return null;
    }
  }

  async hasFastUnlockKey(vaultId: string): Promise<boolean> {
    const query: asset.AssetMap = new Map();
    query.set(asset.Tag.ALIAS, textBytes(FAST_UNLOCK_PREFIX + vaultId));
    query.set(asset.Tag.RETURN_TYPE, asset.ReturnType.ATTRIBUTES);
    try {
      const res: Array<asset.AssetMap> = await asset.query(query);
      return res.length > 0;
    } catch (e) {
      return false;
    }
  }

  async clearFastUnlockKey(vaultId: string): Promise<void> {
    await KeyStoreImpl.removeQuietly(FAST_UNLOCK_PREFIX + vaultId);
  }

  /** 自动会话密钥（开关关闭时）：设备锁屏保护（DEVICE_UNLOCKED），无认证门控。 */
  async saveAutoUnlockKey(vaultId: string, masterKey: Uint8Array): Promise<void> {
    const alias: string = AUTO_UNLOCK_PREFIX + vaultId;
    await KeyStoreImpl.removeQuietly(alias);
    const attributes: asset.AssetMap = new Map();
    attributes.set(asset.Tag.SECRET, masterKey);
    attributes.set(asset.Tag.ALIAS, textBytes(alias));
    attributes.set(asset.Tag.ACCESSIBILITY, asset.Accessibility.DEVICE_UNLOCKED);
    attributes.set(asset.Tag.SYNC_TYPE, asset.SyncType.NEVER);
    attributes.set(asset.Tag.CONFLICT_RESOLUTION, asset.ConflictResolution.OVERWRITE);
    await asset.add(attributes);
  }

  async readAutoUnlockKey(vaultId: string): Promise<Uint8Array | null> {
    const query: asset.AssetMap = new Map();
    query.set(asset.Tag.ALIAS, textBytes(AUTO_UNLOCK_PREFIX + vaultId));
    query.set(asset.Tag.RETURN_TYPE, asset.ReturnType.ALL);
    try {
      const result: Array<asset.AssetMap> = await asset.query(query);
      return KeyStoreImpl.findSecret(result);
    } catch (e) {
      return null;
    }
  }

  async clearAutoUnlockKey(vaultId: string): Promise<void> {
    await KeyStoreImpl.removeQuietly(AUTO_UNLOCK_PREFIX + vaultId);
  }

  async saveSession(session: Session): Promise<void> {
    const payload: SessionPayload = {
      accessToken: session.accessToken,
      refreshToken: session.refreshToken,
      expiresAt: session.expiresAt,
      protectedUserKey: session.protectedUserKey
    };
    const bytes: Uint8Array = textBytes(JSON.stringify(payload));
    await KeyStoreImpl.removeAllSessionRecords();
    if (bytes.length <= ASSET_SECRET_MAX) {
      await KeyStoreImpl.writeRecord(SESSION_ALIAS, bytes);
      return;
    }
    try {
      for (let offset = 0, index = 0; offset < bytes.length;
        offset += ASSET_SECRET_MAX, index++) {
        await KeyStoreImpl.writeRecord(KeyStoreImpl.sessionChunkAlias(index),
          bytes.subarray(offset, Math.min(offset + ASSET_SECRET_MAX, bytes.length)));
      }
    } catch (e) {
      // 部分写入即整体回滚，避免读端拼接出半截会话
      await KeyStoreImpl.removeAllSessionRecords();
      throw e as Error;
    }
  }

  async readSession(): Promise<Session | null> {
    const single: Uint8Array | null = await KeyStoreImpl.readRecordOrNull(SESSION_ALIAS);
    if (single !== null) {
      return KeyStoreImpl.decodeSession(single);
    }
    const parts: Array<Uint8Array> = new Array<Uint8Array>();
    for (let index = 0; index < SESSION_CHUNK_MAX; index++) {
      const part: Uint8Array | null =
        await KeyStoreImpl.readRecordOrNull(KeyStoreImpl.sessionChunkAlias(index));
      if (part === null) {
        break;
      }
      parts.push(part);
    }
    if (parts.length === 0) {
      return null;
    }
    return KeyStoreImpl.decodeSession(KeyStoreImpl.concatBytes(parts));
  }

  async clearSession(): Promise<void> {
    await KeyStoreImpl.removeAllSessionRecords();
  }

  private static sessionChunkAlias(index: number): string {
    return `${SESSION_ALIAS}.${index}`;
  }

  private static decodeSession(secret: Uint8Array): Session | null {
    try {
      const decoder = util.TextDecoder.create('utf-8');
      const json: string = decoder.decodeWithStream(secret);
      const payload: SessionPayload = JSON.parse(json) as SessionPayload;
      return new Session(payload.accessToken, payload.refreshToken, payload.expiresAt,
        payload.protectedUserKey ?? null);
    } catch (e) {
      return null;
    }
  }

  private static async writeRecord(alias: string, secret: Uint8Array): Promise<void> {
    const attributes: asset.AssetMap = new Map();
    attributes.set(asset.Tag.SECRET, secret);
    attributes.set(asset.Tag.ALIAS, textBytes(alias));
    attributes.set(asset.Tag.ACCESSIBILITY, asset.Accessibility.DEVICE_FIRST_UNLOCKED);
    attributes.set(asset.Tag.SYNC_TYPE, asset.SyncType.NEVER);
    attributes.set(asset.Tag.CONFLICT_RESOLUTION, asset.ConflictResolution.OVERWRITE);
    await asset.add(attributes);
  }

  private static async readRecordOrNull(alias: string): Promise<Uint8Array | null> {
    const query: asset.AssetMap = new Map();
    query.set(asset.Tag.ALIAS, textBytes(alias));
    query.set(asset.Tag.RETURN_TYPE, asset.ReturnType.ALL);
    try {
      const result: Array<asset.AssetMap> = await asset.query(query);
      return KeyStoreImpl.findSecret(result);
    } catch (e) {
      return null;
    }
  }

  private static async removeAllSessionRecords(): Promise<void> {
    await KeyStoreImpl.removeQuietly(SESSION_ALIAS);
    for (let index = 0; index < SESSION_CHUNK_MAX; index++) {
      await KeyStoreImpl.removeQuietly(KeyStoreImpl.sessionChunkAlias(index));
    }
  }

  private static concatBytes(parts: Array<Uint8Array>): Uint8Array {
    let total: number = 0;
    for (let index = 0; index < parts.length; index++) {
      total += parts[index].length;
    }
    const out: Uint8Array = new Uint8Array(total);
    let offset: number = 0;
    for (let index = 0; index < parts.length; index++) {
      out.set(parts[index], offset);
      offset += parts[index].length;
    }
    return out;
  }

  private static findSecret(result: Array<asset.AssetMap>): Uint8Array | null {
    for (let i = 0; i < result.length; i++) {
      const value: boolean | number | Uint8Array | undefined = result[i].get(asset.Tag.SECRET);
      if (value instanceof Uint8Array) {
        return value;
      }
    }
    return null;
  }

  private static async removeQuietly(alias: string): Promise<void> {
    const query: asset.AssetMap = new Map();
    query.set(asset.Tag.ALIAS, textBytes(alias));
    try {
      await asset.remove(query);
    } catch (e) {
      /* 不存在时忽略 */
    }
  }

  /**
   * 生物识别/锁屏凭据认证（spec F3，v1.4 优先方式两段式独占认证）：系统统一认证控件
   * 不保证按 authType 数组顺序默认展示方式，"优先使用方式"必须以独占式认证保证——
   * 第一段只提供优先方式 + PIN（锁屏凭据，始终兜底）；用户主动取消（CANCELED）
   * 不降级直接返回；其余失败（未录入/冻结/超时/不匹配等）降级到剩余方式 + PIN 再试。
   */
  private static async authenticate(challenge: Uint8Array, biometricTypes?: BiometricType[]):
    Promise<Uint8Array | null> {
    let enabled: BiometricType[] = biometricTypes ?? ['fingerprint', 'face'];
    if (enabled.length === 0) {
      enabled = ['fingerprint', 'face'];
    }
    const first: AuthAttempt =
      await KeyStoreImpl.authenticateOnce(challenge, [enabled[0]]);
    if (first.token !== null) {
      return first.token;
    }
    if (first.code === AUTH_CANCELED || enabled.length === 1) {
      return null;
    }
    const second: AuthAttempt =
      await KeyStoreImpl.authenticateOnce(challenge, enabled.slice(1));
    return second.token;
  }

  private static async authenticateOnce(challenge: Uint8Array,
    biometricTypes: BiometricType[]): Promise<AuthAttempt> {
    return new Promise<AuthAttempt>((resolve: (value: AuthAttempt) => void) => {
      let settled: boolean = false;
      const finish = (attempt: AuthAttempt): void => {
        if (!settled) {
          settled = true;
          resolve(attempt);
        }
      };
      const authTypes: userAuth.UserAuthType[] = [];
      for (const t of biometricTypes) {
        authTypes.push(t === 'face' ? userAuth.UserAuthType.FACE
          : userAuth.UserAuthType.FINGERPRINT);
      }
      authTypes.push(userAuth.UserAuthType.PIN);
      const authParam: userAuth.AuthParam = {
        challenge: challenge,
        authType: authTypes,
        authTrustLevel: userAuth.AuthTrustLevel.ATL1
      };
      const widgetParam: userAuth.WidgetParam = {
        title: 'HallPass'
      };
      const instance: userAuth.UserAuthInstance =
        userAuth.getUserAuthInstance(authParam, widgetParam);
      const callback: userAuth.IAuthCallback = {
        onResult: (result: userAuth.UserAuthResult): void => {
          if (result.result === userAuth.UserAuthResultCode.SUCCESS
            && result.token !== undefined) {
            const ok: AuthAttempt = { token: result.token, code: result.result };
            finish(ok);
          } else {
            hilog.error(0x0000, 'HallPassKeyStore',
              'user auth fail result=%{public}d', result.result);
            const failed: AuthAttempt = { token: null, code: result.result };
            finish(failed);
          }
        }
      };
      instance.on('result', callback);
      instance.start();
    });
  }

  /** 查询后置清理（官方指导：preQuery 成功后无论成败都要 postQuery 释放会话）。 */
  private static async postQueryQuietly(challenge: Uint8Array): Promise<void> {
    const handle: asset.AssetMap = new Map();
    handle.set(asset.Tag.AUTH_CHALLENGE, challenge);
    try {
      await asset.postQuery(handle);
    } catch (e) {
      /* 清理失败忽略 */
    }
  }
}
