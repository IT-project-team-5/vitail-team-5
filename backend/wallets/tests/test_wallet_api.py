from datetime import timedelta

from django.contrib.auth import get_user_model
from django.utils import timezone
from rest_framework import status
from rest_framework.test import APITestCase

from wallets.models import PointLedger, PointLot
from wallets.services import InsufficientPointsError, get_balance, spend_points

User = get_user_model()


class WalletBalanceTests(APITestCase):
    def setUp(self):
        self.owner = User.objects.create_user(
            email="owner@example.com", password="StrongPass123!", display_name="Dog Owner"
        )
        self.client.force_authenticate(self.owner)

    def grant(self, amount, days_until_expiry=300, remaining=None):
        return PointLot.objects.create(
            owner=self.owner,
            source=PointLot.Source.ADMIN_GRANT,
            amount_earned=amount,
            amount_remaining=amount if remaining is None else remaining,
            expires_at=timezone.now() + timedelta(days=days_until_expiry),
        )

    def test_balance_sums_unexpired_lots(self):
        self.grant(40)
        self.grant(20)

        response = self.client.get("/api/wallet/")

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(response.data["balance"], 60)

    def test_balance_excludes_expired_lots(self):
        self.grant(40)
        self.grant(100, days_until_expiry=-1)

        self.assertEqual(get_balance(self.owner), 40)

    def test_spend_points_consumes_oldest_expiring_lot_first(self):
        soon_expiring = self.grant(30, days_until_expiry=5)
        later_expiring = self.grant(30, days_until_expiry=300)

        spend_points(owner=self.owner, amount=40, entry_type=PointLedger.EntryType.ADMIN_GRANT)

        soon_expiring.refresh_from_db()
        later_expiring.refresh_from_db()
        self.assertEqual(soon_expiring.amount_remaining, 0)
        self.assertEqual(later_expiring.amount_remaining, 20)

    def test_spend_points_raises_when_balance_is_short(self):
        self.grant(10)

        with self.assertRaises(InsufficientPointsError):
            spend_points(owner=self.owner, amount=20, entry_type=PointLedger.EntryType.ADMIN_GRANT)

    def test_ledger_lists_only_the_signed_in_owners_entries(self):
        other_owner = User.objects.create_user(
            email="other@example.com", password="StrongPass123!", display_name="Other Owner"
        )
        PointLedger.objects.create(owner=self.owner, amount=10, entry_type=PointLedger.EntryType.ADMIN_GRANT)
        PointLedger.objects.create(owner=other_owner, amount=10, entry_type=PointLedger.EntryType.ADMIN_GRANT)

        response = self.client.get("/api/wallet/ledger")

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(len(response.data), 1)
        self.assertEqual(response.data[0]["amount"], 10)
