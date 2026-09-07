from django.urls import path

from .views import CafeOrderFeedView


urlpatterns = [
    path("orders", CafeOrderFeedView.as_view(), name="cafe-orders"),
]
