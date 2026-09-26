/*
 * SPDX-FileCopyrightText: 2026 Liugt
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import { CipherView, FolderView, FieldView, FieldType2, CardView, IdentityView, HistoryItemView }
  from '../state/VaultMemoryIndex';
import { ItemType } from '../../domain/model/ItemType';

export class MockDataset {
  static createMockFolders(): FolderView[] {
    return [
      new FolderView('mock-folder-work', '工作与办公'),
      new FolderView('mock-folder-social', '常用社交'),
      new FolderView('mock-folder-finance', '金融资产'),
      new FolderView('mock-folder-life', '个人生活')
    ];
  }

  static createMockCiphers(): CipherView[] {
    const now: number = Date.now();

    // 1. GitHub (带动态 TOTP、历史记录、自定义字段)
    const githubHistory: HistoryItemView[] = [
      new HistoryItemView('OldPass_2025_v1', now - 86400000 * 60),
      new HistoryItemView('InitialPass_2024', now - 86400000 * 180)
    ];
    const githubFields: FieldView[] = [
      new FieldView(FieldType2.Hidden, 'Recovery Codes', '8f3a-9c2b-4e1d-77aa', true),
      new FieldView(FieldType2.Text, 'SSH Key Fingerprint', 'SHA256:mQ8ZfN7bV6kP2...', false)
    ];
    const github = new CipherView(
      'mock-cipher-github',
      ItemType.Login,
      'GitHub (Liugt)',
      true, // favorite
      'mock-folder-work',
      null, // not deleted
      now,
      'developer@hallpass.org',
      'Hp#2026!gHub$Secure',
      'otpauth://totp/GitHub:developer?secret=JBSWY3DPEHPK3PXP&issuer=GitHub',
      ['https://github.com/login', 'https://gist.github.com'],
      '核心开源仓库维护者账号，开启了两步验证，关联 SSH 密钥。',
      githubFields,
      null,
      null,
      [],
      githubHistory,
      now - 3600000 * 2 // 最近 2 小时前使用
    );

    // 2. 路由器管理 (安全备注)
    const routerNote = new CipherView(
      'mock-cipher-router',
      ItemType.SecureNote,
      '家庭 Wi-Fi 6 与网关设置',
      true, // favorite
      'mock-folder-life',
      null,
      now,
      '',
      '',
      '',
      [],
      'Wi-Fi SSID (5G): HallPass_Home_Extreme\nWi-Fi 密码: SunshineCoffee#2026\n管理后台: 192.168.50.1\n管理员: admin / P@ssw0rdForRouter99\nDDNS 域名: home.hallpass.me',
      [],
      null,
      null,
      [],
      [],
      now - 86400000
    );

    // 3. 招行信用卡 (银行卡)
    const cmbCard = new CipherView(
      'mock-cipher-cmb-card',
      ItemType.Card,
      '招商银行经典白金信用卡',
      false,
      'mock-folder-finance',
      null,
      now,
      '',
      '',
      '',
      [],
      '开卡礼已领取，年费 10000 积分抵扣。账单日每月 7 号。',
      [],
      new CardView('Liugt', 'UnionPay', '6225 8888 1234 5678', '09', '2029', '888'),
      null,
      [],
      [],
      0
    );

    // 4. 工作通讯录 (身份)
    const identityCn = new CipherView(
      'mock-cipher-identity-cn',
      ItemType.Identity,
      'Liugt (办公名片)',
      false,
      'mock-folder-work',
      null,
      now,
      '',
      '',
      '',
      [],
      '用于对外商务交流与团队登记。',
      [],
      null,
      new IdentityView(
        'GT', '', 'Liu',
        'HallPass OpenSource Studio',
        'liugt@hallpass.example.com',
        '+86 138 0013 8000',
        '110101199003072345',
        '', '',
        '高新南一道 88 号 创新科技广场 B 座 16 楼', '', '',
        '深圳市', '广东省', '518057', '中国 (CN)'
      ),
      [],
      [],
      0
    );

    // 5. Steam 游戏账号 (普通登录)
    const steam = new CipherView(
      'mock-cipher-steam',
      ItemType.Login,
      'Steam 社区与游戏库',
      false,
      'mock-folder-social',
      null,
      now,
      'cyber_gamer_2026',
      'G@mePlay#Forever88',
      '',
      ['https://store.steampowered.com'],
      '包含全部 3A 游戏库，已绑定手机 Steam 令牌。',
      [],
      null,
      null,
      [],
      [],
      0
    );

    // 6. 回收站条目 (已软删除)
    const trashItem = new CipherView(
      'mock-cipher-trash-old',
      ItemType.Login,
      '旧论坛灌水账号 (已注销)',
      false,
      'mock-folder-social',
      now - 86400000 * 3, // 3 天前软删除
      now,
      'forum_legacy_user',
      '12345678old',
      '',
      [],
      '已废弃不再使用。',
      [],
      null,
      null,
      [],
      [],
      0
    );

    return [github, routerNote, cmbCard, identityCn, steam, trashItem];
  }
}
