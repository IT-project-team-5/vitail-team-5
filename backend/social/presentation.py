from .live import has_active_invitation, shared_distance


def profile(user, request=None, *, preferences=False):
    photo_url = user.photo.url if user.photo else None
    if photo_url and request:
        photo_url = request.build_absolute_uri(photo_url)
    data = {
        "public_id": user.public_id,
        "display_name": user.display_name,
        "photo_url": photo_url,
        "avatar_key": user.virtual_avatar_key,
    }
    if preferences:
        data.update(location_visibility=user.location_visibility, net_matching_enabled=user.net_matching_enabled)
    return data


def relationship(row, actor_id, request=None):
    peer = row.user_high if row.user_low_id == actor_id else row.user_low
    return {"id": row.pk, "user": profile(peer, request), "status": row.status, "is_incoming": row.requested_by_id != actor_id}


def invitation(row, actor_id, request=None):
    incoming = row.recipient_id == actor_id
    return {
        "id": row.pk, "user": profile(row.sender if incoming else row.recipient, request),
        "status": row.status, "is_incoming": incoming,
    }


def live_session(session, request=None):
    if session is None:
        return None
    has_consent = has_active_invitation(session.owner_id)
    distance = shared_distance(session) if has_consent else 0
    return {
        "id": session.pk, "request_id": str(session.request_id), "state": session.state,
        "net_consent": has_consent, "shared_distance_m": float(distance),
    }


def map_peer(session, request=None, *, approximate=False, is_partner=False, distance=None):
    latitude, longitude = float(session.last_latitude), float(session.last_longitude)
    data = {
        "user": profile(session.owner, request),
        "latitude": round(latitude, 3) if approximate else latitude,
        "longitude": round(longitude, 3) if approximate else longitude,
        "recorded_at": session.location_recorded_at.isoformat(),
        "expires_at": session.location_expires_at.isoformat(),
        "is_net_partner": is_partner, "is_approximate": approximate,
    }
    if distance is not None:
        data["distance_m"] = round(distance / 100) * 100 if approximate else round(distance)
    return data
