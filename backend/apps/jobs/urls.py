from django.urls import path
from . import views

urlpatterns = [
    path("", views.job_list),
    path("sync-status/", views.sync_status),
    path("<uuid:pk>/", views.job_detail),
    path("<uuid:pk>/status/", views.update_job_status),
    path("<uuid:pk>/photos/", views.upload_photo),
    path("<uuid:pk>/photos/<uuid:photo_pk>/", views.delete_photo),
]
