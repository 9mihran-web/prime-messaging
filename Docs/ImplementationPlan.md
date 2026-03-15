# Prime Messaging Implementation Plan

## 1. Best Order To Build

1. Design system and app shell
2. Core models and repository protocols
3. Mock-driven Online / Offline mode UX
4. Local cache and drafts
5. Auth and profile flow
6. Online messaging backend integration
7. Notifications and presence
8. Attachments and voice messages
9. Offline Bluetooth transport implementation
10. Disappearing messages, secret chats, and moderation hardening

## 2. What To Mock First

- Auth sessions
- Chat list
- Chat history
- Presence
- Notifications
- Nearby peers
- Draft persistence

This allows UX and interaction design to stabilize before backend complexity begins.

## 3. What To Abstract From Day One

- Chat repository
- Auth repository
- Presence service
- Push notification service
- Local storage
- Online transport
- Offline Bluetooth transport
- Encryption provider

## 4. What To Defer

- Full cryptographic session management
- VoIP/audio calling implementation
- Video calling
- Public groups / channels
- Advanced moderation console
- Invite links and deep group permission surface

## 5. Milestone View

### Milestone A

- App shell
- Mode selector
- Chat list
- Chat screen
- Settings
- Local mocks

### Milestone B

- Real auth
- Profile
- Local persistence
- Search
- Drafts
- Self-chat

### Milestone C

- Realtime backend
- Delivery/read state
- Presence
- Push notifications

### Milestone D

- Media and voice messages
- Live location
- Group roles
- Block/report

### Milestone E

- Bluetooth transport
- Offline peer discovery
- Local session reliability
- Offline-specific UX hardening

### Milestone F

- Secret chats
- Disappearing message enforcement
- Audio call groundwork
