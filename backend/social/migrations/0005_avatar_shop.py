import django.db.models.deletion
from django.conf import settings
from django.db import migrations, models


class Migration(migrations.Migration):
    dependencies = [
        ("accounts", "0006_user_dog_map_profile"),
        ("rewards", "0004_pointentry_sources"),
        ("social", "0004_netwalkinvitation_net_invitation_status_time_shape"),
    ]

    operations = [
        migrations.CreateModel(
            name="AvatarPurchase",
            fields=[
                ("id", models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name="ID")),
                ("product_code", models.CharField(max_length=40)),
                ("request_id", models.UUIDField(editable=False)),
                ("point_cost_snapshot", models.PositiveIntegerField(editable=False)),
                ("created_at", models.DateTimeField(auto_now_add=True)),
                ("owner", models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name="avatar_purchases", to=settings.AUTH_USER_MODEL)),
                ("spend_entry", models.OneToOneField(editable=False, on_delete=django.db.models.deletion.PROTECT, related_name="avatar_purchase", to="rewards.pointentry")),
            ],
            options={
                "constraints": [
                    models.UniqueConstraint(fields=("owner", "product_code"), name="avatar_purchase_owner_product"),
                    models.UniqueConstraint(fields=("owner", "request_id"), name="avatar_purchase_owner_request"),
                    models.CheckConstraint(condition=models.Q(point_cost_snapshot__gt=0), name="avatar_purchase_cost_positive"),
                    models.CheckConstraint(condition=models.Q(product_code__in=("baseballCap", "beanie", "sunHat", "stripedBandana", "polkaDotBandana", "roundGlasses", "starBadge")), name="avatar_purchase_product_known"),
                ],
            },
        ),
        migrations.CreateModel(
            name="AvatarPurchaseRequest",
            fields=[
                ("id", models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name="ID")),
                ("request_id", models.UUIDField(editable=False)),
                ("created_at", models.DateTimeField(auto_now_add=True)),
                ("owner", models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name="avatar_purchase_requests", to=settings.AUTH_USER_MODEL)),
                ("purchase", models.ForeignKey(editable=False, on_delete=django.db.models.deletion.PROTECT, related_name="requests", to="social.avatarpurchase")),
            ],
            options={
                "constraints": [models.UniqueConstraint(fields=("owner", "request_id"), name="avatar_request_owner_uuid")],
            },
        ),
        migrations.CreateModel(
            name="AvatarWardrobe",
            fields=[
                ("id", models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name="ID")),
                ("hat_product_code", models.CharField(blank=True, max_length=40, null=True)),
                ("bandana_product_code", models.CharField(blank=True, max_length=40, null=True)),
                ("extra_product_code", models.CharField(blank=True, max_length=40, null=True)),
                ("owner", models.OneToOneField(on_delete=django.db.models.deletion.CASCADE, related_name="avatar_wardrobe", to=settings.AUTH_USER_MODEL)),
            ],
            options={
                "constraints": [
                    models.CheckConstraint(condition=models.Q(hat_product_code__isnull=True) | models.Q(hat_product_code__in=("baseballCap", "beanie", "sunHat")), name="avatar_wardrobe_hat_known"),
                    models.CheckConstraint(condition=models.Q(bandana_product_code__isnull=True) | models.Q(bandana_product_code__in=("stripedBandana", "polkaDotBandana")), name="avatar_wardrobe_bandana_known"),
                    models.CheckConstraint(condition=models.Q(extra_product_code__isnull=True) | models.Q(extra_product_code__in=("roundGlasses", "starBadge")), name="avatar_wardrobe_extra_known"),
                ],
            },
        ),
    ]
