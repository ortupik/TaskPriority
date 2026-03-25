import io
import logging
from django.utils import timezone
from django.db import transaction
from rest_framework import status
from rest_framework.decorators import api_view, permission_classes, parser_classes
from rest_framework.parsers import MultiPartParser, FormParser, JSONParser
from rest_framework.permissions import IsAuthenticated
from rest_framework.response import Response

from config.pagination import CursorPagination
from .models import Job, JobStatusHistory, JobPhoto
from .serializers import (
    JobListSerializer, JobDetailSerializer,
    UpdateJobStatusSerializer, PhotoUploadSerializer
)
from .filters import JobFilter

logger = logging.getLogger(__name__)


def _base_queryset(user):
    """Jobs visible to this user — technicians only see assigned jobs."""
    from apps.accounts.models import User
    qs = Job.objects.filter(deleted_at__isnull=True).select_related(
        "customer", "assigned_to", "checklist_schema"
    )
    if user.role == User.Role.TECHNICIAN:
        qs = qs.filter(assigned_to=user)
    return qs


@api_view(["GET"])
@permission_classes([IsAuthenticated])
def job_list(request):
    """
    List jobs with filtering, search and cursor pagination.
    GET /api/v1/jobs/
    Query params:
      status, priority, date_from, date_to, search
      lat, lng   — for distance calculation
      cursor     — pagination cursor
      page_size  — default 20, max 100
      updated_after — ISO datetime for delta sync
    """
    qs = _base_queryset(request.user).prefetch_related("photos")

    # Delta sync support: client sends last sync time, gets only changed jobs
    updated_after = request.query_params.get("updated_after")
    if updated_after:
        try:
            from django.utils.dateparse import parse_datetime
            dt = parse_datetime(updated_after)
            if dt:
                qs = qs.filter(updated_at__gt=dt)
        except Exception:
            pass

    # Apply filters
    job_filter = JobFilter(request.query_params, queryset=qs)
    if not job_filter.is_valid():
        return Response(
            {"error": {"code": "INVALID_FILTER", "message": str(job_filter.errors), "details": None}},
            status=400
        )
    qs = job_filter.qs

    # Annotate overdue directly in DB for sorting performance
    qs = qs.order_by("scheduled_start")

    paginator = CursorPagination()
    paginator.ordering = "scheduled_start"
    page = paginator.paginate_queryset(qs, request)
    serializer = JobListSerializer(page, many=True, context={"request": request})
    return paginator.get_paginated_response(serializer.data)


@api_view(["GET"])
@permission_classes([IsAuthenticated])
def job_detail(request, pk):
    """
    Full job detail.
    GET /api/v1/jobs/<pk>/
    """
    try:
        job = _base_queryset(request.user).prefetch_related(
            "photos", "status_history__changed_by"
        ).get(pk=pk)
    except Job.DoesNotExist:
        return Response(
            {"error": {"code": "NOT_FOUND", "message": "Job not found.", "details": None}},
            status=status.HTTP_404_NOT_FOUND
        )
    return Response(JobDetailSerializer(job).data)


@api_view(["PATCH"])
@permission_classes([IsAuthenticated])
def update_job_status(request, pk):
    """
    Update job status with conflict detection.
    PATCH /api/v1/jobs/<pk>/status/

    Conflict detection: if client sends client_version and server version
    is higher, return 409 with both versions so client can show conflict UI.
    """
    try:
        job = _base_queryset(request.user).get(pk=pk)
    except Job.DoesNotExist:
        return Response(
            {"error": {"code": "NOT_FOUND", "message": "Job not found.", "details": None}},
            status=status.HTTP_404_NOT_FOUND
        )

    s = UpdateJobStatusSerializer(data=request.data, context={"job": job})
    s.is_valid(raise_exception=True)

    client_version = s.validated_data.get("client_version")
    if client_version is not None and client_version < job.version:
        # Conflict — server has a newer version
        return Response(
            {
                "error": {
                    "code": "VERSION_CONFLICT",
                    "message": "Job has been modified since your last sync.",
                    "details": {
                        "server_version": job.version,
                        "client_version": client_version,
                        "server_job": JobDetailSerializer(job).data,
                    },
                }
            },
            status=status.HTTP_409_CONFLICT,
        )

    with transaction.atomic():
        old_status = job.status
        new_status = s.validated_data["status"]

        job.status = new_status
        if new_status == Job.Status.IN_PROGRESS and not job.actual_start:
            job.actual_start = timezone.now()
        elif new_status == Job.Status.COMPLETED and not job.actual_end:
            job.actual_end = timezone.now()

        job.save(update_fields=["status", "actual_start", "actual_end", "updated_at"])

        JobStatusHistory.objects.create(
            job=job,
            from_status=old_status,
            to_status=new_status,
            changed_by=request.user,
            notes=s.validated_data.get("notes", ""),
        )

        # Send push notification to dispatcher
        try:
            _notify_status_change(job, old_status, new_status)
        except Exception:
            logger.exception("Failed to send status change notification")

    return Response(JobDetailSerializer(job).data)


@api_view(["POST"])
@permission_classes([IsAuthenticated])
@parser_classes([MultiPartParser, FormParser])
def upload_photo(request, pk):
    """
    Upload a photo for a job. Handles compression server-side as backup
    (client should compress before upload, but we enforce limits).
    POST /api/v1/jobs/<pk>/photos/
    """
    try:
        job = _base_queryset(request.user).get(pk=pk)
    except Job.DoesNotExist:
        return Response(
            {"error": {"code": "NOT_FOUND", "message": "Job not found.", "details": None}},
            status=status.HTTP_404_NOT_FOUND
        )

    s = PhotoUploadSerializer(data=request.data)
    s.is_valid(raise_exception=True)

    uploaded_file = s.validated_data["file"]

    # Reject files > 10MB (client should have compressed to ~1-2MB)
    if uploaded_file.size > 10 * 1024 * 1024:
        return Response(
            {"error": {"code": "FILE_TOO_LARGE", "message": "Max file size is 10MB.", "details": None}},
            status=status.HTTP_413_REQUEST_ENTITY_TOO_LARGE,
        )

    photo = JobPhoto.objects.create(
        job=job,
        uploaded_by=request.user,
        file=uploaded_file,
        filename=uploaded_file.name,
        file_size=uploaded_file.size,
        mime_type=uploaded_file.content_type or "image/jpeg",
        checklist_field_id=s.validated_data.get("checklist_field_id", ""),
        captured_at=s.validated_data.get("captured_at"),
        latitude=s.validated_data.get("latitude"),
        longitude=s.validated_data.get("longitude"),
    )

    from .serializers import JobPhotoSerializer
    return Response(JobPhotoSerializer(photo).data, status=status.HTTP_201_CREATED)


@api_view(["DELETE"])
@permission_classes([IsAuthenticated])
def delete_photo(request, pk, photo_pk):
    """DELETE /api/v1/jobs/<pk>/photos/<photo_pk>/"""
    try:
        job = _base_queryset(request.user).get(pk=pk)
        photo = JobPhoto.objects.get(pk=photo_pk, job=job)
    except (Job.DoesNotExist, JobPhoto.DoesNotExist):
        return Response(
            {"error": {"code": "NOT_FOUND", "message": "Photo not found.", "details": None}},
            status=status.HTTP_404_NOT_FOUND
        )

    # Only uploader or admin can delete
    from apps.accounts.models import User
    if photo.uploaded_by != request.user and request.user.role != User.Role.ADMIN:
        return Response(
            {"error": {"code": "PERMISSION_DENIED", "message": "Cannot delete this photo.", "details": None}},
            status=status.HTTP_403_FORBIDDEN
        )

    photo.file.delete(save=False)
    if photo.thumbnail:
        photo.thumbnail.delete(save=False)
    photo.delete()
    return Response(status=status.HTTP_204_NO_CONTENT)


@api_view(["GET"])
@permission_classes([IsAuthenticated])
def sync_status(request):
    """
    Lightweight endpoint to check how many jobs have been updated since a timestamp.
    Used by app to decide whether a full sync is needed.
    GET /api/v1/jobs/sync-status/?since=<ISO datetime>
    """
    since = request.query_params.get("since")
    count = 0
    if since:
        from django.utils.dateparse import parse_datetime
        dt = parse_datetime(since)
        if dt:
            count = _base_queryset(request.user).filter(updated_at__gt=dt).count()
    return Response({
        "pending_count": count,
        "server_time": timezone.now().isoformat(),
    })


def _notify_status_change(job, old_status, new_status):
    """Fire-and-forget FCM push to dispatcher on status change."""
    from apps.notifications.service import send_push
    if job.created_by and job.created_by.fcm_token:
        send_push(
            token=job.created_by.fcm_token,
            title=f"Job #{job.job_number} updated",
            body=f"Status changed: {old_status} → {new_status}",
            data={"type": "job_status_change", "job_id": str(job.id)},
        )
