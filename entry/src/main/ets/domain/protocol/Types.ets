/*
 * SPDX-FileCopyrightText: 2026 Liugt
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import { EncString } from '../model/EncString';

/**
 * Bitwarden 协议端点路径常量（仅个人空间，范围守卫：无组织/集合端点，ADR-0001 / spec §6）。
 * base url 由实现层注入（官方云 https://vault.bitwarden.com 或自建 Vaultwarden）。
 */
export class BwEndpoints {
  static readonly PRELOGIN: string = '/api/accounts/prelogin';
  /** 官方云 prelogin（2026 布局）：挂在 identity 域 /accounts/prelogin，
   *  vault.bitwarden.com 以 /identity/accounts/prelogin 提供同路由。
   *  Vaultwarden 无此路由（core 路由只挂 /api），故按后端二选一（BwApiClientImpl）。 */
  static readonly PRELOGIN_OFFICIAL: string = '/identity/accounts/prelogin';
  static readonly CONNECT_TOKEN: string = '/identity/connect/token';
  static readonly SYNC: string = '/api/sync';
  static readonly CIPHERS: string = '/api/ciphers';
  static readonly CIPHER_DELETE: string = '/api/ciphers/{id}/delete';
  static readonly CIPHER_RESTORE: string = '/api/ciphers/{id}/restore';
  static readonly CIPHER_HARD_DELETE: string = '/api/ciphers/{id}';
  static readonly FOLDERS: string = '/api/folders';
  static readonly CIPHER_ATTACHMENT: string = '/api/ciphers/{id}/attachment';
  static readonly CIPHER_ATTACHMENT_V2: string = '/api/ciphers/{id}/attachment/v2';
  static readonly ATTACHMENT_DOWNLOAD: string = '/api/ciphers/{cipherId}/attachment/{attachmentId}';
}

/** 两步验证提供方（Bitwarden 线上数值）。MVP 仅支持 0/1（spec §6 Out of Scope：WebAuthn/Duo/YubiKey）。 */
export const TWO_FACTOR_AUTHENTICATOR: number = 0;
export const TWO_FACTOR_EMAIL: number = 1;

/** 协议错误分类（可分类错误 → UI 文案走 i18n，spec F2 边界情况）。 */
export enum ProtocolErrorKind {
  Network = 'network',
  Credential = 'credential',
  TwoFactor = 'twoFactor',
  /** 新设备验证：服务器已向邮箱发送验证码，需以 NewDeviceOtp 重提交 token 请求 */
  NewDeviceVerification = 'newDeviceVerification',
  /** 新设备验证码错误（可留在输入步骤重试，服务器不自动重发） */
  NewDeviceOtpInvalid = 'newDeviceOtpInvalid',
  SessionExpired = 'sessionExpired',
  Quota = 'quota',
  Server = 'server'
}

/** 可分类协议错误：kind 供 UI 决定文案与可重试性，message 不含敏感内容。
 *  serverMessage 为服务器错误响应里的原始可读 Message（ErrorModel.Message 等），
 *  UI 在 Server 兜底场景直接展示以便诊断；无则 null 走 i18n 兜底文案。 */
export class ProtocolError extends Error {
  readonly kind: ProtocolErrorKind;
  readonly httpStatus: number | null;
  readonly serverMessage: string | null;

  constructor(kind: ProtocolErrorKind, message: string, httpStatus: number | null = null,
    serverMessage: string | null = null) {
    super(message);
    this.kind = kind;
    this.httpStatus = httpStatus;
    this.serverMessage = serverMessage;
  }
}

/** 2FA 必需错误（connectToken 返回 TwoFactorProviders 时抛出），携带可用提供方数值列表。 */
export class TwoFactorRequiredError extends ProtocolError {
  readonly providers: number[];

  constructor(providers: number[]) {
    super(ProtocolErrorKind.TwoFactor, 'two factor required');
    this.providers = providers;
  }
}

/** prelogin 响应：账号 KDF 参数。iterations 为 PBKDF2 迭代数；memory 单位 KiB
 *  （服务器 kdfMemory 以 MB 计，实现层 ×1024 换算）；数值为 Bitwarden 线上值（KdfType 0/1）。 */
export class PreloginResponse {
  readonly kdfType: number;
  readonly iterations: number | null;
  readonly memory: number | null;
  readonly parallelism: number | null;

  constructor(kdfType: number, iterations: number | null = null,
    memory: number | null = null, parallelism: number | null = null) {
    this.kdfType = kdfType;
    this.iterations = iterations;
    this.memory = memory;
    this.parallelism = parallelism;
  }
}

/** token 请求（密码授予流程，spec F2）：主密码仅以 masterPasswordHash 形态出现，明文不出网络。 */
export class TokenRequest {
  readonly username: string;
  readonly passwordHash: string;
  readonly twoFactorProvider: number | null;
  readonly twoFactorToken: string | null;
  readonly twoFactorRemember: boolean;
  /** 新设备验证码（官方云 new device verification）：邮箱收到的 OTP，重提交时随 token 请求携带 */
  readonly newDeviceOtp: string | null;

  constructor(username: string, passwordHash: string, twoFactorProvider: number | null = null,
    twoFactorToken: string | null = null, twoFactorRemember: boolean = false,
    newDeviceOtp: string | null = null) {
    this.username = username;
    this.passwordHash = passwordHash;
    this.twoFactorProvider = twoFactorProvider;
    this.twoFactorToken = twoFactorToken;
    this.twoFactorRemember = twoFactorRemember;
    this.newDeviceOtp = newDeviceOtp;
  }
}

/** token 响应：会话令牌（仅内存/Asset，plan D3 安全基线）。expiresIn 为秒。
 *  protectedUserKey 为服务器用户对称密钥密文（EncString 串，由拉伸主密钥包裹），
 *  条目/文件夹/附件一律用它加解密（Bitwarden 协议语义，E2E-01 fix-06）。 */
export class TokenResponse {
  readonly accessToken: string;
  readonly refreshToken: string;
  readonly expiresIn: number;
  readonly protectedUserKey: string | null;

  constructor(accessToken: string, refreshToken: string, expiresIn: number,
    protectedUserKey: string | null = null) {
    this.accessToken = accessToken;
    this.refreshToken = refreshToken;
    this.expiresIn = expiresIn;
    this.protectedUserKey = protectedUserKey;
  }
}

/** 同步 profile 片段（个人空间，ADR-0001：不解析组织字段）。 */
export class ProfileResponse {
  readonly id: string;
  readonly email: string;

  constructor(id: string, email: string) {
    this.id = id;
    this.email = email;
  }
}

/**
 * 官方云判定（域内共享，T28）：WriteService 的 V2 写路径（生成 per-item key）与
 * BwApiClientImpl 的 prelogin 双路径共用；实现层与本判定必须一致。
 * bitwarden.com / bitwarden.eu 的裸域或任一子域（大小写不敏感，丢弃 userinfo/端口/路径）。
 */
export class BwCloud {
  static isOfficialCloud(baseUrl: string): boolean {
    const lower: string = baseUrl.trim().toLowerCase();
    const withoutScheme: string = lower.startsWith('https://') ? lower.substring(8)
      : (lower.startsWith('http://') ? lower.substring(7) : lower);
    const hostStart: number = withoutScheme.indexOf('@') + 1;
    const hostPort: string = withoutScheme.substring(hostStart).split('/')[0];
    const host: string = hostPort.split(':')[0];
    return host === 'bitwarden.com' || host === 'www.bitwarden.com'
      || host === 'bitwarden.eu' || host.endsWith('.bitwarden.com')
      || host.endsWith('.bitwarden.eu');
  }
}

/** 文件夹响应。name 为 EncString 串行化文本（密文原样）；key 为 per-folder 密钥密文
 *  （官方云 V2 账号可能出现，T28；null = 用户密钥加密）。 */
export class FolderResponse {
  readonly id: string;
  readonly name: string;
  readonly revisionDate: string;
  readonly key: string | null;

  constructor(id: string, name: string, revisionDate: string, key: string | null = null) {
    this.id = id;
    this.name = name;
    this.revisionDate = revisionDate;
    this.key = key;
  }
}

/**
 * 条目响应（plan D3/R2）：元数据列提升为显式字段；其余密文子对象
 * （login/card/identity/fields/notes/attachments/key）整包序列化为 dataJson 原样落 RDB
 * （schema 冻结不迁移，结构解析只在 domain 一处）。
 */
export class CipherResponse {
  readonly id: string;
  readonly organizationId: string | null;
  readonly folderId: string | null;
  readonly type: number;
  readonly favorite: boolean;
  readonly revisionDate: string;
  readonly deletedDate: string | null;
  readonly dataJson: string;

  constructor(id: string, organizationId: string | null, folderId: string | null, type: number,
    favorite: boolean, revisionDate: string, deletedDate: string | null, dataJson: string) {
    this.id = id;
    this.organizationId = organizationId;
    this.folderId = folderId;
    this.type = type;
    this.favorite = favorite;
    this.revisionDate = revisionDate;
    this.deletedDate = deletedDate;
    this.dataJson = dataJson;
  }
}

/** 全量同步响应（个人空间；collections 不请求——MVP 无组织/集合，ADR-0001）。 */
export class SyncResponse {
  readonly profile: ProfileResponse;
  readonly folders: FolderResponse[];
  readonly ciphers: CipherResponse[];

  constructor(profile: ProfileResponse, folders: FolderResponse[], ciphers: CipherResponse[]) {
    this.profile = profile;
    this.folders = folders;
    this.ciphers = ciphers;
  }
}

/** 写路径载荷：自定义字段（值为 EncString 串行化文本）。 */
export class FieldPayload {
  readonly type: number;
  readonly name: string;
  readonly value: string | null;
  readonly linkedId: number | null;

  constructor(type: number, name: string, value: string | null, linkedId: number | null = null) {
    this.type = type;
    this.name = name;
    this.value = value;
    this.linkedId = linkedId;
  }
}

/** 写路径载荷：URI（match 为 Bitwarden 线上匹配规则数值，MVP 不设默认 null）。 */
export class UriPayload {
  readonly uri: string;
  readonly match: number | null;

  constructor(uri: string, match: number | null = null) {
    this.uri = uri;
    this.match = match;
  }
}

/** 写路径载荷：登录详情（全部为 EncString 串行化文本或 null）。 */
export class LoginPayload {
  readonly username: string | null;
  readonly password: string | null;
  readonly totp: string | null;
  readonly uris: UriPayload[];

  constructor(username: string | null, password: string | null, totp: string | null,
    uris: UriPayload[] = []) {
    this.username = username;
    this.password = password;
    this.totp = totp;
    this.uris = uris;
  }
}

/** 写路径载荷：银行卡详情。 */
export class CardPayload {
  readonly cardholderName: string | null;
  readonly brand: string | null;
  readonly number: string | null;
  readonly expMonth: string | null;
  readonly expYear: string | null;
  readonly code: string | null;

  constructor(cardholderName: string | null, brand: string | null, number: string | null,
    expMonth: string | null, expYear: string | null, code: string | null) {
    this.cardholderName = cardholderName;
    this.brand = brand;
    this.number = number;
    this.expMonth = expMonth;
    this.expYear = expYear;
    this.code = code;
  }
}

/** 写路径载荷：身份详情（MVP 表单暴露的子集，其余字段恒 null）。 */
export class IdentityPayload {
  readonly firstName: string | null;
  readonly middleName: string | null;
  readonly lastName: string | null;
  readonly company: string | null;
  readonly email: string | null;
  readonly phone: string | null;
  readonly ssn: string | null;
  readonly passportNumber: string | null;
  readonly licenseNumber: string | null;
  readonly address1: string | null;
  readonly address2: string | null;
  readonly address3: string | null;
  readonly city: string | null;
  readonly state: string | null;
  readonly postalCode: string | null;
  readonly country: string | null;

  constructor(firstName: string | null = null, middleName: string | null = null,
    lastName: string | null = null, company: string | null = null, email: string | null = null,
    phone: string | null = null, ssn: string | null = null, passportNumber: string | null = null,
    licenseNumber: string | null = null, address1: string | null = null,
    address2: string | null = null, address3: string | null = null, city: string | null = null,
    state: string | null = null, postalCode: string | null = null, country: string | null = null) {
    this.firstName = firstName;
    this.middleName = middleName;
    this.lastName = lastName;
    this.company = company;
    this.email = email;
    this.phone = phone;
    this.ssn = ssn;
    this.passportNumber = passportNumber;
    this.licenseNumber = licenseNumber;
    this.address1 = address1;
    this.address2 = address2;
    this.address3 = address3;
    this.city = city;
    this.state = state;
    this.postalCode = postalCode;
    this.country = country;
  }
}

/** 附件元数据（写路径回传时随条目保存）。 */
export class AttachmentPayload {
  readonly id: string;
  readonly fileName: string;
  readonly size: number;
  readonly key: string;
  readonly url: string;

  constructor(id: string, fileName: string, size: number, key: string, url: string) {
    this.id = id;
    this.fileName = fileName;
    this.size = size;
    this.key = key;
    this.url = url;
  }
}

/** 密码历史载荷（T27，T27：Bitwarden PasswordHistory；lastModifiedDate 为 ISO 串，密码为 EncString 串）。 */
export class PasswordHistoryPayload {
  readonly password: string;
  readonly lastModifiedDate: string;
  /** T28 fix-08：官方云模型必填（LastUsedDate）；缺失时以 lastModifiedDate 兜底。 */
  readonly lastUsedDate: string | null;

  constructor(password: string, lastModifiedDate: string, lastUsedDate: string | null = null) {
    this.password = password;
    this.lastModifiedDate = lastModifiedDate;
    this.lastUsedDate = lastUsedDate;
  }
}

/**
 * 笔记条目载荷（Bitwarden / Vaultwarden 契约：type 默认为 0 Generic）。
 */
export class SecureNotePayload {
  readonly type: number;

  constructor(type: number = 0) {
    this.type = type;
  }
}

/**
 * 保存/更新条目载荷（WriteService 构造，协议层原样提交，spec F8）。
 * EncString 字段均为串行化文本；id 为 null 表示新建。
 */
export class CipherPayload {
  readonly id: string | null;
  readonly type: number;
  readonly folderId: string | null;
  readonly favorite: boolean;
  readonly name: string;
  readonly notes: string | null;
  readonly fields: FieldPayload[];
  readonly login: LoginPayload | null;
  readonly card: CardPayload | null;
  readonly identity: IdentityPayload | null;
  readonly secureNote: SecureNotePayload | null;
  readonly attachments: AttachmentPayload[];
  readonly lastKnownRevisionDate: string | null;
  /** 密码历史（T27）：改密/编辑保存时由 WriteService 从既有条目合并，空数组不提交。 */
  readonly passwordHistory: PasswordHistoryPayload[];
  /** 条目密钥密文（T28，官方云 V2 写路径）：非 null 时随载荷提交 `key` 字段，
   *  全部字段已用该条目密钥整包重加密；null = 传统用户密钥单密钥加密。 */
  readonly key: string | null;

  constructor(id: string | null, type: number, folderId: string | null, favorite: boolean,
    name: string, notes: string | null, fields: FieldPayload[], login: LoginPayload | null,
    card: CardPayload | null, identity: IdentityPayload | null,
    secureNote: SecureNotePayload | null = null,
    attachments: AttachmentPayload[] = [], lastKnownRevisionDate: string | null = null,
    passwordHistory: PasswordHistoryPayload[] = [], key: string | null = null) {
    this.id = id;
    this.type = type;
    this.folderId = folderId;
    this.favorite = favorite;
    this.name = name;
    this.notes = notes;
    this.fields = fields;
    this.login = login;
    this.card = card;
    this.identity = identity;
    this.secureNote = secureNote;
    this.attachments = attachments;
    this.lastKnownRevisionDate = lastKnownRevisionDate;
    this.passwordHistory = passwordHistory;
    this.key = key;
  }
}

/** 附件 v2 上传响应：取得直传 URL 与回传登记所需参数。 */
export class AttachmentUploadResponse {
  readonly attachmentId: string;
  readonly url: string;
  readonly fileUploadType: number;
  readonly cipherResponse: CipherResponse;
  readonly cipherMiniResponseKey: string | null;

  constructor(attachmentId: string, url: string, fileUploadType: number,
    cipherResponse: CipherResponse, cipherMiniResponseKey: string | null = null) {
    this.attachmentId = attachmentId;
    this.url = url;
    this.fileUploadType = fileUploadType;
    this.cipherResponse = cipherResponse;
    this.cipherMiniResponseKey = cipherMiniResponseKey;
  }
}

/** 附件 v2 下载响应：直传下载 URL。 */
export class AttachmentDownloadResponse {
  readonly url: string;
  readonly key: string | null;

  constructor(url: string, key: string | null = null) {
    this.url = url;
    this.key = key;
  }
}

/** EncString 协议层透传别名场景：本地导出以免实现层重复 import 路径（仅类型复用）。 */
export type EncStringValue = EncString;
