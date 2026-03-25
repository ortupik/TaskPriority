from django.urls import path
from . import views

urlpatterns = [
    path("schemas/", views.schema_list),
    path("schemas/<uuid:pk>/", views.schema_detail),
    path("jobs/<uuid:job_pk>/response/", views.get_response),
    path("jobs/<uuid:job_pk>/draft/", views.save_draft),
    path("jobs/<uuid:job_pk>/submit/", views.submit_checklist),
]
