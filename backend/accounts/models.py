from django.contrib.auth.models import AbstractBaseUser, PermissionsMixin
from django.db import models
from django.utils import timezone

from .managers import UserManager


class User(AbstractBaseUser, PermissionsMixin):
    class Role(models.TextChoices):
        OWNER = "OWNER", "Owner"
        CAFE = "CAFE", "Café"
        ADMIN = "ADMIN", "Admin"

    email = models.EmailField(unique=True)
    display_name = models.CharField(max_length=100)
    role = models.CharField(max_length=10, choices=Role.choices, default=Role.OWNER)
    is_staff = models.BooleanField(default=False)
    is_active = models.BooleanField(default=True)
    date_joined = models.DateTimeField(default=timezone.now)

    objects = UserManager()

    USERNAME_FIELD = "email"
    REQUIRED_FIELDS = ["display_name"]

    def __str__(self):
        return self.email


class CafeProfile(models.Model):
    """Small café-owned contact/display profile, not a second reward catalogue."""

    user = models.OneToOneField(User, on_delete=models.CASCADE, related_name="cafe_profile")
    address = models.CharField(max_length=255, blank=True)
    description = models.TextField(max_length=2000, blank=True)
    opening_hours = models.CharField(max_length=500, blank=True)

    def __str__(self):
        return self.user.display_name
