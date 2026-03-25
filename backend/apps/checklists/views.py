from django.utils import timezone
from rest_framework import status
from rest_framework.decorators import api_view, permission_classes
from rest_framework.permissions import IsAuthenticated
from rest_framework.response import Response

from apps.jobs.models import Job
from .models import ChecklistSchema, ChecklistResponse
from .serializers import (
    ChecklistSchemaSerializer,
    ChecklistResponseSerializer,
    SaveDraftSerializer,
    SubmitChecklistSerializer,
)


# ── Schema endpoints ────────────────────────────────────────────────────────

@api_view(["GET"])
@permission_classes([IsAuthenticated])
def schema_list(request):
    schemas = ChecklistSchema.objects.filter(is_active=True).order_by("name")
    return Response(ChecklistSchemaSerializer(schemas, many=True).data)


@api_view(["GET"])
@permission_classes([IsAuthenticated])
def schema_detail(request, pk):
    try:
        schema = ChecklistSchema.objects.get(pk=pk, is_active=True)
    except ChecklistSchema.DoesNotExist:
        return Response(
            {"error": {"code": "NOT_FOUND", "message": "Schema not found.", "details": None}},
            status=status.HTTP_404_NOT_FOUND,
        )
    return Response(ChecklistSchemaSerializer(schema).data)


# ── Response endpoints ───────────────────────────────────────────────────────

def _get_job_for_technician(request, job_pk):
    """Retrieve a job the current user is assigned to (or admin)."""
    from apps.accounts.models import User
    qs = Job.objects.filter(pk=job_pk, deleted_at__isnull=True)
    if request.user.role == User.Role.TECHNICIAN:
        qs = qs.filter(assigned_to=request.user)
    try:
        return qs.select_related("checklist_schema").get()
    except Job.DoesNotExist:
        return None


@api_view(["GET"])
@permission_classes([IsAuthenticated])
def get_response(request, job_pk):
    """
    Get the checklist response for a job.
    Returns 404 if no response has been started yet.
    GET /api/v1/checklists/jobs/<job_pk>/response/
    """
    job = _get_job_for_technician(request, job_pk)
    if not job:
        return Response(
            {"error": {"code": "NOT_FOUND", "message": "Job not found.", "details": None}},
            status=status.HTTP_404_NOT_FOUND,
        )
    try:
        resp = ChecklistResponse.objects.get(job=job)
    except ChecklistResponse.DoesNotExist:
        return Response(
            {"error": {"code": "NOT_FOUND", "message": "No checklist response yet.", "details": None}},
            status=status.HTTP_404_NOT_FOUND,
        )
    return Response(ChecklistResponseSerializer(resp).data)


@api_view(["POST"])
@permission_classes([IsAuthenticated])
def save_draft(request, job_pk):
    """
    Create or update a draft checklist response. Partial saves allowed.
    POST /api/v1/checklists/jobs/<job_pk>/draft/
    """
    job = _get_job_for_technician(request, job_pk)
    if not job:
        return Response(
            {"error": {"code": "NOT_FOUND", "message": "Job not found.", "details": None}},
            status=status.HTTP_404_NOT_FOUND,
        )
    if not job.checklist_schema:
        return Response(
            {"error": {"code": "NO_SCHEMA", "message": "This job has no checklist schema.", "details": None}},
            status=status.HTTP_400_BAD_REQUEST,
        )

    s = SaveDraftSerializer(data=request.data)
    s.is_valid(raise_exception=True)

    resp, created = ChecklistResponse.objects.get_or_create(
        job=job,
        defaults={
            "schema": job.checklist_schema,
            "schema_version": job.checklist_schema.version,
            "answers": {},
        },
    )

    if resp.status == ChecklistResponse.Status.SUBMITTED:
        return Response(
            {"error": {"code": "ALREADY_SUBMITTED", "message": "This checklist has already been submitted.", "details": None}},
            status=status.HTTP_409_CONFLICT,
        )

    # Merge incoming answers with existing (allows partial saves)
    resp.answers.update(s.validated_data["answers"])
    if s.validated_data.get("client_updated_at"):
        resp.client_updated_at = s.validated_data["client_updated_at"]
    resp.save(update_fields=["answers", "client_updated_at", "updated_at"])

    return Response(
        ChecklistResponseSerializer(resp).data,
        status=status.HTTP_201_CREATED if created else status.HTTP_200_OK,
    )


@api_view(["POST"])
@permission_classes([IsAuthenticated])
def submit_checklist(request, job_pk):
    """
    Submit a completed checklist. Validates all required fields.
    POST /api/v1/checklists/jobs/<job_pk>/submit/
    """
    job = _get_job_for_technician(request, job_pk)
    if not job:
        return Response(
            {"error": {"code": "NOT_FOUND", "message": "Job not found.", "details": None}},
            status=status.HTTP_404_NOT_FOUND,
        )
    if not job.checklist_schema:
        return Response(
            {"error": {"code": "NO_SCHEMA", "message": "This job has no checklist schema.", "details": None}},
            status=status.HTTP_400_BAD_REQUEST,
        )

    s = SubmitChecklistSerializer(data=request.data)
    s.is_valid(raise_exception=True)

    resp, _ = ChecklistResponse.objects.get_or_create(
        job=job,
        defaults={
            "schema": job.checklist_schema,
            "schema_version": job.checklist_schema.version,
            "answers": {},
        },
    )

    if resp.status == ChecklistResponse.Status.SUBMITTED:
        return Response(
            {"error": {"code": "ALREADY_SUBMITTED", "message": "Already submitted.", "details": None}},
            status=status.HTTP_409_CONFLICT,
        )

    resp.answers = s.validated_data["answers"]
    if s.validated_data.get("client_updated_at"):
        resp.client_updated_at = s.validated_data["client_updated_at"]

    # Validate required fields
    validation_errors = resp.validate_answers()
    if validation_errors:
        return Response(
            {
                "error": {
                    "code": "VALIDATION_ERROR",
                    "message": "Checklist has validation errors.",
                    "details": {"field_errors": validation_errors},
                }
            },
            status=status.HTTP_422_UNPROCESSABLE_ENTITY,
        )

    resp.status = ChecklistResponse.Status.SUBMITTED
    resp.submitted_by = request.user
    resp.submitted_at = timezone.now()
    resp.save()

    return Response(ChecklistResponseSerializer(resp).data)
