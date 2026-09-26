/*
 * SPDX-FileCopyrightText: 2026 Liugt
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import { ItemType } from '../../domain/model/ItemType';

/**
 * 明文内存投影（票 11，plan D3/D9/R5）：解锁后由密文缓存解密构建，锁定即清空。
 * 明文绝不落盘（ADR 安全基线）；@ObservedV2 + @Trace 支撑长列表与 TOTP 每秒刷新的细粒度更新。
 */
@ObservedV2
export class FieldView {
  @Trace type: FieldType2 = FieldType2.Text;
  @Trace name: string = '';
  @Trace value: string = '';
  @Trace linkedId: number | null = null;
  isHidden: boolean = false;

  constructor(type: FieldType2, name: string, value: string, isHidden: boolean,
    linkedId: number | null = null) {
    this.type = type;
    this.name = name;
    this.value = value;
    this.isHidden = isHidden;
    this.linkedId = linkedId;
  }
}

/** FieldType 别名（view 层不 import domain 明细，用数值语义保持一致）。 */
export enum FieldType2 {
  Text = 0,
  Hidden = 1,
  Boolean = 2,
  Linked = 3
}

@ObservedV2
export class CardView {
  @Trace cardholderName: string = '';
  @Trace brand: string = '';
  @Trace number: string = '';
  @Trace expMonth: string = '';
  @Trace expYear: string = '';
  @Trace code: string = '';

  constructor(cardholderName: string, brand: string, number: string, expMonth: string,
    expYear: string, code: string) {
    this.cardholderName = cardholderName;
    this.brand = brand;
    this.number = number;
    this.expMonth = expMonth;
    this.expYear = expYear;
    this.code = code;
  }
}

@ObservedV2
export class IdentityView {
  @Trace firstName: string = '';
  @Trace middleName: string = '';
  @Trace lastName: string = '';
  @Trace company: string = '';
  @Trace email: string = '';
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

  constructor(firstName: string, middleName: string, lastName: string, company: string,
    email: string, phone: string, ssn: string, passportNumber: string, licenseNumber: string,
    address1: string, address2: string, address3: string, city: string, state: string,
    postalCode: string, country: string) {
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

@ObservedV2
export class AttachmentView {
  readonly id: string;
  @Trace fileName: string;
  readonly size: number;
  readonly keySerialized: string;
  readonly url: string;

  constructor(id: string, fileName: string, size: number, keySerialized: string, url: string) {
    this.id = id;
    this.fileName = fileName;
    this.size = size;
    this.keySerialized = keySerialized;
    this.url = url;
  }
}

/** 密码历史明文投影（T27，spec F7：只读历史，旧密码默认遮蔽）。 */
@ObservedV2
export class HistoryItemView {
  @Trace password: string;
  readonly lastModifiedDate: number;

  constructor(password: string, lastModifiedDate: number) {
    this.password = password;
    this.lastModifiedDate = lastModifiedDate;
  }
}

@ObservedV2
export class CipherView {
  readonly id: string;
  @Trace type: ItemType;
  @Trace name: string;
  @Trace favorite: boolean;
  readonly folderId: string | null;
  readonly deletedDate: number | null;
  readonly revisionDate: number;
  @Trace username: string;
  @Trace password: string;
  /** TOTP 密钥明文（otpauth:// 或 Base32），空串表示无 */
  @Trace totpSecret: string;
  @Trace uris: string[];
  @Trace notes: string;
  @Trace fields: FieldView[];
  @Trace card: CardView | null;
  @Trace identity: IdentityView | null;
  @Trace attachments: AttachmentView[];
  /** 密码历史（T27，spec F7；时间倒序由展示层处理）。 */
  @Trace passwordHistory: HistoryItemView[];
  /** 最近使用（T27 本地行为元数据，epoch 毫秒；0 = 从未使用，复制密码后更新）。 */
  @Trace lastUsedAt: number;

  constructor(id: string, type: ItemType, name: string, favorite: boolean,
    folderId: string | null, deletedDate: number | null, revisionDate: number,
    username: string, password: string, totpSecret: string, uris: string[], notes: string,
    fields: FieldView[], card: CardView | null, identity: IdentityView | null,
    attachments: AttachmentView[], passwordHistory: HistoryItemView[] = [],
    lastUsedAt: number = 0) {
    this.id = id;
    this.type = type;
    this.name = name;
    this.favorite = favorite;
    this.folderId = folderId;
    this.deletedDate = deletedDate;
    this.revisionDate = revisionDate;
    this.username = username;
    this.password = password;
    this.totpSecret = totpSecret;
    this.uris = uris;
    this.notes = notes;
    this.fields = fields;
    this.card = card;
    this.identity = identity;
    this.attachments = attachments;
    this.passwordHistory = passwordHistory;
    this.lastUsedAt = lastUsedAt;
  }
}

@ObservedV2
export class FolderView {
  readonly id: string;
  @Trace name: string;

  constructor(id: string, name: string) {
    this.id = id;
    this.name = name;
  }
}

/**
 * 保管库内存索引（plan D9 域投影）：解锁后 rebuild 填充，锁定事件清空。
 * 破损/解密失败的单条目被跳过并计数（plan R2），不阻塞整库。
 */
type IndexListener = () => void;

@ObservedV2
export class VaultMemoryIndex {
  @Trace entries: CipherView[] = [];
  @Trace folders: FolderView[] = [];
  @Trace syncing: boolean = false;
  @Trace lastSyncAt: number = 0;
  @Trace lastSkippedCount: number = 0;
  private listeners: IndexListener[] = [];

  /** 数据变更通知（写路径/同步后触发；列表页订阅自动刷新，票 19 接线）。 */
  addListener(listener: IndexListener): void {
    this.listeners.push(listener);
  }

  removeListener(listener: IndexListener): void {
    this.listeners = this.listeners.filter((l: IndexListener): boolean => l !== listener);
  }

  private notify(): void {
    for (let i = 0; i < this.listeners.length; i++) {
      try {
        this.listeners[i]();
      } catch (e) {
        /* 单个监听器失败不影响其他 */
      }
    }
  }

  clear(): void {
    this.entries = [];
    this.folders = [];
    this.lastSkippedCount = 0;
    this.notify();
  }

  /** 整体重建（同步/解锁重建的批量替换）：与 upsert/remove 一样必须通知订阅者，
   *  否则已挂载的列表页感知不到新数据（登录后不手动刷新不出条目的根因）。 */
  replaceAll(entries: CipherView[], folders: FolderView[], skippedCount: number): void {
    this.entries = entries;
    this.folders = folders;
    this.lastSkippedCount = skippedCount;
    this.notify();
  }

  upsert(view: CipherView): void {
    const next: CipherView[] = [];
    let replaced: boolean = false;
    for (let i = 0; i < this.entries.length; i++) {
      if (this.entries[i].id === view.id) {
        next.push(view);
        replaced = true;
      } else {
        next.push(this.entries[i]);
      }
    }
    if (!replaced) {
      next.push(view);
    }
    this.entries = next;
    this.notify();
  }

  remove(id: string): void {
    this.entries = this.entries.filter((entry: CipherView): boolean => entry.id !== id);
    this.notify();
  }
}
