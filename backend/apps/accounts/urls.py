from django.urls import path
from . import views

urlpatterns = [
    path("login/", views.login),
    path("refresh/", views.refresh_token),
    path("logout/", views.logout),
    path("me/", views.me),
    path("me/update/", views.update_profile),
    path("fcm-token/", views.register_fcm_token),
    path("change-password/", views.change_password),
]
