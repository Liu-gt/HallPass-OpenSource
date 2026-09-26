/*
 * SPDX-FileCopyrightText: 2026 Liugt
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import { AppButton } from '../../common/components/AppButton';
import { ThemeService, ThemeState } from '../../application/theme/ThemeService';
import { AppInput } from '../../common/components/AppInput';
import { Spacing, Typography, Sizes, Opacity } from '../../common/design/Tokens';
import { SafeArea } from '../../common/design/SafeArea';
import { UrlCheck } from '../../common/utils/UrlCheck';
import { OnboardingBackInterceptor } from './OnboardingPage';
import { TwoFactorStep } from './TwoFactorStep';
import { NewDeviceVerificationStep } from './NewDeviceVerificationStep';
import { ServiceLocator } from '../../application/ServiceLocator';
import { FastUnlockPromptService } from '../../application/FastUnlockPromptService';
import { Session } from '../../domain/model/Session';
import { SymmetricKey } from '../../domain/crypto/CryptoEngine';
import { KdfParams, KdfType } from '../../domain/model/VaultContext';
import { TokenRequest, ProtocolError, ProtocolErrorKind, TwoFactorRequiredError }
  from '../../domain/protocol/Types';
import { VaultContextId } from '../../application/SessionService';
import { PrefKeys } from '../../domain/repository/PreferencesStore';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { common, OpenLinkOptions } from '@kit.AbilityKit';

/** 登录结果（票 15 编排，spec F2）。serverMessage 仅 Server 兜底场景携带
 *  （服务器原始错误消息，DIAG-01 阶段二），其余场景为 null 走 i18n。 */
export enum LoginOutcome {
  Ok = 'ok',
  NeedTwoFactor = 'need2fa',
  /** 新设备验证（官方云）：服务器已向邮箱发送验证码，需 OTP 步骤后重提交 */
  NeedNewDeviceVerification = 'needNewDevice',
  Credentials = 'credentials',
  Network = 'network',
  Server = 'server'
}

export interface LoginTwoFactorInput {
  provider: number;
  token: string;
  remember: boolean;
}

/**
 * 登录编排（票 15，spec F2）：prelogin 取 KDF → 派生主密钥（Argon2id 经 NAPI 桥/
 * TaskPool）→ 拉伸 → masterPasswordHash → connectToken；2FA 必需时返回提供方列表，
 * 主密码仅存内存、用后即清（LoginStep 持有并在成功/失败路径上置空）。
 */
/** 预备登录产物（未提交：不切相位、不落盘；快速解锁确认后再 commit）。 */
export interface PreparedLogin {
  vaultId: string;
  email: string;
  serverUrl: string;
  session: Session;
  masterKey: Uint8Array;
  stretched: SymmetricKey;
  /** 服务器用户密钥（条目加解密真正密钥，fix-06）；无服务器密钥时等于 stretched。 */
  userKey: SymmetricKey;
  /** 本次登录的 KDF 参数（T26：commit 时写入本地缓存，供离线主密码解锁）。 */
  kdf: KdfParams;
}

export class LoginResult {
  readonly outcome: LoginOutcome;
  readonly providers: number[];
  readonly prepared: PreparedLogin | null;
  readonly serverMessage: string | null;

  constructor(outcome: LoginOutcome, providers: number[] = [],
    prepared: PreparedLogin | null = null, serverMessage: string | null = null) {
    this.outcome = outcome;
    this.providers = providers;
    this.prepared = prepared;
    this.serverMessage = serverMessage;
  }
}

export class LoginFlow {
  async login(serverUrl: string, email: string, password: string,
    twoFactor: LoginTwoFactorInput | null,
    newDeviceOtp: string | null = null): Promise<LoginResult> {
    ServiceLocator.clientImpl().configure(serverUrl);
    const client = ServiceLocator.client();
    const crypto = ServiceLocator.crypto();
    let kdf: KdfParams;
    try {
      const prelogin = await client.prelogin(email.toLowerCase());
      kdf = prelogin.kdfType === KdfType.Argon2id
        ? new KdfParams(KdfType.Argon2id, prelogin.iterations ?? 3,
          prelogin.memory ?? 65536, prelogin.parallelism ?? 4)
        : new KdfParams(KdfType.Pbkdf2, prelogin.iterations ?? 600000);
    } catch (e) {
      return LoginFlow.resultFromError(e);
    }
    let masterKey: Uint8Array;
    let stretched: SymmetricKey;
    let hash: string;
    try {
      masterKey = await crypto.deriveMasterKey(email, password, kdf);
      stretched = await crypto.stretchKeyHkdf(masterKey);
      hash = await crypto.masterPasswordHash(masterKey, password);
    } catch (e) {
      // 派生失败无服务器消息，classify 兜底记录异常类型+消息（阶段二可诊断性）
      return new LoginResult(LoginFlow.classify(e));
    }
    // 新设备验证重提交与 2FA 输入可同时携带（服务器先验 2FA 再验设备 OTP）
    const request: TokenRequest = twoFactor === null
      ? new TokenRequest(email.toLowerCase(), hash, null, null, false, newDeviceOtp)
      : new TokenRequest(email.toLowerCase(), hash, twoFactor.provider, twoFactor.token,
        twoFactor.remember, newDeviceOtp);
    try {
      const token = await client.connectToken(request);
      // 解开服务器用户密钥（fix-06）：条目/文件夹/附件由它加解密，而非拉伸主密钥。
      // 解包失败说明密钥层级不一致，条目必然不可读，按 Server 失败并记录（可诊断性）。
      let userKey: SymmetricKey = stretched;
      if (token.protectedUserKey !== null) {
        try {
          userKey = await crypto.unwrapUserKey(token.protectedUserKey, stretched);
        } catch (e) {
          const err: Error = e as Error;
          hilog.error(0x0000, 'HallPassLogin', 'user key unwrap fail %{public}s: %{public}s',
            err.name ?? 'unknown', err.message ?? '');
          return new LoginResult(LoginOutcome.Server);
        }
      } else {
        hilog.warn(0x0000, 'HallPassLogin', 'token response without Key field');
      }
      const vaultId: string = VaultContextId.forEmail(email.toLowerCase());
      const prepared: PreparedLogin = {
        vaultId: vaultId,
        email: email.toLowerCase(),
        serverUrl: serverUrl,
        session: new Session(token.accessToken, token.refreshToken,
          Date.now() + token.expiresIn * 1000, token.protectedUserKey),
        masterKey: masterKey,
        stretched: stretched,
        userKey: userKey,
        kdf: kdf
      };
      return new LoginResult(LoginOutcome.Ok, [], prepared);
    } catch (e) {
      if (e instanceof TwoFactorRequiredError) {
        return new LoginResult(LoginOutcome.NeedTwoFactor,
          (e as TwoFactorRequiredError).providers);
      }
      return LoginFlow.resultFromError(e);
    }
  }

  /** 提交预备登录（快速解锁确认后调用）：会话落位 + 相位切换 + 首次同步。 */
  async commit(prepared: PreparedLogin): Promise<void> {
    await ServiceLocator.session().completeLogin(prepared.vaultId, prepared.email,
      prepared.serverUrl, prepared.session, prepared.masterKey, prepared.stretched,
      prepared.userKey, prepared.kdf);
    // 首次全量同步（spec F2：登录成功触发；后台执行不阻塞进主界面）。
    // 失败记日志不提示（可下拉重试），避免静默吞错（E2E-01 fix-04 教训）。
    ServiceLocator.sync().sync().catch((e: Object): void => {
      const err: Error = e as Error;
      hilog.error(0x0000, 'HallPassLogin', 'first sync fail %{public}s: %{public}s',
        err.name ?? 'unknown', err.message ?? '');
    });
  }

  private static classify(e: Object): LoginOutcome {
    if (e instanceof ProtocolError) {
      const kind: ProtocolErrorKind = (e as ProtocolError).kind;
      if (kind === ProtocolErrorKind.Credential) {
        return LoginOutcome.Credentials;
      }
      if (kind === ProtocolErrorKind.Network) {
        return LoginOutcome.Network;
      }
      if (kind === ProtocolErrorKind.TwoFactor) {
        return LoginOutcome.NeedTwoFactor;
      }
      if (kind === ProtocolErrorKind.NewDeviceVerification
        || kind === ProtocolErrorKind.NewDeviceOtpInvalid) {
        return LoginOutcome.NeedNewDeviceVerification;
      }
    }
    // 未识别异常/未映射 kind 兜底（DIAG-01 阶段二）：日志记录异常类型+消息，
    // UI 仍用 login_error_server 文案，不外泄 stack。
    const err: Error = e as Error;
    hilog.error(0x0000, 'HallPassLogin', 'login classify fallback %{public}s: %{public}s',
      e instanceof ProtocolError ? `kind=${(e as ProtocolError).kind}` : (err.name ?? 'unknown'),
      err.message ?? '');
    return LoginOutcome.Server;
  }

  /** 分类并透传服务器原始消息（仅 Server 兜底场景；2FA/凭据/网络文案走 i18n）。 */
  private static resultFromError(e: Object): LoginResult {
    const outcome: LoginOutcome = LoginFlow.classify(e);
    const serverMessage: string | null =
      outcome === LoginOutcome.Server && e instanceof ProtocolError
        ? (e as ProtocolError).serverMessage
        : null;
    return new LoginResult(outcome, [], null, serverMessage);
  }
}

function outcomeError(outcome: LoginOutcome): ResourceStr | null {
  if (outcome === LoginOutcome.Credentials) {
    return $r('app.string.login_error_credentials');
  }
  if (outcome === LoginOutcome.Network) {
    return $r('app.string.login_error_network');
  }
  if (outcome === LoginOutcome.Server) {
    return $r('app.string.login_error_server');
  }
  return null;
}

const MAX_TWO_FACTOR_ATTEMPTS: number = 5;

/**
 * 登录步骤（票 15，spec F2 + F3 开启路径）：邮箱/主密码表单（空则禁用）、
 * 2FA 子流程（TOTP/邮箱，连续 5 次失败退回登录）；成功后直接进入主界面，
 * 快速解锁开启确认由主页卡片提示承接（FastUnlockPromptService 一次性信号）。
 */
@ComponentV2
export struct LoginStep {
  /** 品牌色响应源（T24：主题切换经 ThemeState 即时生效）。 */
  private theme: ThemeState = ThemeService.get().state;
  @Event onNext: () => void = (): void => {
  };
  @Param serverUrl: string = 'https://vault.bitwarden.com';
  /** 第三方服务器：登录页显示服务器地址输入项，提交时归一化校验（spec F1）。 */
  @Param customServer: boolean = false;
  @Local private customServerUrl: string = '';
  @Local private serverUrlError: boolean = false;
  @Event onBack: () => void = (): void => {
  };
  private flow: LoginFlow = new LoginFlow();
  private prepared: PreparedLogin | null = null;
  @Local private email: string = '';
  @Local private password: string = '';
  @Local private busy: boolean = false;
  @Local private errorText: ResourceStr | null = null;
  @Local private serverErrorText: string | null = null;
  @Local private showTwoFactor: boolean = false;
  @Local private showNewDeviceVerification: boolean = false;
  /** 2FA 通过后转新设备验证时暂存的 2FA 输入：OTP 重提交必须一并携带（服务器同请求校验） */
  private pendingTwoFactor: LoginTwoFactorInput | null = null;
  @Local private twoFactorExhausted: boolean = false;
  private twoFactorAttempts: number = 0;
  private lastProviders: number[] = [];
  private safeTop: number = 0;
  private safeBottom: number = 0;
  private loginBackHandler: () => boolean = (): boolean => false;
  private normalizedCustomUrl: string = '';

  aboutToAppear(): void {
    this.safeTop = SafeArea.top();
    this.safeBottom = SafeArea.bottom();
    // 返回手势：优先关闭 2FA/新设备验证浮层，其次退回服务器选择（栈式拦截器，先于容器）
    this.loginBackHandler = (): boolean => {
      if (this.showTwoFactor) {
        this.showTwoFactor = false;
        return true;
      }
      if (this.showNewDeviceVerification) {
        this.showNewDeviceVerification = false;
        if (this.pendingTwoFactor !== null) {
          this.showTwoFactor = true;
        }
        return true;
      }
      this.onBack();
      return true;
    };
    OnboardingBackInterceptor.register(this.loginBackHandler);
    this.prefillLastEmail();
  }

  aboutToDisappear(): void {
    OnboardingBackInterceptor.unregister(this.loginBackHandler);
  }

  private prefillLastEmail(): void {
    // 预填上次使用的邮箱（非敏感偏好，plan §1.5；features 经 application 包装）
    ServiceLocator.lastEmail().then((value: string | null): void => {
      if (value !== null) {
        this.email = value;
      }
    }).catch((_e: Object): void => {
    });
  }

  private canSubmit(): boolean {
    return this.email.length > 0 && this.password.length > 0 && !this.busy;
  }

  /** 实际登录地址：官方云用容器传入地址；第三方用登录页输入（提交时归一化缓存）。 */
  private effectiveServerUrl(): string {
    return this.customServer ? this.normalizedCustomUrl : this.serverUrl;
  }

  /** 归一化并校验第三方服务器地址；非法返回 false 并置错误提示。 */
  private validateCustomServer(): boolean {
    if (!this.customServer) {
      return true;
    }
    const normalized: string | null = UrlCheck.normalizeServerUrl(this.customServerUrl);
    if (normalized === null || !UrlCheck.isValidHost(normalized)) {
      this.serverUrlError = true;
      return false;
    }
    this.serverUrlError = false;
    this.normalizedCustomUrl = normalized;
    return true;
  }

  /**
   * 登录后是否跳过快速解锁开启弹层（v1.4）：任一方式偏好已开启（重登场景，密钥由
   * completeLogin 按偏好恢复），或"进入应用需解锁"总开关已关闭（生物识别随总开关
   * 关闭且不再出现解锁页），均无需提示。
   */
  private static async skipFastUnlockPrompt(): Promise<boolean> {
    const prefs = ServiceLocator.prefs();
    const entryLock: boolean | null = await prefs.getBoolean(PrefKeys.ENTRY_LOCK_REQUIRED);
    if (entryLock === false) {
      return true;
    }
    const fingerprint: boolean | null =
      await prefs.getBoolean(PrefKeys.BIOMETRIC_FINGERPRINT_ENABLED);
    if (fingerprint === true) {
      return true;
    }
    const face: boolean | null = await prefs.getBoolean(PrefKeys.BIOMETRIC_FACE_ENABLED);
    return face === true;
  }

  private async submitLogin(twoFactor: LoginTwoFactorInput | null): Promise<void> {
    this.busy = true;
    this.errorText = null;
    this.serverErrorText = null;
    this.serverUrlError = false;
    if (!this.validateCustomServer()) {
      this.busy = false;
      return;
    }
    const result: LoginResult =
      await this.flow.login(this.effectiveServerUrl(), this.email, this.password, twoFactor);
    if (result.outcome === LoginOutcome.Ok && result.prepared !== null) {
      this.prepared = result.prepared;
      await this.proceedAfterPrepared();
      this.busy = false;
      return;
    }
    if (result.outcome === LoginOutcome.NeedTwoFactor) {
      // 主密码保留在内存：2FA/新设备验证重提交仍需它派生密钥（成功提交后才清，spec F2）
      this.showTwoFactor = true;
      this.busy = false;
      return;
    }
    if (result.outcome === LoginOutcome.NeedNewDeviceVerification) {
      this.showNewDeviceVerification = true;
      this.busy = false;
      return;
    }
    this.busy = false;
    this.errorText = outcomeError(result.outcome);
    // Server 兜底时优先展示服务器原始消息（DIAG-01 阶段二），无则显示 i18n 笼统文案
    this.serverErrorText =
      result.outcome === LoginOutcome.Server ? result.serverMessage : null;
  }

  /** prepared 收口（登录提交/2FA 验证/新设备验证共用）：清主密码（用后即清，spec F2）
   *  → 提交登录直接进主界面；需开启快速解锁时登记主页提示（VaultPage 挂载后弹卡片）。 */
  private async proceedAfterPrepared(): Promise<void> {
    this.password = '';
    if (!(await LoginStep.skipFastUnlockPrompt())) {
      FastUnlockPromptService.get().request();
    }
    await this.finishLogin();
  }

  /** 提交登录并进入主界面（会话落位 + 相位切换 + 首次同步）。
   *  commit 失败留在登录页提示（E2E-01 fix-03：不静默），并撤销主页提示登记。 */
  private async finishLogin(): Promise<void> {
    const pending: PreparedLogin | null = this.prepared;
    if (pending === null) {
      return;
    }
    try {
      await this.flow.commit(pending);
      this.prepared = null;
    } catch (e) {
      FastUnlockPromptService.get().clearRequest();
      const err: Error = e as Error;
      hilog.error(0x0000, 'HallPassLogin', 'login commit fail %{public}s: %{public}s',
        err.name ?? 'unknown', err.message ?? '');
      this.errorText = $r('app.string.login_error_server');
    }
  }

  private async verifyTwoFactor(provider: number, code: string,
    remember: boolean): Promise<ResourceStr | null> {
    this.busy = true;
    const result: LoginResult =
      await this.flow.login(this.effectiveServerUrl(), this.email, this.password,
        { provider: provider, token: code, remember: remember } as LoginTwoFactorInput);
    this.busy = false;
    if (result.outcome === LoginOutcome.Ok && result.prepared !== null) {
      this.prepared = result.prepared;
      this.showTwoFactor = false;
      await this.proceedAfterPrepared();
      this.busy = false;
      return null;
    }
    if (result.outcome === LoginOutcome.NeedNewDeviceVerification) {
      // 2FA 输入正确但该设备未被信任：转新设备验证步骤，OTP 重提交时一并携带 2FA 输入
      this.pendingTwoFactor = { provider: provider, token: code, remember: remember };
      this.showTwoFactor = false;
      this.showNewDeviceVerification = true;
      return null;
    }
    if (result.outcome === LoginOutcome.NeedTwoFactor && provider === 1) {
      return null; // 邮箱验证码已发送（服务端再次返回 2FA-required 属预期）
    }
    if (result.outcome === LoginOutcome.NeedTwoFactor) {
      this.lastProviders = result.providers;
      this.twoFactorAttempts++;
      if (this.twoFactorAttempts >= MAX_TWO_FACTOR_ATTEMPTS) {
        this.showTwoFactor = false;
        this.twoFactorExhausted = true;
        return $r('app.string.twofactor_exhausted');
      }
      return $r('app.string.login_error_credentials');
    }
    const mapped: ResourceStr | null = outcomeError(result.outcome);
    return mapped ?? $r('app.string.login_error_server');
  }

  /** 新设备验证码提交（官方云 new device verification）：携主密码（与暂存 2FA 输入）重提交
   *  token 请求；验证码错误留在本步提示重试（服务器不自动重发，需退回重新登录触发新邮件）。 */
  private async verifyNewDeviceOtp(code: string): Promise<ResourceStr | null> {
    this.busy = true;
    const result: LoginResult =
      await this.flow.login(this.effectiveServerUrl(), this.email, this.password,
        this.pendingTwoFactor, code);
    this.busy = false;
    if (result.outcome === LoginOutcome.Ok && result.prepared !== null) {
      this.prepared = result.prepared;
      this.pendingTwoFactor = null;
      this.showNewDeviceVerification = false;
      await this.proceedAfterPrepared();
      this.busy = false;
      return null;
    }
    if (result.outcome === LoginOutcome.NeedNewDeviceVerification) {
      return $r('app.string.newdevice_invalid');
    }
    const mapped: ResourceStr | null = outcomeError(result.outcome);
    return mapped ?? $r('app.string.login_error_server');
  }

  private static readonly REGISTER_URL: string = 'https://bitwarden.com/go/start-free/';

  private openRegisterUrl(): void {
    if (this.busy) {
      return;
    }
    const url: string = LoginStep.REGISTER_URL;
    try {
      const context: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
      if (context) {
        if (typeof context.openLink === 'function') {
          const options: OpenLinkOptions = { appLinkingOnly: false };
          context.openLink(url, options).catch((err: Object): void => {
            hilog.error(0x0000, 'HallPassLogin', 'openLink fail: %{public}s', JSON.stringify(err));
          });
          return;
        }
        context.startAbility({
          action: 'ohos.want.action.viewData',
          entities: ['entity.system.browsable'],
          uri: url
        }).catch((err: Object): void => {
          hilog.error(0x0000, 'HallPassLogin', 'startAbility fail: %{public}s', JSON.stringify(err));
        });
      }
    } catch (e) {
      hilog.error(0x0000, 'HallPassLogin', 'openRegisterUrl error: %{public}s', JSON.stringify(e));
    }
  }

  build() {
    Stack() {
      // 固定布局（不滚动）：内容区限宽居中，适配折叠屏展开等宽屏比例。
      Column() {
        Text($r('app.string.login_title'))
          .fontSize(Typography.largeTitle.size)
          .lineHeight(Typography.largeTitle.lineHeight)
          .fontWeight(Typography.largeTitle.weight)
          .fontColor($r('app.color.label'))
          .margin({ top: this.safeTop + Spacing.xl })

        Column({ space: Spacing.md }) {
          Text($r('app.string.login_label_email'))
            .fontSize(Typography.footnote.size)
            .lineHeight(Typography.footnote.lineHeight)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.secondary_label'))
            .width('100%')
            .textAlign(TextAlign.Start)
          AppInput({
            placeholder: $r('app.string.login_email_hint'),
            text: this.email,
            inputType: InputType.Normal,
            onChange: (value: string): void => {
              this.email = value;
            }
          })
          Text($r('app.string.login_label_password'))
            .fontSize(Typography.footnote.size)
            .lineHeight(Typography.footnote.lineHeight)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.secondary_label'))
            .width('100%')
            .textAlign(TextAlign.Start)
          AppInput({
            placeholder: $r('app.string.login_password_hint'),
            text: this.password,
            inputType: InputType.Password,
            onChange: (value: string): void => {
              this.password = value;
            }
          })
          if (this.customServer) {
            Text($r('app.string.login_label_server'))
              .fontSize(Typography.footnote.size)
              .lineHeight(Typography.footnote.lineHeight)
              .fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.secondary_label'))
              .width('100%')
              .textAlign(TextAlign.Start)
            AppInput({
              placeholder: $r('app.string.server_url_hint'),
              text: this.customServerUrl,
              onChange: (value: string): void => {
                this.customServerUrl = value;
                this.serverUrlError = false;
              }
            })
          }
          Row() {
            Row() {
              Text($r('app.string.login_register_hint'))
                .fontSize(Typography.footnote.size)
                .lineHeight(Typography.footnote.lineHeight)
                .fontColor(this.theme.primary)
            }
            .padding({ top: Spacing.xs, bottom: Spacing.xs })
            .stateStyles({
              pressed: {
                .opacity(Opacity.pressed)
              },
              normal: {
                .opacity(1.0)
              }
            })
            .onClick((): void => {
              this.openRegisterUrl();
            })
          }
          .width('100%')
          .justifyContent(FlexAlign.End)
        }
        .width('100%')
        .margin({ top: Spacing.lg })

        if (this.serverUrlError) {
          Text($r('app.string.server_url_invalid'))
            .fontSize(Typography.footnote.size)
            .lineHeight(Typography.footnote.lineHeight)
            .fontColor($r('app.color.danger'))
            .width('100%')
            .textAlign(TextAlign.Start)
        }

        if (this.serverErrorText !== null) {
          Text(this.serverErrorText)
            .fontSize(Typography.footnote.size)
            .lineHeight(Typography.footnote.lineHeight)
            .fontColor($r('app.color.danger'))
            .width('100%')
            .textAlign(TextAlign.Start)
        } else if (this.errorText !== null) {
          Text(this.errorText)
            .fontSize(Typography.footnote.size)
            .lineHeight(Typography.footnote.lineHeight)
            .fontColor($r('app.color.danger'))
            .width('100%')
            .textAlign(TextAlign.Start)
        }

        if (this.twoFactorExhausted) {
          Text($r('app.string.twofactor_exhausted'))
            .fontSize(Typography.footnote.size)
            .lineHeight(Typography.footnote.lineHeight)
            .fontColor($r('app.color.secondary_label'))
            .width('100%')
            .textAlign(TextAlign.Start)
        }

        if (this.busy) {
          Text($r('app.string.login_busy'))
            .fontSize(Typography.footnote.size)
            .lineHeight(Typography.footnote.lineHeight)
            .fontColor($r('app.color.secondary_label'))
            .width('100%')
            .textAlign(TextAlign.Start)
        }

        Blank().layoutWeight(1)

        Text($r('app.string.previous_step'))
          .fontSize(Typography.subhead.size)
          .lineHeight(Typography.subhead.lineHeight)
          .fontColor(this.theme.primary)
          .constraintSize({ minHeight: Sizes.touchMin })
          .onClick(() => this.onBack())

        AppButton({
          label: $r('app.string.login_cta'),
          isEnabled: this.canSubmit(),
          onTap: (): void => {
            this.submitLogin(null);
          }
        })
          .margin({ top: Spacing.sm })
      }
      .constraintSize({ maxWidth: 520 })
      .width('100%')
      .height('100%')
      .padding({
        left: Spacing.page,
        right: Spacing.page,
        bottom: this.safeBottom + Spacing.xl
      })

      if (this.showTwoFactor) {
        TwoFactorStep({
          providers: this.lastProviders,
          busy: this.busy,
          onVerify: (provider: number, code: string, remember: boolean):
            Promise<ResourceStr | null> => this.verifyTwoFactor(provider, code, remember),
          onBack: (): void => {
            this.showTwoFactor = false;
          }
        })
      }

      if (this.showNewDeviceVerification) {
        NewDeviceVerificationStep({
          busy: this.busy,
          email: this.email,
          onVerify: (code: string): Promise<ResourceStr | null> =>
            this.verifyNewDeviceOtp(code),
          onBack: (): void => {
            this.showNewDeviceVerification = false;
            if (this.pendingTwoFactor !== null) {
              // 从两步验证转入的场景：退回 2FA 步骤重试
              this.showTwoFactor = true;
            }
          }
        })
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.system_background'))
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }
}
