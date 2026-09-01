from django.urls import path

from .views import VenueDetailView, VenueListView, VenueOffersView

urlpatterns = [
    path("", VenueListView.as_view(), name="venue-list"),
    path("<int:pk>", VenueDetailView.as_view(), name="venue-detail"),
    path("<int:venue_id>/offers", VenueOffersView.as_view(), name="venue-offers"),
]
