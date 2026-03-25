"""
Checklist system — two-part design:
  ChecklistSchema  — reusable template owned by org/dispatcher
  ChecklistResponse — per-job instance filled by technician

Schema field types match the Flutter form engine exactly.
"""
import uuid
from django.db import models


FIELD_TYPES = [
    ("text", "Text"),
    ("textarea", "Text Area"),
    ("number", "Number"),
    ("select", "Select"),
    ("multi_select", "Multi-Select"),
    ("datetime", "Date/Time"),
    ("photo", "Photo"),
    ("signature", "Signature"),
    ("checkbox", "Checkbox"),
]


class ChecklistSchema(models.Model):
    """
    Reusable checklist template. A single schema can be attached to many jobs.

    The `fields` JSON array defines every field in rendering order:

    [
      {
        "id": "f_uuid",           -- stable field ID (used in responses)
        "type": "text|textarea|number|select|multi_select|datetime|photo|signature|checkbox",
        "label": "Customer name",
        "required": true,
        "order": 0,
        -- type-specific options below --
        "validation": {
          "min": 0, "max": 100,          -- number
          "min_length": 2,               -- text/textarea
          "max_length": 500,             -- text/textarea
          "pattern": "^[0-9]+$",         -- text (regex)
          "pattern_hint": "Digits only", -- human message
          "format": "email|phone|number" -- text subtype
        },
        "options": ["Pass", "Fail", "N/A"],  -- select / multi_select
        "max_photos": 3,                     -- photo
        "placeholder": "Enter value...",     -- text/textarea/number
        "help_text": "Describe the issue",   -- all types
        "default_value": null               -- pre-fill value
      }
    ]
    """
    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
    name = models.CharField(max_length=255)
    description = models.TextField(blank=True)
    fields = models.JSONField(default=list)
    version = models.PositiveIntegerField(default=1)
    is_active = models.BooleanField(default=True)
    created_by = models.ForeignKey(
        "accounts.User", on_delete=models.SET_NULL, null=True, related_name="+"
    )
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        db_table = "checklist_schemas"

    def __str__(self):
        return f"{self.name} (v{self.version})"


class ChecklistResponse(models.Model):
    """
    One response per job. Contains all field answers.

    `answers` JSON structure:
    {
      "field_id": <value>,
      ...
    }

    Value types per field type:
      text / textarea    → string
      number             → number
      select             → string (one of options)
      multi_select       → [string, ...]
      datetime           → ISO 8601 string
      checkbox           → boolean
      photo              → [photo_id, ...]   (references JobPhoto.id)
      signature          → photo_id          (references JobPhoto.id)
    """
    class Status(models.TextChoices):
        DRAFT = "draft", "Draft"
        SUBMITTED = "submitted", "Submitted"

    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
    job = models.OneToOneField(
        "jobs.Job", on_delete=models.CASCADE, related_name="checklist_response"
    )
    schema = models.ForeignKey(
        ChecklistSchema, on_delete=models.PROTECT, related_name="responses"
    )
    schema_version = models.PositiveIntegerField()
    answers = models.JSONField(default=dict)
    status = models.CharField(
        max_length=20, choices=Status.choices, default=Status.DRAFT
    )
    submitted_by = models.ForeignKey(
        "accounts.User", on_delete=models.SET_NULL, null=True, related_name="+"
    )
    submitted_at = models.DateTimeField(null=True, blank=True)
    # Sync metadata — client sets this; server echoes it back
    client_updated_at = models.DateTimeField(null=True, blank=True)
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        db_table = "checklist_responses"

    def validate_answers(self):
        """
        Server-side validation of answers against schema fields.
        Returns list of {field_id, message} dicts (empty = valid).
        """
        errors = []
        field_map = {f["id"]: f for f in self.schema.fields}

        for field in self.schema.fields:
            fid = field["id"]
            ftype = field["type"]
            required = field.get("required", False)
            value = self.answers.get(fid)

            # Required check
            if required:
                empty = (
                    value is None
                    or value == ""
                    or value == []
                    or (ftype == "checkbox" and value is False)
                )
                if empty:
                    errors.append({"field_id": fid, "message": f"{field['label']} is required."})
                    continue

            if value is None:
                continue  # optional + not provided — skip

            validation = field.get("validation", {})

            if ftype in ("text", "textarea"):
                if not isinstance(value, str):
                    errors.append({"field_id": fid, "message": "Must be a string."})
                    continue
                min_len = validation.get("min_length")
                max_len = validation.get("max_length")
                if min_len and len(value) < min_len:
                    errors.append({"field_id": fid, "message": f"Minimum {min_len} characters."})
                if max_len and len(value) > max_len:
                    errors.append({"field_id": fid, "message": f"Maximum {max_len} characters."})
                fmt = validation.get("format")
                if fmt == "email":
                    import re
                    if not re.match(r"[^@]+@[^@]+\.[^@]+", value):
                        errors.append({"field_id": fid, "message": "Enter a valid email address."})
                elif fmt == "phone":
                    import re
                    if not re.match(r"^\+?[\d\s\-()]{7,20}$", value):
                        errors.append({"field_id": fid, "message": "Enter a valid phone number."})

            elif ftype == "number":
                if not isinstance(value, (int, float)):
                    errors.append({"field_id": fid, "message": "Must be a number."})
                    continue
                mn = validation.get("min")
                mx = validation.get("max")
                if mn is not None and value < mn:
                    errors.append({"field_id": fid, "message": f"Minimum value is {mn}."})
                if mx is not None and value > mx:
                    errors.append({"field_id": fid, "message": f"Maximum value is {mx}."})

            elif ftype == "select":
                options = field.get("options", [])
                if value not in options:
                    errors.append({"field_id": fid, "message": f"Must be one of: {', '.join(options)}."})

            elif ftype == "multi_select":
                options = field.get("options", [])
                if not isinstance(value, list):
                    errors.append({"field_id": fid, "message": "Must be a list."})
                elif not all(v in options for v in value):
                    errors.append({"field_id": fid, "message": f"All values must be one of: {', '.join(options)}."})

        return errors
