from datetime import timedelta

from django.contrib.auth import get_user_model
from django.test import TestCase
from django.urls import reverse
from django.utils import timezone
from rest_framework import status
from rest_framework.test import APITestCase

from rewards.models import PointEntry, Redemption, Reward
from rewards.services import credit_points

User = get_user_model()


class RewardsApiTestCase(APITestCase):
    wallet_url = "/api/wallet/"
    ledger_url = "/api/wallet/ledger"
    rewards_url = "/api/redemptions/rewards"
    redemptions_url = "/api/redemptions/"

    def setUp(self):
        self.owner = User.objects.create_user(
            email="owner@example.com", password="StrongPass123!", display_name="Dog Owner"
        )
        self.other_owner = User.objects.create_user(
            email="other@example.com", password="StrongPass123!", display_name="Other Owner"
        )
        self.cafe_user = User.objects.create_user(
            email="cafe@example.com",
            password="StrongPass123!",
            display_name="Corner Café",
            role=User.Role.CAFE,
        )
        self.client.force_authenticate(self.owner)

        self.reward = Reward.objects.create(
            cafe_user=self.cafe_user, name="Small Coffee", point_cost=40
        )
        self.unavailable_reward = Reward.objects.create(
            cafe_user=self.cafe_user,
            name="Retired Reward",
            point_cost=10,
            is_available=False,
        )

    def grant(self, user, amount, days_until_expiry=300):
        return credit_points(
            user=user,
            amount=amount,
            expires_at=timezone.now() + timedelta(days=days_until_expiry),
        )

    def create_redemption(self, reward_id=None):
        return self.client.post(
            self.redemptions_url,
            {"reward_id": reward_id or self.reward.id},
            format="json",
        )


class WalletApiTests(RewardsApiTestCase):
    def test_balance_reflects_admin_granted_points(self):
        self.grant(self.owner, 100)

        response = self.client.get(self.wallet_url)

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(response.data["balance"], 100)

    def test_balance_ignores_expired_grants(self):
        self.grant(self.owner, 100, days_until_expiry=-1)

        response = self.client.get(self.wallet_url)

        self.assertEqual(response.data["balance"], 0)

    def test_ledger_lists_credit_and_debit_entries(self):
        self.grant(self.owner, 100)
        self.create_redemption()

        response = self.client.get(self.ledger_url)

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        amounts = sorted(entry["amount"] for entry in response.data)
        self.assertEqual(amounts, [-40, 100])

    def test_cafe_account_cannot_access_the_wallet(self):
        self.client.force_authenticate(self.cafe_user)

        response = self.client.get(self.wallet_url)

        self.assertEqual(response.status_code, status.HTTP_403_FORBIDDEN)


class RewardListApiTests(RewardsApiTestCase):
    def test_only_available_rewards_are_listed(self):
        response = self.client.get(self.rewards_url)

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        names = {reward["name"] for reward in response.data}
        self.assertEqual(names, {"Small Coffee"})


class RedemptionApiTests(RewardsApiTestCase):
    def test_redeeming_a_reward_deducts_points_and_issues_a_reference_number(self):
        self.grant(self.owner, 100)

        response = self.create_redemption()

        self.assertEqual(response.status_code, status.HTTP_201_CREATED)
        self.assertEqual(response.data["status"], Redemption.Status.PENDING)
        self.assertEqual(response.data["point_cost_snapshot"], 40)
        self.assertTrue(response.data["reference_number"])

        redemption = Redemption.objects.get(id=response.data["id"])
        self.assertEqual(redemption.owner_user, self.owner)
        self.assertEqual(self.client.get(self.wallet_url).data["balance"], 60)

    def test_redeeming_with_insufficient_points_is_rejected_and_nothing_is_deducted(self):
        self.grant(self.owner, 10)

        response = self.create_redemption()

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertEqual(response.data["code"], "INSUFFICIENT_POINTS")
        self.assertEqual(Redemption.objects.count(), 0)
        self.assertEqual(self.client.get(self.wallet_url).data["balance"], 10)

    def test_spend_draws_from_the_soonest_expiring_grant_first(self):
        self.grant(self.owner, 30, days_until_expiry=5)
        self.grant(self.owner, 30, days_until_expiry=300)

        self.create_redemption()

        soon_expiring = PointEntry.objects.get(amount=30, expires_at__lt=timezone.now() + timedelta(days=10))
        later_expiring = PointEntry.objects.get(amount=30, expires_at__gt=timezone.now() + timedelta(days=10))
        self.assertEqual(soon_expiring.remaining_points, 0)
        self.assertEqual(later_expiring.remaining_points, 20)

    def test_an_unavailable_reward_is_rejected(self):
        self.grant(self.owner, 100)

        response = self.create_redemption(reward_id=self.unavailable_reward.id)

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertEqual(Redemption.objects.count(), 0)

    def test_owner_can_collect_a_pending_redemption(self):
        self.grant(self.owner, 100)
        redemption_id = self.create_redemption().data["id"]

        response = self.client.post(f"{self.redemptions_url}{redemption_id}/collect")

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(response.data["status"], Redemption.Status.COLLECTED)
        self.assertIsNotNone(Redemption.objects.get(id=redemption_id).collected_at)

    def test_collecting_an_already_collected_redemption_is_idempotent(self):
        self.grant(self.owner, 100)
        redemption_id = self.create_redemption().data["id"]
        self.client.post(f"{self.redemptions_url}{redemption_id}/collect")

        response = self.client.post(f"{self.redemptions_url}{redemption_id}/collect")

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(response.data["status"], Redemption.Status.COLLECTED)

    def test_owner_cannot_collect_another_owners_redemption(self):
        self.grant(self.owner, 100)
        redemption_id = self.create_redemption().data["id"]
        self.client.force_authenticate(self.other_owner)

        response = self.client.post(f"{self.redemptions_url}{redemption_id}/collect")

        self.assertEqual(response.status_code, status.HTTP_404_NOT_FOUND)
        self.assertEqual(
            Redemption.objects.get(id=redemption_id).status, Redemption.Status.PENDING
        )

    def test_history_only_returns_the_signed_in_owners_redemptions(self):
        self.grant(self.owner, 100)
        self.create_redemption()
        self.grant(self.other_owner, 100)
        self.client.force_authenticate(self.other_owner)
        self.create_redemption()

        self.client.force_authenticate(self.owner)
        response = self.client.get(self.redemptions_url)

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(len(response.data), 1)

    def test_cafe_account_cannot_redeem_a_reward(self):
        self.client.force_authenticate(self.cafe_user)

        response = self.create_redemption()

        self.assertEqual(response.status_code, status.HTTP_403_FORBIDDEN)

    def test_collecting_an_expired_redemption_is_rejected_and_refunds_the_points(self):
        self.grant(self.owner, 100)
        redemption_id = self.create_redemption().data["id"]
        Redemption.objects.filter(id=redemption_id).update(
            expires_at=timezone.now() - timedelta(minutes=1)
        )

        response = self.client.post(f"{self.redemptions_url}{redemption_id}/collect")

        self.assertEqual(response.status_code, status.HTTP_409_CONFLICT)
        redemption = Redemption.objects.get(id=redemption_id)
        self.assertEqual(redemption.status, Redemption.Status.EXPIRED)
        self.assertIsNone(redemption.collected_at)
        self.assertEqual(self.client.get(self.wallet_url).data["balance"], 100)

    def test_an_expired_redemption_is_refunded_exactly_once(self):
        self.grant(self.owner, 100)
        redemption_id = self.create_redemption().data["id"]
        Redemption.objects.filter(id=redemption_id).update(
            expires_at=timezone.now() - timedelta(minutes=1)
        )

        # Two separate reads that each trigger the lazy-expiry sweep.
        first_balance = self.client.get(self.wallet_url).data["balance"]
        second_balance = self.client.get(self.wallet_url).data["balance"]

        self.assertEqual(first_balance, 100)
        self.assertEqual(second_balance, 100)
        refund_entries = PointEntry.objects.filter(type=PointEntry.Type.REFUND, user=self.owner)
        self.assertEqual(refund_entries.count(), 1)

    def test_history_reflects_expiry_without_a_collect_attempt(self):
        self.grant(self.owner, 100)
        redemption_id = self.create_redemption().data["id"]
        Redemption.objects.filter(id=redemption_id).update(
            expires_at=timezone.now() - timedelta(minutes=1)
        )

        response = self.client.get(self.redemptions_url)

        self.assertEqual(response.data[0]["status"], Redemption.Status.EXPIRED)


class PointEntryAdminTests(TestCase):
    """Covers the PR review requirement that admin-created point entries
    can only be positive grants — a negative entry created by hand would
    validate against PointEntry.clean() but would not actually decrement
    any credit entry's remaining_points, silently desyncing the balance.
    """

    def setUp(self):
        self.admin_user = User.objects.create_superuser(
            email="admin@example.com", password="StrongPass123!", display_name="Admin"
        )
        self.owner = User.objects.create_user(
            email="owner@example.com", password="StrongPass123!", display_name="Dog Owner"
        )
        self.client.force_login(self.admin_user)

    def add_url(self):
        return reverse("admin:rewards_pointentry_add")

    def test_admin_cannot_create_a_negative_point_entry(self):
        response = self.client.post(
            self.add_url(),
            {
                "user": self.owner.id,
                "amount": -20,
                "remaining_points": 0,
                "type": PointEntry.Type.SPEND,
                "expires_at_0": "",
                "expires_at_1": "",
            },
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK)  # form re-rendered with errors
        self.assertEqual(PointEntry.objects.count(), 0)

    def test_admin_can_create_a_positive_grant(self):
        expires = timezone.now() + timedelta(days=300)
        response = self.client.post(
            self.add_url(),
            {
                "user": self.owner.id,
                "amount": 50,
                "remaining_points": 0,
                "type": PointEntry.Type.ADMIN,
                "expires_at_0": expires.strftime("%Y-%m-%d"),
                "expires_at_1": expires.strftime("%H:%M:%S"),
            },
        )

        self.assertEqual(response.status_code, status.HTTP_302_FOUND)  # redirected on success
        entry = PointEntry.objects.get(user=self.owner)
        self.assertEqual(entry.amount, 50)
        self.assertEqual(entry.remaining_points, 50)
