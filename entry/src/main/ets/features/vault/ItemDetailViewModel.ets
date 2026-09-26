/*
 * SPDX-FileCopyrightText: 2026 Liugt
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import { CipherView, AttachmentView, HistoryItemView }
  from '../../application/state/VaultMemoryIndex';
import { VaultMemoryIndex } from '../../application/state/VaultMemoryIndex';
import { ServiceLocator } from '../../application/ServiceLocator';
import { TotpConfig, totpAt, secondsRemaining } from '../../common/utils/Totp';
import { OtpauthUri } from '../../common/utils/OtpauthUri';
import { FileSaver } from '../../common/utils/FileSaver';
import { CipherDraft } from '../../application/WriteService';
import { ThemeService } from '../../application/theme/ThemeService';

/** 密码强度分段数（spec F7：4 段，按长度 ceil(len/4) 封顶）。 */
export function strengthSegments(password: string): number {
  if (password.length === 0) {
    return 0;
  }
  return Math.min(4, Math.ceil(password.length / 4));
}

/** 强度色语义：≥12 位 success、≥10 位品牌色（ThemeState 直连，T24）、其余 danger（spec F7）。 */
export function strengthColorToken(password: string): ResourceStr {
  if (password.length >= 12) {
    return $r('app.color.success');
  }
  if (password.length >= 10) {
    return ThemeService.get().state.primary;
  }
  return $r('app.color.danger');
}

export function maskPassword(password: string): string {
  return '•'.repeat(Math.min(password.length, 12));
}

export function formatTimestamp(epochMs: number): string {
  if (epochMs <= 0) {
    return '';
  }
  const d: Date = new Date(epochMs);
  const pad = (n: number): string => (n < 10 ? `0${n}` : `${n}`);
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())} ${pad(d.getHours())}:${pad(d.getMinutes())}`;
}

export function formatFileSize(bytes: number): string {
  if (bytes < 1024) {
    return `${bytes} B`;
  }
  if (bytes < 1024 * 1024) {
    return `${(bytes / 1024).toFixed(1)} KB`;
  }
  return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
}

/**
 * 条目详情 ViewModel（票 18，spec F7/F15/F9）：路由参数仅 cipherId（plan §1.2），
 * 数据从 MemoryIndex 明文投影取；密码默认遮蔽、离开页面恢复遮蔽；
 * TOTP 行订阅 ClockService；复制/删除经页面回调（ClipboardService/WriteService）。
 */
@ObservedV2
export class ItemDetailViewModel {
  @Trace view: CipherView | null = null;
  @Trace renderEpoch: number = 0;
  @Trace passwordVisible: boolean = false;
  @Trace folderName: string = '';
  @Trace totpCode: string = '';
  @Trace totpRemaining: number = 0;
  @Trace downloadingIds: string[] = [];
  private cipherId: string = '';
  private totpConfig: TotpConfig | null = null;
  private tickListener: ((epochSeconds: number) => void) | null = null;
  private indexListener: (() => void) | null = null;

  init(cipherId: string): void {
    this.cipherId = cipherId;
    this.refresh();
    if (this.tickListener === null) {
      this.tickListener = (epochSeconds: number): void => {
        if (this.totpConfig !== null) {
          const code: string | null = totpAt(this.totpConfig, epochSeconds);
          this.totpCode = code ?? '';
          this.totpRemaining = secondsRemaining(this.totpConfig.period, epochSeconds);
        }
      };
      ServiceLocator.clock().addListener(this.tickListener);
      ServiceLocator.clock().start();
      this.tickListener(Math.floor(Date.now() / 1000));
    }
    // 索引变更即刷新（fix-07：编辑保存返回详情页立即更新，无需重进列表）
    if (this.indexListener === null) {
      this.indexListener = (): void => {
        this.refresh();
      };
      ServiceLocator.sync().indexState().addListener(this.indexListener);
    }
  }

  /** 明文投影重取（init 的数据部分；索引变更监听与时钟装配除外）。 */
  private refresh(): void {
    const index: VaultMemoryIndex = ServiceLocator.sync().indexState();
    let found: CipherView | null = null;
    for (let i = 0; i < index.entries.length; i++) {
      if (index.entries[i].id === this.cipherId) {
        found = index.entries[i];
        break;
      }
    }
    this.view = found;
    this.folderName = '';
    if (found !== null && found.folderId !== null) {
      for (let i = 0; i < index.folders.length; i++) {
        if (index.folders[i].id === found.folderId) {
          this.folderName = index.folders[i].name;
          break;
        }
      }
    }
    this.totpConfig = found !== null && found.totpSecret.length > 0
      ? OtpauthUri.parse(found.totpSecret) : null;
    const now: number = Math.floor(Date.now() / 1000);
    this.totpCode = this.totpConfig === null ? '' : (totpAt(this.totpConfig, now) ?? '');
    this.totpRemaining = this.totpConfig === null ? 0 : secondsRemaining(this.totpConfig.period, now);
    // Builder value parameters and cached ForEach closures must follow the new projection.
    this.renderEpoch++;
  }

  /** 离开页面恢复默认遮蔽（spec F7 验收）。 */
  onDisappear(): void {
    this.passwordVisible = false;
    if (this.tickListener !== null) {
      ServiceLocator.clock().removeListener(this.tickListener);
      this.tickListener = null;
    }
    if (this.indexListener !== null) {
      ServiceLocator.sync().indexState().removeListener(this.indexListener);
      this.indexListener = null;
    }
  }

  /** 复制密码成功后的本地"最近使用"更新（T27；仅密码计，用户名/TOTP/URI 不计）。 */
  async touchPasswordUsed(): Promise<void> {
    const view: CipherView | null = this.view;
    if (view === null) {
      return;
    }
    await ServiceLocator.sync().touchLastUsed(view.id);
  }

  /** 详情页时间倒序历史投影（T27，spec F7：只读列表）。 */
  historySorted(): HistoryItemView[] {
    const view: CipherView | null = this.view;
    if (view === null) {
      return [];
    }
    const sorted: HistoryItemView[] = view.passwordHistory.slice(0);
    sorted.sort((a: HistoryItemView, b: HistoryItemView): number =>
      b.lastModifiedDate - a.lastModifiedDate);
    return sorted;
  }

  /** 首次触碰密码后保持明文，直至离开详情页。 */
  revealPassword(): void {
    this.passwordVisible = true;
  }

  async toggleFavorite(): Promise<void> {
    const view: CipherView | null = this.view;
    if (view === null) {
      return;
    }
    const draft: CipherDraft = ServiceLocator.write().draftFromView(view);
    draft.favorite = !view.favorite;
    await ServiceLocator.write().save(draft);
    this.init(this.cipherId);
  }

  /** 附件下载（离线/网络失败经错误分类反馈给页面）。 */
  async downloadAttachment(attachment: AttachmentView): Promise<'ok' | 'network' | 'error'> {
    const view: CipherView | null = this.view;
    if (view === null || this.downloadingIds.indexOf(attachment.id) >= 0) {
      return 'error';
    }
    this.downloadingIds = this.downloadingIds.concat([attachment.id]);
    try {
      const ticket = await ServiceLocator.client().requestAttachmentDownload(this.cipherId,
        attachment.id);
      const key: string = ticket.key ?? attachment.keySerialized;
      const plain: Uint8Array = await ServiceLocator.attachment().download(key, ticket.url,
        (_percent: number): void => {
        }, this.cipherId);
      return (await FileSaver.save(attachment.fileName, plain)) ? 'ok' : 'error';
    } catch (e) {
      return 'network';
    } finally {
      this.downloadingIds = this.downloadingIds.filter((id: string): boolean =>
        id !== attachment.id);
    }
  }

  /** 软删（确认弹窗由页面负责）。 */
  async softDelete(): Promise<void> {
    await ServiceLocator.write().softDelete(this.cipherId);
  }
}
