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

The backend auto-detects Railway's `PORT` and `RAILWAY_PUBLIC_DOMAIN`.

## Endpoints

- `GET /health`
- `POST /auth/signup`
- `POST /auth/login`
- `GET /usernames/check?username=<name>&user_id=<uuid>`
- `POST /usernames/claim`
- `GET /users/search`
- `POST /chats/direct`
- `GET /messages`
- `POST /messages/send`
