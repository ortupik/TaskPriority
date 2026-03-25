import jwt
import hashlib
import secrets
from datetime import datetime, timezone
from django.conf import settings
from rest_framework.authentication import BaseAuthentication
from rest_framework.exceptions import AuthenticationFailed


JWT_SETTINGS = settings.JWT_SETTINGS


def generate_access_token(user):
    """Issue a short-lived access token (15 min)."""
    now = datetime.now(timezone.utc)
    payload = {
        "sub": str(user.id),
        "email": user.email,
        "role": user.role,
        "iat": now,
        "exp": now + JWT_SETTINGS["ACCESS_TOKEN_LIFETIME"],
        "type": "access",
    }
    return jwt.encode(payload, JWT_SETTINGS["SIGNING_KEY"], algorithm=JWT_SETTINGS["ALGORITHM"])


def generate_refresh_token(user, device_info=""):
    """
    Issue a long-lived refresh token (7 days).
    Stores a hashed version in DB for rotation/revocation.
    Returns (raw_token, RefreshToken_instance).
    """
    from .models import RefreshToken
    from django.utils import timezone as tz

    raw = secrets.token_urlsafe(64)
    hashed = _hash_token(raw)

    expires_at = tz.now() + JWT_SETTINGS["REFRESH_TOKEN_LIFETIME"]
    record = RefreshToken.objects.create(
        user=user,
        token=hashed,
        device_info=device_info,
        expires_at=expires_at,
    )
    return raw, record


def rotate_refresh_token(raw_token, device_info=""):
    """
    Validate and rotate a refresh token.
    Revokes the old record and issues a fresh pair.
    Returns (access_token, new_raw_refresh_token) or raises AuthenticationFailed.
    """
    from .models import RefreshToken
    from django.utils import timezone as tz

    hashed = _hash_token(raw_token)
    try:
        record = RefreshToken.objects.select_related("user").get(token=hashed)
    except RefreshToken.DoesNotExist:
        raise AuthenticationFailed("Invalid refresh token.")

    if not record.is_valid:
        # Possible token reuse — revoke entire family
        _revoke_token_family(record)
        raise AuthenticationFailed("Refresh token expired or already used.")

    # Revoke old
    record.revoked_at = tz.now()
    record.save(update_fields=["revoked_at"])

    user = record.user
    access = generate_access_token(user)
    new_raw, new_record = generate_refresh_token(user, device_info)
    record.replaced_by = new_record
    record.save(update_fields=["replaced_by"])

    return access, new_raw


def decode_access_token(token):
    """Decode and validate access token. Returns payload dict."""
    try:
        payload = jwt.decode(
            token,
            JWT_SETTINGS["SIGNING_KEY"],
            algorithms=[JWT_SETTINGS["ALGORITHM"]],
        )
        if payload.get("type") != "access":
            raise AuthenticationFailed("Invalid token type.")
        return payload
    except jwt.ExpiredSignatureError:
        raise AuthenticationFailed("Access token expired.")
    except jwt.InvalidTokenError as e:
        raise AuthenticationFailed(f"Invalid token: {e}")


def _hash_token(raw_token):
    return hashlib.sha256(raw_token.encode()).hexdigest()


def _revoke_token_family(record):
    """Walk the chain and revoke all tokens in a reuse-detected family."""
    from .models import RefreshToken
    from django.utils import timezone as tz

    # Find the root
    current = record
    while current.replaces_id:
        try:
            current = RefreshToken.objects.get(pk=current.replaces_id)
        except RefreshToken.DoesNotExist:
            break

    # Revoke all tokens for this user from this device to be safe
    RefreshToken.objects.filter(
        user=record.user,
        revoked_at__isnull=True,
    ).update(revoked_at=tz.now())


class JWTAuthentication(BaseAuthentication):
    """DRF authentication class that reads Bearer token from Authorization header."""

    def authenticate(self, request):
        auth_header = request.META.get("HTTP_AUTHORIZATION", "")
        if not auth_header.startswith("Bearer "):
            return None

        token = auth_header.split(" ", 1)[1]
        payload = decode_access_token(token)

        from .models import User
        try:
            user = User.objects.get(pk=payload["sub"], is_active=True)
        except User.DoesNotExist:
            raise AuthenticationFailed("User not found or inactive.")

        return user, payload

    def authenticate_header(self, request):
        return "Bearer"
