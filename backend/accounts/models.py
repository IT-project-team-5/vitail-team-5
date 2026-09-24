from django.contrib.auth.models import AbstractBaseUser, PermissionsMixin
from django.db import models
from django.utils import timezone
import uuid

from .managers import UserManager


def new_public_id():
    return uuid.uuid4().hex


class User(AbstractBaseUser, PermissionsMixin):
    class Role(models.TextChoices):
        OWNER = "OWNER", "Owner"
        CAFE = "CAFE", "Café"
        ADMIN = "ADMIN", "Admin"

    email = models.EmailField(unique=True)
    display_name = models.CharField(max_length=100)
    photo = models.FileField(upload_to="avatars/people/", blank=True, null=True)
    role = models.CharField(max_length=10, choices=Role.choices, default=Role.OWNER)
    is_staff = models.BooleanField(default=False)
    is_active = models.BooleanField(default=True)
    date_joined = models.DateTimeField(default=timezone.now)
    public_id = models.CharField(max_length=32, unique=True, default=new_public_id, editable=False)
    virtual_avatar_key = models.CharField(max_length=80, blank=True)
    location_visibility = models.CharField(max_length=10, choices=[("OFF", "Off"), ("FRIENDS", "Friends")], default="OFF")
    net_matching_enabled = models.BooleanField(default=False)
    leaderboard_visible = models.BooleanField(default=False)
    notification_preferences = models.JSONField(default=dict, blank=True)
    active_walk_session = models.OneToOneField("walks.WalkSession", null=True, blank=True, on_delete=models.SET_NULL, related_name="active_for_user")
    auth_version = models.PositiveIntegerField(default=1)
    deleted_at = models.DateTimeField(null=True, blank=True)

    objects = UserManager()

    USERNAME_FIELD = "email"
    REQUIRED_FIELDS = ["display_name"]

    class Meta:
        constraints = [
            models.CheckConstraint(condition=models.Q(location_visibility__in=("OFF", "FRIENDS")), name="user_location_visibility_known"),
            models.CheckConstraint(condition=models.Q(auth_version__gt=0), name="user_auth_version_positive"),
        ]

    def __str__(self):
        return self.email
