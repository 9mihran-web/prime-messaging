#!/usr/bin/env python3
import base64
import json
import os
import threading
import uuid
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse


BASE_DIR = os.path.dirname(__file__)
DATA_DIR = os.path.join(BASE_DIR, "data")
DATA_FILE = os.path.join(DATA_DIR, "database.json")
AVATAR_DIR = os.path.join(DATA_DIR, "avatars")
MEDIA_DIR = os.path.join(DATA_DIR, "media")
HOST = os.environ.get("PRIME_MESSAGING_HOST", "0.0.0.0")
PORT = int(os.environ.get("PRIME_MESSAGING_PORT") or os.environ.get("PORT", "8080"))
RAILWAY_PUBLIC_DOMAIN = os.environ.get("RAILWAY_PUBLIC_DOMAIN", "").strip()
PUBLIC_BASE_URL = (
    os.environ.get("PRIME_MESSAGING_PUBLIC_BASE_URL", "").strip().rstrip("/")
    or (f"https://{RAILWAY_PUBLIC_DOMAIN}" if RAILWAY_PUBLIC_DOMAIN else "")
)
LOCK = threading.Lock()


def now_iso():
    return datetime.now(timezone.utc).isoformat()


def ensure_storage():
    os.makedirs(DATA_DIR, exist_ok=True)
    os.makedirs(AVATAR_DIR, exist_ok=True)
    os.makedirs(MEDIA_DIR, exist_ok=True)

    if not os.path.exists(DATA_FILE):
        seed = {
            "users": [],
            "chats": [],
            "messages": [],
        }
        with open(DATA_FILE, "w", encoding="utf-8") as file:
            json.dump(seed, file, indent=2)


def load_db():
    ensure_storage()
    with open(DATA_FILE, "r", encoding="utf-8") as file:
        return json.load(file)


def save_db(database):
    with open(DATA_FILE, "w", encoding="utf-8") as file:
        json.dump(database, file, indent=2, sort_keys=True)


def find_user(database, user_id):
    return next((user for user in database["users"] if user["id"] == user_id), None)


def serialize_user(user):
    return {
        "id": user["id"],
        "profile": user["profile"],
        "identityMethods": user["identityMethods"],
        "privacySettings": user["privacySettings"],
    }


def default_privacy_settings():
    return {
        "showEmail": True,
        "showPhoneNumber": False,
        "allowLastSeen": True,
        "allowProfilePhoto": True,
        "allowCallsFromNonContacts": False,
        "allowGroupInvitesFromNonContacts": False,
        "allowForwardLinkToProfile": False,
    }


def find_user_by_identifier(database, identifier):
    identifier = identifier.lower().lstrip("@")
    for user in database["users"]:
        profile = user["profile"]
        if profile["username"].lower() == identifier:
            return user
        if (profile.get("email") or "").lower() == identifier:
            return user
        if (profile.get("phoneNumber") or "").lower() == identifier:
            return user
    return None


def username_taken(database, username, excluding_user_id=None):
    username = username.lower()
    for user in database["users"]:
        if excluding_user_id and user["id"] == excluding_user_id:
            continue
        if user["profile"]["username"].lower() == username:
            return True
    return False


def ensure_saved_messages_chat(database, user_id, mode):
    existing = next(
        (
            chat for chat in database["chats"]
            if chat["type"] == "selfChat"
            and chat["mode"] == mode
            and chat["participantIDs"] == [user_id]
        ),
        None
    )

    if existing is not None:
        return existing

    chat = {
        "id": user_id,
        "mode": mode,
        "type": "selfChat",
        "participantIDs": [user_id],
        "createdAt": now_iso(),
    }
    database["chats"].append(chat)
    return chat


def normalized_optional_string(value):
    if value is None:
        return None
    cleaned = str(value).strip()
    return cleaned or None


def build_identity_methods(username, email=None, phone_number=None):
    methods = [
        {
            "id": str(uuid.uuid4()),
            "type": "username",
            "value": f"@{username}",
            "isVerified": True,
            "isPubliclyDiscoverable": True,
        }
    ]

    if email:
        methods.insert(
            0,
            {
                "id": str(uuid.uuid4()),
                "type": "email",
                "value": email,
                "isVerified": True,
                "isPubliclyDiscoverable": True,
            },
        )

    if phone_number:
        methods.insert(
            0,
            {
                "id": str(uuid.uuid4()),
                "type": "phone",
                "value": phone_number,
                "isVerified": True,
                "isPubliclyDiscoverable": True,
            },
        )

    return methods


def remove_file_for_url(file_url, directory):
    if not file_url:
        return

    basename = os.path.basename(urlparse(file_url).path)
    if not basename:
        return

    target_path = os.path.join(directory, basename)
    if os.path.exists(target_path):
        os.remove(target_path)


def save_base64_blob(directory, file_name, encoded_data):
    raw = base64.b64decode(encoded_data or "")
    stem, ext = os.path.splitext(file_name or "")
    if not ext:
        ext = ".bin"
    safe_stem = "".join(ch for ch in (stem or "upload") if ch.isalnum() or ch in ("-", "_")) or "upload"
    safe_name = f"{safe_stem}-{uuid.uuid4().hex}{ext}"
    output_path = os.path.join(directory, safe_name)
    with open(output_path, "wb") as file:
        file.write(raw)
    return safe_name, len(raw)


def message_preview(message):
    if message.get("deletedForEveryoneAt"):
        return "Message deleted"

    if message.get("text"):
        return message["text"]

    if message.get("voiceMessage"):
        return "Voice message"

    attachments = message.get("attachments") or []
    if not attachments:
        return None

    first_type = attachments[0].get("type")
    previews = {
        "photo": "Photo",
        "audio": "Audio",
        "video": "Video",
        "document": "Document",
        "contact": "Contact",
        "location": "Location",
    }
    return previews.get(first_type, "Attachment")


def sender_display_name_for(message, database):
    stored_name = (message.get("senderDisplayName") or "").strip()
    if stored_name:
        return stored_name

    sender = find_user(database, message.get("senderID"))
    if not sender:
        return "Unknown user"

    display_name = (sender["profile"].get("displayName") or "").strip()
    return display_name or sender["profile"]["username"]


def generic_direct_title(value):
    trimmed = (value or "").strip().lower()
    return trimmed in ("", "chat", "direct chat")


def generic_direct_subtitle(value):
    trimmed = (value or "").strip().lower()
    return trimmed in ("", "direct conversation")


def direct_chat_other_user(chat, current_user_id, database):
    participant_ids = chat.get("participantIDs") or []

    for user_id in participant_ids:
        if user_id == current_user_id:
            continue
        user = find_user(database, user_id)
        if user:
            return user

    messages = [message for message in database["messages"] if message["chatID"] == chat["id"]]
    messages.sort(key=lambda item: item["createdAt"], reverse=True)

    for message in messages:
        sender_id = message.get("senderID")
        if not sender_id or sender_id == current_user_id:
            continue
        user = find_user(database, sender_id)
        if user:
            return user

    cached_subtitle = (chat.get("cachedSubtitle") or "").strip()
    if cached_subtitle.startswith("@"):
        user = find_user_by_identifier(database, cached_subtitle)
        if user and user["id"] != current_user_id:
            return user

    return None


def chat_title_for(chat, current_user_id, database):
    if chat["type"] == "selfChat":
        return "Saved Messages"

    if chat["type"] == "group":
        return (chat.get("group") or {}).get("title") or chat.get("cachedTitle", "Group Chat")

    other_user = direct_chat_other_user(chat, current_user_id, database)
    if other_user:
        display_name = (other_user["profile"].get("displayName") or "").strip()
        if display_name:
            return display_name
        return other_user["profile"]["username"]

    cached_title = chat.get("cachedTitle", "Direct Chat")
    if generic_direct_title(cached_title):
        cached_subtitle = chat.get("cachedSubtitle", "Direct conversation")
        if cached_subtitle.startswith("@"):
            return cached_subtitle.removeprefix("@")
        return "Chat"

    return cached_title


def chat_subtitle_for(chat, current_user_id, database):
    if chat["type"] == "group":
        group = chat.get("group") or {}
        members = group.get("members") or []
        count = max(len(members), 1)
        return f"{count} members"

    other_user = direct_chat_other_user(chat, current_user_id, database)
    if not other_user:
        cached_subtitle = chat.get("cachedSubtitle", "Direct conversation")
        return "Direct conversation" if generic_direct_subtitle(cached_subtitle) else cached_subtitle

    return f"@{other_user['profile']['username']}"


def serialize_chat(chat, current_user_id, database):
    messages = [message for message in database["messages"] if message["chatID"] == chat["id"]]
    messages.sort(key=lambda item: item["createdAt"])
    last_message = messages[-1] if messages else None

    return {
        "id": chat["id"],
        "mode": chat["mode"],
        "type": chat["type"],
        "title": chat_title_for(chat, current_user_id, database),
        "subtitle": chat_subtitle_for(chat, current_user_id, database),
        "participantIDs": chat["participantIDs"],
        "group": chat.get("group"),
        "lastMessagePreview": message_preview(last_message) if last_message else None,
        "lastActivityAt": last_message["createdAt"] if last_message else chat["createdAt"],
        "unreadCount": 0,
        "isPinned": False,
        "draft": None,
        "disappearingPolicy": None,
        "notificationPreferences": {
            "muteState": "active",
            "previewEnabled": True,
            "customSoundName": None,
            "badgeEnabled": True,
        },
    }


def serialize_message(message, database):
    is_deleted = message.get("deletedForEveryoneAt") is not None
    return {
        "id": message["id"],
        "chatID": message["chatID"],
        "senderID": message["senderID"],
        "senderDisplayName": sender_display_name_for(message, database),
        "mode": message["mode"],
        "kind": message.get("kind", "text"),
        "text": None if is_deleted else message["text"],
        "attachments": [] if is_deleted else message.get("attachments", []),
        "replyToMessageID": None,
        "status": message.get("status", "sent"),
        "createdAt": message["createdAt"],
        "editedAt": message.get("editedAt"),
        "deletedForEveryoneAt": message.get("deletedForEveryoneAt"),
        "reactions": [],
        "voiceMessage": None if is_deleted else message.get("voiceMessage"),
        "liveLocation": None,
    }


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        parsed = urlparse(self.path)

        if parsed.path == "/health":
            return self.respond(200, {"status": "ok"})

        if parsed.path.startswith("/avatars/"):
            return self.serve_avatar(parsed.path.removeprefix("/avatars/"))

        if parsed.path.startswith("/media/"):
            return self.serve_media(parsed.path.removeprefix("/media/"))

        with LOCK:
            database = load_db()

            if parsed.path == "/usernames/check":
                params = parse_qs(parsed.query)
                username = (params.get("username") or [""])[0].strip().lower()
                user_id = (params.get("user_id") or [""])[0].strip() or None
                available = bool(username) and not username_taken(database, username, user_id)
                return self.respond(200, {"available": available})

            if parsed.path == "/users/search":
                params = parse_qs(parsed.query)
                query = (params.get("query") or [""])[0].strip().lower()
                exclude_user_id = (params.get("exclude_user_id") or [""])[0].strip()
                users = [
                    serialize_user(user)
                    for user in database["users"]
                    if user["id"] != exclude_user_id and (
                        query in user["profile"]["username"].lower() or
                        query in user["profile"]["displayName"].lower()
                    )
                ]
                return self.respond(200, users[:20])

            if parsed.path.startswith("/users/") and "/profile" not in parsed.path and "/avatar" not in parsed.path:
                user_id = parsed.path.split("/")[2]
                user = find_user(database, user_id)
                if not user:
                    return self.respond(404, {"error": "user_not_found"})
                return self.respond(200, serialize_user(user))

            if parsed.path == "/chats":
                params = parse_qs(parsed.query)
                user_id = (params.get("user_id") or [""])[0].strip()
                mode = (params.get("mode") or ["online"])[0].strip()
                ensure_saved_messages_chat(database, user_id, mode)
                chats = [
                    serialize_chat(chat, user_id, database)
                    for chat in database["chats"]
                    if user_id in chat["participantIDs"] and chat["mode"] == mode
                ]
                chats.sort(key=lambda item: item["lastActivityAt"], reverse=True)
                return self.respond(200, chats)

            if parsed.path == "/messages":
                params = parse_qs(parsed.query)
                chat_id = (params.get("chat_id") or [""])[0].strip()
                messages = [serialize_message(item, database) for item in database["messages"] if item["chatID"] == chat_id]
                messages.sort(key=lambda item: item["createdAt"])
                return self.respond(200, messages)

        return self.respond(404, {"error": "not_found"})

    def do_POST(self):
        return self.handle_mutation("POST")

    def do_PATCH(self):
        return self.handle_mutation("PATCH")

    def do_DELETE(self):
        return self.handle_mutation("DELETE")

    def handle_mutation(self, method):
        parsed = urlparse(self.path)
        payload = self.read_json()

        with LOCK:
            database = load_db()

            if method == "POST" and parsed.path == "/auth/signup":
                username = str(payload.get("username", "")).strip().lower()
                if username_taken(database, username):
                    return self.respond(409, {"error": "username_taken"})

                user_id = str(uuid.uuid4())
                method_type = payload.get("method_type", "email")
                contact_value = normalized_optional_string(payload.get("contact_value"))
                email = contact_value if method_type == "email" else None
                phone_number = contact_value if method_type == "phone" else None
                user = {
                    "id": user_id,
                    "password": payload.get("password", ""),
                    "profile": {
                        "displayName": payload.get("display_name", ""),
                        "username": username,
                        "bio": "Welcome to Prime Messaging.",
                        "status": "Available",
                        "email": email,
                        "phoneNumber": phone_number,
                        "profilePhotoURL": None,
                        "socialLink": None,
                    },
                    "identityMethods": build_identity_methods(username, email=email, phone_number=phone_number),
                    "privacySettings": default_privacy_settings(),
                }
                database["users"].append(user)
                ensure_saved_messages_chat(database, user_id, "online")
                ensure_saved_messages_chat(database, user_id, "offline")
                save_db(database)
                return self.respond(200, serialize_user(user))

            if method == "POST" and parsed.path == "/auth/login":
                identifier = str(payload.get("identifier", "")).strip().lower()
                password = str(payload.get("password", ""))
                user = find_user_by_identifier(database, identifier)
                if not user:
                    return self.respond(404, {"error": "user_not_found"})
                if user.get("password") != password:
                    return self.respond(401, {"error": "invalid_credentials"})
                return self.respond(200, serialize_user(user))

            if method == "POST" and parsed.path == "/usernames/claim":
                username = str(payload.get("username", "")).strip().lower()
                user_id = str(payload.get("user_id", "")).strip()
                user = find_user(database, user_id)
                if not user:
                    return self.respond(404, {"error": "user_not_found"})
                if username_taken(database, username, user_id):
                    return self.respond(409, {"error": "username_taken"})

                user["profile"]["username"] = username
                email = user["profile"].get("email")
                phone_number = user["profile"].get("phoneNumber")
                user["identityMethods"] = build_identity_methods(username, email=email, phone_number=phone_number)
                save_db(database)
                return self.respond(200, {"ok": True})

            if method == "PATCH" and parsed.path.endswith("/profile"):
                user_id = parsed.path.split("/")[2]
                user = find_user(database, user_id)
                if not user:
                    return self.respond(404, {"error": "user_not_found"})

                username = str(payload.get("username", user["profile"]["username"])).strip().lower()
                if username_taken(database, username, user_id):
                    return self.respond(409, {"error": "username_taken"})

                email = normalized_optional_string(payload.get("email"))
                phone_number = normalized_optional_string(payload.get("phone_number"))
                user["profile"] = {
                    "displayName": payload.get("display_name", user["profile"]["displayName"]),
                    "username": username,
                    "bio": payload.get("bio", user["profile"]["bio"]),
                    "status": payload.get("status", user["profile"]["status"]),
                    "email": email,
                    "phoneNumber": phone_number,
                    "profilePhotoURL": payload.get("profile_photo_url", user["profile"].get("profilePhotoURL")),
                    "socialLink": payload.get("social_link"),
                }
                user["identityMethods"] = build_identity_methods(username, email=email, phone_number=phone_number)
                save_db(database)
                return self.respond(200, serialize_user(user))

            if method == "PATCH" and parsed.path.endswith("/password"):
                user_id = parsed.path.split("/")[2]
                user = find_user(database, user_id)
                if not user:
                    return self.respond(404, {"error": "user_not_found"})

                user["password"] = str(payload.get("password", "")).strip()
                save_db(database)
                return self.respond(200, {"ok": True})

            if method == "POST" and parsed.path.endswith("/avatar"):
                user_id = parsed.path.split("/")[2]
                user = find_user(database, user_id)
                if not user:
                    return self.respond(404, {"error": "user_not_found"})

                remove_file_for_url(user["profile"].get("profilePhotoURL"), AVATAR_DIR)
                raw = base64.b64decode(payload.get("image_base64", ""))
                avatar_name = f"{user_id}.png"
                avatar_path = os.path.join(AVATAR_DIR, avatar_name)
                with open(avatar_path, "wb") as file:
                    file.write(raw)

                user["profile"]["profilePhotoURL"] = f"{self.base_url()}/avatars/{avatar_name}"
                save_db(database)
                return self.respond(200, serialize_user(user))

            if method == "DELETE" and parsed.path.endswith("/avatar"):
                user_id = parsed.path.split("/")[2]
                user = find_user(database, user_id)
                if not user:
                    return self.respond(404, {"error": "user_not_found"})

                remove_file_for_url(user["profile"].get("profilePhotoURL"), AVATAR_DIR)
                user["profile"]["profilePhotoURL"] = None
                save_db(database)
                return self.respond(200, serialize_user(user))

            if method == "POST" and parsed.path == "/chats/direct":
                current_user_id = str(payload.get("current_user_id", "")).strip()
                other_user_id = str(payload.get("other_user_id", "")).strip()
                mode = str(payload.get("mode", "online")).strip()
                other_user = find_user(database, other_user_id)
                cached_title = other_user["profile"]["displayName"] if other_user else "Direct Chat"
                cached_subtitle = f"@{other_user['profile']['username']}" if other_user else "Direct conversation"

                existing = next(
                    (
                        chat for chat in database["chats"]
                        if chat["type"] == "direct"
                        and set(chat["participantIDs"]) == {current_user_id, other_user_id}
                        and chat["mode"] == mode
                    ),
                    None
                )

                if existing is None:
                    existing = {
                        "id": str(uuid.uuid4()),
                        "mode": mode,
                        "type": "direct",
                        "participantIDs": [current_user_id, other_user_id],
                        "cachedTitle": cached_title,
                        "cachedSubtitle": cached_subtitle,
                        "createdAt": now_iso(),
                    }
                    database["chats"].append(existing)
                else:
                    existing["cachedTitle"] = cached_title
                    existing["cachedSubtitle"] = cached_subtitle

                save_db(database)

                return self.respond(200, serialize_chat(existing, current_user_id, database))

            if method == "POST" and parsed.path == "/chats/group":
                owner_id = str(payload.get("owner_id", "")).strip()
                title = str(payload.get("title", "")).strip() or "New Group"
                member_ids = [member_id for member_id in payload.get("member_ids", []) if str(member_id).strip()]
                mode = str(payload.get("mode", "online")).strip()
                participant_ids = [owner_id] + [member_id for member_id in member_ids if member_id != owner_id]
                group_id = str(uuid.uuid4())
                group = {
                    "id": group_id,
                    "title": title,
                    "photoURL": None,
                    "ownerID": owner_id,
                    "members": [
                        {
                            "id": str(uuid.uuid4()),
                            "userID": member_id,
                            "role": "owner" if member_id == owner_id else "member",
                            "joinedAt": now_iso(),
                        }
                        for member_id in participant_ids
                    ],
                }
                chat = {
                    "id": group_id,
                    "mode": mode,
                    "type": "group",
                    "participantIDs": participant_ids,
                    "group": group,
                    "cachedTitle": title,
                    "cachedSubtitle": f"{len(participant_ids)} members",
                    "createdAt": now_iso(),
                }
                database["chats"].append(chat)
                save_db(database)
                return self.respond(200, serialize_chat(chat, owner_id, database))

            if method == "POST" and parsed.path == "/messages/send":
                chat_id = str(payload.get("chat_id", "")).strip()
                sender_id = str(payload.get("sender_id", "")).strip()
                sender_display_name = normalized_optional_string(payload.get("sender_display_name"))
                text = normalized_optional_string(payload.get("text"))
                mode = str(payload.get("mode", "online")).strip()
                kind = str(payload.get("kind", "text")).strip() or "text"
                attachments = []
                for attachment in payload.get("attachments", []):
                    file_name = attachment.get("file_name") or "attachment.bin"
                    remote_url = None
                    byte_size = int(attachment.get("byte_size") or 0)
                    if attachment.get("data_base64"):
                        media_name, detected_size = save_base64_blob(MEDIA_DIR, file_name, attachment.get("data_base64"))
                        remote_url = f"{self.base_url()}/media/{media_name}"
                        byte_size = detected_size

                    attachments.append(
                        {
                            "id": str(uuid.uuid4()),
                            "type": attachment.get("type", "document"),
                            "fileName": file_name,
                            "mimeType": attachment.get("mime_type", "application/octet-stream"),
                            "localURL": None,
                            "remoteURL": remote_url,
                            "byteSize": byte_size,
                        }
                    )

                voice_payload = payload.get("voice_message")
                voice_message = None
                if voice_payload:
                    remote_url = None
                    if voice_payload.get("data_base64"):
                        media_name, _ = save_base64_blob(
                            MEDIA_DIR,
                            voice_payload.get("file_name") or "voice.m4a",
                            voice_payload.get("data_base64"),
                        )
                        remote_url = f"{self.base_url()}/media/{media_name}"

                    voice_message = {
                        "durationSeconds": int(voice_payload.get("duration_seconds") or 0),
                        "waveformSamples": voice_payload.get("waveform_samples") or [],
                        "localFileURL": None,
                        "remoteFileURL": remote_url,
                    }

                message = {
                    "id": str(uuid.uuid4()),
                    "chatID": chat_id,
                    "senderID": sender_id,
                    "senderDisplayName": sender_display_name,
                    "mode": mode,
                    "kind": kind,
                    "text": text,
                    "attachments": attachments,
                    "voiceMessage": voice_message,
                    "status": "sent",
                    "createdAt": now_iso(),
                    "editedAt": None,
                    "deletedForEveryoneAt": None,
                }
                database["messages"].append(message)
                save_db(database)
                return self.respond(200, serialize_message(message, database))

            if method == "PATCH" and parsed.path.startswith("/messages/"):
                message_id = parsed.path.split("/")[2]
                chat_id = str(payload.get("chat_id", "")).strip()
                editor_id = str(payload.get("editor_id", "")).strip()
                updated_text = normalized_optional_string(payload.get("text"))

                message = next(
                    (
                        item for item in database["messages"]
                        if item["id"] == message_id and item["chatID"] == chat_id
                    ),
                    None
                )
                if not message:
                    return self.respond(404, {"error": "message_not_found"})
                if message["senderID"] != editor_id:
                    return self.respond(403, {"error": "edit_not_allowed"})
                if message.get("deletedForEveryoneAt"):
                    return self.respond(409, {"error": "message_deleted"})
                if message.get("attachments") or message.get("voiceMessage"):
                    return self.respond(409, {"error": "edit_not_supported"})
                if not updated_text:
                    return self.respond(409, {"error": "empty_message"})

                message["text"] = updated_text
                message["editedAt"] = now_iso()
                save_db(database)
                return self.respond(200, serialize_message(message, database))

            if method == "DELETE" and parsed.path.startswith("/messages/"):
                message_id = parsed.path.split("/")[2]
                chat_id = str(payload.get("chat_id", "")).strip()
                requester_id = str(payload.get("requester_id", "")).strip()

                message = next(
                    (
                        item for item in database["messages"]
                        if item["id"] == message_id and item["chatID"] == chat_id
                    ),
                    None
                )
                if not message:
                    return self.respond(404, {"error": "message_not_found"})
                if message["senderID"] != requester_id:
                    return self.respond(403, {"error": "delete_not_allowed"})

                message["text"] = None
                message["attachments"] = []
                message["voiceMessage"] = None
                message["deletedForEveryoneAt"] = now_iso()
                save_db(database)
                return self.respond(200, serialize_message(message, database))

        return self.respond(404, {"error": "not_found"})

    def serve_avatar(self, avatar_name):
        avatar_path = os.path.join(AVATAR_DIR, os.path.basename(avatar_name))
        if not os.path.exists(avatar_path):
            return self.respond(404, {"error": "avatar_not_found"})

        with open(avatar_path, "rb") as file:
            body = file.read()

        self.send_response(200)
        self.send_header("Content-Type", "image/png")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def serve_media(self, media_name):
        media_path = os.path.join(MEDIA_DIR, os.path.basename(media_name))
        if not os.path.exists(media_path):
            return self.respond(404, {"error": "media_not_found"})

        with open(media_path, "rb") as file:
            body = file.read()

        self.send_response(200)
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def read_json(self):
        content_length = int(self.headers.get("Content-Length", "0"))
        raw = self.rfile.read(content_length) if content_length > 0 else b"{}"
        try:
            return json.loads(raw.decode("utf-8"))
        except json.JSONDecodeError:
            return {}

    def respond(self, status, payload):
        body = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def base_url(self):
        if PUBLIC_BASE_URL:
            return PUBLIC_BASE_URL
        host = self.headers.get("Host", "127.0.0.1:8080")
        return f"http://{host}"

    def log_message(self, format, *args):
        return


if __name__ == "__main__":
    ensure_storage()
    server = ThreadingHTTPServer((HOST, PORT), Handler)
    print(f"Prime Messaging backend listening on http://{HOST}:{PORT}")
    server.serve_forever()
