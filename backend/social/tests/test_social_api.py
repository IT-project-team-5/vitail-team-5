import math
from datetime import datetime, timedelta
from decimal import Decimal
from unittest.mock import patch
from uuid import uuid4
from zoneinfo import ZoneInfo

from django.contrib.auth import get_user_model
from django.db import IntegrityError, transaction
from django.db.models import Sum
from django.test import override_settings
from django.utils import timezone
from rest_framework.test import APIRequestFactory, APITestCase

from dogs.models import Breed, Dog
from rewards.models import PointEntry
from rewards.services import credit_points
from social import live as social_live
from social.live import purge_expired_presence, refresh_invitations
from social.models import Friendship, NetWalkInvitation, UserBlock
from social.views import (
    SocialInvitationThrottle,
    SocialMapThrottle,
    SocialSearchThrottle,
    _discovery_bounds,
)
from walks.models import LocationSample, NetWalkInterval, Walk, WalkSession

User = get_user_model()


class SocialApiTests(APITestCase):
    @classmethod
    def setUpTestData(cls):
        cls.alice = User.objects.create_user(email="alice-private@example.com", display_name="Alice Walker")
        cls.bob = User.objects.create_user(email="bob-private@example.com", display_name="Bob Walker")
        cls.eve = User.objects.create_user(email="eve-private@example.com", display_name="Eve Walker")
        cls.cafe = User.objects.create_user(email="cafe-private@example.com", display_name="Cafe Walker", role="CAFE")
        breed = Breed.objects.create(name="Social test breed", energy_level="MODERATE", default_size="SMALL")
        cls.dog = Dog.objects.create(owner=cls.alice, breed=breed, name="Milo", age_months=24, size="SMALL", is_brachycephalic=False)

    def setUp(self):
        self.now = datetime(2026, 10, 7, 12, tzinfo=ZoneInfo("Australia/Melbourne"))
        clock = patch("social.live.timezone.now", side_effect=lambda: self.now)
        clock.start()
        self.addCleanup(clock.stop)
        self.client.force_authenticate(self.alice)

    def as_user(self, user):
        user.refresh_from_db()
        self.client.force_authenticate(user)

    def post(self, path, data=None, expected=200):
        response = self.client.post("/api/social/" + path, data or {}, format="json")
        self.assertEqual(response.status_code, expected, response.data)
        return response.data

    def preferences(self, user, **values):
        self.as_user(user)
        response = self.client.patch("/api/social/preferences", values, format="json")
        self.assertEqual(response.status_code, 200, response.data)
        return response.data

    def start(self, user):
        self.as_user(user)
        return self.post("walk-sessions", {"request_id": str(uuid4()), "started_at": (self.now - timedelta(seconds=1)).isoformat()}, expected=201)

    def location(self, user, session, metres=0, **overrides):
        self.as_user(user)
        data = {
            "latitude": 0, "longitude": math.degrees(metres / 6_371_000),
            "accuracy_m": 5, "recorded_at": self.now.isoformat(), "is_simulated": False,
            **overrides,
        }
        return self.client.post(f"/api/social/walk-sessions/{session['id']}/location", data, format="json")

    def prepare_walkers(self):
        sessions = []
        for user, offset in ((self.alice, 0), (self.bob, 5)):
            self.preferences(user, net_matching_enabled=True)
            session = self.start(user)
            self.assertEqual(self.location(user, session, offset).status_code, 200)
            sessions.append(session)
        return sessions

    def accept_pair(self):
        alice_session, bob_session = self.prepare_walkers()
        self.as_user(self.alice)
        invite = self.post("net-walk-invitations", {"public_id": self.bob.public_id}, expected=201)
        self.as_user(self.bob)
        accepted = self.post(f"net-walk-invitations/{invite['id']}/respond", {"accept": True})
        self.assertEqual(accepted["status"], "ACTIVE")
        return alice_session, bob_session, invite

    def friend_pair(self):
        self.as_user(self.alice)
        row = self.post("friend-requests", {"public_id": self.bob.public_id}, expected=201)
        self.as_user(self.bob)
        self.post(f"friend-requests/{row['id']}/respond", {"accept": True})
        return row

    def live_candidate(self, name, *, latitude, longitude):
        user = User.objects.create_user(
            email=f"{name.lower().replace(' ', '-')}@example.com", display_name=name,
            net_matching_enabled=True,
        )
        session = WalkSession.objects.create(
            owner=user, request_id=uuid4(), state="RECORDING",
            started_at=self.now - timedelta(seconds=1), heartbeat_at=self.now,
            last_latitude=latitude, last_longitude=longitude, last_accuracy_m=5,
            location_recorded_at=self.now,
            location_expires_at=self.now + timedelta(seconds=30),
            validation_version="test-only",
        )
        user.active_walk_session = session
        user.save(update_fields=("active_walk_session",))
        return session

    def test_search_and_overview_expose_public_identity_never_email(self):
        self.as_user(self.alice)
        for query in ("", "B", self.bob.email):
            self.assertEqual(self.client.get("/api/social/users", {"q": query}).data, [])
        response = self.client.get("/api/social/users", {"q": "Walker"})
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response["Cache-Control"], "private, no-store")
        self.assertEqual({row["display_name"] for row in response.data}, {"Bob Walker", "Eve Walker"})
        self.assertTrue(all(set(row) == {"public_id", "display_name", "photo_url", "avatar_key"} for row in response.data))
        self.assertNotIn("private@example.com", str(response.data))
        by_id = self.client.get("/api/social/users", {"q": self.bob.public_id})
        self.assertEqual(by_id.data[0]["public_id"], self.bob.public_id)
        overview = self.client.get("/api/social/overview").data
        self.assertEqual(overview["me"]["location_visibility"], "OFF")
        self.assertFalse(overview["me"]["net_matching_enabled"])
        self.assertEqual(overview["me"]["avatar_key"], "")
        self.assertNotIn("email", overview["me"])

    def test_social_endpoint_throttles_have_independent_per_user_buckets(self):
        request = APIRequestFactory().get("/api/social/map")
        request.user = self.alice
        keys = {
            throttle().get_cache_key(request, None)
            for throttle in (SocialSearchThrottle, SocialInvitationThrottle, SocialMapThrottle)
        }
        self.assertEqual(len(keys), 3)
        self.assertEqual(SocialMapThrottle.rate, "60/min")

    def test_virtual_avatar_can_be_selected_and_is_limited_to_known_values(self):
        updated = self.preferences(self.alice, virtual_avatar_key="paw")
        self.assertEqual(updated["avatar_key"], "paw")
        self.alice.refresh_from_db()
        self.assertEqual(self.alice.virtual_avatar_key, "paw")
        response = self.client.patch(
            "/api/social/preferences", {"virtual_avatar_key": "unknown"}, format="json"
        )
        self.assertEqual(response.status_code, 400)
        self.assertEqual(self.client.get("/api/social/overview").data["me"]["avatar_key"], "paw")

    def test_owner_only_and_active_account_guards(self):
        self.client.force_authenticate(None)
        self.assertEqual(self.client.get("/api/social/overview").status_code, 401)
        self.as_user(self.cafe)
        self.assertEqual(self.client.get("/api/social/overview").status_code, 403)
        self.as_user(self.alice)
        User.objects.filter(pk=self.bob.pk).update(deleted_at=self.now)
        self.post("friend-requests", {"public_id": self.bob.public_id}, expected=404)
        self.assertEqual(self.client.get("/api/social/users", {"q": "Bob"}).data, [])
        User.objects.filter(pk=self.alice.pk).update(is_active=False)
        self.assertEqual(self.client.get("/api/social/overview").status_code, 404)

    def test_request_accept_remove_and_reciprocal_consent(self):
        row = self.post("friend-requests", {"public_id": self.bob.public_id}, expected=201)
        repeated = self.post("friend-requests", {"public_id": self.bob.public_id}, expected=201)
        self.assertEqual(row["id"], repeated["id"])
        self.as_user(self.eve)
        self.post(f"friend-requests/{row['id']}/respond", {"accept": True}, expected=404)
        self.as_user(self.alice)
        self.post(f"friend-requests/{row['id']}/respond", {"accept": True}, expected=400)
        self.as_user(self.bob)
        reciprocal = self.post("friend-requests", {"public_id": self.alice.public_id}, expected=201)
        self.assertEqual(reciprocal["status"], "PENDING")
        incoming = self.client.get("/api/social/overview").data["incoming_requests"]
        self.assertEqual(len(incoming), 1)
        self.post(f"friend-requests/{row['id']}/respond", {"accept": True})
        self.post(f"friend-requests/{row['id']}/respond", {"accept": True})
        self.assertEqual(len(self.client.get("/api/social/overview").data["friends"]), 1)
        self.post(f"friends/{self.alice.public_id}/remove")
        self.assertFalse(Friendship.objects.exists())

    def test_declined_request_can_be_explicitly_renewed_without_auto_acceptance(self):
        row = self.post("friend-requests", {"public_id": self.bob.public_id}, expected=201)
        self.as_user(self.bob)
        self.post(f"friend-requests/{row['id']}/respond", {"accept": False})
        self.as_user(self.alice)
        renewed = self.post("friend-requests", {"public_id": self.bob.public_id}, expected=201)
        self.assertEqual(renewed["id"], row["id"])
        self.assertEqual(renewed["status"], "PENDING")
        self.assertFalse(Friendship.objects.filter(status="ACCEPTED").exists())

    def test_block_hides_search_requests_presence_and_unblock_does_not_restore(self):
        self.friend_pair()
        alice_session, bob_session, invite = self.accept_pair()
        self.as_user(self.alice)
        self.post("blocks", {"public_id": self.bob.public_id})
        self.assertFalse(Friendship.objects.exists())
        self.assertEqual(NetWalkInvitation.objects.get(pk=invite["id"]).status, "ENDED")
        overview = self.client.get("/api/social/overview").data
        self.assertEqual(overview["blocked_users"][0]["public_id"], self.bob.public_id)
        self.assertEqual(self.client.get("/api/social/users", {"q": "Bob"}).data, [])
        self.assertEqual(self.client.get("/api/social/map").data, {"friends": [], "nearby": [], "partner": None})
        self.as_user(self.bob)
        self.post("friend-requests", {"public_id": self.alice.public_id}, expected=404)
        self.post(f"blocks/{self.alice.public_id}/remove")
        self.assertTrue(UserBlock.objects.exists())
        self.as_user(self.alice)
        self.post(f"blocks/{self.bob.public_id}/remove")
        self.assertFalse(UserBlock.objects.exists())
        self.assertFalse(Friendship.objects.exists())

    def test_exact_friend_location_requires_explicit_visibility_and_fresh_recording(self):
        self.friend_pair()
        bob_session = self.start(self.bob)
        self.assertEqual(self.location(self.bob, bob_session, 13).status_code, 200)
        self.as_user(self.alice)
        self.assertEqual(self.client.get("/api/social/map").data["friends"], [])
        self.preferences(self.bob, location_visibility="FRIENDS")
        self.as_user(self.alice)
        peer = self.client.get("/api/social/map").data["friends"][0]
        self.assertFalse(peer["is_approximate"])
        self.assertIsInstance(peer["longitude"], float)
        self.assertIn("expires_at", peer)
        self.as_user(self.eve)
        self.assertEqual(self.client.get("/api/social/map").data["friends"], [])
        self.now += timedelta(seconds=31)
        self.as_user(self.alice)
        self.assertEqual(self.client.get("/api/social/map").data["friends"], [])
        purge_expired_presence()
        self.assertIsNone(WalkSession.objects.get(pk=bob_session["id"]).last_latitude)

    def test_default_off_map_only_evaluates_explicitly_visible_sessions(self):
        self.friend_pair()
        self.preferences(self.bob, location_visibility="FRIENDS")
        bob_session = self.start(self.bob)
        self.assertEqual(self.location(self.bob, bob_session, 13).status_code, 200)
        eve_session = self.start(self.eve)
        self.assertEqual(self.location(self.eve, eve_session, 20).status_code, 200)
        self.as_user(self.alice)
        with patch("social.views.live.fresh_presence", wraps=social_live.fresh_presence) as freshness:
            data = self.client.get("/api/social/map").data
        self.assertEqual([row["user"]["public_id"] for row in data["friends"]], [self.bob.public_id])
        checked_owner_ids = {
            call.args[0].owner_id for call in freshness.call_args_list if call.args
        }
        self.assertEqual(checked_owner_ids, {self.bob.pk})

    @override_settings(SOCIAL_DISCOVERY_CANDIDATE_LIMIT=3)
    def test_discovery_bounds_and_caps_exact_distance_work(self):
        self.preferences(self.alice, net_matching_enabled=True)
        mine = self.start(self.alice)
        self.assertEqual(self.location(self.alice, mine).status_code, 200)
        for index in range(5):
            self.live_candidate(
                f"Nearby {index}", latitude=0,
                longitude=math.degrees((index + 1) * 20 / 6_371_000),
            )
        far = self.live_candidate("Far Away", latitude=20, longitude=20)

        self.as_user(self.alice)
        with patch("social.views.distance_between", wraps=social_live.distance_between) as distance:
            data = self.client.get("/api/social/map").data

        self.assertEqual(len(data["nearby"]), 3)
        self.assertEqual(distance.call_count, 3)
        scanned_latitudes = {call.args[1]["latitude"] for call in distance.call_args_list}
        self.assertNotIn(float(far.last_latitude), scanned_latitudes)

    def test_discovery_box_wraps_dateline_and_covers_poles(self):
        self.preferences(self.alice, net_matching_enabled=True)
        mine = self.start(self.alice)
        self.assertEqual(
            self.location(self.alice, mine, longitude=179.999).status_code, 200
        )
        peer = self.live_candidate(
            "Dateline Nearby", latitude=0, longitude=-179.999
        )
        self.as_user(self.alice)
        nearby = self.client.get("/api/social/map").data["nearby"]
        self.assertEqual(
            [row["user"]["public_id"] for row in nearby], [peer.owner.public_id]
        )
        south, north, longitudes = _discovery_bounds(89.999, 30, 2000)
        self.assertLess(south, north)
        self.assertIsNone(longitudes)

    def test_net_discovery_is_coarse_opt_in_and_independent_of_friend_visibility(self):
        alice_session, bob_session = self.prepare_walkers()
        self.as_user(self.alice)
        data = self.client.get("/api/social/map").data
        self.assertEqual(data["friends"], [])
        self.assertEqual(len(data["nearby"]), 1)
        self.assertTrue(data["nearby"][0]["is_approximate"])
        self.assertEqual(data["nearby"][0]["longitude"], 0.0)
        self.assertEqual(data["nearby"][0]["distance_m"], 0)
        self.preferences(self.bob, net_matching_enabled=False)
        self.as_user(self.alice)
        self.assertEqual(self.client.get("/api/social/map").data["nearby"], [])
        self.post("net-walk-invitations", {"public_id": self.bob.public_id}, expected=400)

    def test_nonfriends_accept_explicit_invitation_and_pair_progress_never_replays(self):
        alice_session, bob_session, invite = self.accept_pair()
        self.assertEqual(set(invite), {"id", "user", "status", "is_incoming"})
        self.assertFalse(Friendship.objects.exists())
        self.as_user(self.eve)
        self.post(f"net-walk-invitations/{invite['id']}/respond", {"accept": True}, expected=404)
        self.post(f"net-walk-invitations/{invite['id']}/end", expected=404)
        self.as_user(self.alice)
        self.assertTrue(self.client.get("/api/social/walk-sessions/current").data["net_consent"])
        self.assertEqual(
            set(self.client.get("/api/social/walk-sessions/current").data),
            {"id", "request_id", "state", "net_consent", "shared_distance_m"},
        )
        self.assertIsNotNone(self.client.get("/api/social/map").data["partner"])
        self.now += timedelta(seconds=10)
        self.assertEqual(self.location(self.alice, alice_session, 20).status_code, 200)
        response = self.location(self.bob, bob_session, 25)
        self.assertEqual(response.status_code, 200, response.data)
        self.assertAlmostEqual(response.data["shared_distance_m"], 20, delta=0.2)
        self.assertGreater(response.data["shared_distance_m"], 0)
        self.assertNotIn("bonus_status", response.data)
        self.assertEqual(PointEntry.objects.count(), 0)
        self.assertEqual(NetWalkInterval.objects.count(), 1)
        self.assertEqual(NetWalkInterval.objects.get().invitation_id, invite["id"])
        replay = self.location(self.bob, bob_session, 25)
        self.assertEqual(replay.status_code, 200)
        self.assertEqual(NetWalkInterval.objects.count(), 1)
        self.assertAlmostEqual(replay.data["shared_distance_m"], 20, delta=0.2)
        changed = self.location(self.bob, bob_session, 26)
        self.assertEqual(changed.status_code, 409)

    def test_pending_invitation_cannot_be_self_accepted_or_change_partner(self):
        alice_session, bob_session = self.prepare_walkers()
        self.as_user(self.alice)
        row = self.post("net-walk-invitations", {"public_id": self.bob.public_id}, expected=201)
        self.post(f"net-walk-invitations/{row['id']}/respond", {"accept": True}, expected=404)
        self.assertFalse(self.client.get("/api/social/walk-sessions/current").data["net_consent"])
        self.post("net-walk-invitations", {"public_id": self.alice.public_id}, expected=404)
        self.as_user(self.bob)
        self.post("net-walk-invitations", {"public_id": self.alice.public_id}, expected=409)
        self.post(f"net-walk-invitations/{row['id']}/respond", {"accept": False})
        self.assertIsNone(self.client.get("/api/social/net-walk-invitations").data["active"])

    def test_pending_invitation_has_deadline_and_no_distance_without_acceptance(self):
        alice_session, bob_session = self.prepare_walkers()
        self.as_user(self.alice)
        row = self.post("net-walk-invitations", {"public_id": self.bob.public_id}, expected=201)
        for index in range(1, 13):
            self.now += timedelta(seconds=10)
            self.location(self.alice, alice_session, index * 20)
            self.location(self.bob, bob_session, index * 20 + 5)
        self.assertFalse(NetWalkInterval.objects.exists())
        self.as_user(self.bob)
        self.assertEqual(self.client.get("/api/social/net-walk-invitations").data["incoming"], [])
        self.assertEqual(NetWalkInvitation.objects.get(pk=row["id"]).status, "EXPIRED")
        self.post(f"net-walk-invitations/{row['id']}/respond", {"accept": True}, expected=409)

    def test_refresh_does_not_overwrite_concurrent_invitation_transition(self):
        alice_session, bob_session = self.prepare_walkers()
        self.as_user(self.alice)
        invitation = self.post(
            "net-walk-invitations", {"public_id": self.bob.public_id}, expected=201
        )

        def accept_after_refresh_read(*_args):
            NetWalkInvitation.objects.filter(pk=invitation["id"]).update(
                status="ACTIVE", accepted_at=self.now
            )
            WalkSession.objects.filter(pk__in=(alice_session["id"], bob_session["id"])).update(
                net_consent_at=self.now, net_consent_withdrawn_at=None
            )
            return True

        with patch("social.live.is_blocked", side_effect=accept_after_refresh_read):
            refresh_invitations(self.alice.pk, now=self.now)

        row = NetWalkInvitation.objects.get(pk=invitation["id"])
        self.assertEqual(row.status, "ACTIVE")
        self.assertEqual(row.accepted_at, self.now)
        self.assertFalse(
            WalkSession.objects.filter(
                pk__in=(alice_session["id"], bob_session["id"]),
                net_consent_withdrawn_at__isnull=False,
            ).exists()
        )

    def test_distance_requires_both_moving_close_fresh_locations(self):
        alice_session, bob_session, invite = self.accept_pair()
        self.now += timedelta(seconds=10)
        self.assertEqual(self.location(self.alice, alice_session, 20).status_code, 200)
        self.assertEqual(self.location(self.bob, bob_session, 5).status_code, 200)
        self.assertFalse(NetWalkInterval.objects.exists())
        # Separated by >50m, even though both submit plausible walking speeds.
        for index in range(1, 5):
            self.now += timedelta(seconds=10)
            self.assertEqual(self.location(self.alice, alice_session, 20 + index * 20).status_code, 200)
            self.assertEqual(self.location(self.bob, bob_session, 5 - index * 20).status_code, 200)
        # A short preceding overlap can be eligible, but no separated segment.
        old_count = NetWalkInterval.objects.count()
        self.now += timedelta(seconds=10)
        self.location(self.alice, alice_session, 120)
        self.location(self.bob, bob_session, -95)
        self.assertEqual(NetWalkInterval.objects.count(), old_count)
        self.now += timedelta(seconds=31)
        self.as_user(self.alice)
        self.assertIsNone(self.client.get("/api/social/net-walk-invitations").data["active"])
        self.assertIsNone(self.client.get("/api/social/map").data["partner"])

    def test_pause_stop_and_opt_out_revoke_partner_and_clear_gps(self):
        alice_session, bob_session, invite = self.accept_pair()
        self.as_user(self.alice)
        self.post(f"walk-sessions/{alice_session['id']}/state", {"state": "PAUSED"})
        self.assertFalse(LocationSample.objects.filter(session_id=alice_session["id"]).exists())
        self.assertIsNone(WalkSession.objects.get(pk=alice_session["id"]).last_latitude)
        self.assertEqual(NetWalkInvitation.objects.get(pk=invite["id"]).status, "ENDED")
        self.assertIsNone(self.client.get("/api/social/map").data["partner"])
        self.now += timedelta(seconds=10)
        self.post(f"walk-sessions/{alice_session['id']}/state", {"state": "RECORDING"})
        self.assertEqual(self.location(self.alice, alice_session, 1000).status_code, 200)
        self.assertEqual(WalkSession.objects.get(pk=alice_session["id"]).verified_distance_m, 0)
        self.post(f"walk-sessions/{alice_session['id']}/state", {"state": "FINISHED"})
        self.assertEqual(self.client.get("/api/social/walk-sessions/current").json(), None)
        self.alice.refresh_from_db()
        self.assertIsNone(self.alice.active_walk_session_id)
        self.preferences(self.bob, net_matching_enabled=False)
        self.assertFalse(self.bob.walk_sessions.get(pk=bob_session["id"]).net_consent_withdrawn_at is None)

    def test_simulated_inaccurate_future_stale_and_jump_samples_never_publish(self):
        self.friend_pair()
        self.preferences(self.bob, location_visibility="FRIENDS")
        bob_session = self.start(self.bob)
        response = self.location(self.bob, bob_session, is_simulated=True)
        self.assertEqual(response.status_code, 400)
        self.assertEqual(response.data["code"], "SIMULATED_LOCATION")
        self.now += timedelta(seconds=1)
        self.assertEqual(self.location(self.bob, bob_session, accuracy_m=31).status_code, 400)
        self.now += timedelta(seconds=1)
        self.assertEqual(self.location(self.bob, bob_session, recorded_at=(self.now + timedelta(minutes=1)).isoformat()).status_code, 400)
        self.assertEqual(self.location(self.bob, bob_session, recorded_at=(self.now - timedelta(seconds=31)).isoformat()).status_code, 400)
        self.assertEqual(self.location(self.bob, bob_session, 0).status_code, 200)
        self.now += timedelta(seconds=10)
        jumping = self.location(self.bob, bob_session, 1000)
        self.assertEqual(jumping.status_code, 400)
        self.assertEqual(jumping.data["code"], "IMPLAUSIBLE_SPEED")
        self.as_user(self.alice)
        self.assertEqual(self.client.get("/api/social/map").data["friends"], [])
        self.now += timedelta(seconds=10)
        self.assertEqual(self.location(self.bob, bob_session, 1005).status_code, 200)
        self.assertEqual(WalkSession.objects.get(pk=bob_session["id"]).verified_distance_m, 0)

    def test_session_is_idempotent_owned_and_timeout_releases_slot(self):
        row = self.start(self.alice)
        self.as_user(self.alice)
        started = WalkSession.objects.get(pk=row["id"]).started_at
        replay = self.post("walk-sessions", {"request_id": row["request_id"], "started_at": started.isoformat()}, expected=201)
        self.assertEqual(replay["id"], row["id"])
        self.post("walk-sessions", {"request_id": str(uuid4()), "started_at": self.now.isoformat()}, expected=409)
        self.as_user(self.eve)
        self.post(f"walk-sessions/{row['id']}/state", {"state": "FINISHED"}, expected=400)
        self.now += timedelta(minutes=6)
        self.as_user(self.alice)
        self.assertEqual(self.client.get("/api/social/walk-sessions/current").json(), None)
        self.assertEqual(WalkSession.objects.get(pk=row["id"]).state, "TIMED_OUT")
        new_row = self.start(self.alice)
        self.assertNotEqual(new_row["id"], row["id"])

    def test_presence_post_cannot_revive_a_timed_out_session(self):
        row = self.start(self.alice)
        WalkSession.objects.filter(pk=row["id"]).update(
            heartbeat_at=self.now - timedelta(minutes=6),
        )
        response = self.location(self.alice, row)
        self.assertEqual(response.status_code, 409)
        self.assertEqual(response.data["code"], "SESSION_TIMED_OUT")
        stored = WalkSession.objects.get(pk=row["id"])
        self.assertEqual(stored.state, "TIMED_OUT")
        self.assertEqual(stored.heartbeat_at, self.now)
        self.assertFalse(LocationSample.objects.filter(session=stored).exists())
        self.alice.refresh_from_db()
        self.assertIsNone(self.alice.active_walk_session_id)

    def test_future_presence_at_ttl_boundary_is_validation_error_not_database_error(self):
        session = self.start(self.alice)
        future = self.location(self.alice, session, recorded_at=(self.now + timedelta(seconds=30)).isoformat())
        self.assertEqual(future.status_code, 400)
        self.assertEqual(future.data["code"], "STALE_LOCATION")
        self.assertFalse(LocationSample.objects.exists())
        tolerated = self.location(self.alice, session, recorded_at=(self.now + timedelta(seconds=4)).isoformat())
        self.assertEqual(tolerated.status_code, 200)
        stored = WalkSession.objects.get(pk=session["id"])
        self.assertGreater(stored.location_expires_at, stored.location_recorded_at)

    def test_server_rate_limit_stops_dense_stream_and_never_bridges_rejected_update(self):
        alice_session, bob_session, invite = self.accept_pair()
        self.now += timedelta(milliseconds=500)
        limited = self.location(self.alice, alice_session, 1)
        self.assertEqual(limited.status_code, 429)
        self.assertEqual(limited["Retry-After"], "1")
        self.assertEqual(LocationSample.objects.filter(owner=self.alice).count(), 1)
        self.assertIsNone(WalkSession.objects.get(pk=alice_session["id"]).last_latitude)
        self.assertEqual(NetWalkInvitation.objects.get(pk=invite["id"]).status, "ENDED")
        self.now += timedelta(seconds=2)
        anchored = self.location(self.alice, alice_session, 1000)
        self.assertEqual(anchored.status_code, 200)
        self.assertEqual(WalkSession.objects.get(pk=alice_session["id"]).verified_distance_m, 0)
        self.assertFalse(NetWalkInterval.objects.exists())

    @override_settings(SOCIAL_MAX_SESSION_SAMPLES=3)
    def test_raw_buffer_is_bounded_even_with_current_readings(self):
        session = self.start(self.alice)
        self.location(self.alice, session)
        for index in range(1, 6):
            self.now += timedelta(seconds=10)
            self.assertEqual(self.location(self.alice, session, index * 20).status_code, 200)
        rows = LocationSample.objects.filter(session_id=session["id"])
        self.assertEqual(rows.count(), 3)
        self.assertEqual(list(rows.order_by("sequence").values_list("sequence", flat=True)), [3, 4, 5])

    def test_same_local_walk_can_recover_timed_out_presence_without_gap_credit_or_old_partner(self):
        alice_session, bob_session, invite = self.accept_pair()
        self.now += timedelta(seconds=10)
        self.location(self.alice, alice_session, 20)
        self.location(self.bob, bob_session, 25)
        self.assertEqual(NetWalkInterval.objects.count(), 1)
        original_started = WalkSession.objects.get(pk=alice_session["id"]).started_at
        self.preferences(self.alice, net_matching_enabled=False, location_visibility="OFF")
        self.now += timedelta(minutes=6)
        self.as_user(self.alice)
        self.assertIsNone(self.client.get("/api/social/overview").data["current_session"])
        self.assertFalse(LocationSample.objects.filter(owner=self.alice).exists())
        self.preferences(self.alice, net_matching_enabled=True)
        recovered = self.post("walk-sessions", {"request_id": alice_session["request_id"], "started_at": original_started.isoformat()}, expected=201)
        self.assertEqual(recovered["id"], alice_session["id"])
        self.assertEqual(recovered["state"], "RECORDING")
        self.assertFalse(recovered["net_consent"])
        old_distance = WalkSession.objects.get(pk=alice_session["id"]).verified_distance_m
        self.assertEqual(self.location(self.alice, recovered, 1000).status_code, 200)
        self.assertEqual(WalkSession.objects.get(pk=alice_session["id"]).verified_distance_m, old_distance)
        self.assertEqual(NetWalkInterval.objects.count(), 1)
        self.assertEqual(NetWalkInvitation.objects.get(pk=invite["id"]).status, "ENDED")

    def completed_pair_walk(self):
        alice_session, bob_session, invite = self.accept_pair()
        started = WalkSession.objects.get(pk=alice_session["id"]).started_at
        samples = [{"latitude": 0, "longitude": 0, "accuracy_m": 5, "is_simulated": False, "recorded_at": self.now.isoformat()}]
        # Fifty one legitimate 2m/s updates cross a whole bonus-point boundary.
        for index in range(1, 52):
            self.now += timedelta(seconds=10)
            metres = index * 20
            first = self.location(self.alice, alice_session, metres)
            second = self.location(self.bob, bob_session, metres + 5)
            self.assertEqual(first.status_code, 200, first.data)
            self.assertEqual(second.status_code, 200, second.data)
            samples.append({"latitude": 0, "longitude": math.degrees(metres / 6_371_000), "accuracy_m": 5, "is_simulated": False, "recorded_at": self.now.isoformat()})
        self.as_user(self.alice)
        self.post(f"walk-sessions/{alice_session['id']}/state", {"state": "FINISHED"})
        payload = {"request_id": alice_session["request_id"], "started_at": started.isoformat(), "ended_at": self.now.isoformat(), "dog_ids": [self.dog.pk], "samples": samples}
        response = self.client.post("/api/walks", payload, format="json")
        self.assertEqual(response.status_code, 201, response.data)
        return Walk.objects.get(pk=response.data["id"]), payload

    def test_completed_walk_links_verified_net_distance_without_unapproved_bonus(self):
        walk, payload = self.completed_pair_walk()
        self.assertAlmostEqual(float(walk.net_distance_m), 1020, delta=0.6)
        self.assertIsNotNone(walk.net_settled_at)
        self.assertIsNone(walk.net_point_entry_id)
        self.assertEqual(walk.points_awarded, 8)
        self.assertFalse(LocationSample.objects.filter(owner=self.alice).exists())
        with override_settings(NET_WALK_REWARDS_ENABLED=True):
            replay = self.client.post("/api/walks", payload, format="json")
            self.assertEqual(replay.status_code, 201)
            self.assertFalse(PointEntry.objects.filter(earn_category="NET_WALK").exists())

    @override_settings(NET_WALK_REWARDS_ENABLED=True)
    def test_optional_bonus_is_server_verified_and_idempotent_in_shared_cap(self):
        walk, payload = self.completed_pair_walk()
        self.assertEqual(walk.net_point_entry.amount, 2)
        self.assertEqual(walk.net_point_entry.earn_category, "NET_WALK")
        replay = self.client.post("/api/walks", payload, format="json")
        self.assertEqual(replay.status_code, 201)
        self.assertEqual(PointEntry.objects.filter(earn_category="NET_WALK").count(), 1)
        from checkins.services import daily_activity_points
        self.assertEqual(daily_activity_points(self.alice, walk.point_date), 10)

    def test_optional_bonus_uses_completed_whole_kilometres(self):
        for metres, points in (
            (999, 0), (1000, 2), (1499, 2), (1500, 2),
            (1999, 2), (2000, 4), (5000, 10), (6000, 10),
        ):
            with self.subTest(metres=metres):
                self.assertEqual(social_live._eligible_net_walk_points(metres), points)

    @override_settings(NET_WALK_REWARDS_ENABLED=True)
    def test_optional_bonus_accumulates_daily_distance_before_rounding(self):
        def settle(metres, offset):
            request_id = uuid4()
            started_at = self.now - timedelta(minutes=10 - offset)
            ended_at = started_at + timedelta(minutes=1)
            WalkSession.objects.create(
                owner=self.alice,
                request_id=request_id,
                state="FINISHED",
                started_at=started_at,
                ended_at=ended_at,
                heartbeat_at=ended_at,
                validation_version="cumulative-test",
            )
            walk = Walk.objects.create(
                owner=self.alice,
                request_id=request_id,
                request_fingerprint=uuid4().hex * 2,
                started_at=started_at,
                ended_at=ended_at,
                point_date=self.now.date(),
                distance_m=metres,
            )
            with patch("social.live.shared_distance", return_value=Decimal(metres)):
                social_live.link_walk_and_settle(walk)
            walk.refresh_from_db()
            return walk

        self.assertIsNone(settle(600, 0).net_point_entry_id)
        self.assertEqual(settle(400, 1).net_point_entry.amount, 2)
        self.assertIsNone(settle(499, 2).net_point_entry_id)
        self.assertIsNone(settle(1, 3).net_point_entry_id)
        self.assertEqual(settle(500, 4).net_point_entry.amount, 2)
        self.assertEqual(
            PointEntry.objects.filter(
                user=self.alice,
                earned_on=self.now.date(),
                earn_category="NET_WALK",
                type="EARN",
            ).aggregate(total=Sum("amount"))["total"],
            4,
        )

    @override_settings(NET_WALK_REWARDS_ENABLED=True)
    def test_optional_bonus_cannot_overrun_shared_daily_budget(self):
        credit_points(user=self.alice, amount=63, type="EARN", source_reference="social-cap-fixture", earn_category="CHECK_IN", earned_on=self.now.date(), rules_version="test-only")
        walk, payload = self.completed_pair_walk()
        self.assertEqual(walk.points_awarded, 8)
        self.assertEqual(walk.net_point_entry.amount, 1)
        from checkins.services import daily_activity_points
        self.assertEqual(daily_activity_points(self.alice, walk.point_date), 72)

    def test_enabling_bonus_midday_does_not_backfill_previous_disabled_distance(self):
        old_walk, _ = self.completed_pair_walk()
        self.assertIsNone(old_walk.net_point_entry_id)
        self.as_user(self.bob)
        bob_session = self.client.get("/api/social/walk-sessions/current").data
        self.post(f"walk-sessions/{bob_session['id']}/state", {"state": "FINISHED"})
        self.now += timedelta(seconds=2)
        with override_settings(NET_WALK_REWARDS_ENABLED=True):
            new_walk, _ = self.completed_pair_walk()
        self.assertEqual(new_walk.net_point_entry.amount, 2)
        self.assertEqual(new_walk.validation_summary["net_bonus_policy"], "enabled-v1")
        old_walk.refresh_from_db()
        self.assertEqual(old_walk.validation_summary["net_bonus_policy"], "distance-only-v1")

    def test_retention_purges_raw_location_evidence(self):
        session = self.start(self.alice)
        self.assertEqual(self.location(self.alice, session).status_code, 200)
        self.now += timedelta(minutes=16)
        self.assertEqual(purge_expired_presence(), 1)
        self.assertFalse(LocationSample.objects.exists())
        self.assertIsNone(WalkSession.objects.get(pk=session["id"]).last_latitude)

    def test_invitation_database_rejects_inverted_timestamps(self):
        now = timezone.now()
        sessions = [
            WalkSession.objects.create(
                owner=owner,
                request_id=uuid4(),
                state="RECORDING",
                started_at=now - timedelta(minutes=5),
                heartbeat_at=now,
                validation_version="chronology-test",
            )
            for owner in (self.alice, self.bob)
        ]
        common = {
            "sender": self.alice,
            "recipient": self.bob,
            "sender_session": sessions[0],
            "recipient_session": sessions[1],
        }
        invalid = (
            {"status": "PENDING", "expires_at": now - timedelta(seconds=1)},
            {
                "status": "ACTIVE",
                "expires_at": now + timedelta(minutes=5),
                "accepted_at": now - timedelta(days=1),
            },
            {
                "status": "ENDED",
                "expires_at": now + timedelta(minutes=5),
                "accepted_at": now + timedelta(minutes=2),
                "ended_at": now + timedelta(minutes=1),
            },
            {
                "status": "CANCELLED",
                "expires_at": now + timedelta(minutes=5),
                "ended_at": now - timedelta(days=1),
            },
        )
        for values in invalid:
            with self.subTest(values=values), self.assertRaises(IntegrityError), transaction.atomic():
                NetWalkInvitation.objects.create(**common, **values)

        instant = now + timedelta(minutes=1)
        valid = NetWalkInvitation.objects.create(
            **common,
            status="ENDED",
            expires_at=instant + timedelta(minutes=1),
            accepted_at=instant,
            ended_at=instant,
        )
        self.assertEqual(valid.accepted_at, valid.ended_at)
