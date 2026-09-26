/*
 * SPDX-FileCopyrightText: 2026 Liugt
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import { Cipher, EncField, FieldType, LoginDetails, CardDetails, IdentityDetails,
  PasswordHistoryItem }
  from '../model/Cipher';
import { Attachment } from '../model/Attachment';
import { EncString } from '../model/EncString';
import { EncStringCodec } from '../crypto/EncStringCodec';
import { ItemType } from '../model/ItemType';
import { CipherResponse } from './Types';

/**
 * 服务器条目响应解析（票 11，plan R2：结构解析只在 domain 一处）。
 * Bitwarden sync/cipher 响应的密文字段 JSON → domain Cipher。
 * 附件元数据（fileName/url 为明文、key 为 EncString）随条目解析。
 * 解析失败抛错——同步层捕获后跳过单条目，不阻塞整库（R2）。
 */
export class ServerCipherCodec {

  static parse(response: CipherResponse): Cipher {
    const json: Record<string, Object> =
      JSON.parse(response.dataJson) as Record<string, Object>;
    const name: EncString = EncStringCodec.decode(
      ServerCipherCodec.requireString(json, 'name'));
    let login: LoginDetails | null = null;
    const loginRaw: Object | undefined = json['login'];
    if (loginRaw !== undefined && loginRaw !== null) {
      const l: Record<string, Object> = loginRaw as Record<string, Object>;
      login = new LoginDetails(
        ServerCipherCodec.encOrNull(l, 'username'),
        ServerCipherCodec.encOrNull(l, 'password'),
        ServerCipherCodec.encOrNull(l, 'totp'),
        ServerCipherCodec.uriArray(l));
    }
    const notes: EncString | null = ServerCipherCodec.encOrNull(json, 'notes');
    const fields: EncField[] = [];
    const fieldsRaw: Object | undefined = json['fields'];
    if (fieldsRaw !== undefined && fieldsRaw !== null) {
      const arr: Array<Object> = fieldsRaw as Array<Object>;
      for (let i = 0; i < arr.length; i++) {
        const f: Record<string, Object> = arr[i] as Record<string, Object>;
        fields.push(new EncField(ServerCipherCodec.toFieldType(f['type']),
          EncStringCodec.decode(ServerCipherCodec.requireString(f, 'name')),
          ServerCipherCodec.encOrNull(f, 'value'),
          typeof f['linkedId'] === 'number' ? f['linkedId'] as number : null));
      }
    }
    let card: CardDetails | null = null;
    const cardRaw: Object | undefined = json['card'];
    if (cardRaw !== undefined && cardRaw !== null) {
      const c: Record<string, Object> = cardRaw as Record<string, Object>;
      card = new CardDetails(
        ServerCipherCodec.encOrNull(c, 'cardholderName'), ServerCipherCodec.encOrNull(c, 'brand'),
        ServerCipherCodec.encOrNull(c, 'number'), ServerCipherCodec.encOrNull(c, 'expMonth'),
        ServerCipherCodec.encOrNull(c, 'expYear'), ServerCipherCodec.encOrNull(c, 'code'));
    }
    let identity: IdentityDetails | null = null;
    const identityRaw: Object | undefined = json['identity'];
    if (identityRaw !== undefined && identityRaw !== null) {
      const d: Record<string, Object> = identityRaw as Record<string, Object>;
      identity = new IdentityDetails(
        ServerCipherCodec.encOrNull(d, 'firstName'), ServerCipherCodec.encOrNull(d, 'middleName'),
        ServerCipherCodec.encOrNull(d, 'lastName'), ServerCipherCodec.encOrNull(d, 'company'),
        ServerCipherCodec.encOrNull(d, 'email'), ServerCipherCodec.encOrNull(d, 'phone'),
        ServerCipherCodec.encOrNull(d, 'ssn'), ServerCipherCodec.encOrNull(d, 'passportNumber'),
        ServerCipherCodec.encOrNull(d, 'licenseNumber'), ServerCipherCodec.encOrNull(d, 'address1'),
        ServerCipherCodec.encOrNull(d, 'address2'), ServerCipherCodec.encOrNull(d, 'address3'),
        ServerCipherCodec.encOrNull(d, 'city'), ServerCipherCodec.encOrNull(d, 'state'),
        ServerCipherCodec.encOrNull(d, 'postalCode'), ServerCipherCodec.encOrNull(d, 'country'));
    }
    const attachments: Attachment[] = [];
    const attachmentsRaw: Object | undefined = json['attachments'];
    if (attachmentsRaw !== undefined && attachmentsRaw !== null) {
      const arr: Array<Object> = attachmentsRaw as Array<Object>;
      for (let i = 0; i < arr.length; i++) {
        const a: Record<string, Object> = arr[i] as Record<string, Object>;
        attachments.push(new Attachment(
          ServerCipherCodec.requireString(a, 'id'),
          response.id,
          ServerCipherCodec.requireString(a, 'fileName'),
          ServerCipherCodec.numberOrZero(a, 'size'),
          EncStringCodec.decode(ServerCipherCodec.requireString(a, 'key')),
          ServerCipherCodec.requireString(a, 'url')));
      }
    }
    const history: PasswordHistoryItem[] = [];
    const historyRaw: Object | undefined = json['passwordHistory'];
    if (historyRaw !== undefined && historyRaw !== null) {
      const hArr: Array<Object> = historyRaw as Array<Object>;
      for (let i = 0; i < hArr.length; i++) {
        const h: Record<string, Object> = hArr[i] as Record<string, Object>;
        // 服务器 PasswordHistory：{password: EncStr, lastModifiedDate: ISO, lastUsedDate: ISO?}
        // lastUsedDate（T28 fix-08）：官方云必填字段，原样解析保留，缺省为 null
        const passwordRaw: Object | undefined = h['password'];
        const modifiedRaw: Object | undefined = h['lastModifiedDate'];
        const usedRaw: Object | undefined = h['lastUsedDate'];
        if (typeof passwordRaw === 'string') {
          const modifiedIso: string = typeof modifiedRaw === 'string' ? modifiedRaw as string : '';
          const usedIso: string = typeof usedRaw === 'string' ? usedRaw as string : '';
          // 部分服务器实现（官方云实测）返回 lastModifiedDate=null、时间落在 lastUsedDate；
          // 更改时间缺失时以 lastUsedDate 回退，避免历史行时间丢失
          const modifiedEpoch: number = ServerCipherCodec.toEpoch(modifiedIso);
          const usedEpoch: number = ServerCipherCodec.toEpoch(usedIso);
          history.push(new PasswordHistoryItem(EncStringCodec.decode(passwordRaw as string),
            modifiedEpoch > 0 ? modifiedEpoch : usedEpoch,
            typeof usedRaw === 'string' ? usedEpoch : null));
        }
      }
    }
    // V2 per-cipher key（DIAG-02）：官方云 V2 账号条目字段以条目密钥加密，
    // 顶层 key 为用户密钥包裹的 EncString 串行化文本；传统账号无此字段。
    const cipherKeyRaw: Object | undefined = json['key'];
    const cipherKey: string | null =
      typeof cipherKeyRaw === 'string' ? cipherKeyRaw as string : null;
    return new Cipher(response.id, '', ServerCipherCodec.toItemType(response.type),
      response.organizationId, ServerCipherCodec.toEpoch(response.revisionDate),
      response.favorite, response.folderId,
      response.deletedDate === null ? null : ServerCipherCodec.toEpoch(response.deletedDate),
      fields, login, notes, card, identity, attachments, name, history, 0, cipherKey);
  }

  private static toItemType(value: number): ItemType {
    if (value === ItemType.SecureNote) {
      return ItemType.SecureNote;
    } else if (value === ItemType.Card) {
      return ItemType.Card;
    } else if (value === ItemType.Identity) {
      return ItemType.Identity;
    }
    return ItemType.Login;
  }

  private static toFieldType(value: Object): FieldType {
    const n: number = value as number;
    if (n === FieldType.Hidden) {
      return FieldType.Hidden;
    } else if (n === FieldType.Boolean) {
      return FieldType.Boolean;
    } else if (n === FieldType.Linked) {
      return FieldType.Linked;
    }
    return FieldType.Text;
  }

  private static toEpoch(iso: string): number {
    const ms: number = new Date(iso).getTime();
    return Number.isNaN(ms) ? 0 : ms;
  }

  private static requireString(obj: Record<string, Object>, key: string): string {
    const raw: Object | undefined = obj[key];
    if (typeof raw !== 'string') {
      throw new Error(`ServerCipherCodec: missing field '${key}'`);
    }
    return raw as string;
  }

  private static numberOrZero(obj: Record<string, Object>, key: string): number {
    const raw: Object | undefined = obj[key];
    return typeof raw === 'number' ? raw as number : 0;
  }

  private static encOrNull(obj: Record<string, Object>, key: string): EncString | null {
    const raw: Object | undefined = obj[key];
    if (raw === undefined || raw === null) {
      return null;
    }
    return EncStringCodec.decode(raw as string);
  }

  /** 服务器 uris 形如 [{uri: EncStr, match}]；match 元数据不入 MVP 域模型。
   *  官方云允许元素 uri 为 null（空 URI 条目，DIAG-02），跳过而非整条目失败。 */
  private static uriArray(login: Record<string, Object>): EncString[] {
    const out: EncString[] = [];
    const raw: Object | undefined = login['uris'];
    if (raw === undefined || raw === null) {
      return out;
    }
    const arr: Array<Object> = raw as Array<Object>;
    for (let i = 0; i < arr.length; i++) {
      const u: Record<string, Object> = arr[i] as Record<string, Object>;
      const uri: EncString | null = ServerCipherCodec.encOrNull(u, 'uri');
      if (uri === null) {
        continue;
      }
      out.push(uri);
    }
    return out;
  }
}
