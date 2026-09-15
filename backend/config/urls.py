from django.contrib import admin
from django.urls import include, path


urlpatterns = [
    path("admin/", admin.site.urls),
    path("api/auth/", include("accounts.urls")),
    path("api/", include("accounts.cafe_urls")),
    path("api/", include("dogs.urls")),
    path("api/", include("walks.urls")),
    path("api/", include("rewards.urls")),
]
