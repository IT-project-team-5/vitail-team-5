from django.db import migrations, models


class Migration(migrations.Migration):
    dependencies = [("social", "0002_netwalkinvitation")]

    # Add replacements before dropping FK support indexes. This order lets
    # MySQL move each foreign key onto its immutable, single-column index.
    operations = [
        migrations.AddIndex(model_name="netwalkinvitation", index=models.Index(fields=["sender"], name="net_inv_sender_owner")),
        migrations.AddIndex(model_name="netwalkinvitation", index=models.Index(fields=["recipient"], name="net_inv_recipient_owner")),
        migrations.RemoveIndex(model_name="netwalkinvitation", name="net_invitation_sender"),
        migrations.RemoveIndex(model_name="netwalkinvitation", name="net_invitation_recipient"),
        # Status-first lookup indexes speed open invitation scans without
        # becoming mutable support indexes for the owner foreign keys.
        migrations.AddIndex(model_name="netwalkinvitation", index=models.Index(fields=["status", "sender"], name="net_inv_status_sender")),
        migrations.AddIndex(model_name="netwalkinvitation", index=models.Index(fields=["status", "recipient"], name="net_inv_status_recipient")),
    ]
