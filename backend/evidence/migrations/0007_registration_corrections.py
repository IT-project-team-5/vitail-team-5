from django.db import migrations, models


def preserve_renewal_boundary(apps, schema_editor):
    Entitlement = apps.get_model("evidence", "DocumentEntitlement")
    Entitlement.objects.using(schema_editor.connection.alias).filter(kind="COUNCIL_REGISTRATION").update(
        renewal_blocked_through=models.F("valid_to"))


class Migration(migrations.Migration):
    dependencies = [("evidence", "0006_council_document_expiry")]
    operations = [
        migrations.AddField(model_name="documententitlement", name="renewal_blocked_through",
                            field=models.DateField(blank=True, null=True)),
        migrations.RunPython(preserve_renewal_boundary, migrations.RunPython.noop),
    ]
