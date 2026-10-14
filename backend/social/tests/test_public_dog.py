from datetime import date, timedelta
from uuid import uuid4

from django.contrib.auth import get_user_model
from django.utils import timezone
from rest_framework.test import APITestCase

from dogs.models import Breed, Dog
from social import presentation
from social.models import Friendship
from walks.models import WalkSession


User = get_user_model()


class PublicDogTests(APITestCase):
    @classmethod
    def setUpTestData(cls):
        cls.alice = User.objects.create_user(email="public-dog-alice@example.com", display_name="Alice Walker")
        cls.bob = User.objects.create_user(email="public-dog-bob@example.com", display_name="Bob Walker")
        cls.breed = Breed.objects.create(name="Public dog test breed", energy_level="MODERATE", default_size="SMALL")
        cls.dog = Dog.objects.create(
            owner=cls.alice, name="Milo", breed=cls.breed, age_months=999,
            date_of_birth=date(2023, 2, 1), size="SMALL", weight_kg="8.50",
            is_brachycephalic=False, microchip_number="private-microchip",
            photo="https://example.com/private-dog-photo.png",
        )
        cls.other_dog = Dog.objects.create(
            owner=cls.alice, name="Ruby", breed=cls.breed, age_months=18,
            size="MEDIUM", is_brachycephalic=False,
        )
        cls.bobs_dog = Dog.objects.create(
            owner=cls.bob, name="Buddy", breed=cls.breed, age_months=30,
            size="LARGE", is_brachycephalic=False,
        )

    def setUp(self):
        self.client.force_authenticate(self.alice)

    def preferences(self, **values):
        response = self.client.patch("/api/social/preferences", values, format="json")
        self.assertEqual(response.status_code, 200, response.data)
        return response.data

    def search_for(self, user):
        response = self.client.get("/api/social/users", {"q": user.public_id})
        self.assertEqual(response.status_code, 200, response.data)
        return response.data

    def expected_summary(self, dog):
        return {
            "name": dog.name, "breed_name": dog.breed.name,
            "age_months": dog.current_age_months, "size": dog.size,
        }

    def test_existing_private_dogs_are_hidden_until_explicit_selection(self):
        me = self.client.get("/api/social/overview").data["me"]
        self.assertIsNone(me["dog"])
        self.assertIsNone(me["public_dog_id"])
        self.alice.refresh_from_db()
        self.assertIsNone(self.alice.public_dog_id)
        self.client.force_authenticate(self.bob)
        profile = self.search_for(self.alice)[0]
        self.assertIsNone(profile["dog"])
        self.assertNotIn("public_dog_id", profile)

    def test_selection_publishes_only_four_approved_fields_and_derived_age(self):
        saved = self.preferences(public_dog_id=self.dog.pk)
        self.assertEqual(saved["public_dog_id"], self.dog.pk)
        self.assertEqual(saved["dog"], self.expected_summary(self.dog))
        self.assertEqual(set(saved["dog"]), {"name", "breed_name", "age_months", "size"})
        self.assertNotEqual(saved["dog"]["age_months"], self.dog.age_months)
        self.assertEqual(saved["location_visibility"], "OFF")
        self.assertFalse(saved["net_matching_enabled"])
        self.client.force_authenticate(self.bob)
        profile = self.search_for(self.alice)[0]
        self.assertEqual(profile["dog"], self.expected_summary(self.dog))
        self.assertNotIn("public_dog_id", profile)
        self.assertNotIn("private-microchip", str(profile))
        self.assertNotIn("private-dog-photo", str(profile))
        self.assertNotIn("2023-02-01", str(profile))
        self.assertNotIn("8.50", str(profile))

    def test_absent_selection_preserves_it_null_clears_and_replacement_is_one_dog(self):
        self.preferences(public_dog_id=self.dog.pk, virtual_avatar_key="dog", bandana_color="yellow")
        saved = self.preferences(bandana_color="red")
        self.assertEqual(saved["public_dog_id"], self.dog.pk)
        self.assertEqual(saved["dog"]["name"], "Milo")
        replaced = self.preferences(public_dog_id=self.other_dog.pk)
        self.assertEqual(replaced["dog"], self.expected_summary(self.other_dog))
        self.assertEqual(replaced["public_dog_id"], self.other_dog.pk)
        cleared = self.preferences(public_dog_id=None)
        self.assertIsNone(cleared["dog"])
        self.assertIsNone(cleared["public_dog_id"])
        self.assertEqual(cleared["avatar_key"], "dog")
        self.assertEqual(cleared["bandana_color"], "red")
        self.alice.refresh_from_db()
        self.assertIsNone(self.alice.public_dog_id)

    def test_foreign_selection_rejects_entire_preferences_patch_atomically(self):
        before = self.preferences(
            public_dog_id=self.dog.pk, virtual_avatar_key="paw",
            bandana_color="yellow", location_visibility="FRIENDS", net_matching_enabled=True,
        )
        response = self.client.patch("/api/social/preferences", {
            "public_dog_id": self.bobs_dog.pk, "virtual_avatar_key": "coffee",
            "bandana_color": "green", "location_visibility": "OFF", "net_matching_enabled": False,
        }, format="json")
        self.assertEqual(response.status_code, 400, response.data)
        self.assertIn("public_dog_id", response.data)
        self.assertEqual(self.client.get("/api/social/overview").data["me"], before)

    def test_unknown_malformed_or_archived_selection_is_rejected(self):
        Dog.objects.filter(pk=self.other_dog.pk).update(archived_at=timezone.now())
        for value in (0, -1, "invalid", True, 9_223_372_036_854_775_808, 999999, self.other_dog.pk):
            with self.subTest(value=value):
                response = self.client.patch("/api/social/preferences", {"public_dog_id": value}, format="json")
                self.assertEqual(response.status_code, 400, response.data)
                self.assertIn("public_dog_id", response.data)
        self.alice.refresh_from_db()
        self.assertIsNone(self.alice.public_dog_id)

    def test_ownership_transfer_suppresses_summary_even_for_cached_owner(self):
        self.preferences(public_dog_id=self.dog.pk)
        self.alice.refresh_from_db()
        cached_owner = self.alice
        self.dog.owner = self.bob
        self.dog.save(update_fields=("owner",))
        self.assertIsNone(presentation.profile(cached_owner)["dog"])
        self.assertIsNone(presentation.profile(cached_owner, preferences=True)["public_dog_id"])
        self.assertIsNone(self.client.get("/api/social/overview").data["me"]["dog"])
        rejected = self.client.patch("/api/social/preferences", {"public_dog_id": self.dog.pk}, format="json")
        self.assertEqual(rejected.status_code, 400)
        self.client.force_authenticate(self.bob)
        self.assertIsNone(self.search_for(self.alice)[0]["dog"])
        # Receiving ownership never publishes a dog on the recipient's behalf.
        self.assertIsNone(self.client.get("/api/social/overview").data["me"]["dog"])

    def test_archival_suppresses_summary_and_owner_selection_id(self):
        self.preferences(public_dog_id=self.dog.pk)
        self.alice.refresh_from_db()
        Dog.objects.filter(pk=self.dog.pk).update(archived_at=timezone.now())
        self.assertIsNone(presentation.profile(self.alice)["dog"])
        me = self.client.get("/api/social/overview").data["me"]
        self.assertIsNone(me["dog"])
        self.assertIsNone(me["public_dog_id"])
        self.client.force_authenticate(self.bob)
        self.assertIsNone(self.search_for(self.alice)[0]["dog"])

    def test_deletion_clears_fk_and_suppresses_cached_summary(self):
        self.preferences(public_dog_id=self.dog.pk)
        self.alice.refresh_from_db()
        self.dog.delete()
        self.assertIsNone(presentation.profile(self.alice)["dog"])
        self.alice.refresh_from_db()
        self.assertIsNone(self.alice.public_dog_id)
        me = self.client.get("/api/social/overview").data["me"]
        self.assertIsNone(me["dog"])
        self.assertIsNone(me["public_dog_id"])

    def test_public_summary_updates_from_current_dog_profile(self):
        self.preferences(public_dog_id=self.dog.pk)
        Dog.objects.filter(pk=self.dog.pk).update(name="Milo Junior", size="MEDIUM")
        self.client.force_authenticate(self.bob)
        summary = self.search_for(self.alice)[0]["dog"]
        self.assertEqual(summary["name"], "Milo Junior")
        self.assertEqual(summary["size"], "MEDIUM")

    def test_friend_requests_and_map_use_summary_under_existing_visibility_gates(self):
        self.preferences(public_dog_id=self.dog.pk)
        request = self.client.post("/api/social/friend-requests", {"public_id": self.bob.public_id}, format="json")
        self.assertEqual(request.status_code, 201, request.data)
        self.client.force_authenticate(self.bob)
        incoming = self.client.get("/api/social/overview").data["incoming_requests"][0]
        self.assertEqual(incoming["user"]["dog"], self.expected_summary(self.dog))
        self.assertNotIn("public_dog_id", incoming["user"])
        response = self.client.post(f"/api/social/friend-requests/{request.data['id']}/respond", {"accept": True}, format="json")
        self.assertEqual(response.status_code, 200, response.data)
        self.assertEqual(Friendship.objects.get(pk=request.data["id"]).status, "ACCEPTED")

        now = timezone.now()
        session = WalkSession.objects.create(
            owner=self.alice, request_id=uuid4(), state="RECORDING",
            started_at=now - timedelta(seconds=1), heartbeat_at=now,
            last_latitude=-37.8, last_longitude=144.9, last_accuracy_m=5,
            location_recorded_at=now, location_expires_at=now + timedelta(seconds=30),
            validation_version="test-only",
        )
        User.objects.filter(pk=self.alice.pk).update(active_walk_session=session)
        self.assertEqual(self.client.get("/api/social/map").data["friends"], [])
        User.objects.filter(pk=self.alice.pk).update(location_visibility="FRIENDS")
        peer = self.client.get("/api/social/map").data["friends"][0]
        self.assertEqual(peer["user"]["dog"], self.expected_summary(self.dog))
        self.assertNotIn("public_dog_id", peer["user"])
        blocked = self.client.post("/api/social/blocks", {"public_id": self.alice.public_id}, format="json")
        self.assertEqual(blocked.status_code, 200, blocked.data)
        self.assertEqual(self.client.get("/api/social/map").data["friends"], [])
        self.assertEqual(self.search_for(self.alice), [])

    def test_inactive_or_deleted_owner_has_no_discoverable_profile(self):
        self.preferences(public_dog_id=self.dog.pk)
        self.client.force_authenticate(self.bob)
        User.objects.filter(pk=self.alice.pk).update(is_active=False)
        self.assertEqual(self.search_for(self.alice), [])
        User.objects.filter(pk=self.alice.pk).update(is_active=True, deleted_at=timezone.now())
        self.assertEqual(self.search_for(self.alice), [])
