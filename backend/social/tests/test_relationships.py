from django.contrib.auth import get_user_model
from django.core.exceptions import ValidationError
from django.db import IntegrityError, transaction
from django.test import TestCase

from social.models import Friendship, UserBlock
from social.services import are_friends, block_user, request_friendship, respond_to_friendship, unblock_user


class RelationshipFoundationTests(TestCase):
    @classmethod
    def setUpTestData(cls):
        User = get_user_model()
        cls.first = User.objects.create_user(email="social-first@example.com", display_name="First")
        cls.second = User.objects.create_user(email="social-second@example.com", display_name="Second")
        cls.third = User.objects.create_user(email="social-third@example.com", display_name="Third")

    def test_reciprocal_request_reuses_pair_but_does_not_accept(self):
        first = request_friendship(sender=self.first, recipient=self.second)
        reverse = request_friendship(sender=self.second, recipient=self.first)
        self.assertEqual(first.pk, reverse.pk)
        self.assertFalse(are_friends(self.first.pk, self.second.pk))
        with self.assertRaises(ValidationError):
            respond_to_friendship(actor=self.first, other=self.second, accept=True)
        accepted = respond_to_friendship(actor=self.second, other=self.first, accept=True)
        replay = respond_to_friendship(actor=self.second, other=self.first, accept=True)
        self.assertEqual(accepted.pk, replay.pk)
        self.assertTrue(are_friends(self.first.pk, self.second.pk))

    def test_block_revokes_relationship_and_unblock_does_not_restore_it(self):
        request_friendship(sender=self.first, recipient=self.second)
        respond_to_friendship(actor=self.second, other=self.first, accept=True)
        block_user(actor=self.second, other=self.first)
        self.assertFalse(are_friends(self.first.pk, self.second.pk))
        self.assertFalse(Friendship.objects.exists())
        for sender, recipient in ((self.first, self.second), (self.second, self.first)):
            with self.assertRaises(ValidationError):
                request_friendship(sender=sender, recipient=recipient)
        # The other participant cannot remove this directional block.
        unblock_user(actor=self.first, other=self.second)
        self.assertTrue(UserBlock.objects.exists())
        unblock_user(actor=self.second, other=self.first)
        self.assertFalse(UserBlock.objects.exists())
        self.assertFalse(are_friends(self.first.pk, self.second.pk))

    def test_self_block_invalid_pair_and_outside_requester_are_rejected_by_database(self):
        cases = [
            lambda: UserBlock.objects.create(blocker=self.first, blocked=self.first),
            lambda: Friendship.objects.create(user_low=self.second, user_high=self.first, requested_by=self.first),
            lambda: Friendship.objects.create(user_low=self.first, user_high=self.second, requested_by=self.third),
            lambda: Friendship.objects.create(user_low=self.first, user_high=self.second, requested_by=self.first, status="ACCEPTED"),
        ]
        for operation in cases:
            with self.subTest(operation=operation), self.assertRaises(IntegrityError), transaction.atomic():
                operation()

    def test_cafe_and_inactive_accounts_cannot_create_relationships(self):
        self.second.is_active = False
        self.second.save(update_fields=("is_active",))
        with self.assertRaises(ValidationError):
            request_friendship(sender=self.first, recipient=self.second)
        self.second.is_active = True
        self.second.role = "CAFE"
        self.second.save(update_fields=("is_active", "role"))
        with self.assertRaises(ValidationError):
            request_friendship(sender=self.first, recipient=self.second)

    def test_unrelated_user_cannot_answer_request(self):
        request_friendship(sender=self.first, recipient=self.second)
        with self.assertRaises(ValidationError):
            respond_to_friendship(actor=self.third, other=self.first, accept=True)
        self.assertEqual(Friendship.objects.get().status, "PENDING")
