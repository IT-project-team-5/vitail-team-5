from django.urls import path, re_path

from .views import CheckInCancelView, CheckInCollectionView, CheckInLocationView, CheckInProgressView, VenueCheckInStartView, VenueMapView


urlpatterns = [
    re_path(r"^venues/?$", VenueMapView.as_view(), name="venue-map"),
    re_path(r"^venues/(?P<venue_id>[0-9]+)/check-ins/?$", VenueCheckInStartView.as_view(), name="venue-checkin-start"),
    re_path(r"^check-ins/?$", CheckInProgressView.as_view(), name="checkin-progress"),
    path("check-ins/<uuid:attempt_id>/locations", CheckInLocationView.as_view(), name="checkin-location"),
    path("check-ins/<uuid:attempt_id>/locations/", CheckInLocationView.as_view()),
    path("check-ins/<uuid:attempt_id>/cancel", CheckInCancelView.as_view(), name="checkin-cancel"),
    path("check-ins/<uuid:attempt_id>/cancel/", CheckInCancelView.as_view()),
    path("check-ins/<uuid:attempt_id>/collect", CheckInCollectionView.as_view(), name="checkin-collect"),
    path("check-ins/<uuid:attempt_id>/collect/", CheckInCollectionView.as_view()),
]
