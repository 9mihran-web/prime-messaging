# Prime Messaging Architecture

## 1. iOS App Architecture

### Stack

- `Swift 5.10+`
- `SwiftUI`
- `async/await`
- `Feature-first modular structure inside one Xcode target initially`
- `Repository + service protocol abstractions`
- `Local cache abstraction from day one`

### Architectural Style

- Presentation: `SwiftUI Views + ViewModels`
- Domain: entities, enums, value objects, use-case-like service boundaries
- Data: repositories, transport services, storage adapters, mock/live implementations

This gives fast MVP delivery now and a clean path to splitting packages or frameworks later.

## 2. Backend Proposal

### Recommended First Scalable Version

Use a custom backend with managed infrastructure rather than a fully managed chat product.

Recommended components:

- `API Gateway`
- `Auth Service`
- `Realtime Messaging Service` using WebSocket
- `Presence / Typing Service`
- `Media Service`
- `Notification Service`
- `Moderation Service`
- `PostgreSQL`
- `Redis` for ephemeral state
- `S3-compatible object storage`
- `APNs` for notifications

### Why Not Pure Firebase / Supabase

- Email-only and phone-optional identity is central to the product
- Delete-for-everyone, granular privacy, presence, live location, group roles, and secret-chat roadmap need tighter control
- Future calls and encryption evolution benefit from owning the realtime protocol

A hybrid option is reasonable for MVP:

- Managed auth or storage selectively
- Custom realtime/chat core from day one

## 3. Online Transport Model

### Transport Layers

- REST for profile, settings, history pagination, search, uploads, reports
- WebSocket for realtime messages, edits, deletes, typing, read state, presence, live location updates
- APNs for offline wakeups and notification previews

### Message Send Flow

1. Client creates local pending message with client-generated UUID
2. Message is inserted into local cache immediately
3. Outbound event is sent over WebSocket
4. Server validates, stores, fans out, and returns authoritative ack
5. Local cache updates delivery state
6. Recipients receive event or APNs fallback

## 4. Offline Bluetooth Transport Model

### Goals

- Nearby-only local messaging
- Separate chat space from online
- Local discovery and local presence
- Best-effort local delivery

### Recommended Approach

- `CoreBluetooth` for advertising, scanning, peer identity exchange, and lightweight payload transport
- Session abstraction on top of peripheral/central roles
- App-level message envelope with chunking and ack
- Optional future migration to `MultipeerConnectivity` evaluation if product constraints change, but foundation keeps the transport abstracted

### Constraints

- Background discovery is limited on iOS
- Session reliability is weaker than internet transport
- Large media should be restricted or require active foreground sessions
- Delivery guarantees are best-effort
- Offline deletion-for-everyone cannot promise global revocation beyond peers that received the revoke event

## 5. Caching / Storage Strategy

### Local Persistence

- Use `SwiftData` or `SQLite-backed store` in production
- Cache chats, messages, drafts, profiles, notification settings, and pending queues
- Keep transport-independent domain models and persistence DTOs separate once backend integration begins

### Cache Rules

- Chat list loads from cache first, then refreshes
- Drafts persist locally by mode and chat
- Message edits and deletes reconcile using event versions
- Expiring content honors disappearing message policy

## 6. Push Notification Strategy

- APNs token registration during onboarding or permission grant
- Server-side push fanout for unread online messages and calls
- Per-chat mute and preview settings resolved server-side and client-side
- Badge count derived from unread counters

Offline Bluetooth chats do not use APNs to simulate nearby delivery.

## 7. Security / Encryption Strategy

### MVP Direction

- TLS in transit for online traffic
- Encrypted storage for sensitive local material where feasible
- Keychain for auth/session tokens and future identity keys
- Device-scoped encryption service abstraction now

### E2EE Roadmap

- Default chats can begin as transport-secure plus server-trusted for MVP
- Secret chats should be modeled now as device-to-device encrypted sessions
- Introduce identity keys, signed prekeys, and session keys later without rewriting message UI or repositories

## 8. Localization Strategy

- String keys only in UI
- Armenian-first copy review
- English parity in foundation
- Localizable date, time, status, and pluralization helpers
- Content direction remains LTR, but text system is locale-driven

## 9. Data Model Summary

Primary entities:

- User
- Profile
- IdentityMethod
- PrivacySettings
- Chat
- ChatMode
- Group
- GroupMemberRole
- Message
- MessageStatus
- Attachment
- VoiceMessage
- LiveLocationSession
- SecretChat
- DisappearingMessagePolicy
- NotificationPreferences
- OfflinePeer
- BluetoothSession
- Draft
- Presence
- BlockRecord
- ReportRecord
