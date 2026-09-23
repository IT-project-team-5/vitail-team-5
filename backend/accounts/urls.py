from django.urls import path
from rest_framework_simplejwt.views import TokenRefreshView

from .serializers import AccountTokenRefreshSerializer
from .views import LoginView, MePhotoView, MeView, RegisterView


urlpatterns = [
    path("register", RegisterView.as_view(), name="auth-register"),
    path("login", LoginView.as_view(), name="auth-login"),
    path(
        "refresh",
        TokenRefreshView.as_view(serializer_class=AccountTokenRefreshSerializer),
        name="auth-refresh",
    ),
    path("me/photo", MePhotoView.as_view(), name="auth-me-photo"),
    path("me", MeView.as_view(), name="auth-me"),
]
