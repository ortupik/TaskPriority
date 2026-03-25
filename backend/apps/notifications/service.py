"""
Push notification service using FCM HTTP v1 API.
Gracefully no-ops when FCM_SERVER_KEY is not configured.
"""
import json
import logging
import urllib.request
from django.conf import settings

logger = logging.getLogger(__name__)


def send_push(token: str, title: str, body: str, data: dict = None):
    """
    Send a single FCM push notification.
    Non-blocking — caller should catch exceptions.
    """
    if not token:
        return
    server_key = getattr(settings, "FCM_SERVER_KEY", "")
    if not server_key:
        logger.debug("FCM_SERVER_KEY not configured — skipping push notification")
        return

    payload = {
        "to": token,
        "notification": {"title": title, "body": body},
        "data": data or {},
        "priority": "high",
    }

    req = urllib.request.Request(
        "https://fcm.googleapis.com/fcm/send",
        data=json.dumps(payload).encode(),
        headers={
            "Content-Type": "application/json",
            "Authorization": f"key={server_key}",
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=5) as resp:
            result = json.loads(resp.read())
            if result.get("failure"):
                logger.warning("FCM send failure: %s", result)
    except Exception as e:
        logger.warning("FCM push failed: %s", e)


def send_new_job_notification(job):
    """Notify the assigned technician of a new job assignment."""
    if not job.assigned_to or not job.assigned_to.fcm_token:
        return
    send_push(
        token=job.assigned_to.fcm_token,
        title="New Job Assigned",
        body=f"#{job.job_number}: {job.title}",
        data={
            "type": "new_job",
            "job_id": str(job.id),
            "job_number": job.job_number,
        },
    )
