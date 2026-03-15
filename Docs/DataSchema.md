# Prime Messaging Data Schema

## User

```swift
struct User {
    let id: UUID
    var profile: Profile
    var identityMethods: [IdentityMethod]
    var privacySettings: PrivacySettings
}
```

Purpose:

- Canonical app user record
- Keeps identity and privacy policy attached to a user

## Profile

```swift
struct Profile {
    var displayName: String
    var username: String
    var bio: String
    var status: String
    var email: String?
    var phoneNumber: String?
    var profilePhotoURL: URL?
    var socialLink: URL?
}
```

## IdentityMethod

```swift
struct IdentityMethod {
    let id: UUID
    let type: IdentityMethodType
    let value: String
    let isVerified: Bool
    let isPubliclyDiscoverable: Bool
}
```

Supports:

- Email
- Phone
- Username
- QR-based share target

## PrivacySettings

Controls:

- Email visibility
- Phone visibility
- Last seen visibility
- Profile photo visibility
- Call access
- Group invite access
- Forwarded profile attribution

## Chat

```swift
struct Chat {
    let id: UUID
    var mode: ChatMode
    var type: ChatType
    var title: String
    var subtitle: String
    var participantIDs: [UUID]
    var group: Group?
    var lastMessagePreview: String?
    var lastActivityAt: Date
    var unreadCount: Int
    var isPinned: Bool
    var draft: Draft?
    var disappearingPolicy: DisappearingMessagePolicy?
    var notificationPreferences: NotificationPreferences
}
```

Important rule:

- The same person can have one `online` chat and one `offline` chat and they are intentionally different chats.

## ChatMode

- `online`
- `offline`

## Group

```swift
struct Group {
    let id: UUID
    var title: String
    var photoURL: URL?
    var ownerID: UUID
    var members: [GroupMember]
}
```

## GroupMemberRole

- `owner`
- `admin`
- `member`

## Message

```swift
struct Message {
    let id: UUID
    let chatID: UUID
    let senderID: UUID
    var mode: ChatMode
    var kind: MessageKind
    var text: String?
    var attachments: [Attachment]
    var replyToMessageID: UUID?
    var status: MessageStatus
    var createdAt: Date
    var editedAt: Date?
    var deletedForEveryoneAt: Date?
    var reactions: [MessageReaction]
    var voiceMessage: VoiceMessage?
    var liveLocation: LiveLocationSession?
}
```

## MessageStatus

- `localPending`
- `sending`
- `sent`
- `delivered`
- `read`
- `failed`

Offline Mode may map these differently because delivery guarantees are best-effort.

## Attachment

Supports:

- Photo
- Video
- Document
- Audio
- Contact
- Location

## VoiceMessage

Contains:

- Duration
- Waveform samples
- Local file URL
- Remote file URL

## LiveLocationSession

Tracks:

- Sender
- Coordinates
- Accuracy
- Start and end time
- Active state

## SecretChat

Modeled now so the app can evolve to device-to-device encrypted sessions later without changing the rest of the message UI.

## DisappearingMessagePolicy

Tracks:

- Expiration duration
- Whether the timer starts on read

## NotificationPreferences

Tracks:

- Mute state
- Preview visibility
- Sound placeholder
- Badge behavior

## OfflinePeer

Represents a nearby discoverable Bluetooth peer.

## BluetoothSession

Tracks:

- Peer linkage
- Session state
- Negotiated MTU
- Last activity

## Draft

Drafts are scoped by:

- Chat ID
- Chat mode
- Last updated time

## Presence

Tracks:

- Presence state
- Last seen
- Typing

Online presence and Offline local reachability are separate concepts.

## ReportRecord / BlockRecord

These provide moderation hooks for:

- User block
- Message report
- Chat report
- User report
