from django.urls import path
from . import views

urlpatterns = [
    path("test-push/", views.test_push),
]
