from concurrent.futures import ThreadPoolExecutor
from datetime import date, timedelta
from threading import Barrier
from unittest import skipUnless
from uuid import uuid4

from django.contrib.auth import get_user_model
from django.db import close_old_connections, connection
from django.test import TestCase, TransactionTestCase
from rest_framework.test import APIClient

from dogs.models import Dog, DogGoalTarget
from dogs.tests.test_goals import GoalFixture
from evidence.models import DocumentSubmission
from quests.models import QuestAward, QuestDefinition
from rewards.models import PointEntry, Reward
from rewards.services import get_balance, credit_points
from venues.models import Venue


class OwnerJourneyTests(GoalFixture, TestCase):
    def setUp(self):
        super().setUp()
        self.client = APIClient()
        self.client.force_authenticate(self.owner)

    def payload(self, **changes):
        return {"request_id": str(uuid4()), "name": "Pip", "breed_id": self.dog.breed_id,
                "date_of_birth": "2024-01-01", "weight_kg": "12.50", **changes}

    def collect(self, dog=None, day=None, **extra):
        return self.client.post(f"/api/quests/goals/{(dog or self.dog).pk}/collect",
            {"local_date": str(day or self.day), **extra}, format="json")

    def register(self, dog):
        response = self.client.post("/api/quests/documents", {"request_id": str(uuid4()), "dog_id": dog.pk,
            "kind": "MICROCHIP_REGISTRATION", "registration_number": "012345678901234"}, format="json")
        self.assertEqual(response.status_code, 201, response.data)
        self.assertEqual(response.data["awarded_points"], 0)
        return response

    def second_dog(self):
        response = self.client.post("/api/dogs", self.payload(), format="json")
        self.assertEqual(response.status_code, 201, response.data)
        return Dog.objects.get(pk=response.data["id"])

    def test_dog_retry_at_limit_and_conflict_preserve_two_profiles(self):
        payload = self.payload()
        first = self.client.post("/api/dogs", payload, format="json")
        retry = self.client.post("/api/dogs", payload, format="json")
        self.assertEqual(first.data["id"], retry.data["id"])
        self.assertEqual(self.client.post("/api/dogs", self.payload(), format="json").status_code, 400)
        self.assertEqual(self.client.post("/api/dogs", {**payload, "name": "Changed"}, format="json").status_code, 400)
        self.assertEqual(Dog.objects.filter(owner=self.owner).count(), 2)

    def test_weight_required_positive_and_size_reuses_breed(self):
        for weight in (None, "", "0", "-1", "NaN", "1.234", "abc"):
            self.assertEqual(self.client.post("/api/dogs", self.payload(weight_kg=weight), format="json").status_code, 400)
        missing = self.payload(); missing.pop("weight_kg")
        self.assertEqual(self.client.post("/api/dogs", missing, format="json").status_code, 400)
        dog = self.second_dog()
        self.assertEqual(dog.size, self.dog.breed.default_size)
        self.assertEqual(self.client.patch(f"/api/dogs/{self.dog.pk}", {"name": "Legacy edited"}, format="json").status_code, 200)

    def test_goal_request_replays_original_after_profile_change_and_midnight(self):
        self.dog.weight_kg = 12
        self.dog.date_of_birth = date(2024, 1, 1)
        self.dog.save()
        payload = {"request_id": str(uuid4()), "effective_from": str(self.day), "owner_adjustment": "1.25"}
        url = f"/api/dogs/{self.dog.pk}/goal"
        first = self.client.post(url, payload, format="json")
        self.assertEqual(first.status_code, 201, first.data)
        self.now += timedelta(days=1)
        Dog.objects.filter(pk=self.dog.pk).update(weight_kg=20)
        retry = self.client.post(url, payload, format="json")
        self.assertEqual(retry.status_code, 201, retry.data)
        self.assertEqual(retry.data["saved_target"], first.data["saved_target"])
        self.assertEqual(DogGoalTarget.objects.count(), 1)
        self.assertEqual(self.client.post(url, {**payload, "owner_adjustment": "1.50"}, format="json").status_code, 400)

    def test_two_dogs_complete_and_collect_independently(self):
        other = self.second_dog()
        self.configure(60); self.configure(60, dog=other)
        self.walk(dogs=[self.dog, other])
        before = get_balance(self.owner)
        dashboard = self.client.get("/api/quests").data
        self.assertEqual(len([task for task in dashboard["tasks"] if task["kind"] == "DAILY_GOAL" and task["status"] == "READY"]), 2)
        self.assertFalse(PointEntry.objects.filter(earn_category="DAILY_GOAL").exists())
        for index, dog in enumerate((self.dog, other), 1):
            response = self.collect(dog)
            self.assertEqual(response.status_code, 201, response.data)
            self.assertEqual(response.data["award"]["points"], 20)
            self.assertEqual(response.data["balance"], before + index * 20)
            self.assertEqual(self.collect(dog).status_code, 200)
            self.assertEqual(get_balance(self.owner), before + index * 20)
        self.assertEqual(PointEntry.objects.filter(earn_category="DAILY_GOAL").count(), 2)
        self.assertEqual(QuestAward.objects.filter(kind="DAILY_GOAL").count(), 2)

    def test_unselected_dog_incomplete_and_client_award_rejected(self):
        other = self.second_dog()
        self.configure(60); self.configure(60, dog=other)
        self.walk()
        self.assertEqual(self.collect(other).status_code, 400)
        self.assertEqual(self.collect(points=9999).status_code, 400)
        self.assertEqual(self.collect(day=self.day - timedelta(days=1)).status_code, 400)
        self.assertEqual(self.collect().status_code, 201)

    def test_shared_cap_full_award_or_zero(self):
        other = self.second_dog()
        self.configure(60); self.configure(60, dog=other)
        self.walk(dogs=[self.dog, other])
        self.credit(40, "WALK"); self.credit(12, "CHECK_IN")
        response = self.collect()
        self.assertEqual(response.status_code, 201, response.data)
        self.assertEqual(response.data["balance"], 72)
        blocked = self.collect(other)
        self.assertEqual(blocked.status_code, 400)
        self.assertIn("full goal reward", str(blocked.data))
        self.assertEqual(get_balance(self.owner), 72)
        self.assertEqual(PointEntry.objects.filter(earn_category="DAILY_GOAL").count(), 1)

    def test_insufficient_allowance_does_not_issue_partial_points(self):
        self.configure(60); self.walk(); self.credit(53, "WALK")
        self.assertEqual(self.collect().status_code, 400)
        self.assertEqual(get_balance(self.owner), 53)
        self.assertFalse(QuestAward.objects.filter(kind="DAILY_GOAL").exists())
        tasks = self.client.get("/api/quests").data["tasks"]
        self.assertIn("full 20 points", next(t["detail"] for t in tasks if t["kind"] == "DAILY_GOAL"))

    def test_other_owner_and_disabled_quest_cannot_collect(self):
        self.configure(60); self.walk()
        other = get_user_model().objects.create_user(email="other-journey@example.com", display_name="Other")
        self.client.force_authenticate(other)
        self.assertEqual(self.collect().status_code, 400)
        self.client.force_authenticate(self.owner)
        QuestDefinition.objects.filter(code="DAILY_GOAL").update(is_enabled=False)
        self.assertEqual(self.collect().status_code, 400)

    def test_collection_receipt_replay_after_midnight_does_not_reaward(self):
        self.configure(60); self.walk()
        first = self.collect()
        self.now += timedelta(days=1)
        replay = self.collect(day=self.day)
        self.assertEqual(replay.status_code, 200)
        self.assertEqual(replay.data["award"], first.data["award"])
        self.assertEqual(PointEntry.objects.filter(earn_category="DAILY_GOAL").count(), 1)

    def test_microchip_gate_and_purchase_without_document_collection(self):
        other = self.second_dog()
        cafe = get_user_model().objects.create_user(email="journey-cafe@example.com", display_name="Cafe", role="CAFE")
        venue = Venue.objects.create(name="Journey cafe", kind="CAFE", manager_user=cafe, is_partner=True)
        reward = Reward.objects.create(venue=venue, name="Treat", point_cost=40)
        credit_points(user=self.owner, amount=100)
        request = {"reward_id": reward.pk, "request_id": str(uuid4())}
        for expected in (2, 1):
            response = self.client.post("/api/redemptions", request, format="json")
            self.assertEqual(response.status_code, 403, response.data)
            self.assertEqual(len(response.data["incomplete_dogs"]), expected)
            self.assertEqual(get_balance(self.owner), 100)
            self.register(self.dog if expected == 2 else other)
        self.assertFalse(PointEntry.objects.filter(earn_category="DOCUMENT").exists())
        response = self.client.post("/api/redemptions", request, format="json")
        self.assertEqual(response.status_code, 201, response.data)
        self.assertEqual(get_balance(self.owner), 60)
        self.assertEqual(self.client.post("/api/redemptions", request, format="json").data["id"], response.data["id"])
        self.assertEqual(get_balance(self.owner), 60)
        DocumentSubmission.objects.filter(dog=other).update(audit_status="REJECTED")
        self.assertFalse(self.client.get("/api/redemptions/eligibility").data["eligible"])
        self.assertEqual(self.client.post("/api/redemptions", request, format="json").data["id"], response.data["id"])
        self.assertEqual(self.client.post("/api/redemptions", {**request, "request_id": str(uuid4())}, format="json").status_code, 403)
        self.assertEqual(get_balance(self.owner), 60)

    def test_one_dog_registration_unlocks_without_collecting_points(self):
        gate = self.client.get("/api/redemptions/eligibility").data
        self.assertFalse(gate["eligible"])
        self.assertEqual(gate["incomplete_dogs"], [{"id": self.dog.pk, "name": self.dog.name}])
        self.register(self.dog)
        self.assertEqual(self.client.get("/api/redemptions/eligibility").data,
                         {"eligible": True, "incomplete_dogs": []})
        self.assertFalse(PointEntry.objects.exists())

    def test_council_search_and_arbitrary_text_rejected(self):
        names = self.client.get("/api/councils", {"q": "Melbourne"})
        self.assertIn("Melbourne City Council", [row["name"] for row in names.data])
        from evidence.councils import council_data
        postcodes = [code for row in council_data() for code in row["postcodes"]]
        shared = next(code for code in postcodes if postcodes.count(code) > 1)
        self.assertGreater(len(self.client.get("/api/councils", {"q": shared}).data), 1)
        self.assertEqual(self.client.get("/api/councils", {"q": "123"}).status_code, 400)
        self.assertEqual(self.client.get("/api/councils", {"q": "No such council"}).data, [])
        response = self.client.post("/api/quests/documents", {"request_id": str(uuid4()), "dog_id": self.dog.pk,
            "kind": "COUNCIL_REGISTRATION", "registration_number": "A123", "council_name": "Anything",
            "valid_to": "2027-12-31"}, format="json")
        self.assertEqual(response.status_code, 400)

    def test_new_onboarding_is_persistent_and_completion_idempotent(self):
        response = self.client.post("/api/auth/register", {"email": "new-journey@example.com",
            "password": "VeryStrong123!", "display_name": "New owner"}, format="json")
        self.assertEqual(response.status_code, 201, response.data)
        owner = get_user_model().objects.get(pk=response.data["user"]["id"])
        self.assertFalse(owner.onboarding_complete)
        self.client.force_authenticate(owner)
        self.assertEqual(self.client.post("/api/auth/onboarding/complete").status_code, 400)
        self.assertEqual(self.client.post("/api/dogs", self.payload(), format="json").status_code, 201)
        for _ in range(2):
            self.assertTrue(self.client.post("/api/auth/onboarding/complete").data["onboarding_complete"])
        owner.refresh_from_db()
        self.assertTrue(self.client.get("/api/auth/me").data["onboarding_complete"])


@skipUnless(connection.vendor == "mysql", "Requires MySQL row locks")
class OwnerJourneyConcurrencyTests(GoalFixture, TransactionTestCase):
    def race(self, operation):
        barrier = Barrier(2)
        def run(_):
            close_old_connections()
            try:
                client = APIClient(); client.force_authenticate(self.owner)
                barrier.wait(timeout=15)
                return operation(client)
            finally:
                close_old_connections()
        with ThreadPoolExecutor(max_workers=2) as pool:
            return list(pool.map(run, range(2)))

    def test_simultaneous_creation_cannot_exceed_two(self):
        responses = self.race(lambda client: client.post("/api/dogs", {"request_id": str(uuid4()),
            "name": "Pip", "breed_id": self.dog.breed_id, "weight_kg": "8", "date_of_birth": "2024-01-01"}, format="json"))
        self.assertCountEqual([row.status_code for row in responses], [201, 400])
        self.assertEqual(Dog.objects.filter(owner=self.owner).count(), 2)

    def test_simultaneous_collection_has_one_credit(self):
        QuestDefinition.objects.get_or_create(code="DAILY_GOAL", defaults={"title": "Daily goal"})
        self.configure(60); self.walk()
        responses = self.race(lambda client: client.post(f"/api/quests/goals/{self.dog.pk}/collect",
            {"local_date": str(self.day)}, format="json"))
        self.assertCountEqual([row.status_code for row in responses], [201, 200])
        self.assertEqual(PointEntry.objects.filter(earn_category="DAILY_GOAL").count(), 1)

    def test_two_dog_collections_compete_for_shared_allowance(self):
        QuestDefinition.objects.get_or_create(code="DAILY_GOAL", defaults={"title": "Daily goal"})
        other = Dog.objects.create(owner=self.owner, name="Second", breed=self.dog.breed,
            age_months=24, size="SMALL", is_brachycephalic=False)
        self.configure(60); self.configure(60, dog=other); self.walk(dogs=[self.dog, other])
        self.credit(40, "WALK")
        barrier = Barrier(2)
        def collect(dog):
            close_old_connections()
            try:
                client = APIClient(); client.force_authenticate(self.owner)
                barrier.wait(timeout=15)
                return client.post(f"/api/quests/goals/{dog.pk}/collect", {"local_date": str(self.day)}, format="json").status_code
            finally:
                close_old_connections()
        with ThreadPoolExecutor(max_workers=2) as pool:
            results = list(pool.map(collect, [self.dog, other]))
        self.assertCountEqual(results, [201, 400])
        self.assertEqual(get_balance(self.owner), 60)
