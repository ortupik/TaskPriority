from rest_framework import serializers
from django.contrib.auth import authenticate
from .models import User


class LoginSerializer(serializers.Serializer):
    email = serializers.EmailField()
    password = serializers.CharField(write_only=True, min_length=8)
    device_info = serializers.CharField(required=False, default="", max_length=255)

    def validate(self, attrs):
        email = attrs["email"].lower().strip()
        password = attrs["password"]

        user = authenticate(username=email, password=password)
        if not user:
            raise serializers.ValidationError(
                {"detail": "Invalid email or password."}, code="authentication_failed"
            )
        if not user.is_active:
            raise serializers.ValidationError(
                {"detail": "Account is disabled."}, code="account_disabled"
            )

        attrs["user"] = user
        return attrs


class UserSerializer(serializers.ModelSerializer):
    full_name = serializers.CharField(read_only=True)

    class Meta:
        model = User
        fields = ["id", "email", "first_name", "last_name", "full_name", "role", "phone", "created_at"]
        read_only_fields = ["id", "email", "role", "created_at"]


class TokenResponseSerializer(serializers.Serializer):
    access_token = serializers.CharField()
    refresh_token = serializers.CharField()
    token_type = serializers.CharField(default="Bearer")
    expires_in = serializers.IntegerField(help_text="Access token lifetime in seconds")
    user = UserSerializer()


class RefreshTokenSerializer(serializers.Serializer):
    refresh_token = serializers.CharField()
    device_info = serializers.CharField(required=False, default="", max_length=255)


class FCMTokenSerializer(serializers.Serializer):
    fcm_token = serializers.CharField(max_length=4096)


class ChangePasswordSerializer(serializers.Serializer):
    current_password = serializers.CharField(write_only=True)
    new_password = serializers.CharField(write_only=True, min_length=8)

    def validate_current_password(self, value):
        user = self.context["request"].user
        if not user.check_password(value):
            raise serializers.ValidationError("Current password is incorrect.")
        return value
