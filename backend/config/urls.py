from django.contrib import admin
from django.urls import include, path


urlpatterns = [
    path("admin/", admin.site.urls),
    path("api/auth/", include("accounts.urls")),
    path("api/venues/", include("venues.urls")),
    path("api/wallet/", include("wallets.urls")),
    path("api/redemptions/", include("redemptions.urls")),
]
