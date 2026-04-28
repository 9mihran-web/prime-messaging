# Prime Messaging Website

Статический product/support сайт для Prime Messaging с английской версией по умолчанию и русской локалью под `/ru/...`.

## Основная маршрутизация

### Английская версия по умолчанию

- `/` -> главная страница
- `/helpcenter/` -> Help Center
- `/security/` -> Security
- `/business/` -> Business
- `/about/` -> About
- `/privacypolicy/` -> Privacy Policy
- `/web/` -> веб-клиент Prime Messaging
- `/admin/` -> browser admin console для пользователей, чатов, сообществ и push broadcast
- `/download/` -> мгновенный редирект в App Store на Prime Messaging

### Русская версия

- `/ru/` -> главная страница
- `/ru/helpcenter/` -> Help Center
- `/ru/security/` -> страница безопасности
- `/ru/business/` -> страница для бизнеса
- `/ru/about/` -> страница о продукте
- `/ru/privacypolicy/` -> Политика конфиденциальности

## Файлы

- `styles.css` — общая дизайн-система и layout для всех страниц
- `script.js` — меню, reveal-анимации и живая отправка support-формы
- `web/` — отдельный статический bundle для рабочего web client поверх backend API
- `admin/` — отдельный статический bundle для browser admin console поверх тех же backend admin API
- `prime-favicon.svg` — favicon
- корневые `about.html`, `business.html`, `security.html` — compatibility redirects на английские маршруты

## Support form

Форма на главной странице сайта отправляет POST-запрос на backend endpoint:

- `POST /support/contact`

По умолчанию письма уходят на:

- `schwitt.shot@yahoo.com`

Можно переопределить через переменную окружения backend:

- `PRIME_MESSAGING_SUPPORT_CONTACT_EMAIL`

## Web client

В `web/` лежит отдельный статический web client для Prime Messaging.

- сейчас он рассчитан на запуск по пути `/web/`
- при необходимости этот же bundle можно вынести на отдельный домен `web.primemessaging.site`
- для realtime browser websocket backend поддерживает `access_token` в query string именно для web client подключения

## Admin console

В `admin/` лежит отдельный статический admin console для Prime Messaging.

- маршрут по сайту: `/admin/`
- можно вынести на отдельный домен `admin.primemessaging.site`
- для работы нужны:
  - обычный вход в Prime Messaging аккаунт администратора `@mihran`
  - серверные admin credentials (`X-Prime-Admin-Login` / `X-Prime-Admin-Password`)
- console работает поверх backend admin endpoints:
  - `/admin/summary`
  - `/admin/users`
  - `/admin/chats`
  - `/admin/messages`
  - `/admin/users/create`
  - `/admin/users/bulk-delete`
  - `/admin/cleanup/legacy-placeholders`
  - `/admin/users/:id/ban`
  - `/admin/chats/:id/official`
  - `/admin/chats/:id/block`
  - `/admin/chats/:id`
  - `/admin/users/:id`
  - `/admin/push/broadcast`

## Быстрый запуск

```bash
python3 -m http.server 8080
```

После этого откройте:

- `http://localhost:8080/`
- `http://localhost:8080/helpcenter/`
- `http://localhost:8080/privacypolicy/`
- `http://localhost:8080/web/`
- `http://localhost:8080/admin/`
- `http://localhost:8080/download/`
- `http://localhost:8080/ru/`
