from django.conf import settings

from .live import active_invitation, shared_distance


def profile(user, request=None, *, preferences=False):
    photo_url = user.photo.url if user.photo else None
    if photo_url and request:
        photo_url = request.build_absolute_uri(photo_url)
    data = {"public_id": user.public_id, "display_name": user.display_name, "photo_url": photo_url}
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
        "status": row.status, "is_incoming": incoming, "created_at": row.created_at.isoformat(),
        "session_id": row.recipient_session_id if incoming else row.sender_session_id,
        "partner_session_id": row.sender_session_id if incoming else row.recipient_session_id,
        "expires_at": row.expires_at.isoformat(), "end_reason": row.end_reason,
    }


def live_session(session, request=None):
    if session is None:
        return None
    row = active_invitation(session.owner_id)
    peer = row.recipient if row and row.sender_id == session.owner_id else (row.sender if row else None)
    distance = shared_distance(session)
    walk = session.walk
    awarded = walk.net_point_entry.amount if walk and walk.net_point_entry_id else 0
    bonus_status = "awaiting_rules" if not settings.NET_WALK_REWARDS_ENABLED else ("settled" if walk and walk.net_settled_at else "provisional")
    return {
        "id": session.pk, "request_id": str(session.request_id), "state": session.state,
        "net_consent": bool(row), "shared_distance_m": float(distance),
        "estimated_bonus_points": min(10, int(distance * 2 / 1000)), "bonus_points": awarded,
        "bonus_status": bonus_status, "partner": profile(peer, request) if peer else None,
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
