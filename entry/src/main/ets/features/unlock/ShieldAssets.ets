/*
 * SPDX-FileCopyrightText: 2026 Liugt
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

/**
 * 盾牌动效资源表：按主题色预制的三层 SVG（media/security_shield_<layer>[_<themeId>]）。
 * 资源名必须是编译期字面量（$r 不支持拼接），故按 themeId 显式映射；未知 id 回退默认主题。
 * 深浅两套由 resources/base 与 resources/dark 自动切换，本表只负责"主题色"这一维。
 * 新增主题时：先执行 tools/gen_shield_svgs.py 生成资源，再在下面各表补一行映射。
 */
export class ShieldAssets {
  /** 盾体：剪影淡填充 + 双层泛光 + 左右半盾清晰线条 */
  static body(themeId: string): Resource {
    switch (themeId) {
      case 'waterlily':
        return $r('app.media.security_shield_body_waterlily');
      case 'cathedral':
        return $r('app.media.security_shield_body_cathedral');
      case 'rose':
        return $r('app.media.security_shield_body_rose');
      case 'haystack':
        return $r('app.media.security_shield_body_haystack');
      default:
        return $r('app.media.security_shield_body');
    }
  }

  /** 中央竖条：双层泛光 + 清晰线条（主题色比左右线条更深一档） */
  static bar(themeId: string): Resource {
    switch (themeId) {
      case 'waterlily':
        return $r('app.media.security_shield_bar_waterlily');
      case 'cathedral':
        return $r('app.media.security_shield_bar_cathedral');
      case 'rose':
        return $r('app.media.security_shield_bar_rose');
      case 'haystack':
        return $r('app.media.security_shield_bar_haystack');
      default:
        return $r('app.media.security_shield_bar');
    }
  }

  /** 融化态：轮廓剪影径向渐变 + feGaussianBlur 线条 */
  static solid(themeId: string): Resource {
    switch (themeId) {
      case 'waterlily':
        return $r('app.media.security_shield_solid_waterlily');
      case 'cathedral':
        return $r('app.media.security_shield_solid_cathedral');
      case 'rose':
        return $r('app.media.security_shield_solid_rose');
      case 'haystack':
        return $r('app.media.security_shield_solid_haystack');
      default:
        return $r('app.media.security_shield_solid');
    }
  }
}
