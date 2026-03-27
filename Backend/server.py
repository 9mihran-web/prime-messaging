#!/usr/bin/env python3
import base64
import hashlib
import hmac
import json
import os
import threading
import uuid
from datetime import datetime, timedelta, timezone
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
ACCESS_TOKEN_TTL_SECONDS = 60 * 60
REFRESH_TOKEN_TTL_SECONDS = 60 * 60 * 24 * 30
SESSION_ACTIVITY_TOUCH_INTERVAL_SECONDS = 15
PRESENCE_ONLINE_WINDOW_SECONDS = 45
ADMIN_LOGIN = (os.environ.get("PRIME_MESSAGING_ADMIN_LOGIN", "admin") or "admin").strip().lower()
ADMIN_PASSWORD = os.environ.get("PRIME_MESSAGING_ADMIN_PASSWORD", "Prime-admin-very-secret-2026").strip()
ADMIN_TOKEN = os.environ.get("PRIME_MESSAGING_ADMIN_TOKEN", "").strip()
ADMIN_USERNAME = (os.environ.get("PRIME_MESSAGING_ADMIN_USERNAME", "mihran") or "mihran").strip().lower()


def log_event(name, **fields):
    payload = {
        "timestamp": now_iso(),
        "event": name,
        **fields,
    }
    print(json.dumps(payload, ensure_ascii=False), flush=True)


def now_iso():
    return datetime.now(timezone.utc).isoformat()


def expires_at_iso(seconds):
    return (datetime.now(timezone.utc) + timedelta(seconds=seconds)).isoformat()


def normalize_username(value):
    lowered = (value or "").strip().lower()
    if lowered.startswith("@"):
        lowered = lowered[1:]
    return "".join(
        character
        for character in lowered
        if character.isascii() and (character.isalnum() or character == "_")
    )[:32]


def ensure_storage():
    os.makedirs(DATA_DIR, exist_ok=True)
    os.makedirs(AVATAR_DIR, exist_ok=True)
    os.makedirs(MEDIA_DIR, exist_ok=True)

    if not os.path.exists(DATA_FILE):
        seed = {
            "users": [],
            "chats": [],
            "messages": [],
            "calls": [],
            "callEvents": [],
        }
        with open(DATA_FILE, "w", encoding="utf-8") as file:
            json.dump(seed, file, indent=2)


def load_db():
    ensure_storage()
    with open(DATA_FILE, "r", encoding="utf-8") as file:
        database = json.load(file)

    if ensure_database_schema(database):
        save_db(database)

    return database


def save_db(database):
    with open(DATA_FILE, "w", encoding="utf-8") as file:
        json.dump(database, file, indent=2, sort_keys=True)


def normalized_entity_id(value):
    if value is None:
        return None
    cleaned = str(value).strip()
    return cleaned.lower() if cleaned else None


def ids_equal(lhs, rhs):
    left_id = normalized_entity_id(lhs)
    right_id = normalized_entity_id(rhs)
    return left_id is not None and right_id is not None and left_id == right_id


def unique_entity_ids(values):
    normalized_values = []
    seen = set()
    for value in values or []:
        normalized_value = normalized_entity_id(value)
        if not normalized_value or normalized_value in seen:
            continue
        seen.add(normalized_value)
        normalized_values.append(normalized_value)
    return normalized_values


def ensure_database_schema(database):
    did_update = False

    for key in ("users", "chats", "messages", "sessions", "deviceTokens", "calls", "callEvents"):
        if key not in database:
            database[key] = []
            did_update = True

    if normalize_database_entities(database):
        did_update = True

    return did_update


def find_user(database, user_id):
    user_id = normalized_entity_id(user_id)
    if not user_id:
        return None
    return next((user for user in database["users"] if ids_equal(user.get("id"), user_id)), None)


def find_chat(database, chat_id):
    chat_id = normalized_entity_id(chat_id)
    if not chat_id:
        return None
    return next((chat for chat in database["chats"] if ids_equal(chat.get("id"), chat_id)), None)


def find_message(database, message_id):
    message_id = normalized_entity_id(message_id)
    if not message_id:
        return None
    return next((message for message in database["messages"] if ids_equal(message.get("id"), message_id)), None)


def prefer_first_timestamp(lhs, rhs):
    if not lhs:
        return rhs
    if not rhs:
        return lhs
    return min(lhs, rhs)


def message_status_rank(value):
    ranking = {"sent": 1, "delivered": 2, "read": 3}
    return ranking.get((value or "").strip().lower(), 0)


def user_merge_score(user):
    profile = user.get("profile") or {}
    username = (profile.get("username") or "").strip().lower()
    score = 0
    if not is_legacy_placeholder_user(user):
        score += 100
    if (user.get("password") or "").strip():
        score += 40
    if (profile.get("email") or "").strip():
        score += 20
    if (profile.get("phoneNumber") or "").strip():
        score += 20
    if (profile.get("displayName") or "").strip():
        score += 10
    if username and not username.startswith("legacy_"):
        score += 10
    if (profile.get("profilePhotoURL") or "").strip():
        score += 5
    return score


def merge_user_records(primary, secondary):
    did_update = False
    primary_profile = primary.setdefault("profile", {})
    secondary_profile = secondary.get("profile") or {}

    if not (primary.get("password") or "").strip() and (secondary.get("password") or "").strip():
        primary["password"] = secondary.get("password", "")
        did_update = True

    field_names = ("displayName", "bio", "status", "email", "phoneNumber", "profilePhotoURL", "socialLink")
    for field_name in field_names:
        if (primary_profile.get(field_name) or "").strip():
            continue
        secondary_value = secondary_profile.get(field_name)
        if secondary_value is None or not str(secondary_value).strip():
            continue
        primary_profile[field_name] = secondary_value
        did_update = True

    primary_username = (primary_profile.get("username") or "").strip().lower()
    secondary_username = (secondary_profile.get("username") or "").strip().lower()
    if secondary_username and (
        not primary_username
        or primary_username.startswith("legacy_")
        and not secondary_username.startswith("legacy_")
    ):
        primary_profile["username"] = secondary_username
        did_update = True

    identity_methods = primary.setdefault("identityMethods", [])
    seen_methods = {
        (
            (item.get("type") or "").strip().lower(),
            (item.get("value") or "").strip().lower(),
        )
        for item in identity_methods
    }
    for item in secondary.get("identityMethods") or []:
        signature = (
            (item.get("type") or "").strip().lower(),
            (item.get("value") or "").strip().lower(),
        )
        if signature in seen_methods:
            continue
        identity_methods.append(item)
        seen_methods.add(signature)
        did_update = True

    privacy_settings = primary.setdefault("privacySettings", {})
    for key, value in (secondary.get("privacySettings") or {}).items():
        if key in privacy_settings:
            continue
        privacy_settings[key] = value
        did_update = True

    return did_update


def chat_merge_score(chat):
    score = 0
    if chat.get("type") == "group":
        score += 20
    if chat.get("group"):
        score += 10
    score += len(unique_entity_ids(chat.get("participantIDs") or []))
    if (chat.get("cachedTitle") or "").strip():
        score += 3
    if (chat.get("cachedSubtitle") or "").strip():
        score += 2
    if chat.get("createdAt"):
        score += 1
    return score


def merge_group_records(primary_group, secondary_group):
    did_update = False
    if not secondary_group:
        return did_update

    if not primary_group:
        return True

    if not (primary_group.get("title") or "").strip() and (secondary_group.get("title") or "").strip():
        primary_group["title"] = secondary_group.get("title")
        did_update = True

    if not (primary_group.get("photoURL") or "").strip() and (secondary_group.get("photoURL") or "").strip():
        primary_group["photoURL"] = secondary_group.get("photoURL")
        did_update = True

    secondary_owner_id = normalized_entity_id(secondary_group.get("ownerID"))
    if not normalized_entity_id(primary_group.get("ownerID")) and secondary_owner_id:
        primary_group["ownerID"] = secondary_owner_id
        did_update = True

    seen_members = {
        normalized_entity_id(member.get("userID"))
        for member in primary_group.get("members") or []
        if normalized_entity_id(member.get("userID"))
    }
    for member in secondary_group.get("members") or []:
        member_user_id = normalized_entity_id(member.get("userID"))
        if not member_user_id or member_user_id in seen_members:
            continue
        member["userID"] = member_user_id
        (primary_group.setdefault("members", [])).append(member)
        seen_members.add(member_user_id)
        did_update = True

    return did_update


def merge_chat_records(primary, secondary):
    did_update = False
    if not (primary.get("mode") or "").strip() and (secondary.get("mode") or "").strip():
        primary["mode"] = secondary.get("mode")
        did_update = True

    if not (primary.get("type") or "").strip() and (secondary.get("type") or "").strip():
        primary["type"] = secondary.get("type")
        did_update = True

    merged_participants = unique_entity_ids((primary.get("participantIDs") or []) + (secondary.get("participantIDs") or []))
    if merged_participants != unique_entity_ids(primary.get("participantIDs") or []):
        primary["participantIDs"] = merged_participants
        did_update = True

    if (
        generic_direct_title(primary.get("cachedTitle"))
        and not generic_direct_title(secondary.get("cachedTitle"))
    ) or (not (primary.get("cachedTitle") or "").strip() and (secondary.get("cachedTitle") or "").strip()):
        primary["cachedTitle"] = secondary.get("cachedTitle")
        did_update = True

    if (
        generic_direct_subtitle(primary.get("cachedSubtitle"))
        and not generic_direct_subtitle(secondary.get("cachedSubtitle"))
    ) or (not (primary.get("cachedSubtitle") or "").strip() and (secondary.get("cachedSubtitle") or "").strip()):
        primary["cachedSubtitle"] = secondary.get("cachedSubtitle")
        did_update = True

    primary["createdAt"] = prefer_first_timestamp(primary.get("createdAt"), secondary.get("createdAt"))
    if merge_group_records(primary.get("group"), secondary.get("group")):
        if not primary.get("group") and secondary.get("group"):
            primary["group"] = secondary.get("group")
        did_update = True

    return did_update


def message_merge_score(message):
    score = 0
    if not message.get("deletedForEveryoneAt"):
        score += 10
    if message.get("text"):
        score += 5
    if message.get("attachments"):
        score += 4
    if message.get("voiceMessage"):
        score += 4
    score += message_status_rank(message.get("status"))
    if message.get("senderDisplayName"):
        score += 2
    return score


def merge_message_records(primary, secondary):
    did_update = False
    preferred_status = primary.get("status")
    if message_status_rank(secondary.get("status")) > message_status_rank(preferred_status):
        preferred_status = secondary.get("status")
    if preferred_status != primary.get("status"):
        primary["status"] = preferred_status
        did_update = True

    if not primary.get("text") and secondary.get("text"):
        primary["text"] = secondary.get("text")
        did_update = True

    if not primary.get("attachments") and secondary.get("attachments"):
        primary["attachments"] = secondary.get("attachments")
        did_update = True

    if not primary.get("voiceMessage") and secondary.get("voiceMessage"):
        primary["voiceMessage"] = secondary.get("voiceMessage")
        did_update = True

    if not primary.get("senderDisplayName") and secondary.get("senderDisplayName"):
        primary["senderDisplayName"] = secondary.get("senderDisplayName")
        did_update = True

    if not primary.get("editedAt") and secondary.get("editedAt"):
        primary["editedAt"] = secondary.get("editedAt")
        did_update = True

    if not primary.get("deletedForEveryoneAt") and secondary.get("deletedForEveryoneAt"):
        primary["deletedForEveryoneAt"] = secondary.get("deletedForEveryoneAt")
        did_update = True

    primary["createdAt"] = prefer_first_timestamp(primary.get("createdAt"), secondary.get("createdAt"))
    return did_update


def normalize_database_entities(database):
    did_update = False

    user_id_map = {}
    grouped_users = {}
    for user in database.get("users", []):
        original_user_id = normalized_optional_string(user.get("id"))
        canonical_user_id = normalized_entity_id(original_user_id) or str(uuid.uuid4())
        grouped_users.setdefault(canonical_user_id, []).append(user)
        if original_user_id:
            user_id_map[original_user_id] = canonical_user_id
        user_id_map[canonical_user_id] = canonical_user_id

    normalized_users = []
    for canonical_user_id, records in grouped_users.items():
        chosen = max(records, key=user_merge_score)
        for record in records:
            if record is chosen:
                continue
            if merge_user_records(chosen, record):
                did_update = True
        if chosen.get("id") != canonical_user_id:
            chosen["id"] = canonical_user_id
            did_update = True
        profile = chosen.setdefault("profile", {})
        username = normalized_optional_string(profile.get("username"))
        if username and profile.get("username") != username.lower():
            profile["username"] = username.lower()
            did_update = True
        normalized_users.append(chosen)
    database["users"] = normalized_users

    chat_id_map = {}
    normalized_chat_records = []
    for chat in database.get("chats", []):
        original_chat_id = normalized_optional_string(chat.get("id"))
        participant_ids = [
            user_id_map.get(normalized_optional_string(participant_id), normalized_entity_id(participant_id))
            for participant_id in chat.get("participantIDs") or []
        ]
        participant_ids = unique_entity_ids(participant_ids)
        if participant_ids != (chat.get("participantIDs") or []):
            chat["participantIDs"] = participant_ids
            did_update = True

        if chat.get("type") == "selfChat" and participant_ids:
            canonical_chat_id = participant_ids[0]
        else:
            canonical_chat_id = normalized_entity_id(original_chat_id) or str(uuid.uuid4())
        if original_chat_id:
            chat_id_map[original_chat_id] = canonical_chat_id
        chat_id_map[canonical_chat_id] = canonical_chat_id
        if chat.get("id") != canonical_chat_id:
            chat["id"] = canonical_chat_id
            did_update = True

        group = chat.get("group")
        if group:
            if group.get("id") != canonical_chat_id:
                group["id"] = canonical_chat_id
                did_update = True
            owner_id = user_id_map.get(normalized_optional_string(group.get("ownerID")), normalized_entity_id(group.get("ownerID")))
            if owner_id and group.get("ownerID") != owner_id:
                group["ownerID"] = owner_id
                did_update = True
            for member in group.get("members") or []:
                member_user_id = user_id_map.get(normalized_optional_string(member.get("userID")), normalized_entity_id(member.get("userID")))
                if member_user_id and member.get("userID") != member_user_id:
                    member["userID"] = member_user_id
                    did_update = True

        normalized_chat_records.append(chat)

    grouped_chats = {}
    for chat in normalized_chat_records:
        grouped_chats.setdefault(chat["id"], []).append(chat)

    normalized_chats = []
    for canonical_chat_id, records in grouped_chats.items():
        chosen = max(records, key=chat_merge_score)
        for record in records:
            if record is chosen:
                continue
            if merge_chat_records(chosen, record):
                did_update = True
        normalized_chats.append(chosen)
    database["chats"] = normalized_chats

    normalized_messages = []
    grouped_messages = {}
    for message in database.get("messages", []):
        original_message_id = normalized_optional_string(message.get("id"))
        canonical_message_id = normalized_entity_id(original_message_id) or str(uuid.uuid4())
        if message.get("id") != canonical_message_id:
            message["id"] = canonical_message_id
            did_update = True

        canonical_chat_id = chat_id_map.get(normalized_optional_string(message.get("chatID")), normalized_entity_id(message.get("chatID")))
        if canonical_chat_id and message.get("chatID") != canonical_chat_id:
            message["chatID"] = canonical_chat_id
            did_update = True

        canonical_sender_id = user_id_map.get(normalized_optional_string(message.get("senderID")), normalized_entity_id(message.get("senderID")))
        if canonical_sender_id and message.get("senderID") != canonical_sender_id:
            message["senderID"] = canonical_sender_id
            did_update = True

        grouped_messages.setdefault(canonical_message_id, []).append(message)
        normalized_messages.append(message)

    deduplicated_messages = []
    for canonical_message_id, records in grouped_messages.items():
        chosen = max(records, key=message_merge_score)
        for record in records:
            if record is chosen:
                continue
            if merge_message_records(chosen, record):
                did_update = True
        deduplicated_messages.append(chosen)
    database["messages"] = deduplicated_messages

    normalized_sessions = []
    for session in database.get("sessions", []):
        canonical_session_id = normalized_entity_id(session.get("id")) or str(uuid.uuid4())
        if session.get("id") != canonical_session_id:
            session["id"] = canonical_session_id
            did_update = True
        canonical_user_id = user_id_map.get(normalized_optional_string(session.get("userID")), normalized_entity_id(session.get("userID")))
        if canonical_user_id and session.get("userID") != canonical_user_id:
            session["userID"] = canonical_user_id
            did_update = True
        normalized_sessions.append(session)
    database["sessions"] = normalized_sessions

    normalized_device_tokens = []
    seen_tokens = set()
    for entry in database.get("deviceTokens", []):
        canonical_entry_id = normalized_entity_id(entry.get("id")) or str(uuid.uuid4())
        if entry.get("id") != canonical_entry_id:
            entry["id"] = canonical_entry_id
            did_update = True
        canonical_user_id = user_id_map.get(normalized_optional_string(entry.get("userID")), normalized_entity_id(entry.get("userID")))
        if canonical_user_id and entry.get("userID") != canonical_user_id:
            entry["userID"] = canonical_user_id
            did_update = True
        token_value = normalized_optional_string(entry.get("token"))
        if token_value and token_value in seen_tokens:
            did_update = True
            continue
        if token_value:
            seen_tokens.add(token_value)
        normalized_device_tokens.append(entry)
    database["deviceTokens"] = normalized_device_tokens

    call_id_map = {}
    normalized_calls = []
    grouped_calls = {}
    for call in database.get("calls", []):
        original_call_id = normalized_optional_string(call.get("id"))
        canonical_call_id = normalized_entity_id(original_call_id) or str(uuid.uuid4())
        if original_call_id:
            call_id_map[original_call_id] = canonical_call_id
        call_id_map[canonical_call_id] = canonical_call_id
        if call.get("id") != canonical_call_id:
            call["id"] = canonical_call_id
            did_update = True

        caller_id = user_id_map.get(normalized_optional_string(call.get("callerID")), normalized_entity_id(call.get("callerID")))
        if caller_id and call.get("callerID") != caller_id:
            call["callerID"] = caller_id
            did_update = True

        callee_id = user_id_map.get(normalized_optional_string(call.get("calleeID")), normalized_entity_id(call.get("calleeID")))
        if callee_id and call.get("calleeID") != callee_id:
            call["calleeID"] = callee_id
            did_update = True

        chat_id = chat_id_map.get(normalized_optional_string(call.get("chatID")), normalized_entity_id(call.get("chatID")))
        if chat_id and call.get("chatID") != chat_id:
            call["chatID"] = chat_id
            did_update = True

        ended_by_user_id = user_id_map.get(normalized_optional_string(call.get("endedByUserID")), normalized_entity_id(call.get("endedByUserID")))
        if ended_by_user_id and call.get("endedByUserID") != ended_by_user_id:
            call["endedByUserID"] = ended_by_user_id
            did_update = True

        if not normalized_optional_string(call.get("mode")):
            call["mode"] = "online"
            did_update = True

        if not normalized_optional_string(call.get("kind")):
            call["kind"] = "audio"
            did_update = True

        if not normalized_optional_string(call.get("state")):
            call["state"] = "ringing"
            did_update = True

        try:
            last_event_sequence = int(call.get("lastEventSequence") or 0)
        except (TypeError, ValueError):
            last_event_sequence = 0
        if call.get("lastEventSequence") != last_event_sequence:
            call["lastEventSequence"] = last_event_sequence
            did_update = True

        grouped_calls.setdefault(canonical_call_id, []).append(call)
        normalized_calls.append(call)

    deduplicated_calls = []
    for canonical_call_id, records in grouped_calls.items():
        chosen = max(
            records,
            key=lambda item: (
                parse_iso_datetime(item.get("updatedAt")) or datetime.min.replace(tzinfo=timezone.utc),
                parse_iso_datetime(item.get("answeredAt")) or datetime.min.replace(tzinfo=timezone.utc),
            ),
        )
        deduplicated_calls.append(chosen)
        if len(records) > 1:
            did_update = True
    database["calls"] = deduplicated_calls

    normalized_call_events = []
    seen_call_event_ids = set()
    for event in database.get("callEvents", []):
        canonical_event_id = normalized_entity_id(event.get("id")) or str(uuid.uuid4())
        if canonical_event_id in seen_call_event_ids:
            did_update = True
            continue
        seen_call_event_ids.add(canonical_event_id)
        if event.get("id") != canonical_event_id:
            event["id"] = canonical_event_id
            did_update = True

        call_id = call_id_map.get(normalized_optional_string(event.get("callID")), normalized_entity_id(event.get("callID")))
        if call_id and event.get("callID") != call_id:
            event["callID"] = call_id
            did_update = True

        sender_id = user_id_map.get(normalized_optional_string(event.get("senderID")), normalized_entity_id(event.get("senderID")))
        if sender_id and event.get("senderID") != sender_id:
            event["senderID"] = sender_id
            did_update = True

        try:
            sequence = int(event.get("sequence") or 0)
        except (TypeError, ValueError):
            sequence = 0
        if event.get("sequence") != sequence:
            event["sequence"] = sequence
            did_update = True

        normalized_call_events.append(event)
    database["callEvents"] = normalized_call_events

    return did_update


def generate_token():
    return f"{uuid.uuid4().hex}{uuid.uuid4().hex}"


def hash_token(token):
    return hashlib.sha256((token or "").encode("utf-8")).hexdigest()


def parse_iso_datetime(value):
    if not value:
        return None
    try:
        return datetime.fromisoformat(value)
    except ValueError:
        return None


def issue_session(database, user_id):
    user_id = normalized_entity_id(user_id)
    access_token = generate_token()
    refresh_token = generate_token()
    session = {
        "id": str(uuid.uuid4()),
        "userID": user_id,
        "accessTokenHash": hash_token(access_token),
        "refreshTokenHash": hash_token(refresh_token),
        "accessTokenExpiresAt": expires_at_iso(ACCESS_TOKEN_TTL_SECONDS),
        "refreshTokenExpiresAt": expires_at_iso(REFRESH_TOKEN_TTL_SECONDS),
        "updatedAt": now_iso(),
    }
    database["sessions"].append(session)
    return session, access_token, refresh_token


def rotate_session(session):
    access_token = generate_token()
    refresh_token = generate_token()
    session["accessTokenHash"] = hash_token(access_token)
    session["refreshTokenHash"] = hash_token(refresh_token)
    session["accessTokenExpiresAt"] = expires_at_iso(ACCESS_TOKEN_TTL_SECONDS)
    session["refreshTokenExpiresAt"] = expires_at_iso(REFRESH_TOKEN_TTL_SECONDS)
    session["updatedAt"] = now_iso()
    return access_token, refresh_token


def session_payload(user, session, access_token, refresh_token):
    return {
        "user": serialize_user(user),
        "session": {
            "access_token": access_token,
            "refresh_token": refresh_token,
            "access_token_expires_at": session["accessTokenExpiresAt"],
            "refresh_token_expires_at": session["refreshTokenExpiresAt"],
        },
    }


def find_session_by_access_token(database, access_token):
    token_hash = hash_token(access_token)
    return next((session for session in database["sessions"] if session["accessTokenHash"] == token_hash), None)


def find_session_by_refresh_token(database, refresh_token):
    token_hash = hash_token(refresh_token)
    return next((session for session in database["sessions"] if session["refreshTokenHash"] == token_hash), None)


def bearer_token_from_headers(headers):
    authorization = headers.get("Authorization", "")
    if not authorization.lower().startswith("bearer "):
        return None
    return authorization[7:].strip() or None


def authenticated_user(database, headers):
    access_token = bearer_token_from_headers(headers)
    if not access_token:
        return None, None, "invalid_credentials"

    session = find_session_by_access_token(database, access_token)
    if not session:
        return None, None, "invalid_credentials"

    if (parse_iso_datetime(session.get("accessTokenExpiresAt")) or datetime.min.replace(tzinfo=timezone.utc)) <= datetime.now(timezone.utc):
        return None, None, "invalid_credentials"

    user = find_user(database, session.get("userID"))
    if not user:
        return None, None, "user_not_found"

    current_time = datetime.now(timezone.utc)
    updated_at = parse_iso_datetime(session.get("updatedAt"))
    if not updated_at or (current_time - updated_at).total_seconds() >= SESSION_ACTIVITY_TOUCH_INTERVAL_SECONDS:
        session["updatedAt"] = current_time.isoformat()
        save_db(database)
    return user, session, None


def request_user_with_fallback(database, headers, fallback_user_id=None, create_if_missing=False):
    user, session, auth_error = authenticated_user(database, headers)
    if not auth_error:
        return user, session, None

    fallback_user_id = normalized_entity_id(fallback_user_id)
    if not fallback_user_id:
        return None, None, auth_error

    fallback_user = find_user(database, fallback_user_id)
    if not fallback_user:
        if create_if_missing:
            return ensure_legacy_placeholder_user(database, fallback_user_id), None, None
        return None, None, "user_not_found"

    return fallback_user, None, None


def unique_legacy_username(database, user_id):
    base = f"legacy_{str(user_id).replace('-', '')[:8]}".lower()
    candidate = base
    counter = 1
    while username_taken(database, candidate):
        candidate = f"{base}_{counter}"
        counter += 1
    return candidate


def ensure_legacy_placeholder_user(database, user_id):
    existing_user = find_user(database, user_id)
    if existing_user:
        return existing_user

    username = unique_legacy_username(database, user_id)
    user = {
        "id": user_id,
        "password": "",
        "profile": {
            "displayName": "Prime User",
            "username": username,
            "bio": "Welcome to Prime Messaging.",
            "status": "Available",
            "email": None,
            "phoneNumber": None,
            "profilePhotoURL": None,
            "socialLink": None,
        },
        "identityMethods": build_identity_methods(username),
        "privacySettings": default_privacy_settings(),
    }
    database["users"].append(user)
    ensure_saved_messages_chat(database, user_id, "online")
    ensure_saved_messages_chat(database, user_id, "offline")
    save_db(database)
    return user


def is_legacy_placeholder_user(user):
    profile = user.get("profile") or {}
    username = (profile.get("username") or "").strip().lower()
    return (
        not user.get("password")
        and not normalized_optional_string(profile.get("email"))
        and not normalized_optional_string(profile.get("phoneNumber"))
        and username.startswith("legacy_")
    )


def is_admin_account(user):
    profile = (user or {}).get("profile") or {}
    return normalize_username(profile.get("username")) == normalize_username(ADMIN_USERNAME)


def admin_request_error(database, headers):
    provided_login = normalized_optional_string(headers.get("X-Prime-Admin-Login")) or ""
    provided_password = (headers.get("X-Prime-Admin-Password") or "").strip()
    provided_token = (headers.get("X-Prime-Admin-Token") or "").strip()

    if ADMIN_LOGIN and ADMIN_PASSWORD:
        if not provided_login or not provided_password:
            if ADMIN_TOKEN and provided_token:
                if not hmac.compare_digest(provided_token, ADMIN_TOKEN):
                    return "admin_forbidden"
            else:
                return "admin_credentials_required"
        else:
            if provided_login.lower() != ADMIN_LOGIN:
                return "admin_forbidden"
            if not hmac.compare_digest(provided_password, ADMIN_PASSWORD):
                return "admin_forbidden"
    elif ADMIN_TOKEN:
        if not provided_token:
            return "admin_token_required"
        if not hmac.compare_digest(provided_token, ADMIN_TOKEN):
            return "admin_forbidden"
    else:
        return "admin_not_configured"

    admin_user, _, auth_error = authenticated_user(database, headers)
    if auth_error:
        return "admin_auth_required"

    if not is_admin_account(admin_user):
        return "admin_account_required"

    return None


def payload_string(payload, *keys):
    for key in keys:
        value = normalized_optional_string(payload.get(key))
        if value:
            return value
    return None


def latest_user_session_activity(database, user_id):
    latest = None
    for session in database.get("sessions", []):
        if not ids_equal(session.get("userID"), user_id):
            continue
        updated_at = parse_iso_datetime(session.get("updatedAt"))
        if updated_at and (latest is None or updated_at > latest):
            latest = updated_at
    return latest


def user_is_online(database, user_id):
    latest_activity = latest_user_session_activity(database, user_id)
    if not latest_activity:
        return False
    return (datetime.now(timezone.utc) - latest_activity).total_seconds() <= PRESENCE_ONLINE_WINDOW_SECONDS


def serialize_presence(viewer, target_user, database):
    latest_activity = latest_user_session_activity(database, target_user["id"])
    allow_last_seen = (target_user.get("privacySettings") or {}).get("allowLastSeen", True)

    if user_is_online(database, target_user["id"]):
        state = "online"
        last_seen_at = latest_activity.isoformat() if latest_activity else now_iso()
    elif latest_activity and allow_last_seen:
        state = "lastSeen"
        last_seen_at = latest_activity.isoformat()
    else:
        state = "recently"
        last_seen_at = latest_activity.isoformat() if latest_activity else None

    if viewer and ids_equal(viewer["id"], target_user["id"]) and latest_activity:
        state = "online" if user_is_online(database, target_user["id"]) else "lastSeen"
        last_seen_at = latest_activity.isoformat()

    return {
        "userID": target_user["id"],
        "state": state,
        "lastSeenAt": last_seen_at,
        "isTyping": False,
    }


def serialize_user(user):
    return {
        "id": user["id"],
        "profile": sanitized_profile(user["profile"]),
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
        if excluding_user_id and ids_equal(user["id"], excluding_user_id):
            continue
        if user["profile"]["username"].lower() == username:
            return True
    return False


def ensure_saved_messages_chat(database, user_id, mode):
    user_id = normalized_entity_id(user_id)
    existing = next(
        (
            chat for chat in database["chats"]
            if chat["type"] == "selfChat"
            and chat["mode"] == mode
            and unique_entity_ids(chat.get("participantIDs")) == [user_id]
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


def normalized_optional_url_string(value):
    return normalized_optional_string(value)


def sanitized_profile(profile):
    payload = dict(profile or {})
    payload["profilePhotoURL"] = normalized_optional_url_string(payload.get("profilePhotoURL"))
    payload["socialLink"] = normalized_optional_url_string(payload.get("socialLink"))
    return payload


def sanitized_group(group):
    if not group:
        return None

    payload = dict(group)
    payload["photoURL"] = normalized_optional_url_string(payload.get("photoURL"))
    return payload


def sanitized_attachments(attachments):
    sanitized = []
    for attachment in attachments or []:
        payload = dict(attachment)
        payload["localURL"] = normalized_optional_url_string(payload.get("localURL"))
        payload["remoteURL"] = normalized_optional_url_string(payload.get("remoteURL"))
        sanitized.append(payload)
    return sanitized


def sanitized_voice_message(voice_message):
    if not voice_message:
        return None

    payload = dict(voice_message)
    payload["localFileURL"] = normalized_optional_url_string(payload.get("localFileURL"))
    payload["remoteFileURL"] = normalized_optional_url_string(payload.get("remoteFileURL"))
    return payload


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


def resolved_user_display_name(user):
    if not user:
        return None

    display_name = (user["profile"].get("displayName") or "").strip()
    if display_name:
        return display_name

    username = (user["profile"].get("username") or "").strip()
    return username or None


def sync_user_snapshots(database, user):
    did_update = False
    display_name = resolved_user_display_name(user)
    username = (user["profile"].get("username") or "").strip()

    for chat in database["chats"]:
        if chat.get("type") == "group":
            group = chat.get("group") or {}
            members = group.get("members") or []
            for member in members:
                if not ids_equal(member.get("userID"), user["id"]):
                    continue

                if display_name and member.get("displayName") != display_name:
                    member["displayName"] = display_name
                    did_update = True

                if username and member.get("username") != username:
                    member["username"] = username
                    did_update = True

    return did_update


def backfill_group_member_snapshots(chat, database):
    if chat.get("type") != "group":
        return False

    group = chat.get("group") or {}
    members = group.get("members") or []
    did_update = False

    for member in members:
        user = find_user(database, member.get("userID"))
        if not user:
            continue

        display_name = resolved_user_display_name(user)
        username = (user["profile"].get("username") or "").strip()

        if display_name and member.get("displayName") != display_name:
            member["displayName"] = display_name
            did_update = True

        if username and member.get("username") != username:
            member["username"] = username
            did_update = True

    return did_update


def group_member_display_name_for(chat, user_id):
    if not chat or chat.get("type") != "group":
        return None

    group = chat.get("group") or {}
    for member in group.get("members") or []:
        if not ids_equal(member.get("userID"), user_id):
            continue

        display_name = (member.get("displayName") or "").strip()
        if display_name:
            return display_name

        username = (member.get("username") or "").strip()
        if username:
            return username

    return None


def find_group_member(chat, user_id):
    if not chat or chat.get("type") != "group":
        return None

    group = chat.get("group") or {}
    return next(
        (member for member in group.get("members") or [] if ids_equal(member.get("userID"), user_id)),
        None,
    )


def can_manage_group(chat, user_id):
    member = find_group_member(chat, user_id)
    if not member:
        return False

    return member.get("role") in ("owner", "admin")


def can_update_group_member_role(chat, requester_id, member_user_id, new_role):
    member_role = (find_group_member(chat, requester_id) or {}).get("role")
    if member_role != "owner":
        return False
    if new_role not in ("admin", "member"):
        return False
    if ids_equal(member_user_id, requester_id):
        return False
    if ids_equal((chat.get("group") or {}).get("ownerID"), member_user_id):
        return False
    return find_group_member(chat, member_user_id) is not None


def can_remove_group_member(chat, requester_id, member_user_id):
    requester_member = find_group_member(chat, requester_id)
    target_member = find_group_member(chat, member_user_id)
    if not requester_member or not target_member:
        return False
    if ids_equal(member_user_id, requester_id):
        return False
    if ids_equal((chat.get("group") or {}).get("ownerID"), member_user_id):
        return False

    requester_role = requester_member.get("role")
    target_role = target_member.get("role")
    if requester_role == "owner":
        return True
    if requester_role == "admin":
        return target_role == "member"
    return False


def update_group_member_role(chat, member_user_id, new_role):
    if not chat or chat.get("type") != "group":
        return False

    group = chat.get("group") or {}
    if new_role not in ("admin", "member"):
        return False

    did_update = False
    for member in group.get("members") or []:
        if not ids_equal(member.get("userID"), member_user_id):
            continue
        if member.get("role") == new_role:
            return False
        member["role"] = new_role
        did_update = True
        break

    return did_update


def remove_group_member(chat, member_user_id):
    if not chat or chat.get("type") != "group":
        return False

    group = chat.get("group") or {}
    owner_id = normalized_entity_id(group.get("ownerID"))
    member_user_id = normalized_entity_id(member_user_id)
    if not member_user_id or ids_equal(owner_id, member_user_id):
        return False

    previous_member_count = len(group.get("members") or [])
    previous_participant_count = len(chat.get("participantIDs") or [])

    group["members"] = [
        member for member in (group.get("members") or [])
        if not ids_equal(member.get("userID"), member_user_id)
    ]
    chat["participantIDs"] = [
        participant_id
        for participant_id in (chat.get("participantIDs") or [])
        if not ids_equal(participant_id, member_user_id)
    ]
    chat["cachedSubtitle"] = f"{len(group['members'])} members"
    return previous_member_count != len(group["members"]) or previous_participant_count != len(chat["participantIDs"])


def leave_group(chat, requester_id):
    if not chat or chat.get("type") != "group":
        return False

    group = chat.get("group") or {}
    if ids_equal(group.get("ownerID"), requester_id):
        return False

    return remove_group_member(chat, requester_id)


def delete_user_account(database, user_id):
    user = find_user(database, user_id)
    if not user:
        return False

    remove_file_for_url((user.get("profile") or {}).get("profilePhotoURL"), AVATAR_DIR)

    database["users"] = [
        candidate
        for candidate in database.get("users", [])
        if not ids_equal(candidate.get("id"), user_id)
    ]
    database["sessions"] = [
        session
        for session in database.get("sessions", [])
        if not ids_equal(session.get("userID"), user_id)
    ]
    database["deviceTokens"] = [
        token
        for token in database.get("deviceTokens", [])
        if not ids_equal(token.get("userID"), user_id)
    ]

    deleted_chat_ids = set()
    for chat in list(database.get("chats", [])):
        if not any(ids_equal(participant_id, user_id) for participant_id in (chat.get("participantIDs") or [])):
            continue

        if chat.get("type") in ("selfChat", "direct"):
            deleted_chat_ids.add(normalized_entity_id(chat.get("id")))
            continue

        if chat.get("type") == "group":
            group = chat.get("group") or {}
            if ids_equal(group.get("ownerID"), user_id):
                remaining_members = [
                    member
                    for member in (group.get("members") or [])
                    if not ids_equal(member.get("userID"), user_id)
                ]
                if not remaining_members:
                    deleted_chat_ids.add(normalized_entity_id(chat.get("id")))
                    continue

                new_owner_id = normalized_entity_id(remaining_members[0].get("userID"))
                group["ownerID"] = new_owner_id
                for member in remaining_members:
                    member["role"] = "owner" if ids_equal(member.get("userID"), new_owner_id) else (
                        "admin" if member.get("role") == "admin" else "member"
                    )
                group["members"] = remaining_members
                chat["participantIDs"] = unique_entity_ids(
                    participant_id
                    for participant_id in (chat.get("participantIDs") or [])
                    if not ids_equal(participant_id, user_id)
                )
                chat["cachedSubtitle"] = f"{len(group['members'])} members"
                continue

            remove_group_member(chat, user_id)

    database["chats"] = [
        chat
        for chat in database.get("chats", [])
        if normalized_entity_id(chat.get("id")) not in deleted_chat_ids
    ]
    database["messages"] = [
        message
        for message in database.get("messages", [])
        if normalized_entity_id(message.get("chatID")) not in deleted_chat_ids
    ]

    return True


def ban_user_account(database, user_id, duration_days):
    user = find_user(database, user_id)
    if not user:
        return False

    user["bannedUntil"] = expires_at_iso(max(duration_days, 1) * 24 * 60 * 60)
    database["sessions"] = [
        session
        for session in database.get("sessions", [])
        if not ids_equal(session.get("userID"), user_id)
    ]
    return True


def bulk_delete_users(database, user_ids):
    removed_count = 0
    skipped_count = 0

    for user_id in unique_entity_ids(user_ids):
        target_user = find_user(database, user_id)
        if not target_user:
            skipped_count += 1
            continue
        if is_admin_account(target_user):
            skipped_count += 1
            continue
        if delete_user_account(database, user_id):
            removed_count += 1
        else:
            skipped_count += 1

    return removed_count, skipped_count


def admin_summary_payload(database):
    legacy_user_count = sum(1 for user in database.get("users", []) if is_legacy_placeholder_user(user))
    return {
        "users": len(database.get("users", [])),
        "legacyUsers": legacy_user_count,
        "chats": len(database.get("chats", [])),
        "messages": len(database.get("messages", [])),
        "sessions": len(database.get("sessions", [])),
        "deviceTokens": len(database.get("deviceTokens", [])),
    }


def admin_user_payload(database, user):
    profile = user.get("profile") or {}
    user_id = normalized_entity_id(user.get("id"))
    chat_count = sum(
        1
        for chat in database.get("chats", [])
        if any(ids_equal(participant_id, user_id) for participant_id in (chat.get("participantIDs") or []))
    )
    sent_message_count = sum(
        1
        for message in database.get("messages", [])
        if ids_equal(message.get("senderID"), user_id)
    )
    session_count = sum(
        1
        for session in database.get("sessions", [])
        if ids_equal(session.get("userID"), user_id)
    )

    return {
        "id": user.get("id"),
        "displayName": profile.get("displayName") or "",
        "username": profile.get("username") or "",
        "email": profile.get("email"),
        "phoneNumber": profile.get("phoneNumber"),
        "accountKind": user.get("accountKind") or "standard",
        "createdAt": user.get("createdAt") or now_iso(),
        "guestExpiresAt": user.get("guestExpiresAt"),
        "bannedUntil": user.get("bannedUntil"),
        "isLegacyPlaceholder": is_legacy_placeholder_user(user),
        "chatCount": chat_count,
        "sentMessageCount": sent_message_count,
        "sessionCount": session_count,
    }


def group_member_payload(database, member_id, role):
    user = find_user(database, member_id)
    return {
        "id": str(uuid.uuid4()),
        "userID": member_id,
        "displayName": resolved_user_display_name(user),
        "username": (user or {}).get("profile", {}).get("username"),
        "role": role,
        "joinedAt": now_iso(),
    }


def chat_participant_payload(database, user_id):
    user = find_user(database, user_id)
    if not user:
        return None

    return {
        "id": user_id,
        "username": user["profile"].get("username") or "",
        "displayName": resolved_user_display_name(user),
    }


def avatar_content_type(file_name):
    lower_name = (file_name or "").lower()
    if lower_name.endswith(".jpg") or lower_name.endswith(".jpeg"):
        return "image/jpeg"
    if lower_name.endswith(".heic"):
        return "image/heic"
    if lower_name.endswith(".webp"):
        return "image/webp"
    return "image/png"


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

    chat = find_chat(database, message.get("chatID"))
    group_member_name = group_member_display_name_for(chat, message.get("senderID"))
    if group_member_name:
        return group_member_name

    sender = find_user(database, message.get("senderID"))
    if not sender:
        historical_names = [
            (item.get("senderDisplayName") or "").strip()
            for item in database["messages"]
            if item.get("senderID") == message.get("senderID")
        ]
        historical_names = [name for name in historical_names if name]
        return historical_names[-1] if historical_names else "Unknown user"

    display_name = (sender["profile"].get("displayName") or "").strip()
    return display_name or sender["profile"]["username"]


def backfill_sender_display_name(message, database):
    if (message.get("senderDisplayName") or "").strip():
        return False

    resolved_name = sender_display_name_for(message, database)
    if not resolved_name or resolved_name == "Unknown user":
        return False

    message["senderDisplayName"] = resolved_name
    return True


def generic_direct_title(value):
    trimmed = (value or "").strip().lower()
    return trimmed in ("", "chat", "direct chat")


def generic_direct_subtitle(value):
    trimmed = (value or "").strip().lower()
    return trimmed in ("", "direct conversation")


def direct_chat_other_user(chat, current_user_id, database):
    participant_ids = chat.get("participantIDs") or []

    for user_id in participant_ids:
        if ids_equal(user_id, current_user_id):
            continue
        user = find_user(database, user_id)
        if user:
            return user

    messages = [message for message in database["messages"] if ids_equal(message.get("chatID"), chat.get("id"))]
    messages.sort(key=lambda item: item["createdAt"], reverse=True)

    for message in messages:
        sender_id = message.get("senderID")
        if not sender_id or ids_equal(sender_id, current_user_id):
            continue
        user = find_user(database, sender_id)
        if user:
            return user

    cached_subtitle = (chat.get("cachedSubtitle") or "").strip()
    if cached_subtitle.startswith("@"):
        user = find_user_by_identifier(database, cached_subtitle)
        if user and not ids_equal(user["id"], current_user_id):
            return user

    return None


def direct_chat_fallback_participant(chat, current_user_id, database):
    messages = [message for message in database["messages"] if ids_equal(message.get("chatID"), chat.get("id"))]
    messages.sort(key=lambda item: item["createdAt"], reverse=True)
    other_user_id = next(
        (participant_id for participant_id in (chat.get("participantIDs") or []) if not ids_equal(participant_id, current_user_id)),
        None,
    )
    cached_subtitle = (chat.get("cachedSubtitle") or "").strip()
    username = cached_subtitle.removeprefix("@") if cached_subtitle.startswith("@") else ""

    for message in messages:
        sender_id = message.get("senderID")
        if not sender_id or ids_equal(sender_id, current_user_id):
            continue

        display_name = (message.get("senderDisplayName") or "").strip()
        if not display_name or display_name.lower() == "unknown user":
            continue

        return {
            "id": sender_id or other_user_id,
            "username": username,
            "displayName": display_name,
        }

    if other_user_id and username:
        return {
            "id": other_user_id,
            "username": username,
            "displayName": username,
        }

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

    fallback_participant = direct_chat_fallback_participant(chat, current_user_id, database)
    if fallback_participant:
        display_name = (fallback_participant.get("displayName") or "").strip()
        if display_name:
            return display_name
        username = (fallback_participant.get("username") or "").strip()
        if username:
            return username

    cached_title = chat.get("cachedTitle", "Direct Chat")
    if generic_direct_title(cached_title):
        cached_subtitle = chat.get("cachedSubtitle", "Direct conversation")
        if cached_subtitle.startswith("@"):
            return cached_subtitle.removeprefix("@")
        return "Missing User"

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
    messages = [message for message in database["messages"] if ids_equal(message.get("chatID"), chat.get("id"))]
    messages.sort(key=lambda item: item["createdAt"])
    last_message = messages[-1] if messages else None
    participants = [
        payload for payload in (
            chat_participant_payload(database, participant_id)
            for participant_id in chat["participantIDs"]
        )
        if payload is not None
    ]

    if chat["type"] == "direct":
        other_user_id = next(
            (participant_id for participant_id in chat["participantIDs"] if not ids_equal(participant_id, current_user_id)),
            None,
        )
        has_other_participant = any(ids_equal(participant["id"], other_user_id) for participant in participants) if other_user_id else False
        if not has_other_participant:
            fallback_participant = direct_chat_fallback_participant(chat, current_user_id, database)
            if fallback_participant:
                participants.append(fallback_participant)

    return {
        "id": chat["id"],
        "mode": chat["mode"],
        "type": chat["type"],
        "title": chat_title_for(chat, current_user_id, database),
        "subtitle": chat_subtitle_for(chat, current_user_id, database),
        "participantIDs": chat["participantIDs"],
        "participants": participants,
        "group": sanitized_group(chat.get("group")),
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
        "attachments": [] if is_deleted else sanitized_attachments(message.get("attachments", [])),
        "replyToMessageID": message.get("replyToMessageID"),
        "replyPreview": None if is_deleted else sanitized_reply_preview(message.get("replyPreview")),
        "status": message.get("status", "sent"),
        "createdAt": message["createdAt"],
        "editedAt": message.get("editedAt"),
        "deletedForEveryoneAt": message.get("deletedForEveryoneAt"),
        "reactions": [] if is_deleted else sanitized_reactions(message.get("reactions")),
        "voiceMessage": None if is_deleted else sanitized_voice_message(message.get("voiceMessage")),
        "liveLocation": None,
    }


def mark_messages_delivered(chat, database, recipient_id):
    if not chat or chat.get("mode") != "online" or chat.get("type") != "direct":
        return False

    did_update = False
    for message in database["messages"]:
        if not ids_equal(message.get("chatID"), chat.get("id")):
            continue
        if ids_equal(message.get("senderID"), recipient_id):
            continue
        if message.get("deletedForEveryoneAt"):
            continue
        if message.get("status") != "sent":
            continue

        message["status"] = "delivered"
        did_update = True

    return did_update


def sanitized_reply_preview(reply_preview):
    if not isinstance(reply_preview, dict):
        return None

    preview_text = normalized_optional_string(reply_preview.get("previewText"))
    if not preview_text:
        return None

    return {
        "senderID": normalized_entity_id(reply_preview.get("senderID")),
        "senderDisplayName": normalized_optional_string(reply_preview.get("senderDisplayName")),
        "previewText": preview_text,
    }


def sanitized_reactions(reactions):
    if not isinstance(reactions, list):
        return []

    sanitized = []
    for reaction in reactions:
        if not isinstance(reaction, dict):
            continue
        emoji = normalized_optional_string(reaction.get("emoji"))
        if not emoji:
            continue

        user_ids = unique_entity_ids(reaction.get("userIDs") or [])
        if not user_ids:
            continue

        sanitized.append(
            {
                "id": normalized_entity_id(reaction.get("id")) or str(uuid.uuid4()),
                "emoji": emoji,
                "userIDs": user_ids,
            }
        )

    return sanitized


def mark_chat_read(chat, database, reader_id):
    if not chat or chat.get("mode") != "online" or chat.get("type") != "direct":
        return False

    did_update = False
    for message in database["messages"]:
        if not ids_equal(message.get("chatID"), chat.get("id")):
            continue
        if ids_equal(message.get("senderID"), reader_id):
            continue
        if message.get("deletedForEveryoneAt"):
            continue
        if message.get("status") == "read":
            continue

        message["status"] = "read"
        did_update = True

    return did_update


def device_tokens_for_recipients(database, chat, excluding_user_id):
    recipient_ids = [
        participant_id
        for participant_id in (chat.get("participantIDs") or [])
        if not ids_equal(participant_id, excluding_user_id)
    ]
    return [
        device_token
        for device_token in database.get("deviceTokens", [])
        if any(ids_equal(device_token.get("userID"), recipient_id) for recipient_id in recipient_ids)
    ]


def push_payload_for_message(chat, message, database):
    title = (
        (chat.get("group") or {}).get("title")
        if chat.get("type") == "group"
        else sender_display_name_for(message, database)
    ) or "Prime Messaging"

    return {
        "chat_id": chat["id"],
        "message_id": message["id"],
        "mode": chat["mode"],
        "chat_type": chat["type"],
        "title": title,
        "body": message_preview(message) or "New message",
    }


def log_push_dispatch_attempt(database, chat, message):
    device_tokens = device_tokens_for_recipients(database, chat, message.get("senderID"))
    payload = push_payload_for_message(chat, message, database)

    if not device_tokens:
        log_event(
            "push.dispatch.skipped",
            reason="no_device_tokens",
            chat_id=chat["id"],
            message_id=message["id"],
            recipient_count=0,
        )
        return

    token_suffixes = [
        (entry.get("token") or "")[-8:]
        for entry in device_tokens
        if entry.get("token")
    ]
    log_event(
        "push.dispatch.pending_provider",
        reason="apns_provider_not_configured_in_backend",
        chat_id=chat["id"],
        message_id=message["id"],
        recipient_count=len(device_tokens),
        token_suffixes=token_suffixes,
        payload=payload,
    )


ACTIVE_CALL_STATES = {"ringing", "active"}


def call_involves_user(call, user_id):
    return ids_equal(call.get("callerID"), user_id) or ids_equal(call.get("calleeID"), user_id)


def visible_call_for_client(call):
    state = normalized_optional_string(call.get("state")) or "ringing"
    return state in ACTIVE_CALL_STATES


def find_call(database, call_id):
    call_id = normalized_entity_id(call_id)
    if not call_id:
        return None
    return next((call for call in database.get("calls", []) if ids_equal(call.get("id"), call_id)), None)


def call_participant_payload(database, user_id):
    user = find_user(database, user_id)
    if not user:
        return None

    return {
        "id": user["id"],
        "username": user["profile"]["username"],
        "displayName": normalized_optional_string(user["profile"].get("displayName")),
        "profilePhotoURL": normalized_optional_url_string(user["profile"].get("profilePhotoURL")),
    }


def serialize_call(call, viewer_id, database):
    participants = [
        payload for payload in (
            call_participant_payload(database, call.get("callerID")),
            call_participant_payload(database, call.get("calleeID")),
        ) if payload is not None
    ]

    return {
        "id": call["id"],
        "mode": call.get("mode", "online"),
        "kind": call.get("kind", "audio"),
        "state": call.get("state", "ringing"),
        "chatID": call.get("chatID"),
        "callerID": call.get("callerID"),
        "calleeID": call.get("calleeID"),
        "participants": participants,
        "createdAt": call.get("createdAt"),
        "answeredAt": call.get("answeredAt"),
        "endedAt": call.get("endedAt"),
        "lastEventSequence": int(call.get("lastEventSequence") or 0),
    }


def serialize_call_event(event):
    payload = event.get("payload") or {}
    return {
        "id": event["id"],
        "callID": event["callID"],
        "sequence": int(event.get("sequence") or 0),
        "type": event.get("type"),
        "senderID": event.get("senderID"),
        "sdp": payload.get("sdp"),
        "candidate": payload.get("candidate"),
        "sdpMid": payload.get("sdpMid"),
        "sdpMLineIndex": payload.get("sdpMLineIndex"),
        "createdAt": event.get("createdAt"),
    }


def append_call_event(database, call, event_type, sender_id=None, payload=None):
    next_sequence = int(call.get("lastEventSequence") or 0) + 1
    event = {
        "id": str(uuid.uuid4()),
        "callID": call["id"],
        "sequence": next_sequence,
        "type": event_type,
        "senderID": normalized_entity_id(sender_id),
        "payload": payload or {},
        "createdAt": now_iso(),
    }
    database["callEvents"].append(event)
    call["lastEventSequence"] = next_sequence
    call["updatedAt"] = event["createdAt"]
    return event


def call_events_for(database, call_id, since_sequence):
    return sorted(
        [
            event for event in database.get("callEvents", [])
            if ids_equal(event.get("callID"), call_id) and int(event.get("sequence") or 0) > since_sequence
        ],
        key=lambda item: int(item.get("sequence") or 0),
    )


def ensure_direct_chat_record(database, first_user_id, second_user_id, mode):
    existing = existing_direct_chat_record(database, first_user_id, second_user_id, mode)
    if existing:
        return existing

    participant_ids = unique_entity_ids([first_user_id, second_user_id])
    chat = {
        "id": str(uuid.uuid4()),
        "mode": mode,
        "type": "direct",
        "participantIDs": participant_ids,
        "cachedTitle": "Direct Chat",
        "cachedSubtitle": "Direct conversation",
        "createdAt": now_iso(),
    }
    database["chats"].append(chat)
    return chat


def existing_direct_chat_record(database, first_user_id, second_user_id, mode):
    participant_ids = unique_entity_ids([first_user_id, second_user_id])
    return next(
        (
            chat for chat in database["chats"]
            if chat.get("type") == "direct"
            and chat.get("mode") == mode
            and set(unique_entity_ids(chat.get("participantIDs") or [])) == set(participant_ids)
        ),
        None,
    )


def call_requires_saved_contact(database, caller, callee, mode):
    privacy_settings = callee.get("privacySettings") or default_privacy_settings()
    if privacy_settings.get("allowCallsFromNonContacts", False):
        return False

    return existing_direct_chat_record(database, caller["id"], callee["id"], mode) is None


def active_call_between(database, caller_id, callee_id, mode):
    participant_ids = {normalized_entity_id(caller_id), normalized_entity_id(callee_id)}
    for call in database.get("calls", []):
        if call.get("mode") != mode:
            continue
        if normalized_optional_string(call.get("state")) not in ACTIVE_CALL_STATES:
            continue
        if {normalized_entity_id(call.get("callerID")), normalized_entity_id(call.get("calleeID"))} == participant_ids:
            return call
    return None


def can_manage_call(call, user_id):
    return call_involves_user(call, user_id)


def log_call_dispatch_attempt(database, call):
    recipient_id = call.get("calleeID")
    if normalized_optional_string(call.get("state")) != "ringing":
        return

    device_tokens = [
        token for token in database.get("deviceTokens", [])
        if ids_equal(token.get("userID"), recipient_id)
    ]

    if not device_tokens:
        log_event(
            "call.dispatch.skipped",
            reason="no_device_tokens",
            call_id=call["id"],
            recipient_id=recipient_id,
        )
        return

    log_event(
        "call.dispatch.pending_provider",
        reason="apns_provider_not_configured_in_backend",
        call_id=call["id"],
        recipient_id=recipient_id,
        token_suffixes=[(entry.get("token") or "")[-8:] for entry in device_tokens if entry.get("token")],
    )


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

            if parsed.path == "/admin/summary":
                admin_error = admin_request_error(database, self.headers)
                if admin_error:
                    return self.respond(401 if admin_error in {"admin_not_configured", "admin_token_required", "admin_credentials_required", "admin_auth_required"} else 403, {"error": admin_error})
                return self.respond(200, admin_summary_payload(database))

            if parsed.path == "/admin/users":
                admin_error = admin_request_error(database, self.headers)
                if admin_error:
                    return self.respond(401 if admin_error in {"admin_not_configured", "admin_token_required", "admin_credentials_required", "admin_auth_required"} else 403, {"error": admin_error})

                params = parse_qs(parsed.query)
                query = (params.get("query") or [""])[0].strip().lower()
                placeholders_only = (params.get("placeholders_only") or ["0"])[0].strip().lower() in {"1", "true", "yes"}

                users = []
                for user in database.get("users", []):
                    if placeholders_only and not is_legacy_placeholder_user(user):
                        continue

                    profile = user.get("profile") or {}
                    if query and not (
                        query in (profile.get("username") or "").lower()
                        or query in (profile.get("displayName") or "").lower()
                        or query in (profile.get("email") or "").lower()
                        or query in (profile.get("phoneNumber") or "").lower()
                    ):
                        continue

                    users.append(admin_user_payload(database, user))

                users.sort(key=lambda item: ((not item["isLegacyPlaceholder"]), item["createdAt"], item["username"]))
                return self.respond(200, users)

            if parsed.path == "/admin/chats":
                admin_error = admin_request_error(database, self.headers)
                if admin_error:
                    return self.respond(401 if admin_error in {"admin_not_configured", "admin_token_required", "admin_credentials_required", "admin_auth_required"} else 403, {"error": admin_error})

                params = parse_qs(parsed.query)
                user_id = normalized_entity_id((params.get("user_id") or [""])[0].strip())
                user = find_user(database, user_id)
                if not user:
                    return self.respond(404, {"error": "user_not_found"})

                chats = []
                for chat in database.get("chats", []):
                    if any(ids_equal(participant_id, user_id) for participant_id in (chat.get("participantIDs") or [])):
                        chats.append(serialize_chat(chat, user_id, database))

                chats.sort(key=lambda item: item.get("lastActivityAt") or "", reverse=True)
                return self.respond(200, chats)

            if parsed.path == "/admin/messages":
                admin_error = admin_request_error(database, self.headers)
                if admin_error:
                    return self.respond(401 if admin_error in {"admin_not_configured", "admin_token_required", "admin_credentials_required", "admin_auth_required"} else 403, {"error": admin_error})

                params = parse_qs(parsed.query)
                chat_id = normalized_entity_id((params.get("chat_id") or [""])[0].strip())
                chat = find_chat(database, chat_id)
                if not chat:
                    return self.respond(404, {"error": "chat_not_found"})

                messages = [
                    serialize_message(message, database)
                    for message in database.get("messages", [])
                    if ids_equal(message.get("chatID"), chat_id)
                ]
                messages.sort(key=lambda item: item.get("createdAt") or "")

                participant_ids = unique_entity_ids(chat.get("participantIDs") or [])
                viewer_id = participant_ids[0] if participant_ids else None
                return self.respond(200, {
                    "chat": serialize_chat(chat, viewer_id, database) if viewer_id else None,
                    "messages": messages,
                })

            if parsed.path == "/auth/me":
                user, _, auth_error = authenticated_user(database, self.headers)
                if auth_error == "user_not_found":
                    return self.respond(404, {"error": "user_not_found"})
                if auth_error:
                    return self.respond(401, {"error": auth_error})
                return self.respond(200, serialize_user(user))

            if parsed.path == "/usernames/check":
                params = parse_qs(parsed.query)
                username = (params.get("username") or [""])[0].strip().lower()
                user_id = normalized_entity_id((params.get("user_id") or [""])[0].strip() or None)
                available = bool(username) and not username_taken(database, username, user_id)
                return self.respond(200, {"available": available})

            if parsed.path == "/users/search":
                params = parse_qs(parsed.query)
                fallback_user_id = (params.get("exclude_user_id") or [""])[0].strip() or None
                current_user, _, auth_error = request_user_with_fallback(
                    database,
                    self.headers,
                    fallback_user_id,
                    create_if_missing=True
                )
                if auth_error == "user_not_found":
                    return self.respond(404, {"error": "user_not_found"})
                if auth_error:
                    return self.respond(401, {"error": auth_error})

                query = (params.get("query") or [""])[0].strip().lower()
                users = [
                    serialize_user(user)
                    for user in database["users"]
                    if not ids_equal(user["id"], current_user["id"]) and (
                        query in user["profile"]["username"].lower() or
                        query in user["profile"]["displayName"].lower() or
                        query in (user["profile"].get("email") or "").lower() or
                        query in (user["profile"].get("phoneNumber") or "").lower()
                    )
                ]
                return self.respond(200, users[:20])

            if parsed.path.startswith("/users/") and parsed.path.endswith("/privacy"):
                user_id = normalized_entity_id(parsed.path.split("/")[2])
                params = parse_qs(parsed.query)
                fallback_user_id = (
                    (params.get("user_id") or [""])[0].strip()
                    or (params.get("viewer_id") or [""])[0].strip()
                    or user_id
                )
                current_user, _, auth_error = request_user_with_fallback(
                    database,
                    self.headers,
                    fallback_user_id,
                    create_if_missing=True
                )
                if auth_error == "user_not_found":
                    return self.respond(404, {"error": "user_not_found"})
                if auth_error:
                    return self.respond(401, {"error": auth_error})
                if not ids_equal(current_user["id"], user_id):
                    return self.respond(403, {"error": "edit_not_allowed"})
                return self.respond(200, current_user.get("privacySettings") or default_privacy_settings())

            if parsed.path.startswith("/users/") and "/profile" not in parsed.path and "/avatar" not in parsed.path and "/privacy" not in parsed.path:
                user_id = normalized_entity_id(parsed.path.split("/")[2])
                user = find_user(database, user_id)
                if not user:
                    return self.respond(404, {"error": "user_not_found"})
                return self.respond(200, serialize_user(user))

            if parsed.path.startswith("/presence/"):
                params = parse_qs(parsed.query)
                fallback_user_id = (
                    (params.get("viewer_id") or [""])[0].strip()
                    or (params.get("user_id") or [""])[0].strip()
                    or None
                )
                current_user, _, auth_error = request_user_with_fallback(
                    database,
                    self.headers,
                    fallback_user_id,
                    create_if_missing=True
                )
                if auth_error == "user_not_found":
                    return self.respond(404, {"error": "user_not_found"})
                if auth_error:
                    return self.respond(401, {"error": auth_error})

                user_id = normalized_entity_id(parsed.path.split("/")[2])
                user = find_user(database, user_id)
                if not user:
                    return self.respond(404, {"error": "user_not_found"})
                return self.respond(200, serialize_presence(current_user, user, database))

            if parsed.path == "/calls":
                params = parse_qs(parsed.query)
                fallback_user_id = (
                    (params.get("user_id") or [""])[0].strip()
                    or (params.get("viewer_id") or [""])[0].strip()
                    or None
                )
                current_user, _, auth_error = request_user_with_fallback(
                    database,
                    self.headers,
                    fallback_user_id,
                    create_if_missing=True
                )
                if auth_error == "user_not_found":
                    return self.respond(404, {"error": "user_not_found"})
                if auth_error:
                    return self.respond(401, {"error": auth_error})

                calls = [
                    serialize_call(call, current_user["id"], database)
                    for call in database.get("calls", [])
                    if call_involves_user(call, current_user["id"]) and visible_call_for_client(call)
                ]
                calls.sort(key=lambda item: item.get("createdAt") or "", reverse=True)
                return self.respond(200, calls)

            if parsed.path.startswith("/calls/") and parsed.path.endswith("/events"):
                params = parse_qs(parsed.query)
                fallback_user_id = (
                    (params.get("user_id") or [""])[0].strip()
                    or (params.get("viewer_id") or [""])[0].strip()
                    or None
                )
                current_user, _, auth_error = request_user_with_fallback(
                    database,
                    self.headers,
                    fallback_user_id,
                    create_if_missing=True
                )
                if auth_error == "user_not_found":
                    return self.respond(404, {"error": "user_not_found"})
                if auth_error:
                    return self.respond(401, {"error": auth_error})

                call_id = normalized_entity_id(parsed.path.split("/")[2])
                call = find_call(database, call_id)
                if not call:
                    return self.respond(404, {"error": "call_not_found"})
                if not can_manage_call(call, current_user["id"]):
                    return self.respond(403, {"error": "call_permission_denied"})

                try:
                    since_sequence = int((params.get("since") or ["0"])[0])
                except ValueError:
                    since_sequence = 0
                events = [serialize_call_event(event) for event in call_events_for(database, call_id, since_sequence)]
                return self.respond(200, events)

            if parsed.path.startswith("/calls/"):
                params = parse_qs(parsed.query)
                fallback_user_id = (
                    (params.get("user_id") or [""])[0].strip()
                    or (params.get("viewer_id") or [""])[0].strip()
                    or None
                )
                current_user, _, auth_error = request_user_with_fallback(
                    database,
                    self.headers,
                    fallback_user_id,
                    create_if_missing=True
                )
                if auth_error == "user_not_found":
                    return self.respond(404, {"error": "user_not_found"})
                if auth_error:
                    return self.respond(401, {"error": auth_error})

                call_id = normalized_entity_id(parsed.path.split("/")[2])
                call = find_call(database, call_id)
                if not call:
                    return self.respond(404, {"error": "call_not_found"})
                if not can_manage_call(call, current_user["id"]):
                    return self.respond(403, {"error": "call_permission_denied"})

                return self.respond(200, serialize_call(call, current_user["id"], database))

            if parsed.path == "/chats":
                params = parse_qs(parsed.query)
                mode = (params.get("mode") or ["online"])[0].strip()
                fallback_user_id = (params.get("user_id") or [""])[0].strip() or None
                user, _, auth_error = request_user_with_fallback(
                    database,
                    self.headers,
                    fallback_user_id,
                    create_if_missing=True
                )
                if auth_error == "user_not_found":
                    return self.respond(404, {"error": "user_not_found"})
                if auth_error:
                    return self.respond(401, {"error": auth_error})
                user_id = user["id"]

                ensure_saved_messages_chat(database, user_id, mode)
                chats = []
                did_backfill = False
                for chat in database["chats"]:
                    if not any(ids_equal(user_id, participant_id) for participant_id in (chat.get("participantIDs") or [])) or chat["mode"] != mode:
                        continue
                    did_backfill = backfill_group_member_snapshots(chat, database) or did_backfill
                    did_backfill = mark_messages_delivered(chat, database, user_id) or did_backfill
                    chats.append(serialize_chat(chat, user_id, database))

                if did_backfill:
                    save_db(database)

                chats.sort(key=lambda item: item["lastActivityAt"], reverse=True)
                return self.respond(200, chats)

            if parsed.path == "/messages":
                params = parse_qs(parsed.query)
                fallback_user_id = (params.get("user_id") or [""])[0].strip() or None
                current_user, _, auth_error = request_user_with_fallback(
                    database,
                    self.headers,
                    fallback_user_id,
                    create_if_missing=True
                )
                if auth_error == "user_not_found":
                    return self.respond(404, {"error": "user_not_found"})
                if auth_error:
                    return self.respond(401, {"error": auth_error})

                chat_id = normalized_entity_id((params.get("chat_id") or [""])[0].strip())
                chat = find_chat(database, chat_id)
                if not chat:
                    return self.respond(404, {"error": "chat_not_found"})
                if not any(ids_equal(current_user["id"], participant_id) for participant_id in (chat.get("participantIDs") or [])):
                    return self.respond(403, {"error": "sender_not_in_chat"})

                raw_messages = [item for item in database["messages"] if ids_equal(item.get("chatID"), chat["id"])]
                did_backfill = backfill_group_member_snapshots(chat, database)
                did_backfill = mark_messages_delivered(chat, database, current_user["id"]) or did_backfill
                for message in raw_messages:
                    did_backfill = backfill_sender_display_name(message, database) or did_backfill
                if did_backfill:
                    save_db(database)

                messages = [serialize_message(item, database) for item in raw_messages]
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

            if method == "POST" and parsed.path == "/admin/users/bulk-delete":
                admin_error = admin_request_error(database, self.headers)
                if admin_error:
                    return self.respond(401 if admin_error in {"admin_not_configured", "admin_token_required", "admin_credentials_required", "admin_auth_required"} else 403, {"error": admin_error})

                user_ids = payload.get("user_ids") or payload.get("userIDs") or []
                if not isinstance(user_ids, list):
                    user_ids = []

                removed_count, skipped_count = bulk_delete_users(database, user_ids)
                save_db(database)
                return self.respond(200, {"ok": True, "removed": removed_count, "skipped": skipped_count})

            if method == "POST" and parsed.path.startswith("/admin/users/") and parsed.path.endswith("/ban"):
                admin_error = admin_request_error(database, self.headers)
                if admin_error:
                    return self.respond(401 if admin_error in {"admin_not_configured", "admin_token_required", "admin_credentials_required", "admin_auth_required"} else 403, {"error": admin_error})

                path_parts = parsed.path.split("/")
                user_id = normalized_entity_id(path_parts[3] if len(path_parts) > 3 else None)
                if not user_id:
                    return self.respond(404, {"error": "user_not_found"})

                target_user = find_user(database, user_id)
                if not target_user:
                    return self.respond(404, {"error": "user_not_found"})
                if is_admin_account(target_user):
                    return self.respond(403, {"error": "admin_account_protected"})

                try:
                    duration_days = int(payload.get("duration_days") or payload.get("durationDays") or 0)
                except (TypeError, ValueError):
                    duration_days = 0
                if duration_days <= 0:
                    return self.respond(409, {"error": "invalid_ban_duration"})

                ban_user_account(database, user_id, duration_days)
                save_db(database)
                return self.respond(200, {"ok": True, "bannedUntil": target_user.get("bannedUntil")})

            if method == "DELETE" and parsed.path.startswith("/admin/users/"):
                admin_error = admin_request_error(database, self.headers)
                if admin_error:
                    return self.respond(401 if admin_error in {"admin_not_configured", "admin_token_required", "admin_credentials_required", "admin_auth_required"} else 403, {"error": admin_error})

                user_id = normalized_entity_id(parsed.path.split("/")[3] if len(parsed.path.split("/")) > 3 else None)
                if not user_id:
                    return self.respond(404, {"error": "user_not_found"})

                target_user = find_user(database, user_id)
                if target_user and is_admin_account(target_user):
                    return self.respond(403, {"error": "admin_account_protected"})

                if delete_user_account(database, user_id) is False:
                    return self.respond(404, {"error": "user_not_found"})

                save_db(database)
                return self.respond(200, {"ok": True})

            if method == "POST" and parsed.path == "/auth/signup":
                username = str(payload.get("username", "")).strip().lower()
                requested_user_id = normalized_entity_id(payload.get("user_id"))
                existing_requested_user = find_user(database, requested_user_id) if requested_user_id else None
                if username_taken(database, username, requested_user_id):
                    return self.respond(409, {"error": "username_taken"})

                if existing_requested_user and not is_legacy_placeholder_user(existing_requested_user):
                    return self.respond(409, {"error": "user_id_taken"})

                user_id = requested_user_id or str(uuid.uuid4())
                method_type = payload.get("method_type", "email")
                contact_value = normalized_optional_string(payload.get("contact_value"))
                email = contact_value if method_type == "email" else None
                phone_number = contact_value if method_type == "phone" else None
                if existing_requested_user and is_legacy_placeholder_user(existing_requested_user):
                    user = existing_requested_user
                    user["password"] = payload.get("password", "")
                    user["profile"] = {
                        "displayName": payload.get("display_name", ""),
                        "username": username,
                        "bio": user["profile"].get("bio") or "Welcome to Prime Messaging.",
                        "status": user["profile"].get("status") or "Available",
                        "email": email,
                        "phoneNumber": phone_number,
                        "profilePhotoURL": user["profile"].get("profilePhotoURL"),
                        "socialLink": user["profile"].get("socialLink"),
                    }
                    user["identityMethods"] = build_identity_methods(username, email=email, phone_number=phone_number)
                    user["privacySettings"] = user.get("privacySettings") or default_privacy_settings()
                    sync_user_snapshots(database, user)
                else:
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
                session, access_token, refresh_token = issue_session(database, user_id)
                save_db(database)
                return self.respond(200, session_payload(user, session, access_token, refresh_token))

            if method == "POST" and parsed.path == "/auth/login":
                identifier = str(payload.get("identifier", "")).strip().lower()
                password = str(payload.get("password", ""))
                user = find_user_by_identifier(database, identifier)
                if not user:
                    return self.respond(404, {"error": "user_not_found"})
                if user.get("password") != password:
                    return self.respond(401, {"error": "invalid_credentials"})
                session, access_token, refresh_token = issue_session(database, user["id"])
                save_db(database)
                return self.respond(200, session_payload(user, session, access_token, refresh_token))

            if method == "POST" and parsed.path == "/auth/refresh":
                refresh_token = str(payload.get("refresh_token", "")).strip()
                session = find_session_by_refresh_token(database, refresh_token)
                if not session:
                    return self.respond(401, {"error": "invalid_credentials"})

                refresh_expires_at = parse_iso_datetime(session.get("refreshTokenExpiresAt"))
                if not refresh_expires_at or refresh_expires_at <= datetime.now(timezone.utc):
                    return self.respond(401, {"error": "invalid_credentials"})

                user = find_user(database, session.get("userID"))
                if not user:
                    return self.respond(404, {"error": "user_not_found"})

                access_token, new_refresh_token = rotate_session(session)
                save_db(database)
                return self.respond(200, session_payload(user, session, access_token, new_refresh_token))

            if method == "POST" and parsed.path == "/usernames/claim":
                username = str(payload.get("username", "")).strip().lower()
                current_user, _, auth_error = request_user_with_fallback(
                    database,
                    self.headers,
                    payload_string(payload, "user_id", "userID", "current_user_id", "currentUserID"),
                    create_if_missing=True
                )
                if auth_error == "user_not_found":
                    return self.respond(404, {"error": "user_not_found"})
                if auth_error:
                    return self.respond(401, {"error": auth_error})

                user_id = current_user["id"]
                if username_taken(database, username, user_id):
                    return self.respond(409, {"error": "username_taken"})

                current_user["profile"]["username"] = username
                email = current_user["profile"].get("email")
                phone_number = current_user["profile"].get("phoneNumber")
                current_user["identityMethods"] = build_identity_methods(username, email=email, phone_number=phone_number)
                sync_user_snapshots(database, current_user)
                save_db(database)
                return self.respond(200, {"ok": True})

            if method == "POST" and parsed.path == "/devices/register":
                current_user, _, auth_error = authenticated_user(database, self.headers)
                if auth_error == "user_not_found":
                    return self.respond(404, {"error": "user_not_found"})
                if auth_error:
                    return self.respond(401, {"error": auth_error})

                token = normalized_optional_string(payload.get("token"))
                platform = normalized_optional_string(payload.get("platform")) or "ios"
                if not token:
                    return self.respond(409, {"error": "invalid_device_token"})

                database["deviceTokens"] = [
                    entry for entry in database["deviceTokens"]
                    if entry.get("token") != token
                ]
                database["deviceTokens"].append(
                    {
                        "id": str(uuid.uuid4()),
                        "userID": current_user["id"],
                        "token": token,
                        "platform": platform,
                        "updatedAt": now_iso(),
                    }
                )
                save_db(database)
                log_event(
                    "push.token.registered",
                    user_id=current_user["id"],
                    platform=platform,
                    token_suffix=(token[-8:] if token else None),
                )
                return self.respond(200, {"ok": True})

            if method == "POST" and parsed.path == "/calls":
                caller, _, auth_error = request_user_with_fallback(
                    database,
                    self.headers,
                    payload_string(payload, "caller_id", "callerID", "user_id", "userID"),
                    create_if_missing=True
                )
                if auth_error == "user_not_found":
                    return self.respond(404, {"error": "user_not_found"})
                if auth_error:
                    return self.respond(401, {"error": auth_error})

                caller_id = caller["id"]
                callee_id = normalized_entity_id(payload_string(payload, "callee_id", "calleeID", "other_user_id", "otherUserID"))
                if not callee_id:
                    return self.respond(404, {"error": "user_not_found"})
                if ids_equal(caller_id, callee_id):
                    return self.respond(409, {"error": "invalid_call_operation"})

                callee = find_user(database, callee_id)
                if not callee:
                    return self.respond(404, {"error": "user_not_found"})

                mode = payload_string(payload, "mode", "call_mode", "callMode") or "online"
                if call_requires_saved_contact(database, caller, callee, mode):
                    return self.respond(403, {"error": "call_requires_saved_contact"})
                existing_call = active_call_between(database, caller_id, callee_id, mode)
                if existing_call:
                    return self.respond(200, serialize_call(existing_call, caller_id, database))

                direct_chat = ensure_direct_chat_record(database, caller_id, callee_id, mode)
                call = {
                    "id": str(uuid.uuid4()),
                    "mode": mode,
                    "kind": payload_string(payload, "kind") or "audio",
                    "state": "ringing",
                    "chatID": direct_chat["id"],
                    "callerID": caller_id,
                    "calleeID": callee_id,
                    "createdAt": now_iso(),
                    "updatedAt": now_iso(),
                    "answeredAt": None,
                    "endedAt": None,
                    "endedByUserID": None,
                    "lastEventSequence": 0,
                }
                database["calls"].append(call)
                append_call_event(database, call, "created", sender_id=caller_id)
                save_db(database)
                log_call_dispatch_attempt(database, call)
                return self.respond(200, serialize_call(call, caller_id, database))

            if method == "POST" and parsed.path.startswith("/calls/") and parsed.path.endswith("/accept"):
                call_id = normalized_entity_id(parsed.path.split("/")[2])
                requester, _, auth_error = request_user_with_fallback(
                    database,
                    self.headers,
                    payload_string(payload, "user_id", "userID", "requester_id", "requesterID"),
                    create_if_missing=True
                )
                if auth_error == "user_not_found":
                    return self.respond(404, {"error": "user_not_found"})
                if auth_error:
                    return self.respond(401, {"error": auth_error})

                call = find_call(database, call_id)
                if not call:
                    return self.respond(404, {"error": "call_not_found"})
                if not can_manage_call(call, requester["id"]):
                    return self.respond(403, {"error": "call_permission_denied"})
                if not ids_equal(call.get("calleeID"), requester["id"]) or normalized_optional_string(call.get("state")) != "ringing":
                    return self.respond(409, {"error": "invalid_call_operation"})

                call["state"] = "active"
                call["answeredAt"] = now_iso()
                call["updatedAt"] = call["answeredAt"]
                append_call_event(database, call, "accepted", sender_id=requester["id"])
                save_db(database)
                return self.respond(200, serialize_call(call, requester["id"], database))

            if method == "POST" and parsed.path.startswith("/calls/") and parsed.path.endswith("/reject"):
                call_id = normalized_entity_id(parsed.path.split("/")[2])
                requester, _, auth_error = request_user_with_fallback(
                    database,
                    self.headers,
                    payload_string(payload, "user_id", "userID", "requester_id", "requesterID"),
                    create_if_missing=True
                )
                if auth_error == "user_not_found":
                    return self.respond(404, {"error": "user_not_found"})
                if auth_error:
                    return self.respond(401, {"error": auth_error})

                call = find_call(database, call_id)
                if not call:
                    return self.respond(404, {"error": "call_not_found"})
                if not can_manage_call(call, requester["id"]):
                    return self.respond(403, {"error": "call_permission_denied"})
                if normalized_optional_string(call.get("state")) != "ringing":
                    return self.respond(409, {"error": "invalid_call_operation"})

                call["state"] = "rejected"
                call["endedAt"] = now_iso()
                call["endedByUserID"] = requester["id"]
                call["updatedAt"] = call["endedAt"]
                append_call_event(database, call, "rejected", sender_id=requester["id"])
                save_db(database)
                return self.respond(200, serialize_call(call, requester["id"], database))

            if method == "POST" and parsed.path.startswith("/calls/") and parsed.path.endswith("/hangup"):
                call_id = normalized_entity_id(parsed.path.split("/")[2])
                requester, _, auth_error = request_user_with_fallback(
                    database,
                    self.headers,
                    payload_string(payload, "user_id", "userID", "requester_id", "requesterID"),
                    create_if_missing=True
                )
                if auth_error == "user_not_found":
                    return self.respond(404, {"error": "user_not_found"})
                if auth_error:
                    return self.respond(401, {"error": auth_error})

                call = find_call(database, call_id)
                if not call:
                    return self.respond(404, {"error": "call_not_found"})
                if not can_manage_call(call, requester["id"]):
                    return self.respond(403, {"error": "call_permission_denied"})
                if normalized_optional_string(call.get("state")) not in ACTIVE_CALL_STATES:
                    return self.respond(409, {"error": "invalid_call_operation"})

                if normalized_optional_string(call.get("state")) == "ringing" and ids_equal(call.get("callerID"), requester["id"]):
                    call["state"] = "cancelled"
                elif normalized_optional_string(call.get("state")) == "ringing":
                    call["state"] = "rejected"
                else:
                    call["state"] = "ended"
                call["endedAt"] = now_iso()
                call["endedByUserID"] = requester["id"]
                call["updatedAt"] = call["endedAt"]
                append_call_event(database, call, "ended", sender_id=requester["id"])
                save_db(database)
                return self.respond(200, serialize_call(call, requester["id"], database))

            if method == "POST" and parsed.path.startswith("/calls/") and parsed.path.endswith("/offer"):
                call_id = normalized_entity_id(parsed.path.split("/")[2])
                requester, _, auth_error = request_user_with_fallback(
                    database,
                    self.headers,
                    payload_string(payload, "user_id", "userID", "requester_id", "requesterID"),
                    create_if_missing=True
                )
                if auth_error == "user_not_found":
                    return self.respond(404, {"error": "user_not_found"})
                if auth_error:
                    return self.respond(401, {"error": auth_error})

                call = find_call(database, call_id)
                if not call:
                    return self.respond(404, {"error": "call_not_found"})
                if not can_manage_call(call, requester["id"]):
                    return self.respond(403, {"error": "call_permission_denied"})
                if normalized_optional_string(call.get("state")) not in ACTIVE_CALL_STATES:
                    return self.respond(409, {"error": "invalid_call_operation"})

                event = append_call_event(
                    database,
                    call,
                    "offer",
                    sender_id=requester["id"],
                    payload={"sdp": payload_string(payload, "sdp")}
                )
                save_db(database)
                return self.respond(200, serialize_call_event(event))

            if method == "POST" and parsed.path.startswith("/calls/") and parsed.path.endswith("/answer"):
                call_id = normalized_entity_id(parsed.path.split("/")[2])
                requester, _, auth_error = request_user_with_fallback(
                    database,
                    self.headers,
                    payload_string(payload, "user_id", "userID", "requester_id", "requesterID"),
                    create_if_missing=True
                )
                if auth_error == "user_not_found":
                    return self.respond(404, {"error": "user_not_found"})
                if auth_error:
                    return self.respond(401, {"error": auth_error})

                call = find_call(database, call_id)
                if not call:
                    return self.respond(404, {"error": "call_not_found"})
                if not can_manage_call(call, requester["id"]):
                    return self.respond(403, {"error": "call_permission_denied"})
                if normalized_optional_string(call.get("state")) not in ACTIVE_CALL_STATES:
                    return self.respond(409, {"error": "invalid_call_operation"})

                event = append_call_event(
                    database,
                    call,
                    "answer",
                    sender_id=requester["id"],
                    payload={"sdp": payload_string(payload, "sdp")}
                )
                save_db(database)
                return self.respond(200, serialize_call_event(event))

            if method == "POST" and parsed.path.startswith("/calls/") and parsed.path.endswith("/ice"):
                call_id = normalized_entity_id(parsed.path.split("/")[2])
                requester, _, auth_error = request_user_with_fallback(
                    database,
                    self.headers,
                    payload_string(payload, "user_id", "userID", "requester_id", "requesterID"),
                    create_if_missing=True
                )
                if auth_error == "user_not_found":
                    return self.respond(404, {"error": "user_not_found"})
                if auth_error:
                    return self.respond(401, {"error": auth_error})

                call = find_call(database, call_id)
                if not call:
                    return self.respond(404, {"error": "call_not_found"})
                if not can_manage_call(call, requester["id"]):
                    return self.respond(403, {"error": "call_permission_denied"})
                if normalized_optional_string(call.get("state")) not in ACTIVE_CALL_STATES:
                    return self.respond(409, {"error": "invalid_call_operation"})

                event = append_call_event(
                    database,
                    call,
                    "ice",
                    sender_id=requester["id"],
                    payload={
                        "candidate": payload_string(payload, "candidate"),
                        "sdpMid": payload_string(payload, "sdp_mid", "sdpMid"),
                        "sdpMLineIndex": payload.get("sdp_mline_index", payload.get("sdpMLineIndex")),
                    }
                )
                save_db(database)
                return self.respond(200, serialize_call_event(event))

            if method == "PATCH" and parsed.path.startswith("/users/") and parsed.path.endswith("/profile"):
                user_id = normalized_entity_id(parsed.path.split("/")[2])
                current_user, _, auth_error = request_user_with_fallback(
                    database,
                    self.headers,
                    payload_string(payload, "user_id", "userID", "current_user_id", "currentUserID") or user_id,
                    create_if_missing=True
                )
                if auth_error == "user_not_found":
                    return self.respond(404, {"error": "user_not_found"})
                if auth_error:
                    return self.respond(401, {"error": auth_error})
                if not ids_equal(current_user["id"], user_id):
                    return self.respond(403, {"error": "edit_not_allowed"})

                username = str(payload.get("username", current_user["profile"]["username"])).strip().lower()
                if username_taken(database, username, user_id):
                    return self.respond(409, {"error": "username_taken"})

                email = normalized_optional_string(payload.get("email"))
                phone_number = normalized_optional_string(payload.get("phone_number"))
                current_user["profile"] = {
                    "displayName": payload.get("display_name", current_user["profile"]["displayName"]),
                    "username": username,
                    "bio": payload.get("bio", current_user["profile"]["bio"]),
                    "status": payload.get("status", current_user["profile"]["status"]),
                    "email": email,
                    "phoneNumber": phone_number,
                    "profilePhotoURL": normalized_optional_url_string(
                        payload.get("profile_photo_url", current_user["profile"].get("profilePhotoURL"))
                    ),
                    "socialLink": normalized_optional_url_string(payload.get("social_link")),
                }
                current_user["identityMethods"] = build_identity_methods(username, email=email, phone_number=phone_number)
                sync_user_snapshots(database, current_user)
                save_db(database)
                return self.respond(200, serialize_user(current_user))

            if method == "PATCH" and parsed.path.startswith("/users/") and parsed.path.endswith("/privacy"):
                user_id = normalized_entity_id(parsed.path.split("/")[2])
                current_user, _, auth_error = request_user_with_fallback(
                    database,
                    self.headers,
                    payload_string(payload, "user_id", "userID", "current_user_id", "currentUserID") or user_id,
                    create_if_missing=True
                )
                if auth_error == "user_not_found":
                    return self.respond(404, {"error": "user_not_found"})
                if auth_error:
                    return self.respond(401, {"error": auth_error})
                if not ids_equal(current_user["id"], user_id):
                    return self.respond(403, {"error": "edit_not_allowed"})

                incoming = payload.get("privacy_settings")
                if not isinstance(incoming, dict):
                    incoming = payload

                updated_settings = default_privacy_settings()
                updated_settings.update(current_user.get("privacySettings") or {})
                for key in default_privacy_settings().keys():
                    if key in incoming:
                        updated_settings[key] = bool(incoming.get(key))

                current_user["privacySettings"] = updated_settings
                save_db(database)
                return self.respond(200, updated_settings)

            if method == "PATCH" and parsed.path.startswith("/users/") and parsed.path.endswith("/password"):
                user_id = normalized_entity_id(parsed.path.split("/")[2])
                current_user, _, auth_error = request_user_with_fallback(
                    database,
                    self.headers,
                    payload_string(payload, "user_id", "userID", "current_user_id", "currentUserID") or user_id,
                    create_if_missing=True
                )
                if auth_error == "user_not_found":
                    return self.respond(404, {"error": "user_not_found"})
                if auth_error:
                    return self.respond(401, {"error": auth_error})
                if not ids_equal(current_user["id"], user_id):
                    return self.respond(403, {"error": "edit_not_allowed"})

                current_user["password"] = str(payload.get("password", "")).strip()
                save_db(database)
                return self.respond(200, {"ok": True})

            if method == "POST" and parsed.path.startswith("/users/") and parsed.path.endswith("/avatar"):
                user_id = normalized_entity_id(parsed.path.split("/")[2])
                current_user, _, auth_error = request_user_with_fallback(
                    database,
                    self.headers,
                    payload_string(payload, "user_id", "userID", "current_user_id", "currentUserID") or user_id,
                    create_if_missing=True
                )
                if auth_error == "user_not_found":
                    return self.respond(404, {"error": "user_not_found"})
                if auth_error:
                    return self.respond(401, {"error": auth_error})
                if not ids_equal(current_user["id"], user_id):
                    return self.respond(403, {"error": "edit_not_allowed"})

                remove_file_for_url(current_user["profile"].get("profilePhotoURL"), AVATAR_DIR)
                raw = base64.b64decode(payload.get("image_base64", ""))
                avatar_name = f"{user_id}.png"
                avatar_path = os.path.join(AVATAR_DIR, avatar_name)
                with open(avatar_path, "wb") as file:
                    file.write(raw)

                current_user["profile"]["profilePhotoURL"] = f"{self.base_url()}/avatars/{avatar_name}"
                save_db(database)
                return self.respond(200, serialize_user(current_user))

            if method == "DELETE" and parsed.path.startswith("/users/") and parsed.path.endswith("/avatar"):
                user_id = normalized_entity_id(parsed.path.split("/")[2])
                current_user, _, auth_error = request_user_with_fallback(
                    database,
                    self.headers,
                    payload_string(payload, "user_id", "userID", "current_user_id", "currentUserID") or user_id,
                    create_if_missing=True
                )
                if auth_error == "user_not_found":
                    return self.respond(404, {"error": "user_not_found"})
                if auth_error:
                    return self.respond(401, {"error": auth_error})
                if not ids_equal(current_user["id"], user_id):
                    return self.respond(403, {"error": "delete_not_allowed"})

                remove_file_for_url(current_user["profile"].get("profilePhotoURL"), AVATAR_DIR)
                current_user["profile"]["profilePhotoURL"] = None
                save_db(database)
                return self.respond(200, serialize_user(current_user))

            if method == "DELETE" and parsed.path.startswith("/users/") and "/avatar" not in parsed.path and "/profile" not in parsed.path and "/password" not in parsed.path:
                user_id = normalized_entity_id(parsed.path.split("/")[2])
                current_user, _, auth_error = request_user_with_fallback(
                    database,
                    self.headers,
                    payload_string(payload, "user_id", "userID", "current_user_id", "currentUserID") or user_id,
                    create_if_missing=False
                )
                if auth_error == "user_not_found":
                    return self.respond(404, {"error": "user_not_found"})
                if auth_error:
                    return self.respond(401, {"error": auth_error})
                if not ids_equal(current_user["id"], user_id):
                    return self.respond(403, {"error": "delete_not_allowed"})

                if delete_user_account(database, user_id) is False:
                    return self.respond(404, {"error": "user_not_found"})

                save_db(database)
                return self.respond(200, {"ok": True})

            if method == "POST" and parsed.path == "/chats/direct":
                current_user, _, auth_error = request_user_with_fallback(
                    database,
                    self.headers,
                    payload_string(
                        payload,
                        "current_user_id",
                        "currentUserID",
                        "user_id",
                        "userID",
                        "requester_id",
                        "requesterID",
                        "owner_id",
                        "ownerID"
                    ),
                    create_if_missing=True
                )
                if auth_error == "user_not_found":
                    return self.respond(404, {"error": "user_not_found"})
                if auth_error:
                    return self.respond(401, {"error": auth_error})

                current_user_id = current_user["id"]
                other_user_id = normalized_entity_id(payload_string(
                    payload,
                    "other_user_id",
                    "otherUserID",
                    "contact_id",
                    "contactID",
                    "peer_id",
                    "peerID",
                    "target_user_id",
                    "targetUserID"
                ) or "")
                mode = (
                    payload_string(payload, "mode", "chat_mode", "chatMode")
                    or "online"
                )
                other_user = find_user(database, other_user_id)
                if not other_user:
                    return self.respond(404, {"error": "user_not_found"})
                if ids_equal(current_user_id, other_user_id):
                    return self.respond(409, {"error": "invalid_direct_chat"})
                cached_title = resolved_user_display_name(other_user) or other_user["profile"]["username"] or "Missing User"
                cached_subtitle = f"@{other_user['profile']['username']}"

                existing = next(
                    (
                        chat for chat in database["chats"]
                        if chat["type"] == "direct"
                        and set(unique_entity_ids(chat.get("participantIDs") or [])) == {current_user_id, other_user_id}
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
                current_user, _, auth_error = request_user_with_fallback(
                    database,
                    self.headers,
                    payload.get("owner_id"),
                    create_if_missing=True
                )
                if auth_error == "user_not_found":
                    return self.respond(404, {"error": "user_not_found"})
                if auth_error:
                    return self.respond(401, {"error": auth_error})

                owner_id = current_user["id"]
                title = str(payload.get("title", "")).strip() or "New Group"
                member_ids = [
                    normalized_entity_id(member_id)
                    for member_id in payload.get("member_ids", [])
                    if normalized_entity_id(member_id)
                ]
                mode = str(payload.get("mode", "online")).strip()

                participant_ids = [owner_id]
                for member_id in member_ids:
                    if member_id not in participant_ids:
                        participant_ids.append(member_id)

                if any(find_user(database, participant_id) is None for participant_id in participant_ids):
                    return self.respond(404, {"error": "user_not_found"})

                group_id = str(uuid.uuid4())
                group = {
                    "id": group_id,
                    "title": title,
                    "photoURL": None,
                    "ownerID": owner_id,
                    "members": [
                        group_member_payload(
                            database,
                            member_id,
                            "owner" if member_id == owner_id else "member",
                        )
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

            if method == "PATCH" and parsed.path.startswith("/chats/") and parsed.path.endswith("/group"):
                chat_id = normalized_entity_id(parsed.path.split("/")[2])
                requester, _, auth_error = request_user_with_fallback(
                    database,
                    self.headers,
                    payload.get("requester_id"),
                    create_if_missing=True
                )
                if auth_error == "user_not_found":
                    return self.respond(404, {"error": "user_not_found"})
                if auth_error:
                    return self.respond(401, {"error": auth_error})
                requester_id = requester["id"]
                updated_title = normalized_optional_string(payload.get("title"))

                chat = find_chat(database, chat_id)
                if not chat:
                    return self.respond(404, {"error": "chat_not_found"})
                if chat.get("type") != "group":
                    return self.respond(409, {"error": "invalid_group_chat"})
                if not can_manage_group(chat, requester_id):
                    return self.respond(403, {"error": "group_permission_denied"})
                if not updated_title:
                    return self.respond(409, {"error": "invalid_group_operation"})

                chat["group"]["title"] = updated_title
                chat["cachedTitle"] = updated_title
                save_db(database)
                return self.respond(200, serialize_chat(chat, requester_id, database))

            if method == "POST" and parsed.path.startswith("/chats/") and parsed.path.endswith("/group/avatar"):
                chat_id = normalized_entity_id(parsed.path.split("/")[2])
                requester, _, auth_error = request_user_with_fallback(
                    database,
                    self.headers,
                    payload.get("requester_id"),
                    create_if_missing=True
                )
                if auth_error == "user_not_found":
                    return self.respond(404, {"error": "user_not_found"})
                if auth_error:
                    return self.respond(401, {"error": auth_error})
                requester_id = requester["id"]

                chat = find_chat(database, chat_id)
                if not chat:
                    return self.respond(404, {"error": "chat_not_found"})
                if chat.get("type") != "group":
                    return self.respond(409, {"error": "invalid_group_chat"})
                if not can_manage_group(chat, requester_id):
                    return self.respond(403, {"error": "group_permission_denied"})

                remove_file_for_url((chat.get("group") or {}).get("photoURL"), AVATAR_DIR)
                raw = base64.b64decode(payload.get("image_base64", ""))
                avatar_name = f"group-{chat_id}.jpg"
                avatar_path = os.path.join(AVATAR_DIR, avatar_name)
                with open(avatar_path, "wb") as file:
                    file.write(raw)

                chat["group"]["photoURL"] = f"{self.base_url()}/avatars/{avatar_name}"
                save_db(database)
                return self.respond(200, serialize_chat(chat, requester_id, database))

            if method == "DELETE" and parsed.path.startswith("/chats/") and parsed.path.endswith("/group/avatar"):
                chat_id = normalized_entity_id(parsed.path.split("/")[2])
                requester, _, auth_error = request_user_with_fallback(
                    database,
                    self.headers,
                    payload.get("requester_id"),
                    create_if_missing=True
                )
                if auth_error == "user_not_found":
                    return self.respond(404, {"error": "user_not_found"})
                if auth_error:
                    return self.respond(401, {"error": auth_error})
                requester_id = requester["id"]

                chat = find_chat(database, chat_id)
                if not chat:
                    return self.respond(404, {"error": "chat_not_found"})
                if chat.get("type") != "group":
                    return self.respond(409, {"error": "invalid_group_chat"})
                if not can_manage_group(chat, requester_id):
                    return self.respond(403, {"error": "group_permission_denied"})

                remove_file_for_url((chat.get("group") or {}).get("photoURL"), AVATAR_DIR)
                chat["group"]["photoURL"] = None
                save_db(database)
                return self.respond(200, serialize_chat(chat, requester_id, database))

            if method == "POST" and parsed.path.startswith("/chats/") and parsed.path.endswith("/group/members"):
                chat_id = normalized_entity_id(parsed.path.split("/")[2])
                requester, _, auth_error = request_user_with_fallback(
                    database,
                    self.headers,
                    payload.get("requester_id"),
                    create_if_missing=True
                )
                if auth_error == "user_not_found":
                    return self.respond(404, {"error": "user_not_found"})
                if auth_error:
                    return self.respond(401, {"error": auth_error})
                requester_id = requester["id"]
                incoming_member_ids = [
                    normalized_entity_id(member_id)
                    for member_id in payload.get("member_ids", [])
                    if normalized_entity_id(member_id)
                ]

                chat = find_chat(database, chat_id)
                if not chat:
                    return self.respond(404, {"error": "chat_not_found"})
                if chat.get("type") != "group":
                    return self.respond(409, {"error": "invalid_group_chat"})
                if not can_manage_group(chat, requester_id):
                    return self.respond(403, {"error": "group_permission_denied"})

                group = chat.get("group") or {}
                members = group.get("members") or []
                participant_ids = chat.get("participantIDs") or []

                for member_id in incoming_member_ids:
                    if not find_user(database, member_id):
                        return self.respond(404, {"error": "user_not_found"})
                    if member_id in participant_ids:
                        continue

                    participant_ids.append(member_id)
                    members.append(group_member_payload(database, member_id, "member"))

                group["members"] = members
                chat["participantIDs"] = participant_ids
                chat["cachedSubtitle"] = f"{len(members)} members"
                save_db(database)
                return self.respond(200, serialize_chat(chat, requester_id, database))

            if method == "DELETE" and parsed.path.startswith("/chats/") and "/group/members/" in parsed.path:
                path_components = parsed.path.strip("/").split("/")
                if len(path_components) < 5:
                    return self.respond(404, {"error": "not_found"})

                chat_id = normalized_entity_id(path_components[1])
                member_user_id = normalized_entity_id(path_components[4])
                requester, _, auth_error = request_user_with_fallback(
                    database,
                    self.headers,
                    payload.get("requester_id"),
                    create_if_missing=True
                )
                if auth_error == "user_not_found":
                    return self.respond(404, {"error": "user_not_found"})
                if auth_error:
                    return self.respond(401, {"error": auth_error})
                requester_id = requester["id"]

                chat = find_chat(database, chat_id)
                if not chat:
                    return self.respond(404, {"error": "chat_not_found"})
                if chat.get("type") != "group":
                    return self.respond(409, {"error": "invalid_group_chat"})
                if not can_manage_group(chat, requester_id):
                    return self.respond(403, {"error": "group_permission_denied"})
                if not member_user_id or not any(ids_equal(member_user_id, participant_id) for participant_id in (chat.get("participantIDs") or [])):
                    return self.respond(404, {"error": "user_not_found"})
                if not can_remove_group_member(chat, requester_id, member_user_id):
                    return self.respond(409, {"error": "invalid_group_operation"})

                if remove_group_member(chat, member_user_id) is False:
                    return self.respond(409, {"error": "invalid_group_operation"})

                save_db(database)
                return self.respond(200, serialize_chat(chat, requester_id, database))

            if method == "PATCH" and parsed.path.startswith("/chats/") and "/group/members/" in parsed.path and parsed.path.endswith("/role"):
                path_components = parsed.path.strip("/").split("/")
                if len(path_components) < 6:
                    return self.respond(404, {"error": "not_found"})

                chat_id = normalized_entity_id(path_components[1])
                member_user_id = normalized_entity_id(path_components[4])
                requester, _, auth_error = request_user_with_fallback(
                    database,
                    self.headers,
                    payload.get("requester_id"),
                    create_if_missing=True
                )
                if auth_error == "user_not_found":
                    return self.respond(404, {"error": "user_not_found"})
                if auth_error:
                    return self.respond(401, {"error": auth_error})
                requester_id = requester["id"]

                chat = find_chat(database, chat_id)
                if not chat:
                    return self.respond(404, {"error": "chat_not_found"})
                if chat.get("type") != "group":
                    return self.respond(409, {"error": "invalid_group_chat"})

                new_role = normalized_optional_string(payload.get("role"))
                if not can_update_group_member_role(chat, requester_id, member_user_id, new_role):
                    return self.respond(403, {"error": "group_permission_denied"})

                if update_group_member_role(chat, member_user_id, new_role) is False:
                    return self.respond(409, {"error": "invalid_group_operation"})

                save_db(database)
                return self.respond(200, serialize_chat(chat, requester_id, database))

            if method == "POST" and parsed.path.startswith("/chats/") and parsed.path.endswith("/group/leave"):
                chat_id = normalized_entity_id(parsed.path.split("/")[2])
                requester, _, auth_error = request_user_with_fallback(
                    database,
                    self.headers,
                    payload.get("requester_id"),
                    create_if_missing=True
                )
                if auth_error == "user_not_found":
                    return self.respond(404, {"error": "user_not_found"})
                if auth_error:
                    return self.respond(401, {"error": auth_error})
                requester_id = requester["id"]

                chat = find_chat(database, chat_id)
                if not chat:
                    return self.respond(404, {"error": "chat_not_found"})
                if chat.get("type") != "group":
                    return self.respond(409, {"error": "invalid_group_chat"})
                if find_group_member(chat, requester_id) is None:
                    return self.respond(403, {"error": "sender_not_in_chat"})
                if leave_group(chat, requester_id) is False:
                    return self.respond(409, {"error": "invalid_group_operation"})

                save_db(database)
                return self.respond(200, {"ok": True})

            if method == "POST" and parsed.path.startswith("/chats/") and parsed.path.endswith("/read"):
                chat_id = normalized_entity_id(parsed.path.split("/")[2])
                reader, _, auth_error = request_user_with_fallback(
                    database,
                    self.headers,
                    payload.get("reader_id"),
                    create_if_missing=True
                )
                if auth_error == "user_not_found":
                    return self.respond(404, {"error": "user_not_found"})
                if auth_error:
                    return self.respond(401, {"error": auth_error})

                chat = find_chat(database, chat_id)
                if not chat:
                    return self.respond(404, {"error": "chat_not_found"})
                if not any(ids_equal(reader["id"], participant_id) for participant_id in (chat.get("participantIDs") or [])):
                    return self.respond(403, {"error": "sender_not_in_chat"})

                did_update = mark_chat_read(chat, database, reader["id"])
                if did_update:
                    save_db(database)
                return self.respond(200, {"ok": True})

            if method == "POST" and parsed.path == "/messages/send":
                chat_id = normalized_entity_id(payload.get("chat_id"))
                sender, _, auth_error = request_user_with_fallback(
                    database,
                    self.headers,
                    payload.get("sender_id"),
                    create_if_missing=True
                )
                if auth_error == "user_not_found":
                    return self.respond(404, {"error": "user_not_found"})
                if auth_error:
                    return self.respond(401, {"error": auth_error})

                sender_id = sender["id"]
                chat = find_chat(database, chat_id)
                if not chat:
                    return self.respond(404, {"error": "chat_not_found"})

                if not any(ids_equal(sender_id, participant_id) for participant_id in (chat.get("participantIDs") or [])):
                    return self.respond(403, {"error": "sender_not_in_chat"})

                sender_display_name = normalized_optional_string(payload.get("sender_display_name")) or resolved_user_display_name(sender)
                text = normalized_optional_string(payload.get("text"))
                mode = str(payload.get("mode", "online")).strip()
                if chat.get("mode") != mode:
                    return self.respond(409, {"error": "chat_mode_mismatch"})

                kind = str(payload.get("kind", "text")).strip() or "text"
                reply_to_message_id = normalized_entity_id(payload.get("reply_to_message_id"))
                reply_target_message = find_message(database, reply_to_message_id) if reply_to_message_id else None
                if reply_to_message_id and not reply_target_message:
                    reply_to_message_id = None
                reply_preview = sanitized_reply_preview(payload.get("reply_preview"))
                if reply_to_message_id and not reply_preview and reply_target_message:
                    reply_preview = {
                        "senderID": reply_target_message.get("senderID"),
                        "senderDisplayName": sender_display_name_for(reply_target_message, database),
                        "previewText": message_preview(reply_target_message),
                    }
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
                    "chatID": chat["id"],
                    "senderID": sender_id,
                    "senderDisplayName": sender_display_name,
                    "mode": mode,
                    "kind": kind,
                    "text": text,
                    "attachments": attachments,
                    "replyToMessageID": reply_to_message_id,
                    "replyPreview": reply_preview,
                    "voiceMessage": voice_message,
                    "status": "sent",
                    "createdAt": now_iso(),
                    "editedAt": None,
                    "deletedForEveryoneAt": None,
                    "reactions": [],
                }
                backfill_group_member_snapshots(chat, database)
                database["messages"].append(message)
                save_db(database)
                log_push_dispatch_attempt(database, chat, message)
                return self.respond(200, serialize_message(message, database))

            if method == "POST" and parsed.path.startswith("/messages/") and parsed.path.endswith("/reactions"):
                message_id = normalized_entity_id(parsed.path.split("/")[2])
                chat_id = normalized_entity_id(payload.get("chat_id"))
                requester, _, auth_error = request_user_with_fallback(
                    database,
                    self.headers,
                    payload.get("user_id"),
                    create_if_missing=True
                )
                if auth_error == "user_not_found":
                    return self.respond(404, {"error": "user_not_found"})
                if auth_error:
                    return self.respond(401, {"error": auth_error})
                requester_id = requester["id"]
                emoji = normalized_optional_string(payload.get("emoji"))

                if not emoji:
                    return self.respond(409, {"error": "empty_message"})

                message = find_message(database, message_id)
                if not message:
                    return self.respond(404, {"error": "message_not_found"})
                if chat_id and not ids_equal(message["chatID"], chat_id):
                    return self.respond(404, {"error": "message_not_found"})
                chat = find_chat(database, message["chatID"])
                if not chat or not any(ids_equal(requester_id, participant_id) for participant_id in (chat.get("participantIDs") or [])):
                    return self.respond(403, {"error": "sender_not_in_chat"})
                if message.get("deletedForEveryoneAt"):
                    return self.respond(409, {"error": "message_deleted"})

                reactions = message.setdefault("reactions", [])
                target_reaction = next(
                    (reaction for reaction in reactions if normalized_optional_string(reaction.get("emoji")) == emoji),
                    None,
                )

                if target_reaction:
                    existing_user_ids = unique_entity_ids(target_reaction.get("userIDs") or [])
                    user_ids = [
                        reaction_user_id
                        for reaction_user_id in existing_user_ids
                        if not ids_equal(reaction_user_id, requester_id)
                    ]
                    if len(user_ids) == len(existing_user_ids):
                        user_ids.append(requester_id)
                    target_reaction["userIDs"] = user_ids
                    if not user_ids:
                        reactions[:] = [
                            reaction
                            for reaction in reactions
                            if normalized_optional_string(reaction.get("emoji")) != emoji
                        ]
                else:
                    reactions.append(
                        {
                            "id": str(uuid.uuid4()),
                            "emoji": emoji,
                            "userIDs": [requester_id],
                        }
                    )

                save_db(database)
                return self.respond(200, serialize_message(message, database))

            if method == "PATCH" and parsed.path.startswith("/messages/"):
                message_id = normalized_entity_id(parsed.path.split("/")[2])
                chat_id = normalized_entity_id(payload.get("chat_id"))
                editor, _, auth_error = request_user_with_fallback(
                    database,
                    self.headers,
                    payload.get("editor_id"),
                    create_if_missing=True
                )
                if auth_error == "user_not_found":
                    return self.respond(404, {"error": "user_not_found"})
                if auth_error:
                    return self.respond(401, {"error": auth_error})
                editor_id = editor["id"]
                updated_text = normalized_optional_string(payload.get("text"))

                message = find_message(database, message_id)
                if not message:
                    return self.respond(404, {"error": "message_not_found"})
                if chat_id and not ids_equal(message["chatID"], chat_id):
                    return self.respond(404, {"error": "message_not_found"})
                chat = find_chat(database, message["chatID"])
                if not chat or not any(ids_equal(editor_id, participant_id) for participant_id in (chat.get("participantIDs") or [])):
                    return self.respond(403, {"error": "sender_not_in_chat"})
                if not ids_equal(message["senderID"], editor_id):
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
                message_id = normalized_entity_id(parsed.path.split("/")[2])
                chat_id = normalized_entity_id(payload.get("chat_id"))
                requester, _, auth_error = request_user_with_fallback(
                    database,
                    self.headers,
                    payload.get("requester_id"),
                    create_if_missing=True
                )
                if auth_error == "user_not_found":
                    return self.respond(404, {"error": "user_not_found"})
                if auth_error:
                    return self.respond(401, {"error": auth_error})
                requester_id = requester["id"]

                message = find_message(database, message_id)
                if not message:
                    return self.respond(404, {"error": "message_not_found"})
                if chat_id and not ids_equal(message["chatID"], chat_id):
                    return self.respond(404, {"error": "message_not_found"})
                chat = find_chat(database, message["chatID"])
                if not chat or not any(ids_equal(requester_id, participant_id) for participant_id in (chat.get("participantIDs") or [])):
                    return self.respond(403, {"error": "sender_not_in_chat"})
                if not ids_equal(message["senderID"], requester_id):
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
        self.send_header("Content-Type", avatar_content_type(avatar_name))
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
