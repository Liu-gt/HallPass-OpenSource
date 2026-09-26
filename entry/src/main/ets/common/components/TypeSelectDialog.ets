/*
 * SPDX-FileCopyrightText: 2026 Liugt
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import { KeyCode } from '@kit.InputKit';
import { Spacing, Typography, Radius, Sizes, Shadows, Opacity } from '../design/Tokens';
import { Motion } from '../design/Motion';
import { ItemType } from '../../domain/model/ItemType';

interface TypeOptionItem {
  type: ItemType;
  label: Resource;
  icon: Resource;
  badgeBg: ResourceColor;
}

/**
 * 条目类型选择弹窗：居中卡片、scrim 全屏压暗（含状态栏与底座）；
 * 主标题 "Type" 左对齐，类型选项垂直列表左对齐，带图标徽章与点击态。
 */
@ComponentV2
export struct TypeSelectDialog {
  @Param title: ResourceStr = $r('app.string.dialog_type_title');
  @Event onSelect: (type: ItemType) => void = (_type: ItemType): void => {};
  @Event onCancel: () => void = (): void => {};

  aboutToAppear(): void {
    // F2-04: 主动清除焦点以收起软键盘，避免弹窗被 IME 遮挡
    try {
      this.getUIContext().getFocusController().clearFocus();
    } catch (_e) {
      // 容错处理
    }
  }

  // F-08: 遵循设计系统规范，使用资源颜色令牌替代硬编码色值
  private readonly options: TypeOptionItem[] = [
    {
      type: ItemType.Login,
      label: $r('app.string.type_login'),
      icon: $r('sys.symbol.person_crop_circle_fill_1'),
      badgeBg: $r('app.color.type_badge_login')
    },
    {
      type: ItemType.Card,
      label: $r('app.string.type_card'),
      icon: $r('sys.symbol.creditcard_fill'),
      badgeBg: $r('app.color.type_badge_card')
    },
    {
      type: ItemType.Identity,
      label: $r('app.string.type_identity'),
      icon: $r('sys.symbol.person_text_rectangle_fill'),
      badgeBg: $r('app.color.type_badge_identity')
    },
    {
      type: ItemType.SecureNote,
      label: $r('app.string.type_note'),
      icon: $r('sys.symbol.doc_text'),
      badgeBg: $r('app.color.type_badge_note')
    }
  ];

  @Builder
  typeRow(item: TypeOptionItem, withDivider: boolean, isFirst: boolean) {
    Column() {
      if (withDivider) {
        Divider()
          .color($r('app.color.separator'))
          .strokeWidth(Sizes.hairline)
          .margin({ left: Spacing.md + Sizes.chip + Spacing.md })
      }
      Row({ space: Spacing.md }) {
        Column() {
          SymbolGlyph(item.icon)
            .fontSize(Sizes.rowIcon)
            .fontColor([$r('app.color.on_tint')])
        }
        .width(Sizes.chip)
        .height(Sizes.chip)
        .borderRadius(Radius.pill(Sizes.chip))
        .backgroundColor(item.badgeBg)
        .justifyContent(FlexAlign.Center)

        Text(item.label)
          .fontSize(Typography.body.size)
          .lineHeight(Typography.body.lineHeight)
          .fontColor($r('app.color.label'))
          .layoutWeight(1)
          .textAlign(TextAlign.Start)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })

        SymbolGlyph($r('sys.symbol.chevron_right'))
          .fontSize(Sizes.chevron)
          .fontColor([$r('app.color.tertiary_label')])
      }
      .width('100%')
      .constraintSize({ minHeight: Sizes.touchMin })
      .padding({ left: Spacing.md, right: Spacing.md, top: Spacing.sm, bottom: Spacing.sm })
      .accessibilityGroup(true)
      .accessibilityText(item.label)
      .accessibilityRole(AccessibilityRoleType.BUTTON)
      .focusable(true)
      .defaultFocus(isFirst) // F2-04: 首项默认获焦，确保外接键盘即时响应 Tab/Enter/Esc
      .stateStyles({
        pressed: {
          .backgroundColor($r('app.color.search_field_secondary'))
        }
      })
      .onClick(() => {
        this.onSelect(item.type);
      })
      .onKeyEvent((event: KeyEvent): boolean => {
        // F2-02: 物理键盘 Enter / Space 触发选中
        if (event.type === KeyType.Down &&
            (event.keyCode === KeyCode.KEYCODE_ENTER || event.keyCode === KeyCode.KEYCODE_SPACE)) {
          this.onSelect(item.type);
          return true;
        }
        return false;
      })
    }
    .width('100%')
  }

  build() {
    Column() {
      Column() {
        // 主标题 "Type" 左对齐
        Row() {
          Text(this.title)
            .fontSize(Typography.headline.size)
            .lineHeight(Typography.headline.lineHeight)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.label'))
            .textAlign(TextAlign.Start)
        }
        .width('100%')
        .padding({ bottom: Spacing.md })

        // F-10: 约束滚动容器，适应折叠屏、横屏与大字号缩放
        Scroll() {
          Column() {
            ForEach(this.options, (item: TypeOptionItem, index: number) => {
              this.typeRow(item, index > 0, index === 0);
            }, (item: TypeOptionItem) => String(item.type))
          }
          .width('100%')
          .borderRadius(Radius.lg)
          .backgroundColor($r('app.color.tertiary_system_background'))
          .clip(true)
        }
        .width('100%')
        .constraintSize({ maxHeight: '55%' })
        .scrollBar(BarState.Off)

        // 取消按钮
        Button($r('app.string.cancel'))
          .type(ButtonType.Normal)
          .width('100%')
          .height(Sizes.control)
          .borderRadius(Radius.pill(Sizes.control))
          .backgroundColor($r('app.color.tertiary_system_background'))
          .fontColor($r('app.color.label'))
          .fontSize(Typography.body.size)
          .fontWeight(FontWeight.Medium)
          .margin({ top: Spacing.lg })
          .stateStyles({
            pressed: { .opacity(Opacity.pressed) },
            normal: { .opacity(1.0) }
          })
          .onClick(() => {
            this.onCancel();
          })
      }
      .width('100%')
      .constraintSize({ maxWidth: 380, maxHeight: '85%' })
      .padding(Spacing.xl)
      .borderRadius(Radius.xl)
      .backgroundColor($r('app.color.secondary_system_background'))
      .clip(true)
      .shadow({
        radius: Shadows.dialog.radius,
        color: Shadows.dialog.color,
        offsetY: Shadows.dialog.offsetY
      })
      .onKeyEvent((event: KeyEvent): boolean => {
        // F2-02: Esc 键取消弹窗
        if (event.type === KeyType.Down && event.keyCode === KeyCode.KEYCODE_ESCAPE) {
          this.onCancel();
          return true;
        }
        return false;
      })
      .onClick(() => {
        // 拦截点击事件，防止冒泡到 scrim
      })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .padding({ left: Spacing.xl, right: Spacing.xl })
    .backgroundColor($r('app.color.scrim'))
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    .onClick(() => {
      this.onCancel();
    })
    .transition(TransitionEffect.opacity(0)
      .animation({ duration: Motion.durationDialog, curve: Motion.curve })
      .combine(TransitionEffect.scale({ x: 1.15, y: 1.15 })
        .animation({ duration: Motion.durationDialog, curve: Motion.curve })))
  }
}
