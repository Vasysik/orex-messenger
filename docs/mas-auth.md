# Авторизация Orex и Matrix Authentication Service

## Главное решение

Экран входа Orex остаётся нативным и не заменяется страницей в браузере.
Пользователь по-прежнему вводит имя и пароль в аккуратной форме приложения,
а регистрация по коду приглашения остаётся в том же интерфейсе.

MAS используется в двух разных режимах:

1. **Matrix compatibility API** — для нативного входа по паролю, регистрации,
   смены и восстановления пароля. Orex вызывает стандартные Matrix Client-Server
   пути, а reverse proxy направляет соответствующие запросы в ресурс `compat`
   MAS.
2. **OAuth/OIDC под `/auth`** — для будущего входа по QR-коду через Device
   Authorization Grant. Этот контур не принимает пароль из Flutter-формы и не
   должен подменять основной экран входа.

Таким образом, красивый интерфейс Orex сохраняется, а управление паролями уже
может выполняться MAS.

## Что реализовано в клиенте

### Обычный вход и регистрация

Сохранены:

- поля «Имя пользователя» и «Пароль»;
- вход через `m.login.password`;
- регистрация по `m.login.registration_token`;
- нативная смена пароля в настройках;
- все существующие стили, фон, стеклянная панель и брендирование Orex.

Клиент не открывает web-форму MAS для обычного входа и не использует внутренний
GraphQL API его фронтенда.

### Восстановление по почте

На экране входа добавлена небольшая ссылка «Забыли пароль?». Весь сценарий
показывается внутри Orex:

1. пользователь вводит привязанный адрес почты;
2. Orex запрашивает письмо через стандартный Matrix endpoint
   `/_matrix/client/v3/account/password/email/requestToken`;
3. пользователь подтверждает ссылку из письма;
4. пользователь возвращается в тот же диалог и вводит новый пароль;
5. Orex завершает восстановление через
   `/_matrix/client/v3/account/password` и UIA
   `m.login.email.identity`.

Одноразовый `client_secret` существует только в памяти открытого диалога и не
записывается в настройки или базу приложения.

### Основа для входа по QR

Клиент умеет:

- читать OIDC metadata из
  `https://vasys.ru/auth/.well-known/openid-configuration`;
- проверять, что issuer, token endpoint и device authorization endpoint
  действительно находятся внутри настроенного `/auth`;
- определять поддержку OAuth Device Authorization Grant;
- запрашивать `device_code`, `user_code`, `verification_uri`,
  `verification_uri_complete`, срок действия и интервал polling;
- возвращать готовый `qrUri`, который позже можно передать виджету генерации
  QR-кода.

Кнопка QR пока намеренно не добавлена на production-экран. Сначала нужно
проверенно подключить обмен device code на Matrix Native OIDC-сессию в
используемой версии Matrix Dart SDK. Полуготовый пункт, который показывает QR,
но не умеет завершить вход, в интерфейс Orex не попадает.

Для bootstrap QR требуется заранее зарегистрированный public OAuth client:

```text
--dart-define=OREX_OIDC_CLIENT_ID=<ULID-клиента-Orex>
```

Секрет клиента в приложение не встраивается.

## Настройка MAS

Ниже перечислены необходимые части конфигурации. Точные listener-ы и reverse
proxy зависят от текущей схемы развёртывания.

### Пароли, регистрация и восстановление

```yaml
passwords:
  enabled: true

account:
  password_registration_enabled: true
  password_registration_token_required: true
  password_change_allowed: true
  password_recovery_enabled: true
  login_with_email_allowed: true
```

`login_with_email_allowed` нужен только в том случае, если вход по адресу почты
должен работать в обычном поле логина. Для восстановления пароля достаточно
привязанной и подтверждённой почты.

### Отправка писем

```yaml
email:
  from: '"Orex" <noreply@vasys.ru>'
  transport: smtp
  mode: starttls
  hostname: <smtp-хост>
  port: 587
  username: <smtp-пользователь>
  password: <smtp-пароль>
```

Пароль SMTP лучше передавать через secret-файл или механизм секретов окружения,
а не хранить открытым в репозитории.

### Device Authorization Grant для будущего QR

```yaml
oauth:
  device_code_grant_enabled: true
  device_code_user_code_auto_fill_enabled: true
```

Второй параметр позволяет MAS вернуть `verification_uri_complete`, который
удобно сразу кодировать в QR.

### Ресурс compatibility API

MAS должен публиковать ресурс:

```yaml
resources:
  - name: compat
```

Стандартные Matrix пути должны доходить до него без изменения адресов, которые
ожидают Matrix-клиенты. Обычно reverse proxy направляет в MAS как минимум:

```text
/_matrix/client/v3/login
/_matrix/client/v3/register
/_matrix/client/v3/account/password
/_matrix/client/v3/account/password/email/requestToken
```

OAuth, human UI и discovery при этом остаются под `/auth`:

```text
/auth/.well-known/openid-configuration
/auth/oauth2/...
/auth/account/...
```

Не следует пытаться заставить Matrix SDK отправлять обычный
`m.login.password` в `/auth/oauth2/...`: у OAuth/OIDC нет стандартного публичного
метода, куда нативное приложение передаёт логин и пароль пользователя. Для этого
MAS и предоставляет `compat`.

## Нужно ли удалять старые точки входа

Пока в Orex принципиально остаются нативные поля логина и пароля, стандартный
Matrix login endpoint удалять нельзя. Но его можно полностью отвязать от старой
проверки пароля Synapse и обслуживать через MAS compatibility layer.

Это даёт нужное поведение:

- новые версии сохраняют нативный интерфейс;
- старые версии продолжают входить;
- пароль проверяет MAS;
- `/auth` используется для OAuth/device-flow и управления аккаунтом;
- после миграции не требуется держать два независимых хранилища паролей.

Удалять можно старую реализацию авторизации за endpoint-ом, когда подтверждено,
что все password/login запросы уже обрабатывает MAS. Сам стандартный Matrix путь
нужен клиентам и остаётся частью совместимости.

## Следующий этап QR

Для полноценного QR-входа остаются четыре изолированных шага:

1. показать `qrUri` из `beginQrLogin()` в фирменном диалоге Orex;
2. опрашивать token endpoint с обработкой `authorization_pending`, `slow_down`,
   `access_denied` и `expired_token`;
3. безопасно импортировать выданную Native OIDC-сессию в Matrix Dart SDK;
4. после входа предложить E2EE-верификацию нового устройства.

Это не требует переделывать существующую форму входа и может быть добавлено
отдельной аккуратной кнопкой, когда завершающий SDK-flow будет проверен.
