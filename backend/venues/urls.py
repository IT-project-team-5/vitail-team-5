from django.urls import re_path

from .views import CheckInAbandonView, CheckInLocationView, VenueCheckInView, VenueListView


urlpatterns = [
    re_path(r"^venues/?$", VenueListView.as_view(), name="venue-list"),
    re_path(r"^venues/(?P<venue_id>\d+)/check-ins/?$", VenueCheckInView.as_view(), name="venue-check-in"),
    re_path(r"^check-ins/(?P<check_in_id>\d+)/locations/?$", CheckInLocationView.as_view(), name="check-in-location"),
    re_path(r"^check-ins/(?P<check_in_id>\d+)/abandon/?$", CheckInAbandonView.as_view(), name="check-in-abandon"),
]
