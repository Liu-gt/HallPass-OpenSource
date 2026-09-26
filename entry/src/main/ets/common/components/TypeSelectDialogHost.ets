/*
 * SPDX-FileCopyrightText: 2026 Liugt
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import { TypeSelectDialogService } from '../../application/TypeSelectDialogService';
import { TypeSelectDialog } from './TypeSelectDialog';
import { ItemType } from '../../domain/model/ItemType';

/**
 * 条目类型选择弹窗根级宿主：由 Index 渲染在 Navigation 之上，
 * 使 TypeSelectDialog 的 scrim 覆盖状态栏与页签栏（含玻璃条带），阻断下层交互。
 */
@ComponentV2
export struct TypeSelectDialogHost {
  private service: TypeSelectDialogService = TypeSelectDialogService.get();

  build() {
    if (this.service.visible) {
      TypeSelectDialog({
        title: this.service.title,
        onSelect: (type: ItemType): void => {
          this.service.select(type);
        },
        onCancel: (): void => {
          this.service.cancel();
        }
      })
    }
  }
}
