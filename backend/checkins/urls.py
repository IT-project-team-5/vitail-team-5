from django.urls import re_path

from .views import CheckInCancelView, CheckInCollectionView, CheckInLocationView, CheckInProgressView, VenueCheckInStartView, VenueMapView


urlpatterns = [
    re_path(r"^venues/?$", VenueMapView.as_view(), name="venue-map"),
    re_path(r"^venues/(?P<venue_id>[0-9]+)/check-ins/?$", VenueCheckInStartView.as_view(), name="venue-checkin-start"),
    re_path(r"^check-ins/?$", CheckInProgressView.as_view(), name="checkin-progress"),
    re_path(r"^check-ins/(?P<checkin_id>[0-9]+)/locations/?$", CheckInLocationView.as_view(), name="checkin-location"),
    re_path(r"^check-ins/(?P<checkin_id>[0-9]+)/cancel/?$", CheckInCancelView.as_view(), name="checkin-cancel"),
    re_path(r"^check-ins/(?P<attempt_id>[0-9a-f-]+)/collect/?$", CheckInCollectionView.as_view(), name="checkin-collect"),
]
