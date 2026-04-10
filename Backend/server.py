#!/usr/bin/env python3
import base64
import hashlib
import hmac
import json
import mimetypes
import os
import shutil
import subprocess
import threading
import time
import uuid
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

try:
    import httpx
except Exception:
    httpx = None

try:
    import jwt
except Exception:
    jwt = None

try:
    import boto3
    from botocore.config import Config as BotocoreConfig
    from botocore.exceptions import ClientError
except Exception:
    boto3 = None
    BotocoreConfig = None
    ClientError = Exception


BASE_DIR = os.path.dirname(__file__)
WEBSITE_DIR = os.path.abspath(os.path.join(BASE_DIR, "..", "Website"))
DATA_DIR = os.path.join(BASE_DIR, "data")
DATA_FILE = os.path.join(DATA_DIR, "database.json")
AVATAR_DIR = os.path.join(DATA_DIR, "avatars")
MEDIA_DIR = os.path.join(DATA_DIR, "media")
HOST = os.environ.get("PRIME_MESSAGING_HOST", "0.0.0.0")
PORT = int(os.environ.get("PRIME_MESSAGING_PORT") or os.environ.get("PORT", "8080"))
SERVER_BUILD_ID = (os.environ.get("PRIME_MESSAGING_SERVER_BUILD_ID", "") or "").strip() or "unset"
SERVER_STARTED_AT = datetime.now(timezone.utc).isoformat()
try:
    SERVER_CODE_MTIME = datetime.fromtimestamp(os.path.getmtime(__file__), tz=timezone.utc).isoformat()
except Exception:
    SERVER_CODE_MTIME = None
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
DEFAULT_OTP_CODE = "000000"
GUEST_ACCOUNT_LIFETIME_SECONDS = 60 * 60 * 24 * 3
ADMIN_LOGIN = (os.environ.get("PRIME_MESSAGING_ADMIN_LOGIN", "admin") or "admin").strip().lower()
ADMIN_PASSWORD = os.environ.get("PRIME_MESSAGING_ADMIN_PASSWORD", "Prime-admin-very-secret-2026").strip()
ADMIN_TOKEN = os.environ.get("PRIME_MESSAGING_ADMIN_TOKEN", "").strip()
ADMIN_USERNAME = (os.environ.get("PRIME_MESSAGING_ADMIN_USERNAME", "mihran") or "mihran").strip().lower()
APNS_KEY_PATH = os.environ.get("PRIME_MESSAGING_APNS_KEY_PATH", "").strip()
APNS_KEY_P8 = os.environ.get("PRIME_MESSAGING_APNS_KEY_P8", "").strip()
APNS_KEY_ID = os.environ.get("PRIME_MESSAGING_APNS_KEY_ID", "").strip()
APNS_TEAM_ID = os.environ.get("PRIME_MESSAGING_APNS_TEAM_ID", "").strip()
APNS_TOPIC = os.environ.get("PRIME_MESSAGING_APNS_TOPIC", "").strip()
APNS_VOIP_TOPIC = os.environ.get("PRIME_MESSAGING_APNS_VOIP_TOPIC", "").strip()
APNS_ENVIRONMENT = (os.environ.get("PRIME_MESSAGING_APNS_ENVIRONMENT", "auto") or "auto").strip().lower()
CALL_ICE_SERVERS_RAW = os.environ.get("PRIME_MESSAGING_CALL_ICE_SERVERS_JSON", "").strip()
MEDIA_STORAGE_BACKEND = (os.environ.get("PRIME_MESSAGING_MEDIA_STORAGE_BACKEND", "local") or "local").strip().lower()
MEDIA_S3_BUCKET = os.environ.get("PRIME_MESSAGING_MEDIA_S3_BUCKET", "").strip()
MEDIA_S3_REGION = os.environ.get("PRIME_MESSAGING_MEDIA_S3_REGION", "").strip()
MEDIA_S3_ENDPOINT_URL = os.environ.get("PRIME_MESSAGING_MEDIA_S3_ENDPOINT_URL", "").strip()
MEDIA_S3_ACCESS_KEY_ID = os.environ.get("PRIME_MESSAGING_MEDIA_S3_ACCESS_KEY_ID", "").strip()
MEDIA_S3_SECRET_ACCESS_KEY = os.environ.get("PRIME_MESSAGING_MEDIA_S3_SECRET_ACCESS_KEY", "").strip()
MEDIA_S3_PREFIX = (os.environ.get("PRIME_MESSAGING_MEDIA_S3_PREFIX", "media") or "media").strip().strip("/")
MEDIA_KEEP_LOCAL_COPY = (
    (os.environ.get("PRIME_MESSAGING_MEDIA_KEEP_LOCAL_COPY", "0") or "0").strip().lower()
    in {"1", "true", "yes"}
)
if APNS_ENVIRONMENT not in {"production", "development", "auto"}:
    APNS_ENVIRONMENT = "auto"
try:
    APNS_TIMEOUT_SECONDS = max(1.0, float(os.environ.get("PRIME_MESSAGING_APNS_TIMEOUT_SECONDS", "10")))
except ValueError:
    APNS_TIMEOUT_SECONDS = 10.0
APNS_JWT_TTL_SECONDS = 50 * 60


def parse_call_ice_servers(raw_value):
    default_servers = [
        {"urls": ["stun:stun.l.google.com:19302"]},
        {
            "urls": [
                "turn:openrelay.metered.ca:80?transport=udp",
                "turn:openrelay.metered.ca:443?transport=tcp",
                "turns:openrelay.metered.ca:443?transport=tcp",
            ],
            "username": "openrelayproject",
            "credential": "openrelayproject",
        },
    ]
    if not raw_value:
        return default_servers

    try:
        parsed = json.loads(raw_value)
    except Exception:
        return default_servers

    if isinstance(parsed, dict):
        parsed = [parsed]
    if not isinstance(parsed, list):
        return default_servers

    normalized_servers = []
    for server in parsed:
        if not isinstance(server, dict):
            continue

        urls = server.get("urls")
        if isinstance(urls, str):
            urls = [urls]
        if not isinstance(urls, list):
            continue
        clean_urls = [str(url).strip() for url in urls if str(url).strip()]
        if not clean_urls:
            continue

        normalized_servers.append(
            {
                "urls": clean_urls,
                "username": (server.get("username") or "").strip() or None,
                "credential": (server.get("credential") or "").strip() or None,
            }
        )

    return normalized_servers or default_servers


CALL_ICE_SERVERS = parse_call_ice_servers(CALL_ICE_SERVERS_RAW)


def call_ice_capabilities(ice_servers):
    has_turn = False
    has_turns = False
    for server in ice_servers:
        urls = server.get("urls") if isinstance(server, dict) else None
        if not isinstance(urls, list):
            continue
        for raw_url in urls:
            value = (str(raw_url).strip().lower() if raw_url is not None else "")
            if value.startswith("turn:"):
                has_turn = True
            if value.startswith("turns:"):
                has_turns = True
    return {
        "count": len(ice_servers),
        "hasTurn": has_turn,
        "hasTurns": has_turns,
    }


def log_event(name, **fields):
    payload = {
        "timestamp": now_iso(),
        "event": name,
        **fields,
    }
    print(json.dumps(payload, ensure_ascii=False), flush=True)


class APNsProvider:
    INVALID_TOKEN_REASONS = {"BadDeviceToken", "Unregistered", "DeviceTokenNotForTopic"}
    RETRYABLE_ENVIRONMENT_REASONS = {
        "BadDeviceToken",
        "DeviceTokenNotForTopic",
        "BadEnvironmentKeyInToken",
        "BadCertificateEnvironment",
    }

    def __init__(
        self,
        key_path,
        key_content,
        key_id,
        team_id,
        topic,
        environment,
        timeout_seconds=10.0,
    ):
        self.key_path = key_path
        self.key_content = key_content
        self.key_id = key_id
        self.team_id = team_id
        self.topic = topic
        self.environment = environment if environment in {"production", "development", "auto"} else "auto"
        self.timeout_seconds = timeout_seconds
        self._token_lock = threading.Lock()
        self._cached_bearer_token = None
        self._cached_bearer_expiry = 0
        self._private_key = None
        self.configuration_error = self._load_configuration_error()

    @property
    def base_url(self):
        if self.environment == "development":
            return "https://api.sandbox.push.apple.com"
        return "https://api.push.apple.com"

    def base_url_for_environment(self, environment):
        return "https://api.sandbox.push.apple.com" if environment == "development" else "https://api.push.apple.com"

    def environments_to_try(self):
        if self.environment == "auto":
            return ["production", "development"]
        if self.environment == "development":
            return ["development", "production"]
        return ["production", "development"]

    @property
    def is_configured(self):
        return self.configuration_error is None

    def _load_configuration_error(self):
        if httpx is None or jwt is None:
            return "missing_dependencies_httpx_or_pyjwt"

        if not self.key_id:
            return "missing_apns_key_id"
        if not self.team_id:
            return "missing_apns_team_id"
        if not self.topic and not APNS_VOIP_TOPIC:
            return "missing_apns_topic"
        if self.key_content:
            self._private_key = self.key_content.replace("\\n", "\n").strip()
        else:
            if not self.key_path:
                return "missing_apns_key_path_or_inline_key"
            if os.path.isfile(self.key_path) is False:
                return "apns_key_file_not_found"

            try:
                with open(self.key_path, "r", encoding="utf-8") as file:
                    self._private_key = file.read().strip()
            except OSError:
                return "failed_to_read_apns_key_file"

        if not self._private_key:
            return "empty_apns_key_file"
        return None

    def _authorization_header_value(self):
        now_seconds = int(time.time())
        with self._token_lock:
            if self._cached_bearer_token and now_seconds < self._cached_bearer_expiry:
                return f"bearer {self._cached_bearer_token}"

            encoded = jwt.encode(
                {"iss": self.team_id, "iat": now_seconds},
                self._private_key,
                algorithm="ES256",
                headers={"alg": "ES256", "kid": self.key_id},
            )
            token = encoded if isinstance(encoded, str) else encoded.decode("utf-8")
            self._cached_bearer_token = token
            self._cached_bearer_expiry = now_seconds + APNS_JWT_TTL_SECONDS
            return f"bearer {token}"

    def send_notification(
        self,
        device_token,
        payload,
        push_type="alert",
        priority="10",
        collapse_id=None,
        topic_override=None,
    ):
        if not self.is_configured:
            return {
                "ok": False,
                "status": None,
                "reason": self.configuration_error,
                "apns_id": None,
            }

        request_headers = {
            "authorization": self._authorization_header_value(),
            "apns-topic": topic_override or self.topic,
            "apns-push-type": push_type,
            "apns-priority": priority,
            "content-type": "application/json",
        }
        if collapse_id:
            request_headers["apns-collapse-id"] = str(collapse_id)[:64]

        last_result = {
            "ok": False,
            "status": None,
            "reason": "unknown",
            "apns_id": None,
            "environment": None,
        }

        for index, environment in enumerate(self.environments_to_try()):
            request_url = f"{self.base_url_for_environment(environment)}/3/device/{device_token}"
            try:
                with httpx.Client(http2=True, timeout=self.timeout_seconds) as client:
                    response = client.post(request_url, headers=request_headers, json=payload)
            except Exception as error:
                return {
                    "ok": False,
                    "status": None,
                    "reason": f"transport_error:{type(error).__name__}",
                    "apns_id": None,
                    "environment": environment,
                }

            response_reason = f"http_{response.status_code}"
            if response.content:
                try:
                    response_body = response.json()
                except ValueError:
                    response_body = {}
                response_reason = response_body.get("reason") or response_reason

            if response.status_code == 200:
                return {
                    "ok": True,
                    "status": 200,
                    "reason": None,
                    "apns_id": response.headers.get("apns-id"),
                    "environment": environment,
                }

            last_result = {
                "ok": False,
                "status": response.status_code,
                "reason": response_reason,
                "apns_id": response.headers.get("apns-id"),
                "environment": environment,
            }

            should_retry_other_environment = (
                index == 0
                and response_reason in self.RETRYABLE_ENVIRONMENT_REASONS
            )
            if not should_retry_other_environment:
                break

        return last_result


APNS_PROVIDER = APNsProvider(
    key_path=APNS_KEY_PATH,
    key_content=APNS_KEY_P8,
    key_id=APNS_KEY_ID,
    team_id=APNS_TEAM_ID,
    topic=APNS_TOPIC,
    environment=APNS_ENVIRONMENT,
    timeout_seconds=APNS_TIMEOUT_SECONDS,
)


class MediaObjectStorage:
    ENABLED_BACKENDS = {"s3", "r2"}

    def __init__(
        self,
        backend,
        bucket,
        region,
        endpoint_url,
        access_key_id,
        secret_access_key,
        prefix,
    ):
        self.raw_backend = (backend or "local").strip().lower()
        self.backend = self.raw_backend if self.raw_backend in self.ENABLED_BACKENDS else "local"
        self.bucket = (bucket or "").strip()
        self.region = (region or "").strip() or None
        self.endpoint_url = (endpoint_url or "").strip() or None
        self.access_key_id = (access_key_id or "").strip() or None
        self.secret_access_key = (secret_access_key or "").strip() or None
        self.prefix = (prefix or "media").strip().strip("/")
        self._client = None
        self._client_lock = threading.Lock()
        self.configuration_error = self._load_configuration_error()

    @property
    def is_enabled(self):
        return self.backend in self.ENABLED_BACKENDS

    @property
    def is_configured(self):
        return self.configuration_error is None

    def _load_configuration_error(self):
        if not self.is_enabled:
            return None
        if boto3 is None:
            return "missing_dependency_boto3"
        if not self.bucket:
            return "missing_media_s3_bucket"
        if self.backend == "r2" and not self.endpoint_url:
            return "missing_media_s3_endpoint_url"
        return None

    def status_payload(self):
        return {
            "backend": self.backend,
            "bucket": self.bucket,
            "region": self.region,
            "endpointURL": self.endpoint_url,
            "prefix": self.prefix,
            "configured": self.is_configured,
            "configurationError": self.configuration_error,
            "keepLocalCopy": MEDIA_KEEP_LOCAL_COPY,
        }

    def object_key(self, file_name):
        basename = os.path.basename(file_name or "")
        if not basename:
            raise ValueError("invalid_media_file_name")
        if self.prefix:
            return f"{self.prefix}/{basename}"
        return basename

    def _build_client(self):
        kwargs = {
            "service_name": "s3",
        }
        if self.region:
            kwargs["region_name"] = self.region
        if self.endpoint_url:
            kwargs["endpoint_url"] = self.endpoint_url
        if self.access_key_id and self.secret_access_key:
            kwargs["aws_access_key_id"] = self.access_key_id
            kwargs["aws_secret_access_key"] = self.secret_access_key
        if BotocoreConfig:
            kwargs["config"] = BotocoreConfig(
                signature_version="s3v4",
                retries={
                    "max_attempts": 4,
                    "mode": "standard",
                },
            )
        return boto3.client(**kwargs)

    def client(self):
        if self.configuration_error:
            raise RuntimeError(self.configuration_error)
        with self._client_lock:
            if self._client is None:
                self._client = self._build_client()
            return self._client

    def head_by_name(self, file_name):
        if not self.is_enabled:
            return None
        key = self.object_key(file_name)
        try:
            response = self.client().head_object(Bucket=self.bucket, Key=key)
        except ClientError as error:
            code = (
                (error.response or {}).get("Error", {}).get("Code")
                if hasattr(error, "response")
                else None
            )
            if str(code) in {"404", "NoSuchKey", "NotFound"}:
                return None
            raise
        return {
            "fileName": os.path.basename(file_name),
            "byteSize": int(response.get("ContentLength") or 0),
            "mimeType": normalized_optional_string(response.get("ContentType")),
            "storageBackend": self.backend,
            "objectKey": key,
        }

    def upload_local_file(self, file_name, local_path, mime_type=None, expected_size=None, expected_sha256=None, upload_kind="attachment"):
        key = self.object_key(file_name)
        extra_args = {}
        normalized_mime_type = normalized_optional_string(mime_type)
        if normalized_mime_type:
            extra_args["ContentType"] = normalized_mime_type

        log_event(
            "media.remote.upload.begin",
            file_name=os.path.basename(file_name),
            storage_backend=self.backend,
            bucket=self.bucket,
            object_key=key,
            upload_kind=upload_kind,
            expected_byte_size=expected_size,
            expected_sha256=expected_sha256,
        )
        try:
            if extra_args:
                self.client().upload_file(local_path, self.bucket, key, ExtraArgs=extra_args)
            else:
                self.client().upload_file(local_path, self.bucket, key)
        except Exception as error:
            log_event(
                "media.remote.upload.failed",
                file_name=os.path.basename(file_name),
                storage_backend=self.backend,
                bucket=self.bucket,
                object_key=key,
                upload_kind=upload_kind,
                error=type(error).__name__,
            )
            raise ValueError("media_remote_upload_failed")

        remote_info = self.head_by_name(file_name)
        if not remote_info:
            raise ValueError("media_remote_upload_missing_after_write")

        remote_size = int(remote_info.get("byteSize") or 0)
        if expected_size is not None and remote_size != int(expected_size):
            log_event(
                "media.remote.upload.size_mismatch",
                file_name=os.path.basename(file_name),
                storage_backend=self.backend,
                bucket=self.bucket,
                object_key=key,
                expected_byte_size=int(expected_size),
                remote_byte_size=remote_size,
            )
            try:
                self.delete_by_name(file_name)
            except Exception:
                pass
            raise ValueError("media_remote_upload_size_mismatch")

        log_event(
            "media.remote.upload.complete",
            file_name=os.path.basename(file_name),
            storage_backend=self.backend,
            bucket=self.bucket,
            object_key=key,
            upload_kind=upload_kind,
            byte_size=remote_size,
            sha256=expected_sha256,
        )
        return remote_info

    def delete_by_name(self, file_name):
        if not self.is_enabled:
            return
        key = self.object_key(file_name)
        try:
            self.client().delete_object(Bucket=self.bucket, Key=key)
            log_event(
                "media.remote.deleted",
                file_name=os.path.basename(file_name),
                storage_backend=self.backend,
                bucket=self.bucket,
                object_key=key,
            )
        except ClientError as error:
            code = (
                (error.response or {}).get("Error", {}).get("Code")
                if hasattr(error, "response")
                else None
            )
            if str(code) in {"404", "NoSuchKey", "NotFound"}:
                return
            log_event(
                "media.remote.delete_failed",
                file_name=os.path.basename(file_name),
                storage_backend=self.backend,
                bucket=self.bucket,
                object_key=key,
                error=str(code or type(error).__name__),
            )
            raise

    def stream_by_name(self, file_name, start=None, end=None):
        key = self.object_key(file_name)
        request = {
            "Bucket": self.bucket,
            "Key": key,
        }
        if start is not None and end is not None:
            request["Range"] = f"bytes={int(start)}-{int(end)}"
        return self.client().get_object(**request)


MEDIA_OBJECT_STORAGE = MediaObjectStorage(
    backend=MEDIA_STORAGE_BACKEND,
    bucket=MEDIA_S3_BUCKET,
    region=MEDIA_S3_REGION,
    endpoint_url=MEDIA_S3_ENDPOINT_URL,
    access_key_id=MEDIA_S3_ACCESS_KEY_ID,
    secret_access_key=MEDIA_S3_SECRET_ACCESS_KEY,
    prefix=MEDIA_S3_PREFIX,
)


def finalise_media_blob_storage(file_name, mime_type=None, byte_size=None, sha256=None, upload_kind="attachment"):
    local_path = os.path.join(MEDIA_DIR, os.path.basename(file_name or ""))
    if not os.path.exists(local_path):
        raise ValueError("uploaded_media_not_found")

    if not MEDIA_OBJECT_STORAGE.is_enabled:
        return
    if not MEDIA_OBJECT_STORAGE.is_configured:
        raise ValueError("media_object_storage_not_configured")

    MEDIA_OBJECT_STORAGE.upload_local_file(
        file_name=os.path.basename(file_name),
        local_path=local_path,
        mime_type=mime_type,
        expected_size=byte_size,
        expected_sha256=sha256,
        upload_kind=upload_kind,
    )
    if MEDIA_KEEP_LOCAL_COPY:
        return
    try:
        os.remove(local_path)
    except OSError:
        pass


def now_iso():
    return datetime.now(timezone.utc).isoformat()


def expires_at_iso(seconds):
    return (datetime.now(timezone.utc) + timedelta(seconds=seconds)).isoformat()


def parse_iso_timestamp(value):
    normalized = normalized_optional_string(value)
    if not normalized:
        return None
    try:
        return datetime.fromisoformat(normalized.replace("Z", "+00:00"))
    except ValueError:
        return None


def should_hide_deleted_message(message):
    deleted_at = parse_iso_timestamp(message.get("deletedForEveryoneAt"))
    created_at = parse_iso_timestamp(message.get("createdAt"))
    if not deleted_at or not created_at:
        return False
    return (deleted_at - created_at).total_seconds() <= 7 * 24 * 60 * 60


def message_self_destruct_seconds(message):
    delivery_options = message.get("deliveryOptions")
    if not isinstance(delivery_options, dict):
        return None
    try:
        value = int(
            delivery_options.get("selfDestructSeconds")
            or delivery_options.get("self_destruct_seconds")
            or 0
        )
    except (TypeError, ValueError):
        return None
    return value if value > 0 else None


def message_self_destruct_expires_at(message):
    seconds = message_self_destruct_seconds(message)
    if not seconds:
        return None
    created_at = parse_iso_timestamp(message.get("createdAt"))
    if not created_at:
        return None
    return created_at + timedelta(seconds=seconds)


def message_self_destruct_expired(message, reference_time=None):
    expires_at = message_self_destruct_expires_at(message)
    if not expires_at:
        return False
    now_value = reference_time or datetime.now(timezone.utc)
    return now_value >= expires_at


def prune_expired_self_destruct_messages(database):
    now_value = datetime.now(timezone.utc)
    did_prune = False
    retained_messages = []
    for message in database.get("messages", []):
        if message_self_destruct_expired(message, reference_time=now_value):
            remove_message_media_files(message)
            did_prune = True
            continue
        retained_messages.append(message)
    if did_prune:
        database["messages"] = retained_messages
    return did_prune


def default_delivery_state_for_mode(mode):
    return "offline" if mode == "offline" else "online"


def normalized_delivery_state(value, mode):
    normalized = normalized_optional_string(value)
    if normalized in {"offline", "online", "syncing", "migrated"}:
        return normalized
    return default_delivery_state_for_mode(mode)


def merge_delivery_states(existing_state, incoming_state, mode):
    priorities = {
        "offline": 10,
        "syncing": 20,
        "online": 30,
        "migrated": 40,
    }
    normalized_existing = normalized_delivery_state(existing_state, mode)
    normalized_incoming = normalized_delivery_state(incoming_state, mode)
    return normalized_existing if priorities[normalized_existing] >= priorities[normalized_incoming] else normalized_incoming


def normalize_username(value):
    lowered = (value or "").strip().lower()
    return "".join(
        character
        for character in lowered
        if character.isascii() and (character.isalnum() or character == "_")
    )[:32]


def is_valid_username(value, minimum_length=5):
    return minimum_length <= len(value) <= 32 and all(
        character.isascii() and (character.isalnum() or character == "_")
        for character in value
    )


def is_valid_legacy_username(value):
    return is_valid_username(value, minimum_length=3)


def normalize_phone_number(value):
    cleaned = []
    for index, character in enumerate((value or "").strip()):
        if character == "+" and index == 0:
            cleaned.append(character)
        elif character.isdigit():
            cleaned.append(character)
    return "".join(cleaned)


def is_valid_phone_number(value):
    if not value.startswith("+"):
        return False
    digits = value[1:]
    return 7 <= len(digits) <= 15 and digits.isdigit()


def normalize_email(value):
    return normalized_optional_string(value)


def is_valid_email(value):
    if not value:
        return False
    parts = value.split("@")
    return len(parts) == 2 and bool(parts[0]) and bool(parts[1]) and "." in parts[1]


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

    did_update = ensure_database_schema(database)
    if purge_expired_guests(database):
        did_update = True

    if did_update:
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

    for key in ("users", "chats", "messages", "sessions", "deviceTokens", "calls", "callEvents", "chatReadMarkers"):
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

    field_names = ("displayName", "bio", "status", "birthday", "email", "phoneNumber", "profilePhotoURL", "socialLink")
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

    if not (primary.get("accountKind") or "").strip() and (secondary.get("accountKind") or "").strip():
        primary["accountKind"] = secondary.get("accountKind")
        did_update = True

    if not (primary.get("createdAt") or "").strip() and (secondary.get("createdAt") or "").strip():
        primary["createdAt"] = secondary.get("createdAt")
        did_update = True

    if not (primary.get("guestExpiresAt") or "").strip() and (secondary.get("guestExpiresAt") or "").strip():
        primary["guestExpiresAt"] = secondary.get("guestExpiresAt")
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
    primary_guest_request = normalized_guest_request(primary.get("guestRequest"))
    secondary_guest_request = normalized_guest_request(secondary.get("guestRequest"))
    if not primary_guest_request and secondary_guest_request:
        primary["guestRequest"] = secondary_guest_request
        did_update = True
    elif primary_guest_request and secondary_guest_request:
        primary_status = primary_guest_request.get("status")
        secondary_status = secondary_guest_request.get("status")
        if primary_status != secondary_status and primary_status != "approved" and secondary_status == "approved":
            primary["guestRequest"] = secondary_guest_request
            did_update = True
        elif primary_status == "pending" and secondary_status == "declined" and primary_guest_request.get("respondedAt") is None:
            primary["guestRequest"] = secondary_guest_request
            did_update = True
        elif not primary_guest_request.get("introText") and secondary_guest_request.get("introText"):
            primary["guestRequest"] = secondary_guest_request
            did_update = True
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
        username = normalize_username(profile.get("username"))
        if username and profile.get("username") != username:
            profile["username"] = username
            did_update = True
        if "birthday" not in profile:
            profile["birthday"] = None
            did_update = True
        if "accountKind" not in chosen:
            chosen["accountKind"] = "standard"
            did_update = True
        if "createdAt" not in chosen or not chosen.get("createdAt"):
            chosen["createdAt"] = now_iso()
            did_update = True
        if "guestExpiresAt" not in chosen:
            chosen["guestExpiresAt"] = None
            did_update = True
        privacy_settings = chosen.setdefault("privacySettings", {})
        for key, value in default_privacy_settings().items():
            if key not in privacy_settings:
                privacy_settings[key] = value
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

        normalized_request = normalized_guest_request(chat.get("guestRequest"))
        if normalized_request:
            mapped_request = dict(normalized_request)
            mapped_request["requesterUserID"] = user_id_map.get(
                normalized_optional_string(mapped_request.get("requesterUserID")),
                normalized_entity_id(mapped_request.get("requesterUserID"))
            )
            mapped_request["recipientUserID"] = user_id_map.get(
                normalized_optional_string(mapped_request.get("recipientUserID")),
                normalized_entity_id(mapped_request.get("recipientUserID"))
            )
            if chat.get("guestRequest") != mapped_request:
                chat["guestRequest"] = mapped_request
                did_update = True
        elif chat.get("guestRequest") is not None:
            chat["guestRequest"] = None
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

    normalized_read_markers = []
    grouped_read_markers = {}
    for marker in database.get("chatReadMarkers", []):
        user_id = user_id_map.get(normalized_optional_string(marker.get("userID")), normalized_entity_id(marker.get("userID")))
        chat_id = chat_id_map.get(normalized_optional_string(marker.get("chatID")), normalized_entity_id(marker.get("chatID")))
        read_through_at = normalized_optional_string(marker.get("readThroughAt")) or now_iso()
        if not user_id or not chat_id:
            did_update = True
            continue
        marker_key = (user_id, chat_id)
        grouped_read_markers.setdefault(marker_key, []).append(
            {
                "userID": user_id,
                "chatID": chat_id,
                "readThroughAt": read_through_at,
            }
        )

    for marker_key, markers in grouped_read_markers.items():
        latest_marker = max(
            markers,
            key=lambda item: parse_iso_datetime(item.get("readThroughAt")) or datetime.min.replace(tzinfo=timezone.utc),
        )
        normalized_read_markers.append(latest_marker)
        if len(markers) > 1:
            did_update = True

    if normalized_read_markers != (database.get("chatReadMarkers") or []):
        database["chatReadMarkers"] = normalized_read_markers
        did_update = True

    normalized_device_tokens = []
    seen_tokens = set()
    seen_user_devices = set()
    for entry in database.get("deviceTokens", []):
        canonical_entry_id = normalized_entity_id(entry.get("id")) or str(uuid.uuid4())
        if entry.get("id") != canonical_entry_id:
            entry["id"] = canonical_entry_id
            did_update = True
        canonical_user_id = user_id_map.get(normalized_optional_string(entry.get("userID")), normalized_entity_id(entry.get("userID")))
        if canonical_user_id and entry.get("userID") != canonical_user_id:
            entry["userID"] = canonical_user_id
            did_update = True
        token_value = normalized_apns_device_token(entry.get("token"))
        if token_value and entry.get("token") != token_value:
            entry["token"] = token_value
            did_update = True
        platform_value = normalized_device_platform(entry.get("platform")) or "ios"
        if entry.get("platform") != platform_value:
            entry["platform"] = platform_value
            did_update = True
        token_type_value = normalized_device_token_type(
            entry.get("tokenType") or entry.get("token_type")
        )
        if entry.get("tokenType") != token_type_value:
            entry["tokenType"] = token_type_value
            did_update = True
        topic_value = normalized_optional_string(entry.get("topic"))
        if entry.get("topic") != topic_value:
            entry["topic"] = topic_value
            did_update = True
        device_id_value = normalized_device_identifier(
            entry.get("deviceID") or entry.get("device_id")
        )
        if entry.get("deviceID") != device_id_value:
            entry["deviceID"] = device_id_value
            did_update = True
        if token_value and token_value in seen_tokens:
            did_update = True
            continue
        device_key = (canonical_user_id, device_id_value) if canonical_user_id and device_id_value else None
        if device_key:
            device_key = (device_key[0], device_key[1], token_type_value)
        if device_key and device_key in seen_user_devices:
            did_update = True
            continue
        if token_value:
            seen_tokens.add(token_value)
        if device_key:
            seen_user_devices.add(device_key)
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


def hash_security_code(value):
    return hashlib.sha256((value or "").encode("utf-8")).hexdigest()


def make_backup_codes(count=8):
    codes = []
    for _ in range(max(count, 1)):
        codes.append(secrets.token_hex(4).upper())
    return codes


def security_settings_for(user):
    settings = (user or {}).get("securitySettings") or {}
    two_factor = settings.get("twoFactor") or {}
    backup_hashes = two_factor.get("backupCodeHashes") or []
    return {
        "twoFactorEnabled": bool(two_factor.get("enabled")),
        "backupCodesRemaining": len(backup_hashes),
    }


def parse_iso_datetime(value):
    if not value:
        return None
    try:
        return datetime.fromisoformat(value)
    except ValueError:
        return None


def session_device_metadata_from_headers(headers):
    def clean_header(name):
        return normalized_optional_string(headers.get(name))

    platform = clean_header("X-Prime-Platform")
    device_name = clean_header("X-Prime-Device-Name")
    device_model = clean_header("X-Prime-Device-Model")
    os_name = clean_header("X-Prime-OS-Name")
    os_version = clean_header("X-Prime-OS-Version")
    app_version = clean_header("X-Prime-App-Version")

    if not platform:
        user_agent = (headers.get("User-Agent") or "").lower()
        if "watch" in user_agent:
            platform = "watchos"
        elif "appletv" in user_agent or "tvos" in user_agent:
            platform = "tvos"
        elif "ipad" in user_agent:
            platform = "ipados"
        elif "macintosh" in user_agent or "mac os" in user_agent:
            platform = "macos"
        elif "iphone" in user_agent or "ios" in user_agent:
            platform = "ios"
        else:
            platform = "unknown"

    return {
        "platform": platform or "unknown",
        "deviceName": device_name,
        "deviceModel": device_model,
        "osName": os_name,
        "osVersion": os_version,
        "appVersion": app_version,
    }


def apply_session_device_metadata(session, metadata):
    if not isinstance(session, dict) or not isinstance(metadata, dict):
        return

    for source_key, target_key in (
        ("platform", "platform"),
        ("deviceName", "deviceName"),
        ("deviceModel", "deviceModel"),
        ("osName", "osName"),
        ("osVersion", "osVersion"),
        ("appVersion", "appVersion"),
    ):
        value = normalized_optional_string(metadata.get(source_key))
        if value:
            session[target_key] = value


def issue_session(database, user_id, device_metadata=None):
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
    apply_session_device_metadata(session, device_metadata or {})
    database["sessions"].append(session)
    return session, access_token, refresh_token


def rotate_session(session, device_metadata=None):
    access_token = generate_token()
    refresh_token = generate_token()
    session["accessTokenHash"] = hash_token(access_token)
    session["refreshTokenHash"] = hash_token(refresh_token)
    session["accessTokenExpiresAt"] = expires_at_iso(ACCESS_TOKEN_TTL_SECONDS)
    session["refreshTokenExpiresAt"] = expires_at_iso(REFRESH_TOKEN_TTL_SECONDS)
    session["updatedAt"] = now_iso()
    apply_session_device_metadata(session, device_metadata or {})
    return access_token, refresh_token


def session_payload(user, session, access_token, refresh_token):
    return {
        "user": serialize_user(user, user),
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
    if is_user_banned(user):
        return None, None, "account_banned"

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
    # If the client sent a bearer token but authentication failed, do not silently
    # fall back to user_id query params. That fallback can hydrate a different user
    # timeline on another device and causes chat history divergence.
    if bearer_token_from_headers(headers):
        return None, None, auth_error

    fallback_user_id = normalized_entity_id(fallback_user_id)
    if not fallback_user_id:
        return None, None, auth_error

    fallback_user = find_user(database, fallback_user_id)
    if not fallback_user:
        if create_if_missing:
            return ensure_legacy_placeholder_user(database, fallback_user_id), None, None
        return None, None, "user_not_found"

    return fallback_user, None, None


def optional_request_viewer(database, headers, fallback_user_id=None):
    viewer, _, auth_error = request_user_with_fallback(
        database,
        headers,
        fallback_user_id,
        create_if_missing=False
    )
    if auth_error:
        return None
    return viewer


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


def is_user_banned(user):
    banned_until = parse_iso_timestamp((user or {}).get("bannedUntil"))
    if not banned_until:
        return False
    return banned_until > datetime.now(timezone.utc)


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


def latest_user_device_token_activity(database, user_id):
    latest = None
    for entry in database.get("deviceTokens", []):
        if not ids_equal(entry.get("userID"), user_id):
            continue
        updated_at = parse_iso_datetime(entry.get("updatedAt"))
        if updated_at and (latest is None or updated_at > latest):
            latest = updated_at
    return latest


def latest_user_presence_activity(database, user_id):
    session_activity = latest_user_session_activity(database, user_id)
    token_activity = latest_user_device_token_activity(database, user_id)
    if session_activity and token_activity:
        return max(session_activity, token_activity)
    return session_activity or token_activity


def user_is_online(database, user_id):
    latest_activity = latest_user_presence_activity(database, user_id)
    if not latest_activity:
        return False
    return (datetime.now(timezone.utc) - latest_activity).total_seconds() <= PRESENCE_ONLINE_WINDOW_SECONDS


def serialize_presence(viewer, target_user, database):
    latest_activity = latest_user_presence_activity(database, target_user["id"])
    allow_last_seen = privacy_settings_for(target_user).get("allowLastSeen", True)

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


def serialize_user(user, viewer=None):
    privacy_settings = privacy_settings_for(user)
    return {
        "id": user["id"],
        "profile": visible_profile_for_viewer(user["profile"], viewer, user),
        "identityMethods": user["identityMethods"],
        "privacySettings": privacy_settings,
        "securitySettings": security_settings_for(user),
        "accountKind": user.get("accountKind") or "standard",
        "createdAt": user.get("createdAt") or now_iso(),
        "guestExpiresAt": user.get("guestExpiresAt"),
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
        "guestMessageRequests": "approvalRequired",
    }


def privacy_settings_for(user):
    settings = default_privacy_settings()
    settings.update((user or {}).get("privacySettings") or {})
    guest_policy = normalized_optional_string(settings.get("guestMessageRequests")) or "approvalRequired"
    if guest_policy not in {"approvalRequired", "blocked"}:
        guest_policy = "approvalRequired"
    settings["guestMessageRequests"] = guest_policy
    return settings


def find_user_by_identifier(database, identifier):
    identifier = (identifier or "").strip().lower()
    username_identifier = identifier.lstrip("@")
    phone_identifier = normalize_phone_number(identifier)
    for user in database["users"]:
        profile = user["profile"]
        if (profile["username"] or "").lower() == username_identifier:
            return user
        if (profile.get("email") or "").lower() == identifier:
            return user
        if (profile.get("phoneNumber") or "") == phone_identifier:
            return user
    return None


def username_taken(database, username, excluding_user_id=None):
    username = normalize_username(username)
    for user in database["users"]:
        if excluding_user_id and ids_equal(user["id"], excluding_user_id):
            continue
        if (user["profile"].get("username") or "").lower() == username:
            return True
    return False


def email_taken(database, email, excluding_user_id=None):
    normalized_email = normalize_email(email)
    if not normalized_email:
        return False
    for user in database["users"]:
        if excluding_user_id and ids_equal(user["id"], excluding_user_id):
            continue
        if normalize_email((user.get("profile") or {}).get("email")) == normalized_email:
            return True
    return False


def phone_number_taken(database, phone_number, excluding_user_id=None):
    normalized_phone_number = normalize_phone_number(phone_number)
    if not normalized_phone_number:
        return False
    for user in database["users"]:
        if excluding_user_id and ids_equal(user["id"], excluding_user_id):
            continue
        if normalize_phone_number((user.get("profile") or {}).get("phoneNumber")) == normalized_phone_number:
            return True
    return False


def purge_expired_guests(database):
    now = datetime.now(timezone.utc)
    expired_guest_ids = {
        normalized_entity_id(user.get("id"))
        for user in database.get("users", [])
        if (user.get("accountKind") or "standard") == "guest"
        and parse_iso_timestamp(user.get("guestExpiresAt"))
        and parse_iso_timestamp(user.get("guestExpiresAt")) <= now
    }

    expired_guest_ids.discard(None)
    if not expired_guest_ids:
        return False

    did_update = False
    database["users"] = [
        user for user in database.get("users", [])
        if normalized_entity_id(user.get("id")) not in expired_guest_ids
    ]
    database["sessions"] = [
        session for session in database.get("sessions", [])
        if normalized_entity_id(session.get("userID")) not in expired_guest_ids
    ]
    database["deviceTokens"] = [
        item for item in database.get("deviceTokens", [])
        if normalized_entity_id(item.get("userID")) not in expired_guest_ids
    ]

    removed_chat_ids = {
        normalized_entity_id(chat.get("id"))
        for chat in database.get("chats", [])
        if any(normalized_entity_id(participant_id) in expired_guest_ids for participant_id in (chat.get("participantIDs") or []))
    }

    database["chats"] = [
        chat for chat in database.get("chats", [])
        if normalized_entity_id(chat.get("id")) not in removed_chat_ids
    ]
    database["messages"] = [
        message for message in database.get("messages", [])
        if normalized_entity_id(message.get("chatID")) not in removed_chat_ids
        and normalized_entity_id(message.get("senderID")) not in expired_guest_ids
    ]
    database["calls"] = [
        call for call in database.get("calls", [])
        if normalized_entity_id(call.get("callerID")) not in expired_guest_ids
        and normalized_entity_id(call.get("calleeID")) not in expired_guest_ids
    ]
    active_call_ids = {normalized_entity_id(call.get("id")) for call in database.get("calls", [])}
    database["callEvents"] = [
        event for event in database.get("callEvents", [])
        if normalized_entity_id(event.get("senderID")) not in expired_guest_ids
        and normalized_entity_id(event.get("callID")) in active_call_ids
    ]
    did_update = True
    return did_update


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


def normalized_device_platform(value):
    normalized = normalized_optional_string(value)
    return normalized.lower() if normalized else None


def normalized_device_token_type(value):
    normalized = (normalized_optional_string(value) or "apns_alert").lower()
    if normalized in {"apns", "alert", "apns_alert", "apns-standard"}:
        return "apns_alert"
    if normalized in {"voip", "apns_voip", "pushkit_voip"}:
        return "apns_voip"
    return "apns_alert"


def normalized_device_identifier(value):
    normalized = normalized_optional_string(value)
    if not normalized:
        return None
    cleaned = "".join(
        character for character in normalized
        if character.isalnum() or character in ("-", "_", ".", ":")
    )
    return cleaned[:128] or None


def normalized_apns_device_token(value):
    normalized = normalized_optional_string(value)
    if not normalized:
        return None
    # APNs tokens are hexadecimal; clients occasionally submit spaced/uppercased
    # variants, so we canonicalize before storing and dispatching.
    token = "".join(character for character in normalized if character.isalnum()).lower()
    return token or None


def is_voip_device_token_entry(entry):
    return normalized_device_token_type(entry.get("tokenType")) == "apns_voip"


def is_alert_device_token_entry(entry):
    return normalized_device_token_type(entry.get("tokenType")) == "apns_alert"


def normalized_optional_url_string(value):
    return normalized_optional_string(value)


def sanitized_profile(profile):
    payload = dict(profile or {})
    payload["profilePhotoURL"] = normalized_optional_url_string(payload.get("profilePhotoURL"))
    payload["socialLink"] = normalized_optional_url_string(payload.get("socialLink"))
    return payload


def visible_profile_for_viewer(profile, viewer, target_user):
    payload = sanitized_profile(profile)
    if not viewer or ids_equal((viewer or {}).get("id"), (target_user or {}).get("id")):
        return payload

    privacy_settings = privacy_settings_for(target_user)
    if not privacy_settings.get("showEmail", True):
        payload["email"] = None
    if not privacy_settings.get("showPhoneNumber", False):
        payload["phoneNumber"] = None
    if not privacy_settings.get("allowProfilePhoto", True):
        payload["profilePhotoURL"] = None
    return payload


def sanitized_group(group):
    if not group:
        return None

    payload = dict(group)
    payload["photoURL"] = normalized_optional_url_string(payload.get("photoURL"))
    return payload


def normalized_invite_code(value):
    raw_value = normalized_optional_string(value)
    if not raw_value:
        return None

    cleaned = "".join(
        character for character in raw_value.lower()
        if character.isalnum() or character in ("-", "_")
    )
    return cleaned[:64] or None


def is_official_channel_editor(user):
    if not user:
        return False

    username = normalized_optional_string((user.get("profile") or {}).get("username")) or ""
    normalized_username = username.lower().removeprefix("@")
    return normalized_username == "mihran"


def find_chat_by_invite_code(database, invite_code):
    normalized_code = normalized_invite_code(invite_code)
    if not normalized_code:
        return None

    return next(
        (
            chat for chat in database.get("chats", [])
            if normalized_invite_code((chat.get("communityDetails") or {}).get("inviteCode")) == normalized_code
        ),
        None,
    )


def unique_invite_code(database, preferred_code=None):
    normalized_code = normalized_invite_code(preferred_code)
    if normalized_code and find_chat_by_invite_code(database, normalized_code) is None:
        return normalized_code

    while True:
        candidate = uuid.uuid4().hex[:12]
        if find_chat_by_invite_code(database, candidate) is None:
            return candidate


def invite_link_for_code(invite_code):
    normalized_code = normalized_invite_code(invite_code)
    if not normalized_code:
        return None
    return f"primemessaging://join/{normalized_code}"


def sanitized_community_topic(topic):
    if not isinstance(topic, dict):
        return None

    title = normalized_optional_string(topic.get("title"))
    if not title:
        return None

    symbol_name = normalized_optional_string(topic.get("symbolName") or topic.get("symbol_name")) or "number"
    try:
        unread_count = max(0, int(topic.get("unreadCount") or topic.get("unread_count") or 0))
    except (TypeError, ValueError):
        unread_count = 0

    return {
        "id": normalized_entity_id(topic.get("id")) or str(uuid.uuid4()),
        "title": title,
        "symbolName": symbol_name,
        "unreadCount": unread_count,
        "isPinned": bool(topic.get("isPinned") or topic.get("is_pinned")),
        "lastActivityAt": (
            parse_iso_timestamp(topic.get("lastActivityAt") or topic.get("last_activity_at")) or datetime.now(timezone.utc)
        ).isoformat(),
    }


def normalized_community_details(raw_details, database, existing_details=None, requester=None):
    if not isinstance(raw_details, dict):
        if isinstance(existing_details, dict):
            return dict(existing_details)
        return None

    existing_details = existing_details if isinstance(existing_details, dict) else {}
    kind = normalized_optional_string(raw_details.get("kind")) or normalized_optional_string(existing_details.get("kind")) or "group"
    if kind not in {"group", "supergroup", "channel", "community"}:
        kind = "group"

    topics = [
        topic
        for topic in (
            sanitized_community_topic(item)
            for item in (raw_details.get("topics") or existing_details.get("topics") or [])
        )
        if topic is not None
    ][:12]

    invite_code = unique_invite_code(
        database,
        raw_details.get("inviteCode") or raw_details.get("invite_code") or existing_details.get("inviteCode")
    )

    previous_is_official = bool(existing_details.get("isOfficial"))
    incoming_is_official = bool(
        raw_details.get("isOfficial") if "isOfficial" in raw_details else raw_details.get("is_official", previous_is_official)
    )
    if incoming_is_official != previous_is_official and not is_official_channel_editor(requester):
        raise PermissionError("official_badge_permission_denied")

    return {
        "kind": kind,
        "forumModeEnabled": bool(
            raw_details.get("forumModeEnabled")
            if "forumModeEnabled" in raw_details
            else raw_details.get("forum_mode_enabled", existing_details.get("forumModeEnabled", False))
        ),
        "commentsEnabled": bool(
            raw_details.get("commentsEnabled")
            if "commentsEnabled" in raw_details
            else raw_details.get("comments_enabled", existing_details.get("commentsEnabled", False))
        ),
        "isPublic": bool(
            raw_details.get("isPublic")
            if "isPublic" in raw_details
            else raw_details.get("is_public", existing_details.get("isPublic", False))
        ),
        "topics": topics,
        "inviteCode": invite_code,
        "inviteLink": invite_link_for_code(invite_code),
        "isOfficial": incoming_is_official,
    }


def sanitized_community_details(details):
    if not isinstance(details, dict):
        return None

    kind = normalized_optional_string(details.get("kind")) or "group"
    if kind not in {"group", "supergroup", "channel", "community"}:
        kind = "group"

    topics = [
        topic
        for topic in (
            sanitized_community_topic(item)
            for item in (details.get("topics") or [])
        )
        if topic is not None
    ]

    invite_code = normalized_invite_code(details.get("inviteCode") or details.get("invite_code"))
    invite_link = normalized_optional_string(details.get("inviteLink") or details.get("invite_link")) or invite_link_for_code(invite_code)

    return {
        "kind": kind,
        "forumModeEnabled": bool(details.get("forumModeEnabled")),
        "commentsEnabled": bool(details.get("commentsEnabled")),
        "isPublic": bool(details.get("isPublic")),
        "topics": topics,
        "inviteCode": invite_code,
        "inviteLink": invite_link,
        "isOfficial": bool(details.get("isOfficial")),
    }


def chat_is_publicly_joinable(chat):
    community_details = sanitized_community_details(chat.get("communityDetails"))
    return bool((community_details or {}).get("isPublic"))


def normalized_group_moderation_settings(raw_settings, existing_settings=None):
    if raw_settings is None:
        raw_settings = {}
    if not isinstance(raw_settings, dict):
        raw_settings = {}

    existing_settings = existing_settings if isinstance(existing_settings, dict) else {}

    welcome_message = normalized_optional_string(
        raw_settings.get("welcomeMessage")
        if "welcomeMessage" in raw_settings
        else raw_settings.get("welcome_message", existing_settings.get("welcomeMessage"))
    ) or ""
    rules = normalized_optional_string(
        raw_settings.get("rules")
        if "rules" in raw_settings
        else existing_settings.get("rules")
    ) or ""

    raw_questions = (
        raw_settings.get("entryQuestions")
        if "entryQuestions" in raw_settings
        else raw_settings.get("entry_questions", existing_settings.get("entryQuestions", []))
    )
    entry_questions = []
    if isinstance(raw_questions, list):
        for item in raw_questions:
            question = normalized_optional_string(item)
            if question:
                entry_questions.append(question[:180])

    try:
        slow_mode_seconds = max(
            0,
            int(
                raw_settings.get("slowModeSeconds")
                if "slowModeSeconds" in raw_settings
                else raw_settings.get("slow_mode_seconds", existing_settings.get("slowModeSeconds", 0))
            ),
        )
    except (TypeError, ValueError):
        slow_mode_seconds = max(0, int(existing_settings.get("slowModeSeconds", 0) or 0))

    return {
        "requiresJoinApproval": bool(
            raw_settings.get("requiresJoinApproval")
            if "requiresJoinApproval" in raw_settings
            else raw_settings.get("requires_join_approval", existing_settings.get("requiresJoinApproval", False))
        ),
        "welcomeMessage": welcome_message[:500],
        "rules": rules[:1200],
        "entryQuestions": entry_questions[:5],
        "slowModeSeconds": slow_mode_seconds,
        "restrictMedia": bool(
            raw_settings.get("restrictMedia")
            if "restrictMedia" in raw_settings
            else raw_settings.get("restrict_media", existing_settings.get("restrictMedia", False))
        ),
        "restrictLinks": bool(
            raw_settings.get("restrictLinks")
            if "restrictLinks" in raw_settings
            else raw_settings.get("restrict_links", existing_settings.get("restrictLinks", False))
        ),
        "antiSpamEnabled": bool(
            raw_settings.get("antiSpamEnabled")
            if "antiSpamEnabled" in raw_settings
            else raw_settings.get("anti_spam_enabled", existing_settings.get("antiSpamEnabled", False))
        ),
    }


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


def normalized_guest_request(guest_request):
    if not guest_request:
        return None

    payload = dict(guest_request)
    requester_user_id = normalized_entity_id(payload.get("requesterUserID"))
    recipient_user_id = normalized_entity_id(payload.get("recipientUserID"))
    if not requester_user_id or not recipient_user_id:
        return None

    status = (payload.get("status") or "pending").strip()
    if status not in {"pending", "approved", "declined"}:
        status = "pending"

    intro_text = normalized_optional_string(payload.get("introText"))
    if intro_text and len(intro_text) > 150:
        intro_text = intro_text[:150]

    return {
        "requesterUserID": requester_user_id,
        "recipientUserID": recipient_user_id,
        "status": status,
        "introText": intro_text,
        "createdAt": payload.get("createdAt") or now_iso(),
        "respondedAt": payload.get("respondedAt"),
    }


def guest_request_preview(chat, current_user_id):
    guest_request = normalized_guest_request(chat.get("guestRequest"))
    if not guest_request:
        return None

    status = guest_request.get("status")
    intro_text = guest_request.get("introText")
    if status == "pending":
        if ids_equal(current_user_id, guest_request.get("requesterUserID")):
            return "Guest request sent" if intro_text else "Send guest request"
        return intro_text or "Guest request pending"

    if status == "declined":
        return "Guest request declined"

    return None


def guest_request_activity_at(chat):
    guest_request = normalized_guest_request(chat.get("guestRequest"))
    if not guest_request:
        return None
    return guest_request.get("respondedAt") or guest_request.get("createdAt")


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


def display_name_for_user(user):
    return resolved_user_display_name(user)


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


def can_transfer_group_ownership(chat, requester_id, member_user_id):
    requester_member = find_group_member(chat, requester_id)
    target_member = find_group_member(chat, member_user_id)
    if not requester_member or not target_member:
        return False
    if requester_member.get("role") != "owner":
        return False
    if ids_equal(member_user_id, requester_id):
        return False
    return True


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


def transfer_group_ownership(chat, new_owner_user_id):
    if not chat or chat.get("type") != "group":
        return False

    group = chat.get("group") or {}
    current_owner_id = normalized_entity_id(group.get("ownerID"))
    new_owner_user_id = normalized_entity_id(new_owner_user_id)
    if not current_owner_id or not new_owner_user_id or ids_equal(current_owner_id, new_owner_user_id):
        return False

    did_update = False
    for member in group.get("members") or []:
        member_user_id = normalized_entity_id(member.get("userID"))
        if ids_equal(member_user_id, current_owner_id):
            member["role"] = "admin"
            did_update = True
        elif ids_equal(member_user_id, new_owner_user_id):
            member["role"] = "owner"
            did_update = True

    if did_update is False:
        return False

    group["ownerID"] = new_owner_user_id
    return True


def leave_group(chat, requester_id):
    if not chat or chat.get("type") != "group":
        return False

    group = chat.get("group") or {}
    if ids_equal(group.get("ownerID"), requester_id):
        return False

    return remove_group_member(chat, requester_id)


def active_group_bans(chat):
    if not chat or chat.get("type") != "group":
        return []

    now = datetime.now(timezone.utc)
    retained = []
    for ban in (chat.get("bannedMembers") or []):
        banned_until = parse_iso_timestamp(ban.get("bannedUntil"))
        if banned_until and banned_until <= now:
            continue
        retained.append(ban)
    chat["bannedMembers"] = retained
    return retained


def is_group_banned(chat, user_id):
    user_id = normalized_entity_id(user_id)
    if not user_id:
        return False
    return any(ids_equal(ban.get("userID"), user_id) for ban in active_group_bans(chat))


def sanitized_join_request_payload(payload, database):
    if not isinstance(payload, dict):
        return None

    requester_user_id = normalized_entity_id(payload.get("requesterUserID") or payload.get("requester_user_id"))
    requester = find_user(database, requester_user_id)
    if not requester:
        return None

    raw_answers = payload.get("answers") or []
    answers = []
    if isinstance(raw_answers, list):
        for item in raw_answers:
            answer = normalized_optional_string(item)
            if not answer:
                continue
            answers.append(answer[:180])

    status = normalized_optional_string(payload.get("status")) or "pending"
    if status not in {"pending", "approved", "declined"}:
        status = "pending"

    return {
        "id": normalized_entity_id(payload.get("id")) or str(uuid.uuid4()),
        "requesterUserID": requester_user_id,
        "requesterDisplayName": resolved_user_display_name(requester),
        "requesterUsername": (requester.get("profile") or {}).get("username"),
        "answers": answers[:5],
        "status": status,
        "createdAt": (parse_iso_timestamp(payload.get("createdAt") or payload.get("created_at")) or datetime.now(timezone.utc)).isoformat(),
        "resolvedAt": (
            parse_iso_timestamp(payload.get("resolvedAt") or payload.get("resolved_at")).isoformat()
            if parse_iso_timestamp(payload.get("resolvedAt") or payload.get("resolved_at"))
            else None
        ),
        "reviewedByUserID": normalized_entity_id(payload.get("reviewedByUserID") or payload.get("reviewed_by_user_id")),
    }


def sanitized_report_record(payload, database):
    if not isinstance(payload, dict):
        return None

    reporter_user_id = normalized_entity_id(payload.get("reporterUserID") or payload.get("reporter_user_id"))
    reporter = find_user(database, reporter_user_id)
    if not reporter:
        return None

    reason = normalized_optional_string(payload.get("reason")) or "other"
    if reason not in {"spam", "abuse", "harassment", "impersonation", "misinformation", "illegal", "off_topic", "other"}:
        reason = "other"

    details = normalized_optional_string(payload.get("details"))
    if details:
        details = details[:400]

    target_message_id = normalized_entity_id(payload.get("targetMessageID") or payload.get("target_message_id"))
    target_message = find_message(database, target_message_id) if target_message_id else None

    return {
        "id": normalized_entity_id(payload.get("id")) or str(uuid.uuid4()),
        "reporterUserID": reporter_user_id,
        "reporterDisplayName": resolved_user_display_name(reporter),
        "reporterUsername": (reporter.get("profile") or {}).get("username"),
        "targetChatID": normalized_entity_id(payload.get("targetChatID") or payload.get("target_chat_id")),
        "targetMessageID": target_message_id,
        "targetUserID": normalized_entity_id(payload.get("targetUserID") or payload.get("target_user_id")),
        "reason": reason,
        "details": details,
        "targetPreview": message_preview(target_message) if target_message else normalized_optional_string(payload.get("targetPreview") or payload.get("target_preview")),
        "createdAt": (parse_iso_timestamp(payload.get("createdAt") or payload.get("created_at")) or datetime.now(timezone.utc)).isoformat(),
    }


def sanitized_group_ban_record(payload, database):
    if not isinstance(payload, dict):
        return None

    user_id = normalized_entity_id(payload.get("userID") or payload.get("user_id"))
    banned_by_user_id = normalized_entity_id(payload.get("bannedByUserID") or payload.get("banned_by_user_id"))
    if not user_id or not banned_by_user_id:
        return None

    user = find_user(database, user_id)
    reason = normalized_optional_string(payload.get("reason"))
    if reason:
        reason = reason[:180]

    banned_until = parse_iso_timestamp(payload.get("bannedUntil") or payload.get("banned_until"))

    return {
        "id": normalized_entity_id(payload.get("id")) or str(uuid.uuid4()),
        "userID": user_id,
        "displayName": resolved_user_display_name(user),
        "username": (user.get("profile") or {}).get("username") if user else None,
        "reason": reason,
        "createdAt": (parse_iso_timestamp(payload.get("createdAt") or payload.get("created_at")) or datetime.now(timezone.utc)).isoformat(),
        "bannedUntil": banned_until.isoformat() if banned_until else None,
        "bannedByUserID": banned_by_user_id,
    }


def moderation_dashboard_payload(chat, database):
    active_group_bans(chat)
    return {
        "joinRequests": [
            sanitized_join_request_payload(request, database)
            for request in ((chat.get("joinRequests") or []))
            if sanitized_join_request_payload(request, database) is not None
        ],
        "reports": [
            sanitized_report_record(report, database)
            for report in ((chat.get("reports") or []))
            if sanitized_report_record(report, database) is not None
        ],
        "bans": [
            sanitized_group_ban_record(ban, database)
            for ban in active_group_bans(chat)
            if sanitized_group_ban_record(ban, database) is not None
        ],
    }


def delete_user_account(database, user_id):
    user_id = normalized_entity_id(user_id)
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
        chat_id = normalized_entity_id(chat.get("id"))
        participant_ids = unique_entity_ids(chat.get("participantIDs") or [])
        is_participant = any(ids_equal(participant_id, user_id) for participant_id in participant_ids)

        guest_request = normalized_guest_request(chat.get("guestRequest"))
        if guest_request and (
            ids_equal(guest_request.get("requesterUserID"), user_id)
            or ids_equal(guest_request.get("recipientUserID"), user_id)
        ):
            chat["guestRequest"] = None

        if not is_participant:
            if chat.get("type") == "group":
                group = chat.get("group") or {}
                filtered_members = [
                    member
                    for member in (group.get("members") or [])
                    if not ids_equal(member.get("userID"), user_id)
                ]
                if len(filtered_members) != len(group.get("members") or []):
                    group["members"] = filtered_members
                    chat["cachedSubtitle"] = f"{len(filtered_members)} members"
            continue

        if chat.get("type") in ("selfChat", "direct"):
            if chat_id:
                deleted_chat_ids.add(chat_id)
            continue

        if chat.get("type") == "group":
            group = chat.get("group") or {}
            remaining_members = [
                member
                for member in (group.get("members") or [])
                if not ids_equal(member.get("userID"), user_id)
            ]

            if not remaining_members:
                if chat_id:
                    deleted_chat_ids.add(chat_id)
                continue

            if ids_equal(group.get("ownerID"), user_id):
                new_owner_id = normalized_entity_id(remaining_members[0].get("userID"))
                group["ownerID"] = new_owner_id
            else:
                new_owner_id = normalized_entity_id(group.get("ownerID"))

            for member in remaining_members:
                member_user_id = normalized_entity_id(member.get("userID"))
                member["role"] = "owner" if ids_equal(member_user_id, new_owner_id) else (
                    "admin" if member.get("role") == "admin" else "member"
                )

            group["members"] = remaining_members
            chat["participantIDs"] = unique_entity_ids(
                participant_id
                for participant_id in participant_ids
                if not ids_equal(participant_id, user_id)
            )

            if len(chat["participantIDs"]) == 0:
                if chat_id:
                    deleted_chat_ids.add(chat_id)
                continue

            chat["cachedSubtitle"] = f"{len(group['members'])} members"

    removed_message_ids = set()
    retained_messages = []
    for message in database.get("messages", []):
        message_id = normalized_entity_id(message.get("id"))
        chat_id = normalized_entity_id(message.get("chatID"))
        sender_id = normalized_entity_id(message.get("senderID"))

        if chat_id in deleted_chat_ids or ids_equal(sender_id, user_id):
            if message_id:
                removed_message_ids.add(message_id)
            remove_message_media_files(message)
            continue

        sanitized_reaction_entries = []
        for reaction in message.get("reactions") or []:
            if not isinstance(reaction, dict):
                continue
            remaining_user_ids = [
                reaction_user_id
                for reaction_user_id in unique_entity_ids(reaction.get("userIDs") or [])
                if not ids_equal(reaction_user_id, user_id)
            ]
            if not remaining_user_ids:
                continue
            updated_reaction = dict(reaction)
            updated_reaction["userIDs"] = remaining_user_ids
            sanitized_reaction_entries.append(updated_reaction)
        message["reactions"] = sanitized_reaction_entries

        retained_messages.append(message)

    for message in retained_messages:
        if normalized_entity_id(message.get("replyToMessageID")) in removed_message_ids:
            message["replyToMessageID"] = None
            message["replyPreview"] = None
            continue

        reply_preview = message.get("replyPreview")
        if isinstance(reply_preview, dict) and ids_equal(reply_preview.get("senderID"), user_id):
            message["replyPreview"] = None

    database["chats"] = [
        chat
        for chat in database.get("chats", [])
        if normalized_entity_id(chat.get("id")) not in deleted_chat_ids
    ]
    database["messages"] = retained_messages

    deleted_call_ids = set()
    retained_calls = []
    for call in database.get("calls", []):
        call_id = normalized_entity_id(call.get("id"))
        call_chat_id = normalized_entity_id(call.get("chatID"))
        if (
            ids_equal(call.get("callerID"), user_id)
            or ids_equal(call.get("calleeID"), user_id)
            or call_chat_id in deleted_chat_ids
        ):
            if call_id:
                deleted_call_ids.add(call_id)
            continue
        retained_calls.append(call)
    database["calls"] = retained_calls

    database["callEvents"] = [
        event
        for event in database.get("callEvents", [])
        if not ids_equal(event.get("senderID"), user_id)
        and normalized_entity_id(event.get("callID")) not in deleted_call_ids
    ]

    return True


def delete_legacy_placeholder_users(database):
    legacy_user_ids = [
        normalized_entity_id(user.get("id"))
        for user in database.get("users", [])
        if is_legacy_placeholder_user(user)
    ]

    removed_count = 0
    for user_id in legacy_user_ids:
        if user_id and delete_user_account(database, user_id):
            removed_count += 1

    return removed_count


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
    if MEDIA_OBJECT_STORAGE.is_enabled and MEDIA_OBJECT_STORAGE.is_configured:
        try:
            MEDIA_OBJECT_STORAGE.delete_by_name(basename)
        except Exception:
            log_event(
                "media.remote.delete_failed",
                file_name=basename,
                storage_backend=MEDIA_OBJECT_STORAGE.backend,
            )


def remove_message_media_files(message):
    for attachment in message.get("attachments") or []:
        if not isinstance(attachment, dict):
            continue
        remove_file_for_url(attachment.get("remoteURL"), MEDIA_DIR)

    voice_message = message.get("voiceMessage")
    if isinstance(voice_message, dict):
        remove_file_for_url(voice_message.get("remoteFileURL"), MEDIA_DIR)


def build_safe_blob_name(file_name):
    stem, ext = os.path.splitext(file_name or "")
    if not ext:
        ext = ".bin"
    safe_stem = "".join(ch for ch in (stem or "upload") if ch.isalnum() or ch in ("-", "_")) or "upload"
    safe_name = f"{safe_stem}-{uuid.uuid4().hex}{ext}"
    return safe_name, ext


def save_binary_blob(directory, file_name, raw, mime_type=None, upload_kind="attachment"):
    safe_name, ext = build_safe_blob_name(file_name)
    output_path = os.path.join(directory, safe_name)
    with open(output_path, "wb") as file:
        file.write(raw)
        file.flush()
        os.fsync(file.fileno())

    byte_size = len(raw)
    sha256 = hashlib.sha256(raw).hexdigest()
    log_event(
        "media.upload.saved",
        file_name=safe_name,
        original_name=file_name,
        byte_size=byte_size,
        sha256=sha256,
        extension=ext,
        mime_type=mime_type,
        upload_kind=upload_kind,
    )
    return safe_name, byte_size, sha256


def save_streamed_blob(directory, file_name, input_stream, content_length, mime_type=None, upload_kind="attachment"):
    safe_name, ext = build_safe_blob_name(file_name)
    output_path = os.path.join(directory, safe_name)
    digest = hashlib.sha256()
    written = 0
    remaining = max(int(content_length or 0), 0)

    with open(output_path, "wb") as file:
        while remaining > 0:
            chunk = input_stream.read(min(64 * 1024, remaining))
            if not chunk:
                break
            file.write(chunk)
            digest.update(chunk)
            written += len(chunk)
            remaining -= len(chunk)
        file.flush()
        os.fsync(file.fileno())

    if written != content_length:
        if os.path.exists(output_path):
            os.remove(output_path)
        raise ValueError("incomplete_upload")

    sha256 = digest.hexdigest()
    log_event(
        "media.upload.saved",
        file_name=safe_name,
        original_name=file_name,
        byte_size=written,
        sha256=sha256,
        extension=ext,
        mime_type=mime_type,
        upload_kind=upload_kind,
    )
    return safe_name, written, sha256


def file_sha256(file_path):
    digest = hashlib.sha256()
    with open(file_path, "rb") as file:
        while True:
            chunk = file.read(64 * 1024)
            if not chunk:
                break
            digest.update(chunk)
    return digest.hexdigest()


def normalize_uploaded_video_mp4(directory, input_file_name, upload_kind):
    input_path = os.path.join(directory, input_file_name)
    if upload_kind != "video":
        return input_file_name, os.path.getsize(input_path), file_sha256(input_path), None

    if not os.path.exists(input_path):
        raise ValueError("uploaded_media_not_found")

    ffmpeg_path = shutil.which("ffmpeg")
    ffprobe_path = shutil.which("ffprobe")
    if not ffmpeg_path:
        passthrough_size = os.path.getsize(input_path)
        passthrough_sha256 = file_sha256(input_path)
        log_event(
            "media.upload.video_normalized_passthrough",
            reason="ffmpeg_unavailable",
            file_name=input_file_name,
            byte_size=passthrough_size,
            sha256=passthrough_sha256,
        )
        return input_file_name, passthrough_size, passthrough_sha256, None

    normalized_name = f"video-{uuid.uuid4().hex}.mp4"
    normalized_path = os.path.join(directory, normalized_name)

    def run_cmd(command, timeout_seconds):
        return subprocess.run(
            command,
            capture_output=True,
            text=True,
            timeout=timeout_seconds,
        )

    try:
        if os.path.exists(normalized_path):
            os.remove(normalized_path)

        transcode_cmd = [
            ffmpeg_path,
            "-y",
            "-i",
            input_path,
            "-map",
            "0:v:0?",
            "-map",
            "0:a:0?",
            "-c:v",
            "libx264",
            "-preset",
            "veryfast",
            "-crf",
            "23",
            "-pix_fmt",
            "yuv420p",
            "-profile:v",
            "high",
            "-level",
            "4.1",
            "-c:a",
            "aac",
            "-b:a",
            "128k",
            "-movflags",
            "+faststart",
            "-f",
            "mp4",
            normalized_path,
        ]
        transcode_result = run_cmd(transcode_cmd, timeout_seconds=420)
        if transcode_result.returncode != 0:
            log_event(
                "media.upload.video_normalize_failed",
                file_name=input_file_name,
                stage="transcode",
                stderr=(transcode_result.stderr or "")[-1500:],
            )
            raise ValueError("video_normalization_failed")

        if not os.path.exists(normalized_path):
            raise ValueError("video_normalization_failed")

        normalized_size = os.path.getsize(normalized_path)
        if normalized_size <= 0:
            raise ValueError("video_normalization_failed")

        if ffprobe_path:
            probe_cmd = [
                ffprobe_path,
                "-v",
                "error",
                "-show_entries",
                "format=duration",
                "-of",
                "default=noprint_wrappers=1:nokey=1",
                normalized_path,
            ]
            probe_result = run_cmd(probe_cmd, timeout_seconds=30)
            if probe_result.returncode == 0:
                duration_text = (probe_result.stdout or "").strip()
                try:
                    duration_value = float(duration_text)
                except (TypeError, ValueError):
                    duration_value = 0.0
                if duration_value <= 0:
                    log_event(
                        "media.upload.video_probe_duration_unavailable",
                        file_name=normalized_name,
                        duration_text=duration_text,
                    )

        normalized_sha256 = file_sha256(normalized_path)
        try:
            os.remove(input_path)
        except OSError:
            pass
        log_event(
            "media.upload.video_normalized",
            original_file_name=input_file_name,
            normalized_file_name=normalized_name,
            byte_size=normalized_size,
            sha256=normalized_sha256,
        )
        return normalized_name, normalized_size, normalized_sha256, "video/mp4"
    except subprocess.TimeoutExpired:
        raise ValueError("video_normalization_timeout")
    except ValueError:
        if os.path.exists(normalized_path):
            try:
                os.remove(normalized_path)
            except OSError:
                pass
        raise
    except Exception:
        if os.path.exists(normalized_path):
            try:
                os.remove(normalized_path)
            except OSError:
                pass
        raise ValueError("video_normalization_failed")


def save_base64_blob(directory, file_name, encoded_data, mime_type=None, upload_kind="attachment"):
    raw = base64.b64decode(encoded_data or "")
    safe_name, size, sha256 = save_binary_blob(
        directory,
        file_name,
        raw,
        mime_type=mime_type,
        upload_kind=upload_kind,
    )
    if directory == MEDIA_DIR:
        finalise_media_blob_storage(
            file_name=safe_name,
            mime_type=mime_type,
            byte_size=size,
            sha256=sha256,
            upload_kind=upload_kind,
        )
    return safe_name, size


def media_file_info_for_url(file_url, directory):
    basename = os.path.basename(urlparse(file_url or "").path)
    if not basename:
        return None

    file_path = os.path.join(directory, basename)
    if not os.path.exists(file_path):
        if not (directory == MEDIA_DIR and MEDIA_OBJECT_STORAGE.is_enabled and MEDIA_OBJECT_STORAGE.is_configured):
            return None
        try:
            remote_info = MEDIA_OBJECT_STORAGE.head_by_name(basename)
        except Exception:
            log_event(
                "media.remote.head_failed",
                file_name=basename,
                storage_backend=MEDIA_OBJECT_STORAGE.backend,
            )
            return None
        if not remote_info:
            return None
        return {
            "fileName": basename,
            "filePath": None,
            "byteSize": int(remote_info.get("byteSize") or 0),
            "storageBackend": MEDIA_OBJECT_STORAGE.backend,
        }

    return {
        "fileName": basename,
        "filePath": file_path,
        "byteSize": os.path.getsize(file_path),
        "storageBackend": "local",
    }


def media_content_type_for_name(file_name, fallback=None):
    content_type = normalized_optional_string(fallback)
    if content_type:
        return content_type
    guessed_content_type, _ = mimetypes.guess_type(file_name or "")
    if guessed_content_type:
        content_type = guessed_content_type
    else:
        content_type = "application/octet-stream"
    if str(file_name or "").lower().endswith(".m4a"):
        return "audio/mp4"
    if str(file_name or "").lower().endswith(".mov"):
        return "video/quicktime"
    return content_type


def resolved_media_byte_range(range_header, file_size):
    if file_size <= 0:
        return {
            "status": 200,
            "start": 0,
            "end": -1,
            "length": 0,
            "invalid": False,
        }

    start = 0
    end = file_size - 1
    status = 200
    invalid = False

    if range_header and range_header.startswith("bytes="):
        range_spec = range_header.removeprefix("bytes=").split(",", 1)[0].strip()
        start_text, _, end_text = range_spec.partition("-")
        try:
            if start_text == "" and end_text:
                suffix_length = int(end_text)
                if suffix_length <= 0:
                    raise ValueError("invalid_suffix_length")
                start = max(file_size - suffix_length, 0)
                end = file_size - 1
            else:
                start = int(start_text or 0)
                if end_text:
                    end = min(int(end_text), file_size - 1)
                else:
                    end = file_size - 1
            if start < 0 or start >= file_size or end < start:
                invalid = True
            else:
                status = 206
        except ValueError:
            start = 0
            end = file_size - 1
            status = 200

    return {
        "status": status,
        "start": start,
        "end": end,
        "length": max((end - start) + 1, 0),
        "invalid": invalid,
    }


def message_preview(message):
    if message.get("deletedForEveryoneAt"):
        if should_hide_deleted_message(message):
            return None
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


def direct_chat_guest_request(chat):
    return normalized_guest_request(chat.get("guestRequest"))


def direct_chat_allows_messages(chat):
    guest_request = direct_chat_guest_request(chat)
    return guest_request is None or guest_request.get("status") == "approved"


def guest_request_policy_for(user):
    privacy_settings = privacy_settings_for(user)
    return (privacy_settings.get("guestMessageRequests") or "approvalRequired").strip() or "approvalRequired"


def backfill_pending_guest_request(chat, database):
    if chat.get("type") != "direct":
        return False
    if direct_chat_guest_request(chat):
        return False

    participant_ids = unique_entity_ids(chat.get("participantIDs") or [])
    if len(participant_ids) != 2:
        return False

    first_user = find_user(database, participant_ids[0])
    second_user = find_user(database, participant_ids[1])
    if not first_user or not second_user:
        return False

    first_kind = (first_user.get("accountKind") or "standard").strip() or "standard"
    second_kind = (second_user.get("accountKind") or "standard").strip() or "standard"

    if first_kind == "guest" and second_kind != "guest":
        guest_user = first_user
        recipient_user = second_user
    elif second_kind == "guest" and first_kind != "guest":
        guest_user = second_user
        recipient_user = first_user
    else:
        return False

    if guest_request_policy_for(recipient_user) != "approvalRequired":
        return False

    chat["guestRequest"] = {
        "requesterUserID": guest_user["id"],
        "recipientUserID": recipient_user["id"],
        "status": "pending",
        "introText": None,
        "createdAt": now_iso(),
        "respondedAt": None,
    }
    return True


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
        community_details = sanitized_community_details(chat.get("communityDetails"))
        if (community_details or {}).get("kind") == "channel":
            return f"{count} subscriber" if count == 1 else f"{count} subscribers"
        return f"{count} member" if count == 1 else f"{count} members"

    other_user = direct_chat_other_user(chat, current_user_id, database)
    if not other_user:
        cached_subtitle = chat.get("cachedSubtitle", "Direct conversation")
        return "Direct conversation" if generic_direct_subtitle(cached_subtitle) else cached_subtitle

    return f"@{other_user['profile']['username']}"


def serialize_chat(chat, current_user_id, database):
    messages = [
        message
        for message in database["messages"]
        if ids_equal(message.get("chatID"), chat.get("id"))
        and not message_self_destruct_expired(message)
    ]
    messages.sort(key=lambda item: item["createdAt"])
    community_details = sanitized_community_details(chat.get("communityDetails")) or {}
    if community_details.get("kind") == "channel" and community_details.get("commentsEnabled"):
        root_messages = [
            message
            for message in messages
            if not ((message.get("communityContext") or {}).get("parentPostID"))
        ]
        last_message = next(
            (message for message in reversed(root_messages) if not should_hide_deleted_message(message)),
            None,
        )
    else:
        last_message = next(
            (message for message in reversed(messages) if not should_hide_deleted_message(message)),
            None,
        )
    guest_request = direct_chat_guest_request(chat)
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

    unread_count = unread_count_for_chat_user(database, chat, current_user_id)

    return {
        "id": chat["id"],
        "mode": chat["mode"],
        "type": chat["type"],
        "title": chat_title_for(chat, current_user_id, database),
        "subtitle": chat_subtitle_for(chat, current_user_id, database),
        "participantIDs": chat["participantIDs"],
        "participants": participants,
        "group": sanitized_group(chat.get("group")),
        "lastMessagePreview": message_preview(last_message) if last_message else guest_request_preview(chat, current_user_id),
        "lastActivityAt": last_message["createdAt"] if last_message else (guest_request_activity_at(chat) or chat["createdAt"]),
        "unreadCount": unread_count,
        "isPinned": False,
        "draft": None,
        "disappearingPolicy": None,
        "notificationPreferences": {
            "muteState": "active",
            "previewEnabled": True,
            "customSoundName": None,
            "badgeEnabled": True,
        },
        "guestRequest": None if not guest_request or guest_request.get("status") == "approved" else guest_request,
        "communityDetails": sanitized_community_details(chat.get("communityDetails")),
        "eventDetails": chat.get("eventDetails"),
        "moderationSettings": chat.get("moderationSettings"),
    }


def serialize_message(message, database):
    is_deleted = message.get("deletedForEveryoneAt") is not None
    mode = message.get("mode", "online")
    return {
        "id": message["id"],
        "chatID": message["chatID"],
        "senderID": message["senderID"],
        "clientMessageID": message.get("clientMessageID") or message["id"],
        "senderDisplayName": sender_display_name_for(message, database),
        "mode": mode,
        "deliveryState": normalized_delivery_state(message.get("deliveryState"), mode),
        "kind": message.get("kind", "text"),
        "text": None if is_deleted else message["text"],
        "attachments": [] if is_deleted else sanitized_attachments(message.get("attachments", [])),
        "replyToMessageID": message.get("replyToMessageID"),
        "replyPreview": None if is_deleted else sanitized_reply_preview(message.get("replyPreview")),
        "communityContext": None if is_deleted else sanitized_community_message_context(message.get("communityContext")),
        "deliveryOptions": None if is_deleted else sanitized_delivery_options(message.get("deliveryOptions")),
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


def sanitized_delivery_options(delivery_options):
    if not isinstance(delivery_options, dict):
        return None

    is_silent = bool(delivery_options.get("isSilent") or delivery_options.get("is_silent"))
    scheduled_at = parse_iso_timestamp(
        delivery_options.get("scheduledAt") or delivery_options.get("scheduled_at")
    )
    self_destruct_seconds = int(delivery_options.get("selfDestructSeconds") or delivery_options.get("self_destruct_seconds") or 0)
    if self_destruct_seconds <= 0:
        self_destruct_seconds = None

    if not is_silent and not scheduled_at and not self_destruct_seconds:
        return None

    return {
        "isSilent": is_silent,
        "scheduledAt": scheduled_at.isoformat() if scheduled_at else None,
        "selfDestructSeconds": self_destruct_seconds,
    }


def sanitized_community_message_context(community_context, chat=None, database=None):
    if not isinstance(community_context, dict):
        return None

    topic_id = normalized_entity_id(
        community_context.get("topicID") or community_context.get("topic_id")
    )
    parent_post_id = normalized_entity_id(
        community_context.get("parentPostID") or community_context.get("parent_post_id")
    )

    if chat and topic_id:
        community_details = sanitized_community_details(chat.get("communityDetails")) or {}
        allowed_topic_ids = {
            normalized_entity_id(topic.get("id"))
            for topic in (community_details.get("topics") or [])
            if normalized_entity_id(topic.get("id"))
        }
        if topic_id not in allowed_topic_ids:
            topic_id = None

    if chat and database and parent_post_id:
        parent_message = find_message(database, parent_post_id)
        if not parent_message or not ids_equal(parent_message.get("chatID"), chat.get("id")):
            parent_post_id = None

    if not topic_id and not parent_post_id:
        return None

    return {
        "topicID": topic_id,
        "parentPostID": parent_post_id,
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


def chat_read_marker_for(database, user_id, chat_id):
    normalized_user_id = normalized_entity_id(user_id)
    normalized_chat_id = normalized_entity_id(chat_id)
    if not normalized_user_id or not normalized_chat_id:
        return None

    return next(
        (
            marker
            for marker in database.get("chatReadMarkers", [])
            if ids_equal(marker.get("userID"), normalized_user_id)
            and ids_equal(marker.get("chatID"), normalized_chat_id)
        ),
        None,
    )


def chat_read_marker_timestamp(database, user_id, chat_id):
    marker = chat_read_marker_for(database, user_id, chat_id)
    if not marker:
        return None
    return parse_iso_datetime(marker.get("readThroughAt"))


def upsert_chat_read_marker(database, user_id, chat_id, read_through_at):
    normalized_user_id = normalized_entity_id(user_id)
    normalized_chat_id = normalized_entity_id(chat_id)
    read_through_at_value = normalized_optional_string(read_through_at)
    if not normalized_user_id or not normalized_chat_id or not read_through_at_value:
        return False

    next_timestamp = parse_iso_datetime(read_through_at_value) or datetime.now(timezone.utc)
    existing_marker = chat_read_marker_for(database, normalized_user_id, normalized_chat_id)
    if existing_marker:
        existing_timestamp = parse_iso_datetime(existing_marker.get("readThroughAt")) or datetime.min.replace(tzinfo=timezone.utc)
        if next_timestamp <= existing_timestamp:
            return False
        existing_marker["readThroughAt"] = next_timestamp.isoformat()
        return True

    database.setdefault("chatReadMarkers", []).append(
        {
            "userID": normalized_user_id,
            "chatID": normalized_chat_id,
            "readThroughAt": next_timestamp.isoformat(),
        }
    )
    return True


def unread_count_for_chat_user(database, chat, user_id):
    if not chat or chat.get("mode") != "online":
        return 0
    if not any(ids_equal(participant_id, user_id) for participant_id in (chat.get("participantIDs") or [])):
        return 0

    read_through_at = chat_read_marker_timestamp(database, user_id, chat.get("id"))

    unread_count = 0
    for message in database.get("messages", []):
        if not ids_equal(message.get("chatID"), chat.get("id")):
            continue
        if message_self_destruct_expired(message):
            continue
        if message.get("deletedForEveryoneAt"):
            continue
        if ids_equal(message.get("senderID"), user_id):
            continue

        if read_through_at:
            message_created_at = parse_iso_datetime(message.get("createdAt"))
            if message_created_at and message_created_at <= read_through_at:
                continue
        elif chat.get("type") == "direct" and normalized_optional_string(message.get("status")) == "read":
            continue

        unread_count += 1

    return unread_count


def mark_chat_read(chat, database, reader_id):
    if not chat or chat.get("mode") != "online":
        return False

    if not any(ids_equal(reader_id, participant_id) for participant_id in (chat.get("participantIDs") or [])):
        return False

    latest_incoming_at = None
    for message in database["messages"]:
        if not ids_equal(message.get("chatID"), chat.get("id")):
            continue
        if ids_equal(message.get("senderID"), reader_id):
            continue
        if message.get("deletedForEveryoneAt"):
            continue
        if message_self_destruct_expired(message):
            continue

        created_at = parse_iso_datetime(message.get("createdAt"))
        if created_at and (latest_incoming_at is None or created_at > latest_incoming_at):
            latest_incoming_at = created_at

    did_update = upsert_chat_read_marker(
        database=database,
        user_id=reader_id,
        chat_id=chat.get("id"),
        read_through_at=(latest_incoming_at.isoformat() if latest_incoming_at else now_iso()),
    )

    if chat.get("type") != "direct":
        return did_update

    did_mark_status_read = False
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
        did_mark_status_read = True

    return did_update or did_mark_status_read


def device_tokens_for_recipients(database, chat, excluding_user_id):
    recipient_ids = [
        participant_id
        for participant_id in (chat.get("participantIDs") or [])
        if not ids_equal(participant_id, excluding_user_id)
    ]
    matching_tokens = [
        device_token
        for device_token in database.get("deviceTokens", [])
        if any(ids_equal(device_token.get("userID"), recipient_id) for recipient_id in recipient_ids)
    ]
    deduplicated = []
    seen_tokens = set()
    seen_user_devices = set()
    for entry in matching_tokens:
        if is_alert_device_token_entry(entry) is False:
            continue
        token_value = normalized_apns_device_token(entry.get("token"))
        if not token_value or token_value in seen_tokens:
            continue
        recipient_user_id = normalized_entity_id(entry.get("userID"))
        recipient_device_id = normalized_device_identifier(entry.get("deviceID"))
        token_type = normalized_device_token_type(entry.get("tokenType"))
        user_device_key = (
            recipient_user_id,
            recipient_device_id,
            token_type,
        ) if recipient_user_id and recipient_device_id else None
        if user_device_key and user_device_key in seen_user_devices:
            continue
        seen_tokens.add(token_value)
        if user_device_key:
            seen_user_devices.add(user_device_key)
        deduplicated.append(entry)
    return deduplicated


def is_ios_apns_target(entry):
    platform = normalized_device_platform(entry.get("platform")) or "ios"
    return platform in {"ios", "iphone", "ipad", "ipados"}


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


def unread_badge_count_for_user(database, user_id):
    normalized_user_id = normalized_entity_id(user_id)
    if not normalized_user_id:
        return 0

    unread_count = 0
    for chat in database.get("chats", []):
        if chat.get("mode") != "online":
            continue
        if not any(ids_equal(participant_id, normalized_user_id) for participant_id in (chat.get("participantIDs") or [])):
            continue
        unread_count += unread_count_for_chat_user(database, chat, normalized_user_id)

    return max(0, unread_count)


def unread_badge_counts_for_users(user_ids):
    normalized_ids = [
        normalized_entity_id(user_id)
        for user_id in (user_ids or [])
        if normalized_entity_id(user_id)
    ]
    if not normalized_ids:
        return {}

    with LOCK:
        database = load_db()

    return {
        user_id: unread_badge_count_for_user(database, user_id)
        for user_id in normalized_ids
    }


def apns_payload_for_message(payload, badge_count):
    return {
        "aps": {
            "alert": {
                "title": payload["title"],
                "body": payload["body"],
            },
            "sound": "default",
            "badge": max(0, int(badge_count or 0)),
        },
        "chat_id": payload["chat_id"],
        "message_id": payload["message_id"],
        "mode": payload["mode"],
        "chat_type": payload["chat_type"],
    }


def push_payload_for_call(call, database):
    caller = find_user(database, call.get("callerID"))
    caller_name = resolved_user_display_name(caller) if caller else "Someone"
    issued_at = now_iso()
    return {
        "call_id": call["id"],
        "chat_id": call.get("chatID"),
        "mode": call.get("mode") or "online",
        "kind": call.get("kind") or "audio",
        "caller_id": call.get("callerID"),
        "caller_name": caller_name,
        "call_event_id": str(uuid.uuid4()),
        "issued_at": issued_at,
        "notification_type": "incoming_call",
        "title": "Incoming call",
        "body": f"{caller_name} is calling",
    }


def apns_payload_for_call(payload, badge_count, push_type="alert"):
    if push_type == "voip":
        return {
            "aps": {
                "content-available": 1,
            },
            "call_id": payload["call_id"],
            "chat_id": payload["chat_id"],
            "mode": payload["mode"],
            "kind": payload.get("kind") or "audio",
            "caller_id": payload.get("caller_id"),
            "caller_name": payload.get("caller_name"),
            "call_event_id": payload.get("call_event_id"),
            "issued_at": payload.get("issued_at"),
            "notification_type": payload.get("notification_type") or "incoming_call",
        }

    return {
        "aps": {
            "alert": {
                "title": payload["title"],
                "body": payload["body"],
            },
            "sound": "default",
            "badge": max(0, int(badge_count or 0)),
            "content-available": 1,
            "interruption-level": "time-sensitive",
            "category": "INCOMING_CALL",
        },
        "call_id": payload["call_id"],
        "chat_id": payload["chat_id"],
        "mode": payload["mode"],
        "kind": payload.get("kind") or "audio",
        "caller_id": payload.get("caller_id"),
        "caller_name": payload.get("caller_name"),
        "call_event_id": payload.get("call_event_id"),
        "issued_at": payload.get("issued_at"),
        "notification_type": payload.get("notification_type") or "incoming_call",
    }


def initial_message_status_for_dispatch(database, chat, sender_id):
    if chat.get("mode") != "online":
        return "sent"
    _ = database
    _ = sender_id
    return "sent"


def remove_device_tokens(token_values):
    token_set = {
        normalized_optional_string(token_value)
        for token_value in (token_values or [])
        if normalized_optional_string(token_value)
    }
    if not token_set:
        return 0

    with LOCK:
        database = load_db()
        existing = database.get("deviceTokens", [])
        filtered = [
            item for item in existing
            if normalized_optional_string(item.get("token")) not in token_set
        ]
        removed_count = len(existing) - len(filtered)
        if removed_count > 0:
            database["deviceTokens"] = filtered
            save_db(database)
        return removed_count


def resolve_apns_topic_for_dispatch(entry, push_type):
    entry_topic = normalized_optional_string(entry.get("topic"))
    if push_type == "voip":
        if entry_topic:
            return entry_topic
        if APNS_VOIP_TOPIC:
            return APNS_VOIP_TOPIC
        if APNS_TOPIC:
            return f"{APNS_TOPIC}.voip"
        return None
    return entry_topic or APNS_TOPIC


def mark_message_delivered_by_id(message_id):
    normalized_message_id = normalized_entity_id(message_id)
    if not normalized_message_id:
        return False

    with LOCK:
        database = load_db()
        message = find_message(database, normalized_message_id)
        if not message:
            return False
        if message.get("deletedForEveryoneAt"):
            return False
        if message.get("status") in {"delivered", "read"}:
            return False

        message["status"] = "delivered"
        save_db(database)
        return True


def dispatch_apns_notifications(dispatch_kind, device_tokens, payload, context):
    if not device_tokens:
        return

    if not APNS_PROVIDER.is_configured:
        log_event(
            f"{dispatch_kind}.dispatch.pending_provider",
            reason=APNS_PROVIDER.configuration_error,
            **context,
        )
        return

    success_count = 0
    failure_count = 0
    invalid_tokens = []
    token_suffixes = []
    used_environments = set()
    badge_counts_by_user = unread_badge_counts_for_users(
        {
            normalized_entity_id(entry.get("userID"))
            for entry in device_tokens
            if normalized_entity_id(entry.get("userID"))
        }
    )
    collapse_id = (
        f"msg-{normalized_entity_id(payload.get('message_id')) or 'unknown'}"
        if dispatch_kind == "push"
        else f"call-{normalized_entity_id(payload.get('call_id')) or 'unknown'}"
    )

    for entry in device_tokens:
        if not is_ios_apns_target(entry):
            continue
        token_type = normalized_device_token_type(entry.get("tokenType"))
        if dispatch_kind == "push" and token_type != "apns_alert":
            continue
        if dispatch_kind == "call" and token_type != "apns_voip":
            continue
        if dispatch_kind == "call_alert" and token_type != "apns_alert":
            continue

        token = normalized_apns_device_token(entry.get("token"))
        if not token:
            continue

        recipient_user_id = normalized_entity_id(entry.get("userID"))
        recipient_device_id = normalized_device_identifier(entry.get("deviceID"))
        badge_count = badge_counts_by_user.get(recipient_user_id, 0)
        token_suffix = token[-8:]
        token_suffixes.append(token_suffix)

        push_type = "alert"
        priority = "10"
        if dispatch_kind == "call":
            push_type = "voip"
            priority = "10"
        elif dispatch_kind == "call_alert":
            push_type = "alert"
            priority = "10"
        topic_override = resolve_apns_topic_for_dispatch(entry, push_type=push_type)
        if not topic_override:
            failure_count += 1
            log_event(
                f"{dispatch_kind}.dispatch.failed",
                reason="missing_apns_topic_for_token_type",
                token_type=token_type,
                token_suffix=token_suffix,
                recipient_user_id=recipient_user_id,
                recipient_device_id=recipient_device_id,
                **context,
            )
            continue

        apns_payload = (
            apns_payload_for_message(payload, badge_count=badge_count)
            if dispatch_kind == "push"
            else apns_payload_for_call(payload, badge_count=badge_count, push_type=push_type)
        )
        result = APNS_PROVIDER.send_notification(
            token,
            apns_payload,
            push_type=push_type,
            priority=priority,
            collapse_id=collapse_id,
            topic_override=topic_override,
        )
        environment_used = result.get("environment")
        if environment_used:
            used_environments.add(environment_used)
        if result["ok"]:
            success_count += 1
            continue

        failure_count += 1
        reason = result.get("reason") or "unknown"
        if reason in APNS_PROVIDER.INVALID_TOKEN_REASONS:
            invalid_tokens.append(token)
        log_event(
            f"{dispatch_kind}.dispatch.failed",
            reason=reason,
            status=result.get("status"),
            apns_id=result.get("apns_id"),
            environment=environment_used,
            token_suffix=token_suffix,
            token_type=token_type,
            topic=topic_override,
            badge_count=badge_count,
            recipient_user_id=recipient_user_id,
            recipient_device_id=recipient_device_id,
            **context,
        )

    removed_count = remove_device_tokens(invalid_tokens)
    if removed_count > 0:
        log_event(
            "push.token.removed",
            reason="invalid_or_unregistered_in_apns",
            removed_count=removed_count,
        )

    if dispatch_kind == "push" and success_count > 0:
        log_event(
            "push.message.dispatched",
            message_id=context.get("message_id"),
            chat_id=context.get("chat_id"),
            success_count=success_count,
        )

    log_event(
        f"{dispatch_kind}.dispatch.completed",
        configured_environment=APNS_PROVIDER.environment,
        used_environments=sorted(used_environments),
        topic=APNS_PROVIDER.topic,
        candidate_count=len(device_tokens),
        target_count=len(token_suffixes),
        success_count=success_count,
        failure_count=failure_count,
        collapse_id=collapse_id,
        badge_counts_by_user=badge_counts_by_user,
        token_suffixes=token_suffixes,
        **context,
    )


def schedule_apns_dispatch(dispatch_kind, device_tokens, payload, context):
    worker = threading.Thread(
        target=dispatch_apns_notifications,
        args=(dispatch_kind, device_tokens, payload, context),
        daemon=True,
    )
    worker.start()


def log_push_dispatch_attempt(database, chat, message):
    device_tokens = device_tokens_for_recipients(database, chat, message.get("senderID"))
    payload = push_payload_for_message(chat, message, database)
    recipient_ids = [
        participant_id
        for participant_id in (chat.get("participantIDs") or [])
        if not ids_equal(participant_id, message.get("senderID"))
    ]
    log_event(
        "push.dispatch.provider_state",
        configured=APNS_PROVIDER.is_configured,
        configuration_error=APNS_PROVIDER.configuration_error,
        configured_environment=APNS_PROVIDER.environment,
        topic=APNS_PROVIDER.topic,
        chat_id=chat["id"],
        message_id=message["id"],
    )

    if not device_tokens:
        recipient_token_rows = [
            token
            for token in database.get("deviceTokens", [])
            if any(ids_equal(token.get("userID"), recipient_id) for recipient_id in recipient_ids)
        ]
        platform_counts = {}
        for token_row in recipient_token_rows:
            platform_key = normalized_device_platform(token_row.get("platform")) or "unknown"
            platform_counts[platform_key] = platform_counts.get(platform_key, 0) + 1
        log_event(
            "push.dispatch.skipped",
            reason="no_device_tokens",
            chat_id=chat["id"],
            message_id=message["id"],
            recipient_count=0,
            recipient_ids=recipient_ids,
            registered_token_count=len(recipient_token_rows),
            registered_platforms=platform_counts,
        )
        return

    context = {
        "chat_id": chat["id"],
        "message_id": message["id"],
    }
    log_event(
        "push.dispatch.queued",
        recipient_count=len(device_tokens),
        **context,
    )
    schedule_apns_dispatch("push", device_tokens, payload, context)


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
    raw_sdp_mline_index = payload.get("sdpMLineIndex")
    try:
        sdp_mline_index = int(raw_sdp_mline_index) if raw_sdp_mline_index is not None else None
    except (TypeError, ValueError):
        sdp_mline_index = None
    return {
        "id": event["id"],
        "callID": event["callID"],
        "sequence": int(event.get("sequence") or 0),
        "type": event.get("type"),
        "senderID": event.get("senderID"),
        "sdp": payload.get("sdp"),
        "candidate": payload.get("candidate"),
        "sdpMid": payload.get("sdpMid"),
        "sdpMLineIndex": sdp_mline_index,
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


def any_direct_chat_record(database, first_user_id, second_user_id):
    participant_ids = set(unique_entity_ids([first_user_id, second_user_id]))
    return next(
        (
            chat for chat in database["chats"]
            if chat.get("type") == "direct"
            and set(unique_entity_ids(chat.get("participantIDs") or [])) == participant_ids
        ),
        None,
    )


def call_requires_saved_contact(database, caller, callee, mode):
    privacy_settings = privacy_settings_for(callee)
    if privacy_settings.get("allowCallsFromNonContacts", False):
        return False

    return existing_direct_chat_record(database, caller["id"], callee["id"], mode) is None


def group_invite_requires_saved_contact(database, inviter, invitee):
    if not inviter or not invitee or ids_equal(inviter.get("id"), invitee.get("id")):
        return False

    privacy_settings = privacy_settings_for(invitee)
    if privacy_settings.get("allowGroupInvitesFromNonContacts", False):
        return False

    return any_direct_chat_record(database, inviter["id"], invitee["id"]) is None


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

    log_event(
        "call.dispatch.provider_state",
        configured=APNS_PROVIDER.is_configured,
        configuration_error=APNS_PROVIDER.configuration_error,
        configured_environment=APNS_PROVIDER.environment,
        topic=APNS_PROVIDER.topic,
        voip_topic=(APNS_VOIP_TOPIC or None),
        call_id=call["id"],
        recipient_id=recipient_id,
    )

    device_tokens = [
        token for token in database.get("deviceTokens", [])
        if ids_equal(token.get("userID"), recipient_id)
    ]
    deduplicated = []
    seen_tokens = set()
    seen_user_devices = set()
    for entry in device_tokens:
        token_value = normalized_apns_device_token(entry.get("token"))
        if not token_value or token_value in seen_tokens:
            continue
        recipient_user_id = normalized_entity_id(entry.get("userID"))
        recipient_device_id = normalized_device_identifier(entry.get("deviceID"))
        token_type = normalized_device_token_type(entry.get("tokenType"))
        user_device_key = (
            recipient_user_id,
            recipient_device_id,
            token_type,
        ) if recipient_user_id and recipient_device_id else None
        if user_device_key and user_device_key in seen_user_devices:
            continue
        seen_tokens.add(token_value)
        if user_device_key:
            seen_user_devices.add(user_device_key)
        deduplicated.append(entry)
    deduplicated_tokens = deduplicated
    voip_device_tokens = [token for token in deduplicated_tokens if is_voip_device_token_entry(token)]
    alert_device_tokens = [token for token in deduplicated_tokens if is_alert_device_token_entry(token)]

    if not voip_device_tokens and not alert_device_tokens:
        log_event(
            "call.dispatch.skipped",
            reason="no_device_tokens",
            call_id=call["id"],
            recipient_id=recipient_id,
        )
        return

    payload = push_payload_for_call(call, database)
    context = {
        "call_id": call["id"],
        "recipient_id": recipient_id,
    }
    log_event(
        "call.dispatch.queued",
        voip_recipient_count=len(voip_device_tokens),
        alert_recipient_count=len(alert_device_tokens),
        **context,
    )
    if voip_device_tokens:
        schedule_apns_dispatch("call", voip_device_tokens, payload, context)
    if alert_device_tokens:
        schedule_apns_dispatch(
            "call_alert",
            alert_device_tokens,
            payload,
            {
                **context,
                "fallback": "alert",
            },
        )


class Handler(BaseHTTPRequestHandler):
    def do_OPTIONS(self):
        self.send_response(204)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_GET(self):
        parsed = urlparse(self.path)

        if parsed.path == "/health":
            ice_capabilities = call_ice_capabilities(CALL_ICE_SERVERS)
            return self.respond(200, {
                "status": "ok",
                "serverBuildID": SERVER_BUILD_ID,
                "serverStartedAt": SERVER_STARTED_AT,
                "serverCodeMTime": SERVER_CODE_MTIME,
                "serverFunctions": {
                    "resolved_user_display_name": callable(globals().get("resolved_user_display_name")),
                    "display_name_for_user": callable(globals().get("display_name_for_user")),
                    "push_payload_for_call": callable(globals().get("push_payload_for_call")),
                    "log_call_dispatch_attempt": callable(globals().get("log_call_dispatch_attempt")),
                },
                "callIce": ice_capabilities,
                "mediaStorage": MEDIA_OBJECT_STORAGE.status_payload(),
            })

        if parsed.path.startswith("/avatars/"):
            return self.serve_avatar(parsed.path.removeprefix("/avatars/"))

        if parsed.path.startswith("/media/"):
            return self.serve_media(parsed.path.removeprefix("/media/"))

        if self.serve_website_route(parsed.path):
            return

        with LOCK:
            database = load_db()
            did_prune_self_destruct = prune_expired_self_destruct_messages(database)
            if did_prune_self_destruct:
                save_db(database)

            if parsed.path == "/admin/summary":
                admin_error = admin_request_error(database, self.headers)
                if admin_error:
                    return self.respond(401 if admin_error in {"admin_not_configured", "admin_token_required", "admin_auth_required"} else 403, {"error": admin_error})
                return self.respond(200, admin_summary_payload(database))

            if parsed.path == "/admin/users":
                admin_error = admin_request_error(database, self.headers)
                if admin_error:
                    return self.respond(401 if admin_error in {"admin_not_configured", "admin_token_required", "admin_auth_required"} else 403, {"error": admin_error})

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
                    return self.respond(401 if admin_error in {"admin_not_configured", "admin_token_required", "admin_auth_required"} else 403, {"error": admin_error})

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
                    return self.respond(401 if admin_error in {"admin_not_configured", "admin_token_required", "admin_auth_required"} else 403, {"error": admin_error})

                params = parse_qs(parsed.query)
                chat_id = normalized_entity_id((params.get("chat_id") or [""])[0].strip())
                chat = find_chat(database, chat_id)
                if not chat:
                    return self.respond(404, {"error": "chat_not_found"})

                messages = [
                    serialize_message(message, database)
                    for message in database.get("messages", [])
                    if ids_equal(message.get("chatID"), chat_id)
                    and not message_self_destruct_expired(message)
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
                return self.respond(200, serialize_user(user, user))

            if parsed.path == "/auth/2fa-status":
                user, _, auth_error = authenticated_user(database, self.headers)
                if auth_error == "user_not_found":
                    return self.respond(404, {"error": "user_not_found"})
                if auth_error:
                    return self.respond(401, {"error": auth_error})
                return self.respond(200, security_settings_for(user))

            if parsed.path == "/devices":
                user, current_session, auth_error = authenticated_user(database, self.headers)
                if auth_error == "user_not_found":
                    return self.respond(404, {"error": "user_not_found"})
                if auth_error:
                    return self.respond(401, {"error": auth_error})

                sessions = []
                for session in database.get("sessions", []):
                    if not ids_equal(session.get("userID"), user.get("id")):
                        continue
                    sessions.append({
                        "id": session.get("id"),
                        "platform": normalized_optional_string(session.get("platform")) or "unknown",
                        "deviceName": normalized_optional_string(session.get("deviceName")),
                        "deviceModel": normalized_optional_string(session.get("deviceModel")),
                        "osName": normalized_optional_string(session.get("osName")),
                        "osVersion": normalized_optional_string(session.get("osVersion")),
                        "appVersion": normalized_optional_string(session.get("appVersion")),
                        "lastActiveAt": normalized_optional_string(session.get("updatedAt")) or now_iso(),
                        "isCurrent": ids_equal(session.get("id"), current_session.get("id")),
                    })

                sessions.sort(key=lambda item: item.get("lastActiveAt") or "", reverse=True)
                return self.respond(200, sessions)

            if parsed.path == "/usernames/check":
                params = parse_qs(parsed.query)
                username = (params.get("username") or [""])[0].strip().lower()
                user_id = normalized_entity_id((params.get("user_id") or [""])[0].strip() or None)
                available = bool(username) and is_valid_username(normalize_username(username)) and not username_taken(database, username, user_id)
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
                    serialize_user(user, current_user)
                    for user in database["users"]
                    if not ids_equal(user["id"], current_user["id"]) and (
                        query in user["profile"]["username"].lower() or
                        query in user["profile"]["displayName"].lower() or
                        query in (user["profile"].get("email") or "").lower() or
                        query in (user["profile"].get("phoneNumber") or "").lower()
                    )
                ]
                return self.respond(200, users[:20])

            if parsed.path == "/communities/search":
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

                query = (params.get("query") or [""])[0].strip().lower()
                mode = (params.get("mode") or ["online"])[0].strip()
                if not query:
                    return self.respond(200, [])

                chats = []
                for chat in database.get("chats", []):
                    if chat.get("type") != "group" or chat.get("mode") != mode:
                        continue
                    if not chat_is_publicly_joinable(chat):
                        continue

                    title = chat_title_for(chat, current_user["id"], database).lower()
                    subtitle = chat_subtitle_for(chat, current_user["id"], database).lower()
                    invite_code = (sanitized_community_details(chat.get("communityDetails")) or {}).get("inviteCode") or ""

                    if query not in title and query not in subtitle and query not in invite_code.lower():
                        continue

                    chats.append(serialize_chat(chat, current_user["id"], database))

                chats.sort(key=lambda item: item["lastActivityAt"], reverse=True)
                return self.respond(200, chats[:20])

            if parsed.path.startswith("/invites/"):
                path_components = parsed.path.strip("/").split("/")
                if len(path_components) != 2:
                    return self.respond(404, {"error": "not_found"})

                fallback_user_id = (
                    (parse_qs(parsed.query).get("user_id") or [""])[0].strip()
                    or (parse_qs(parsed.query).get("viewer_id") or [""])[0].strip()
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

                chat = find_chat_by_invite_code(database, path_components[1])
                if not chat:
                    return self.respond(404, {"error": "invite_not_found"})

                return self.respond(200, serialize_chat(chat, current_user["id"], database))

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
                params = parse_qs(parsed.query)
                viewer_hint = (
                    (params.get("viewer_id") or [""])[0].strip()
                    or (params.get("user_id") or [""])[0].strip()
                    or None
                )
                current_user = optional_request_viewer(database, self.headers, viewer_hint)
                user = find_user(database, user_id)
                if not user:
                    return self.respond(404, {"error": "user_not_found"})
                return self.respond(200, serialize_user(user, current_user))

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

            if parsed.path == "/calls/ice-config":
                params = parse_qs(parsed.query)
                fallback_user_id = (
                    (params.get("user_id") or [""])[0].strip()
                    or (params.get("viewer_id") or [""])[0].strip()
                    or None
                )
                _, _, auth_error = request_user_with_fallback(
                    database,
                    self.headers,
                    fallback_user_id,
                    create_if_missing=True
                )
                if auth_error == "user_not_found":
                    return self.respond(404, {"error": "user_not_found"})
                if auth_error:
                    return self.respond(401, {"error": auth_error})

                return self.respond(200, {"iceServers": CALL_ICE_SERVERS})

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

            if parsed.path == "/calls/history":
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
                    if call_involves_user(call, current_user["id"])
                ]
                calls.sort(
                    key=lambda item: item.get("endedAt") or item.get("answeredAt") or item.get("createdAt") or "",
                    reverse=True,
                )
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
                    did_backfill = backfill_pending_guest_request(chat, database) or did_backfill
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

                raw_messages = [
                    item
                    for item in database["messages"]
                    if ids_equal(item.get("chatID"), chat["id"])
                    and not message_self_destruct_expired(item)
                ]
                did_backfill = backfill_pending_guest_request(chat, database)
                did_backfill = backfill_group_member_snapshots(chat, database) or did_backfill
                did_backfill = mark_messages_delivered(chat, database, current_user["id"]) or did_backfill
                for message in raw_messages:
                    did_backfill = backfill_sender_display_name(message, database) or did_backfill
                if did_backfill:
                    save_db(database)

                messages = [serialize_message(item, database) for item in raw_messages]
                messages.sort(key=lambda item: item["createdAt"])
                return self.respond(200, messages)

            if parsed.path.startswith("/chats/") and parsed.path.endswith("/moderation/dashboard"):
                params = parse_qs(parsed.query)
                fallback_user_id = (params.get("user_id") or [""])[0].strip() or None
                requester, _, auth_error = request_user_with_fallback(
                    database,
                    self.headers,
                    fallback_user_id,
                    create_if_missing=True
                )
                if auth_error == "user_not_found":
                    return self.respond(404, {"error": "user_not_found"})
                if auth_error:
                    return self.respond(401, {"error": auth_error})

                chat_id = normalized_entity_id(parsed.path.split("/")[2])
                chat = find_chat(database, chat_id)
                if not chat:
                    return self.respond(404, {"error": "chat_not_found"})
                if chat.get("type") != "group":
                    return self.respond(409, {"error": "invalid_group_chat"})
                if not can_manage_group(chat, requester["id"]):
                    return self.respond(403, {"error": "group_permission_denied"})

                return self.respond(200, moderation_dashboard_payload(chat, database))

        if self.serve_website_route(parsed.path):
            return

        return self.respond(404, {"error": "not_found"})

    def do_POST(self):
        parsed = urlparse(self.path)
        if parsed.path == "/media/upload":
            return self.handle_media_upload(parsed)
        return self.handle_mutation("POST")

    def do_PATCH(self):
        return self.handle_mutation("PATCH")

    def do_DELETE(self):
        return self.handle_mutation("DELETE")

    def handle_media_upload(self, parsed):
        params = parse_qs(parsed.query)
        fallback_user_id = (
            (params.get("user_id") or [""])[0].strip()
            or (params.get("requester_id") or [""])[0].strip()
            or None
        )

        with LOCK:
            database = load_db()
            did_prune_self_destruct = prune_expired_self_destruct_messages(database)
            if did_prune_self_destruct:
                save_db(database)
            requester, _, auth_error = request_user_with_fallback(
                database,
                self.headers,
                fallback_user_id,
                create_if_missing=False
            )

        if auth_error == "user_not_found":
            return self.respond(404, {"error": "user_not_found"})
        if auth_error:
            return self.respond(401, {"error": auth_error})

        try:
            content_length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            content_length = 0

        if content_length <= 0:
            return self.respond(409, {"error": "empty_upload"})

        file_name = (
            normalized_optional_string(self.headers.get("X-Prime-Upload-File-Name"))
            or normalized_optional_string((params.get("file_name") or [""])[0])
            or "upload.bin"
        )
        mime_type = (
            normalized_optional_string(self.headers.get("X-Prime-Upload-Mime-Type"))
            or normalized_optional_string(self.headers.get("Content-Type"))
            or "application/octet-stream"
        )
        upload_kind = (
            normalized_optional_string(self.headers.get("X-Prime-Upload-Kind"))
            or normalized_optional_string((params.get("kind") or [""])[0])
            or "attachment"
        )

        log_event(
            "media.upload.begin",
            requester_id=requester["id"],
            file_name=file_name,
            mime_type=mime_type,
            byte_size=content_length,
            upload_kind=upload_kind,
        )

        try:
            media_name, stored_size, sha256 = save_streamed_blob(
                MEDIA_DIR,
                file_name,
                self.rfile,
                content_length,
                mime_type=mime_type,
                upload_kind=upload_kind,
            )
        except ValueError as error:
            log_event(
                "media.upload.failed",
                requester_id=requester["id"],
                file_name=file_name,
                mime_type=mime_type,
                byte_size=content_length,
                upload_kind=upload_kind,
                error=str(error),
            )
            return self.respond(409, {"error": str(error)})

        normalized_mime_type = None
        try:
            media_name, stored_size, sha256, normalized_mime_type = normalize_uploaded_video_mp4(
                MEDIA_DIR,
                media_name,
                upload_kind,
            )
        except ValueError as error:
            log_event(
                "media.upload.normalize.failed",
                requester_id=requester["id"],
                file_name=file_name,
                stored_file_name=media_name,
                mime_type=mime_type,
                byte_size=stored_size,
                upload_kind=upload_kind,
                error=str(error),
            )
            try:
                os.remove(os.path.join(MEDIA_DIR, media_name))
            except OSError:
                pass
            return self.respond(409, {"error": str(error)})

        if normalized_mime_type:
            mime_type = normalized_mime_type

        try:
            finalise_media_blob_storage(
                file_name=media_name,
                mime_type=mime_type,
                byte_size=stored_size,
                sha256=sha256,
                upload_kind=upload_kind,
            )
        except ValueError as error:
            log_event(
                "media.upload.storage.failed",
                requester_id=requester["id"],
                file_name=media_name,
                mime_type=mime_type,
                byte_size=stored_size,
                upload_kind=upload_kind,
                error=str(error),
            )
            try:
                os.remove(os.path.join(MEDIA_DIR, media_name))
            except OSError:
                pass
            return self.respond(409, {"error": str(error)})

        remote_url = f"{self.base_url()}/media/{media_name}"
        log_event(
            "media.upload.complete",
            requester_id=requester["id"],
            file_name=media_name,
            mime_type=mime_type,
            byte_size=stored_size,
            upload_kind=upload_kind,
            remote_url=remote_url,
            sha256=sha256,
            storage_backend=MEDIA_OBJECT_STORAGE.backend,
        )
        return self.respond(200, {
            "fileName": media_name,
            "mimeType": mime_type,
            "byteSize": stored_size,
            "remoteURL": remote_url,
            "sha256": sha256,
        })

    def handle_mutation(self, method):
        parsed = urlparse(self.path)
        payload = self.read_json()

        with LOCK:
            database = load_db()
            did_prune_self_destruct = prune_expired_self_destruct_messages(database)
            if did_prune_self_destruct:
                save_db(database)

            if method == "POST" and parsed.path == "/admin/cleanup/legacy-placeholders":
                admin_error = admin_request_error(database, self.headers)
                if admin_error:
                    return self.respond(401 if admin_error in {"admin_not_configured", "admin_token_required", "admin_auth_required"} else 403, {"error": admin_error})

                removed_count = delete_legacy_placeholder_users(database)
                save_db(database)
                return self.respond(200, {"ok": True, "removed": removed_count})

            if method == "POST" and parsed.path == "/admin/users/bulk-delete":
                admin_error = admin_request_error(database, self.headers)
                if admin_error:
                    return self.respond(401 if admin_error in {"admin_not_configured", "admin_token_required", "admin_auth_required"} else 403, {"error": admin_error})

                user_ids = payload.get("user_ids") or payload.get("userIDs") or []
                if not isinstance(user_ids, list):
                    user_ids = []

                removed_count, skipped_count = bulk_delete_users(database, user_ids)
                save_db(database)
                return self.respond(200, {"ok": True, "removed": removed_count, "skipped": skipped_count})

            if method == "POST" and parsed.path == "/admin/users/create":
                admin_error = admin_request_error(database, self.headers)
                if admin_error:
                    return self.respond(401 if admin_error in {"admin_not_configured", "admin_token_required", "admin_auth_required"} else 403, {"error": admin_error})

                username = normalize_username(payload.get("username", ""))
                display_name = normalized_optional_string(payload.get("display_name")) or username
                password = str(payload.get("password", "")).strip()
                account_kind = normalized_optional_string(payload.get("account_kind")) or "standard"
                if account_kind not in {"standard", "offlineOnly", "guest"}:
                    account_kind = "standard"

                if not is_valid_legacy_username(username):
                    return self.respond(409, {"error": "invalid_username"})
                if username_taken(database, username):
                    return self.respond(409, {"error": "username_taken"})
                if not password:
                    return self.respond(409, {"error": "invalid_credentials"})

                user_id = str(uuid.uuid4())
                user = {
                    "id": user_id,
                    "password": password,
                    "profile": {
                        "displayName": display_name,
                        "username": username,
                        "bio": "Welcome to Prime Messaging.",
                        "status": "Available",
                        "birthday": None,
                        "email": None,
                        "phoneNumber": None,
                        "profilePhotoURL": None,
                        "socialLink": None,
                    },
                    "identityMethods": build_identity_methods(username),
                    "privacySettings": default_privacy_settings(),
                    "accountKind": account_kind,
                    "createdAt": now_iso(),
                    "guestExpiresAt": expires_at_iso(GUEST_ACCOUNT_LIFETIME_SECONDS) if account_kind == "guest" else None,
                }
                database["users"].append(user)
                ensure_saved_messages_chat(database, user_id, "online")
                ensure_saved_messages_chat(database, user_id, "offline")
                save_db(database)
                return self.respond(200, admin_user_payload(database, user))

            if method == "POST" and parsed.path.startswith("/admin/users/") and parsed.path.endswith("/ban"):
                admin_error = admin_request_error(database, self.headers)
                if admin_error:
                    return self.respond(401 if admin_error in {"admin_not_configured", "admin_token_required", "admin_auth_required"} else 403, {"error": admin_error})

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

            if method == "PATCH" and parsed.path.startswith("/admin/chats/") and parsed.path.endswith("/official"):
                admin_error = admin_request_error(database, self.headers)
                if admin_error:
                    return self.respond(401 if admin_error in {"admin_not_configured", "admin_token_required", "admin_auth_required"} else 403, {"error": admin_error})

                path_parts = parsed.path.strip("/").split("/")
                chat_id = normalized_entity_id(path_parts[2] if len(path_parts) > 2 else None)
                if not chat_id:
                    return self.respond(404, {"error": "chat_not_found"})

                chat = find_chat(database, chat_id)
                if not chat:
                    return self.respond(404, {"error": "chat_not_found"})
                if chat.get("type") != "group":
                    return self.respond(409, {"error": "invalid_group_chat"})

                existing_details = sanitized_community_details(chat.get("communityDetails")) or {}
                if existing_details.get("kind") not in {"channel", "community"}:
                    return self.respond(409, {"error": "invalid_group_chat"})

                admin_user, _, auth_error = authenticated_user(database, self.headers)
                if auth_error or not admin_user:
                    return self.respond(401, {"error": "admin_auth_required"})

                requested_is_official = payload.get("is_official")
                if requested_is_official is None and "isOfficial" in payload:
                    requested_is_official = payload.get("isOfficial")

                try:
                    updated_details = normalized_community_details(
                        {"isOfficial": bool(requested_is_official)},
                        database,
                        existing_details=existing_details,
                        requester=admin_user
                    )
                except PermissionError as error:
                    return self.respond(403, {"error": str(error)})

                chat["communityDetails"] = updated_details
                save_db(database)
                return self.respond(200, serialize_chat(chat, admin_user["id"], database))

            if method == "DELETE" and parsed.path.startswith("/admin/users/"):
                admin_error = admin_request_error(database, self.headers)
                if admin_error:
                    return self.respond(401 if admin_error in {"admin_not_configured", "admin_token_required", "admin_auth_required"} else 403, {"error": admin_error})

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
                username = normalize_username(payload.get("username", ""))
                requested_user_id = normalized_entity_id(payload.get("user_id"))
                existing_requested_user = find_user(database, requested_user_id) if requested_user_id else None
                account_kind = (payload.get("account_kind") or "standard").strip() or "standard"
                if account_kind not in {"standard", "offlineOnly", "guest"}:
                    return self.respond(409, {"error": "invalid_account_kind"})
                if not is_valid_username(username) or username_taken(database, username, requested_user_id):
                    return self.respond(409, {"error": "username_taken"})

                if existing_requested_user and not is_legacy_placeholder_user(existing_requested_user):
                    return self.respond(409, {"error": "user_id_taken"})

                user_id = requested_user_id or str(uuid.uuid4())
                method_type = payload.get("method_type", "email")
                contact_value = payload.get("contact_value")
                normalized_email = None
                normalized_phone_number = None

                if account_kind == "standard":
                    normalized_phone_number = normalize_phone_number(contact_value)
                    if method_type != "phone" or not is_valid_phone_number(normalized_phone_number):
                        return self.respond(409, {"error": "invalid_phone_number"})
                    if phone_number_taken(database, normalized_phone_number, requested_user_id):
                        return self.respond(409, {"error": "phone_taken"})
                elif account_kind == "offlineOnly":
                    normalized_email = normalize_email(contact_value)
                    if method_type != "email" or not is_valid_email(normalized_email):
                        return self.respond(409, {"error": "invalid_email"})
                    if email_taken(database, normalized_email, requested_user_id):
                        return self.respond(409, {"error": "email_taken"})
                elif account_kind == "guest":
                    method_type = "username"

                birthday = normalized_optional_string(payload.get("birthday"))
                email = contact_value if method_type == "email" else None
                phone_number = contact_value if method_type == "phone" else None
                email = normalized_email if normalized_email is not None else email
                phone_number = normalized_phone_number if normalized_phone_number is not None else phone_number
                if existing_requested_user and is_legacy_placeholder_user(existing_requested_user):
                    user = existing_requested_user
                    user["password"] = payload.get("password", "")
                    user["profile"] = {
                        "displayName": payload.get("display_name", ""),
                        "username": username,
                        "bio": user["profile"].get("bio") or "Welcome to Prime Messaging.",
                        "status": user["profile"].get("status") or "Available",
                        "birthday": birthday,
                        "email": email,
                        "phoneNumber": phone_number,
                        "profilePhotoURL": user["profile"].get("profilePhotoURL"),
                        "socialLink": user["profile"].get("socialLink"),
                    }
                    user["identityMethods"] = build_identity_methods(username, email=email, phone_number=phone_number)
                    user["privacySettings"] = user.get("privacySettings") or default_privacy_settings()
                    user["accountKind"] = account_kind
                    user["createdAt"] = user.get("createdAt") or now_iso()
                    user["guestExpiresAt"] = expires_at_iso(GUEST_ACCOUNT_LIFETIME_SECONDS) if account_kind == "guest" else None
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
                            "birthday": birthday,
                            "email": email,
                            "phoneNumber": phone_number,
                            "profilePhotoURL": None,
                            "socialLink": None,
                        },
                        "identityMethods": build_identity_methods(username, email=email, phone_number=phone_number),
                        "privacySettings": default_privacy_settings(),
                        "accountKind": account_kind,
                        "createdAt": now_iso(),
                        "guestExpiresAt": expires_at_iso(GUEST_ACCOUNT_LIFETIME_SECONDS) if account_kind == "guest" else None,
                    }
                    database["users"].append(user)
                ensure_saved_messages_chat(database, user_id, "online")
                ensure_saved_messages_chat(database, user_id, "offline")
                session, access_token, refresh_token = issue_session(
                    database,
                    user_id,
                    device_metadata=session_device_metadata_from_headers(self.headers)
                )
                save_db(database)
                return self.respond(200, session_payload(user, session, access_token, refresh_token))

            if method == "POST" and parsed.path == "/auth/account-lookup":
                identifier = payload.get("identifier", "")
                user = find_user_by_identifier(database, identifier)
                if not user:
                    return self.respond(200, {"exists": False, "accountKind": None, "displayName": None})

                display_name = normalized_optional_string(user.get("profile", {}).get("displayName"))
                return self.respond(
                    200,
                    {
                        "exists": True,
                        "accountKind": (user.get("accountKind") or "standard").strip() or "standard",
                        "displayName": display_name,
                    }
                )

            if method == "POST" and parsed.path == "/auth/otp-login":
                identifier = payload.get("identifier", "")
                otp_code = str(payload.get("otp_code", "")).strip()
                if otp_code != DEFAULT_OTP_CODE:
                    return self.respond(401, {"error": "invalid_otp"})
                user = find_user_by_identifier(database, identifier)
                if not user:
                    return self.respond(404, {"error": "user_not_found"})
                if is_user_banned(user):
                    return self.respond(403, {"error": "account_banned"})
                session, access_token, refresh_token = issue_session(
                    database,
                    user["id"],
                    device_metadata=session_device_metadata_from_headers(self.headers)
                )
                save_db(database)
                return self.respond(200, session_payload(user, session, access_token, refresh_token))

            if method == "POST" and parsed.path == "/auth/login":
                identifier = str(payload.get("identifier", "")).strip().lower()
                password = str(payload.get("password", ""))
                user = find_user_by_identifier(database, identifier)
                if not user:
                    return self.respond(404, {"error": "user_not_found"})
                if is_user_banned(user):
                    return self.respond(403, {"error": "account_banned"})
                if user.get("password") != password:
                    return self.respond(401, {"error": "invalid_credentials"})
                session, access_token, refresh_token = issue_session(
                    database,
                    user["id"],
                    device_metadata=session_device_metadata_from_headers(self.headers)
                )
                save_db(database)
                return self.respond(200, session_payload(user, session, access_token, refresh_token))

            if method == "POST" and parsed.path == "/auth/reset-password":
                identifier = payload.get("identifier", "")
                new_password = str(payload.get("new_password", "")).strip()
                user = find_user_by_identifier(database, identifier)
                if not user:
                    return self.respond(404, {"error": "user_not_found"})
                if not new_password:
                    return self.respond(409, {"error": "invalid_credentials"})
                user["password"] = new_password
                save_db(database)
                return self.respond(200, {"ok": True})

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
                if is_user_banned(user):
                    return self.respond(403, {"error": "account_banned"})

                access_token, new_refresh_token = rotate_session(
                    session,
                    device_metadata=session_device_metadata_from_headers(self.headers)
                )
                save_db(database)
                return self.respond(200, session_payload(user, session, access_token, new_refresh_token))

            if method == "POST" and parsed.path == "/auth/2fa-enable":
                user, _, auth_error = authenticated_user(database, self.headers)
                if auth_error == "user_not_found":
                    return self.respond(404, {"error": "user_not_found"})
                if auth_error:
                    return self.respond(401, {"error": auth_error})

                code = str(payload.get("code") or "").strip()
                if len(code) < 4:
                    return self.respond(409, {"error": "invalid_2fa_code"})

                backup_codes = make_backup_codes()
                security_settings = user.get("securitySettings") or {}
                security_settings["twoFactor"] = {
                    "enabled": True,
                    "codeHash": hash_security_code(code),
                    "backupCodeHashes": [hash_security_code(item) for item in backup_codes],
                    "updatedAt": now_iso(),
                }
                user["securitySettings"] = security_settings
                save_db(database)
                return self.respond(200, {
                    "ok": True,
                    "backupCodes": backup_codes,
                    "backupCodesRemaining": len(backup_codes),
                })

            if method == "POST" and parsed.path == "/auth/2fa-disable":
                user, _, auth_error = authenticated_user(database, self.headers)
                if auth_error == "user_not_found":
                    return self.respond(404, {"error": "user_not_found"})
                if auth_error:
                    return self.respond(401, {"error": auth_error})

                provided_code = str(payload.get("code") or "").strip()
                provided_backup_code = str(payload.get("backup_code") or payload.get("backupCode") or "").strip().upper()
                security_settings = user.get("securitySettings") or {}
                two_factor = security_settings.get("twoFactor") or {}
                if not two_factor.get("enabled"):
                    return self.respond(200, {"ok": True, "backupCodesRemaining": 0})

                expected_code_hash = two_factor.get("codeHash") or ""
                backup_hashes = [str(item) for item in (two_factor.get("backupCodeHashes") or []) if str(item)]
                valid_code = provided_code and hmac.compare_digest(hash_security_code(provided_code), expected_code_hash)
                backup_hash = hash_security_code(provided_backup_code) if provided_backup_code else None
                valid_backup = backup_hash in backup_hashes if backup_hash else False
                if valid_code is False and valid_backup is False:
                    return self.respond(401, {"error": "invalid_2fa_code"})

                security_settings["twoFactor"] = {
                    "enabled": False,
                    "codeHash": None,
                    "backupCodeHashes": [],
                    "updatedAt": now_iso(),
                }
                user["securitySettings"] = security_settings
                save_db(database)
                return self.respond(200, {"ok": True, "backupCodesRemaining": 0})

            if method == "POST" and parsed.path == "/auth/2fa-regenerate-backup":
                user, _, auth_error = authenticated_user(database, self.headers)
                if auth_error == "user_not_found":
                    return self.respond(404, {"error": "user_not_found"})
                if auth_error:
                    return self.respond(401, {"error": auth_error})

                provided_code = str(payload.get("code") or "").strip()
                security_settings = user.get("securitySettings") or {}
                two_factor = security_settings.get("twoFactor") or {}
                if not two_factor.get("enabled"):
                    return self.respond(409, {"error": "2fa_not_enabled"})

                expected_code_hash = two_factor.get("codeHash") or ""
                if not provided_code or hmac.compare_digest(hash_security_code(provided_code), expected_code_hash) is False:
                    return self.respond(401, {"error": "invalid_2fa_code"})

                backup_codes = make_backup_codes()
                two_factor["backupCodeHashes"] = [hash_security_code(item) for item in backup_codes]
                two_factor["updatedAt"] = now_iso()
                security_settings["twoFactor"] = two_factor
                user["securitySettings"] = security_settings
                save_db(database)
                return self.respond(200, {
                    "ok": True,
                    "backupCodes": backup_codes,
                    "backupCodesRemaining": len(backup_codes),
                })

            if method == "POST" and parsed.path == "/devices/revoke-others":
                user, current_session, auth_error = authenticated_user(database, self.headers)
                if auth_error == "user_not_found":
                    return self.respond(404, {"error": "user_not_found"})
                if auth_error:
                    return self.respond(401, {"error": auth_error})

                previous_count = len(database.get("sessions", []))
                current_session_id = current_session.get("id")
                database["sessions"] = [
                    session
                    for session in database.get("sessions", [])
                    if not ids_equal(session.get("userID"), user.get("id")) or ids_equal(session.get("id"), current_session_id)
                ]
                revoked_count = max(previous_count - len(database["sessions"]), 0)
                save_db(database)
                return self.respond(200, {"ok": True, "revoked": revoked_count})

            if method == "DELETE" and parsed.path.startswith("/devices/"):
                user, current_session, auth_error = authenticated_user(database, self.headers)
                if auth_error == "user_not_found":
                    return self.respond(404, {"error": "user_not_found"})
                if auth_error:
                    return self.respond(401, {"error": auth_error})

                session_id = normalized_entity_id(parsed.path.split("/")[2])
                if not session_id:
                    return self.respond(404, {"error": "session_not_found"})

                target_session = next(
                    (
                        session for session in database.get("sessions", [])
                        if ids_equal(session.get("id"), session_id) and ids_equal(session.get("userID"), user.get("id"))
                    ),
                    None
                )
                if not target_session:
                    return self.respond(404, {"error": "session_not_found"})

                if ids_equal(target_session.get("id"), current_session.get("id")):
                    return self.respond(409, {"error": "cannot_revoke_current_session"})

                database["sessions"] = [
                    session for session in database.get("sessions", [])
                    if not ids_equal(session.get("id"), session_id)
                ]
                save_db(database)
                return self.respond(200, {"ok": True})

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
                if not is_valid_username(normalize_username(username)):
                    return self.respond(409, {"error": "invalid_username"})
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
                current_user, _, auth_error = request_user_with_fallback(
                    database,
                    self.headers,
                    payload_string(payload, "user_id", "userID", "current_user_id", "currentUserID"),
                    create_if_missing=False
                )
                if auth_error == "user_not_found":
                    return self.respond(404, {"error": "user_not_found"})
                if auth_error:
                    return self.respond(401, {"error": auth_error})

                token = normalized_apns_device_token(payload.get("token"))
                platform = normalized_device_platform(payload.get("platform")) or "ios"
                token_type = normalized_device_token_type(
                    payload_string(payload, "token_type", "tokenType")
                )
                topic = normalized_optional_string(payload.get("topic"))
                device_id = normalized_device_identifier(
                    payload_string(payload, "device_id", "deviceID")
                )
                if not token:
                    return self.respond(409, {"error": "invalid_device_token"})

                previous_count = len(database["deviceTokens"])
                database["deviceTokens"] = [
                    entry for entry in database["deviceTokens"]
                    if normalized_apns_device_token(entry.get("token")) != token
                    and not (
                        device_id
                        and normalized_device_identifier(entry.get("deviceID")) == device_id
                        and normalized_device_token_type(entry.get("tokenType")) == token_type
                    )
                ]
                database["deviceTokens"].append(
                    {
                        "id": str(uuid.uuid4()),
                        "userID": current_user["id"],
                        "token": token,
                        "platform": platform,
                        "tokenType": token_type,
                        "topic": topic,
                        "deviceID": device_id,
                        "updatedAt": now_iso(),
                    }
                )
                replaced_count = max(0, previous_count - len(database["deviceTokens"]) + 1)
                save_db(database)
                log_event(
                    "push.token.registered",
                    user_id=current_user["id"],
                    platform=platform,
                    token_type=token_type,
                    topic=topic,
                    token_suffix=(token[-8:] if token else None),
                    device_id_suffix=(device_id[-8:] if device_id else None),
                    replaced_count=replaced_count,
                )
                return self.respond(200, {"ok": True, "replacedCount": replaced_count})

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
                log_event(
                    "call.signal.offer.received",
                    call_id=call.get("id"),
                    sender_id=requester.get("id"),
                    sequence=event.get("sequence"),
                    sdp_size=len(payload_string(payload, "sdp") or ""),
                )
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
                log_event(
                    "call.signal.answer.received",
                    call_id=call.get("id"),
                    sender_id=requester.get("id"),
                    sequence=event.get("sequence"),
                    sdp_size=len(payload_string(payload, "sdp") or ""),
                )
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
                log_event(
                    "call.signal.ice.received",
                    call_id=call.get("id"),
                    sender_id=requester.get("id"),
                    sequence=event.get("sequence"),
                    candidate_size=len(payload_string(payload, "candidate") or ""),
                    sdp_mid=payload_string(payload, "sdp_mid", "sdpMid"),
                    sdp_mline_index=payload.get("sdp_mline_index", payload.get("sdpMLineIndex")),
                )
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

                username = normalize_username(payload.get("username", current_user["profile"]["username"]))
                current_username = normalize_username(current_user["profile"]["username"])
                if username == current_username:
                    if not is_valid_legacy_username(username):
                        return self.respond(409, {"error": "invalid_username"})
                elif not is_valid_username(username):
                    return self.respond(409, {"error": "invalid_username"})
                if username_taken(database, username, user_id):
                    return self.respond(409, {"error": "username_taken"})

                current_account_kind = (current_user.get("accountKind") or "standard").strip() or "standard"
                email = normalize_email(payload.get("email"))
                phone_number = normalize_phone_number(payload.get("phone_number"))
                if email and not is_valid_email(email):
                    return self.respond(409, {"error": "invalid_email"})
                if phone_number and not is_valid_phone_number(phone_number):
                    return self.respond(409, {"error": "invalid_phone_number"})
                if email and email_taken(database, email, user_id):
                    return self.respond(409, {"error": "email_taken"})
                if phone_number and phone_number_taken(database, phone_number, user_id):
                    return self.respond(409, {"error": "phone_taken"})
                if current_account_kind == "offlineOnly":
                    phone_number = None
                if current_account_kind == "guest":
                    email = current_user["profile"].get("email")
                    phone_number = current_user["profile"].get("phoneNumber")
                current_user["profile"] = {
                    "displayName": payload.get("display_name", current_user["profile"]["displayName"]),
                    "username": username,
                    "bio": payload.get("bio", current_user["profile"]["bio"]),
                    "status": payload.get("status", current_user["profile"]["status"]),
                    "birthday": normalized_optional_string(payload.get("birthday", current_user["profile"].get("birthday"))),
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
                return self.respond(200, serialize_user(current_user, current_user))

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
                for key in ("showEmail", "showPhoneNumber", "allowLastSeen", "allowProfilePhoto", "allowCallsFromNonContacts", "allowGroupInvitesFromNonContacts", "allowForwardLinkToProfile"):
                    if key in incoming:
                        updated_settings[key] = bool(incoming.get(key))
                if "guestMessageRequests" in incoming:
                    guest_policy = normalized_optional_string(incoming.get("guestMessageRequests")) or "approvalRequired"
                    if guest_policy not in {"approvalRequired", "blocked"}:
                        guest_policy = "approvalRequired"
                    updated_settings["guestMessageRequests"] = guest_policy

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
                if (current_user.get("accountKind") or "standard") == "guest":
                    return self.respond(403, {"error": "guest_limited_profile"})

                remove_file_for_url(current_user["profile"].get("profilePhotoURL"), AVATAR_DIR)
                raw = base64.b64decode(payload.get("image_base64", ""))
                avatar_name = f"{user_id}.png"
                avatar_path = os.path.join(AVATAR_DIR, avatar_name)
                with open(avatar_path, "wb") as file:
                    file.write(raw)

                current_user["profile"]["profilePhotoURL"] = f"{self.base_url()}/avatars/{avatar_name}"
                save_db(database)
                return self.respond(200, serialize_user(current_user, current_user))

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
                return self.respond(200, serialize_user(current_user, current_user))

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

                requester_is_guest = (current_user.get("accountKind") or "standard") == "guest"
                recipient_is_guest = (other_user.get("accountKind") or "standard") == "guest"
                recipient_policy = guest_request_policy_for(other_user)

                if existing is None:
                    if requester_is_guest and not recipient_is_guest and recipient_policy == "blocked":
                        return self.respond(403, {"error": "guest_requests_blocked"})
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

                existing_request = direct_chat_guest_request(existing)
                if requester_is_guest and not recipient_is_guest:
                    if existing_request is None and recipient_policy == "approvalRequired":
                        existing["guestRequest"] = {
                            "requesterUserID": current_user_id,
                            "recipientUserID": other_user_id,
                            "status": "pending",
                            "introText": None,
                            "createdAt": now_iso(),
                            "respondedAt": None,
                        }

                save_db(database)

                return self.respond(200, serialize_chat(existing, current_user_id, database))

            if method == "POST" and parsed.path.startswith("/chats/") and parsed.path.endswith("/guest-request"):
                chat_id = normalized_entity_id(parsed.path.split("/")[2])
                requester, _, auth_error = request_user_with_fallback(
                    database,
                    self.headers,
                    payload_string(payload, "requester_id", "requesterID", "user_id", "userID"),
                    create_if_missing=True
                )
                if auth_error == "user_not_found":
                    return self.respond(404, {"error": "user_not_found"})
                if auth_error:
                    return self.respond(401, {"error": auth_error})

                chat = find_chat(database, chat_id)
                if not chat or chat.get("type") != "direct":
                    return self.respond(404, {"error": "chat_not_found"})
                if not any(ids_equal(requester["id"], participant_id) for participant_id in (chat.get("participantIDs") or [])):
                    return self.respond(403, {"error": "sender_not_in_chat"})

                guest_request = direct_chat_guest_request(chat)
                if not guest_request or guest_request.get("status") != "pending":
                    return self.respond(409, {"error": "guest_request_pending"})
                if not ids_equal(guest_request.get("requesterUserID"), requester["id"]):
                    return self.respond(409, {"error": "guest_request_approval_required"})

                intro_text = normalized_optional_string(payload_string(payload, "intro_text", "introText", "text"))
                if not intro_text:
                    return self.respond(409, {"error": "guest_request_intro_required"})
                if len(intro_text) > 150:
                    return self.respond(409, {"error": "guest_request_intro_too_long"})

                guest_request["introText"] = intro_text
                chat["guestRequest"] = guest_request
                save_db(database)
                return self.respond(200, serialize_chat(chat, requester["id"], database))

            if method == "PATCH" and parsed.path.startswith("/chats/") and parsed.path.endswith("/guest-request"):
                chat_id = normalized_entity_id(parsed.path.split("/")[2])
                responder, _, auth_error = request_user_with_fallback(
                    database,
                    self.headers,
                    payload_string(payload, "responder_id", "responderID", "user_id", "userID"),
                    create_if_missing=True
                )
                if auth_error == "user_not_found":
                    return self.respond(404, {"error": "user_not_found"})
                if auth_error:
                    return self.respond(401, {"error": auth_error})

                chat = find_chat(database, chat_id)
                if not chat or chat.get("type") != "direct":
                    return self.respond(404, {"error": "chat_not_found"})
                if not any(ids_equal(responder["id"], participant_id) for participant_id in (chat.get("participantIDs") or [])):
                    return self.respond(403, {"error": "sender_not_in_chat"})

                guest_request = direct_chat_guest_request(chat)
                if not guest_request or guest_request.get("status") != "pending":
                    return self.respond(409, {"error": "guest_request_pending"})
                if not ids_equal(guest_request.get("recipientUserID"), responder["id"]):
                    return self.respond(403, {"error": "group_permission_denied"})

                action = (payload.get("action") or "").strip().lower()
                if action not in {"approve", "decline"}:
                    return self.respond(409, {"error": "invalid_group_operation"})

                guest_request["status"] = "approved" if action == "approve" else "declined"
                guest_request["respondedAt"] = now_iso()
                chat["guestRequest"] = guest_request
                save_db(database)
                return self.respond(200, serialize_chat(chat, responder["id"], database))

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

                for participant_id in participant_ids:
                    invitee = find_user(database, participant_id)
                    if group_invite_requires_saved_contact(database, current_user, invitee):
                        return self.respond(403, {"error": "group_invites_blocked"})

                try:
                    community_details = normalized_community_details(
                        payload.get("community_details"),
                        database,
                        existing_details=None,
                        requester=current_user
                    )
                except PermissionError as error:
                    return self.respond(403, {"error": str(error)})

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
                    "communityDetails": community_details,
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
                incoming_moderation_settings = payload.get("moderation_settings")

                chat = find_chat(database, chat_id)
                if not chat:
                    return self.respond(404, {"error": "chat_not_found"})
                if chat.get("type") != "group":
                    return self.respond(409, {"error": "invalid_group_chat"})
                if not can_manage_group(chat, requester_id):
                    return self.respond(403, {"error": "group_permission_denied"})
                if not updated_title and incoming_moderation_settings is None:
                    return self.respond(409, {"error": "invalid_group_operation"})

                if updated_title:
                    chat["group"]["title"] = updated_title
                    chat["cachedTitle"] = updated_title
                if incoming_moderation_settings is not None:
                    chat["moderationSettings"] = normalized_group_moderation_settings(
                        incoming_moderation_settings,
                        existing_settings=chat.get("moderationSettings")
                    )
                save_db(database)
                return self.respond(200, serialize_chat(chat, requester_id, database))

            if method == "PATCH" and parsed.path.startswith("/chats/") and parsed.path.endswith("/community"):
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

                try:
                    community_details = normalized_community_details(
                        payload.get("community_details"),
                        database,
                        existing_details=chat.get("communityDetails"),
                        requester=requester
                    )
                except PermissionError as error:
                    return self.respond(403, {"error": str(error)})

                if not community_details:
                    return self.respond(409, {"error": "invalid_group_operation"})

                chat["communityDetails"] = community_details
                save_db(database)
                return self.respond(200, serialize_chat(chat, requester_id, database))

            if method == "DELETE" and parsed.path.startswith("/chats/") and parsed.path.endswith("/group"):
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

                group = chat.get("group") or {}
                if not ids_equal(group.get("ownerID"), requester_id):
                    return self.respond(403, {"error": "group_permission_denied"})

                remove_file_for_url(group.get("photoURL"), AVATAR_DIR)
                database["chats"] = [
                    item for item in database.get("chats", [])
                    if not ids_equal(item.get("id"), chat_id)
                ]
                database["messages"] = [
                    message for message in database.get("messages", [])
                    if not ids_equal(message.get("chatID"), chat_id)
                ]
                save_db(database)
                return self.respond(200, {"ok": True})

            if method == "POST" and parsed.path.startswith("/chats/") and parsed.path.endswith("/join"):
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
                if not chat_is_publicly_joinable(chat):
                    return self.respond(403, {"error": "chat_not_public"})
                if is_group_banned(chat, requester_id):
                    save_db(database)
                    return self.respond(403, {"error": "user_banned"})
                moderation_settings = chat.get("moderationSettings") or {}
                if moderation_settings.get("requiresJoinApproval"):
                    return self.respond(409, {"error": "join_approval_required"})
                if any(ids_equal(requester_id, participant_id) for participant_id in (chat.get("participantIDs") or [])):
                    return self.respond(200, serialize_chat(chat, requester_id, database))

                chat["participantIDs"] = unique_entity_ids((chat.get("participantIDs") or []) + [requester_id])
                group = chat.get("group") or {}
                members = group.get("members") or []
                members.append(group_member_payload(database, requester_id, "member"))
                group["members"] = members
                chat["group"] = group
                community_details = chat.get("communityDetails") or {}
                if community_details.get("kind") == "channel":
                    chat["cachedSubtitle"] = f"{len(members)} subscribers"
                else:
                    chat["cachedSubtitle"] = f"{len(members)} members"

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
                    invitee = find_user(database, member_id)
                    if not invitee:
                        return self.respond(404, {"error": "user_not_found"})
                    if member_id in participant_ids:
                        continue
                    if group_invite_requires_saved_contact(database, requester, invitee):
                        return self.respond(403, {"error": "group_invites_blocked"})

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

            if method == "PATCH" and parsed.path.startswith("/chats/") and parsed.path.endswith("/group/owner"):
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
                member_user_id = normalized_entity_id(payload.get("member_id"))

                chat = find_chat(database, chat_id)
                if not chat:
                    return self.respond(404, {"error": "chat_not_found"})
                if chat.get("type") != "group":
                    return self.respond(409, {"error": "invalid_group_chat"})
                if not can_transfer_group_ownership(chat, requester_id, member_user_id):
                    return self.respond(403, {"error": "group_permission_denied"})
                if transfer_group_ownership(chat, member_user_id) is False:
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

            if method == "POST" and parsed.path.startswith("/invites/") and parsed.path.endswith("/join"):
                path_components = parsed.path.strip("/").split("/")
                if len(path_components) != 3:
                    return self.respond(404, {"error": "not_found"})

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

                chat = find_chat_by_invite_code(database, path_components[1])
                if not chat:
                    return self.respond(404, {"error": "invite_not_found"})
                if chat.get("type") != "group":
                    return self.respond(409, {"error": "invalid_group_chat"})
                if is_group_banned(chat, requester_id):
                    save_db(database)
                    return self.respond(403, {"error": "user_banned"})
                moderation_settings = chat.get("moderationSettings") or {}
                if moderation_settings.get("requiresJoinApproval"):
                    return self.respond(409, {"error": "join_approval_required"})
                if any(ids_equal(requester_id, participant_id) for participant_id in (chat.get("participantIDs") or [])):
                    return self.respond(200, serialize_chat(chat, requester_id, database))

                chat["participantIDs"] = unique_entity_ids((chat.get("participantIDs") or []) + [requester_id])
                group = chat.get("group") or {}
                members = group.get("members") or []
                members.append(group_member_payload(database, requester_id, "member"))
                group["members"] = members
                chat["group"] = group
                community_details = chat.get("communityDetails") or {}
                if community_details.get("kind") == "channel":
                    chat["cachedSubtitle"] = f"{len(members)} subscribers"
                else:
                    chat["cachedSubtitle"] = f"{len(members)} members"

                save_db(database)
                return self.respond(200, serialize_chat(chat, requester_id, database))

            if method == "POST" and parsed.path.startswith("/chats/") and parsed.path.endswith("/join-request"):
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
                if not chat_is_publicly_joinable(chat):
                    return self.respond(403, {"error": "chat_not_public"})
                if is_group_banned(chat, requester_id):
                    save_db(database)
                    return self.respond(403, {"error": "user_banned"})
                if any(ids_equal(requester_id, participant_id) for participant_id in (chat.get("participantIDs") or [])):
                    return self.respond(200, {"ok": True})

                moderation_settings = chat.get("moderationSettings") or {}
                if not moderation_settings.get("requiresJoinApproval"):
                    return self.respond(409, {"error": "invalid_group_operation"})

                raw_answers = payload.get("answers") or []
                answers = []
                if isinstance(raw_answers, list):
                    for item in raw_answers:
                        answer = normalized_optional_string(item)
                        if answer:
                            answers.append(answer[:180])

                existing_requests = chat.setdefault("joinRequests", [])
                existing_index = next(
                    (index for index, item in enumerate(existing_requests) if ids_equal(item.get("requesterUserID"), requester_id)),
                    None
                )
                request_payload = {
                    "id": existing_requests[existing_index].get("id") if existing_index is not None else str(uuid.uuid4()),
                    "requesterUserID": requester_id,
                    "requesterDisplayName": resolved_user_display_name(requester),
                    "requesterUsername": (requester.get("profile") or {}).get("username"),
                    "answers": answers[:5],
                    "status": "pending",
                    "createdAt": existing_requests[existing_index].get("createdAt") if existing_index is not None else now_iso(),
                    "resolvedAt": None,
                    "reviewedByUserID": None,
                }
                if existing_index is None:
                    existing_requests.append(request_payload)
                else:
                    existing_requests[existing_index] = request_payload

                save_db(database)
                return self.respond(200, {"ok": True})

            if method == "GET" and parsed.path.startswith("/chats/") and parsed.path.endswith("/moderation/dashboard"):
                chat_id = normalized_entity_id(parsed.path.split("/")[2])
                params = parse_qs(parsed.query)
                fallback_user_id = (params.get("user_id") or [""])[0].strip() or None
                requester, _, auth_error = request_user_with_fallback(
                    database,
                    self.headers,
                    fallback_user_id,
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

                save_db(database)
                return self.respond(200, moderation_dashboard_payload(chat, database))

            if method == "POST" and parsed.path.startswith("/chats/") and "/join-requests/" in parsed.path:
                path_components = parsed.path.strip("/").split("/")
                if len(path_components) < 5:
                    return self.respond(404, {"error": "not_found"})

                chat_id = normalized_entity_id(path_components[1])
                target_user_id = normalized_entity_id(path_components[3])
                action = path_components[4]
                if action not in {"approve", "decline"}:
                    return self.respond(404, {"error": "not_found"})

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

                requests = chat.get("joinRequests") or []
                request = next((item for item in requests if ids_equal(item.get("requesterUserID"), target_user_id)), None)
                if not request:
                    return self.respond(404, {"error": "user_not_found"})

                request["status"] = "approved" if action == "approve" else "declined"
                request["resolvedAt"] = now_iso()
                request["reviewedByUserID"] = requester_id

                if action == "approve":
                    if is_group_banned(chat, target_user_id):
                        save_db(database)
                        return self.respond(403, {"error": "user_banned"})
                    if any(ids_equal(target_user_id, participant_id) for participant_id in (chat.get("participantIDs") or [])) is False:
                        chat["participantIDs"] = unique_entity_ids((chat.get("participantIDs") or []) + [target_user_id])
                        group = chat.get("group") or {}
                        members = group.get("members") or []
                        members.append(group_member_payload(database, target_user_id, "member"))
                        group["members"] = members
                        chat["group"] = group
                        community_details = chat.get("communityDetails") or {}
                        if community_details.get("kind") == "channel":
                            chat["cachedSubtitle"] = f"{len(members)} subscribers"
                        else:
                            chat["cachedSubtitle"] = f"{len(members)} members"

                save_db(database)
                return self.respond(200, moderation_dashboard_payload(chat, database))

            if method == "POST" and parsed.path.startswith("/chats/") and parsed.path.endswith("/reports"):
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
                if not any(ids_equal(requester_id, participant_id) for participant_id in (chat.get("participantIDs") or [])):
                    return self.respond(403, {"error": "sender_not_in_chat"})

                report_payload = sanitized_report_record(
                    {
                        "id": str(uuid.uuid4()),
                        "reporterUserID": requester_id,
                        "targetChatID": chat_id,
                        "targetMessageID": payload.get("target_message_id"),
                        "targetUserID": payload.get("target_user_id"),
                        "reason": payload.get("reason"),
                        "details": payload.get("details"),
                    },
                    database
                )
                if not report_payload:
                    return self.respond(409, {"error": "invalid_group_operation"})

                chat.setdefault("reports", []).append(report_payload)
                save_db(database)
                return self.respond(200, {"ok": True})

            if method == "POST" and parsed.path.startswith("/chats/") and parsed.path.endswith("/bans"):
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
                target_user_id = normalized_entity_id(payload.get("member_id"))

                chat = find_chat(database, chat_id)
                if not chat:
                    return self.respond(404, {"error": "chat_not_found"})
                if chat.get("type") != "group":
                    return self.respond(409, {"error": "invalid_group_chat"})
                if not can_manage_group(chat, requester_id):
                    return self.respond(403, {"error": "group_permission_denied"})
                if not target_user_id or ids_equal(target_user_id, requester_id) or ids_equal((chat.get("group") or {}).get("ownerID"), target_user_id):
                    return self.respond(409, {"error": "invalid_group_operation"})

                target_member = find_group_member(chat, target_user_id)
                if target_member and not can_remove_group_member(chat, requester_id, target_user_id):
                    return self.respond(403, {"error": "group_permission_denied"})

                duration_seconds = payload.get("duration_seconds") or 0
                try:
                    duration_seconds = max(3600, int(duration_seconds))
                except (TypeError, ValueError):
                    duration_seconds = 86400

                banned_until = (datetime.now(timezone.utc) + timedelta(seconds=duration_seconds)).isoformat()
                ban_payload = sanitized_group_ban_record(
                    {
                        "id": str(uuid.uuid4()),
                        "userID": target_user_id,
                        "reason": payload.get("reason"),
                        "createdAt": now_iso(),
                        "bannedUntil": banned_until,
                        "bannedByUserID": requester_id,
                    },
                    database
                )
                if not ban_payload:
                    return self.respond(409, {"error": "invalid_group_operation"})

                bans = [ban for ban in active_group_bans(chat) if not ids_equal(ban.get("userID"), target_user_id)]
                bans.append(ban_payload)
                chat["bannedMembers"] = bans
                chat["joinRequests"] = [
                    item for item in (chat.get("joinRequests") or [])
                    if not ids_equal(item.get("requesterUserID"), target_user_id)
                ]
                if target_member:
                    remove_group_member(chat, target_user_id)

                save_db(database)
                return self.respond(200, moderation_dashboard_payload(chat, database))

            if method == "DELETE" and parsed.path.startswith("/chats/") and "/bans/" in parsed.path:
                path_components = parsed.path.strip("/").split("/")
                if len(path_components) < 4:
                    return self.respond(404, {"error": "not_found"})

                chat_id = normalized_entity_id(path_components[1])
                target_user_id = normalized_entity_id(path_components[3])
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

                previous_count = len(chat.get("bannedMembers") or [])
                chat["bannedMembers"] = [
                    ban for ban in active_group_bans(chat)
                    if not ids_equal(ban.get("userID"), target_user_id)
                ]
                if previous_count == len(chat.get("bannedMembers") or []):
                    return self.respond(404, {"error": "user_not_found"})

                save_db(database)
                return self.respond(200, moderation_dashboard_payload(chat, database))

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

                did_backfill_guest_request = backfill_pending_guest_request(chat, database)
                guest_request = direct_chat_guest_request(chat)
                if chat.get("type") == "direct":
                    other_user = direct_chat_other_user(chat, sender_id, database)
                    sender_is_guest = (sender.get("accountKind") or "standard") == "guest"
                    other_is_guest = (other_user.get("accountKind") or "standard") == "guest" if other_user else False
                    recipient_policy = guest_request_policy_for(other_user) if other_user else "approvalRequired"

                    if sender_is_guest and not other_is_guest and recipient_policy == "blocked":
                        if did_backfill_guest_request:
                            save_db(database)
                        return self.respond(403, {"error": "guest_requests_blocked"})

                    if guest_request and guest_request.get("status") != "approved":
                        if guest_request.get("status") == "declined":
                            if did_backfill_guest_request:
                                save_db(database)
                            return self.respond(409, {"error": "guest_request_declined"})
                        if ids_equal(guest_request.get("requesterUserID"), sender_id):
                            if not normalized_optional_string(guest_request.get("introText")):
                                if did_backfill_guest_request:
                                    save_db(database)
                                return self.respond(409, {"error": "guest_request_intro_required"})
                            if did_backfill_guest_request:
                                save_db(database)
                            return self.respond(409, {"error": "guest_request_pending"})
                        if did_backfill_guest_request:
                            save_db(database)
                        return self.respond(409, {"error": "guest_request_approval_required"})

                sender_display_name = normalized_optional_string(payload.get("sender_display_name")) or resolved_user_display_name(sender)
                text = normalized_optional_string(payload.get("text"))
                mode = str(payload.get("mode", "online")).strip()
                if chat.get("mode") != mode:
                    return self.respond(409, {"error": "chat_mode_mismatch"})

                kind = str(payload.get("kind", "text")).strip() or "text"
                client_message_id = normalized_entity_id(payload.get("client_message_id")) or str(uuid.uuid4())
                created_at = (
                    parse_iso_timestamp(payload.get("created_at")) or datetime.now(timezone.utc)
                ).isoformat()
                requested_delivery_state = normalized_delivery_state(payload.get("delivery_state"), mode)
                reply_to_message_id = normalized_entity_id(payload.get("reply_to_message_id"))
                reply_target_message = find_message(database, reply_to_message_id) if reply_to_message_id else None
                if reply_to_message_id and not reply_target_message:
                    reply_to_message_id = None
                reply_preview = sanitized_reply_preview(payload.get("reply_preview"))
                community_context = sanitized_community_message_context(
                    payload.get("community_context"),
                    chat=chat,
                    database=database
                )
                delivery_options = sanitized_delivery_options(payload.get("delivery_options"))
                community_details = sanitized_community_details(chat.get("communityDetails")) or {}
                if community_details.get("kind") == "channel":
                    can_manage_channel = can_manage_group(chat, sender_id)
                    parent_post_id = (community_context or {}).get("parentPostID")
                    if parent_post_id:
                        if not community_details.get("commentsEnabled"):
                            return self.respond(409, {"error": "channel_comments_disabled"})
                    elif not can_manage_channel:
                        return self.respond(403, {"error": "channel_posting_restricted"})
                if reply_to_message_id and not reply_preview and reply_target_message:
                    reply_preview = {
                        "senderID": reply_target_message.get("senderID"),
                        "senderDisplayName": sender_display_name_for(reply_target_message, database),
                        "previewText": message_preview(reply_target_message),
                    }
                attachments = []
                for attachment in payload.get("attachments", []):
                    file_name = attachment.get("file_name") or "attachment.bin"
                    attachment_type = attachment.get("type", "document")
                    attachment_mime_type = attachment.get("mime_type", "application/octet-stream")
                    remote_url = None
                    byte_size = int(attachment.get("byte_size") or 0)
                    if attachment.get("data_base64"):
                        try:
                            media_name, detected_size = save_base64_blob(
                                MEDIA_DIR,
                                file_name,
                                attachment.get("data_base64"),
                                mime_type=attachment_mime_type,
                                upload_kind=attachment_type or "attachment",
                            )
                        except ValueError as error:
                            return self.respond(409, {"error": str(error)})
                        remote_url = f"{self.base_url()}/media/{media_name}"
                        byte_size = detected_size
                    elif attachment.get("remote_url"):
                        remote_url = normalized_optional_string(attachment.get("remote_url"))
                        file_info = media_file_info_for_url(remote_url, MEDIA_DIR)
                        if not file_info:
                            return self.respond(409, {"error": "uploaded_media_not_found"})
                        byte_size = file_info["byteSize"]

                    attachments.append(
                        {
                            "id": str(uuid.uuid4()),
                            "type": attachment_type,
                            "fileName": file_name,
                            "mimeType": attachment_mime_type,
                            "localURL": None,
                            "remoteURL": remote_url,
                            "byteSize": byte_size,
                        }
                    )

                voice_payload = payload.get("voice_message")
                voice_message = None
                if voice_payload:
                    remote_url = None
                    byte_size = int(voice_payload.get("byte_size") or 0)
                    if voice_payload.get("data_base64"):
                        try:
                            media_name, detected_size = save_base64_blob(
                                MEDIA_DIR,
                                voice_payload.get("file_name") or "voice.m4a",
                                voice_payload.get("data_base64"),
                                mime_type=voice_payload.get("mime_type") or "audio/mp4",
                                upload_kind="voice",
                            )
                        except ValueError as error:
                            return self.respond(409, {"error": str(error)})
                        remote_url = f"{self.base_url()}/media/{media_name}"
                        byte_size = detected_size
                    elif voice_payload.get("remote_url"):
                        remote_url = normalized_optional_string(voice_payload.get("remote_url"))
                        file_info = media_file_info_for_url(remote_url, MEDIA_DIR)
                        if not file_info:
                            return self.respond(409, {"error": "uploaded_media_not_found"})
                        byte_size = file_info["byteSize"]

                    voice_message = {
                        "durationSeconds": int(voice_payload.get("duration_seconds") or 0),
                        "waveformSamples": voice_payload.get("waveform_samples") or [],
                        "byteSize": byte_size,
                        "localFileURL": None,
                        "remoteFileURL": remote_url,
                    }

                existing_message = next(
                    (
                        item
                        for item in database["messages"]
                        if ids_equal(item.get("chatID"), chat["id"])
                        and ids_equal(item.get("senderID"), sender_id)
                        and ids_equal(item.get("clientMessageID"), client_message_id)
                    ),
                    None,
                )
                initial_status = initial_message_status_for_dispatch(database, chat, sender_id)
                recipient_token_count = len(device_tokens_for_recipients(database, chat, sender_id))
                if existing_message:
                    existing_message["mode"] = mode
                    existing_message["kind"] = existing_message.get("kind") or kind
                    existing_message["clientMessageID"] = existing_message.get("clientMessageID") or client_message_id
                    existing_message["deliveryState"] = merge_delivery_states(
                        existing_message.get("deliveryState"),
                        requested_delivery_state,
                        mode,
                    )
                    existing_message["createdAt"] = existing_message.get("createdAt") or created_at
                    existing_message["senderDisplayName"] = existing_message.get("senderDisplayName") or sender_display_name
                    if existing_message.get("replyToMessageID") is None and reply_to_message_id:
                        existing_message["replyToMessageID"] = reply_to_message_id
                    if not existing_message.get("replyPreview") and reply_preview:
                        existing_message["replyPreview"] = reply_preview
                    if not existing_message.get("communityContext") and community_context:
                        existing_message["communityContext"] = community_context
                    if not existing_message.get("deliveryOptions") and delivery_options:
                        existing_message["deliveryOptions"] = delivery_options
                    if not normalized_optional_string(existing_message.get("text")) and text:
                        existing_message["text"] = text
                    if not existing_message.get("attachments") and attachments:
                        existing_message["attachments"] = attachments
                    if not existing_message.get("voiceMessage") and voice_message:
                        existing_message["voiceMessage"] = voice_message
                    if message_status_rank(initial_status) > message_status_rank(existing_message.get("status")):
                        existing_message["status"] = initial_status
                    save_db(database)
                    log_event(
                        "message.send.duplicate",
                        chat_id=chat["id"],
                        message_id=existing_message.get("id"),
                        sender_id=sender_id,
                        status=existing_message.get("status"),
                        computed_initial_status=initial_status,
                        recipient_token_count=recipient_token_count,
                    )
                    return self.respond(200, serialize_message(existing_message, database))

                message = {
                    "id": str(uuid.uuid4()),
                    "chatID": chat["id"],
                    "senderID": sender_id,
                    "clientMessageID": client_message_id,
                    "senderDisplayName": sender_display_name,
                    "mode": mode,
                    "deliveryState": requested_delivery_state,
                    "kind": kind,
                    "text": text,
                    "attachments": attachments,
                    "replyToMessageID": reply_to_message_id,
                    "replyPreview": reply_preview,
                    "communityContext": community_context,
                    "deliveryOptions": delivery_options,
                    "voiceMessage": voice_message,
                    "status": initial_status,
                    "createdAt": created_at,
                    "editedAt": None,
                    "deletedForEveryoneAt": None,
                    "reactions": [],
                }
                backfill_group_member_snapshots(chat, database)
                database["messages"].append(message)
                save_db(database)
                log_event(
                    "message.send.accepted",
                    chat_id=chat["id"],
                    message_id=message["id"],
                    sender_id=sender_id,
                    status=message.get("status"),
                    recipient_token_count=recipient_token_count,
                )
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
                    user_ids = [
                        reaction_user_id
                        for reaction_user_id in unique_entity_ids(target_reaction.get("userIDs") or [])
                        if not ids_equal(reaction_user_id, requester_id)
                    ]
                    if len(user_ids) == len(unique_entity_ids(target_reaction.get("userIDs") or [])):
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
        media_file_name = os.path.basename(media_name or "")
        if not media_file_name:
            return self.respond(404, {"error": "media_not_found"})

        range_header = self.headers.get("Range")
        media_path = os.path.join(MEDIA_DIR, media_file_name)

        remote_info = None
        if MEDIA_OBJECT_STORAGE.is_enabled and MEDIA_OBJECT_STORAGE.is_configured:
            try:
                remote_info = MEDIA_OBJECT_STORAGE.head_by_name(media_file_name)
            except Exception as error:
                log_event(
                    "media.remote.head_failed",
                    file_name=media_file_name,
                    storage_backend=MEDIA_OBJECT_STORAGE.backend,
                    error=type(error).__name__,
                )
                remote_info = None

        if remote_info:
            file_size = int(remote_info.get("byteSize") or 0)
            range_info = resolved_media_byte_range(range_header, file_size)
            if range_info["invalid"]:
                self.send_response(416)
                self.send_header("Content-Range", f"bytes */{file_size}")
                self.send_header("Accept-Ranges", "bytes")
                self.end_headers()
                log_event(
                    "media.serve.range_invalid",
                    file_name=media_file_name,
                    source=MEDIA_OBJECT_STORAGE.backend,
                    range_header=range_header,
                    file_size=file_size,
                )
                return

            status = range_info["status"]
            start = range_info["start"]
            end = range_info["end"]
            content_length = range_info["length"]
            content_type = media_content_type_for_name(media_file_name, remote_info.get("mimeType"))

            try:
                stream_response = MEDIA_OBJECT_STORAGE.stream_by_name(
                    media_file_name,
                    start=start if status == 206 else None,
                    end=end if status == 206 else None,
                )
            except ClientError as error:
                code = (
                    (error.response or {}).get("Error", {}).get("Code")
                    if hasattr(error, "response")
                    else None
                )
                if str(code) in {"404", "NoSuchKey", "NotFound"}:
                    return self.respond(404, {"error": "media_not_found"})
                log_event(
                    "media.serve.remote_failed",
                    file_name=media_file_name,
                    source=MEDIA_OBJECT_STORAGE.backend,
                    range_header=range_header,
                    file_size=file_size,
                    error=str(code or type(error).__name__),
                )
                return self.respond(409, {"error": "media_stream_failed"})
            except Exception as error:
                log_event(
                    "media.serve.remote_failed",
                    file_name=media_file_name,
                    source=MEDIA_OBJECT_STORAGE.backend,
                    range_header=range_header,
                    file_size=file_size,
                    error=type(error).__name__,
                )
                return self.respond(409, {"error": "media_stream_failed"})

            self.send_response(status)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Disposition", "inline")
            self.send_header("Content-Length", str(content_length))
            self.send_header("Accept-Ranges", "bytes")
            if status == 206:
                self.send_header("Content-Range", f"bytes {start}-{end}/{file_size}")
            self.end_headers()

            streamed = 0
            body_stream = stream_response.get("Body")
            try:
                while streamed < content_length:
                    chunk = body_stream.read(min(64 * 1024, content_length - streamed))
                    if not chunk:
                        break
                    self.wfile.write(chunk)
                    streamed += len(chunk)
            finally:
                if body_stream is not None:
                    body_stream.close()

            log_event(
                "media.serve",
                file_name=media_file_name,
                source=MEDIA_OBJECT_STORAGE.backend,
                status=status,
                content_type=content_type,
                file_size=file_size,
                range_header=range_header,
                range_start=start,
                range_end=end,
                content_length=content_length,
                streamed_length=streamed,
            )
            return

        if not os.path.exists(media_path):
            if MEDIA_OBJECT_STORAGE.is_enabled and not MEDIA_OBJECT_STORAGE.is_configured:
                log_event(
                    "media.serve.storage_not_configured",
                    file_name=media_file_name,
                    storage_backend=MEDIA_OBJECT_STORAGE.backend,
                    reason=MEDIA_OBJECT_STORAGE.configuration_error,
                )
                return self.respond(503, {"error": "media_object_storage_not_configured"})
            return self.respond(404, {"error": "media_not_found"})

        content_type = media_content_type_for_name(media_path)
        file_size = os.path.getsize(media_path)
        range_info = resolved_media_byte_range(range_header, file_size)
        if range_info["invalid"]:
            self.send_response(416)
            self.send_header("Content-Range", f"bytes */{file_size}")
            self.send_header("Accept-Ranges", "bytes")
            self.end_headers()
            log_event(
                "media.serve.range_invalid",
                file_name=os.path.basename(media_path),
                source="local",
                range_header=range_header,
                file_size=file_size,
            )
            return

        status = range_info["status"]
        start = range_info["start"]
        end = range_info["end"]
        content_length = range_info["length"]
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Disposition", "inline")
        self.send_header("Content-Length", str(content_length))
        self.send_header("Accept-Ranges", "bytes")
        if status == 206:
            self.send_header("Content-Range", f"bytes {start}-{end}/{file_size}")
        self.end_headers()
        log_event(
            "media.serve",
            file_name=os.path.basename(media_path),
            source="local",
            status=status,
            content_type=content_type,
            file_size=file_size,
            range_header=range_header,
            range_start=start,
            range_end=end,
            content_length=content_length,
        )

        with open(media_path, "rb") as file:
            file.seek(start)
            remaining = content_length
            while remaining > 0:
                chunk = file.read(min(64 * 1024, remaining))
                if not chunk:
                    break
                self.wfile.write(chunk)
                remaining -= len(chunk)

    def serve_website_route(self, request_path):
        if not os.path.isdir(WEBSITE_DIR):
            return False

        normalized_path = request_path or "/"
        if normalized_path == "/":
            relative_path = "index.html"
        else:
            relative_path = os.path.normpath(normalized_path.lstrip("/"))

        if relative_path.startswith(".."):
            return False

        file_path = os.path.join(WEBSITE_DIR, relative_path)
        if os.path.isdir(file_path):
            file_path = os.path.join(file_path, "index.html")

        if not os.path.isfile(file_path):
            return False

        content_type, _ = mimetypes.guess_type(file_path)
        if content_type is None:
            content_type = "application/octet-stream"

        with open(file_path, "rb") as file:
            body = file.read()

        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
        return True

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

    def end_headers(self):
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, PATCH, DELETE, OPTIONS")
        self.send_header(
            "Access-Control-Allow-Headers",
            "Authorization, Content-Type, "
            "X-Prime-Admin-Token, X-Prime-Admin-Login, X-Prime-Admin-Password, "
            "X-Prime-Upload-File-Name, X-Prime-Upload-Mime-Type, X-Prime-Upload-Kind, "
            "X-Prime-Platform, X-Prime-Device-Name, X-Prime-Device-Model, "
            "X-Prime-OS-Name, X-Prime-OS-Version, X-Prime-App-Version"
        )
        self.send_header("Access-Control-Expose-Headers", "Accept-Ranges, Content-Length, Content-Range, Content-Type")
        self.send_header("Access-Control-Max-Age", "86400")
        super().end_headers()

    def base_url(self):
        if PUBLIC_BASE_URL:
            return PUBLIC_BASE_URL
        host = self.headers.get("Host", "127.0.0.1:8080")
        return f"http://{host}"

    def log_message(self, format, *args):
        return


if __name__ == "__main__":
    ensure_storage()
    ice_capabilities = call_ice_capabilities(CALL_ICE_SERVERS)
    log_event(
        "server.startup",
        build_id=SERVER_BUILD_ID,
        started_at=SERVER_STARTED_AT,
        code_mtime=SERVER_CODE_MTIME,
        python_version=os.sys.version.split()[0],
        backend_file=os.path.basename(__file__),
        call_ice_count=ice_capabilities["count"],
        call_ice_has_turn=ice_capabilities["hasTurn"],
        call_ice_has_turns=ice_capabilities["hasTurns"],
    )
    key_source = "inline_env" if APNS_KEY_P8 else "path"
    if APNS_PROVIDER.is_configured:
        log_event(
            "apns.provider.ready",
            environment=APNS_PROVIDER.environment,
            topic=APNS_PROVIDER.topic,
            key_id=APNS_PROVIDER.key_id,
            key_path=APNS_PROVIDER.key_path,
            key_source=key_source,
        )
    else:
        log_event(
            "apns.provider.disabled",
            reason=APNS_PROVIDER.configuration_error,
            environment=APNS_PROVIDER.environment,
            topic=APNS_PROVIDER.topic,
            key_id=APNS_PROVIDER.key_id,
            key_path=APNS_PROVIDER.key_path,
            key_source=key_source,
        )
    if MEDIA_OBJECT_STORAGE.is_enabled and MEDIA_OBJECT_STORAGE.is_configured:
        log_event(
            "media.storage.ready",
            backend=MEDIA_OBJECT_STORAGE.backend,
            bucket=MEDIA_OBJECT_STORAGE.bucket,
            region=MEDIA_OBJECT_STORAGE.region,
            endpoint_url=MEDIA_OBJECT_STORAGE.endpoint_url,
            prefix=MEDIA_OBJECT_STORAGE.prefix,
            keep_local_copy=MEDIA_KEEP_LOCAL_COPY,
        )
    elif MEDIA_OBJECT_STORAGE.is_enabled:
        log_event(
            "media.storage.disabled",
            backend=MEDIA_OBJECT_STORAGE.backend,
            reason=MEDIA_OBJECT_STORAGE.configuration_error,
            bucket=MEDIA_OBJECT_STORAGE.bucket,
            region=MEDIA_OBJECT_STORAGE.region,
            endpoint_url=MEDIA_OBJECT_STORAGE.endpoint_url,
            prefix=MEDIA_OBJECT_STORAGE.prefix,
            keep_local_copy=MEDIA_KEEP_LOCAL_COPY,
        )
    else:
        log_event(
            "media.storage.local_only",
            backend=MEDIA_OBJECT_STORAGE.backend,
            media_dir=MEDIA_DIR,
            keep_local_copy=MEDIA_KEEP_LOCAL_COPY,
        )
    server = ThreadingHTTPServer((HOST, PORT), Handler)
    print(f"Prime Messaging backend listening on http://{HOST}:{PORT}")
    server.serve_forever()
