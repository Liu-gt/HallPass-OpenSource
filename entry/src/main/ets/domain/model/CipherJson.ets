/*
 * SPDX-FileCopyrightText: 2026 Liugt
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import { Cipher, EncField, FieldType, LoginDetails, CardDetails, IdentityDetails,
  PasswordHistoryItem }
  from './Cipher';
import { Attachment } from './Attachment';
import { EncString } from './EncString';
import { EncStringCodec } from '../crypto/EncStringCodec';
import { ItemType } from './ItemType';

/**
 * 条目密文 JSON 编解码（plan R2：结构解析只在 domain 一处）。
 * `ciphers.data` 列存"整包密文字段 JSON"（结构公开、值全密文，EncString 串行化文本），
 * schema 冻结不迁移；本编解码是该 JSON 的唯一权威映射。
 * 附件不内嵌（attachments 表规范化存储，plan §1.4）。
 */
export class CipherJsonCodec {

  /** domain Cipher 的密文字段 → JSON 文本（不含元数据列与附件）。 */
  static encode(cipher: Cipher): string {
    const obj: Record<string, Object> = {};
    if (cipher.cipherKey !== null) {
      obj['key'] = cipher.cipherKey as Object;
    }
    if (cipher.name !== null) {
      obj['name'] = EncStringCodec.encode(cipher.name) as Object;
    }
    if (cipher.login !== null) {
      const uris: Array<string> = [];
      for (let i = 0; i < cipher.login.uris.length; i++) {
        uris.push(EncStringCodec.encode(cipher.login.uris[i]));
      }
      const loginObj: Record<string, Object> = {
        'username': CipherJsonCodec.encOrNull(cipher.login.username) as Object,
        'password': CipherJsonCodec.encOrNull(cipher.login.password) as Object,
        'totp': CipherJsonCodec.encOrNull(cipher.login.totp) as Object,
        'uris': uris
      };
      obj['login'] = loginObj;
    }
    if (cipher.notes !== null) {
      obj['notes'] = EncStringCodec.encode(cipher.notes);
    }
    if (cipher.fields.length > 0) {
      const fields: Array<Record<string, Object>> = [];
      for (let i = 0; i < cipher.fields.length; i++) {
        const f: EncField = cipher.fields[i];
        const field: Record<string, Object> = {
          'type': (f.type as number) as Object,
          'name': EncStringCodec.encode(f.name) as Object
        };
        if (f.value !== null) {
          field['value'] = EncStringCodec.encode(f.value);
        }
        if (f.linkedId !== null) {
          field['linkedId'] = f.linkedId as Object;
        }
        fields.push(field);
      }
      obj['fields'] = fields;
    }
    if (cipher.card !== null) {
      const cardObj: Record<string, Object> = {
        'cardholderName': CipherJsonCodec.encOrNull(cipher.card.cardholderName) as Object,
        'brand': CipherJsonCodec.encOrNull(cipher.card.brand) as Object,
        'number': CipherJsonCodec.encOrNull(cipher.card.number) as Object,
        'expMonth': CipherJsonCodec.encOrNull(cipher.card.expMonth) as Object,
        'expYear': CipherJsonCodec.encOrNull(cipher.card.expYear) as Object,
        'code': CipherJsonCodec.encOrNull(cipher.card.code) as Object
      };
      obj['card'] = cardObj;
    }
    if (cipher.identity !== null) {
      const identityObj: Record<string, Object> = {
        'firstName': CipherJsonCodec.encOrNull(cipher.identity.firstName) as Object,
        'middleName': CipherJsonCodec.encOrNull(cipher.identity.middleName) as Object,
        'lastName': CipherJsonCodec.encOrNull(cipher.identity.lastName) as Object,
        'company': CipherJsonCodec.encOrNull(cipher.identity.company) as Object,
        'email': CipherJsonCodec.encOrNull(cipher.identity.email) as Object,
        'phone': CipherJsonCodec.encOrNull(cipher.identity.phone) as Object,
        'ssn': CipherJsonCodec.encOrNull(cipher.identity.ssn) as Object,
        'passportNumber': CipherJsonCodec.encOrNull(cipher.identity.passportNumber) as Object,
        'licenseNumber': CipherJsonCodec.encOrNull(cipher.identity.licenseNumber) as Object,
        'address1': CipherJsonCodec.encOrNull(cipher.identity.address1) as Object,
        'address2': CipherJsonCodec.encOrNull(cipher.identity.address2) as Object,
        'address3': CipherJsonCodec.encOrNull(cipher.identity.address3) as Object,
        'city': CipherJsonCodec.encOrNull(cipher.identity.city) as Object,
        'state': CipherJsonCodec.encOrNull(cipher.identity.state) as Object,
        'postalCode': CipherJsonCodec.encOrNull(cipher.identity.postalCode) as Object,
        'country': CipherJsonCodec.encOrNull(cipher.identity.country) as Object
      };
      obj['identity'] = identityObj;
    }
    if (cipher.passwordHistory.length > 0) {
      const history: Array<Record<string, Object>> = [];
      for (let i = 0; i < cipher.passwordHistory.length; i++) {
        const h: PasswordHistoryItem = cipher.passwordHistory[i];
        // lastUsedDate（T28 fix-08）：官方云必填字段，随 data JSON roundtrip
        const entry: Record<string, Object> = {
          'password': EncStringCodec.encode(h.password),
          'lastModifiedDate': h.lastModifiedDate as Object
        };
        if (h.lastUsedDate !== null) {
          entry['lastUsedDate'] = h.lastUsedDate as Object;
        }
        history.push(entry);
      }
      obj['passwordHistory'] = history;
    }
    return JSON.stringify(obj);
  }

  /**
   * JSON 文本 → domain Cipher（元数据列由调用方传入；附件归 attachments 表）。
   * 解析失败抛错——同步层捕获后跳过单条目（plan R2），本方法不静默吞错。
   */
  static decode(id: string, vaultId: string, type: number, organizationId: string | null,
    revisionDate: number, favorite: boolean, folderId: string | null,
    deletedDate: number | null, dataJson: string, attachments: Attachment[] = [],
    lastUsedAt: number = 0): Cipher {
    const obj: Record<string, Object> = JSON.parse(dataJson) as Record<string, Object>;
    const name: EncString | null = CipherJsonCodec.strToEnc(obj, 'name');
    // V2 per-cipher key（DIAG-02）：EncString 串行化文本原样透传，解密在同步/展示层
    const cipherKeyRaw: Object | undefined = obj['key'];
    const cipherKey: string | null =
      typeof cipherKeyRaw === 'string' ? cipherKeyRaw as string : null;
    let login: LoginDetails | null = null;
    const loginRaw: Object | undefined = obj['login'];
    if (loginRaw !== undefined && loginRaw !== null) {
      const l: Record<string, Object> = loginRaw as Record<string, Object>;
      login = new LoginDetails(
        CipherJsonCodec.strToEnc(l, 'username'),
        CipherJsonCodec.strToEnc(l, 'password'),
        CipherJsonCodec.strToEnc(l, 'totp'),
        CipherJsonCodec.uriArray(l));
    }
    const notes: EncString | null = CipherJsonCodec.strToEnc(obj, 'notes');
    const fields: EncField[] = [];
    const fieldsRaw: Object | undefined = obj['fields'];
    if (fieldsRaw !== undefined && fieldsRaw !== null) {
      const arr: Array<Object> = fieldsRaw as Array<Object>;
      for (let i = 0; i < arr.length; i++) {
        const f: Record<string, Object> = arr[i] as Record<string, Object>;
        fields.push(new EncField(CipherJsonCodec.toFieldType(f['type']),
          CipherJsonCodec.strToEnc(f, 'name') as EncString,
          CipherJsonCodec.strToEnc(f, 'value'),
          typeof f['linkedId'] === 'number' ? f['linkedId'] as number : null));
      }
    }
    let card: CardDetails | null = null;
    const cardRaw: Object | undefined = obj['card'];
    if (cardRaw !== undefined && cardRaw !== null) {
      const c: Record<string, Object> = cardRaw as Record<string, Object>;
      card = new CardDetails(
        CipherJsonCodec.strToEnc(c, 'cardholderName'), CipherJsonCodec.strToEnc(c, 'brand'),
        CipherJsonCodec.strToEnc(c, 'number'), CipherJsonCodec.strToEnc(c, 'expMonth'),
        CipherJsonCodec.strToEnc(c, 'expYear'), CipherJsonCodec.strToEnc(c, 'code'));
    }
    let identity: IdentityDetails | null = null;
    const identityRaw: Object | undefined = obj['identity'];
    if (identityRaw !== undefined && identityRaw !== null) {
      const d: Record<string, Object> = identityRaw as Record<string, Object>;
      identity = new IdentityDetails(
        CipherJsonCodec.strToEnc(d, 'firstName'), CipherJsonCodec.strToEnc(d, 'middleName'),
        CipherJsonCodec.strToEnc(d, 'lastName'), CipherJsonCodec.strToEnc(d, 'company'),
        CipherJsonCodec.strToEnc(d, 'email'), CipherJsonCodec.strToEnc(d, 'phone'),
        CipherJsonCodec.strToEnc(d, 'ssn'), CipherJsonCodec.strToEnc(d, 'passportNumber'),
        CipherJsonCodec.strToEnc(d, 'licenseNumber'), CipherJsonCodec.strToEnc(d, 'address1'),
        CipherJsonCodec.strToEnc(d, 'address2'), CipherJsonCodec.strToEnc(d, 'address3'),
        CipherJsonCodec.strToEnc(d, 'city'), CipherJsonCodec.strToEnc(d, 'state'),
        CipherJsonCodec.strToEnc(d, 'postalCode'), CipherJsonCodec.strToEnc(d, 'country'));
    }
    const history: PasswordHistoryItem[] = [];
    const historyRaw: Object | undefined = obj['passwordHistory'];
    if (historyRaw !== undefined && historyRaw !== null) {
      const arr: Array<Object> = historyRaw as Array<Object>;
      for (let i = 0; i < arr.length; i++) {
        const h: Record<string, Object> = arr[i] as Record<string, Object>;
        const passwordRaw: Object | undefined = h['password'];
        const modified: Object | undefined = h['lastModifiedDate'];
        const used: Object | undefined = h['lastUsedDate'];
        if (typeof passwordRaw === 'string' && typeof modified === 'number') {
          history.push(new PasswordHistoryItem(EncStringCodec.decode(passwordRaw as string),
            modified as number, typeof used === 'number' ? used as number : null));
        }
      }
    }
    return new Cipher(id, vaultId, CipherJsonCodec.toItemType(type), organizationId,
      revisionDate, favorite, folderId, deletedDate, fields, login, notes, card, identity,
      attachments, name, history, lastUsedAt, cipherKey);
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

  private static encOrNull(value: EncString | null): string | null {
    return value === null ? null : EncStringCodec.encode(value);
  }

  private static strToEnc(obj: Record<string, Object>, key: string): EncString | null {
    const raw: Object | undefined = obj[key];
    if (raw === undefined || raw === null) {
      return null;
    }
    return EncStringCodec.decode(raw as string);
  }

  /** uris 为 EncString 串行化文本数组（match 元数据不在 MVP 域模型内）。 */
  private static uriArray(login: Record<string, Object>): EncString[] {
    const out: EncString[] = [];
    const raw: Object | undefined = login['uris'];
    if (raw === undefined || raw === null) {
      return out;
    }
    const arr: Array<Object> = raw as Array<Object>;
    for (let i = 0; i < arr.length; i++) {
      out.push(EncStringCodec.decode(arr[i] as string));
    }
    return out;
  }
}
