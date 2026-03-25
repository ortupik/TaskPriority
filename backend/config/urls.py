from django.contrib import admin
from django.urls import path, include
from django.http import JsonResponse


def health_check(request):
    return JsonResponse({"status": "ok", "service": "fieldpulse-api"})


urlpatterns = [
    path("admin/", admin.site.urls),
    path("health/", health_check),
    path("api/v1/auth/", include("apps.accounts.urls")),
    path("api/v1/jobs/", include("apps.jobs.urls")),
    path("api/v1/checklists/", include("apps.checklists.urls")),
    path("api/v1/notifications/", include("apps.notifications.urls")),
]
