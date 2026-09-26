/*
 * SPDX-FileCopyrightText: 2026 Liugt
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import { pasteboard } from '@kit.BasicServicesKit';
import { ClipboardSink } from '../../application/ClipboardService';

/**
 * 系统 pasteboard 适配器（票 12，plan D3 infrastructure/clipboard）：
 * ClipboardSink 的系统实现；30 秒清除由 ClipboardService 编排。
 */
export class PasteboardAdapter implements ClipboardSink {
  setContent(text: string): Promise<void> {
    const data: pasteboard.PasteData = pasteboard.createData(
      pasteboard.MIMETYPE_TEXT_PLAIN, text);
    return pasteboard.getSystemPasteboard().setData(data);
  }

  async getContent(): Promise<string | null> {
    const data: pasteboard.PasteData = await pasteboard.getSystemPasteboard().getData();
    const text: string = data.getPrimaryText();
    return text.length === 0 ? null : text;
  }

  clear(): Promise<void> {
    return pasteboard.getSystemPasteboard().clear();
  }
}
