from django.conf import settings
from django.conf.urls.static import static
from django.contrib import admin
from django.urls import include, path


urlpatterns = [
    path("admin/", admin.site.urls),
    path("api/auth/", include("accounts.urls")),
    path("api/", include("accounts.cafe_urls")),
    path("api/", include("dogs.urls")),
    path("api/", include("walks.urls")),
    path("api/", include("checkins.urls")),
    path("api/", include("rewards.urls")),
    path("api/", include("quests.urls")),
    path("api/", include("evidence.urls")),
]

urlpatterns += static(settings.MEDIA_URL, document_root=settings.MEDIA_ROOT)
