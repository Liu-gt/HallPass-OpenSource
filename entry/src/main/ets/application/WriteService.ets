/*
 * SPDX-FileCopyrightText: 2026 Liugt
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import { BwApiClient } from '../domain/protocol/BwApiClient';
import { BwCloud, CipherPayload, FieldPayload, UriPayload, LoginPayload, CardPayload,
  IdentityPayload, SecureNotePayload, AttachmentPayload, PasswordHistoryPayload, CipherResponse, ProtocolError,
  ProtocolErrorKind }
  from '../domain/protocol/Types';
import { EncStringCodec } from '../domain/crypto/EncStringCodec';
import { Cipher } from '../domain/model/Cipher';
import { VaultRepository } from '../domain/repository/VaultRepository';
import { CryptoEngine, SymmetricKey } from '../domain/crypto/CryptoEngine';
import { Utf8 } from '../domain/crypto/Utf8';
import { ItemType } from '../domain/model/ItemType';
import { EncString } from '../domain/model/EncString';
import { OutboxOp } from '../domain/model/OutboxOp';
import { SessionService } from './SessionService';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { CipherView } from './state/VaultMemoryIndex';
import { FieldType2 } from './state/VaultMemoryIndex';

/** 表单草稿自定义字段。 */
@ObservedV2
export class DraftField {
  @Trace name: string = '';
  @Trace value: string = '';
  @Trace type: number = 0;
  @Trace linkedId: number | null = null;

  constructor(name: string, value: string, type: number = 0, linkedId: number | null = null) {
    this.name = name;
    this.value = value;
    this.type = type;
    this.linkedId = linkedId;
  }
}

/** 新建/编辑草稿（票 19 表单填充；全部明文，仅内存存在）。 */
@ObservedV2
export class CipherDraft {
  @Trace id: string | null = null;
  @Trace type: ItemType = ItemType.Login;
  @Trace folderId: string | null = null;
  @Trace favorite: boolean = false;
  @Trace name: string = '';
  @Trace notes: string = '';
  @Trace username: string = '';
  @Trace password: string = '';
  @Trace totp: string = '';
  @Trace uris: string[] = [];
  /** 自定义字段列表：@Trace 令 addField 的 push 触发表单重绘。 */
  @Trace fields: DraftField[] = [];
  @Trace cardholderName: string = '';
  @Trace brand: string = '';
  @Trace cardNumber: string = '';
  @Trace expMonth: string = '';
  @Trace expYear: string = '';
  @Trace cardCode: string = '';
  @Trace firstName: string = '';
  @Trace middleName: string = '';
  @Trace lastName: string = '';
  @Trace company: string = '';
  @Trace identityEmail: string = '';
  @Trace phone: string = '';
  @Trace ssn: string = '';
  @Trace passportNumber: string = '';
  @Trace licenseNumber: string = '';
  @Trace address1: string = '';
  @Trace address2: string = '';
  @Trace address3: string = '';
  @Trace city: string = '';
  @Trace state: string = '';
  @Trace postalCode: string = '';
  @Trace country: string = '';
  /** 既有附件（编辑时保留；T19 从视图回填） */
  @Trace attachments: AttachmentPayload[] = [];
  @Trace lastKnownRevisionDate: string | null = null;
}

/** 保存结果：saved = 已同步；queued = 离线入队（UI 提示"已排队待同步"）。 */
export type WriteResult = 'saved' | 'queued';

/**
 * WriteService（票 11，spec F8/F9 写路径约束、plan D3 数据流向）：
 * 明文草稿 → 加密载荷 → 上传；成功 → RDB/索引更新；网络失败 → outbox 入队（载荷已全密文）
 * 并返回 queued；解锁且联网后按序重放（replayOutbox，SyncService 解锁事件触发）。
 */
export class WriteService {
  private readonly client: BwApiClient;
  private readonly repository: VaultRepository;
  private readonly crypto: CryptoEngine;
  private readonly sessionService: SessionService;
  private readonly onUpdated: (response: CipherResponse) => Promise<void>;
  private replaying: boolean = false;

  constructor(client: BwApiClient, repository: VaultRepository, crypto: CryptoEngine,
    sessionService: SessionService,
    onUpdated: (response: CipherResponse) => Promise<void>) {
    this.client = client;
    this.repository = repository;
    this.crypto = crypto;
    this.sessionService = sessionService;
    this.onUpdated = onUpdated;
  }

  async save(draft: CipherDraft): Promise<WriteResult> {
    const userKey: SymmetricKey | null = this.sessionService.userKey();
    if (userKey === null) {
      throw new Error('WriteService: locked');
    }
    // T28 V2 写路径：条目密钥解析——既有 per-key 条目沿用其密钥整包重加密；
    // 官方云 V2 会话（有服务器用户密钥）新建/升级条目生成新条目密钥；
    // 自建 Vaultwarden/无服务器密钥保持用户密钥单密钥加密（协议兼容）。
    const vaultId: string = this.sessionService.state.vaultId;
    const existing: Cipher | null =
      draft.id === null ? null : await this.repository.getCipher(vaultId, draft.id);
    let itemKey: SymmetricKey = userKey;
    let payloadKey: string | null = null;
    let mode: string = 'legacy';
    if (existing !== null && existing.cipherKey !== null) {
      mode = 'reuse';
      try {
        itemKey = await this.crypto.unwrapUserKey(existing.cipherKey, userKey);
      } catch (e) {
        const err: Error = e as Error;
        hilog.error(0x0000, 'HallPassWrite',
          'itemKey unwrap fail id=%{public}s: %{public}s', draft.id ?? '', err.message ?? '');
        throw e as Error;
      }
      payloadKey = existing.cipherKey;
    } else if (BwCloud.isOfficialCloud(this.sessionService.state.serverUrl)
      && this.sessionService.protectedUserKey() !== null) {
      mode = 'generate';
      const fresh: Uint8Array = await this.crypto.randomBytes(64);
      itemKey = new SymmetricKey(fresh.slice(0, 32), fresh.slice(32, 64));
      payloadKey = EncStringCodec.encode(await this.crypto.makeEncString(fresh, userKey));
    }
    hilog.info(0x0000, 'HallPassWrite', 'save begin: id=%{public}s mode=%{public}s',
      draft.id ?? 'new', mode);
    // T27（spec F8）：登录条目改密 → 旧密码入历史；重编码保存合并既有历史防丢失。
    // 历史以本地缓存既有条目为准（draft 不携带历史，收藏/移动等编辑也不会清空历史）。
    let history: PasswordHistoryPayload[] = [];
    if (draft.type === ItemType.Login) {
      history = await this.buildHistory(draft, itemKey, existing);
    }
    const payload: CipherPayload = await this.buildPayload(draft, itemKey, history, payloadKey);
    try {
      const response: CipherResponse = await this.client.saveCipher(payload);
      hilog.info(0x0000, 'HallPassWrite', 'save ok: id=%{public}s', response.id);
      await this.onUpdated(response);
      return 'saved';
    } catch (e) {
      const err: Error = e as Error;
      const proto: ProtocolError | null = e instanceof ProtocolError ? e as ProtocolError : null;
      hilog.error(0x0000, 'HallPassWrite',
        'save fail: kind=%{public}s status=%{public}s msg=%{public}s server=%{public}s',
        proto === null ? 'unknown' : proto.kind,
        proto === null || proto.httpStatus === null ? '-' : `${proto.httpStatus}`,
        err.message ?? '', proto === null ? '-' : (proto.serverMessage ?? '-'));
      if (proto !== null && proto.kind === ProtocolErrorKind.Network) {
        await this.repository.enqueueOp(draft.id ?? WriteService.newId(), 'save',
          JSON.stringify(payload));
        return 'queued';
      }
      throw e as Error;
    }
  }

  /**
   * 密码历史合并（T27）：既有历史来自本地缓存条目（密文原样透传）；
   * 登录条目密码与既有不同时追加旧密码（旧值密文 + 当前时间）。新建条目无历史。
   */
  /**
   * 密码历史合并（T27）：既有历史来自本地缓存条目（密文原样透传）；
   * 登录条目密码与既有不同时追加旧密码（旧值密文 + 当前时间）。新建条目无历史。
   * T28：既有条目为 per-key 条目时以条目密钥解密旧密码（与字段加密密钥一致）。
   */
  private async buildHistory(draft: CipherDraft, itemKey: SymmetricKey,
    existing: Cipher | null): Promise<PasswordHistoryPayload[]> {
    if (draft.id === null || existing === null) {
      return [];
    }
    const history: PasswordHistoryPayload[] = [];
    for (let i = 0; i < existing.passwordHistory.length; i++) {
      const h = existing.passwordHistory[i];
      // T28 fix-08：官方云模型 LastUsedDate 必填；Vaultwarden/旧数据缺省时以更改时间兜底
      history.push(new PasswordHistoryPayload(EncStringCodec.encode(h.password),
        WriteService.toIso(h.lastModifiedDate),
        h.lastUsedDate === null ? WriteService.toIso(h.lastModifiedDate)
          : WriteService.toIso(h.lastUsedDate)));
    }
    const oldPassword: EncString | null = existing.login === null ? null : existing.login.password;
    if (oldPassword === null) {
      return history;
    }
    const oldPlain: string = await this.crypto.decryptToString(oldPassword, itemKey);
    if (oldPlain !== draft.password && draft.password.length > 0) {
      history.push(new PasswordHistoryPayload(EncStringCodec.encode(oldPassword),
        WriteService.toIso(Date.now()), WriteService.toIso(Date.now())));
    }
    return history;
  }

  private static toIso(epochMs: number): string {
    return new Date(epochMs).toISOString();
  }

  async softDelete(id: string): Promise<WriteResult> {
    try {
      await this.client.softDeleteCipher(id);
      await this.localCipher(id, Date.now());
      return 'saved';
    } catch (e) {
      if (e instanceof ProtocolError && e.kind === ProtocolErrorKind.Network) {
        await this.repository.enqueueOp(id, 'softDelete', null);
        await this.localCipher(id, Date.now());
        return 'queued';
      }
      throw e as Error;
    }
  }

  async restore(id: string): Promise<WriteResult> {
    try {
      const response: CipherResponse = await this.client.restoreCipher(id);
      await this.onUpdated(response);
      return 'saved';
    } catch (e) {
      if (e instanceof ProtocolError && e.kind === ProtocolErrorKind.Network) {
        await this.repository.enqueueOp(id, 'restore', null);
        await this.localCipher(id, null);
        return 'queued';
      }
      throw e as Error;
    }
  }

  async hardDelete(id: string): Promise<WriteResult> {
    try {
      await this.client.hardDeleteCipher(id);
      await this.repository.removeCipher(this.sessionService.state.vaultId, id);
      this.onRemovedLocally(id);
      return 'saved';
    } catch (e) {
      if (e instanceof ProtocolError && e.kind === ProtocolErrorKind.Network) {
        await this.repository.enqueueOp(id, 'hardDelete', null);
        return 'queued';
      }
      throw e as Error;
    }
  }

  /** 解锁且联网后按序重放（spec F9）；网络失败即停（保序），其余失败跳过并确认。 */
  async replayOutbox(): Promise<void> {
    if (this.replaying) {
      return;
    }
    this.replaying = true;
    try {
      let ops: OutboxOp[] = await this.repository.peekOutbox();
      while (ops.length > 0) {
        const op: OutboxOp = ops[0];
        try {
          await this.replayOne(op);
          await this.repository.ackOp(op.seq);
        } catch (e) {
          if (e instanceof ProtocolError && e.kind === ProtocolErrorKind.Network) {
            return; // 保持队列，等待下次解锁
          }
          await this.repository.ackOp(op.seq); // 永久性失败：跳过该条避免堵队
        }
        ops = await this.repository.peekOutbox();
      }
    } finally {
      this.replaying = false;
    }
  }

  private async replayOne(op: OutboxOp): Promise<void> {
    if (op.op === 'save') {
      const payload: CipherPayload | null =
        op.payload === null ? null : WriteService.payloadFromJson(op.payload);
      if (payload !== null) {
        const response: CipherResponse = await this.client.saveCipher(payload);
        await this.onUpdated(response);
      }
    } else if (op.op === 'softDelete') {
      await this.client.softDeleteCipher(op.cipherId);
      await this.localCipher(op.cipherId, Date.now());
    } else if (op.op === 'restore') {
      await this.client.restoreCipher(op.cipherId);
      await this.localCipher(op.cipherId, null);
    } else if (op.op === 'hardDelete') {
      await this.client.hardDeleteCipher(op.cipherId);
      await this.repository.removeCipher(this.sessionService.state.vaultId, op.cipherId);
      this.onRemovedLocally(op.cipherId);
    }
  }

  private async buildPayload(draft: CipherDraft, key: SymmetricKey,
    history: PasswordHistoryPayload[] = [], payloadKey: string | null = null):
    Promise<CipherPayload> {
    const encOrNull = async (text: string): Promise<string | null> => {
      if (text.length === 0) {
        return null;
      }
      const enc: EncString = await this.crypto.makeEncString(Utf8.encode(text), key);
      return EncStringCodec.encode(enc);
    };
    let login: LoginPayload | null = null;
    let card: CardPayload | null = null;
    let identity: IdentityPayload | null = null;
    let secureNote: SecureNotePayload | null = null;
    if (draft.type === ItemType.Login) {
      const uris: UriPayload[] = [];
      for (let i = 0; i < draft.uris.length; i++) {
        const uri: string | null = await encOrNull(draft.uris[i]);
        if (uri !== null) {
          uris.push(new UriPayload(uri));
        }
      }
      login = new LoginPayload(await encOrNull(draft.username), await encOrNull(draft.password),
        await encOrNull(draft.totp), uris);
    } else if (draft.type === ItemType.Card) {
      card = new CardPayload(await encOrNull(draft.cardholderName), await encOrNull(draft.brand),
        await encOrNull(draft.cardNumber), await encOrNull(draft.expMonth),
        await encOrNull(draft.expYear), await encOrNull(draft.cardCode));
    } else if (draft.type === ItemType.Identity) {
      identity = new IdentityPayload(await encOrNull(draft.firstName),
        await encOrNull(draft.middleName), await encOrNull(draft.lastName),
        await encOrNull(draft.company), await encOrNull(draft.identityEmail),
        await encOrNull(draft.phone), await encOrNull(draft.ssn),
        await encOrNull(draft.passportNumber), await encOrNull(draft.licenseNumber),
        await encOrNull(draft.address1), await encOrNull(draft.address2),
        await encOrNull(draft.address3), await encOrNull(draft.city),
        await encOrNull(draft.state), await encOrNull(draft.postalCode),
        await encOrNull(draft.country));
    } else if (draft.type === ItemType.SecureNote) {
      secureNote = new SecureNotePayload(0);
    }
    const fields: FieldPayload[] = [];
    for (let i = 0; i < draft.fields.length; i++) {
      const f = draft.fields[i];
      const nameEnc: string | null = await encOrNull(f.name);
      if (nameEnc === null) {
        continue;
      }
      fields.push(new FieldPayload(f.type, nameEnc,
        f.type === 3 ? null : await encOrNull(f.value), f.linkedId));
    }
    const nameEnc: string | null = await encOrNull(draft.name);
    return new CipherPayload(draft.id, draft.type as number, draft.folderId, draft.favorite,
      nameEnc ?? '', await encOrNull(draft.notes), fields, login, card, identity,
      secureNote, draft.attachments, draft.lastKnownRevisionDate, history, payloadKey);
  }

  private onRemovedLocally(id: string): void {
    this.onRemovedHook(id);
  }

  private onRemovedHook: (id: string) => void = (_id: string): void => {
  };

  /** 软删/恢复后的本地重投影（经 ServiceLocator 接 SyncService，保持写/同步解耦）。 */
  private async localCipher(id: string, deletedDate: number | null): Promise<void> {
    await this.localCipherHook(id, deletedDate);
  }

  private localCipherHook: (id: string, deletedDate: number | null) => Promise<void> =
    async (_id: string, _deletedDate: number | null): Promise<void> => {
    };

  setLocalCipherHook(hook: (id: string, deletedDate: number | null) => Promise<void>): void {
    this.localCipherHook = hook;
  }

  setRemovedHook(hook: (id: string) => void): void {
    this.onRemovedHook = hook;
  }

  /** 明文视图 → 草稿（收藏/移动/编辑共用；卡片/身份/字段全量回填）。 */
  draftFromView(view: CipherView): CipherDraft {
    const draft: CipherDraft = new CipherDraft();
    draft.id = view.id;
    draft.type = view.type;
    draft.folderId = view.folderId;
    draft.favorite = view.favorite;
    draft.name = view.name;
    draft.notes = view.notes;
    draft.username = view.username;
    draft.password = view.password;
    draft.totp = view.totpSecret;
    draft.uris = view.uris.slice(0);
    for (let i = 0; i < view.fields.length; i++) {
      const f = view.fields[i];
      draft.fields.push(new DraftField(f.name, f.value, f.type as number, f.linkedId));
    }
    if (view.card !== null) {
      draft.cardholderName = view.card.cardholderName;
      draft.brand = view.card.brand;
      draft.cardNumber = view.card.number;
      draft.expMonth = view.card.expMonth;
      draft.expYear = view.card.expYear;
      draft.cardCode = view.card.code;
    }
    if (view.identity !== null) {
      draft.firstName = view.identity.firstName;
      draft.middleName = view.identity.middleName;
      draft.lastName = view.identity.lastName;
      draft.company = view.identity.company;
      draft.identityEmail = view.identity.email;
      draft.phone = view.identity.phone;
      draft.ssn = view.identity.ssn;
      draft.passportNumber = view.identity.passportNumber;
      draft.licenseNumber = view.identity.licenseNumber;
      draft.address1 = view.identity.address1;
      draft.address2 = view.identity.address2;
      draft.address3 = view.identity.address3;
      draft.city = view.identity.city;
      draft.state = view.identity.state;
      draft.postalCode = view.identity.postalCode;
      draft.country = view.identity.country;
    }
    return draft;
  }

  private static newId(): string {
    let seed: number = Date.now();
    let text: string = '';
    for (let i = 0; i < 8; i++) {
      seed = (seed * 1103515245 + 12345) & 0x7fffffff;
      text += (seed % 16).toString(16);
    }
    return `offline-${text}`;
  }

  private static payloadFromJson(json: string): CipherPayload | null {
    try {
      const obj: Record<string, Object> = JSON.parse(json) as Record<string, Object>;
      const fieldsRaw: Array<Object> = (obj['fields'] ?? []) as Array<Object>;
      const fields: FieldPayload[] = [];
      for (let i = 0; i < fieldsRaw.length; i++) {
        const f: Record<string, Object> = fieldsRaw[i] as Record<string, Object>;
        fields.push(new FieldPayload(f['type'] as number, f['name'] as string,
          f['value'] === undefined || f['value'] === null ? null : f['value'] as string,
          typeof f['linkedId'] === 'number' ? f['linkedId'] as number : null));
      }
      let login: LoginPayload | null = null;
      const loginRaw: Object | undefined = obj['login'];
      if (loginRaw !== undefined && loginRaw !== null) {
        const l: Record<string, Object> = loginRaw as Record<string, Object>;
        const uris: UriPayload[] = [];
        const urisRaw: Array<Object> = (l['uris'] ?? []) as Array<Object>;
        for (let i = 0; i < urisRaw.length; i++) {
          const u: Record<string, Object> = urisRaw[i] as Record<string, Object>;
          uris.push(new UriPayload(u['uri'] as string,
            u['match'] === undefined || u['match'] === null ? null : u['match'] as number));
        }
        login = new LoginPayload(WriteService.strOrNull(l, 'username'),
          WriteService.strOrNull(l, 'password'), WriteService.strOrNull(l, 'totp'), uris);
      }
      const history: PasswordHistoryPayload[] = [];
      const historyRaw: Array<Object> = (obj['passwordHistory'] ?? []) as Array<Object>;
      for (let i = 0; i < historyRaw.length; i++) {
        const h: Record<string, Object> = historyRaw[i] as Record<string, Object>;
        history.push(new PasswordHistoryPayload(
          WriteService.strOrNull(h, 'password') ?? '',
          WriteService.strOrNull(h, 'lastModifiedDate') ?? '',
          WriteService.strOrNull(h, 'lastUsedDate')));
      }
      let card: CardPayload | null = null;
      const cardRaw: Object | undefined = obj['card'];
      if (cardRaw !== undefined && cardRaw !== null) {
        const c: Record<string, Object> = cardRaw as Record<string, Object>;
        card = new CardPayload(WriteService.strOrNull(c, 'cardholderName'),
          WriteService.strOrNull(c, 'brand'), WriteService.strOrNull(c, 'number'),
          WriteService.strOrNull(c, 'expMonth'), WriteService.strOrNull(c, 'expYear'),
          WriteService.strOrNull(c, 'code'));
      }
      let identity: IdentityPayload | null = null;
      const identityRaw: Object | undefined = obj['identity'];
      if (identityRaw !== undefined && identityRaw !== null) {
        const d: Record<string, Object> = identityRaw as Record<string, Object>;
        identity = new IdentityPayload(WriteService.strOrNull(d, 'firstName'),
          WriteService.strOrNull(d, 'middleName'), WriteService.strOrNull(d, 'lastName'),
          WriteService.strOrNull(d, 'company'), WriteService.strOrNull(d, 'email'),
          WriteService.strOrNull(d, 'phone'), WriteService.strOrNull(d, 'ssn'),
          WriteService.strOrNull(d, 'passportNumber'), WriteService.strOrNull(d, 'licenseNumber'),
          WriteService.strOrNull(d, 'address1'), WriteService.strOrNull(d, 'address2'),
          WriteService.strOrNull(d, 'address3'), WriteService.strOrNull(d, 'city'),
          WriteService.strOrNull(d, 'state'), WriteService.strOrNull(d, 'postalCode'),
          WriteService.strOrNull(d, 'country'));
      }
      let secureNote: SecureNotePayload | null = null;
      const secureNoteRaw: Object | undefined = obj['secureNote'];
      if (secureNoteRaw !== undefined && secureNoteRaw !== null) {
        const sn: Record<string, Object> = secureNoteRaw as Record<string, Object>;
        const snType: number = typeof sn['type'] === 'number' ? sn['type'] as number : 0;
        secureNote = new SecureNotePayload(snType);
      } else if (obj['type'] === ItemType.SecureNote) {
        secureNote = new SecureNotePayload(0);
      }
      const attachments: AttachmentPayload[] = [];
      const attachmentsRaw: Array<Object> = (obj['attachments'] ?? []) as Array<Object>;
      for (let i = 0; i < attachmentsRaw.length; i++) {
        const a: Record<string, Object> = attachmentsRaw[i] as Record<string, Object>;
        attachments.push(new AttachmentPayload(a['id'] as string, a['fileName'] as string,
          a['size'] as number, a['key'] as string, a['url'] as string));
      }
      const idRaw: Object | undefined = obj['id'];
      return new CipherPayload(
        idRaw === undefined || idRaw === null ? null : idRaw as string,
        obj['type'] as number, WriteService.strOrNull(obj, 'folderId'),
        obj['favorite'] === true, obj['name'] as string,
        WriteService.strOrNull(obj, 'notes'), fields, login, card, identity, secureNote, attachments,
        WriteService.strOrNull(obj, 'lastKnownRevisionDate'), history,
        WriteService.strOrNull(obj, 'key'));
    } catch (e) {
      return null;
    }
  }

  private static strOrNull(obj: Record<string, Object>, key: string): string | null {
    const raw: Object | undefined = obj[key];
    return typeof raw === 'string' ? raw as string : null;
  }
}
