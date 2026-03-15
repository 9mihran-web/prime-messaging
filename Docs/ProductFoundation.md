# Prime Messaging Product Foundation

## 1. Product Assumptions And Clarified Requirements

### Product Restatement

Prime Messaging is a serious Armenian-first messaging app for iPhone with two first-class communication modes inside one product:

- `Online Mode`: internet-based messaging, delivery state, presence, push, media, and future calling
- `Offline Mode`: nearby Bluetooth-only messaging, scoped to local peer discovery and direct local sessions

The app should feel premium, fast, discreet, native to iOS, and strongly inspired by Telegram's clarity and efficiency without reusing Telegram branding or becoming a clone.

### Core Product Assumptions

- The first public release is iPhone-first and optimized for iPhone XS / XR and newer.
- Armenian is mandatory at launch; English ships in the foundation; Russian is prepared for later.
- Users can register with email only, phone only, or both.
- Phone number is optional everywhere in account identity.
- Online and Offline chats are separate threads by design even for the same person.
- Private 1:1 chats and private groups are in MVP; channels and public communities are not.
- Voice messages are MVP; audio calling is architecture-ready but may land after core messaging stability.
- Secret chats and disappearing messages should be modeled now even if the cryptographic protocol is deferred.

### MVP Scope

- Onboarding and authentication
- Profile and privacy settings
- Online chat list
- Offline chat list
- 1:1 online chats
- Private groups
- Self-chat
- Message send, reply, edit, react, delete, delete-for-everyone
- Drafts
- Delivered / read states
- Presence and last seen
- Search
- Voice messages
- Attachments: photo, video, document, audio, contact, location, live location
- Push notifications and badge counts
- Local caching
- Block / report
- Disappearing message policy
- Offline Bluetooth messaging architecture and UX foundation

### Phase 2 / Stretch

- Audio calling rollout
- Video calling
- Full E2EE for default chats or broader session-based encryption
- Secret chat transport and device key verification UX
- More resilient background Bluetooth heuristics
- Invite links and more advanced group management
- Archive, folders, channels, communities
- Admin dashboard and moderation console

## 2. Feature Breakdown

### Auth

- Email-only sign-up
- Phone sign-up
- Combined identity sign-up
- Verification placeholders for OTP / email code
- Session restore and sign-out

### Onboarding

- Brand-led welcome
- Language selection
- Identity method selection
- Profile completion
- Permission education for contacts, notifications, microphone, photos, location, Bluetooth

### Profile / Privacy

- Display name, username, bio, status, avatar
- Optional phone number
- Required visible email when it is the only identity
- Privacy matrix for last seen, profile photo, phone visibility, email visibility, forwards, calls, and groups

### Chat List

- Large mode switch between Online and Offline
- Pinned chats
- Search
- Draft previews
- Unread counters
- Delivery state indicators

### Chat

- Native message list
- Rich composer
- Replies
- Edits
- Delete for me / delete for everyone
- Reactions
- Typing state
- Pinned message banner

### Offline Mode UX

- Distinct mode banner and nearby-only framing
- Peer discovery and session status
- Local delivery state only
- No internet presence leakage
- Explicit messaging around platform limits and range

### Secret Chats / Disappearing Messages

- Policy model in MVP
- Secure chat route and UI placeholders
- Message expiration scheduling tied to local cache and backend retention policy

## 3. User Flows

### Signup With Phone

1. User selects phone sign-up
2. Enters number and receives OTP
3. Completes display name and optional email
4. Lands in home with Online selected by default

### Signup With Email Only

1. User selects email sign-up
2. Verifies email with code or magic link
3. Creates username and profile
4. Privacy screen explains that email remains discoverable when it is the only identity

### Finding Users

User can search by username, phone number, email-allowed identity, QR code, or matched contacts. Discovery is routed through a dedicated people search service, not mixed into chat history loading.

### Switching Between Online And Offline

From the main screen, the user taps a clear Online / Offline segmented control. The selected mode changes chat list source, compose entry points, discovery tools, and transport behavior.

### Starting An Offline Bluetooth Chat

1. User opens Offline Mode
2. Nearby scan starts after Bluetooth permission and local explanation
3. User picks a discovered peer
4. App creates a local-only chat session bound to a Bluetooth session identifier
5. Messages flow using nearby transport and remain inside Offline history only

### Sending And Receiving Messages

- Online uses optimistic local send, websocket ack, and APNs fallback
- Offline uses local queueing, peer session delivery, and session-based reachability updates

### Deleting For Everyone

For online mode, deletion is modeled as a synchronized revoke action with backend authority and local purge policy. For offline mode, deletion-for-everyone only applies within active or later-synced local session rules and must not overpromise impossible remote deletion outside session guarantees.

### Group Creation

1. Start new private group
2. Pick members
3. Name group and optional photo
4. Creator becomes owner
5. Group opens in Online Mode only for MVP

### Sending Live Location

User selects location attachment, chooses current location or live location duration, grants permission, and shares a live session that periodically updates through backend transport and local cache.

### Self-Chat

Self-chat is pinned by default on first launch after account creation and acts as a private notes/media transfer thread in Online Mode.
