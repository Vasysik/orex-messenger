# Orex Messenger

Orex Messenger is a Flutter messenger built on Matrix, with a native Orex call UI over MatrixRTC and LiveKit. The current target is a desktop-first private alpha / dogfood build, not a public secure-messenger release yet.

Current app version: `0.3.3+2`.

## What Works

- Matrix login, session restore, sync and local cache.
- End-to-end encrypted Matrix messages through the Matrix SDK / vodozemac stack.
- Room list, folders, global search, direct rooms, groups, channels and Matrix Space based supergroups.
- Unified conversation preview flow for public rooms, DMs and room references.
- Chat timeline with message grouping, replies, editing, attachments, drag-and-drop limits and MXC media rendering.
- Native Orex calls over MatrixRTC + LiveKit, without embedding call.element.io.
- Incoming direct-call overlay, active call panel, minimized call panel and full-screen call UI.
- Voice-channel behavior for groups/channels/supergroup chats: listen-only UI, raised hands, reactions and admin voice grants.
- Desktop screen-share picker, audio device settings, camera switching and call controls shared between full and minimized call UI.
- Characterization tests for config, storage policy, room metadata, timeline grouping, attachments, composer state, home coordinator and call components.
- CI-style local gate: analyze, tests, Android builds and Windows builds.

## Honest Security Status

Messages are E2EE at the Matrix layer. Calls use MatrixRTC signaling and LiveKit media transport, but Orex does not yet claim media E2EE for calls. SFrame/key-provider work is still future work.

Voice permissions in channels are currently enforced by the Orex client UX and Matrix state, not by a hardened server-side LiveKit authorization gateway. This is acceptable for dogfood, but it is not a security boundary against modified clients.

Desktop cache security is intentionally strict:

- Android/iOS/macOS can use encrypted storage paths provided by the current database stack.
- Windows/Linux desktop SQLCipher is not wired yet.
- Production desktop builds fail closed at runtime if they would use an unencrypted Matrix cache.
- `OREX_ALLOW_INSECURE_DESKTOP_CACHE=true` is only a dogfood escape hatch, not a public release setting.

## Runtime Configuration

Production defaults:

```text
OREX_ENV=production
OREX_HOMESERVER=https://vasys.ru
OREX_JWT_SERVICE=https://jwt.vasys.ru
```

For `dev` and `staging`, both endpoints must be passed explicitly. This prevents accidental testing against production when a build is meant to target another backend.

Supported dart-defines:

```text
OREX_ENV=dev|staging|production
OREX_HOMESERVER=https://...
OREX_JWT_SERVICE=https://...
OREX_ELEMENT_CALL_BASE=https://...
OREX_REQUIRE_VODOZEMAC=true|false
OREX_DEBUG_LOGS=true|false
OREX_ALLOW_INSECURE_DESKTOP_CACHE=true|false
```

## Build Number Policy

Every distributable build must bump `pubspec.yaml`:

```yaml
version: 0.3.3+N
```

The `+N` build number is what Orex shows as `Сборка N`. The previous committed build was `0.3.3+1`, so the current build is `0.3.3+2`.

## Build And Run

Install dependencies:

```powershell
flutter pub get
```

Run web with cross-origin isolation for vodozemac / WebAssembly:

```powershell
flutter run -d chrome `
  --web-header=Cross-Origin-Opener-Policy=same-origin `
  --web-header=Cross-Origin-Embedder-Policy=require-corp
```

Build web:

```powershell
flutter build web `
  --dart-define=OREX_ENV=production `
  --dart-define=OREX_DEBUG_LOGS=false
```

Build Android debug:

```powershell
flutter build apk --debug
```

Build Android release:

```powershell
flutter build apk --release `
  --dart-define=OREX_ENV=production `
  --dart-define=OREX_DEBUG_LOGS=false
```

Android release builds fail closed unless release signing is configured. Put secrets outside Git in `android/key.properties`:

```properties
storeFile=C:/secure/path/orex-release.jks
storePassword=...
keyAlias=orex
keyPassword=...
```

or pass the equivalent environment variables:

```text
OREX_ANDROID_STORE_FILE
OREX_ANDROID_STORE_PASSWORD
OREX_ANDROID_KEY_ALIAS
OREX_ANDROID_KEY_PASSWORD
```

`OREX_ALLOW_UNSIGNED_ANDROID_RELEASE=true` is reserved for CI compile checks only. Do not use it for a distributable APK.

Build a runnable Windows dogfood release without `OREX_ALLOW_INSECURE_DESKTOP_CACHE`:

```powershell
flutter build windows --release `
  --dart-define=OREX_ENV=dev `
  --dart-define=OREX_HOMESERVER=https://vasys.ru `
  --dart-define=OREX_JWT_SERVICE=https://jwt.vasys.ru `
  --dart-define=OREX_DEBUG_LOGS=false
```

That build is intentionally marked `dev`, even if it points at the real backend. It is for internal dogfood while Windows encrypted cache is unfinished.

For a true public Windows production build, do not use `OREX_ALLOW_INSECURE_DESKTOP_CACHE`. Wire SQLCipher or another encrypted desktop storage path first, then build with:

```powershell
flutter build windows --release `
  --dart-define=OREX_ENV=production `
  --dart-define=OREX_DEBUG_LOGS=false
```

Web does not need `OREX_ALLOW_INSECURE_DESKTOP_CACHE`; that policy applies to IO desktop cache, not browser IndexedDB.

## LiveKit JWT Contract

Orex currently talks to an upstream-compatible `lk-jwt-service` legacy endpoint:

```text
POST {OREX_JWT_SERVICE}/sfu/get
```

The request body must stay legacy-compatible:

```json
{
  "room": "!room:server",
  "openid_token": {
    "access_token": "...",
    "token_type": "Bearer",
    "matrix_server_name": "server"
  },
  "device_id": "DEVICE"
}
```

Do not send `requested_livekit_grants` to this endpoint. Upstream-compatible services reject unknown fields with HTTP 400.

Future server-side voice enforcement should use a separate Orex-specific authorization gateway, for example:

```text
POST /orex/sfu/get/v1
```

That gateway must compute effective LiveKit grants from Matrix room state, power levels and `ru.orex.voice.permissions`. The client may request intent, but the server must make the final decision.

## Local Quality Gate

Before a release candidate:

```powershell
flutter analyze --no-pub
flutter test --no-pub
flutter build apk --debug --no-pub
flutter build windows --debug --no-pub
flutter build apk --release --no-pub     # requires release signing
flutter build windows --release --no-pub
```

For a CI-only Android release compile check without signing secrets, set `OREX_ALLOW_UNSIGNED_ANDROID_RELEASE=true`. Never use that flag for release artifacts.

Android currently emits a Kotlin Gradle Plugin future-compatibility warning. It does not fail the current build, but it must be addressed before future Flutter upgrades.

## Architecture Map

```text
lib/
  core/
    config/       runtime config, app version
    storage/      platform database selection and cache security policy
    matrix/       MatrixService facade and Matrix APIs
    voip/         CallController, CallSession, LiveKit credentials, media controllers
    audio/        audio cues and device preferences
  domain/
    rooms/        Orex room/domain preview models independent from Matrix UI
  features/
    home/         shell and conversation coordinator
    chats/        sidebar, chat view, timeline adapter, composer, attachments
    calls/        call presentation, participant tiles, controls and UI actions
    settings/     settings screens and reusable settings content
  shared/
    theme/        Orex theme/glass styling
    widgets/      dialogs, avatars, profile cards, reusable UI
test/
  core/
  domain/
  features/
```

## Roadmap

### 9.1 Calls And Voice Channels - Done In 0.3.3

Done:

- Native Orex call UI over LiveKit and MatrixRTC.
- Full-screen and minimized call layouts.
- Shared call presentation model, controls and UI actions.
- Participant tiles, screen-share preference, focused participant view and zoom.
- Reactions, raised hands and voice-state rendering.
- Audio device settings shared between dialog and settings screen.
- Desktop source picker for screen sharing.
- Call lifecycle rollback for missing VoIP signaling and failed media connect.

Still not claimed:

- Media E2EE for calls.
- Server-side LiveKit authorization gateway for voice permissions.
- Android native MediaProjection / foreground service for robust mobile screen sharing.

### 9.2 Mobile And Production Infrastructure

Postponed until after the current 0.3.3 stabilization:

- Matrix push gateway, FCM/APNs and background notifications.
- Incoming calls while the app is killed or backgrounded.
- Android foreground call service and proper call lifecycle integration.
- Server-side Orex authorization gateway for LiveKit token grants.
- Media E2EE for calls through LiveKit SFrame/key-provider.
- Windows/Linux encrypted desktop cache.
- Crash reporting and telemetry for login, sync, calls and media.
- Release CI with signed artifacts and retained build outputs.

### 9.3 Chats And Message UX

- Voice messages.
- Short video notes and richer custom media formats.
- Stickers and user-created sticker packs.
- Multi-select message actions.
- Dedicated `ChatTimelineController` to continue shrinking `ChatView`.
- Cross-platform media player polish.

### 9.4 MatrixService Migration

Keep `MatrixService` as a compatibility facade, then gradually move APIs behind narrower services:

- `matrix.rooms`
- `matrix.discovery`
- `matrix.security`
- `matrix.media`
- `matrix.supergroups`

This should happen after call/chat stabilization and contract tests, not as another risky big-bang rewrite.

## Current Readiness

- Previous architecture-plan completion: about 80-85%.
- Desktop-first dogfood readiness: about 65-70%.
- Public cross-platform secure-messenger readiness: about 50-55%.

The remaining work is no longer mostly "giant widget cleanup". The big blockers are backend contracts, encrypted desktop storage, mobile push/background flows, call media E2EE and release operations.
