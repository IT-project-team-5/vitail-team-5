from django.urls import re_path

from .cafe_views import CafePhotoView, CafeProfileView


urlpatterns = [
    re_path(r"^cafe/profile/photo/?$", CafePhotoView.as_view(), name="cafe-photo"),
    re_path(r"^cafe/profile/?$", CafeProfileView.as_view(), name="cafe-profile"),
]
