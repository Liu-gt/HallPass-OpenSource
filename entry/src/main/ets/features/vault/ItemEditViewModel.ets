/*
 * SPDX-FileCopyrightText: 2026 Liugt
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import { CipherDraft, DraftField } from '../../application/WriteService';
import { ServiceLocator } from '../../application/ServiceLocator';
import { CipherView, FieldType2 } from '../../application/state/VaultMemoryIndex';
import { ItemType } from '../../domain/model/ItemType';
import { OtpauthUri } from '../../common/utils/OtpauthUri';
import { AppState, AppPhase } from '../../application/state/AppState';

/** 保存结果（页面裁决 pop / 留守提示）。 */
export type EditSaveResult = 'saved' | 'queued' | 'invalid';

/** 文件夹选择项（未分组 = 空串 id）。 */
export interface FolderOption {
  id: string;
  name: string;
}

/**
 * 条目编辑 ViewModel（票 19，spec F8）：表单状态独立于组件生命周期（静态实例表）——
 * 编辑期间被锁定时主界面卸载、解锁恢复栈后 aboutToAppear 取回同一实例，表单内容保留。
 * 名称必填（空则保存禁用）；TOTP 支持 otpauth:// 或 Base32，保存前校验；
 * 离线保存走 outbox（WriteService）并提示已排队。
 */
@ObservedV2
export class ItemEditViewModel {
  @Trace draft: CipherDraft = new CipherDraft();
  @Trace isNew: boolean = true;
  @Trace saving: boolean = false;
  @Trace totpError: boolean = false;
  @Trace folderName: string = '';
  readonly instanceKey: string;

  private static instances: Map<string, ItemEditViewModel> = new Map();

  private constructor(instanceKey: string) {
    this.instanceKey = instanceKey;
  }

  /** 集中生成缓存键：新建条目纯按类型索引（new-${type}），编辑按条目 ID 索引 */
  public static generateKey(cipherId: string | null, type: number | null): string {
    return cipherId === null ? `new-${type ?? ItemType.Login}` : cipherId;
  }

  /** 创建非受管瞬态实例供 ItemEditPage 声明初始化，杜绝僵尸实例污染 */
  public static createTransient(): ItemEditViewModel {
    const model: ItemEditViewModel = new ItemEditViewModel('transient');
    model.draft = new CipherDraft();
    return model;
  }

  /** 登出清理：清空全部草稿缓存，杜绝跨会话泄露敏感明文 */
  public static clearAll(): void {
    ItemEditViewModel.instances.clear();
  }

  static acquire(cipherId: string | null, newType: number | null, folderId?: string | null): ItemEditViewModel {
    const key: string = ItemEditViewModel.generateKey(cipherId, newType);
    const existing: ItemEditViewModel | undefined = ItemEditViewModel.instances.get(key);
    if (existing !== undefined) {
      // F2-03: 对新建条目草稿，严格按当前上下文同步 folderId（空则重置为 null，消除跨文件夹残留）
      if (cipherId === null) {
        const targetFolder: string | null = (folderId !== undefined && folderId !== null && folderId.length > 0)
          ? folderId
          : null;
        existing.draft.folderId = targetFolder;
        existing.folderName = ItemEditViewModel.folderNameFor(targetFolder);
      }
      return existing;
    }
    const model: ItemEditViewModel = new ItemEditViewModel(key);
    model.isNew = cipherId === null;
    if (cipherId === null) {
      model.draft = new CipherDraft();
      model.draft.type = (newType ?? ItemType.Login) as ItemType;
      if (folderId !== undefined && folderId !== null && folderId.length > 0) {
        model.draft.folderId = folderId;
        model.folderName = ItemEditViewModel.folderNameFor(folderId);
      }
    } else {
      const view: CipherView | null = ItemEditViewModel.findView(cipherId);
      if (view !== null) {
        model.draft = ServiceLocator.write().draftFromView(view);
      }
      model.folderName = ItemEditViewModel.folderNameFor(model.draft.folderId);
    }
    ItemEditViewModel.instances.set(key, model);
    return model;
  }

  static release(cipherId: string | null, type?: number | null): void {
    const key: string = ItemEditViewModel.generateKey(cipherId, type ?? null);
    ItemEditViewModel.instances.delete(key);
  }

  private static findView(cipherId: string): CipherView | null {
    const entries: CipherView[] = ServiceLocator.sync().indexState().entries;
    for (let i = 0; i < entries.length; i++) {
      if (entries[i].id === cipherId) {
        return entries[i];
      }
    }
    return null;
  }

  private static folderNameFor(folderId: string | null): string {
    if (folderId === null) {
      return '';
    }
    const folders = ServiceLocator.sync().indexState().folders;
    for (let i = 0; i < folders.length; i++) {
      if (folders[i].id === folderId) {
        return folders[i].name;
      }
    }
    return '';
  }

  foldersForPicker(): FolderOption[] {
    const options: FolderOption[] = [{ id: '', name: '未分组' }];
    const folders = ServiceLocator.sync().indexState().folders;
    for (let i = 0; i < folders.length; i++) {
      options.push({ id: folders[i].id, name: folders[i].name });
    }
    return options;
  }

  canSave(): boolean {
    return !this.hasMissingRequiredFields() && !this.saving;
  }

  hasMissingRequiredFields(): boolean {
    if (this.draft.name.trim().length === 0) {
      return true;
    }
    return this.draft.fields.some((field: DraftField): boolean => field.name.trim().length === 0);
  }

  /** TOTP 保存前校验（空合法；otpauth:// 或 Base32）。 */
  validateTotp(): boolean {
    if (this.draft.totp.trim().length === 0) {
      this.totpError = false;
      return true;
    }
    const valid: boolean = OtpauthUri.parse(this.draft.totp) !== null;
    this.totpError = !valid;
    return valid;
  }

  addField(type: FieldType2 = FieldType2.Text): void {
    // Bitwarden linked-field IDs: 100 = username, 101 = password.
    this.draft.fields.push(new DraftField('', type === FieldType2.Boolean ? 'false' : '', type,
      type === FieldType2.Linked ? 100 : null));
  }

  removeField(index: number): void {
    this.draft.fields = this.draft.fields.filter((_f: DraftField, i: number): boolean =>
      i !== index);
  }

  async save(): Promise<EditSaveResult> {
    if (!this.canSave()) {
      return 'invalid';
    }
    if (!this.validateTotp()) {
      return 'invalid';
    }
    this.saving = true;
    try {
      const result: 'saved' | 'queued' = await ServiceLocator.write().save(this.draft);
      if (result === 'saved') {
        ItemEditViewModel.instances.delete(this.instanceKey);
      }
      return result;
    } finally {
      this.saving = false;
    }
  }

  /** 附件添加（编辑态；新建条目先保存后再添加，spec F8 边界）。 */
  async addAttachment(fileName: string, data: Uint8Array): Promise<boolean> {
    if (this.draft.id === null) {
      return false;
    }
    try {
      await ServiceLocator.attachment().upload(this.draft.id, fileName, data, null);
      return true;
    } catch (e) {
      return false;
    }
  }
}

// 当相位变迁回 onboarding 时自动销毁未保存的编辑态与草稿缓存，杜绝跨会话泄露
AppState.get().addPhaseListener((phase: AppPhase): void => {
  if (phase === 'onboarding') {
    ItemEditViewModel.clearAll();
  }
});

