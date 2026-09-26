from django.db import migrations, models


class Migration(migrations.Migration):
    dependencies = [("evidence", "0005_council_annual_rewards")]

    # Existing years, expiry dates, receipts and ledger entries stay untouched.
    # A missing expiry is deliberately not inferred from an annual reward key.
    operations = [
        migrations.RemoveConstraint(model_name="documententitlement", name="council_dog_year_unique"),
        migrations.RemoveConstraint(model_name="documententitlement", name="council_reward_year_shape"),
        migrations.AddField(model_name="documentsubmission", name="registry_name", field=models.CharField(blank=True, max_length=100)),
        migrations.AddField(model_name="documentsubmission", name="document_dog_name", field=models.CharField(blank=True, max_length=100)),
        migrations.AddField(model_name="documentsubmission", name="document_reading", field=models.JSONField(blank=True, null=True)),
    ]
