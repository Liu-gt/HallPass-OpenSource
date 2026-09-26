/*
 * SPDX-FileCopyrightText: 2026 Liugt
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import { WelcomeStep } from './WelcomeStep';
import { ThemeService, ThemeState } from '../../application/theme/ThemeService';
import { ServerStep } from './ServerStep';
import { LoginStep } from './LoginStep';
import { Spacing, Radius, Sizes } from '../../common/design/Tokens';
import { SafeArea } from '../../common/design/SafeArea';

/** 向导步骤总数（欢迎/服务器/登录）；两步验证为登录步内部子流程（票 15）。 */
const STEP_COUNT: number = 3;

/**
 * 返回手势拦截器栈（@Entry onBackPress 调用）：后注册者优先；
 * 从栈顶开始调用，首个返回 true 者吞掉事件，全部 false 则交给系统默认行为。
 * 容器（OnboardingPage）先注册兜底，子流程（LoginStep/浮层）后注册优先。
 */
export class OnboardingBackInterceptor {
  private static stack: Array<() => boolean> = [];

  static register(handler: () => boolean): void {
    OnboardingBackInterceptor.stack.push(handler);
  }

  static unregister(handler: () => boolean): void {
    const i: number = OnboardingBackInterceptor.stack.indexOf(handler);
    if (i >= 0) {
      OnboardingBackInterceptor.stack.splice(i, 1);
    }
  }

  static handle(): boolean {
    for (let i = OnboardingBackInterceptor.stack.length - 1; i >= 0; i--) {
      if (OnboardingBackInterceptor.stack[i]()) {
        return true;
      }
    }
    return false;
  }
}

/**
 * 首次启动向导容器（票 14，spec F1）：步骤流转 + 页点进度指示。
 * 未登录时根级条件渲染（非路由页，plan D2）；服务器选择结果经容器传给登录步（票 15 接线）。
 */
@ComponentV2
export struct OnboardingPage {
  /** 品牌色响应源（T24：主题切换经 ThemeState 即时生效）。 */
  private theme: ThemeState = ThemeService.get().state;
  @Local private stepIndex: number = 0;
  @Local private serverUrl: string = 'https://vault.bitwarden.com';
  @Local private safeTop: number = 0;

  private containerBackHandler: () => boolean = (): boolean => {
    if (this.stepIndex > 0) {
      this.back();
      return true;
    }
    return false;
  };

  aboutToAppear(): void {
    this.safeTop = SafeArea.top();
    OnboardingBackInterceptor.register(this.containerBackHandler);
  }

  aboutToDisappear(): void {
    OnboardingBackInterceptor.unregister(this.containerBackHandler);
  }

  /** 页点指示：当前步 primary 实心，其余 separator。 */
  @Builder
  progressDots() {
    Row({ space: Spacing.sm }) {
      ForEach(Array.from({ length: STEP_COUNT }, (_v: undefined, i: number) => i),
        (index: number) => {
          Column()
            .width(Spacing.sm)
            .height(Spacing.sm)
            .borderRadius(Radius.pill(Spacing.sm))
            .backgroundColor(index === this.stepIndex
              ? this.theme.primary
              : $r('app.color.separator'))
        }, (index: number) => index.toString())
    }
    .constraintSize({ minHeight: Sizes.touchMin / 2 })
    .justifyContent(FlexAlign.Center)
    .margin({ top: this.safeTop })
  }

  build() {
    Column() {
      this.progressDots()
      Column() {
        this.stepContent()
      }
      .width('100%')
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Center)
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.system_background'))
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }

  @Builder
  stepContent() {
    if (this.stepIndex === 0) {
      WelcomeStep({ onNext: (): void => this.advance() })
    } else if (this.stepIndex === 1) {
      ServerStep({
        onNext: (serverUrl: string): void => {
          this.serverUrl = serverUrl;
          this.advance();
        },
        onBack: (): void => this.back()
      })
    } else {
      // 登录步槽位：传入 ServerStep 所选服务器地址（spec F1）；空串=第三方服务器，
      // 地址由登录页的服务器地址选项输入。
      LoginStep({
        onNext: (): void => this.back(),
        serverUrl: this.serverUrl,
        customServer: this.serverUrl === '',
        onBack: (): void => this.back()
      })
    }
  }

  private advance(): void {
    if (this.stepIndex < STEP_COUNT - 1) {
      this.stepIndex++;
    }
  }

  private back(): void {
    if (this.stepIndex > 0) {
      this.stepIndex--;
    }
  }
}
