# Prime Messaging Deployment

## Architecture

- `Online mode` follows the Telegram model: one shared central server, global usernames, internet delivery, and one source of truth for chats and messages.
- `Offline mode` follows the BitChat idea: nearby device discovery and direct local exchange without the central server.

## Local run

```bash
docker compose up --build
```

This exposes the shared backend on:

```text
http://127.0.0.1:8080
```

## Public deployment

Deploy `Backend/server.py` or the provided `Backend/Dockerfile` to any VPS, Fly.io, Railway, Render, or another container host.

Recommended environment variables:

```text
PRIME_MESSAGING_HOST=0.0.0.0
PRIME_MESSAGING_PUBLIC_BASE_URL=https://your-domain.example
```

Notes:

- The server now also auto-detects Railway's `PORT` variable, so you do not need to set `PRIME_MESSAGING_PORT` manually on Railway.
- The server also auto-detects Railway's public domain through `RAILWAY_PUBLIC_DOMAIN`, so `PRIME_MESSAGING_PUBLIC_BASE_URL` is optional on Railway.
- If you deploy from the repository root on Railway, set `RAILWAY_DOCKERFILE_PATH=Backend/Dockerfile`.

## iOS app configuration

The iOS build now reads one shared server URL from the app bundle key:

```text
PrimeMessagingServerURL
```

In Xcode, set the build setting `PRIME_MESSAGING_SERVER_URL` to the same public base URL for all builds that should talk to the shared server.

Example:

```text
https://your-domain.example
```

Then both phones will use the same online backend automatically, without showing backend settings in the UI.
