/*
 * SPDX-FileCopyrightText: 2026 Liugt
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

/**
 * 附件二进制传输（票 13，plan D5/infrastructure/http）：
 * 与 09 的 BwApiClientImpl 分文件的直传通道（v2 直传 URL，服务端不经代理体）。
 * 进度以阶段回调（0 开始 / 100 完成）上报——rcp 分片流式上传留待打磨（audit L1）。
 */
import { rcp } from '@kit.RemoteCommunicationKit';

export type ProgressListener = (percent: number) => void;

export class AttachmentApi {
  private session: rcp.Session = rcp.createSession();

  async upload(url: string, data: Uint8Array, onProgress: ProgressListener | null): Promise<void> {
    onProgress?.(0);
    const headers: rcp.RequestHeaders = { 'content-type': 'application/octet-stream' };
    const content: rcp.RequestContent = data.buffer as ArrayBuffer;
    const request: rcp.Request = new rcp.Request(url, 'PUT', headers, content, undefined);
    const response: rcp.Response = await this.session.fetch(request);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw new Error(`AttachmentApi: upload failed with ${response.statusCode}`);
    }
    onProgress?.(100);
  }

  async download(url: string, onProgress: ProgressListener | null): Promise<Uint8Array> {
    onProgress?.(0);
    const request: rcp.Request = new rcp.Request(url, 'GET', undefined, undefined, undefined);
    const response: rcp.Response = await this.session.fetch(request);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw new Error(`AttachmentApi: download failed with ${response.statusCode}`);
    }
    const body: ArrayBuffer | undefined = response.body;
    const bytes: Uint8Array = body === undefined ? new Uint8Array(0) : new Uint8Array(body);
    onProgress?.(100);
    return bytes;
  }

  close(): void {
    this.session.close();
  }
}
