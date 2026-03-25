import math
from rest_framework import serializers
from .models import Job, Customer, JobStatusHistory, JobPhoto
from apps.checklists.serializers import ChecklistSchemaSerializer


class CustomerSerializer(serializers.ModelSerializer):
    full_address = serializers.CharField(read_only=True)

    class Meta:
        model = Customer
        fields = [
            "id", "name", "email", "phone",
            "address_line1", "address_line2", "city", "state",
            "zip_code", "country", "full_address", "latitude", "longitude",
        ]


class JobPhotoSerializer(serializers.ModelSerializer):
    url = serializers.SerializerMethodField()
    thumbnail_url = serializers.SerializerMethodField()

    class Meta:
        model = JobPhoto
        fields = [
            "id", "filename", "file_size", "mime_type",
            "latitude", "longitude", "captured_at",
            "checklist_field_id", "url", "thumbnail_url", "created_at"
        ]

    def get_url(self, obj):
        try:
            return obj.presigned_url()
        except Exception:
            return None

    def get_thumbnail_url(self, obj):
        if not obj.thumbnail:
            return None
        try:
            import boto3
            from django.conf import settings
            s3 = boto3.client(
                "s3",
                endpoint_url=settings.AWS_S3_ENDPOINT_URL,
                aws_access_key_id=settings.AWS_ACCESS_KEY_ID,
                aws_secret_access_key=settings.AWS_SECRET_ACCESS_KEY,
            )
            return s3.generate_presigned_url(
                "get_object",
                Params={"Bucket": settings.AWS_STORAGE_BUCKET_NAME, "Key": obj.thumbnail.name},
                ExpiresIn=3600,
            )
        except Exception:
            return None


class JobStatusHistorySerializer(serializers.ModelSerializer):
    changed_by_name = serializers.SerializerMethodField()

    class Meta:
        model = JobStatusHistory
        fields = ["id", "from_status", "to_status", "changed_by_name", "notes", "changed_at"]

    def get_changed_by_name(self, obj):
        if obj.changed_by:
            return obj.changed_by.full_name
        return None


class JobListSerializer(serializers.ModelSerializer):
    """Lightweight serializer for the job list — no nested photos/history."""
    customer_name = serializers.CharField(source="customer.name", read_only=True)
    customer_address = serializers.CharField(source="customer.full_address", read_only=True)
    customer_phone = serializers.CharField(source="customer.phone", read_only=True)
    customer_lat = serializers.DecimalField(
        source="customer.latitude", max_digits=10, decimal_places=7, read_only=True
    )
    customer_lng = serializers.DecimalField(
        source="customer.longitude", max_digits=10, decimal_places=7, read_only=True
    )
    is_overdue = serializers.BooleanField(read_only=True)
    distance_km = serializers.SerializerMethodField()
    has_checklist = serializers.SerializerMethodField()
    checklist_schema = ChecklistSchemaSerializer(read_only=True)
    photo_count = serializers.SerializerMethodField()

    class Meta:
        model = Job
        fields = [
            "id", "job_number", "title", "status", "priority",
            "scheduled_start", "scheduled_end", "actual_start", "actual_end",
            "is_overdue", "customer_name", "customer_address", "customer_phone",
            "customer_lat", "customer_lng", "distance_km",
            "has_checklist", "checklist_schema", "photo_count", "version", "updated_at",
        ]

    def get_distance_km(self, obj):
        """Calculate distance from technician's current location (passed in context)."""
        request = self.context.get("request")
        if not request:
            return None
        try:
            lat = float(request.query_params.get("lat", ""))
            lng = float(request.query_params.get("lng", ""))
        except (TypeError, ValueError):
            return None
        if not obj.customer.latitude or not obj.customer.longitude:
            return None
        return round(_haversine(lat, lng, float(obj.customer.latitude), float(obj.customer.longitude)), 2)

    def get_has_checklist(self, obj):
        return obj.checklist_schema_id is not None

    def get_photo_count(self, obj):
        return obj.photos.count()


class JobDetailSerializer(serializers.ModelSerializer):
    """Full detail — includes customer, schema, photos, history."""
    customer = CustomerSerializer(read_only=True)
    checklist_schema = ChecklistSchemaSerializer(read_only=True)
    photos = JobPhotoSerializer(many=True, read_only=True)
    status_history = JobStatusHistorySerializer(many=True, read_only=True)
    is_overdue = serializers.BooleanField(read_only=True)
    assigned_to_name = serializers.SerializerMethodField()

    class Meta:
        model = Job
        fields = [
            "id", "job_number", "title", "description", "notes",
            "status", "priority", "is_overdue",
            "scheduled_start", "scheduled_end", "actual_start", "actual_end",
            "customer", "checklist_schema", "photos", "status_history",
            "assigned_to_name", "version", "created_at", "updated_at",
        ]

    def get_assigned_to_name(self, obj):
        if obj.assigned_to:
            return obj.assigned_to.full_name
        return None


class UpdateJobStatusSerializer(serializers.Serializer):
    VALID_TRANSITIONS = {
        "pending": ["in_progress", "cancelled", "on_hold"],
        "in_progress": ["completed", "on_hold", "pending"],
        "on_hold": ["in_progress", "cancelled"],
        "completed": [],
        "cancelled": [],
    }

    status = serializers.ChoiceField(choices=Job.Status.choices)
    notes = serializers.CharField(required=False, allow_blank=True)
    # Client sends its known version — used for conflict detection
    client_version = serializers.IntegerField(required=False)

    def validate(self, attrs):
        job = self.context["job"]
        new_status = attrs["status"]
        valid = self.VALID_TRANSITIONS.get(job.status, [])
        if new_status not in valid:
            raise serializers.ValidationError(
                {"status": f"Cannot transition from '{job.status}' to '{new_status}'."}
            )
        return attrs


class PhotoUploadSerializer(serializers.Serializer):
    file = serializers.ImageField()
    checklist_field_id = serializers.CharField(required=False, allow_blank=True)
    captured_at = serializers.DateTimeField(required=False)
    latitude = serializers.DecimalField(required=False, max_digits=10, decimal_places=7)
    longitude = serializers.DecimalField(required=False, max_digits=10, decimal_places=7)


def _haversine(lat1, lon1, lat2, lon2):
    """Return distance in km between two lat/lon pairs."""
    R = 6371
    phi1, phi2 = math.radians(lat1), math.radians(lat2)
    dphi = math.radians(lat2 - lat1)
    dlambda = math.radians(lon2 - lon1)
    a = math.sin(dphi / 2) ** 2 + math.cos(phi1) * math.cos(phi2) * math.sin(dlambda / 2) ** 2
    return R * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a))
