/*
 * SPDX-FileCopyrightText: 2026 Liugt
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import { EncString } from './EncString';
import { ItemType } from './ItemType';
import { Attachment } from './Attachment';

/**
 * 自定义字段类型（Bitwarden 线上数值）。
 */
export enum FieldType {
  Text = 0,
  Hidden = 1,
  Boolean = 2,
  Linked = 3
}

/**
 * 自定义字段。Boolean 字段无值（value 为 null）。
 */
export class EncField {
  readonly type: FieldType;
  readonly name: EncString;
  readonly value: EncString | null;
  readonly linkedId: number | null;

  constructor(type: FieldType, name: EncString, value: EncString | null = null,
    linkedId: number | null = null) {
    this.type = type;
    this.name = name;
    this.value = value;
    this.linkedId = linkedId;
  }
}

export class LoginDetails {
  readonly username: EncString | null;
  readonly password: EncString | null;
  readonly totp: EncString | null;
  readonly uris: EncString[];

  constructor(username: EncString | null = null, password: EncString | null = null,
    totp: EncString | null = null, uris: EncString[] = []) {
    this.username = username;
    this.password = password;
    this.totp = totp;
    this.uris = uris;
  }
}

/**
 * 密码历史条目（T27，plan §1.3 v1.1）：旧密码密文 + 更改时间（epoch 毫秒）。
 * lastUsedDate（T28 fix-08）：官方云模型必填字段（历史条目的上次使用时间，epoch 毫秒）；
 * Vaultwarden/旧数据可能缺省（null，提交时以 lastModifiedDate 兜底）。
 * 属条目结构，随 ciphers.data 整包密文 JSON 存取（plan §1.4 v1.1：不加列）。
 */
export class PasswordHistoryItem {
  readonly password: EncString;
  readonly lastModifiedDate: number;
  readonly lastUsedDate: number | null;

  constructor(password: EncString, lastModifiedDate: number, lastUsedDate: number | null = null) {
    this.password = password;
    this.lastModifiedDate = lastModifiedDate;
    this.lastUsedDate = lastUsedDate;
  }
}

export class CardDetails {
  readonly cardholderName: EncString | null;
  readonly brand: EncString | null;
  readonly number: EncString | null;
  readonly expMonth: EncString | null;
  readonly expYear: EncString | null;
  readonly code: EncString | null;

  constructor(cardholderName: EncString | null = null, brand: EncString | null = null,
    number: EncString | null = null, expMonth: EncString | null = null,
    expYear: EncString | null = null, code: EncString | null = null) {
    this.cardholderName = cardholderName;
    this.brand = brand;
    this.number = number;
    this.expMonth = expMonth;
    this.expYear = expYear;
    this.code = code;
  }
}

export class IdentityDetails {
  readonly firstName: EncString | null;
  readonly middleName: EncString | null;
  readonly lastName: EncString | null;
  readonly address1: EncString | null;
  readonly address2: EncString | null;
  readonly address3: EncString | null;
  readonly city: EncString | null;
  readonly state: EncString | null;
  readonly postalCode: EncString | null;
  readonly country: EncString | null;
  readonly company: EncString | null;
  readonly email: EncString | null;
  readonly phone: EncString | null;
  readonly ssn: EncString | null;
  readonly passportNumber: EncString | null;
  readonly licenseNumber: EncString | null;

  constructor(firstName: EncString | null = null, middleName: EncString | null = null,
    lastName: EncString | null = null, address1: EncString | null = null,
    address2: EncString | null = null, address3: EncString | null = null,
    city: EncString | null = null, state: EncString | null = null,
    postalCode: EncString | null = null, country: EncString | null = null,
    company: EncString | null = null, email: EncString | null = null,
    phone: EncString | null = null, ssn: EncString | null = null,
    passportNumber: EncString | null = null, licenseNumber: EncString | null = null) {
    this.firstName = firstName;
    this.middleName = middleName;
    this.lastName = lastName;
    this.address1 = address1;
    this.address2 = address2;
    this.address3 = address3;
    this.city = city;
    this.state = state;
    this.postalCode = postalCode;
    this.country = country;
    this.company = company;
    this.email = email;
    this.phone = phone;
    this.ssn = ssn;
    this.passportNumber = passportNumber;
    this.licenseNumber = licenseNumber;
  }
}

/**
 * 条目（Bitwarden cipher 的域内模型）。字段值均为 EncString，明文投影仅存在于内存索引。
 * revisionDate/deletedDate 为 epoch 毫秒值（协议层负责 ISO↔epoch 转换）。
 * organizationId 仅为 ADR-0001 的同步过滤保留：非 null 表示组织条目，同步时丢弃；
 * MVP 无组织功能，不做任何组织读写。
 */
export class Cipher {
  readonly id: string;
  readonly vaultId: string;
  readonly type: ItemType;
  readonly organizationId: string | null;
  readonly favorite: boolean;
  readonly revisionDate: number;
  readonly folderId: string | null;
  readonly deletedDate: number | null;
  /** 条目名（EncString 密文，spec F6/F7 展示必需；plan §1.3 骨架模型细化，T11 补齐） */
  readonly name: EncString | null;
  readonly fields: EncField[];
  readonly login: LoginDetails | null;
  readonly notes: EncString | null;
  readonly card: CardDetails | null;
  readonly identity: IdentityDetails | null;
  readonly attachments: Attachment[];
  /** 密码历史（T27，plan §1.3 v1.1）：仅登录类型写入，随 data JSON 整包存取。 */
  readonly passwordHistory: PasswordHistoryItem[];
  /** 最近使用时间（T27 本地行为元数据，epoch 毫秒；0 = 从未使用）。仅 ciphers.last_used_at 列，
   *  不入 data JSON、不随服务器同步覆盖（plan §1.4 v1.1）。 */
  readonly lastUsedAt: number;
  /** V2 加密条目密钥（EncString 串行化文本，DIAG-02）：官方云 V2 账号条目字段以
   *  per-cipher key 加密，该密钥由用户密钥解开；null = 传统单密钥加密（Vaultwarden）。 */
  readonly cipherKey: string | null;

  constructor(id: string, vaultId: string, type: ItemType, organizationId: string | null,
    revisionDate: number, favorite: boolean = false, folderId: string | null = null,
    deletedDate: number | null = null, fields: EncField[] = [], login: LoginDetails | null = null,
    notes: EncString | null = null, card: CardDetails | null = null,
    identity: IdentityDetails | null = null, attachments: Attachment[] = [],
    name: EncString | null = null, passwordHistory: PasswordHistoryItem[] = [],
    lastUsedAt: number = 0, cipherKey: string | null = null) {
    this.id = id;
    this.vaultId = vaultId;
    this.type = type;
    this.organizationId = organizationId;
    this.revisionDate = revisionDate;
    this.favorite = favorite;
    this.folderId = folderId;
    this.deletedDate = deletedDate;
    this.name = name;
    this.fields = fields;
    this.login = login;
    this.notes = notes;
    this.card = card;
    this.identity = identity;
    this.attachments = attachments;
    this.passwordHistory = passwordHistory;
    this.lastUsedAt = lastUsedAt;
    this.cipherKey = cipherKey;
  }
}
