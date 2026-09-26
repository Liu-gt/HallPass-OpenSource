/*
 * SPDX-FileCopyrightText: 2026 Liugt
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import { picker } from '@kit.CoreFileKit';
import { fileIo } from '@kit.CoreFileKit';

/**
 * 系统文件面板落盘（票 13，spec F15）：下载解密后经 DocumentViewPicker 写用户可见目录。
 * 用户取消（空 URI）返回 false；写入失败抛错（UI 提示重试）。
 */
export class FileSaver {
  /** 保存到用户选择的目录，返回是否成功（false = 用户取消）。 */
  static async save(fileName: string, data: Uint8Array): Promise<boolean> {
    const saveOptions: picker.DocumentSaveOptions = new picker.DocumentSaveOptions();
    saveOptions.newFileNames = [fileName];
    const documentPicker: picker.DocumentViewPicker = new picker.DocumentViewPicker();
    const uris: string[] = await documentPicker.save(saveOptions);
    if (uris.length === 0) {
      return false;
    }
    const file = await fileIo.open(uris[0],
      fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.TRUNC);
    try {
      await fileIo.write(file.fd, data);
    } finally {
      await fileIo.close(file.fd);
    }
    return true;
  }
}
