/*
 * SPDX-FileCopyrightText: 2026 Liugt
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import { VaultMemoryIndex, CipherView, FolderView } from '../../application/state/VaultMemoryIndex';
import { ServiceLocator } from '../../application/ServiceLocator';
import { CipherDraft } from '../../application/WriteService';
import { ItemType } from '../../domain/model/ItemType';
import { TotpConfig, TotpAlgorithm, totpAt, secondsRemaining } from '../../common/utils/Totp';
import { OtpauthUri } from '../../common/utils/OtpauthUri';
import { AppState } from '../../application/state/AppState';

/** 筛选 chips（spec F6）。 */
export type VaultChip = 'all' | 'favorites' | 'login' | 'note' | 'card' | 'identity' | 'trash';

/** 字母分组（索引条定位用）。 */
export interface LetterGroup {
  letter: string;
  items: CipherView[];
}

export interface TotpBadge {
  code: string;
  remaining: number;
}

/** 主页分类卡计数（category grid，spec F6 重构）。 */
export interface VaultCounts {
  all: number;
  favorites: number;
  login: number;
  note: number;
  card: number;
  identity: number;
  trash: number;
  folderCounts: Map<string, number>;
}

const NON_LATIN_GROUP: string = '#';

function firstLetter(name: string): string {
  const trimmed: string = name.trim();
  if (trimmed.length === 0) {
    return NON_LATIN_GROUP;
  }
  const first: string = trimmed.charAt(0).toUpperCase();
  const code: number = first.charCodeAt(0);
  const isLatinUpper: boolean = code >= 65 && code <= 90;
  return isLatinUpper ? first : NON_LATIN_GROUP;
}

function matchesChip(item: CipherView, chip: VaultChip): boolean {
  if (chip === 'all') {
    return true;
  }
  if (chip === 'favorites') {
    return item.favorite;
  }
  if (chip === 'login') {
    return item.type === 1;
  }
  if (chip === 'note') {
    return item.type === 2;
  }
  if (chip === 'card') {
    return item.type === 3;
  }
  return item.type === 4;
}

function matchesSearch(item: CipherView, query: string): boolean {
  if (query.length === 0) {
    return true;
  }
  const needle: string = query.toLowerCase();
  if (item.name.toLowerCase().indexOf(needle) >= 0) {
    return true;
  }
  if (item.username.toLowerCase().indexOf(needle) >= 0) {
    return true;
  }
  if (item.notes.toLowerCase().indexOf(needle) >= 0) {
    return true;
  }
  for (let i = 0; i < item.uris.length; i++) {
    if (item.uris[i].toLowerCase().indexOf(needle) >= 0) {
      return true;
    }
  }
  return false;
}

/**
 * 保管库列表 ViewModel（票 17，spec F6）：筛选 → 搜索（名称/用户名/URI/备注，
 * 大小写不敏感）→ 排序（名称/最近使用）→ 字母分组（非拉丁归 #）；
 * TOTP 徽标订阅 ClockService 每秒 tick；数据源 = MemoryIndex（解锁后明文投影）。
 * 排序"最近使用"以 revisionDate 近似（plan §1.4 无 last_used 列，audit L1）。
 */
@ObservedV2
export class VaultViewModel {
  readonly index: VaultMemoryIndex;
  @Trace chip: VaultChip = 'all';
  @Trace folderId: string | null = null;
  @Trace trashMode: boolean = false;
  @Trace searchText: string = '';
  @Trace sortRecent: boolean = false;
  @Trace groups: LetterGroup[] = [];
  @Trace generation: number = 0;
  @Trace visibleCount: number = 0;
  @Trace folders: FolderView[] = [];
  @Trace totpTick: number = 0;
  @Trace totpBadges: Map<string, TotpBadge> = new Map();
  /** 分类卡计数（不随筛选/搜索变化，始终全量统计）。 */
  @Trace counts: VaultCounts = {
    all: 0, favorites: 0, login: 0, note: 0, card: 0, identity: 0, trash: 0,
    folderCounts: new Map()
  };
  private totpConfigs: Map<string, TotpConfig | null> = new Map();
  private tickListener: ((epochSeconds: number) => void) | null = null;
  private indexListener: (() => void) | null = null;
  /** Settings signals read the shared state, not pending persistence writes. */
  private settingsListener: ((phase: string) => void) | null = null;

  constructor() {
    this.index = ServiceLocator.sync().indexState();
    this.loadSortPreference();
  }

  aboutToDetach(): void {
    if (this.tickListener !== null) {
      ServiceLocator.clock().removeListener(this.tickListener);
      this.tickListener = null;
    }
    if (this.indexListener !== null) {
      this.index.removeListener(this.indexListener);
      this.indexListener = null;
    }
    if (this.settingsListener !== null) {
      AppState.get().removeSettingsListener(this.settingsListener);
      this.settingsListener = null;
    }
  }

  /** 索引变更订阅（页面 aboutToAppear 调用）：监听器只做读取重建（refresh），
   *  禁止触发 upsert/remove 等写路径，防 notify 回环与重复刷新（FIX-01）。 */
  attachIndexListener(): void {
    if (this.settingsListener === null) {
      this.settingsListener = (_phase: string): void => {
        this.loadSortPreference();
      };
      AppState.get().addSettingsListener(this.settingsListener);
    }
    if (this.indexListener !== null) {
      return;
    }
    this.indexListener = (): void => {
      this.refresh();
    };
    this.index.addListener(this.indexListener);
  }

  /** 重新计算分组与 TOTP 配置缓存（数据/筛选变化时调用）。 */
  refresh(): void {
    const isTrash: boolean = this.chip === 'trash';
    const active: CipherView[] = this.index.entries.filter(
      (item: CipherView): boolean => isTrash ? item.deletedDate !== null
        : item.deletedDate === null);
    const filtered: CipherView[] = active.filter((item: CipherView): boolean =>
      (isTrash || matchesChip(item, this.chip)) && matchesSearch(item, this.searchText)
      && this.matchesFolder(item));
    const sorted: CipherView[] = filtered.slice(0);
    if (this.sortRecent) {
      // "最近使用"（T27，spec F6）：按 last_used_at 降序；从未使用（0）排在使用过后
      sorted.sort((a: CipherView, b: CipherView): number => {
        if (a.lastUsedAt > 0 && b.lastUsedAt > 0 && a.lastUsedAt !== b.lastUsedAt) {
          return b.lastUsedAt - a.lastUsedAt;
        }
        if (a.lastUsedAt > 0 && b.lastUsedAt === 0) {
          return -1;
        }
        if (a.lastUsedAt === 0 && b.lastUsedAt > 0) {
          return 1;
        }
        const byName: number = a.name.localeCompare(b.name);
        return byName !== 0 ? byName : a.username.localeCompare(b.username);
      });
    } else {
      sorted.sort((a: CipherView, b: CipherView): number => {
        const byName: number = a.name.localeCompare(b.name);
        return byName !== 0 ? byName : a.username.localeCompare(b.username);
      });
    }
    const groups: LetterGroup[] = [];
    let current: LetterGroup | null = null;
    for (let i = 0; i < sorted.length; i++) {
      const letter: string = firstLetter(sorted[i].name);
      if (current === null || current.letter !== letter) {
        current = { letter: letter, items: [] };
        groups.push(current);
      }
      current.items.push(sorted[i]);
    }
    // Rebuild captured builder arguments even when replacement revisions match.
    this.generation++;
    this.groups = groups;
    this.visibleCount = sorted.length;
    this.folders = this.index.folders;
    this.rebuildTotpConfigs(sorted);
    this.totpTick = Math.floor(Date.now() / 1000);
    this.updateTotpBadges(this.totpTick);
    this.recomputeCounts();
  }

  private recomputeCounts(): void {
    const c: VaultCounts = {
      all: 0, favorites: 0, login: 0, note: 0, card: 0, identity: 0, trash: 0,
      folderCounts: new Map()
    };
    for (let i = 0; i < this.index.entries.length; i++) {
      const item: CipherView = this.index.entries[i];
      if (item.deletedDate !== null) {
        c.trash++;
        continue;
      }
      c.all++;
      if (item.favorite) {
        c.favorites++;
      }
      if (item.type === 1) {
        c.login++;
      } else if (item.type === 2) {
        c.note++;
      } else if (item.type === 3) {
        c.card++;
      } else if (item.type === 4) {
        c.identity++;
      }
      if (item.folderId !== null) {
        const prev: number = c.folderCounts.get(item.folderId) ?? 0;
        c.folderCounts.set(item.folderId, prev + 1);
      }
    }
    this.counts = c;
  }

  private matchesFolder(item: CipherView): boolean {
    if (this.folderId === null) {
      return true;
    }
    if (this.folderId.length === 0) {
      return item.folderId === null;
    }
    return item.folderId === this.folderId;
  }

  private rebuildTotpConfigs(items: CipherView[]): void {
    this.totpConfigs.clear();
    for (let i = 0; i < items.length; i++) {
      const item: CipherView = items[i];
      if (item.totpSecret.length === 0) {
        continue;
      }
      this.totpConfigs.set(item.id, OtpauthUri.parse(item.totpSecret));
    }
  }

  /** ClockService 订阅（页面 aboutToAppear 调用）。 */
  startTicking(): void {
    if (this.tickListener !== null) {
      return;
    }
    this.tickListener = (epochSeconds: number): void => {
      this.totpTick = epochSeconds;
      this.updateTotpBadges(epochSeconds);
    };
    ServiceLocator.clock().addListener(this.tickListener);
    this.tickListener(Math.floor(Date.now() / 1000));
    ServiceLocator.clock().start();
  }

  private updateTotpBadges(epochSeconds: number): void {
    const badges: Map<string, TotpBadge> = new Map();
    this.totpConfigs.forEach((config: TotpConfig | null, id: string): void => {
      if (config === null) {
        return;
      }
      const code: string | null = totpAt(config, epochSeconds);
      if (code !== null) {
        badges.set(id, { code: code, remaining: secondsRemaining(config.period, epochSeconds) });
      }
    });
    this.totpBadges = badges;
  }

  badgeFor(id: string): TotpBadge | null {
    const badge: TotpBadge | undefined = this.totpBadges.get(id);
    return badge === undefined ? null : badge;
  }

  /** 索引条字母表（当前分组的字母序列）。 */
  letters(): string[] {
    return this.groups.map((group: LetterGroup): string => group.letter);
  }

  /** 扁平化条目索引（索引条滚动定位）。 */
  flatIndexForLetter(letter: string): number {
    let offset: number = 0;
    for (let i = 0; i < this.groups.length; i++) {
      if (this.groups[i].letter === letter) {
        return offset;
      }
      offset += this.groups[i].items.length;
    }
    return 0;
  }

  setChip(chip: VaultChip): void {
    this.chip = chip;
    this.refresh();
  }

  setSearchText(text: string): void {
    this.searchText = text;
    this.refresh();
  }

  setFolder(folderId: string | null, trashMode: boolean): void {
    this.folderId = folderId;
    this.trashMode = trashMode;
    this.refresh();
  }

  /** 同步（下拉刷新触发）；完成返回。 */
  async syncNow(): Promise<void> {
    await ServiceLocator.sync().sync();
    this.refresh();
  }

  async loadSortPreference(): Promise<void> {
    this.sortRecent = ServiceLocator.settings().state.sortRecent;
    this.refresh();
  }

  /** 页面初始化（排序偏好载入）。 */
  async init(): Promise<void> {
    await this.loadSortPreference();
  }

  private moveTargetId: string | null = null;

  beginMove(id: string): void {
    this.moveTargetId = id;
  }

  /** 移动文件夹（写路径：整草稿重存，仅 folderId 变更）。 */
  async applyMove(folderId: string | null): Promise<void> {
    const target: string | null = this.moveTargetId;
    this.moveTargetId = null;
    if (target === null) {
      return;
    }
    const view: CipherView | null = this.findById(target);
    if (view === null) {
      return;
    }
    const draft: CipherDraft = this.draftFromView(view);
    draft.folderId = folderId;
    await ServiceLocator.write().save(draft);
    this.refresh();
  }

  /** 收藏切换（左滑动作）。 */
  async toggleFavorite(item: CipherView): Promise<void> {
    const view: CipherView | null = this.findById(item.id);
    if (view === null) {
      return;
    }
    const draft: CipherDraft = this.draftFromView(view);
    draft.favorite = !view.favorite;
    await ServiceLocator.write().save(draft);
    this.refresh();
  }

  /** 软删（长按菜单，spec F9：确认弹窗由页面负责）。 */
  async softDelete(id: string): Promise<void> {
    await ServiceLocator.write().softDelete(id);
    this.refresh();
  }

  /** 复制密码成功后的本地"最近使用"更新（T27，spec F6；仅复制密码计，不入服务器同步）。 */
  async touchLastUsed(id: string): Promise<void> {
    await ServiceLocator.sync().touchLastUsed(id);
    this.refresh();
  }

  private findById(id: string): CipherView | null {
    for (let i = 0; i < this.index.entries.length; i++) {
      if (this.index.entries[i].id === id) {
        return this.index.entries[i];
      }
    }
    return null;
  }

  /** 明文视图 → 草稿（委托 WriteService，草稿概念归属写服务）。 */
  private draftFromView(view: CipherView): CipherDraft {
    return ServiceLocator.write().draftFromView(view);
  }

}
