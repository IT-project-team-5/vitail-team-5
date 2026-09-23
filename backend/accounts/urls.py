from django.urls import path
from rest_framework_simplejwt.views import TokenRefreshView

from .views import LoginView, MePhotoView, MeView, RegisterView


urlpatterns = [
    path("register", RegisterView.as_view(), name="auth-register"),
    path("login", LoginView.as_view(), name="auth-login"),
    path("refresh", TokenRefreshView.as_view(), name="auth-refresh"),
    path("me/photo", MePhotoView.as_view(), name="auth-me-photo"),
    path("me", MeView.as_view(), name="auth-me"),
]
