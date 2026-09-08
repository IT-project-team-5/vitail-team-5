from django.contrib import admin
from django.urls import include, path


urlpatterns = [
    path("admin/", admin.site.urls),
    path("api/auth/", include("accounts.urls")),
    path("api/wallet/", include("rewards.wallet_urls")),
    path("api/redemptions/", include("rewards.urls")),
]
