from django.conf import settings
from django.db import migrations, models
import django.db.models.deletion


class Migration(migrations.Migration):
    dependencies = [
        ("social", "0001_initial"),
        ("walks", "0003_activity_foundations"),
        migrations.swappable_dependency(settings.AUTH_USER_MODEL),
    ]

    operations = [
        migrations.CreateModel(
            name="NetWalkInvitation",
            fields=[
                ("id", models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name="ID")),
                ("status", models.CharField(choices=[("PENDING", "Pending"), ("ACTIVE", "Walking together"), ("DECLINED", "Declined"), ("ENDED", "Ended"), ("EXPIRED", "Expired"), ("CANCELLED", "Cancelled")], default="PENDING", max_length=10)),
                ("created_at", models.DateTimeField(auto_now_add=True)),
                ("expires_at", models.DateTimeField()),
                ("accepted_at", models.DateTimeField(blank=True, null=True)),
                ("ended_at", models.DateTimeField(blank=True, null=True)),
                ("end_reason", models.CharField(blank=True, max_length=40)),
                ("sender", models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name="net_invitations_sent", to=settings.AUTH_USER_MODEL)),
                ("recipient", models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name="net_invitations_received", to=settings.AUTH_USER_MODEL)),
                ("sender_session", models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name="net_invitations_sent", to="walks.walksession")),
                ("recipient_session", models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name="net_invitations_received", to="walks.walksession")),
            ],
            options={
                "indexes": [models.Index(fields=["sender", "status"], name="net_invitation_sender"), models.Index(fields=["recipient", "status"], name="net_invitation_recipient")],
                "constraints": [models.CheckConstraint(condition=~models.Q(sender=models.F("recipient")), name="net_invitation_not_self")],
            },
        ),
    ]
