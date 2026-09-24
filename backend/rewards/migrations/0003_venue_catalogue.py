import uuid
import hashlib
import json
from zoneinfo import ZoneInfo

import rewards.models

import django.db.models.deletion
import django.core.validators
from django.conf import settings
from django.core.files.storage import default_storage
from django.db import migrations, models


def populate_venues(apps, schema_editor):
    User = apps.get_model("accounts", "User")
    CafeProfile = apps.get_model("accounts", "CafeProfile")
    Venue = apps.get_model("venues", "Venue")
    Reward = apps.get_model("rewards", "Reward")
    Redemption = apps.get_model("rewards", "Redemption")
    PointEntry = apps.get_model("rewards", "PointEntry")
    alias = schema_editor.connection.alias
    identifiers = set(User.objects.using(alias).filter(role="CAFE").values_list("pk", flat=True))
    identifiers.update(CafeProfile.objects.using(alias).values_list("user_id", flat=True))
    identifiers.update(Reward.objects.using(alias).values_list("cafe_user_id", flat=True))
    identifiers.update(Redemption.objects.using(alias).values_list("cafe_user_id", flat=True))
    identifiers.discard(None)
    copied_files = []
    try:
        for user in User.objects.using(alias).filter(pk__in=identifiers).order_by("pk").iterator():
            profile = CafeProfile.objects.using(alias).filter(user_id=user.pk).first()
            venue, created = Venue.objects.using(alias).get_or_create(manager_user_id=user.pk, defaults={
                "name": user.display_name, "kind": "CAFE", "is_partner": True,
                "is_active": user.is_active and user.role == "CAFE", "checkin_enabled": False,
                "address": profile.address if profile else "",
                "description": profile.description if profile else "",
                "opening_hours": profile.opening_hours if profile else "",
                "google_maps_url": profile.google_maps_url if profile else "",
            })
            # The account and venue must never share a deletable storage key.
            # A missing historical upload stays missing; no external fetch or
            # guessed photo/coordinates are introduced by a schema migration.
            if created and user.photo and default_storage.exists(user.photo.name):
                with default_storage.open(user.photo.name, "rb") as source:
                    name = default_storage.save(f"avatars/venues/{uuid.uuid4().hex}.jpg", source)
                copied_files.append(name)
                Venue.objects.using(alias).filter(pk=venue.pk).update(photo=name)
            Reward.objects.using(alias).filter(cafe_user_id=user.pk).update(venue_id=venue.pk)
            # Historical responsible account, not the product's current owner.
            Redemption.objects.using(alias).filter(cafe_user_id=user.pk).update(venue_id=venue.pk)
        Reward.objects.using(alias).update(updated_at=models.F("created_at"))
        for order in Redemption.objects.using(alias).order_by("pk").iterator():
            updates = {"order_date": order.created_at.astimezone(ZoneInfo("Australia/Melbourne")).date()}
            if order.request_id:
                payload = json.dumps({"reward_id": order.reward_id}, sort_keys=True, separators=(",", ":"))
                updates["request_fingerprint"] = hashlib.sha256(payload.encode()).hexdigest()
            # Only link an exact existing event. Never invent a debit/refund or
            # infer one from a similar amount if the stable source is missing.
            spend = PointEntry.objects.using(alias).filter(
                source_reference=f"redemption:{order.reference_number}", user_id=order.owner_user_id,
                amount=-order.point_cost_snapshot, type="SPEND").first()
            if spend:
                updates["spend_entry_id"] = spend.pk
            if order.status in ("EXPIRED", "CANCELLED"):
                refund = PointEntry.objects.using(alias).filter(
                    source_reference=f"refund:{order.reference_number}", user_id=order.owner_user_id,
                    amount=order.point_cost_snapshot, type="REFUND").first()
                if refund:
                    updates["refund_entry_id"] = refund.pk
            Redemption.objects.using(alias).filter(pk=order.pk).update(**updates)
    except BaseException:
        for name in copied_files:
            default_storage.delete(name)
        raise


def restore_cafe_links(apps, schema_editor):
    Reward = apps.get_model("rewards", "Reward")
    Venue = apps.get_model("venues", "Venue")
    CafeProfile = apps.get_model("accounts", "CafeProfile")
    alias = schema_editor.connection.alias
    for venue in Venue.objects.using(alias).exclude(manager_user_id=None).iterator():
        Reward.objects.using(alias).filter(venue_id=venue.pk).update(cafe_user_id=venue.manager_user_id)
        CafeProfile.objects.using(alias).update_or_create(user_id=venue.manager_user_id, defaults={
            "address": venue.address, "description": venue.description,
            "opening_hours": venue.opening_hours, "google_maps_url": venue.google_maps_url,
        })


class Migration(migrations.Migration):
    dependencies = [("rewards", "0002_connected_redemptions"), ("venues", "0001_initial")]
    operations = [
        migrations.AddField(model_name="reward", name="venue", field=models.ForeignKey(null=True, on_delete=django.db.models.deletion.PROTECT, related_name="rewards", to="venues.venue")),
        migrations.AddField(model_name="redemption", name="venue", field=models.ForeignKey(null=True, on_delete=django.db.models.deletion.PROTECT, related_name="redemptions", to="venues.venue")),
        migrations.AlterField(model_name="reward", name="cafe_user", field=models.ForeignKey(null=True, on_delete=django.db.models.deletion.PROTECT, related_name="rewards", to=settings.AUTH_USER_MODEL)),
        migrations.AddField(model_name="reward", name="photo", field=models.FileField(blank=True, max_length=255, upload_to="rewards/photos/")),
        migrations.AddField(model_name="reward", name="starts_at", field=models.DateTimeField(blank=True, null=True)),
        migrations.AddField(model_name="reward", name="ends_at", field=models.DateTimeField(blank=True, null=True)),
        migrations.AddField(model_name="reward", name="daily_quantity_limit", field=models.PositiveIntegerField(blank=True, null=True, validators=[django.core.validators.MinValueValidator(1)])),
        migrations.AddField(model_name="reward", name="terms", field=models.TextField(blank=True)),
        migrations.AddField(model_name="reward", name="requires_store_purchase", field=models.BooleanField(default=False)),
        migrations.AddField(model_name="reward", name="updated_at", field=models.DateTimeField(auto_now=True, null=True)),
        migrations.AddField(model_name="redemption", name="request_fingerprint", field=models.CharField(blank=True, max_length=64, null=True)),
        migrations.AddField(model_name="redemption", name="terms_snapshot", field=models.TextField(blank=True)),
        migrations.AddField(model_name="redemption", name="eligibility_snapshot", field=models.JSONField(blank=True, default=dict)),
        migrations.AddField(model_name="redemption", name="order_date", field=models.DateField(null=True)),
        migrations.AddField(model_name="redemption", name="spend_entry", field=models.OneToOneField(blank=True, null=True, on_delete=django.db.models.deletion.PROTECT, related_name="spent_redemption", to="rewards.pointentry")),
        migrations.AddField(model_name="redemption", name="refund_entry", field=models.OneToOneField(blank=True, null=True, on_delete=django.db.models.deletion.PROTECT, related_name="refunded_redemption", to="rewards.pointentry")),
        migrations.RunPython(populate_venues, restore_cafe_links, atomic=True),
        migrations.AlterField(model_name="reward", name="updated_at", field=models.DateTimeField(auto_now=True)),
        migrations.AlterField(model_name="redemption", name="order_date", field=models.DateField(default=rewards.models.redemption_order_date)),
        migrations.AlterField(model_name="reward", name="venue", field=models.ForeignKey(on_delete=django.db.models.deletion.PROTECT, related_name="rewards", to="venues.venue")),
        migrations.AlterField(model_name="redemption", name="venue", field=models.ForeignKey(on_delete=django.db.models.deletion.PROTECT, related_name="redemptions", to="venues.venue")),
        migrations.AlterModelOptions(name="reward", options={"ordering": ("venue__name", "point_cost", "name", "id")}),
        migrations.RemoveField(model_name="reward", name="cafe_user"),
        migrations.AddConstraint(model_name="reward", constraint=models.CheckConstraint(condition=models.Q(daily_quantity_limit__isnull=True) | models.Q(daily_quantity_limit__gt=0), name="reward_daily_limit_positive")),
        migrations.AddConstraint(model_name="reward", constraint=models.CheckConstraint(condition=models.Q(starts_at__isnull=True) | models.Q(ends_at__isnull=True) | models.Q(ends_at__gt=models.F("starts_at")), name="reward_window_ordered")),
        migrations.AddConstraint(model_name="redemption", constraint=models.CheckConstraint(condition=models.Q(refund_entry__isnull=True) | models.Q(status__in=["EXPIRED", "CANCELLED"]), name="redemption_refund_terminal")),
        migrations.AddIndex(model_name="reward", index=models.Index(fields=("venue", "is_available"), name="reward_venue_available_idx")),
        migrations.AddIndex(model_name="redemption", index=models.Index(fields=("cafe_user", "feed_cursor"), name="redemption_cafe_cursor_idx")),
        migrations.AddIndex(model_name="redemption", index=models.Index(fields=("owner_user", "created_at"), name="redemption_owner_created_idx")),
        migrations.AddIndex(model_name="redemption", index=models.Index(fields=("reward", "order_date", "status"), name="redemption_reward_quota_idx")),
        migrations.AddIndex(model_name="redemption", index=models.Index(fields=("status", "expires_at"), name="redemption_status_expiry_idx")),
    ]
