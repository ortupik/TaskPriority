import uuid
from django.db import models
from django.contrib.postgres.fields import ArrayField


class Customer(models.Model):
    """Customer/site that jobs are performed at."""
    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
    name = models.CharField(max_length=255)
    email = models.EmailField(blank=True)
    phone = models.CharField(max_length=30, blank=True)
    address_line1 = models.CharField(max_length=255)
    address_line2 = models.CharField(max_length=255, blank=True)
    city = models.CharField(max_length=100)
    state = models.CharField(max_length=100)
    zip_code = models.CharField(max_length=20)
    country = models.CharField(max_length=100, default="US")
    latitude = models.DecimalField(max_digits=10, decimal_places=7, null=True, blank=True)
    longitude = models.DecimalField(max_digits=10, decimal_places=7, null=True, blank=True)
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        db_table = "customers"

    def __str__(self):
        return self.name

    @property
    def full_address(self):
        parts = [self.address_line1]
        if self.address_line2:
            parts.append(self.address_line2)
        parts.append(f"{self.city}, {self.state} {self.zip_code}")
        return ", ".join(parts)


class Job(models.Model):
    class Status(models.TextChoices):
        PENDING = "pending", "Pending"
        IN_PROGRESS = "in_progress", "In Progress"
        COMPLETED = "completed", "Completed"
        CANCELLED = "cancelled", "Cancelled"
        ON_HOLD = "on_hold", "On Hold"

    class Priority(models.TextChoices):
        LOW = "low", "Low"
        NORMAL = "normal", "Normal"
        HIGH = "high", "High"
        URGENT = "urgent", "Urgent"

    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
    job_number = models.CharField(max_length=50, unique=True, db_index=True)
    customer = models.ForeignKey(Customer, on_delete=models.PROTECT, related_name="jobs")
    assigned_to = models.ForeignKey(
        "accounts.User",
        on_delete=models.SET_NULL,
        null=True,
        blank=True,
        related_name="assigned_jobs",
    )
    created_by = models.ForeignKey(
        "accounts.User",
        on_delete=models.SET_NULL,
        null=True,
        related_name="created_jobs",
    )
    title = models.CharField(max_length=255)
    description = models.TextField(blank=True)
    notes = models.TextField(blank=True, help_text="Internal dispatcher notes")
    status = models.CharField(max_length=20, choices=Status.choices, default=Status.PENDING, db_index=True)
    priority = models.CharField(max_length=10, choices=Priority.choices, default=Priority.NORMAL)
    scheduled_start = models.DateTimeField(db_index=True)
    scheduled_end = models.DateTimeField()
    actual_start = models.DateTimeField(null=True, blank=True)
    actual_end = models.DateTimeField(null=True, blank=True)
    checklist_schema = models.ForeignKey(
        "checklists.ChecklistSchema",
        on_delete=models.SET_NULL,
        null=True,
        blank=True,
        related_name="jobs",
    )
    # Server-side version counter for conflict detection
    version = models.PositiveIntegerField(default=1)
    # Soft-delete
    deleted_at = models.DateTimeField(null=True, blank=True)
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        db_table = "jobs"
        indexes = [
            models.Index(fields=["assigned_to", "status", "scheduled_start"]),
            models.Index(fields=["status", "scheduled_start"]),
            models.Index(fields=["updated_at"]),
        ]

    def __str__(self):
        return f"{self.job_number}: {self.title}"

    def save(self, *args, **kwargs):
        if not self.job_number:
            self.job_number = self._generate_job_number()
        # Increment version on every save (except creation)
        if self.pk:
            self.__class__.objects.filter(pk=self.pk).update(version=models.F("version") + 1)
        super().save(*args, **kwargs)

    @staticmethod
    def _generate_job_number():
        import random
        import string
        prefix = "JOB"
        suffix = "".join(random.choices(string.digits, k=6))
        return f"{prefix}-{suffix}"

    @property
    def is_overdue(self):
        from django.utils import timezone
        return (
            self.status in (self.Status.PENDING, self.Status.IN_PROGRESS)
            and self.scheduled_end < timezone.now()
        )


class JobStatusHistory(models.Model):
    """Audit log of all job status changes."""
    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
    job = models.ForeignKey(Job, on_delete=models.CASCADE, related_name="status_history")
    from_status = models.CharField(max_length=20, blank=True)
    to_status = models.CharField(max_length=20)
    changed_by = models.ForeignKey(
        "accounts.User", on_delete=models.SET_NULL, null=True
    )
    notes = models.TextField(blank=True)
    changed_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        db_table = "job_status_history"
        ordering = ["-changed_at"]


class JobPhoto(models.Model):
    """Photos uploaded as part of job completion."""
    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
    job = models.ForeignKey(Job, on_delete=models.CASCADE, related_name="photos")
    uploaded_by = models.ForeignKey("accounts.User", on_delete=models.SET_NULL, null=True)
    file = models.FileField(upload_to="job-photos/%Y/%m/")
    thumbnail = models.FileField(upload_to="job-photos/thumbs/%Y/%m/", blank=True)
    filename = models.CharField(max_length=255)
    file_size = models.PositiveIntegerField(help_text="Size in bytes")
    mime_type = models.CharField(max_length=100, default="image/jpeg")
    # GPS metadata from EXIF
    latitude = models.DecimalField(max_digits=10, decimal_places=7, null=True, blank=True)
    longitude = models.DecimalField(max_digits=10, decimal_places=7, null=True, blank=True)
    # Client-side capture time (may differ from server upload time)
    captured_at = models.DateTimeField(null=True, blank=True)
    # Checklist field reference (if photo belongs to a checklist response)
    checklist_field_id = models.CharField(max_length=100, blank=True)
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        db_table = "job_photos"
        ordering = ["created_at"]

    def presigned_url(self, expires=3600):
        """Generate a presigned URL for temporary access."""
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
            Params={"Bucket": settings.AWS_STORAGE_BUCKET_NAME, "Key": self.file.name},
            ExpiresIn=expires,
        )
