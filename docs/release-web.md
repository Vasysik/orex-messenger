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

### Flutter-страница скачивания

`/download/` — это route того же Flutter-приложения, а не отдельный HTML/CSS
frontend. `web/nginx.conf` обрабатывает `/download`/`/download/` явно и возвращает
`index.html`, после чего bootstrap выбирает облегчённый download-screen без
запуска Matrix-сессии. Явный location нужен, чтобы случайная/stale директория
`build/web/download` не превращала этот SPA route в nginx `403 Forbidden`.
После публикации Web страница доступна по адресу:

```text
https://orex.vasys.ru/download/
```

Экран переиспользует Orex theme, `AmbientBackground`, `GlassPanel` и brand-widget.
Он не хранит версии и ссылки вручную: запрашивает `/updates/stable/latest.json`,
валидирует его через общую update-модель и показывает Windows x64, Android ARM64
и ARMv7. Если feed временно недоступен, можно повторить запрос прямо на экране.
В Web переход встроен в экран входа и в шапку списка чатов; нативные сборки его
не показывают.

`web/nginx.conf` держит Web shell и Flutter runtime на revalidation: `index.html`,
`flutter_bootstrap.js`, `main.dart.js`, JS/WASM/JSON и compatibility service
worker получают `Cache-Control: no-cache, must-revalidate`. Это не запрещает
браузеру хранить файлы: неизменившийся ресурс обычно подтверждается дешёвым
`304`, но одноимённый файл нового deploy не должен молча жить год из старого
кэша. Bundled image assets имеют только короткое окно свежести и затем также
проверяются через ETag/Last-Modified. Build-versioned namespace
`/__orex_build/...` текущим bootstrap/nginx **не используется**.

Из-за одноимённых Flutter-файлов `build/web` всё равно нужно публиковать как одну
согласованную сборку. Web PiP bridge живёт во внешнем same-origin
`flutter_bootstrap.js` и устанавливается до запуска Dart. В `index.html` нет
inline-копии bridge: production CSP намеренно не содержит `unsafe-inline`, поэтому
дублирование там только создавало заблокированный `<script>` и шум в Console.
Dart перед interop-вызовом также проверяет наличие всех трёх JS-функций. Поэтому
новый `main.dart.js` со старым shell не должен падать на регистрации PiP callback;
максимум кнопка безопасно вернёт `false`, если bridge действительно недоступен.

`index.html` также держит лёгкий HTML/CSS bootstrap-фон до первого кадра Flutter,
поэтому даже при холодном старте между навигацией и canvas нет белой вспышки.
Preload `app_icon.png` намеренно удалён: Flutter запрашивает ассет уже через свой
versioned asset base, и отдельный preload только создавал предупреждение
`preloaded ... but not used`.

## Web smoke

Отдельно проверьте lifecycle QR-камеры: после `Сканировать → Показать код` и после
закрытия QR-входа браузер должен погасить индикатор камеры, а повторное открытие
сканера должно снова получить изображение. После первого прогрева списка чатов
обычная перезагрузка вкладки должна брать MXC-аватары из persistent Web-кэша;
очистка site data намеренно удаляет этот кэш.

Во время активного Web-звонка отдельно проверьте ручной media PiP из клика по
кнопке плитки. Chrome требует transient user activation для
`requestPictureInPicture()`, поэтому между пользовательским действием и browser
PiP нельзя добавлять отложенный поиск video или другой `await`. После deploy
проверьте и обычную вкладку, которая уже открывала предыдущий релиз: PiP должен
открываться без `Uncaught Error` на
`orexSetPictureInPictureClosedCallback` и без CSP violation про inline script.
Надписи/controls внутри стандартного video PiP (например Chrome `ПРЯМОЙ ЭФИР`)
рисует сам браузер; убрать их CSS/JS-кодом Orex нельзя без перехода на отдельный
Document Picture-in-Picture path с более узкой browser support.

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

Обновление после новой сборки или изменения `docker-compose.web.yml`:

```bash
docker compose -f docker-compose.web.yml up -d --force-recreate orex-web
```

`restart` не применяет изменённые Traefik labels, поэтому для CSP и прочих
заголовков недостаточен.

Проверка реальных заголовков после запуска:

```bash
curl -I https://orex.vasys.ru/
curl -I https://orex.vasys.ru/download/
curl -I https://orex.vasys.ru/flutter_bootstrap.js
```

В ответе должны быть CSP, HSTS, `X-Content-Type-Options: nosniff`,
`X-Frame-Options: DENY`, `Referrer-Policy: no-referrer`, Permissions Policy,
`Cross-Origin-Opener-Policy: same-origin`,
`Cross-Origin-Embedder-Policy: require-corp`,
`Cross-Origin-Resource-Policy: same-origin` и revalidation cache policy.
`/download/` должен отвечать `200`, а не `403`; bootstrap должен иметь
`Cache-Control: no-cache, must-revalidate`. Эти
COOP/COEP-заголовки нужны `SharedArrayBuffer`/flutter_rust_bridge; обычный
`flutter run -d chrome` их не выставляет и потому может печатать предупреждение,
даже когда production deployment настроен правильно. Файл `web/_headers` остаётся декларацией тех же
требований для хостингов, которые умеют читать этот формат; при Traefik
заголовки реально выставляет middleware из `docker-compose.web.yml`.

### CSP и обязательное E2EE

Текущий `flutter_rust_bridge` использует JavaScript-конструктор `Function(...)`,
чтобы подключить свой same-origin WASM-модуль шифрования. Поэтому в `script-src`
намеренно есть `'unsafe-eval'` вместе с `'wasm-unsafe-eval'`: без него
`flutter_vodozemac` не инициализируется и Orex не должен запускаться без E2EE.
Это временный compatibility debt, а не разрешение сторонних скриптов: политика
по-прежнему допускает scripts только с `'self'`. При обновлении bridge проверьте,
что вызов `Function` исчез, и удалите `'unsafe-eval'` из **обоих** источников
CSP (`docker-compose.web.yml` и `web/_headers`).

Если после публикации появился экран запуска с кодом `STARTUP_*`, сначала
проверьте страницу в инкогнито без расширений. Коды `STARTUP_PREFERENCES` и
`STARTUP_MATRIX_CACHE` означают, что браузер запретил localStorage/IndexedDB;
не очищайте локальные данные без резервной фразы E2EE. Для временной
диагностической сборки можно явно задать `--dart-define=OREX_DEBUG_LOGS=true`;
в обычном production build он должен оставаться `false`.
