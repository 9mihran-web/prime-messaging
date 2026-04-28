# Prime Messaging Backend

Shared backend for the `online` mode of Prime Messaging.

This is the common server that both phones must use for:

- sign up / log in
- global username lookup
- username uniqueness
- online direct chats
- online message delivery
- avatar upload

`Offline` nearby communication is separate and does not use this backend.

## Local run

```bash
python3 Backend/server.py
```

or:

```bash
docker compose up --build
```

## Build configuration

The iOS app now reads the shared backend URL from the app bundle key:

```text
PrimeMessagingServerURL
```

That key is populated from the Xcode build setting:

```text
PRIME_MESSAGING_SERVER_URL
```

So both phones should be built with the same server URL.

For deployment details, see:

- [DEPLOYMENT.md](/Users/fora/Documents/Prime%20Messaging/Backend/DEPLOYMENT.md)

For Railway from the repository root, set:

```text
RAILWAY_DOCKERFILE_PATH=Backend/Dockerfile
```

Important:

- when this Railway service watches repository paths like `/Backend/**`, run `railway up` from the repository root, not from the `Backend` folder
- from this repository, the correct deploy command is:

```bash
cd "/Users/fora/Desktop/Prime Messenger"
railway up
```

The backend auto-detects Railway's `PORT` and `RAILWAY_PUBLIC_DOMAIN`.

## Endpoints

- `GET /health`
- `POST /auth/signup`
- `POST /auth/login`
- `POST /auth/apple-signin`
- `POST /contacts/match`
- `POST /auth/otp/request`
- `POST /auth/otp/verify`
- `POST /auth/otp-login`
- `GET /usernames/check?username=<name>&user_id=<uuid>`
- `POST /usernames/claim`
- `GET /users/search`
- `POST /chats/direct`
- `GET /messages`
- `POST /messages/send`
- `GET /group-calls/active`
- `GET /group-calls/{id}`
- `GET /group-calls/{id}/events`
- `POST /group-calls`
- `POST /group-calls/{id}/join`
- `POST /group-calls/{id}/leave`
- `POST /group-calls/{id}/offer`
- `POST /group-calls/{id}/answer`
- `POST /group-calls/{id}/ice`
- `POST /group-calls/{id}/media-state`

## OTP configuration (production)

Backend now supports OTP challenge flow with:

- persistent OTP challenge storage in `database.json`
- expiry (TTL)
- resend cooldown
- verify attempt limits
- request/hour limits per identifier+purpose

### Required env vars

```text
PRIME_MESSAGING_OTP_PROVIDER=webhook
PRIME_MESSAGING_OTP_TTL_SECONDS=300
PRIME_MESSAGING_OTP_RESEND_COOLDOWN_SECONDS=30
PRIME_MESSAGING_OTP_VERIFY_ATTEMPT_LIMIT=5
PRIME_MESSAGING_OTP_REQUEST_LIMIT_PER_HOUR=20
PRIME_MESSAGING_OTP_HASH_SECRET=<long-random-secret>
```

### Provider integration modes

- `PRIME_MESSAGING_OTP_PROVIDER=mock`
  - for local/dev; code is only logged to server logs
- `PRIME_MESSAGING_OTP_PROVIDER=webhook`
  - backend calls your OTP gateway endpoint
- `PRIME_MESSAGING_OTP_PROVIDER=vonage`
  - direct SMS sending via Vonage API (no custom webhook needed)
- `PRIME_MESSAGING_OTP_PROVIDER=smtp`
  - direct e-mail OTP via SMTP
- `PRIME_MESSAGING_OTP_PROVIDER=sendgrid`
  - direct e-mail OTP via SendGrid API

Webhook mode env vars:

```text
PRIME_MESSAGING_OTP_PROVIDER_WEBHOOK_URL=https://<your-gateway>/otp/send
PRIME_MESSAGING_OTP_PROVIDER_WEBHOOK_TOKEN=<optional-bearer-token>
```

Webhook payload shape sent by backend:

```json
{
  "identifier": "+15550001111",
  "channel": "sms",
  "otp_code": "123456",
  "purpose": "signup",
  "challenge_id": "uuid",
  "expires_at": "2026-04-13T05:58:45.345377+00:00"
}
```

### Vonage direct SMS mode

```text
PRIME_MESSAGING_OTP_PROVIDER=vonage
PRIME_MESSAGING_VONAGE_API_KEY=<your-api-key>
PRIME_MESSAGING_VONAGE_API_SECRET=<your-api-secret>
PRIME_MESSAGING_VONAGE_SMS_FROM=PrimeMsg
```

Notes:

- Vonage mode supports SMS channel only.
- If you also need e-mail OTP, keep `webhook` mode and route e-mail there.

### SMTP direct e-mail mode

```text
PRIME_MESSAGING_OTP_PROVIDER=smtp
PRIME_MESSAGING_SMTP_HOST=smtp.gmail.com
PRIME_MESSAGING_SMTP_PORT=587
PRIME_MESSAGING_SMTP_USERNAME=<smtp-user>
PRIME_MESSAGING_SMTP_PASSWORD=<smtp-password-or-app-password>
PRIME_MESSAGING_SMTP_FROM=<from-email>
PRIME_MESSAGING_SMTP_USE_TLS=1
```

### SendGrid direct e-mail mode

```text
PRIME_MESSAGING_OTP_PROVIDER=sendgrid
PRIME_MESSAGING_SENDGRID_API_KEY=<sendgrid-api-key>
PRIME_MESSAGING_SENDGRID_FROM_EMAIL=<verified-sender-email>
PRIME_MESSAGING_SENDGRID_FROM_NAME=Prime Messaging
PRIME_MESSAGING_SENDGRID_OTP_SUBJECT=Prime Messaging verification code
```

### Debug mode (never use in production)

```text
PRIME_MESSAGING_OTP_DEBUG_RETURN_CODE=1
```

This includes `debug_otp_code` in API responses for fast local testing.

## Sign in with Apple backend config

```text
PRIME_MESSAGING_APPLE_AUDIENCES=prime1.prime-Messaging
```

Notes:

- Set `PRIME_MESSAGING_APPLE_AUDIENCES` to your iOS Bundle ID (or comma-separated list for multiple bundle IDs).
- Backend validates Apple `identity_token` signature via Apple JWKS, issuer, audience, and expiry.
