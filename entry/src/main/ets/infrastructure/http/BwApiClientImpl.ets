/*
 * SPDX-FileCopyrightText: 2026 Liugt
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import { rcp } from '@kit.RemoteCommunicationKit';
import { util } from '@kit.ArkTS';
import { bundleManager } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BwApiClient } from '../../domain/protocol/BwApiClient';
import { BwCloud, PreloginResponse, TokenRequest, TokenResponse, SyncResponse, CipherPayload,
  CipherResponse, FolderResponse, ProtocolError, ProtocolErrorKind, TwoFactorRequiredError,
  AttachmentUploadResponse, AttachmentDownloadResponse, ProfileResponse }
  from '../../domain/protocol/Types';
import { BwEndpoints } from '../../domain/protocol/Types';
import { Session } from '../../domain/model/Session';
import { ItemType } from '../../domain/model/ItemType';

const DEFAULT_BASE_URL: string = 'https://vault.bitwarden.com';

function asString(obj: Record<string, Object> | null, key: string): string | null {
  if (obj === null) {
    return null;
  }
  const value: Object | undefined = obj[key];
  if (typeof value === 'string') {
    return value as string;
  }
  return null;
}

function asNumber(obj: Record<string, Object> | null, key: string): number | null {
  if (obj === null) {
    return null;
  }
  const value: Object | undefined = obj[key];
  if (typeof value === 'number') {
    return value as number;
  }
  return null;
}

/**
 * BwApiClient RCP 实现（票 09，plan D5）：可变 base url（官方云/自建）、token 注入、
 * 401 刷新重放一次、错误分类映射（网络/凭据/配额/2FA/会话过期/服务端）。
 * 范围守卫：仅个人空间端点（无组织/集合请求，ADR-0001）。
 * 会话令牌注入经 attachSession/detachSession（SessionService 接线，票 10）；
 * 刷新成功经 onTokensRefreshed 回调外抛以便持久化。
 */
export class BwApiClientImpl implements BwApiClient {
  private baseUrl: string = DEFAULT_BASE_URL;
  private session: rcp.Session = rcp.createSession();
  private accessToken: string | null = null;
  private refreshToken: string | null = null;
  private deviceIdentifier: string = util.generateRandomUUID(true);
  private clientVersion: string = BwApiClientImpl.loadClientVersion();
  /** 服务器用户对称密钥密文（token/refresh 响应 Key 字段，随会话存 Asset）。 */
  private protectedUserKey: string | null = null;
  /** 刷新成功回调（SessionService 持久化新令牌用） */
  onTokensRefreshed: ((session: Session) => void) | null = null;

  configure(baseUrl: string): void {
    const trimmed: string = baseUrl.trim();
    this.baseUrl = trimmed.endsWith('/') ? trimmed.substring(0, trimmed.length - 1) : trimmed;
  }

  /** 设备标识注入（组合根启动时从偏好恢复；固定标识让服务器把本机记为已知设备，
   *  避免每次冷启动都触发新设备邮箱验证）。 */
  setDeviceIdentifier(id: string): void {
    if (id.length > 0) {
      this.deviceIdentifier = id;
    }
  }

  attachSession(session: Session): void {
    this.accessToken = session.accessToken;
    this.refreshToken = session.refreshToken;
    this.protectedUserKey = session.protectedUserKey;
  }

  detachSession(): void {
    this.accessToken = null;
    this.refreshToken = null;
    this.protectedUserKey = null;
  }

  currentSession(): Session | null {
    const access: string | null = this.accessToken;
    const refresh: string | null = this.refreshToken;
    if (access === null || refresh === null) {
      return null;
    }
    return new Session(access, refresh, 0, this.protectedUserKey);
  }

  async prelogin(email: string): Promise<PreloginResponse> {
    const body: Record<string, Object> = { 'email': email };
    // 官方云 prelogin 挂在 identity 域（/api/accounts/prelogin 在官方云 404，
    // 见 DIAG-01）；Vaultwarden 只在 /api 下提供，故按后端选路径。
    const path: string = BwApiClientImpl.isOfficialCloud(this.baseUrl)
      ? BwEndpoints.PRELOGIN_OFFICIAL : BwEndpoints.PRELOGIN;
    const json: Record<string, Object> =
      await this.requestJson('POST', path, JSON.stringify(body), false);
    const kdfType: number = asNumber(json, 'kdf') ?? 0;
    // 官方/Vaultwarden 响应字段为 kdfIterations/kdfMemory/kdfParallelism；
    // 旧字段名保留为别名兜底。kdfMemory 单位 MB，换算 KiB 供 KdfParams 使用。
    const iterations: number | null =
      asNumber(json, 'kdfIterations') ?? asNumber(json, 'iterations');
    const memoryMb: number | null = asNumber(json, 'kdfMemory') ?? asNumber(json, 'memory');
    const memoryKb: number | null = memoryMb === null ? null : memoryMb * 1024;
    const parallelism: number | null =
      asNumber(json, 'kdfParallelism') ?? asNumber(json, 'parallelism');
    return new PreloginResponse(kdfType, iterations, memoryKb, parallelism);
  }

  async connectToken(request: TokenRequest): Promise<TokenResponse> {
    const form: string[] = [
      'grant_type=password',
      `username=${encodeURIComponent(request.username)}`,
      `password=${encodeURIComponent(request.passwordHash)}`,
      `scope=${encodeURIComponent('api offline_access')}`,
      `client_id=mobile`,
      `deviceIdentifier=${encodeURIComponent(this.deviceIdentifier)}`,
      `deviceName=${encodeURIComponent('HallPass')}`,
      // Bitwarden 身份服务（含 Vaultwarden）校验 device_type 必填，缺失直接 400。
      // DeviceType 枚举无 HarmonyOS 值，取 0（Android，移动端语义）。
      `deviceType=0`
    ];
    if (request.twoFactorProvider !== null && request.twoFactorToken !== null) {
      form.push(`twoFactorProvider=${request.twoFactorProvider}`);
      form.push(`twoFactorToken=${encodeURIComponent(request.twoFactorToken)}`);
      form.push(`twoFactorRemember=${request.twoFactorRemember ? '1' : '0'}`);
    }
    // 新设备验证（官方云）：未知设备首次登录被拒后，携邮箱验证码重提交（同端点同参数）
    if (request.newDeviceOtp !== null) {
      form.push(`NewDeviceOtp=${encodeURIComponent(request.newDeviceOtp)}`);
    }
    const text: string | null = await this.requestText('POST', BwEndpoints.CONNECT_TOKEN,
      form.join('&'), false, 'application/x-www-form-urlencoded');
    if (text === null) {
      throw new ProtocolError(ProtocolErrorKind.Server, 'empty token response');
    }
    const json: Record<string, Object> = JSON.parse(text) as Record<string, Object>;
    const accessToken: string | null = asString(json, 'access_token');
    const refreshToken: string | null = asString(json, 'refresh_token');
    const expiresIn: number = asNumber(json, 'expires_in') ?? 3600;
    // Key 字段：用户对称密钥密文（"0.x|iv|ct|mac" EncString 串），条目加解密的真正密钥
    const protectedKey: string | null = asString(json, 'Key');
    if (accessToken === null || refreshToken === null) {
      throw new ProtocolError(ProtocolErrorKind.Server, 'token response malformed');
    }
    this.accessToken = accessToken;
    this.refreshToken = refreshToken;
    if (protectedKey !== null) {
      this.protectedUserKey = protectedKey;
    }
    return new TokenResponse(accessToken, refreshToken, expiresIn, protectedKey);
  }

  async sync(): Promise<SyncResponse> {
    const json: Record<string, Object> =
      await this.requestJson('GET', BwEndpoints.SYNC, null, true);
    const profileRaw: Object | undefined = json['profile'];
    const profile: Record<string, Object> =
      (profileRaw === undefined || profileRaw === null)
        ? ({ 'id': '', 'email': '' } as Record<string, Object>)
        : (profileRaw as Record<string, Object>);
    const profileResponse: ProfileResponse = new ProfileResponse(
      asString(profile, 'id') ?? '', asString(profile, 'email') ?? '');

    const folders: FolderResponse[] = [];
    const foldersRaw: Object | undefined = json['folders'];
    if (foldersRaw !== undefined && foldersRaw !== null) {
      const arr: Array<Object> = foldersRaw as Array<Object>;
      for (let i = 0; i < arr.length; i++) {
        const f: Record<string, Object> = arr[i] as Record<string, Object>;
        folders.push(new FolderResponse(asString(f, 'id') ?? '',
          asString(f, 'name') ?? '', asString(f, 'revisionDate') ?? '',
          asString(f, 'key')));
      }
    }
    const ciphers: CipherResponse[] = [];
    const ciphersRaw: Object | undefined = json['ciphers'];
    if (ciphersRaw !== undefined && ciphersRaw !== null) {
      const arr: Array<Object> = ciphersRaw as Array<Object>;
      for (let i = 0; i < arr.length; i++) {
        ciphers.push(BwApiClientImpl.parseCipherResponse(arr[i] as Record<string, Object>));
      }
    }
    return new SyncResponse(profileResponse, folders, ciphers);
  }

  async saveCipher(payload: CipherPayload): Promise<CipherResponse> {
    const bodyJson: string = BwApiClientImpl.payloadToJson(payload);
    if (payload.id === null) {
      const json: Record<string, Object> =
        await this.requestJson('POST', BwEndpoints.CIPHERS, bodyJson, true);
      return BwApiClientImpl.parseCipherResponse(json);
    }
    const json: Record<string, Object> = await this.requestJson('PUT',
      `${BwEndpoints.CIPHERS}/${payload.id}`, bodyJson, true);
    return BwApiClientImpl.parseCipherResponse(json);
  }

  async softDeleteCipher(id: string): Promise<void> {
    await this.requestText('PUT',
      BwEndpoints.CIPHER_DELETE.replace('{id}', id), null, true, 'application/json');
  }

  async restoreCipher(id: string): Promise<CipherResponse> {
    const json: Record<string, Object> = await this.requestJson('PUT',
      BwEndpoints.CIPHER_RESTORE.replace('{id}', id), null, true);
    return BwApiClientImpl.parseCipherResponse(json);
  }

  async hardDeleteCipher(id: string): Promise<void> {
    await this.requestText('DELETE',
      BwEndpoints.CIPHER_HARD_DELETE.replace('{id}', id), null, true, 'application/json');
  }

  async listFolders(): Promise<FolderResponse[]> {
    const json: Record<string, Object> =
      await this.requestJson('GET', BwEndpoints.FOLDERS, null, true);
    const folders: FolderResponse[] = [];
    const dataRaw: Object | undefined = json['data'];
    if (dataRaw !== undefined && dataRaw !== null) {
      const arr: Array<Object> = dataRaw as Array<Object>;
      for (let i = 0; i < arr.length; i++) {
        const f: Record<string, Object> = arr[i] as Record<string, Object>;
        folders.push(new FolderResponse(asString(f, 'id') ?? '',
          asString(f, 'name') ?? '', asString(f, 'revisionDate') ?? '',
          asString(f, 'key')));
      }
    }
    return folders;
  }

  async requestAttachmentUpload(cipherId: string, fileName: string, fileSize: number,
    fileKey: string): Promise<AttachmentUploadResponse> {
    const body: Record<string, Object> = {
      'fileName': fileName,
      'fileSize': fileSize as Object,
      'fileKey': fileKey,
      'adminRequest': false as Object
    };
    const json: Record<string, Object> = await this.requestJson('POST',
      BwEndpoints.CIPHER_ATTACHMENT_V2.replace('{id}', cipherId), JSON.stringify(body), true);
    const cipherRaw: Object | undefined = json['cipherResponse'];
    const cipherResponse: CipherResponse =
      (cipherRaw === undefined || cipherRaw === null)
        ? new CipherResponse(cipherId, null, null, 1, false, '', null, '{}')
        : BwApiClientImpl.parseCipherResponse(cipherRaw as Record<string, Object>);
    return new AttachmentUploadResponse(asString(json, 'id') ?? '',
      asString(json, 'url') ?? '', asNumber(json, 'fileUploadType') ?? 0, cipherResponse,
      asString(json, 'cipherMiniResponse'));
  }

  async completeAttachmentUpload(cipherId: string, attachmentId: string,
    dataJson: string): Promise<CipherResponse> {
    const json: Record<string, Object> = await this.requestJson('POST',
      `${BwEndpoints.CIPHERS}/${cipherId}/attachment/${attachmentId}`, dataJson, true);
    return BwApiClientImpl.parseCipherResponse(json);
  }

  async requestAttachmentDownload(cipherId: string, attachmentId: string):
    Promise<AttachmentDownloadResponse> {
    const json: Record<string, Object> = await this.requestJson('GET',
      `${BwEndpoints.CIPHERS}/${cipherId}/attachment/${attachmentId}`, null, true);
    return new AttachmentDownloadResponse(asString(json, 'url') ?? '',
      asString(json, 'key'));
  }

  async deleteAttachment(cipherId: string, attachmentId: string): Promise<void> {
    await this.requestText('DELETE',
      `${BwEndpoints.CIPHERS}/${cipherId}/attachment/${attachmentId}`, null, true, 'application/json');
  }

  /** 刷新令牌（401 重放用）；失败抛会话过期。 */
  private async refreshTokens(): Promise<void> {
    if (this.refreshToken === null) {
      throw new ProtocolError(ProtocolErrorKind.SessionExpired, 'no refresh token');
    }
    const form: string = `grant_type=refresh_token&refresh_token=${encodeURIComponent(this.refreshToken)}`
      + `&client_id=mobile`;
    let text: string;
    try {
      text = await this.execute('POST', BwEndpoints.CONNECT_TOKEN, form,
        'application/x-www-form-urlencoded', null);
    } catch (e) {
      throw new ProtocolError(ProtocolErrorKind.SessionExpired, 'refresh failed');
    }
    const json: Record<string, Object> = JSON.parse(text) as Record<string, Object>;
    const accessToken: string | null = asString(json, 'access_token');
    const refreshToken: string | null = asString(json, 'refresh_token');
    if (accessToken === null || refreshToken === null) {
      throw new ProtocolError(ProtocolErrorKind.SessionExpired, 'refresh response malformed');
    }
    this.accessToken = accessToken;
    this.refreshToken = refreshToken;
    const refreshedKey: string | null = asString(json, 'Key');
    if (refreshedKey !== null) {
      this.protectedUserKey = refreshedKey;
    }
    if (this.onTokensRefreshed !== null) {
      this.onTokensRefreshed(new Session(accessToken, refreshToken, 0, this.protectedUserKey));
    }
  }

  private async requestJson(method: string, path: string, body: string | null,
    authRequired: boolean): Promise<Record<string, Object>> {
    const text: string | null = await this.requestText(method, path, body, authRequired,
      'application/json');
    if (text === null || text.length === 0) {
      return {} as Record<string, Object>;
    }
    return JSON.parse(text) as Record<string, Object>;
  }

  private async requestText(method: string, path: string, body: string | null,
    authRequired: boolean, contentType: string): Promise<string | null> {
    const token: string | null = authRequired ? this.accessToken : null;
    let status: number;
    let responseText: string | null;
    try {
      const response: rcp.Response = await this.executeFull(method, this.baseUrl + path,
        body, contentType, token);
      status = response.statusCode;
      responseText = response.toString();
      if (status === 401 && authRequired && this.refreshToken !== null) {
        await this.refreshTokens();
        const retried: rcp.Response = await this.executeFull(method, this.baseUrl + path,
          body, contentType, this.accessToken);
        status = retried.statusCode;
        responseText = retried.toString();
      }
    } catch (e) {
      throw new ProtocolError(ProtocolErrorKind.Network, 'network error');
    }
    if (status >= 200 && status < 300) {
      return responseText;
    }
    // 诊断（diag-03 教训沿用）：非 2xx 记响应体前 400 字符（校验错误列表/服务器消息，
    // 无请求凭据、无明文）——模型校验失败必须能看到具体字段
    hilog.error(0x0000, 'HallPassHttp', 'http %{public}d %{public}s body=%{public}s',
      status, path, (responseText ?? '').substring(0, 400));
    throw BwApiClientImpl.classify(status, responseText);
  }

  private async execute(method: string, path: string, body: string | null,
    contentType: string, token: string | null): Promise<string> {
    const response: rcp.Response = await this.executeFull(method, this.baseUrl + path,
      body, contentType, token);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw BwApiClientImpl.classify(response.statusCode, response.toString());
    }
    return response.toString() ?? '';
  }

  private async executeFull(method: string, url: string, body: string | null,
    contentType: string, token: string | null): Promise<rcp.Response> {
    const headers: rcp.RequestHeaders = { 'content-type': contentType };
    // 官方云 connectToken 强校验（ClientVersionValidator）：缺失/不可解析 → 拒绝
    // "No client version header found"；V2 加密账号另要求 >= 2025.11.0。
    // 如实上报应用版本，不伪造能力。
    headers['Bitwarden-Client-Name'] = 'mobile';
    headers['Bitwarden-Client-Version'] = this.clientVersion;
    if (token !== null) {
      headers['authorization'] = `Bearer ${token}`;
    }
    const content: rcp.RequestContent | undefined =
      body === null ? undefined : body;
    const request: rcp.Request =
      new rcp.Request(url, method, headers, content, undefined);
    return this.session.fetch(request);
  }

  /** 应用真实版本号（AppScope versionName），读取失败回退 '1.0.0'（可解析即可）。 */
  private static loadClientVersion(): string {
    try {
      const info: bundleManager.BundleInfo =
        bundleManager.getBundleInfoForSelfSync(bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT);
      const version: string = info.versionName;
      return version.length > 0 ? version : '1.0.0';
    } catch (e) {
      return '1.0.0';
    }
  }

  private static parseCipherResponse(json: Record<string, Object>): CipherResponse {
    // dataJson = 服务器返回的整包原样 JSON（提升列之外不再二次加工，plan R2）
    const dataJson: string = JSON.stringify(json);
    return new CipherResponse(
      asString(json, 'id') ?? '',
      asString(json, 'organizationId'),
      asString(json, 'folderId'),
      asNumber(json, 'type') ?? 1,
      json['favorite'] === true,
      asString(json, 'revisionDate') ?? '',
      asString(json, 'deletedDate'),
      dataJson);
  }

  public static payloadToJson(payload: CipherPayload): string {
    const obj: Record<string, Object> = {
      'type': payload.type as Object,
      'name': payload.name,
      'favorite': payload.favorite as Object
    };
    if (payload.folderId !== null) {
      obj['folderId'] = payload.folderId;
    }
    if (payload.notes !== null) {
      obj['notes'] = payload.notes;
    }
    if (payload.fields.length > 0) {
      const fields: Array<Record<string, Object>> = [];
      for (let i = 0; i < payload.fields.length; i++) {
        const f = payload.fields[i];
        const field: Record<string, Object> = {
          'type': f.type as Object,
          'name': f.name
        };
        if (f.value !== null) {
          field['value'] = f.value;
        }
        if (f.linkedId !== null) {
          field['linkedId'] = f.linkedId as Object;
        }
        fields.push(field);
      }
      obj['fields'] = fields;
    }
    if (payload.login !== null) {
      const uris: Array<Record<string, Object>> = [];
      for (let i = 0; i < payload.login.uris.length; i++) {
        const uriObj: Record<string, Object> = { 'uri': payload.login.uris[i].uri };
        if (payload.login.uris[i].match !== null) {
          uriObj['match'] = payload.login.uris[i].match as Object;
        }
        uris.push(uriObj);
      }
      const login: Record<string, Object> = {
        'username': payload.login.username as Object,
        'password': payload.login.password as Object,
        'totp': payload.login.totp as Object,
        'uris': uris
      };
      obj['login'] = login;
    }
    if (payload.card !== null) {
      const card: Record<string, Object> = {
        'cardholderName': payload.card.cardholderName as Object,
        'brand': payload.card.brand as Object,
        'number': payload.card.number as Object,
        'expMonth': payload.card.expMonth as Object,
        'expYear': payload.card.expYear as Object,
        'code': payload.card.code as Object
      };
      obj['card'] = card;
    }
    if (payload.identity !== null) {
      const identity: Record<string, Object> = {
        'firstName': payload.identity.firstName as Object,
        'middleName': payload.identity.middleName as Object,
        'lastName': payload.identity.lastName as Object,
        'company': payload.identity.company as Object,
        'email': payload.identity.email as Object,
        'phone': payload.identity.phone as Object,
        'ssn': payload.identity.ssn as Object,
        'passportNumber': payload.identity.passportNumber as Object,
        'licenseNumber': payload.identity.licenseNumber as Object,
        'address1': payload.identity.address1 as Object,
        'address2': payload.identity.address2 as Object,
        'address3': payload.identity.address3 as Object,
        'city': payload.identity.city as Object,
        'state': payload.identity.state as Object,
        'postalCode': payload.identity.postalCode as Object,
        'country': payload.identity.country as Object
      };
      obj['identity'] = identity;
    }
    if (payload.secureNote !== null) {
      const sn: Record<string, Object> = {
        'type': payload.secureNote.type as Object
      };
      obj['secureNote'] = sn;
    } else if (payload.type === ItemType.SecureNote) {
      const sn: Record<string, Object> = {
        'type': 0 as Object
      };
      obj['secureNote'] = sn;
    }
    if (payload.attachments.length > 0) {
      const attachments: Array<Record<string, Object>> = [];
      for (let i = 0; i < payload.attachments.length; i++) {
        const a = payload.attachments[i];
        attachments.push({
          'id': a.id,
          'fileName': a.fileName,
          'size': a.size as Object,
          'key': a.key,
          'url': a.url
        });
      }
      obj['attachments'] = attachments;
    }
    if (payload.lastKnownRevisionDate !== null) {
      obj['lastKnownRevisionDate'] = payload.lastKnownRevisionDate;
    }
    // T28 V2 写路径：条目密钥密文随载荷提交（官方云 V2 账号必需）
    if (payload.key !== null) {
      obj['key'] = payload.key;
    }
    if (payload.passwordHistory.length > 0) {
      const history: Array<Record<string, Object>> = [];
      for (let i = 0; i < payload.passwordHistory.length; i++) {
        const h = payload.passwordHistory[i];
        const entry: Record<string, Object> = {
          'password': h.password,
          'lastModifiedDate': h.lastModifiedDate
        };
        // T28 fix-08：官方云模型 LastUsedDate 必填（WriteService 已兜底非 null）
        if (h.lastUsedDate !== null) {
          entry['lastUsedDate'] = h.lastUsedDate;
        }
        history.push(entry);
      }
      obj['passwordHistory'] = history;
    }
    return JSON.stringify(obj);
  }

  /** 错误分类（票 09 要点）：2FA/凭据/配额/会话过期/服务端。暴露为静态便于测试。
   *  DIAG-01 阶段二：错误体里的原始 Message 透传到 serverMessage（UI Server 兜底展示）。 */
  static classify(status: number, bodyText: string | null): ProtocolError {
    let body: Record<string, Object> | null = null;
    if (bodyText !== null && bodyText.length > 0) {
      try {
        body = JSON.parse(bodyText) as Record<string, Object>;
      } catch (e) {
        body = null;
      }
    }
    const serverMessage: string | null = BwApiClientImpl.extractServerMessage(body);
    if (status === 400 && body !== null) {
      const providersRaw: Object | undefined = body['TwoFactorProviders'];
      if (providersRaw !== undefined && providersRaw !== null) {
        const providers: number[] = [];
        const providerObj: Record<string, Object> = providersRaw as Record<string, Object>;
        const keys: string[] = Object.keys(providerObj);
        for (let i = 0; i < keys.length; i++) {
          providers.push(Number.parseInt(keys[i], 10));
        }
        return new TwoFactorRequiredError(providers);
      }
      const description: string = (asString(body, 'ErrorDescription')
        ?? asString(body, 'error_description') ?? '').toLowerCase();
      const error: string = (asString(body, 'Error') ?? asString(body, 'error') ?? '').toLowerCase();
      if (description.indexOf('captcha') >= 0 || body['HCaptcha_SiteKey'] !== undefined) {
        // captcha 流程未实现（DIAG-01 待决策）：归 Server 并透传原始消息，不误报凭据错误
        return new ProtocolError(ProtocolErrorKind.Server, 'captcha required', status,
          serverMessage);
      }
      if (description.indexOf('storage') >= 0 || description.indexOf('quota') >= 0
        || error.indexOf('storage') >= 0) {
        return new ProtocolError(ProtocolErrorKind.Quota, 'storage quota exceeded', status);
      }
      if (error.indexOf('invalid_grant') >= 0
        && description.indexOf('invalid username or password') >= 0) {
        return new ProtocolError(ProtocolErrorKind.Credential, 'invalid credentials', status);
      }
      // 新设备验证（官方云 DeviceValidator）：required=服务器已向邮箱发送验证码；
      // invalid=验证码错误，可留在输入步骤重试。serverMessage 一并匹配
      // （错误文本可能只出现在 ErrorModel.Message，或与 error_description 大小写不同）。
      const combined: string = `${description} ${(serverMessage ?? '').toLowerCase()}`;
      if (combined.indexOf('invalid new device otp') >= 0) {
        return new ProtocolError(ProtocolErrorKind.NewDeviceOtpInvalid,
          'invalid new device otp', status, serverMessage);
      }
      if (combined.indexOf('new device verification required') >= 0) {
        return new ProtocolError(ProtocolErrorKind.NewDeviceVerification,
          'new device verification required', status, serverMessage);
      }
      if (description.indexOf('two factor') >= 0) {
        return new ProtocolError(ProtocolErrorKind.TwoFactor, 'two factor required', status);
      }
      if (description.indexOf('refresh token') >= 0 || description.indexOf('expired') >= 0) {
        return new ProtocolError(ProtocolErrorKind.SessionExpired, 'session expired', status);
      }
      if (error.indexOf('invalid_grant') >= 0) {
        return new ProtocolError(ProtocolErrorKind.Credential, 'invalid grant', status);
      }
    }
    if (status === 401) {
      return new ProtocolError(ProtocolErrorKind.SessionExpired, 'unauthorized', status);
    }
    if (status === 429 || status >= 500) {
      return new ProtocolError(ProtocolErrorKind.Server, `server error ${status}`, status,
        serverMessage);
    }
    return new ProtocolError(ProtocolErrorKind.Server, `http ${status}`, status, serverMessage);
  }

  /** 服务器错误体里的原始可读消息：官方云嵌在 ErrorModel.Message，
   *  也兼容顶层 Message/message（部分自建实现）。无则 null。 */
  private static extractServerMessage(body: Record<string, Object> | null): string | null {
    if (body === null) {
      return null;
    }
    const errorModelRaw: Object | undefined = body['ErrorModel'];
    if (errorModelRaw !== undefined && errorModelRaw !== null
      && typeof errorModelRaw === 'object') {
      const msg: string | null =
        asString(errorModelRaw as Record<string, Object>, 'Message');
      if (msg !== null && msg.length > 0) {
        return msg;
      }
    }
    return asString(body, 'Message') ?? asString(body, 'message');
  }

  /** 官方云判定（T28：判定逻辑收口到域内 BwCloud，WriteService V2 写路径共用）。 */
  static isOfficialCloud(baseUrl: string): boolean {
    return BwCloud.isOfficialCloud(baseUrl);
  }
}
