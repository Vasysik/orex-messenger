# Orex Web Release

Перед сборкой версия сверяется с `pubspec.yaml`, затем запускается локальный quality gate:

```powershell
flutter pub get
flutter analyze --no-pub
flutter test --no-pub
```

## Быстро поднять production Web локально

Из корня проекта в PowerShell.

Если `web\e2ee.worker.dart.js` уже есть:

```powershell
flutter build web --release --no-pub --no-web-resources-cdn `
  --dart-define=OREX_ENV=production `
  --dart-define=OREX_DEBUG_LOGS=false

py -m http.server 8080 --directory build\web
```

Откройте `http://localhost:8080`. Это статический production build, а не
`flutter run`. Flutter кладёт release Web-артефакты в `build/web`.

Если worker ещё не собран, один раз выполните перед `flutter build web`:

```powershell
$RepoRoot = (Get-Location).Path
$SdkDir = Join-Path $env:TEMP "livekit-client-sdk-flutter"

Remove-Item -Recurse -Force $SdkDir -ErrorAction SilentlyContinue
git clone --no-checkout https://github.com/livekit/client-sdk-flutter.git $SdkDir
Set-Location $SdkDir
git fetch --depth 1 origin 79921c0ae53e40ed5a0a0bf29a4ecc5a431cfe4e
git checkout --detach FETCH_HEAD
flutter pub get
dart compile js web/e2ee.worker.dart `
  -o "$RepoRoot\web\e2ee.worker.dart.js" `
  -m
Set-Location $RepoRoot
```

После этого повторите production build и запуск сервера из первого блока.

Если команда `py` отсутствует, но установлен Python:

```powershell
python -m http.server 8080 --directory build\web
```

Остановка сервера: `Ctrl+C`. При path-based deep links простой `http.server` не
делает SPA fallback; для проверки главного URL, логина, чатов и звонков этого
достаточно.

## Production build

```powershell
flutter build web --release --no-pub --no-web-resources-cdn `
  --dart-define=OREX_ENV=production `
  --dart-define=OREX_DEBUG_LOGS=false
```

Артефакт:

```text
build\web
```

## Web smoke

Перед публикацией проверьте login/restore session, E2EE сообщения и вложения, большие входящие файлы, Android ↔ Windows ↔ Web media-E2EE звонок, late join и reconnect.

## Деплой на `https://orex.vasys.ru/` через Traefik

В репозитории есть готовый `docker-compose.web.yml`. Он публикует содержимое
`build/web` через nginx в существующую внешнюю сеть `traefik-proxy`. BasicAuth
не включён: сайт доступен публично, а доступ к Matrix-аккаунту по-прежнему
требует обычную Matrix-аутентификацию.

Сначала соберите production Web:

```powershell
flutter build web --release --no-pub --no-web-resources-cdn `
  --dart-define=OREX_ENV=production `
  --dart-define=OREX_DEBUG_LOGS=false
```

Затем на сервере из корня проекта:

```bash
docker compose -f docker-compose.web.yml up -d
```

Обновление после новой сборки:

```bash
docker compose -f docker-compose.web.yml restart orex-web
```

Проверка реальных заголовков после запуска:

```bash
curl -I https://orex.vasys.ru/
```

В ответе должны быть CSP, HSTS, `X-Content-Type-Options: nosniff`,
`X-Frame-Options: DENY`, `Referrer-Policy: no-referrer`, Permissions Policy,
`Cross-Origin-Opener-Policy: same-origin`,
`Cross-Origin-Embedder-Policy: require-corp`,
`Cross-Origin-Resource-Policy: same-origin` и `Cache-Control: no-cache`. Эти
COOP/COEP-заголовки нужны `SharedArrayBuffer`/flutter_rust_bridge; обычный
`flutter run -d chrome` их не выставляет и потому может печатать предупреждение,
даже когда production deployment настроен правильно. Файл `web/_headers` остаётся декларацией тех же
требований для хостингов, которые умеют читать этот формат; при Traefik
заголовки реально выставляет middleware из `docker-compose.web.yml`.
