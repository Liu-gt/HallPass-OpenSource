# HallPass

[English](README.en.md) | 中文

HarmonyOS 原生端到端加密密码管理客户端，兼容 Bitwarden 后端（bitwarden.com 官方云与自建 Vaultwarden，支持自定义服务器地址），以 GPL-3.0-or-later 开源。

| 项 | 值 |
|---|---|
| 包名 | `com.liugt.HallPass` |
| 平台 | `runtimeOS: HarmonyOS`，`compatibleSdkVersion: 6.1.0(23)`，`targetSdkVersion: 26.0.0` |
| 形态 | entry HAP 单模块，phone 优先，tablet/2in1 单栏自适应 |
| 技术栈 | ArkTS + ArkUI 状态管理 V2；单文件 NAPI C++（libargon2）；cryptoFramework / relationalStore / RCP / Asset Store Kit |
| 许可 | GPL-3.0-or-later |

## 功能

| 模块 | 能力 |
|---|---|
| 账号 | 邮箱 + 主密码登录；TOTP/邮箱两步验证；官方云或自建服务器；KDF 参数本地缓存（离线主密码解锁） |
| 同步 | 全量同步个人空间，组织条目过滤；下拉刷新；离线缓存；写失败入队、解锁联网后重放 |
| 保管库 | 搜索（名称/用户名/URI/备注）、类型筛选、文件夹、收藏、字母索引、名称/最近使用排序、回收站（软删/恢复/永久删除） |
| 条目 | 登录、安全笔记、银行卡、身份四类 CRUD；多 URI；自定义字段；密码历史；附件上传下载 |
| TOTP | RFC 6238 实时验证码（SHA1/SHA256/SHA512，6/8 位，30 秒步长），列表徽标与详情倒计时环 |
| 生成器 | 密码 / 密语两种模式；长度与字符集配置；参数持久化，生成结果不落盘 |
| 快速解锁 | 指纹/面容或锁屏凭据释放 Asset 中的主密钥；支持关闭"进入需解锁" |
| 锁定 | 自动锁定 4 档（默认 5 分钟）、立即锁定；锁定时清空内存明文索引与密钥 |
| 剪贴板 | 一键复制用户名/密码/TOTP；默认 30 秒自动清除系统剪贴板，且不覆盖用户后续复制的内容；不清理输入法/剪贴板管理工具自行留存的历史数据 |
| 其他 | 防截屏（窗口隐私模式）；5 套主题 + 深浅色；中英双语 |

## 安全模型

### 密钥层级

```
主密码 ──KDF(PBKDF2-SHA256 | Argon2id)──▶ 主密钥 (32B)
主密钥 ──HKDF-SHA256 Expand(info=enc/mac)──▶ 拉伸密钥 (64B)      # 旧账号回退 PBKDF2 拉伸
拉伸密钥 ──解密服务器包裹的用户密钥──▶ 用户密钥 (encKey 32B + macKey 32B)
用户密钥 ──解包条目密钥 / 文件夹密钥（官方云 V2）──▶ 条目密钥、文件夹密钥
上述密钥 ──AES-CBC + HMAC-SHA256──▶ EncString 字段密文
```

- 服务器登录口令为 `PBKDF2(masterKey, 主密码, 迭代 1 次)` 的 Base64；主密码与主密钥不出设备。
- `EncString` 同时兼容 `AesCbc256_HmacSha256_B64`（新）与 `AesCbc128_HmacSha256_B64`（旧）两代格式；解密前强制 HMAC 校验，失败抛错，不返回部分明文。
- 附件使用独立密钥加密，附件密钥以条目密钥（V2）或用户密钥包裹后随条目存储；下载密文按 `iv|ct|mac` 布局解析，先验 MAC 再解密。
- Argon2id 由 `entry/src/main/cpp` 内置的 libargon2 移植经 NAPI 提供，编译固定 `-O2`，调用固定在 TaskPool 线程，主线程不阻塞；C++ 侧对 memory/iterations 设上限校验。

### 本地存储边界

| 数据 | 存储位置 | 说明 |
|---|---|---|
| 条目/文件夹密文、附件元数据 | relationalStore | `data` 列存服务器密文 JSON 原样内容，schema 不随协议字段演进迁移；仅本地元数据（`favorite`、`revision_date`、`deleted_date`、`last_used_at`）落列；附件文件本体解密后经系统文件面板存用户目录，不缓存在应用内 |
| 会话令牌、快速解锁密钥 | Asset Store Kit | 硬件保护、用户认证门控；锁定即释放内存引用 |
| 非敏感偏好 | Preferences | 主题、自动锁定档位、剪贴板开关、KDF 参数缓存（仅参数，无密钥材料）等 |
| 明文索引与密钥 | 进程内存 | 锁定时清空；解锁后从 RDB 密文重建明文投影 |

其余安全措施：防截屏映射窗口隐私模式；剪贴板自动清除默认开启；日志仅记录条目 ID 与错误类型，不输出密钥或明文。权限仅申请 `INTERNET`、`PRIVACY_WINDOW`、`ACCESS_BIOMETRIC`。

剪贴板自动清除的作用域仅为系统剪贴板：复制 30 秒后清空的是系统剪贴板当前内容，输入法、剪贴板管理工具等在复制过程中另行采集或留存的历史数据不受本功能控制，应用无法删除。敏感凭据在输入法历史中的残留需由用户通过输入法自身的清除功能处理。

## 架构

### 分层与依赖方向

```
features (view / ViewModel) ──▶ application (服务编排) ──▶ domain (纯逻辑)
                                                             ▲
infrastructure (系统能力实现) ────────────────────────────────┘
application/bootstrap/AppContainer ── 唯一同时装配 application 与 infrastructure 的组装点
common/design、common/components、common/utils ── 各层复用
```

- `domain` 不 import 任何 `@ohos.*` / `@kit.*`，可脱离设备单测；`infrastructure` 实现 domain 接口；`features` 只依赖 application 与 common/design，不直接触碰协议与存储。
- 状态管理统一 ArkUI V2（`@ObservedV2` / `@Trace` / `@Local` / `@Provider` / `@Consumer`），无 V1 装饰器混用。
- 路由为全局唯一 `Navigation` + `NavPathStack`，参数只传条目 ID；Onboarding / Unlock 为根级条件渲染，非路由页。

### 目录结构

```
entry/src/main/ets/
├── entryability/       窗口创建、隐私模式、前后台事件转交
├── pages/              Index.ets：根 Navigation + HdsTabs 外壳
├── features/           页面与 ViewModel：onboarding / unlock / vault / generator / settings
├── application/        会话、锁定、同步、写服务、主题、剪贴板、时钟等服务与内存索引
├── domain/             model / crypto / protocol / repository 接口与纯逻辑
├── infrastructure/     crypto（NAPI 桥）、http（RCP）、db（relationalStore）、asset、clipboard
└── common/             design tokens 与主题、通用组件、工具（TOTP、otpauth、URL 校验）
entry/src/main/cpp/     NAPI 模块 argon2napi：libargon2 移植 + 桥接
entry/src/test/         本地单元测试与接口替身（fakes）
entry/src/ohosTest/     设备侧集成测试
```

## 同步与写路径

- 读：`RCP → BwApiClient → domain 解析/解密 → SyncService → RDB（密文落盘）`，随后重建内存明文索引；同步进行中旧索引可继续浏览。
- 写：客户端加密后上传；成功则更新 RDB 与内存索引，失败则写入 `outbox`（`save` / `softDelete` / `restore` / `hardDelete`），解锁且联网后重放。
- 冲突：以服务器 `revisionDate` 为准，最后写入优先（全量替换语义）。
- 容错：单条目解析或解密失败仅跳过并计数，不阻塞整库同步。
- 数据层以 `vault_id` 为一级维度，为多账号与未来 KeePass 后端预留；MVP UI 仅展示单个保管库。
- 生命周期：锁定 → 清空明文索引与密钥；解锁 → 从 RDB 密文重建并重放离线写队列。

### 协议兼容范围

支持：PBKDF2-SHA256 / Argon2id KDF、用户密钥包裹、官方云 V2 条目与文件夹密钥、两代 EncString、TOTP 与邮箱两步验证、附件 API、软删/恢复/永久删除。

## 构建

前置：DevEco Studio（含 HarmonyOS SDK 与 Native/CMake 工具链）。Argon2 原生依赖（libargon2）已内置仓库，无第三方包依赖。

```bash
# Debug HAP
hvigorw assembleHap --mode module -p product=default -p buildMode=debug

# Release HAP
hvigorw assembleHap --mode module -p product=default -p buildMode=release
```

命令在工程根目录执行（`hvigorw` 由 DevEco Studio 内置终端或命令行工具提供）。签名材料不入库（`.gitignore` 排除 `*.p12` / `*.cer` / `*.p7b` 等），运行前需在 DevEco Studio 中配置本机签名。产物位于 `entry/build/default/outputs/default/`。

## 测试

测试框架为 `@ohos/hypium` 与 `@ohos/hamock`，测试主 seam 是 `domain` 层接口，业务验收不经 UI 驱动。

```bash
# 本地单元测试（纯逻辑 + fakes）
hvigorw test -p module=entry@default

# 设备侧测试（需连接真机或模拟器）
hvigorw onDeviceTest -p module=entry@default
```

- `entry/src/test`：EncString 编解码、TOTP、URL 校验、附件、设置服务、同步投影、写队列重放、锁定流程等，使用 `test/fakes` 中的接口替身。
- `entry/src/ohosTest`：官方加密测试向量（含 Argon2）、协议客户端、KeyStore、Repository 与 Ability 测试。

## 许可

- 许可：GPL-3.0-or-later，全文见 `LICENSE`，源码文件带 SPDX 头。
