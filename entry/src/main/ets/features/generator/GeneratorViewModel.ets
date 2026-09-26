/*
 * SPDX-FileCopyrightText: 2026 Liugt
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import { ServiceLocator } from '../../application/ServiceLocator';
import { PrefKeys } from '../../domain/repository/PreferencesStore';

/** 生成器类型（spec F11）：密码 / 密语。 */
export type GeneratorMode = 'password' | 'passphrase';

/** 字符集类（spec F11 四类开关）。 */
export interface CharClasses {
  upper: boolean;
  lower: boolean;
  digits: boolean;
  symbols: boolean;
}

const UPPER: string = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ';
const LOWER: string = 'abcdefghijklmnopqrstuvwxyz';
const DIGITS: string = '0123456789';
const SYMBOLS: string = '!@#$%^&*()-_=+[]{};:,.<>?';
const NO_RESULT: string = '—';
const PASSPHRASE_WORDS: number = 4;
const MIN_LENGTH: number = 8;
const MAX_LENGTH: number = 128;
const DEFAULT_LENGTH: number = 16;

/** 内置密语词表（spec F11"词表内置资源"；紧凑 128 词，小写）。 */
const WORDLIST: string[] = [
  'able', 'acid', 'aged', 'also', 'area', 'arms', 'army', 'away',
  'baby', 'back', 'ball', 'band', 'barn', 'base', 'bath', 'beak',
  'beam', 'bean', 'bear', 'beat', 'bell', 'belt', 'bird', 'bite',
  'blue', 'boat', 'body', 'bold', 'bolt', 'bone', 'book', 'boom',
  'boot', 'born', 'boss', 'both', 'bowl', 'bulk', 'burn', 'bush',
  'call', 'calm', 'came', 'camp', 'card', 'care', 'case', 'cash',
  'cast', 'cave', 'cell', 'chat', 'chip', 'city', 'club', 'coal',
  'coat', 'code', 'cold', 'come', 'cook', 'cool', 'cope', 'copy',
  'core', 'cork', 'corn', 'cost', 'crew', 'crop', 'dark', 'dawn',
  'days', 'dead', 'deal', 'dear', 'deep', 'deer', 'desk', 'diet',
  'disc', 'does', 'done', 'door', 'dust', 'duty', 'each', 'earn',
  'ease', 'east', 'easy', 'echo', 'edge', 'else', 'even', 'ever',
  'eyes', 'face', 'fact', 'fail', 'fair', 'fall', 'farm', 'fast',
  'fate', 'feed', 'feel', 'feet', 'fell', 'felt', 'file', 'fill',
  'film', 'find', 'fine', 'fire', 'firm', 'fish', 'five', 'flat',
  'flow', 'food', 'foot', 'ford', 'forest', 'form', 'fort', 'four'
];

/**
 * 生成器 ViewModel（票 21，spec F11）：CryptoEngine 安全随机（randomBytes + 拒绝表法
 * 避免模偏差）；任意参数变化即时重生成；密语固定 4 词小写 '-' 连接；全关字符集显示
 * "—" 且复制禁用；参数持久化（genParamsJson，plan §1.5 v1.2），结果不落盘。
 */
@ObservedV2
export class GeneratorViewModel {
  @Trace mode: GeneratorMode = 'password';
  @Trace length: number = DEFAULT_LENGTH;
  @Trace upper: boolean = true;
  @Trace lower: boolean = true;
  @Trace digits: boolean = true;
  @Trace symbols: boolean = true;
  @Trace result: string = '';
  @Trace canCopy: boolean = true;

  async init(): Promise<void> {
    await this.restoreParams();
    await this.regenerate();
  }

  /** 参数变更返回生成完成 Promise：UI 侧据此在结果更新后量算布局（如结果行高度）。 */
  async setMode(mode: GeneratorMode): Promise<void> {
    if (this.mode === mode) {
      return;
    }
    this.mode = mode;
    this.persistParams();
    await this.regenerate();
  }

  /** 长度变化（滑条 8–128 步长 1，对齐 Bitwarden 官方上限；变化即重生成）。 */
  async setLength(length: number): Promise<void> {
    const clamped: number = Math.min(MAX_LENGTH, Math.max(MIN_LENGTH, Math.floor(length)));
    if (clamped === this.length) {
      return;
    }
    this.length = clamped;
    this.persistParams();
    await this.regenerate();
  }

  async setCharClass(name: keyof CharClasses, enabled: boolean): Promise<void> {
    if (name === 'upper') {
      this.upper = enabled;
    } else if (name === 'lower') {
      this.lower = enabled;
    } else if (name === 'digits') {
      this.digits = enabled;
    } else {
      this.symbols = enabled;
    }
    this.persistParams();
    await this.regenerate();
  }

  async regenerate(): Promise<void> {
    if (this.mode === 'passphrase') {
      this.result = await this.generatePassphrase();
      this.canCopy = true;
      return;
    }
    const classes: string[] = [];
    if (this.upper) {
      classes.push(UPPER);
    }
    if (this.lower) {
      classes.push(LOWER);
    }
    if (this.digits) {
      classes.push(DIGITS);
    }
    if (this.symbols) {
      classes.push(SYMBOLS);
    }
    if (classes.length === 0) {
      // 字符集全关（spec F11 边界）：占位"—"，复制禁用
      this.result = NO_RESULT;
      this.canCopy = false;
      return;
    }
    this.result = await this.generatePassword(classes);
    this.canCopy = true;
  }

  copyResult(): void {
    if (!this.canCopy || this.result === NO_RESULT) {
      return;
    }
    ServiceLocator.clipboard().copy(this.result);
  }

  /** 生成密码：每类至少一次（spec 边界）+ 余量从并集取 + 安全随机 Fisher-Yates 洗牌。 */
  private async generatePassword(classes: string[]): Promise<string> {
    const union: string = classes.join('');
    const chars: string[] = [];
    for (let i = 0; i < classes.length; i++) {
      chars.push(classes[i].charAt(await this.secureRandomInt(classes[i].length)));
    }
    while (chars.length < this.length) {
      chars.push(union.charAt(await this.secureRandomInt(union.length)));
    }
    for (let i = chars.length - 1; i > 0; i--) {
      const j: number = await this.secureRandomInt(i + 1);
      const tmp: string = chars[i];
      chars[i] = chars[j];
      chars[j] = tmp;
    }
    return chars.join('');
  }

  /** 密语（spec F11）：固定 4 词，小写 '-' 连接。 */
  private async generatePassphrase(): Promise<string> {
    const words: string[] = [];
    for (let i = 0; i < PASSPHRASE_WORDS; i++) {
      words.push(WORDLIST[await this.secureRandomInt(WORDLIST.length)]);
    }
    return words.join('-');
  }

  /** 安全随机整数 [0, max)：拒绝表法（CryptoEngine.randomBytes，避免模偏差）。 */
  private async secureRandomInt(max: number): Promise<number> {
    const limit: number = Math.floor(0x100000000 / max) * max;
    for (;;) {
      const bytes: Uint8Array = await ServiceLocator.crypto().randomBytes(4);
      const value: number =
        ((bytes[0] << 24) | (bytes[1] << 16) | (bytes[2] << 8) | bytes[3]) >>> 0;
      if (value < limit) {
        return value % max;
      }
    }
  }

  /** 参数持久化（genParamsJson，plan §1.5 v1.2）：仅参数，结果不落盘。 */
  private async persistParams(): Promise<void> {
    const payload: Record<string, Object> = {
      'mode': this.mode as Object,
      'length': this.length as Object,
      'upper': this.upper as Object,
      'lower': this.lower as Object,
      'digits': this.digits as Object,
      'symbols': this.symbols as Object
    };
    await ServiceLocator.prefs().setString(PrefKeys.GEN_PARAMS_JSON, JSON.stringify(payload));
  }

  private async restoreParams(): Promise<void> {
    const raw: string | null =
      await ServiceLocator.prefs().getString(PrefKeys.GEN_PARAMS_JSON);
    if (raw === null || raw.length === 0) {
      return;
    }
    try {
      const obj: Record<string, Object> = JSON.parse(raw) as Record<string, Object>;
      if (obj['mode'] === 'passphrase') {
        this.mode = 'passphrase';
      } else if (obj['mode'] === 'password') {
        this.mode = 'password';
      }
      const len: number = typeof obj['length'] === 'number' ? obj['length'] as number : 0;
      if (len >= MIN_LENGTH && len <= MAX_LENGTH) {
        this.length = len;
      }
      if (typeof obj['upper'] === 'boolean') {
        this.upper = obj['upper'] as boolean;
      }
      if (typeof obj['lower'] === 'boolean') {
        this.lower = obj['lower'] as boolean;
      }
      if (typeof obj['digits'] === 'boolean') {
        this.digits = obj['digits'] as boolean;
      }
      if (typeof obj['symbols'] === 'boolean') {
        this.symbols = obj['symbols'] as boolean;
      }
    } catch (e) {
      /* 损坏参数按默认值 */
    }
  }
}

export { MIN_LENGTH, MAX_LENGTH, NO_RESULT };
