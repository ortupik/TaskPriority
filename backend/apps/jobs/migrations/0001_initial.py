from django.db import migrations, models
import django.db.models.deletion
import uuid


class Migration(migrations.Migration):

    initial = True

    dependencies = [
        ("accounts", "0001_initial"),
        ("checklists", "0001_initial"),
    ]

    operations = [
        migrations.CreateModel(
            name="Customer",
            fields=[
                ("id", models.UUIDField(default=uuid.uuid4, editable=False, primary_key=True, serialize=False)),
                ("name", models.CharField(max_length=255)),
                ("email", models.EmailField(blank=True, max_length=254)),
                ("phone", models.CharField(blank=True, max_length=30)),
                ("address_line1", models.CharField(max_length=255)),
                ("address_line2", models.CharField(blank=True, max_length=255)),
                ("city", models.CharField(max_length=100)),
                ("state", models.CharField(max_length=100)),
                ("zip_code", models.CharField(max_length=20)),
                ("country", models.CharField(default="US", max_length=100)),
                ("latitude", models.DecimalField(blank=True, decimal_places=7, max_digits=10, null=True)),
                ("longitude", models.DecimalField(blank=True, decimal_places=7, max_digits=10, null=True)),
                ("created_at", models.DateTimeField(auto_now_add=True)),
            ],
            options={"db_table": "customers"},
        ),
        migrations.CreateModel(
            name="Job",
            fields=[
                ("id", models.UUIDField(default=uuid.uuid4, editable=False, primary_key=True, serialize=False)),
                ("job_number", models.CharField(db_index=True, max_length=50, unique=True)),
                ("title", models.CharField(max_length=255)),
                ("description", models.TextField(blank=True)),
                ("notes", models.TextField(blank=True)),
                ("status", models.CharField(choices=[("pending","Pending"),("in_progress","In Progress"),("completed","Completed"),("cancelled","Cancelled"),("on_hold","On Hold")], db_index=True, default="pending", max_length=20)),
                ("priority", models.CharField(choices=[("low","Low"),("normal","Normal"),("high","High"),("urgent","Urgent")], default="normal", max_length=10)),
                ("scheduled_start", models.DateTimeField(db_index=True)),
                ("scheduled_end", models.DateTimeField()),
                ("actual_start", models.DateTimeField(blank=True, null=True)),
                ("actual_end", models.DateTimeField(blank=True, null=True)),
                ("version", models.PositiveIntegerField(default=1)),
                ("deleted_at", models.DateTimeField(blank=True, null=True)),
                ("created_at", models.DateTimeField(auto_now_add=True)),
                ("updated_at", models.DateTimeField(auto_now=True)),
                ("assigned_to", models.ForeignKey(blank=True, null=True, on_delete=django.db.models.deletion.SET_NULL, related_name="assigned_jobs", to="accounts.user")),
                ("checklist_schema", models.ForeignKey(blank=True, null=True, on_delete=django.db.models.deletion.SET_NULL, related_name="jobs", to="checklists.checklistschema")),
                ("created_by", models.ForeignKey(null=True, on_delete=django.db.models.deletion.SET_NULL, related_name="created_jobs", to="accounts.user")),
                ("customer", models.ForeignKey(on_delete=django.db.models.deletion.PROTECT, related_name="jobs", to="jobs.customer")),
            ],
            options={"db_table": "jobs"},
        ),
        migrations.CreateModel(
            name="JobStatusHistory",
            fields=[
                ("id", models.UUIDField(default=uuid.uuid4, editable=False, primary_key=True, serialize=False)),
                ("from_status", models.CharField(blank=True, max_length=20)),
                ("to_status", models.CharField(max_length=20)),
                ("notes", models.TextField(blank=True)),
                ("changed_at", models.DateTimeField(auto_now_add=True)),
                ("changed_by", models.ForeignKey(null=True, on_delete=django.db.models.deletion.SET_NULL, to="accounts.user")),
                ("job", models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name="status_history", to="jobs.job")),
            ],
            options={"db_table": "job_status_history", "ordering": ["-changed_at"]},
        ),
        migrations.CreateModel(
            name="JobPhoto",
            fields=[
                ("id", models.UUIDField(default=uuid.uuid4, editable=False, primary_key=True, serialize=False)),
                ("file", models.FileField(upload_to="job-photos/%Y/%m/")),
                ("thumbnail", models.FileField(blank=True, upload_to="job-photos/thumbs/%Y/%m/")),
                ("filename", models.CharField(max_length=255)),
                ("file_size", models.PositiveIntegerField()),
                ("mime_type", models.CharField(default="image/jpeg", max_length=100)),
                ("latitude", models.DecimalField(blank=True, decimal_places=7, max_digits=10, null=True)),
                ("longitude", models.DecimalField(blank=True, decimal_places=7, max_digits=10, null=True)),
                ("captured_at", models.DateTimeField(blank=True, null=True)),
                ("checklist_field_id", models.CharField(blank=True, max_length=100)),
                ("created_at", models.DateTimeField(auto_now_add=True)),
                ("job", models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name="photos", to="jobs.job")),
                ("uploaded_by", models.ForeignKey(null=True, on_delete=django.db.models.deletion.SET_NULL, to="accounts.user")),
            ],
            options={"db_table": "job_photos", "ordering": ["created_at"]},
        ),
        migrations.AddIndex(
            model_name="job",
            index=models.Index(fields=["assigned_to", "status", "scheduled_start"], name="jobs_job_assigned_idx"),
        ),
        migrations.AddIndex(
            model_name="job",
            index=models.Index(fields=["status", "scheduled_start"], name="jobs_job_status_idx"),
        ),
        migrations.AddIndex(
            model_name="job",
            index=models.Index(fields=["updated_at"], name="jobs_job_updated_idx"),
        ),
    ]