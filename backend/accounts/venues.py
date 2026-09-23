from urllib.parse import urlencode, urlsplit

from rest_framework import serializers

from .models import CafeProfile


def cafe_profile_for(user):
    try:
        return user.cafe_profile
    except CafeProfile.DoesNotExist:
        return None


def google_maps_url(user, profile=None):
    if profile and profile.google_maps_url:
        return profile.google_maps_url
    query = user.display_name
    if profile and profile.address:
        query += ", " + profile.address
    return "https://www.google.com/maps/search/?" + urlencode({"api": 1, "query": query})


def validate_google_maps_url(value):
    if not value:
        return value
    parsed = urlsplit(value)
    host = (parsed.hostname or "").lower()
    path = parsed.path
    normal_hosts = {
        "google.com", "www.google.com", "google.com.au", "www.google.com.au",
        "google.co.uk", "www.google.co.uk", "google.co.nz", "www.google.co.nz",
    }
    is_maps_path = path == "/maps" or path.startswith("/maps/")
    valid_host = (
        host in {"maps.app.goo.gl", "maps.google.com", "maps.google.com.au"}
        or (host in normal_hosts | {"goo.gl"} and is_maps_path)
    )
    if (parsed.scheme not in {"https", "http"} or parsed.username or parsed.password
            or not valid_host):
        raise serializers.ValidationError("Paste a Google Maps link, or leave this blank to use the café address.")
    return value
