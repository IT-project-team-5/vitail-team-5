from django.conf import settings
from django.core.exceptions import ValidationError as ModelValidationError
from django.db.models import Q
from django.http import JsonResponse
from django.utils import timezone
from rest_framework.exceptions import NotFound, ValidationError
from rest_framework.response import Response
from rest_framework.views import APIView

from rewards.permissions import IsOwnerRole
from walks.models import WalkSession
from walks.services import WalkConflictError, distance_between

from . import live, presentation, services
from .models import Friendship, UserBlock
from .serializers import PreferencesSerializer, PresenceSerializer, PublicIDSerializer, ResponseSerializer, SessionStateSerializer, StartSessionSerializer


class SocialView(APIView):
    permission_classes = [IsOwnerRole]

    def finalize_response(self, request, response, *args, **kwargs):
        response = super().finalize_response(request, response, *args, **kwargs)
        response["Cache-Control"] = "private, no-store"
        return response

    def handle_exception(self, exc):
        if isinstance(exc, WalkConflictError):
            return Response({"code": "SOCIAL_CONFLICT", "message": str(exc)}, status=409)
        if isinstance(exc, ModelValidationError):
            exc = ValidationError(getattr(exc, "message_dict", None) or exc.messages)
        return super().handle_exception(exc)

    def peer(self, request, *, allow_blocked=False):
        serializer = PublicIDSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        return live.public_owner(serializer.validated_data["public_id"], actor=request.user, allow_blocked=allow_blocked)


class OverviewView(SocialView):
    def get(self, request):
        session = live.current_session(request.user)
        live.refresh_invitations(request.user.pk)
        request.user.refresh_from_db()
        rows = Friendship.objects.filter(Q(user_low=request.user) | Q(user_high=request.user)).select_related("user_low", "user_high")
        unavailable = live.blocked_ids(request.user.pk)
        groups = {"friends": [], "incoming_requests": [], "outgoing_requests": []}
        for row in rows:
            peer = row.user_high if row.user_low_id == request.user.pk else row.user_low
            if peer.pk in unavailable or not peer.is_active or peer.deleted_at or peer.role != "OWNER":
                continue
            data = presentation.relationship(row, request.user.pk, request)
            if row.status == "ACCEPTED":
                groups["friends"].append(data)
            elif row.status == "PENDING":
                groups["incoming_requests" if data["is_incoming"] else "outgoing_requests"].append(data)
        blocks = UserBlock.objects.filter(blocker=request.user, blocked__is_active=True, blocked__deleted_at__isnull=True).select_related("blocked")
        return Response({
            "me": presentation.profile(request.user, request, preferences=True), **groups,
            "blocked_users": [presentation.profile(row.blocked, request) for row in blocks],
            "current_session": presentation.live_session(session, request),
        })


class UserSearchView(SocialView):
    def get(self, request):
        query = request.query_params.get("q", "").strip()
        if len(query) < 2:
            return Response([])
        if len(query) > 100:
            raise ValidationError("Search must contain at most one hundred characters.")
        users = live.active_owners().exclude(pk__in=live.blocked_ids(request.user.pk) | {request.user.pk})
        users = users.filter(Q(display_name__icontains=query) | Q(public_id__iexact=query)).order_by("display_name", "id")[:20]
        return Response([presentation.profile(user, request) for user in users])


class FriendRequestView(SocialView):
    def post(self, request):
        peer = self.peer(request)
        row = services.request_friendship(sender=request.user, recipient=peer, allow_declined=True)
        return Response(presentation.relationship(row, request.user.pk, request), status=201)


class FriendResponseView(SocialView):
    def post(self, request, relationship_id):
        serializer = ResponseSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        row = Friendship.objects.filter(Q(user_low=request.user) | Q(user_high=request.user), pk=relationship_id).select_related("user_low", "user_high").first()
        if row is None:
            raise NotFound("This friend request is unavailable.")
        peer = row.user_high if row.user_low_id == request.user.pk else row.user_low
        row = services.respond_to_friendship(actor=request.user, other=peer, **serializer.validated_data)
        return Response(presentation.relationship(row, request.user.pk, request))


class FriendRemoveView(SocialView):
    def post(self, request, public_id):
        peer = live.public_owner(public_id, actor=request.user, allow_blocked=True)
        services.remove_friendship(actor=request.user, other=peer)
        return Response({"removed": True})


class BlockView(SocialView):
    def post(self, request):
        peer = self.peer(request, allow_blocked=True)
        services.block_user(actor=request.user, other=peer)
        return Response({"blocked": True})


class UnblockView(SocialView):
    def post(self, request, public_id):
        peer = live.public_owner(public_id, actor=request.user, allow_blocked=True)
        services.unblock_user(actor=request.user, other=peer)
        return Response({"unblocked": True})


class PreferencesView(SocialView):
    def patch(self, request):
        serializer = PreferencesSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        owner = live.update_preferences(owner=request.user, **serializer.validated_data)
        return Response(presentation.profile(owner, request, preferences=True))


class MapView(SocialView):
    def get(self, request):
        mine = live.current_session(request.user)
        live.refresh_invitations(request.user.pk)
        request.user.refresh_from_db()
        blocked = live.blocked_ids(request.user.pk)
        friend_ids = set()
        for row in Friendship.objects.filter(Q(user_low=request.user) | Q(user_high=request.user), status="ACCEPTED"):
            friend_ids.add(row.user_high_id if row.user_low_id == request.user.pk else row.user_low_id)
        friend_ids -= blocked
        pair = live.active_invitation(request.user.pk)
        partner_id = (pair.recipient_id if pair.sender_id == request.user.pk else pair.sender_id) if pair else None
        now = timezone.now()
        peers = WalkSession.objects.filter(
            state="RECORDING", location_expires_at__gt=now,
            owner__is_active=True, owner__deleted_at__isnull=True, owner__role="OWNER",
        ).exclude(owner_id__in=blocked | {request.user.pk}).select_related("owner")
        friends, nearby, partner = [], [], None
        for session in peers:
            if not live.fresh_presence(session, now):
                continue
            is_partner = session.owner_id == partner_id
            if session.owner_id in friend_ids and session.owner.location_visibility == "FRIENDS":
                friends.append(presentation.map_peer(session, request, is_partner=is_partner))
            if is_partner:
                partner = presentation.map_peer(session, request, is_partner=True)
            elif mine and live.fresh_presence(mine, now) and request.user.net_matching_enabled and session.owner.net_matching_enabled:
                distance = distance_between(live._coordinates(mine), live._coordinates(session))
                if distance <= settings.SOCIAL_NEARBY_RADIUS_M:
                    nearby.append(presentation.map_peer(session, request, approximate=True, distance=distance))
        nearby.sort(key=lambda row: (row["distance_m"], row["user"]["public_id"]))
        return Response({"friends": friends, "nearby": nearby[:50], "partner": partner})


class SessionCreateView(SocialView):
    def post(self, request):
        serializer = StartSessionSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        session = live.start_session(owner=request.user, **serializer.validated_data)
        return Response(presentation.live_session(session, request), status=201)


class CurrentSessionView(SocialView):
    def get(self, request):
        session = live.current_session(request.user)
        live.refresh_invitations(request.user.pk)
        data = presentation.live_session(session, request)
        return Response(data) if data is not None else JsonResponse(None, safe=False)


class PresenceView(SocialView):
    def post(self, request, session_id):
        serializer = PresenceSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        session, code = live.report_presence(owner=request.user, session_id=session_id, **serializer.validated_data)
        if code == "LOCATION_RATE_LIMIT":
            return Response({"code": code, "message": "Wait at least one second before sending another GPS reading."}, status=429, headers={"Retry-After": str(settings.SOCIAL_MIN_SAMPLE_SECONDS)})
        if code:
            return Response({"code": code, "message": "Location is unavailable for sharing or Net-Walking. Wait for a fresh, accurate real GPS reading."}, status=400)
        return Response(presentation.live_session(session, request))


class SessionStateView(SocialView):
    def post(self, request, session_id):
        serializer = SessionStateSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        session = live.update_session_state(owner=request.user, session_id=session_id, **serializer.validated_data)
        return Response(presentation.live_session(session, request))


class InvitationView(SocialView):
    def get(self, request):
        live.current_session(request.user)
        live.refresh_invitations(request.user.pk)
        rows = live.invitations_for(request.user.pk).filter(status__in=live.OPEN_STATUSES).select_related("sender", "recipient")
        incoming, outgoing, active = [], [], None
        for row in rows:
            data = presentation.invitation(row, request.user.pk, request)
            if row.status == "ACTIVE":
                active = data
            else:
                (incoming if data["is_incoming"] else outgoing).append(data)
        return Response({"incoming": incoming, "outgoing": outgoing, "active": active})

    def post(self, request):
        row = live.send_invitation(sender=request.user, recipient=self.peer(request))
        return Response(presentation.invitation(row, request.user.pk, request), status=201)


class InvitationResponseView(SocialView):
    def post(self, request, invitation_id):
        serializer = ResponseSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        row = live.respond_invitation(actor=request.user, invitation_id=invitation_id, **serializer.validated_data)
        return Response(presentation.invitation(row, request.user.pk, request))


class InvitationEndView(SocialView):
    def post(self, request, invitation_id):
        row = live.end_invitation(actor=request.user, invitation_id=invitation_id)
        return Response(presentation.invitation(row, request.user.pk, request))
