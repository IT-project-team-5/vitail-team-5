import django.db.models.deletion
from django.conf import settings
from django.db import migrations, models


def preserve_existing_orders(apps, schema_editor):
    Redemption = apps.get_model("rewards", "Redemption")
    FeedState = apps.get_model("rewards", "CafeOrderFeedState")
    database = schema_editor.connection.alias
    cursors = {}
    for order in Redemption.objects.using(database).select_related(
        "owner_user", "reward__cafe_user"
    ).order_by("created_at", "id").iterator():
        cafe = order.reward.cafe_user
        cursors[cafe.pk] = cursors.get(cafe.pk, 0) + 1
        Redemption.objects.using(database).filter(pk=order.pk).update(
            cafe_user_id=cafe.pk, cafe_name_snapshot=cafe.display_name,
            owner_name_snapshot=order.owner_user.display_name,
            feed_cursor=cursors[cafe.pk],
        )
    FeedState.objects.using(database).bulk_create([
        FeedState(cafe_user_id=cafe_id, cursor=cursor)
        for cafe_id, cursor in cursors.items()
    ])


class Migration(migrations.Migration):
    dependencies = [
        ("rewards", "0001_initial"),
        migrations.swappable_dependency(settings.AUTH_USER_MODEL),
    ]

    operations = [
        migrations.AlterField(
            model_name="pointentry", name="user",
            field=models.ForeignKey(on_delete=django.db.models.deletion.PROTECT, related_name="point_entries", to=settings.AUTH_USER_MODEL),
        ),
        migrations.AlterField(
            model_name="redemption", name="owner_user",
            field=models.ForeignKey(on_delete=django.db.models.deletion.PROTECT, related_name="redemptions", to=settings.AUTH_USER_MODEL),
        ),
        migrations.AddField(
            model_name="redemption", name="cafe_user",
            field=models.ForeignKey(null=True, on_delete=django.db.models.deletion.PROTECT, related_name="cafe_redemptions", to=settings.AUTH_USER_MODEL, help_text="Café responsible when ordered; later catalogue changes do not move orders."),
        ),
        migrations.AddField(
            model_name="redemption", name="owner_name_snapshot",
            field=models.CharField(default="", max_length=100), preserve_default=False,
        ),
        migrations.AddField(
            model_name="redemption", name="cafe_name_snapshot",
            field=models.CharField(default="", max_length=100), preserve_default=False,
        ),
        migrations.AddField(
            model_name="redemption", name="request_id",
            field=models.UUIDField(null=True, blank=True),
        ),
        migrations.AddField(
            model_name="redemption", name="feed_cursor",
            field=models.PositiveBigIntegerField(default=0),
        ),
        migrations.CreateModel(
            name="CafeOrderFeedState",
            fields=[
                ("cafe_user", models.OneToOneField(on_delete=django.db.models.deletion.CASCADE, primary_key=True, serialize=False, to=settings.AUTH_USER_MODEL)),
                ("cursor", models.PositiveBigIntegerField(default=0)),
            ],
        ),
        migrations.RunPython(preserve_existing_orders, migrations.RunPython.noop),
        migrations.AlterField(
            model_name="redemption", name="cafe_user",
            field=models.ForeignKey(on_delete=django.db.models.deletion.PROTECT, related_name="cafe_redemptions", to=settings.AUTH_USER_MODEL, help_text="Café responsible when ordered; later catalogue changes do not move orders."),
        ),
        migrations.AddConstraint(
            model_name="redemption",
            constraint=models.UniqueConstraint(fields=("owner_user", "request_id"), name="redemption_owner_request_unique"),
        ),
    ]
