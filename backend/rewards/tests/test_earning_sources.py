from datetime import date

from django.contrib.auth import get_user_model
from django.db import IntegrityError, transaction
from django.test import TestCase

from rewards.models import PointEntry
from rewards.services import IdempotencyConflictError, credit_points, get_balance


class EarningSourceTests(TestCase):
    def setUp(self):
        self.owner = get_user_model().objects.create_user(email="earning-source@example.com", display_name="Walker")
        self.args = dict(user=self.owner, amount=8, type="EARN", source_reference="walk:source-test",
            earn_category="WALK", earned_on=date(2026, 9, 25), rules_version="test-v1")

    def test_credit_replay_checks_rules_without_adding_points_twice(self):
        original = credit_points(**self.args)
        self.assertEqual(credit_points(**self.args).pk, original.pk)
        self.assertEqual(original.earn_category, "WALK")
        self.assertEqual(get_balance(self.owner), 8)
        for field, value in (("earn_category", "CHECK_IN"), ("earned_on", date(2026, 9, 26)), ("rules_version", "test-v2")):
            with self.subTest(field=field), self.assertRaises(IdempotencyConflictError):
                credit_points(**{**self.args, field: value})
        self.assertEqual(PointEntry.objects.count(), 1)

    def test_non_earn_or_incomplete_metadata_is_rejected(self):
        for change in ({"type": "REFUND"}, {"earn_category": None}, {"earned_on": None}, {"rules_version": ""}):
            with self.subTest(change=change), self.assertRaises(ValueError):
                credit_points(**{**self.args, **change})
        self.assertFalse(PointEntry.objects.exists())

    def test_direct_row_with_partial_null_metadata_cannot_bypass_database_shape(self):
        row = credit_points(**self.args)
        with self.assertRaises(IntegrityError), transaction.atomic():
            PointEntry.objects.filter(pk=row.pk).update(earn_category=None)
        with self.assertRaises(IntegrityError), transaction.atomic():
            PointEntry.objects.filter(pk=row.pk).update(rules_version="")
