# HallPass

[中文](README.md) | English

A native end-to-end encrypted password manager for HarmonyOS, compatible with Bitwarden backends (bitwarden.com and self-hosted Vaultwarden, custom server URL supported). Licensed under GPL-3.0-or-later.

| Item | Value |
|---|---|
| Bundle name | `com.liugt.HallPass` |
| Platform | `runtimeOS: HarmonyOS`, `compatibleSdkVersion: 6.1.0(23)`, `targetSdkVersion: 26.0.0` |
| Form factor | Single entry HAP module; phone first, single-column adaptive layout on tablet/2in1 |
| Stack | ArkTS + ArkUI state management V2; single-file NAPI C++ (libargon2); cryptoFramework / relationalStore / RCP / Asset Store Kit |
| License | GPL-3.0-or-later |

## Features

| Area | Capabilities |
|---|---|
| Account | Email + master password sign-in; TOTP/email two-step verification; official cloud or self-hosted server; locally cached KDF parameters (offline master-password unlock) |
| Sync | Full sync of the personal space with organization items filtered out; pull-to-refresh; offline cache; failed writes queued and replayed once unlocked and online |
| Vault | Search (name/username/URI/notes), type filters, folders, favorites, alphabetical index, sort by name/last used, trash (soft delete/restore/permanent delete) |
| Items | CRUD for login, secure note, card, and identity; multiple URIs; custom fields; password history; attachment upload/download |
| TOTP | RFC 6238 codes (SHA1/SHA256/SHA512, 6/8 digits, 30-second period), list badges and detail countdown ring |
| Generator | Password and passphrase modes; length and character-set options; parameters persisted, generated results never written to disk |
| Fast unlock | Fingerprint/face or lock-screen credential releases the master key from Asset Store Kit; "verify identity on entry" can be turned off |
| Locking | Four auto-lock intervals (default 5 minutes) plus manual lock; locking clears the in-memory plaintext index and keys |
| Clipboard | One-tap copy of username/password/TOTP; the system clipboard is auto-cleared after 30 seconds by default and content the user copies later is never overwritten; history retained by input methods or clipboard managers is not cleaned |
| Other | Screenshot blocking (window privacy mode); 5 themes plus light/dark; Chinese and English UI |

## Security Model

### Key hierarchy

```
master password ──KDF(PBKDF2-SHA256 | Argon2id)──▶ master key (32B)
master key ──HKDF-SHA256 Expand(info=enc/mac)──▶ stretched key (64B)   # legacy accounts fall back to PBKDF2 stretching
stretched key ──decrypt server-wrapped user key──▶ user key (encKey 32B + macKey 32B)
user key ──unwrap item / folder keys (official cloud V2)──▶ item key, folder key
keys above ──AES-CBC + HMAC-SHA256──▶ EncString field ciphertext
```

- The server login password is the Base64 of `PBKDF2(masterKey, master password, 1 iteration)`; the master password and master key never leave the device.
- `EncString` supports both `AesCbc256_HmacSha256_B64` (new) and `AesCbc128_HmacSha256_B64` (legacy) formats; HMAC is verified before decryption and a failure throws instead of returning partial plaintext.
- Attachments use separate keys, wrapped with the item key (V2) or the user key and stored with the item; downloaded ciphertext follows the `iv|ct|mac` layout and is MAC-verified before decryption.
- Argon2id comes from the vendored libargon2 port in `entry/src/main/cpp`, exposed over NAPI, always compiled with `-O2`, and invoked on TaskPool threads so the main thread never blocks; the C++ side enforces upper bounds on memory/iterations.

### Local storage boundaries

| Data | Location | Notes |
|---|---|---|
| Item/folder ciphertext, attachment metadata | relationalStore | The `data` column stores the server's ciphertext JSON verbatim, so the schema never migrates with protocol changes; only local metadata (`favorite`, `revision_date`, `deleted_date`, `last_used_at`) gets its own columns. Attachment files are decrypted and written to a user-visible directory through the system file picker, never cached inside the app |
| Session tokens, fast-unlock key | Asset Store Kit | Hardware-protected and gated by user authentication; in-memory references are released on lock |
| Non-sensitive preferences | Preferences | Theme, auto-lock interval, clipboard toggle, cached KDF parameters (parameters only, no key material), etc. |
| Plaintext index and keys | Process memory | Cleared on lock; rebuilt from ciphertext in RDB after unlock |

Other measures: screenshot blocking maps to window privacy mode; clipboard auto-clear is on by default; logs only record item IDs and error types, never keys or plaintext. Only `INTERNET`, `PRIVACY_WINDOW`, and `ACCESS_BIOMETRIC` permissions are requested.

Clipboard auto-clear applies to the system clipboard only: 30 seconds after a copy it empties the current system clipboard content. History captured or retained by input methods or clipboard manager tools is outside the app's control and cannot be deleted by it. Users must remove sensitive leftovers from input method history through the input method's own clearing features.

## Architecture

### Layers and dependency direction

```
features (view / ViewModel) ──▶ application (orchestration) ──▶ domain (pure logic)
                                                                   ▲
infrastructure (system implementations) ───────────────────────────┘
application/bootstrap/AppContainer ── the only assembly point touching both application and infrastructure
common/design, common/components, common/utils ── shared across layers
```

- `domain` imports no `@ohos.*` / `@kit.*` and is unit-testable off-device; `infrastructure` implements domain interfaces; `features` depends only on application and common/design and never touches protocol or storage directly.
- State management is uniformly ArkUI V2 (`@ObservedV2` / `@Trace` / `@Local` / `@Provider` / `@Consumer`), with no V1 decorators mixed in.
- Routing uses a single global `Navigation` + `NavPathStack` and passes item IDs only; Onboarding/Unlock are root-level conditional renders, not routes.

### Directory layout

```
entry/src/main/ets/
├── entryability/       window creation, privacy mode, foreground/background events
├── pages/              Index.ets: root Navigation + HdsTabs shell
├── features/           pages and ViewModels: onboarding / unlock / vault / generator / settings
├── application/        session, lock, sync, write service, theme, clipboard, clock services and in-memory index
├── domain/             model / crypto / protocol / repository interfaces and pure logic
├── infrastructure/     crypto (NAPI bridge), http (RCP), db (relationalStore), asset, clipboard
└── common/             design tokens and themes, shared components, utilities (TOTP, otpauth, URL validation)
entry/src/main/cpp/     NAPI module argon2napi: vendored libargon2 + bridge
entry/src/test/         local unit tests and interface fakes
entry/src/ohosTest/     on-device integration tests
```

## Sync and Write Paths

- Read: `RCP → BwApiClient → domain parsing/decryption → SyncService → RDB (ciphertext)`, then the in-memory plaintext index is rebuilt; the previous index stays browsable while a sync is running.
- Write: encrypted client-side, then uploaded; on success RDB and the in-memory index are updated, on failure the operation is queued in `outbox` (`save` / `softDelete` / `restore` / `hardDelete`) and replayed after unlock while online.
- Conflicts: last write wins by server `revisionDate` (full-replacement semantics).
- Fault tolerance: an item that fails to parse or decrypt is skipped and counted without blocking the whole sync.
- The data layer is keyed by `vault_id`, reserved for multiple accounts and a future KeePass backend; the MVP UI shows a single vault.
- Lifecycle: lock clears the plaintext index and keys; unlock rebuilds from RDB ciphertext and replays the offline write queue.

### Protocol compatibility

Supported: PBKDF2-SHA256 / Argon2id KDFs, user key wrapping, official cloud V2 item and folder keys, both EncString generations, TOTP and email two-step verification, attachment APIs, soft delete/restore/permanent delete.

## Building

Requirements: DevEco Studio with the HarmonyOS SDK and native/CMake toolchain. The native Argon2 dependency (libargon2) is vendored in the repository; there are no third-party package dependencies.

```bash
# Debug HAP
hvigorw assembleHap --mode module -p product=default -p buildMode=debug

# Release HAP
hvigorw assembleHap --mode module -p product=default -p buildMode=release
```

Run commands from the project root (`hvigorw` is provided by the DevEco Studio terminal or command-line tools). Signing material is not committed (`.gitignore` excludes `*.p12` / `*.cer` / `*.p7b` and similar), so configure your own signing in DevEco Studio before installing. Artifacts land in `entry/build/default/outputs/default/`.

## Testing

Tests use `@ohos/hypium` and `@ohos/hamock`; the main seam is the `domain` interface layer, and business acceptance is not driven through the UI.

```bash
# Local unit tests (pure logic + fakes)
hvigorw test -p module=entry@default

# On-device tests (device or emulator required)
hvigorw onDeviceTest -p module=entry@default
```

- `entry/src/test`: EncString codec, TOTP, URL validation, attachments, settings service, sync projection, write-queue replay, lock flows, using the fakes in `test/fakes`.
- `entry/src/ohosTest`: official crypto test vectors (including Argon2), API client, KeyStore, repository, and ability tests.

## License

- License: GPL-3.0-or-later; see `LICENSE`. Source files carry SPDX headers.
