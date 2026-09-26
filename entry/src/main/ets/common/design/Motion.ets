/*
 * SPDX-FileCopyrightText: 2026 Liugt
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import curves from '@ohos.curves';

/**
 * 动效参数 Token（票 23，spec §5）：时长/曲线唯一权威源。
 * 页面代码禁止裸 ms 数值/裸曲线——一律引用本文件（克制原则：不做锦上添花的新动画）。
 */
export class Motion {
  /** 收缩过渡等快速反馈（大标题收缩紧凑标题浮现）。 */
  static readonly durationQuick: number = 150;
  /** 弹窗出现/消失：大→小渐显、小→大渐隐。 */
  static readonly durationDialog: number = 220;
  /** 生成器结果行随内容增减行的卡片高度过渡（长度滑条连续调整，避免整卡闪跳）。 */
  static readonly durationResultResize: number = 160;
  /** TOTP 倒计时环平滑衰减（每秒 tick 间的视觉过渡）。 */
  static readonly durationTotp: number = 1000;
  /** 解锁完成盾牌动效：① 弹出（弹簧无显式时长，本值=弹簧视为完成的时间，与页签胶囊同规格）。 */
  static readonly durationShieldPop: number = 310;
  /** 解锁完成盾牌动效：② 中心弹出后几近悬停的极缓慢放大。 */
  static readonly durationShieldHover: number = 420;
  /** 解锁完成盾牌动效：③-1 放大到宽度占满屏幕并开始模糊。 */
  static readonly durationShieldFill: number = 130;
  /** 解锁完成盾牌动效：③-2 清晰轮廓急速化为渐变盾牌并铺满全屏。 */
  static readonly durationShieldWash: number = 200;
  /** 解锁完成盾牌动效：③-4 消散（模糊巨盾渐隐 + 背景由虚返实，留足时长做渐变过渡）。 */
  static readonly durationShieldDissolve: number = 500;
  /** 统一缓动曲线（spec §5：EaseOut 体系）。 */
  static readonly curve: Curve = Curve.EaseOut;
  /** 盾牌消散曲线：匀速（"全屏模糊 → 清晰"的长渐变过渡，避免中途陡降显得突然）。 */
  static readonly curveShieldDissolve: Curve = Curve.Linear;
  /** 盾牌弹出曲线：轻微阻尼回弹（与页签胶囊同一弹簧手感）。 */
  static readonly curveShieldPop: ICurve = curves.interpolatingSpring(0, 1, 200, 17);
  /** 连续量平滑曲线（TOTP 环等线性衰减）。 */
  static readonly curveLinear: Curve = Curve.Linear;
}
