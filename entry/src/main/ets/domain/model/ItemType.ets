/*
 * SPDX-FileCopyrightText: 2026 Liugt
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

/**
 * 条目类型（Bitwarden 线上数值，直接存入 RDB `type INTEGER` 列并在协议层透传）。
 */
export enum ItemType {
  Login = 1,
  SecureNote = 2,
  Card = 3,
  Identity = 4
}
