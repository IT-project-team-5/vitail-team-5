from django.urls import re_path

from .cafe_views import CafeProfileView


urlpatterns = [
    re_path(r"^cafe/profile/?$", CafeProfileView.as_view(), name="cafe-profile"),
]
