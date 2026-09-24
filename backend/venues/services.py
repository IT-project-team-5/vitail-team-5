from django.db import transaction
from accounts.models import User
from .models import Venue


def venue_for(user):
    """Create the public place once for a newly onboarded café account."""
    if user.role != "CAFE" or not user.is_active:
        raise ValueError("Only active café accounts can manage a venue.")
    existing = Venue.objects.filter(manager_user_id=user.pk).first()
    if existing is not None:
        return existing
    with transaction.atomic():
        user = User.objects.select_for_update().get(pk=user.pk)
        if user.role != "CAFE" or not user.is_active:
            raise ValueError("Only active café accounts can manage a venue.")
        venue, _ = Venue.objects.get_or_create(manager_user_id=user.pk,
            defaults={"name": user.display_name, "kind": Venue.Kind.CAFE, "is_partner": True})
        return venue
