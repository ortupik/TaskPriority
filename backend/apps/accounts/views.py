from django.conf import settings
from rest_framework import status
from rest_framework.decorators import api_view, permission_classes
from rest_framework.permissions import AllowAny, IsAuthenticated
from rest_framework.response import Response

from .authentication import generate_access_token, generate_refresh_token, rotate_refresh_token
from .serializers import (
    LoginSerializer, UserSerializer, TokenResponseSerializer,
    RefreshTokenSerializer, FCMTokenSerializer, ChangePasswordSerializer
)

JWT_SETTINGS = settings.JWT_SETTINGS


@api_view(["POST"])
@permission_classes([AllowAny])
def login(request):
    """
    Authenticate user and return JWT pair.
    POST /api/v1/auth/login/
    """
    serializer = LoginSerializer(data=request.data)
    serializer.is_valid(raise_exception=True)

    user = serializer.validated_data["user"]
    device_info = serializer.validated_data.get("device_info", "")

    access_token = generate_access_token(user)
    raw_refresh, _ = generate_refresh_token(user, device_info)

    expires_in = int(JWT_SETTINGS["ACCESS_TOKEN_LIFETIME"].total_seconds())

    return Response({
        "access_token": access_token,
        "refresh_token": raw_refresh,
        "token_type": "Bearer",
        "expires_in": expires_in,
        "user": UserSerializer(user).data,
    }, status=status.HTTP_200_OK)


@api_view(["POST"])
@permission_classes([AllowAny])
def refresh_token(request):
    """
    Rotate refresh token and return new token pair.
    POST /api/v1/auth/refresh/
    """
    serializer = RefreshTokenSerializer(data=request.data)
    serializer.is_valid(raise_exception=True)

    raw_token = serializer.validated_data["refresh_token"]
    device_info = serializer.validated_data.get("device_info", "")

    access, new_refresh = rotate_refresh_token(raw_token, device_info)
    expires_in = int(JWT_SETTINGS["ACCESS_TOKEN_LIFETIME"].total_seconds())

    return Response({
        "access_token": access,
        "refresh_token": new_refresh,
        "token_type": "Bearer",
        "expires_in": expires_in,
    }, status=status.HTTP_200_OK)


@api_view(["POST"])
@permission_classes([IsAuthenticated])
def logout(request):
    """
    Revoke all refresh tokens for the requesting user.
    POST /api/v1/auth/logout/
    """
    from django.utils import timezone
    request.user.refresh_tokens.filter(revoked_at__isnull=True).update(revoked_at=timezone.now())
    return Response({"message": "Logged out successfully."}, status=status.HTTP_200_OK)


@api_view(["GET"])
@permission_classes([IsAuthenticated])
def me(request):
    """
    Get current user profile.
    GET /api/v1/auth/me/
    """
    return Response(UserSerializer(request.user).data)


@api_view(["PATCH"])
@permission_classes([IsAuthenticated])
def update_profile(request):
    """
    Update current user profile.
    PATCH /api/v1/auth/me/
    """
    serializer = UserSerializer(request.user, data=request.data, partial=True)
    serializer.is_valid(raise_exception=True)
    serializer.save()
    return Response(serializer.data)


@api_view(["POST"])
@permission_classes([IsAuthenticated])
def register_fcm_token(request):
    """
    Register FCM push notification token for device.
    POST /api/v1/auth/fcm-token/
    """
    serializer = FCMTokenSerializer(data=request.data)
    serializer.is_valid(raise_exception=True)
    request.user.fcm_token = serializer.validated_data["fcm_token"]
    request.user.save(update_fields=["fcm_token"])
    return Response({"message": "FCM token registered."})


@api_view(["POST"])
@permission_classes([IsAuthenticated])
def change_password(request):
    """
    Change user password.
    POST /api/v1/auth/change-password/
    """
    serializer = ChangePasswordSerializer(data=request.data, context={"request": request})
    serializer.is_valid(raise_exception=True)
    request.user.set_password(serializer.validated_data["new_password"])
    request.user.save(update_fields=["password"])
    # Revoke all existing refresh tokens on password change
    from django.utils import timezone
    request.user.refresh_tokens.filter(revoked_at__isnull=True).update(revoked_at=timezone.now())
    return Response({"message": "Password changed. Please log in again."})
