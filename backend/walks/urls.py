from django.urls import re_path

from .views import WalkListCreateView


urlpatterns = [re_path(r"^walks/?$", WalkListCreateView.as_view(), name="walk-list-create")]
