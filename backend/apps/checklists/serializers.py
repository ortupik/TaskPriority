from rest_framework import serializers
from .models import ChecklistSchema, ChecklistResponse

VALID_FIELD_TYPES = {
    "text", "textarea", "number", "select",
    "multi_select", "datetime", "photo", "signature", "checkbox"
}
VALID_FORMATS = {"email", "phone", "number"}


class ChecklistFieldSerializer(serializers.Serializer):
    """Validates a single field definition inside a schema."""
    id = serializers.CharField(max_length=100)
    type = serializers.ChoiceField(choices=list(VALID_FIELD_TYPES))
    label = serializers.CharField(max_length=255)
    required = serializers.BooleanField(default=False)
    order = serializers.IntegerField(default=0)
    placeholder = serializers.CharField(required=False, allow_blank=True)
    help_text = serializers.CharField(required=False, allow_blank=True)
    default_value = serializers.JSONField(required=False, allow_null=True)
    options = serializers.ListField(
        child=serializers.CharField(), required=False, default=list
    )
    max_photos = serializers.IntegerField(required=False, min_value=1, max_value=10)
    validation = serializers.DictField(required=False, default=dict)

    def validate(self, attrs):
        ftype = attrs["type"]
        if ftype in ("select", "multi_select") and not attrs.get("options"):
            raise serializers.ValidationError(
                f"Field '{attrs['id']}' of type '{ftype}' must have options."
            )
        return attrs


class ChecklistSchemaSerializer(serializers.ModelSerializer):
    fields = serializers.JSONField()

    class Meta:
        model = ChecklistSchema
        fields = [
            "id", "name", "description", "fields",
            "version", "is_active", "created_at", "updated_at"
        ]
        read_only_fields = ["id", "version", "created_at", "updated_at"]

    def validate_fields(self, value):
        if not isinstance(value, list):
            raise serializers.ValidationError("Fields must be a list.")
        if not value:
            raise serializers.ValidationError("Schema must have at least one field.")

        seen_ids = set()
        for i, field in enumerate(value):
            field_s = ChecklistFieldSerializer(data=field)
            if not field_s.is_valid():
                raise serializers.ValidationError(
                    {f"fields[{i}]": field_s.errors}
                )
            fid = field.get("id")
            if fid in seen_ids:
                raise serializers.ValidationError(f"Duplicate field id: '{fid}'")
            seen_ids.add(fid)

        return value


class ChecklistResponseSerializer(serializers.ModelSerializer):
    validation_errors = serializers.SerializerMethodField()

    class Meta:
        model = ChecklistResponse
        fields = [
            "id", "job", "schema", "schema_version", "answers",
            "status", "submitted_at", "client_updated_at",
            "validation_errors", "created_at", "updated_at"
        ]
        read_only_fields = [
            "id", "schema_version", "submitted_at", "validation_errors",
            "created_at", "updated_at"
        ]

    def get_validation_errors(self, obj):
        return obj.validate_answers()


class SaveDraftSerializer(serializers.Serializer):
    """Upsert a draft — partial answers allowed."""
    answers = serializers.DictField()
    client_updated_at = serializers.DateTimeField(required=False)


class SubmitChecklistSerializer(serializers.Serializer):
    """Final submission — all required fields must be present."""
    answers = serializers.DictField()
    client_updated_at = serializers.DateTimeField(required=False)
