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
    identifier = identifier.lower()
    for user in database["users"]:
        profile = user["profile"]
        if profile["username"].lower() == identifier:
            return user
        if profile.get("email", "").lower() == identifier:
            return user
        if profile.get("phoneNumber", "").lower() == identifier:
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


def chat_title_for(chat, current_user_id, database):
    if chat["type"] == "selfChat":
        return "Saved Messages"

    other_ids = [user_id for user_id in chat["participantIDs"] if user_id != current_user_id]
    if not other_ids:
        return "Direct Chat"

    other_user = find_user(database, other_ids[0])
    if not other_user:
        return "Direct Chat"

    return other_user["profile"]["displayName"]


def chat_subtitle_for(chat, current_user_id, database):
    other_ids = [user_id for user_id in chat["participantIDs"] if user_id != current_user_id]
    if not other_ids:
        return "Notes and drafts"

    other_user = find_user(database, other_ids[0])
    if not other_user:
        return "Direct conversation"

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
        "group": None,
        "lastMessagePreview": last_message["text"] if last_message else None,
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


def serialize_message(message):
    return {
        "id": message["id"],
        "chatID": message["chatID"],
        "senderID": message["senderID"],
        "mode": message["mode"],
        "kind": "text",
        "text": message["text"],
        "attachments": [],
        "replyToMessageID": None,
        "status": "sent",
        "createdAt": message["createdAt"],
        "editedAt": None,
        "deletedForEveryoneAt": None,
        "reactions": [],
        "voiceMessage": None,
        "liveLocation": None,
    }


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        parsed = urlparse(self.path)

        if parsed.path == "/health":
            return self.respond(200, {"status": "ok"})

        if parsed.path.startswith("/avatars/"):
            return self.serve_avatar(parsed.path.removeprefix("/avatars/"))

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
                messages = [serialize_message(item) for item in database["messages"] if item["chatID"] == chat_id]
                messages.sort(key=lambda item: item["createdAt"])
                return self.respond(200, messages)

        return self.respond(404, {"error": "not_found"})

    def do_POST(self):
        parsed = urlparse(self.path)
        payload = self.read_json()

        with LOCK:
            database = load_db()

            if parsed.path == "/auth/signup":
                username = str(payload.get("username", "")).strip().lower()
                if username_taken(database, username):
                    return self.respond(409, {"error": "username_taken"})

                user_id = str(uuid.uuid4())
                method_type = payload.get("method_type", "email")
                contact_value = payload.get("contact_value")
                user = {
                    "id": user_id,
                    "password": payload.get("password", ""),
                    "profile": {
                        "displayName": payload.get("display_name", ""),
                        "username": username,
                        "bio": "Welcome to Prime Messaging.",
                        "status": "Available",
                        "email": contact_value if method_type == "email" else None,
                        "phoneNumber": contact_value if method_type == "phone" else None,
                        "profilePhotoURL": None,
                        "socialLink": None,
                    },
                    "identityMethods": [
                        {
                            "id": str(uuid.uuid4()),
                            "type": method_type,
                            "value": contact_value,
                            "isVerified": True,
                            "isPubliclyDiscoverable": True,
                        },
                        {
                            "id": str(uuid.uuid4()),
                            "type": "username",
                            "value": f"@{username}",
                            "isVerified": True,
                            "isPubliclyDiscoverable": True,
                        },
                    ],
                    "privacySettings": default_privacy_settings(),
                }
                database["users"].append(user)
                ensure_saved_messages_chat(database, user_id, "online")
                ensure_saved_messages_chat(database, user_id, "offline")
                save_db(database)
                return self.respond(200, serialize_user(user))

            if parsed.path == "/auth/login":
                identifier = str(payload.get("identifier", "")).strip().lower()
                password = str(payload.get("password", ""))
                user = find_user_by_identifier(database, identifier)
                if not user or user.get("password") != password:
                    return self.respond(401, {"error": "invalid_credentials"})
                return self.respond(200, serialize_user(user))

            if parsed.path == "/usernames/claim":
                username = str(payload.get("username", "")).strip().lower()
                user_id = str(payload.get("user_id", "")).strip()
                user = find_user(database, user_id)
                if not user:
                    return self.respond(404, {"error": "user_not_found"})
                if username_taken(database, username, user_id):
                    return self.respond(409, {"error": "username_taken"})

                user["profile"]["username"] = username
                for method in user["identityMethods"]:
                    if method["type"] == "username":
                        method["value"] = f"@{username}"
                save_db(database)
                return self.respond(200, {"ok": True})

            if parsed.path.endswith("/profile"):
                user_id = parsed.path.split("/")[2]
                user = find_user(database, user_id)
                if not user:
                    return self.respond(404, {"error": "user_not_found"})

                username = str(payload.get("username", user["profile"]["username"])).strip().lower()
                if username_taken(database, username, user_id):
                    return self.respond(409, {"error": "username_taken"})

                user["profile"] = {
                    "displayName": payload.get("display_name", user["profile"]["displayName"]),
                    "username": username,
                    "bio": payload.get("bio", user["profile"]["bio"]),
                    "status": payload.get("status", user["profile"]["status"]),
                    "email": payload.get("email"),
                    "phoneNumber": payload.get("phone_number"),
                    "profilePhotoURL": payload.get("profile_photo_url", user["profile"].get("profilePhotoURL")),
                    "socialLink": payload.get("social_link"),
                }
                for method in user["identityMethods"]:
                    if method["type"] == "username":
                        method["value"] = f"@{username}"
                save_db(database)
                return self.respond(200, serialize_user(user))

            if parsed.path.endswith("/avatar"):
                user_id = parsed.path.split("/")[2]
                user = find_user(database, user_id)
                if not user:
                    return self.respond(404, {"error": "user_not_found"})

                raw = base64.b64decode(payload.get("image_base64", ""))
                avatar_name = f"{user_id}.png"
                avatar_path = os.path.join(AVATAR_DIR, avatar_name)
                with open(avatar_path, "wb") as file:
                    file.write(raw)

                user["profile"]["profilePhotoURL"] = f"{self.base_url()}/avatars/{avatar_name}"
                save_db(database)
                return self.respond(200, serialize_user(user))

            if parsed.path == "/chats/direct":
                current_user_id = str(payload.get("current_user_id", "")).strip()
                other_user_id = str(payload.get("other_user_id", "")).strip()
                mode = str(payload.get("mode", "online")).strip()

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
                        "createdAt": now_iso(),
                    }
                    database["chats"].append(existing)
                    save_db(database)

                return self.respond(200, serialize_chat(existing, current_user_id, database))

            if parsed.path == "/messages/send":
                chat_id = str(payload.get("chat_id", "")).strip()
                sender_id = str(payload.get("sender_id", "")).strip()
                text = str(payload.get("text", "")).strip()
                mode = str(payload.get("mode", "online")).strip()

                message = {
                    "id": str(uuid.uuid4()),
                    "chatID": chat_id,
                    "senderID": sender_id,
                    "mode": mode,
                    "text": text,
                    "createdAt": now_iso(),
                }
                database["messages"].append(message)
                save_db(database)
                return self.respond(200, serialize_message(message))

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
