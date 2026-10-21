from django.urls import path, re_path, register_converter
from django.urls.converters import UUIDConverter

from .views import CheckInCancelView, CheckInCollectionView, CheckInLocationView, CheckInProgressView, VenueCheckInStartView, VenueMapView, WalkContextView


class CheckInUUIDConverter(UUIDConverter):
    # Foundation's UUID string representation is uppercase. Keep canonical
    # UUID validation and conversion while accepting either hex letter case.
    regex = "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"


register_converter(CheckInUUIDConverter, "checkin_uuid")


urlpatterns = [
    re_path(r"^check-ins/walk-context/?$", WalkContextView.as_view(), name="checkin-walk-context"),
    re_path(r"^venues/?$", VenueMapView.as_view(), name="venue-map"),
    re_path(r"^venues/(?P<venue_id>[0-9]+)/check-ins/?$", VenueCheckInStartView.as_view(), name="venue-checkin-start"),
    re_path(r"^check-ins/?$", CheckInProgressView.as_view(), name="checkin-progress"),
    path("check-ins/<checkin_uuid:attempt_id>/locations", CheckInLocationView.as_view(), name="checkin-location"),
    path("check-ins/<checkin_uuid:attempt_id>/locations/", CheckInLocationView.as_view()),
    path("check-ins/<checkin_uuid:attempt_id>/cancel", CheckInCancelView.as_view(), name="checkin-cancel"),
    path("check-ins/<checkin_uuid:attempt_id>/cancel/", CheckInCancelView.as_view()),
    path("check-ins/<checkin_uuid:attempt_id>/pause", CheckInCancelView.as_view(), name="checkin-pause"),
    path("check-ins/<checkin_uuid:attempt_id>/pause/", CheckInCancelView.as_view()),
    path("check-ins/<checkin_uuid:attempt_id>/collect", CheckInCollectionView.as_view(), name="checkin-collect"),
    path("check-ins/<checkin_uuid:attempt_id>/collect/", CheckInCollectionView.as_view()),
]
